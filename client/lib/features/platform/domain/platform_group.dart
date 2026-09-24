/// 业务组（租户）的启用状态。
///
/// 与 OpenAPI 的 `GroupStatus` 一一对应：`active` 可正常使用，`disabled` 被平台
/// 停用（组内会话会被一并撤销）。用枚举而不是裸 String，是为了让「拼错状态名」
/// 在解析阶段就暴露成 [FormatException]，而不是等到界面渲染时静默显示成未知态。
enum GroupStatus {
  active('active'),
  disabled('disabled');

  const GroupStatus(this.wireValue);

  /// 与契约一致的线上取值。
  final String wireValue;

  /// 由线上取值反查枚举，未知取值直接抛错。
  static GroupStatus fromWireValue(String value) => values.firstWhere(
    (status) => status.wireValue == value,
    orElse: () => throw FormatException('Unknown group status: $value'),
  );
}

/// 交接主账号的两种模式。
///
/// 对应 `ChangeGroupOwnerRequest.mode`：把组内既有成员提升为主账号，或者新建
/// 一个账号再设为主账号。两种模式要求的字段**互斥**，服务端只认其中一组。
enum OwnerChangeMode {
  existingMember('existing_member'),
  newAccount('new_account');

  const OwnerChangeMode(this.wireValue);

  final String wireValue;
}

/// 平台侧看到的用户摘要（`UserSummary`）。
///
/// 刻意只保留 id / 用户名 / 显示名三个字段：合约里还有一个 `account_type`，
/// 但在「组的主账号」「可提升的候选人」这两个位置上它恒为 `group_owner` 或
/// `member`，落到客户端只是冗余状态；少解析一个字段就少一处可能与服务端
/// 不一致的地方。真需要账号类型时应当另建一个带它的类型，而不是在这里放可空值。
final class PlatformOwner {
  const PlatformOwner({
    required this.id,
    required this.username,
    required this.displayName,
  });

  final int id;
  final String username;
  final String displayName;

  factory PlatformOwner.fromJson(Map<String, Object?> json) => PlatformOwner(
    id: _readInt(json, 'id'),
    username: _readString(json, 'username'),
    displayName: _readString(json, 'display_name'),
  );

  @override
  bool operator ==(Object other) =>
      other is PlatformOwner &&
      id == other.id &&
      username == other.username &&
      displayName == other.displayName;

  @override
  int get hashCode => Object.hash(id, username, displayName);

  @override
  String toString() =>
      'PlatformOwner(id: $id, username: $username, displayName: $displayName)';
}

/// 组的平台摘要（`GroupSummaryData`）。
///
/// [version] 是乐观锁凭据：启停与交接都必须把它原样回传，服务端据此判断
/// 「你看到的还是不是最新那一版」。所以它必须一路从列表带到详情、再带回写请求，
/// 中途不能丢，也不能自己加一。
final class PlatformGroup {
  const PlatformGroup({
    required this.id,
    required this.name,
    required this.status,
    required this.owner,
    required this.memberCount,
    required this.version,
    required this.createdAt,
    required this.updatedAt,
  });

  final int id;
  final String name;
  final GroupStatus status;
  final PlatformOwner owner;

  /// 该组成员总数（服务端聚合，含停用成员，口径由后端决定）。
  final int memberCount;

  /// 乐观锁版本号，写操作必须原样回传。
  final int version;

  final DateTime createdAt;
  final DateTime updatedAt;

  factory PlatformGroup.fromJson(Map<String, Object?> json) => PlatformGroup(
    id: _readInt(json, 'id'),
    name: _readString(json, 'name'),
    status: GroupStatus.fromWireValue(_readString(json, 'status')),
    owner: PlatformOwner.fromJson(_readObject(json, 'owner')),
    memberCount: _readInt(json, 'member_count'),
    version: _readInt(json, 'version'),
    createdAt: _readDate(json, 'created_at'),
    updatedAt: _readDate(json, 'updated_at'),
  );

  @override
  bool operator ==(Object other) =>
      other is PlatformGroup &&
      id == other.id &&
      name == other.name &&
      status == other.status &&
      owner == other.owner &&
      memberCount == other.memberCount &&
      version == other.version &&
      createdAt == other.createdAt &&
      updatedAt == other.updatedAt;

  @override
  int get hashCode => Object.hash(
    id,
    name,
    status,
    owner,
    memberCount,
    version,
    createdAt,
    updatedAt,
  );
}

