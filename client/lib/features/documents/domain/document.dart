import 'package:c_biz_docs_manager/core/bizdate/bizdate.dart';
import 'package:c_biz_docs_manager/core/money/money.dart';

/// 单据方向：入库 / 出库。
///
/// 两种单据共享同一套表结构，由 `kind` 判别列承载；客户端据此拼不同的路由前缀
/// （`/inbound-documents` / `/outbound-documents`）与单号前缀（RK / CK）。
enum DocumentKind {
  inbound('inbound'),
  outbound('outbound');

  const DocumentKind(this.wireValue);

  final String wireValue;

  static DocumentKind fromWireValue(String value) => values.firstWhere(
    (kind) => kind.wireValue == value,
    orElse: () => throw FormatException('未知单据类型：$value'),
  );

  /// 单号前缀（入库 RK、出库 CK）。
  String get numberPrefix => this == DocumentKind.outbound ? 'CK' : 'RK';

  bool get isInbound => this == DocumentKind.inbound;
}

/// 单据业务状态。一期只保留草稿、已提交、已作废三态，
/// 结算审批状态由结算单自身承载，避免单据状态机被审批流程污染。
enum DocumentStatus {
  draft('draft'),
  submitted('submitted'),
  voided('voided');

  const DocumentStatus(this.wireValue);

  final String wireValue;

  static DocumentStatus fromWireValue(String value) => values.firstWhere(
    (status) => status.wireValue == value,
    orElse: () => throw FormatException('未知单据状态：$value'),
  );

  /// 是否终态（作废后不可再动）。
  bool get isTerminal => this == DocumentStatus.voided;
}

/// 明细的单价类型（含税价 / 不含税价）。
///
/// 一期仅用于业务记录与展示，不改变「金额 = 单价 × 数量」的计算公式。
enum PriceTaxMode {
  taxIncluded('tax_included'),
  taxExcluded('tax_excluded');

  const PriceTaxMode(this.wireValue);

  final String wireValue;

  static PriceTaxMode fromWireValue(String value) => values.firstWhere(
    (mode) => mode.wireValue == value,
    orElse: () => throw FormatException('未知价税方式：$value'),
  );
}

/// 出库单的销售金额类型，稳定代码值保持不变，界面再翻译成中文。
enum SaleAmountType {
  /// 增值税专用发票销售金额。
  vatSpecial('Y-1'),

  /// 增值税普通发票销售金额。
  vatGeneral('y-N'),

  /// 不开票销售金额。
  noInvoice('N');

  const SaleAmountType(this.wireValue);

  final String wireValue;

  static SaleAmountType fromWireValue(String value) => values.firstWhere(
    (type) => type.wireValue == value,
    orElse: () => throw FormatException('未知销售金额类型：$value'),
  );
}

/// 单据里的业务员摘要。
///
/// 与认证里的 [AuthUser] 不同，这里的解析是**宽松**的：列表行响应只回填
/// `id` 与 `display_name`，`username` / `account_type` 是零值空串（后端
/// `toSummaryData` 只填 `ID` + `DisplayName`）。所以这里只对 `id`（>0）与
/// `display_name` 做强校验，`username` / `account_type` 允许空串。
final class DocumentBusinessUser {
  const DocumentBusinessUser({
    required this.id,
    required this.displayName,
    required this.username,
    required this.accountType,
  });

  final int id;
  final String displayName;

  /// 列表行可能为空串（未回填）。
  final String username;

  /// 列表行可能为空串（未回填）。
  final String accountType;

  factory DocumentBusinessUser.fromJson(Map<String, Object?> json) {
    final id = json['id'];
    if (id is! int || id < 1) {
      throw const FormatException('业务员 id 无效');
    }
    final displayName = json['display_name'];
    if (displayName is! String) {
      throw const FormatException('业务员 display_name 无效');
    }
    return DocumentBusinessUser(
      id: id,
      displayName: displayName,
      username: json['username'] is String ? json['username'] as String : '',
      accountType: json['account_type'] is String
          ? json['account_type'] as String
          : '',
    );
  }
}

