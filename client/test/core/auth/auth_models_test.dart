import 'package:c_biz_docs_manager/core/auth/auth_models.dart';
import 'package:flutter_test/flutter_test.dart';

/// 构造一份与服务端 `MeData` 契约同构的最小载荷。
///
/// 契约（api/openapi/cbizdocsmanager-v1.yaml → MeData）：
/// required: [user, group, member_type, must_change_password, permission_codes]
/// user  → UserSummary {id, username, display_name, account_type}
/// group → GroupSummary {id, name} | null
Map<String, Object?> mePayload({
  Object? user = const <String, Object?>{
    'id': 11,
    'username': 'owner',
    'display_name': 'Owner',
    'account_type': 'group_owner',
  },
  Object? group = const <String, Object?>{'id': 7, 'name': 'Finance'},
  Object? memberType = 'owner',
  Object? mustChangePassword = false,
  Object? permissionCodes = const <Object?>[],
}) => <String, Object?>{
  'user': user,
  'group': group,
  'member_type': memberType,
  'must_change_password': mustChangePassword,
  'permission_codes': permissionCodes,
};

void main() {
  group('AuthProfile.fromJson 身份矩阵', () {
    test('platform admin 的 group 与 memberType 都为 null', () {
      final profile = AuthProfile.fromJson(
        mePayload(
          user: const <String, Object?>{
            'id': 1,
            'username': 'admin',
            'display_name': '平台管理员',
            'account_type': 'platform_admin',
          },
          group: null,
          memberType: null,
          mustChangePassword: false,
        ),
      );

      expect(profile.accountType, AccountType.platformAdmin);
      expect(profile.group, isNull);
      expect(profile.memberType, isNull);
      expect(profile.hasPermission('member.manage'), isFalse);
    });

    test('groupOwner 带 group 且 member_type=owner（不读 JWT 声明）', () {
      final profile = AuthProfile.fromJson(mePayload());

      expect(profile.accountType, AccountType.groupOwner);
      expect(profile.group?.id, 7);
      expect(profile.group?.name, 'Finance');
      expect(profile.memberType, MemberType.owner);
      expect(profile.user.id, 11);
      expect(profile.user.username, 'owner');
      expect(profile.user.displayName, 'Owner');
      expect(profile.mustChangePassword, isFalse);
    });

    test('member 带 group 且 member_type=member', () {
      final profile = AuthProfile.fromJson(
        mePayload(
          user: const <String, Object?>{
            'id': 22,
            'username': 'sales',
            'display_name': '业务员',
            'account_type': 'member',
          },
          memberType: 'member',
          permissionCodes: const <Object?>['document.view_others'],
        ),
      );

      expect(profile.accountType, AccountType.member);
      expect(profile.memberType, MemberType.member);
      expect(profile.permissionCodes, <String>{'document.view_others'});
    });

    test('未知 account_type 抛 FormatException', () {
      expect(
        () => AuthProfile.fromJson(
          mePayload(
            user: const <String, Object?>{
              'id': 1,
              'username': 'ghost',
              'display_name': 'Ghost',
              'account_type': 'super_admin',
            },
          ),
        ),
        throwsA(isA<FormatException>()),
      );
    });

    test('未知 member_type 抛 FormatException', () {
      expect(
        () => AuthProfile.fromJson(mePayload(memberType: 'manager')),
        throwsA(isA<FormatException>()),
      );
    });

    test('租户身份缺 group 抛 FormatException', () {
      expect(
        () => AuthProfile.fromJson(mePayload(group: null)),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => AuthProfile.fromJson(
          mePayload(
            user: const <String, Object?>{
              'id': 22,
              'username': 'sales',
              'display_name': '业务员',
              'account_type': 'member',
            },
            group: null,
            memberType: 'member',
          ),
        ),
        throwsA(isA<FormatException>()),
      );
    });

    test('groupOwner 的 member_type 不是 owner 抛 FormatException', () {
      expect(
        () => AuthProfile.fromJson(mePayload(memberType: 'member')),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => AuthProfile.fromJson(mePayload(memberType: null)),
        throwsA(isA<FormatException>()),
      );
    });

    test('member 的 member_type 不是 member 抛 FormatException', () {
      expect(
        () => AuthProfile.fromJson(
          mePayload(
            user: const <String, Object?>{
              'id': 22,
              'username': 'sales',
              'display_name': '业务员',
              'account_type': 'member',
            },
            memberType: 'owner',
          ),
        ),
        throwsA(isA<FormatException>()),
      );
    });

    test('platform admin 携带 group 抛 FormatException', () {
      expect(
        () => AuthProfile.fromJson(
          mePayload(
            user: const <String, Object?>{
              'id': 1,
              'username': 'admin',
              'display_name': '平台管理员',
              'account_type': 'platform_admin',
            },
            memberType: null,
          ),
        ),
        throwsA(isA<FormatException>()),
      );
    });

    test('permission_codes 含非字符串元素抛 FormatException', () {
      expect(
        () => AuthProfile.fromJson(mePayload(permissionCodes: const <Object?>[7])),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => AuthProfile.fromJson(mePayload(permissionCodes: 'member.manage')),
        throwsA(isA<FormatException>()),
      );
    });

    test('重复的 permission_codes 折叠为集合', () {
      final profile = AuthProfile.fromJson(
        mePayload(
          permissionCodes: const <Object?>[
            'member.manage',
            'member.manage',
            'dictionary.manage',
          ],
        ),
      );

      expect(profile.permissionCodes, <String>{
        'member.manage',
        'dictionary.manage',
      });
    });

    test('缺少 must_change_password 抛 FormatException', () {
      final payload = mePayload()..remove('must_change_password');
      expect(
        () => AuthProfile.fromJson(payload),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => AuthProfile.fromJson(mePayload(mustChangePassword: 'false')),
        throwsA(isA<FormatException>()),
      );
    });

    test('缺少 permission_codes 抛 FormatException', () {
      final payload = mePayload()..remove('permission_codes');
      expect(
        () => AuthProfile.fromJson(payload),
        throwsA(isA<FormatException>()),
      );
    });

    test('user 缺必填字段抛 FormatException', () {
      expect(
        () => AuthProfile.fromJson(
          mePayload(
            user: const <String, Object?>{
              'id': 11,
              'username': 'owner',
              'display_name': 'Owner',
            },
          ),
        ),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => AuthProfile.fromJson(
          mePayload(
            user: const <String, Object?>{
              'username': 'owner',
              'display_name': 'Owner',
              'account_type': 'group_owner',
            },
          ),
        ),
        throwsA(isA<FormatException>()),
      );
    });

    test('group 缺必填字段抛 FormatException', () {
      expect(
        () => AuthProfile.fromJson(
          mePayload(group: const <String, Object?>{'id': 7}),
        ),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('AuthProfile.hasPermission', () {
    test('主账号隐式持有全部权限', () {
      final profile = AuthProfile.fromJson(mePayload());

      expect(profile.hasPermission('member.manage'), isTrue);
      expect(profile.hasPermission('settlement.approve'), isTrue);
      expect(profile.hasPermission('未注册的权限码'), isTrue);
    });

    test('业务员只持有被显式授予的权限码', () {
      final profile = AuthProfile.fromJson(
        mePayload(
          user: const <String, Object?>{
            'id': 22,
            'username': 'sales',
            'display_name': '业务员',
            'account_type': 'member',
          },
          memberType: 'member',
          permissionCodes: const <Object?>['finance.record'],
        ),
      );

      expect(profile.hasPermission('finance.record'), isTrue);
      expect(profile.hasPermission('member.manage'), isFalse);
    });

    test('平台管理员不继承组内权限', () {
      final profile = AuthProfile.fromJson(
        mePayload(
          user: const <String, Object?>{
            'id': 1,
            'username': 'admin',
            'display_name': '平台管理员',
            'account_type': 'platform_admin',
          },
          group: null,
          memberType: null,
          permissionCodes: const <Object?>[],
        ),
      );

      expect(profile.hasPermission('member.manage'), isFalse);
    });
  });

  group('AuthSession.scopeKey', () {
    AuthSession sessionFor({
      String username = 'owner',
      int userId = 11,
      String accountType = 'group_owner',
      Object? group = const <String, Object?>{'id': 7, 'name': 'Finance'},
      Object? memberType = 'owner',
      bool mustChangePassword = false,
      List<Object?> permissionCodes = const <Object?>[],
    }) => AuthSession(
      accessToken: 'access',
      profile: AuthProfile.fromJson(
        mePayload(
          user: <String, Object?>{
            'id': userId,
            'username': username,
            'display_name': username,
            'account_type': accountType,
          },
          group: group,
          memberType: memberType,
          mustChangePassword: mustChangePassword,
          permissionCodes: permissionCodes,
        ),
      ),
    );

    test('绑定 user / group / role / 改密态 / 权限集合', () {
      expect(
        sessionFor().scopeKey,
        '11:7:group_owner:owner:false:',
      );
      expect(
        sessionFor(userId: 22, username: 'sales', accountType: 'member', memberType: 'member')
            .scopeKey,
        '22:7:member:member:false:',
      );
      expect(
        sessionFor(username: 'admin', accountType: 'platform_admin', group: null, memberType: null)
            .scopeKey,
        '11:0:platform_admin:-:false:',
      );
    });

    test('权限码排序后参与 key，与输入顺序无关', () {
      final first = sessionFor(
        permissionCodes: const <Object?>['member.manage', 'dictionary.manage'],
      );
      final second = sessionFor(
        permissionCodes: const <Object?>['dictionary.manage', 'member.manage'],
      );

      expect(first.scopeKey, second.scopeKey);
      expect(first.scopeKey, endsWith('dictionary.manage,member.manage'));
    });

    test('改密态变化会改变 key，触发会话级重建', () {
      expect(
        sessionFor(mustChangePassword: true).scopeKey,
        isNot(sessionFor(mustChangePassword: false).scopeKey),
      );
    });

    test('从 profile 透出 mustChangePassword，供路由守卫直接读取', () {
      expect(sessionFor(mustChangePassword: true).mustChangePassword, isTrue);
      expect(sessionFor().mustChangePassword, isFalse);
    });
  });
}