/// 按成员状态聚合的人数（`GroupDetailData.member_counts`）。
///
/// 三个键都是**必填**的。契约把 `member_counts` 描述成松散 map（只要值是整数），
/// 但这里的解析偏严：缺键时宁可解析失败，也不退化成 0 —— 一个「活跃成员 0 人」
/// 的假数字会让人以为组被清空了，而真相可能只是服务端换了字段名。
/// Go 侧用 `map[string]int` 序列化时零值键不会消失，所以严格假设是成立的。
final class GroupMemberCounts {
  const GroupMemberCounts({
    required this.active,
    required this.disabled,
    required this.removed,
  });

  final int active;
  final int disabled;
  final int removed;

  factory GroupMemberCounts.fromJson(Map<String, Object?> json) =>
      GroupMemberCounts(
        active: _readNonNegative(json, 'active'),
        disabled: _readNonNegative(json, 'disabled'),
        removed: _readNonNegative(json, 'removed'),
      );

  @override
  bool operator ==(Object other) =>
      other is GroupMemberCounts &&
      active == other.active &&
      disabled == other.disabled &&
      removed == other.removed;

  @override
  int get hashCode => Object.hash(active, disabled, removed);
}

/// 可以被提升为主账号的现有成员（`OwnerCandidateData`）。
///
/// 用 [membershipId] 而不是用户 id 来指向目标：一个用户在不同组里是不同的
/// 「成员关系」，交接是针对关系的操作。服务端只接受 active 成员作为候选。
final class OwnerCandidate {
  const OwnerCandidate({required this.membershipId, required this.user});

  final int membershipId;
  final PlatformOwner user;

  factory OwnerCandidate.fromJson(Map<String, Object?> json) => OwnerCandidate(
    membershipId: _readInt(json, 'membership_id'),
    user: PlatformOwner.fromJson(_readObject(json, 'user')),
  );

  @override
  bool operator ==(Object other) =>
      other is OwnerCandidate &&
      membershipId == other.membershipId &&
      user == other.user;

  @override
  int get hashCode => Object.hash(membershipId, user);
}

/// 组治理详情（`GroupDetailData`）：摘要 + 成员聚合 + 可提升候选人。
final class PlatformGroupDetail {
  const PlatformGroupDetail({
    required this.group,
    required this.memberCounts,
    required this.ownerCandidates,
  });

  final PlatformGroup group;
  final GroupMemberCounts memberCounts;
  final List<OwnerCandidate> ownerCandidates;

  factory PlatformGroupDetail.fromJson(Map<String, Object?> json) =>
      PlatformGroupDetail(
        group: PlatformGroup.fromJson(_readObject(json, 'group')),
        memberCounts: GroupMemberCounts.fromJson(
          _readObject(json, 'member_counts'),
        ),
        ownerCandidates: List<OwnerCandidate>.unmodifiable(<OwnerCandidate>[
          for (final candidate in _readObjectList(json, 'owner_candidates'))
            OwnerCandidate.fromJson(candidate),
        ]),
      );

  @override
  bool operator ==(Object other) =>
      other is PlatformGroupDetail &&
      group == other.group &&
      memberCounts == other.memberCounts &&
      _sameList(ownerCandidates, other.ownerCandidates);

  @override
  int get hashCode =>
      Object.hash(group, memberCounts, Object.hashAll(ownerCandidates));
}

/// 平台组列表的查询条件。
///
/// [page] / [pageSize] 有默认值，构造时不传即为「第一页、每页 20 条」，
/// 与契约里 `page=1`、`page_size=20` 的默认值一致。
/// 实现 `==` 是为了让控制器能判断「这次请求的条件和上次是不是同一套」，
/// 避免用户反复点同一个筛选条件时白白重发请求。
final class PlatformGroupQuery {
  const PlatformGroupQuery({
    this.keyword,
    this.status,
    this.page = 1,
    this.pageSize = 20,
  });

  /// 按组名模糊匹配；null 或空串都表示不筛。
  final String? keyword;

  /// 按状态筛选；null 表示全部。
  final GroupStatus? status;

  final int page;
  final int pageSize;

  @override
  bool operator ==(Object other) =>
      other is PlatformGroupQuery &&
      keyword == other.keyword &&
      status == other.status &&
      page == other.page &&
      pageSize == other.pageSize;

  @override
  int get hashCode => Object.hash(keyword, status, page, pageSize);
}

/// 创建组（连同主账号）的入参（`CreateGroupRequest`）。
///
/// 初始密码是**必填**的：平台管理员创建组时必须当场给出，服务端不会代生成 ——
/// 所以界面有责任提示「请把这串密码安全地交给主账号本人」。
final class CreateGroupDraft {
  const CreateGroupDraft({
    required this.name,
    required this.ownerUsername,
    required this.ownerDisplayName,
    required this.ownerTemporaryPassword,
  });

