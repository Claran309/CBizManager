import 'package:c_biz_docs_manager/core/auth/auth_models.dart';

/// 测试用身份夹具。
///
/// 所有夹具都走真实的 [AuthProfile.fromJson]，而不是直接构造对象：
/// 这样它们与服务端 `MeData` 契约始终保持同构 —— 契约一旦调整，
/// 全部用例会一起失败，而不是悄悄用着一份过期的手搓结构。
Map<String, Object?> _mePayload({
  required int userId,
  required String username,
  required String accountType,
  Object? group,
  Object? memberType,
  bool mustChangePassword = false,
  List<String> permissionCodes = const <String>[],
}) => <String, Object?>{
  'user': <String, Object?>{
    'id': userId,
    'username': username,
    'display_name': username,
    'account_type': accountType,
  },
  'group': group,
  'member_type': memberType,
  'must_change_password': mustChangePassword,
  'permission_codes': List<Object?>.from(permissionCodes),
};

/// 组主账号：隐式持有组内全部权限。
AuthProfile ownerProfile({bool mustChangePassword = false}) => AuthProfile.fromJson(
  _mePayload(
    userId: 11,
    username: 'owner',
    accountType: 'group_owner',
    group: const <String, Object?>{'id': 7, 'name': 'Finance'},
    memberType: 'owner',
    mustChangePassword: mustChangePassword,
  ),
);

/// 普通业务员：只持有被显式授予的权限码。
AuthProfile memberProfile({
  bool mustChangePassword = false,
  List<String> permissionCodes = const <String>[],
}) => AuthProfile.fromJson(
  _mePayload(
    userId: 22,
    username: 'sales',
    accountType: 'member',
    group: const <String, Object?>{'id': 7, 'name': 'Finance'},
    memberType: 'member',
    mustChangePassword: mustChangePassword,
    permissionCodes: permissionCodes,
  ),
);

/// 平台管理员：不属于任何组，也不继承组内权限。
AuthProfile platformAdminProfile({bool mustChangePassword = false}) =>
    AuthProfile.fromJson(
      _mePayload(
        userId: 1,
        username: 'admin',
        accountType: 'platform_admin',
        mustChangePassword: mustChangePassword,
      ),
    );

/// 供路由守卫与网络层测试直接使用的会话。
AuthSession ownerSession({
  bool mustChangePassword = false,
  String accessToken = 'access',
}) => AuthSession(
  accessToken: accessToken,
  profile: ownerProfile(mustChangePassword: mustChangePassword),
);
