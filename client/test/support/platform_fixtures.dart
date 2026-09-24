/// 平台治理相关的测试夹具。
///
/// 与 `auth_fixtures.dart` 同一个思路：这里的 JSON 严格照抄 OpenAPI 的
/// schema 字段名与嵌套结构。夹具只有一份，领域解析与仓储解析两个测试文件
/// 共用它 —— 契约一旦调整，两边会一起失败，而不是各自留着一份过期的结构。
library;

/// `UserSummary`。
Map<String, Object?> platformOwnerJson({
  Object? id = 11,
  Object? username = 'owner',
  Object? displayName = '张三',
}) => <String, Object?>{
  'id': id,
  'username': username,
  'display_name': displayName,
};

/// `GroupSummaryData`。
Map<String, Object?> platformGroupJson({
  Object? id = 7,
  Object? name = '钢材一组',
  Object? status = 'active',
  Object? owner,
  Object? memberCount = 5,
  Object? version = 3,
  Object? createdAt = '2026-01-02T03:04:05Z',
  Object? updatedAt = '2026-02-03T04:05:06Z',
}) => <String, Object?>{
  'id': id,
  'name': name,
  'status': status,
  'owner': owner ?? platformOwnerJson(),
  'member_count': memberCount,
  'version': version,
  'created_at': createdAt,
  'updated_at': updatedAt,
};

/// `OwnerCandidateData`。
Map<String, Object?> platformCandidateJson({
  Object? membershipId = 9,
  Object? user,
}) => <String, Object?>{
  'membership_id': membershipId,
  'user':
      user ??
      platformOwnerJson(id: 22, username: 'sales', displayName: '李四'),
};

/// `GroupDetailData`。
Map<String, Object?> platformGroupDetailJson({
  Object? group,
  Object? memberCounts,
  Object? ownerCandidates,
}) => <String, Object?>{
  'group': group ?? platformGroupJson(),
  'member_counts':
      memberCounts ??
      const <String, Object?>{'active': 3, 'disabled': 1, 'removed': 0},
  'owner_candidates': ownerCandidates ?? const <Object?>[],
};

/// `GroupCreatedData`：注意 `group` 是精简的 `GroupSummary`（只有 id 与 name）。
Map<String, Object?> platformGroupCreatedJson({
  Object? group,
  Object? owner,
}) => <String, Object?>{
  'group': group ?? const <String, Object?>{'id': 7, 'name': '钢材一组'},
  'owner': owner ?? platformOwnerJson(),
};

/// `OwnerChangedData`：`group` 是完整的 `GroupSummaryData`，但没有成员聚合。
Map<String, Object?> platformOwnerChangedJson({
  Object? group,
  Object? owner,
}) => <String, Object?>{
  'group': group ?? platformGroupJson(),
  'owner':
      owner ?? platformOwnerJson(id: 22, username: 'sales', displayName: '李四'),
};

/// `GroupPageData`。
Map<String, Object?> platformGroupPageJson({
  Object? items,
  Object? page = 1,
  Object? pageSize = 20,
  Object? total = 1,
}) => <String, Object?>{
  'items': items ?? <Object?>[platformGroupJson()],
  'page': page,
  'page_size': pageSize,
  'total': total,
};