/// 单据列表行（对应契约 `DocumentSummaryData`）。
final class DocumentSummary {
  const DocumentSummary({
    required this.documentId,
    required this.kind,
    required this.documentNo,
    required this.status,
    required this.businessDate,
    required this.businessUser,
    required this.partyNames,
    required this.itemCount,
    required this.totalAmount,
    required this.version,
    this.shippingUnit,
    this.saleAmountType,
    this.submittedAt,
    required this.createdAt,
    required this.updatedAt,
  });

  final int documentId;
  final DocumentKind kind;
  final String documentNo;
  final DocumentStatus status;
  final DateTime businessDate;
  final DocumentBusinessUser businessUser;

  /// 去重后的往来单位名。
  final List<String> partyNames;
  final int itemCount;
  final Amount totalAmount;
  final int version;

  /// 运输单位，仅出库单；入库单恒 null。
  final String? shippingUnit;

  /// 销售金额类型，仅出库单。
  final SaleAmountType? saleAmountType;
  final DateTime? submittedAt;
  final DateTime createdAt;
  final DateTime updatedAt;

  factory DocumentSummary.fromJson(Map<String, Object?> json) =>
      DocumentSummary(
        documentId: _readPositiveInt(json, 'document_id'),
        kind: DocumentKind.fromWireValue(_readString(json, 'kind')),
        documentNo: _readString(json, 'document_no'),
        status: DocumentStatus.fromWireValue(_readString(json, 'status')),
        businessDate: parseDate(_readString(json, 'business_date')),
        businessUser: DocumentBusinessUser.fromJson(
          _readObject(json, 'business_user'),
        ),
        partyNames: _readStringList(json, 'party_names'),
        itemCount: _readInt(json, 'item_count'),
        totalAmount: _readAmount(json, 'total_amount'),
        version: _readInt(json, 'version'),
        shippingUnit: json['shipping_unit'] as String?,
        saleAmountType: json['sale_amount_type'] == null
            ? null
            : SaleAmountType.fromWireValue(json['sale_amount_type'] as String),
        submittedAt: json['submitted_at'] == null
            ? null
            : DateTime.parse(json['submitted_at'] as String).toUtc(),
        createdAt: _readDateTime(json, 'created_at'),
        updatedAt: _readDateTime(json, 'updated_at'),
      );
}

/// 单据明细行（对应契约 `ItemData`）。
final class DocumentItem {
  const DocumentItem({
    required this.itemId,
    required this.position,
    required this.productName,
    required this.quantity,
    required this.unitPrice,
    required this.priceTaxMode,
    required this.amount,
    this.productModel,
    this.unit,
    this.weight,
    this.remark,
  });

  final int itemId;
  final int position;
  final String productName;
  final String? productModel;
  final String? unit;
  final Quantity quantity;
  final Quantity? weight;
  final UnitPrice unitPrice;
  final PriceTaxMode priceTaxMode;

  /// 金额 = 单价 × 数量，由服务端计算；客户端只展示。
  final Amount amount;
  final String? remark;

  factory DocumentItem.fromJson(Map<String, Object?> json) => DocumentItem(
    itemId: _readPositiveInt(json, 'item_id'),
    position: _readInt(json, 'position'),
    productName: _readString(json, 'product_name'),
    productModel: json['product_model'] as String?,
    unit: json['unit'] as String?,
    quantity: _readQuantity(json, 'quantity'),
    weight: json['weight'] == null
        ? null
        : Quantity.parse(json['weight'] as String),
    unitPrice: _readUnitPrice(json, 'unit_price'),
    priceTaxMode: PriceTaxMode.fromWireValue(
      _readString(json, 'price_tax_mode'),
    ),
    amount: _readAmount(json, 'amount'),
    remark: json['remark'] as String?,
  );
}

/// 往来单位分组（对应契约 `PartyData`）：入库是进项公司，出库是客户。
final class DocumentParty {
  const DocumentParty({
    required this.partyId,
    required this.position,
    required this.partyName,
    required this.subtotal,
    required this.items,
    this.contactPhone,
  });

