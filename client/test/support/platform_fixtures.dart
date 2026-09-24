/// 平台治理相关的测试夹具。
///
/// 与 `auth_fixtures.dart` 同一个思路：这里的 JSON 严格照抄 OpenAPI 的
/// schema 字段名与嵌套结构。夹具只有一份，领域解析与仓储解析两个测试文件
/// 共用它 —— 契约一旦调整，两边会一起失败，而不是各自留着一份过期的结构。
///
/// 下半部分是按**领域对象**（而非 JSON）构造的夹具，供 Controller 测试使用：
/// 那些用例关心的是状态流转，构造一堆 JSON 再解析只会把注意力从时序上引开。
library;

import 'package:c_biz_docs_manager/core/network/page_result.dart';
import 'package:c_biz_docs_manager/features/platform/domain/platform_group.dart';

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
      user ?? platformOwnerJson(id: 22, username: 'sales', displayName: '李四'),
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
Map<String, Object?> platformGroupCreatedJson({Object? group, Object? owner}) =>
    <String, Object?>{
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

/* ------------------------------------------------- 领域对象夹具（Controller 测试用） */

/// 平台用户摘要。
PlatformOwner domainOwner({
  int id = 11,
  String username = 'owner',
  String displayName = '张三',
}) => PlatformOwner(id: id, username: username, displayName: displayName);

/// 组摘要。改 [version] 模拟「服务端回了一个新版本」。
PlatformGroup domainGroup({
  int id = 7,
  String name = '钢材一组',
  GroupStatus status = GroupStatus.active,
  PlatformOwner? owner,
  int memberCount = 5,
  int version = 3,
}) => PlatformGroup(
  id: id,
  name: name,
  status: status,
  owner: owner ?? domainOwner(),
  memberCount: memberCount,
  version: version,
  createdAt: DateTime.utc(2026, 1, 2, 3, 4, 5),
  updatedAt: DateTime.utc(2026, 2, 3, 4, 5, 6),
);

/// 成员状态聚合。
GroupMemberCounts domainMemberCounts({
  int active = 3,
  int disabled = 1,
  int removed = 0,
}) => GroupMemberCounts(active: active, disabled: disabled, removed: removed);

/// 可提升的候选人。
OwnerCandidate domainCandidate({int membershipId = 9, PlatformOwner? user}) =>
    OwnerCandidate(
      membershipId: membershipId,
      // 候选人一定是组内成员，账号类型不是 group_owner，所以默认名也不同。
      user: user ?? domainOwner(id: 22, username: 'sales', displayName: '李四'),
    );

/// 组治理详情。
PlatformGroupDetail domainDetail({
  PlatformGroup? group,
  GroupMemberCounts? memberCounts,
  List<OwnerCandidate>? ownerCandidates,
}) => PlatformGroupDetail(
  group: group ?? domainGroup(),
  memberCounts: memberCounts ?? domainMemberCounts(),
  ownerCandidates: ownerCandidates ?? <OwnerCandidate>[domainCandidate()],
);

/// 创建成功的结果。
CreateGroupResult domainCreateResult({
  int groupId = 7,
  String groupName = '钢材一组',
  PlatformOwner? owner,
}) => CreateGroupResult(
  groupId: groupId,
  groupName: groupName,
  owner: owner ?? domainOwner(),
);

/// 一页组列表。
PageResult<PlatformGroup> domainGroupPage({
  List<PlatformGroup>? items,
  int page = 1,
  int pageSize = 20,
  int total = 1,
}) => PageResult<PlatformGroup>(
  items: items ?? <PlatformGroup>[domainGroup()],
  page: page,
  pageSize: pageSize,
  total: total,
);
