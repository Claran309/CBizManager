enum DictionaryKind {
  supplierCompany('supplier_company'),
  customer('customer'),
  productName('product_name'),
  productModel('product_model'),
  unit('unit'),
  shippingUnit('shipping_unit');

  const DictionaryKind(this.wireValue);

  final String wireValue;

  static DictionaryKind fromWireValue(String value) => values.firstWhere(
    (kind) => kind.wireValue == value,
    orElse: () => throw FormatException('Unknown dictionary kind: $value'),
  );
}

/// 每种 kind 的可写字段规则。
///
/// **这些不是界面偏好，是后端的硬约束**（`backend/internal/dictionary/service.go`
/// 的 `validateDraft`）：提交了不该出现的字段会被直接拒绝。所以客户端必须照它裁剪，
/// 而不是「反正服务端会校验，我全发过去」—— 那只会让用户在点保存之后才吃到
/// 一个他完全无法理解的 `VALIDATION_FAILED`。
extension DictionaryKindRules on DictionaryKind {
  /// 中文名。
  ///
  /// 放在领域层而不是展示层：它是「字典类型的业务名称」（原型里的
  /// 进项公司 / 客户 / 品名 / 型号 / 单位 / 出货单位），页面与 editor 都要用，
  /// 两处各写一遍就可能出现「列表叫品名、编辑器叫产品名称」这种不一致。
  String get label => switch (this) {
    DictionaryKind.supplierCompany => '进项公司',
    DictionaryKind.customer => '客户',
    DictionaryKind.productName => '品名',
    DictionaryKind.productModel => '型号',
    DictionaryKind.unit => '单位',
    DictionaryKind.shippingUnit => '出货单位',
  };

  /// 是否接受联系电话。**只有 `customer` 可以带**，其余 kind 提交就报校验失败。
  bool get acceptsContactPhone => this == DictionaryKind.customer;

  /// 是否必须挂在某个品名之下。`product_model` 的父级是**必填**的，
  /// 且父级必须是一条**启用中**的 `product_name`。
  bool get requiresParent => this == DictionaryKind.productModel;

  /// 写入时是否需要（且允许）提交 `parent_id`。
  ///
  /// 与 [requiresParent] 分开：其余 kind 也可能有历史遗留的 `parent_id`，
  /// 但**写入时必须不带**（后端对非 product_model 的 parent_id 一律判非法）。
  bool get usesParent => this == DictionaryKind.productModel;
}

enum DictionaryStatus {
  active('active'),
  disabled('disabled');

  const DictionaryStatus(this.wireValue);

  final String wireValue;

  static DictionaryStatus fromWireValue(String value) => values.firstWhere(
    (status) => status.wireValue == value,
    orElse: () => throw FormatException('Unknown dictionary status: $value'),
  );
}

final class DictionaryEntry {
  const DictionaryEntry({
    required this.id,
    required this.groupId,
    required this.kind,
    required this.name,
    this.parentId,
    this.contactPhone,
    required this.status,
    required this.version,
  });

  final int id;
  final int groupId;
  final DictionaryKind kind;
  final String name;
  final int? parentId;
  final String? contactPhone;
  final DictionaryStatus status;
  final int version;

  factory DictionaryEntry.fromJson(Map<String, Object?> json) {
    return DictionaryEntry(
      id: json['id'] as int,
      groupId: json['group_id'] as int,
      kind: DictionaryKind.fromWireValue(json['kind'] as String),
      name: json['name'] as String,
      parentId: json['parent_id'] as int?,
      contactPhone: json['contact_phone'] as String?,
      status: DictionaryStatus.fromWireValue(json['status'] as String),
      version: json['version'] as int,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is DictionaryEntry &&
      id == other.id &&
      groupId == other.groupId &&
      kind == other.kind &&
      name == other.name &&
      parentId == other.parentId &&
      contactPhone == other.contactPhone &&
      status == other.status &&
      version == other.version;

  @override
  int get hashCode => Object.hash(
    id,
    groupId,
    kind,
    name,
    parentId,
    contactPhone,
    status,
    version,
  );
}

final class DictionaryQuery {
  const DictionaryQuery({this.kind, this.parentId, this.status, this.keyword});

  final DictionaryKind? kind;

  /// 只查挂在某个父级下的条目（实际只对 `product_model` 有意义）。
  final int? parentId;

  /// 状态筛选。
  ///
  /// **null 表示「只看启用中的条目」，不是「全部状态」。** 契约里根本没有
  /// 「两种状态都返回」的取值：服务端在没有 `status` 参数时会把它收敛成
  /// `active`（`backend/internal/dictionary/service.go` 的 `List`），
  /// 而显式传 `disabled` 需要 `dictionary.manage` 权限、传其它值一律校验失败。
  /// 所以页面的「启用中」对应的就是这个 null。
  ///
  /// 它同时是**本地兜底缓存**的判据之一（`DefaultDictionaryRepository`
  /// 只在「没有额外筛选」时写缓存），这也要求「启用中」必须用 null 表达。
  final DictionaryStatus? status;

  /// 名称关键词，交给服务端做规范化后的模糊匹配。
  final String? keyword;
}

final class DictionaryDraft {
  const DictionaryDraft({
    required this.kind,
    required this.name,
    this.parentId,
    this.contactPhone,
  });

  final DictionaryKind kind;
  final String name;
  final int? parentId;
  final String? contactPhone;
}