  final int partyId;
  final int position;
  final String partyName;
  final String? contactPhone;
  final Amount subtotal;
  final List<DocumentItem> items;

  factory DocumentParty.fromJson(Map<String, Object?> json) => DocumentParty(
    partyId: _readPositiveInt(json, 'party_id'),
    position: _readInt(json, 'position'),
    partyName: _readString(json, 'party_name'),
    contactPhone: json['contact_phone'] as String?,
    subtotal: _readAmount(json, 'subtotal'),
    items: <DocumentItem>[
      for (final item in _readObjectList(json, 'items'))
        DocumentItem.fromJson(item),
    ],
  );
}

/// 单据详情（对应契约 `DocumentData`）：主表 + 往来单位 + 明细。
final class DocumentDetail {
  const DocumentDetail({
    required this.documentId,
    required this.kind,
    required this.documentNo,
    required this.status,
    required this.businessUser,
    required this.businessDate,
    required this.totalAmount,
    required this.totalAmountUpper,
    required this.version,
    required this.parties,
    required this.createdAt,
    required this.updatedAt,
    this.shippingUnit,
    this.saleAmountType,
    this.remark,
    this.submittedAt,
  });

  final int documentId;
  final DocumentKind kind;
  final String documentNo;
  final DocumentStatus status;
  final DocumentBusinessUser businessUser;
  final DateTime businessDate;
  final String? shippingUnit;
  final SaleAmountType? saleAmountType;
  final Amount totalAmount;

  /// 人民币大写，由服务端生成，客户端直接展示。
  final String totalAmountUpper;
  final String? remark;
  final int version;
  final DateTime? submittedAt;
  final DateTime createdAt;
  final DateTime updatedAt;
  final List<DocumentParty> parties;

  factory DocumentDetail.fromJson(Map<String, Object?> json) => DocumentDetail(
    documentId: _readPositiveInt(json, 'document_id'),
    kind: DocumentKind.fromWireValue(_readString(json, 'kind')),
    documentNo: _readString(json, 'document_no'),
    status: DocumentStatus.fromWireValue(_readString(json, 'status')),
    businessUser: DocumentBusinessUser.fromJson(
      _readObject(json, 'business_user'),
    ),
    businessDate: parseDate(_readString(json, 'business_date')),
    shippingUnit: json['shipping_unit'] as String?,
    saleAmountType: json['sale_amount_type'] == null
        ? null
        : SaleAmountType.fromWireValue(json['sale_amount_type'] as String),
    totalAmount: _readAmount(json, 'total_amount'),
    totalAmountUpper: _readString(json, 'total_amount_upper'),
    remark: json['remark'] as String?,
    version: _readInt(json, 'version'),
    submittedAt: json['submitted_at'] == null
        ? null
        : DateTime.parse(json['submitted_at'] as String).toUtc(),
    createdAt: _readDateTime(json, 'created_at'),
    updatedAt: _readDateTime(json, 'updated_at'),
    parties: <DocumentParty>[
      for (final party in _readObjectList(json, 'parties'))
        DocumentParty.fromJson(party),
    ],
  );
}

/* --------------------------------------------------------- 查询与写入草稿 */

/// 单据列表查询条件。
///
/// 全部可选（除分页），「有才带」：查询时不筛的字段不拼进 query，
/// 避免显式传 null 被序列化成空串、被服务端按非法枚举拒绝。
final class DocumentQuery {
  const DocumentQuery({
    this.status,
    this.keyword,
    this.month,
    this.businessUserId,
    this.dateFrom,
    this.dateTo,
    this.page = 1,
    this.pageSize = 20,
  });

  final DocumentStatus? status;

  /// 同时匹配单号与往来单位名。
  final String? keyword;

  /// 形如 `2026-09` 的业务月份。
  final String? month;
  final int? businessUserId;
  final String? dateFrom;
  final String? dateTo;
  final int page;
  final int pageSize;
}