  final String name;
  final String ownerUsername;
  final String ownerDisplayName;
  final String ownerTemporaryPassword;
}

/// 创建成功的结果（`GroupCreatedData`）。
///
/// 这里只留组 id、组名与主账号：创建响应的 `group` 是精简的 `GroupSummary`
/// （只有 id 和 name），没有 version、时间戳这些字段，硬凑成 [PlatformGroup]
/// 只会造出一堆假默认值。调用方拿到 [groupId] 后去详情页读完整数据即可。
final class CreateGroupResult {
  const CreateGroupResult({
    required this.groupId,
    required this.groupName,
    required this.owner,
  });

  final int groupId;
  final String groupName;
  final PlatformOwner owner;

  factory CreateGroupResult.fromJson(Map<String, Object?> json) {
    final group = _readObject(json, 'group');
    return CreateGroupResult(
      groupId: _readInt(group, 'id'),
      groupName: _readString(group, 'name'),
      owner: PlatformOwner.fromJson(_readObject(json, 'owner')),
    );
  }
}

/// 主账号交接的入参。
///
/// 用 sealed 类而不是「一个大对象 + 一堆可空字段」，是为了让两种模式在类型层面
/// 就互斥：请求体的拼装处用 `switch` 穷尽匹配（新增模式会直接编译报错），
/// 从根上杜绝「顺手把 membership_id 和 username 一起发出去」这种自相矛盾的请求。
sealed class OwnerChangeDraft {
  const OwnerChangeDraft({required this.version});

  /// 组版本号，乐观锁凭据，必须原样回传。
  final int version;

  /// 本模式对应的线上取值。
  OwnerChangeMode get mode;
}

/// 把组内既有成员提升为主账号。
final class ExistingMemberOwnerDraft extends OwnerChangeDraft {
  const ExistingMemberOwnerDraft({
    required this.membershipId,
    required super.version,
  });

  /// 目标成员的关系 ID，取自 [OwnerCandidate.membershipId]。
  final int membershipId;

  @override
  OwnerChangeMode get mode => OwnerChangeMode.existingMember;
}

/// 新建账号并设为主账号。
final class NewAccountOwnerDraft extends OwnerChangeDraft {
  const NewAccountOwnerDraft({
    required this.username,
    required this.displayName,
    required this.temporaryPassword,
    required super.version,
  });

  final String username;
  final String displayName;
  final String temporaryPassword;

  @override
  OwnerChangeMode get mode => OwnerChangeMode.newAccount;
}

/* --------------------------------------------------------- 严格解析辅助 */

/// 取出一个必填的对象字段。
Map<String, Object?> _readObject(Map<String, Object?> json, String key) =>
    _asObject(json[key], key);

/// 取出一个必填的「对象数组」字段。
List<Map<String, Object?>> _readObjectList(
  Map<String, Object?> json,
  String key,
) {
  final value = json[key];
  if (value is! List) {
    throw FormatException('Field "$key" must be an array');
  }
  return <Map<String, Object?>>[for (final item in value) _asObject(item, key)];
}

/// 取出一个必填的整数字段。
int _readInt(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! int) {
    throw FormatException('Field "$key" must be an integer');
  }
  return value;
}

/// 取出一个必填的、不允许为负的整数字段。
///
/// 用在人数聚合上：契约给 `member_counts` 的每个值都标了 `minimum: 0`，
/// 出现负数说明服务端聚合写错了，让它直接失败比在界面上显示「-1 人」强。
int _readNonNegative(Map<String, Object?> json, String key) {
  final value = _readInt(json, key);
  if (value < 0) {
    throw FormatException('Field "$key" must not be negative');
  }
  return value;
}

/// 取出一个必填的字符串字段。
String _readString(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! String) {
    throw FormatException('Field "$key" must be a string');
  }
  return value;
}

/// 取出一个必填的 ISO-8601 时间字段，统一转成 UTC。
///
/// 转 UTC 而不是保留服务端时区：界面按用户本地时区展示是展示层的事，
/// 领域对象里留一个带偏移量的时间，会让「两个时间是否相等」的判断变得不可靠。
DateTime _readDate(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! String) {
    throw FormatException('Field "$key" must be an ISO-8601 string');
  }
  return DateTime.parse(value).toUtc();
}

Map<String, Object?> _asObject(Object? value, String key) {
  if (value is! Map) {
    throw FormatException('Field "$key" must be an object');
  }
  return Map<String, Object?>.from(value);
}

/// 逐项比较两个列表的内容（元素需可相等比较）。
bool _sameList<T>(List<T> left, List<T> right) {
  if (identical(left, right)) return true;
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index++) {
    if (left[index] != right[index]) return false;
  }
  return true;
}
