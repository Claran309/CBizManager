import 'package:c_biz_docs_manager/core/auth/auth_models.dart';

enum MemberStatus {
  active('active'),
  disabled('disabled'),
  removed('removed');

  const MemberStatus(this.wireValue);

  final String wireValue;

  static MemberStatus fromWireValue(String value) => values.firstWhere(
    (status) => status.wireValue == value,
    orElse: () => throw FormatException('Unknown member status: $value'),
  );
}

final class Member {
  const Member({
    required this.membershipId,
    required this.userId,
    required this.username,
    required this.displayName,
    required this.memberType,
    required this.status,
    required this.permissionCodes,
    required this.version,
  });

  final int membershipId;

  /// 成员对应账号的用户 ID（契约 `UserSummary.id`）。
  ///
  /// 界面判断「这一行是不是我自己」只能靠它。**不要用 [username] 比身份**：
  /// 用户名是可改的，改过之后「自己」这一行会突然认不出来，
  /// 于是本该禁止的操作（停用自己 / 撤自己的权限）重新变得可点。
  final int userId;

  final String username;
  final String displayName;

  /// 成员的组内角色，契约枚举 `owner` / `member`。
  ///
  /// 解析时**不**在这里转成 [MemberType]：未知取值要让整条记录解析失败
  /// （而不是降级成 member），判断留给 [isGroupOwner]，
  /// 它复用 core/auth 那份枚举当唯一真相，避免散落 `'owner'` 字面量。
  final String memberType;

  final MemberStatus status;
  final Set<String> permissionCodes;
  final int version;

  /// 这一行是不是组主账号。
  bool get isGroupOwner => memberType == MemberType.owner.wireValue;

  factory Member.fromJson(Map<String, Object?> json) {
    final user = json['user'];
    final permissions = json['permission_codes'];
    if (user is! Map || permissions is! List) {
      throw const FormatException('Invalid member payload');
    }
    final userMap = Map<String, Object?>.from(user);
    // user.id 契约里是 minimum: 1，0 与负数都不是合法账号编号。
    final userId = userMap['id'];
    if (userId is! int || userId < 1) {
      throw const FormatException('Invalid member user id');
    }
    return Member(
      membershipId: json['membership_id'] as int,
      userId: userId,
      username: userMap['username'] as String,
      displayName: userMap['display_name'] as String,
      memberType: json['member_type'] as String,
      status: MemberStatus.fromWireValue(json['status'] as String),
      permissionCodes: <String>{for (final code in permissions) code as String},
      version: json['version'] as int,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is Member &&
      membershipId == other.membershipId &&
      userId == other.userId &&
      username == other.username &&
      displayName == other.displayName &&
      memberType == other.memberType &&
      status == other.status &&
      _setsEqual(permissionCodes, other.permissionCodes) &&
      version == other.version;

  @override
  int get hashCode => Object.hash(
    membershipId,
    userId,
    username,
    displayName,
    memberType,
    status,
    Object.hashAllUnordered(permissionCodes),
    version,
  );
}

final class MemberPermissions {
  const MemberPermissions({
    required this.membershipId,
    required this.permissionCodes,
    required this.version,
  });

  final int membershipId;
  final Set<String> permissionCodes;
  final int version;

  factory MemberPermissions.fromJson(Map<String, Object?> json) {
    final permissions = json['permission_codes'];
    if (permissions is! List) {
      throw const FormatException('Invalid member permissions payload');
    }
    return MemberPermissions(
      membershipId: json['membership_id'] as int,
      permissionCodes: <String>{for (final code in permissions) code as String},
      version: json['version'] as int,
    );
  }
}

/// 成员列表的查询条件（对应契约 `GET /api/v1/groups/members` 的
/// `keyword` / `status` 两个可选 query 参数）。
final class MemberQuery {
  const MemberQuery({this.keyword, this.status});

  /// 用户名 / 显示名关键词，交给服务端做模糊匹配。
  ///
  /// 刻意不做「本地过滤已经拿到的那一页」：那样筛出来的结果取决于翻页位置，
  /// 同一个关键词在第 1 页能搜到、翻到第 2 页就搜不到了 —— 用户完全无法理解。
  final String? keyword;

  final MemberStatus? status;

  /// 是否「不带任何筛选」。
  ///
  /// 这不是写法糖，它在仓储层有实际后果：只有不带筛选的结果才是**权威全量**，
  /// 它能写进本地缓存、也能在断网时被当作兜底读回来；
  /// 带条件的结果只是全量的一个子集，拿它写缓存会让下一次全量查询读出残缺的
  /// 组员表，拿缓存冒充它则会让用户看到一堆不符合筛选条件的成员。
  /// 所以空白关键词（`'   '`）按「没筛」算。
  bool get isUnfiltered {
    final trimmed = keyword?.trim();
    return (trimmed == null || trimmed.isEmpty) && status == null;
  }

  /// 交给 Dio 的查询参数（不含分页，页码由数据源自己控制）。
  ///
  /// 可选字段一律「有才带」：显式传 `status: null` 会被序列化成空串，
  /// 服务端按非法枚举拒绝，于是「不筛状态」反而报 400。
  Map<String, Object?> toQueryParameters() {
    final trimmed = keyword?.trim();
    return <String, Object?>{
      if (trimmed != null && trimmed.isNotEmpty) 'keyword': trimmed,
      'status': ?status?.wireValue,
    };
  }

  @override
  bool operator ==(Object other) =>
      other is MemberQuery &&
      keyword?.trim() == other.keyword?.trim() &&
      status == other.status;

  @override
  int get hashCode => Object.hash(keyword?.trim(), status);
}

/// 后端认可的固定权限目录里的一项（契约 `PermissionCatalogItem`）。
///
/// 权限码必须由服务端给出，客户端**不能**自己维护一份：
/// 本地写死的清单会在后端新增权限码之后变成「少了一项」，
/// 用户把成员权限整体替换时就会顺手把新权限清掉。
final class PermissionCatalogItem {
  const PermissionCatalogItem({
    required this.code,
    required this.name,
    required this.description,
  });

  /// 权限码，如 `document.view_others`。
  final String code;

  /// 权限的短名称，列表上显示。
  final String name;

  /// 权限的说明，用来解释「勾上之后这个人能做什么」。
  final String description;

  factory PermissionCatalogItem.fromJson(Map<String, Object?> json) {
    final code = json['code'];
    final name = json['name'];
    final description = json['description'];
    if (code is! String || name is! String || description is! String) {
      throw const FormatException('Invalid permission catalog item');
    }
    return PermissionCatalogItem(
      code: code,
      name: name,
      description: description,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is PermissionCatalogItem &&
      code == other.code &&
      name == other.name &&
      description == other.description;

  @override
  int get hashCode => Object.hash(code, name, description);

  @override
  String toString() => 'PermissionCatalogItem(code: $code, name: $name)';
}

bool _setsEqual(Set<String> left, Set<String> right) =>
    left.length == right.length && left.containsAll(right);