/// 明细写入草稿。
///
/// 数量 / 单价是**字符串**（客户端只做输入校验，不做金额计算；金额由服务端按
/// 单价×数量 算出）。提交时原样发字符串，与后端「金额字段 JSON 一律字符串」一致。
final class ItemDraft {
  const ItemDraft({
    required this.productName,
    required this.quantity,
    required this.unitPrice,
    required this.priceTaxMode,
    this.productModel,
    this.unit,
    this.weight,
    this.remark,
  });

  final String productName;
  final String? productModel;
  final String? unit;

  /// 数量，十进制字符串（如 `"17.050"`）。
  final String quantity;

  /// 重量，可选，十进制字符串。
  final String? weight;

  /// 单价，十进制字符串（如 `"2975.4300"`）。
  final String unitPrice;
  final PriceTaxMode priceTaxMode;
  final String? remark;
}

/// 往来单位写入草稿（入库=进项公司，出库=客户）。
final class PartyDraft {
  const PartyDraft({
    required this.partyName,
    required this.items,
    this.contactPhone,
    this.dictionaryEntryId,
  });

  final String partyName;
  final String? contactPhone;
  final int? dictionaryEntryId;
  final List<ItemDraft> items;
}

/// 创建 / 整体替换单据的写入草稿。
///
/// 没有 `kind`（由仓储构造参数决定）也没有 `amount`（服务端算）。
final class DocumentDraft {
  const DocumentDraft({
    required this.status,
    required this.businessDate,
    required this.parties,
    this.businessUserId,
    this.shippingUnit,
    this.saleAmountType,
    this.remark,
  });

  final DocumentStatus status;

  /// 业务日期，形如 `2026-09-22`（由表单层用 bizdate 解析后再拼回）。
  final String businessDate;

  /// 缺省时由服务端取当前用户。
  final int? businessUserId;

  /// 运输单位，仅出库单；入库单不填。
  final String? shippingUnit;

  /// 销售金额类型，仅出库单；提交时必填。
  final SaleAmountType? saleAmountType;
  final String? remark;
  final List<PartyDraft> parties;
}

/* --------------------------------------------------------- 严格解析辅助 */

Map<String, Object?> _readObject(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! Map) {
    throw FormatException('字段 "$key" 必须是对象');
  }
  return Map<String, Object?>.from(value);
}

List<Map<String, Object?>> _readObjectList(
  Map<String, Object?> json,
  String key,
) {
  final value = json[key];
  if (value is! List) {
    throw FormatException('字段 "$key" 必须是数组');
  }
  return <Map<String, Object?>>[
    for (final item in value)
      if (item is Map)
        Map<String, Object?>.from(item)
      else
        throw FormatException('字段 "$key" 的元素必须是对象'),
  ];
}

int _readInt(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! int) {
    throw FormatException('字段 "$key" 必须是整数');
  }
  return value;
}

int _readPositiveInt(Map<String, Object?> json, String key) {
  final value = _readInt(json, key);
  if (value < 1) {
    throw FormatException('字段 "$key" 必须是正整数');
  }
  return value;
}

String _readString(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! String || value.isEmpty) {
    throw FormatException('字段 "$key" 必须是非空字符串');
  }
  return value;
}

List<String> _readStringList(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! List) {
    throw FormatException('字段 "$key" 必须是字符串数组');
  }
  return <String>[
    for (final item in value)
      if (item is String)
        item
      else
        throw FormatException('字段 "$key" 的元素必须是字符串'),
  ];
}

DateTime _readDateTime(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! String) {
    throw FormatException('字段 "$key" 必须是 ISO-8601 时间');
  }
  return DateTime.parse(value).toUtc();
}

/// 金额字段必须是字符串（契约约定），数字直接拒绝。
Amount _readAmount(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! String) {
    throw FormatException('字段 "$key" 必须是金额字符串');
  }
  return Amount.parse(value);
}

UnitPrice _readUnitPrice(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! String) {
    throw FormatException('字段 "$key" 必须是单价字符串');
  }
  return UnitPrice.parse(value);
}

Quantity _readQuantity(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! String) {
    throw FormatException('字段 "$key" 必须是数量字符串');
  }
  return Quantity.parse(value);
}
