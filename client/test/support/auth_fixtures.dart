import 'package:c_biz_docs_manager/core/auth/auth_models.dart';

/// 测试用身份夹具。
///
/// 所有夹具都走真实的 [AuthProfile.fromJson]，而不是直接构造对象：
/// 这样它们与服务端 `MeData` 契约始终保持同构 —— 契约一旦调整，
/// 全部用例会一起失败，而不是悄悄用着一份过期的手搓结构。
///
/// 默认值刻意落在同一组（groupId=7）：需要验证跨账号 / 跨组隔离时显式传
/// userId 与 groupId 即可。
Map<String, Object?> _mePayload({
  required int userId,
  required String username,
  required String accountType,
  String? displayName,
  Object? group,
  Object? memberType,
  bool mustChangePassword = false,
  List<String> permissionCodes = const <String>[],
}) => <String, Object?>{
  'user': <String, Object?>{
    'id': userId,
    'username': username,
    // 默认与账号同名，省得每个用例都要写两遍；需要区分「姓名」与「账号」
    // （例如首页把两者分两行显示）时再显式传。
    'display_name': displayName ?? username,
    'account_type': accountType,
  },
  'group': group,
  'member_type': memberType,
  'must_change_password': mustChangePassword,
  'permission_codes': List<Object?>.from(permissionCodes),
};

/// 组主账号：隐式持有组内全部权限。
AuthProfile ownerProfile({
  bool mustChangePassword = false,
  int userId = 11,
  String username = 'owner',
  String? displayName,
  int groupId = 7,
  String groupName = 'Finance',
}) => AuthProfile.fromJson(
  _mePayload(
    userId: userId,
    username: username,
    displayName: displayName,
    accountType: 'group_owner',
    group: <String, Object?>{'id': groupId, 'name': groupName},
    memberType: 'owner',
    mustChangePassword: mustChangePassword,
  ),
);

/// 普通业务员：只持有被显式授予的权限码。
AuthProfile memberProfile({
  bool mustChangePassword = false,
  List<String> permissionCodes = const <String>[],
  int userId = 22,
  String username = 'sales',
  String? displayName,
  int groupId = 7,
  String groupName = 'Finance',
}) => AuthProfile.fromJson(
  _mePayload(
    userId: userId,
    username: username,
    displayName: displayName,
    accountType: 'member',
    group: <String, Object?>{'id': groupId, 'name': groupName},
    memberType: 'member',
    mustChangePassword: mustChangePassword,
    permissionCodes: permissionCodes,
  ),
);

/// 平台管理员：不属于任何组，也不继承组内权限。
AuthProfile platformAdminProfile({
  bool mustChangePassword = false,
  int userId = 1,
  String username = 'admin',
}) => AuthProfile.fromJson(
  _mePayload(
    userId: userId,
    username: username,
    accountType: 'platform_admin',
    mustChangePassword: mustChangePassword,
  ),
);

/// 供路由守卫与网络层测试直接使用的组主账号会话。
AuthSession ownerSession({
  bool mustChangePassword = false,
  String accessToken = 'access',
  int userId = 11,
  String? displayName,
  int groupId = 7,
  String groupName = 'Finance',
}) => AuthSession(
  accessToken: accessToken,
  profile: ownerProfile(
    mustChangePassword: mustChangePassword,
    userId: userId,
    displayName: displayName,
    groupId: groupId,
    groupName: groupName,
  ),
);

/// 业务员会话：验证数据范围、跨账号与跨组隔离时用得上。
AuthSession memberSession({
  bool mustChangePassword = false,
  List<String> permissionCodes = const <String>[],
  String accessToken = 'access',
  int userId = 22,
  String username = 'sales',
  String? displayName,
  int groupId = 7,
  String groupName = 'Finance',
}) => AuthSession(
  accessToken: accessToken,
  profile: memberProfile(
    mustChangePassword: mustChangePassword,
    permissionCodes: permissionCodes,
    userId: userId,
    username: username,
    displayName: displayName,
    groupId: groupId,
    groupName: groupName,
  ),
);

/// 平台管理员会话。
AuthSession platformAdminSession({
  bool mustChangePassword = false,
  String accessToken = 'access',
}) => AuthSession(
  accessToken: accessToken,
  profile: platformAdminProfile(mustChangePassword: mustChangePassword),
);
