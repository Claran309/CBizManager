import 'package:c_biz_docs_manager/app/app.dart';
import 'package:c_biz_docs_manager/app/router.dart';
import 'package:c_biz_docs_manager/app/session_scope.dart';
import 'package:c_biz_docs_manager/core/auth/auth_controller.dart';
import 'package:c_biz_docs_manager/core/auth/auth_models.dart';
import 'package:c_biz_docs_manager/core/auth/auth_repository.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
// `Override` 在 Riverpod 3 里由 misc.dart 导出，主入口只给常用的那一组。
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import '../support/auth_fixtures.dart';

/// 只关心会话本身的路由守卫替身；注册与改密不属于本文件的关注点。
final class StaticAuthRepository implements AuthRepository {
  const StaticAuthRepository(this._session);

  /// 恢复会话时必然失败，用来进入未登录态。
  const StaticAuthRepository.signedOut() : _session = null;

  final AuthSession? _session;

  AuthSession get _requiredSession {
    final session = _session;
    if (session == null) {
      throw StateError('本替身没有可用会话');
    }
    return session;
  }

  @override
  Future<AuthSession> login(String username, String password) async =>
      _requiredSession;

  @override
  Future<void> logout() async {}

  @override
  Future<AuthSession> restore() async => _requiredSession;

  @override
  Future<RegistrationResult> register(RegistrationDraft draft) =>
      throw UnsupportedError('路由守卫测试不覆盖注册');

  @override
  Future<AuthSession> changePassword(
    String currentPassword,
    String newPassword,
  ) => throw UnsupportedError('路由守卫测试不覆盖改密');
}

/// 路由表里全部稳定地址，用于「无权地址回到角色首页且不成环」的遍历验证。
const _allLocations = <String>[
  '/splash',
  '/login',
  '/register',
  '/change-password',
  '/platform/groups',
  '/platform/groups/new',
  '/platform/groups/42',
  '/home',
  '/invitations',
  '/members',
  '/members/7/permissions',
  '/dictionaries',
];

void main() {
  /* ------------------------------------------------------ 基础转换行为 */

  test('restoring state stays on splash without redirect loops', () {
    const state = AuthState(AuthPhase.restoring);

    expect(authRedirect(state, '/home'), '/splash');
    expect(authRedirect(state, '/splash'), isNull);
  });

  test('unauthenticated routes stay on login and protect app pages', () {
    const state = AuthState(AuthPhase.unauthenticated);

    expect(authRedirect(state, '/home'), '/login');
    expect(authRedirect(state, '/login'), isNull);
  });

  test('password change is mandatory before authenticated app routes', () {
    final state = AuthState(
      AuthPhase.authenticated,
      session: ownerSession(mustChangePassword: true),
    );

    expect(authRedirect(state, '/home'), '/change-password');
    expect(authRedirect(state, '/change-password'), isNull);
  });

  test('normal authentication enters home and leaves home stable', () {
    final state = AuthState(AuthPhase.authenticated, session: ownerSession());

    expect(authRedirect(state, '/login'), '/home');
    expect(authRedirect(state, '/home'), isNull);
  });

  /* -------------------------------------------------------- 守卫矩阵表 */

  group('多角色守卫矩阵', () {
    const restoring = AuthState(AuthPhase.restoring);
    const signedOut = AuthState(AuthPhase.unauthenticated);
    final forcedOwner = AuthState(
      AuthPhase.authenticated,
      session: ownerSession(mustChangePassword: true),
    );
    final admin = AuthState(
      AuthPhase.authenticated,
      session: platformAdminSession(),
    );
    final owner = AuthState(AuthPhase.authenticated, session: ownerSession());
    final member = AuthState(AuthPhase.authenticated, session: memberSession());
    final managingMember = AuthState(
      AuthPhase.authenticated,
      session: memberSession(permissionCodes: const <String>['member.manage']),
    );

    final cases =
        <({String name, AuthState auth, String location, String? redirect})>[
          // 1. 会话恢复中只认 splash。
          (
            name: 'restoring 访问登录页被送去 splash',
            auth: restoring,
            location: '/login',
            redirect: '/splash',
          ),
          (
            name: 'restoring 停留在 splash',
            auth: restoring,
            location: '/splash',
            redirect: null,
          ),
          // 2. 未登录只允许 login / register。
          (
            name: '未登录可以停在注册页',
            auth: signedOut,
            location: '/register',
            redirect: null,
          ),
          (
            name: '未登录可以停在登录页',
            auth: signedOut,
            location: '/login',
            redirect: null,
          ),
          (
            name: '未登录访问成员页被送去登录页',
            auth: signedOut,
            location: '/members',
            redirect: '/login',
          ),
          (
            name: '未登录访问平台页被送去登录页',
            auth: signedOut,
            location: '/platform/groups',
            redirect: '/login',
          ),
          // 3. 强制改密优先于角色分域。
          (
            name: '待改密的 owner 访问成员页被送去改密页',
            auth: forcedOwner,
            location: '/members',
            redirect: '/change-password',
          ),
          (
            name: '待改密的 owner 访问平台页也要先改密',
            auth: forcedOwner,
            location: '/platform/groups',
            redirect: '/change-password',
          ),
          // 4. 平台管理员只能进 /platform/*。
          (
            name: '平台管理员访问租户首页被送去平台列表',
            auth: admin,
            location: '/home',
            redirect: '/platform/groups',
          ),
          (
            name: '平台管理员停在平台列表',
            auth: admin,
            location: '/platform/groups',
            redirect: null,
          ),
          (
            name: '平台管理员可以进新建组',
            auth: admin,
            location: '/platform/groups/new',
            redirect: null,
          ),
          (
            name: '平台管理员可以进组详情',
            auth: admin,
            location: '/platform/groups/42',
            redirect: null,
          ),
          (
            name: '平台管理员访问邀请码被送回平台列表',
            auth: admin,
            location: '/invitations',
            redirect: '/platform/groups',
          ),
          // 5. 租户用户不能进 /platform/*。
          (
            name: 'owner 访问平台列表被送回租户首页',
            auth: owner,
            location: '/platform/groups',
            redirect: '/home',
          ),
          (
            name: 'owner 访问平台详情被送回租户首页',
            auth: owner,
            location: '/platform/groups/42',
            redirect: '/home',
          ),
          (
            name: 'owner 访问新建组被送回租户首页',
            auth: owner,
            location: '/platform/groups/new',
            redirect: '/home',
          ),
          // 6. owner 专属地址。
          (
            name: 'owner 可以进邀请码页',
            auth: owner,
            location: '/invitations',
            redirect: null,
          ),
          (
            name: 'owner 可以进权限替换页',
            auth: owner,
            location: '/members/7/permissions',
            redirect: null,
          ),
          (
            name: '普通成员进不了邀请码页',
            auth: member,
            location: '/invitations',
            redirect: '/home',
          ),
          (
            name: '普通成员即使有 member.manage 也进不了权限页',
            auth: managingMember,
            location: '/members/7/permissions',
            redirect: '/home',
          ),
          // 7. 成员管理入口按 member.manage 判定。
          (
            name: 'owner 隐式允许成员页',
            auth: owner,
            location: '/members',
            redirect: null,
          ),
          (
            name: '无 member.manage 的普通成员进不了成员页',
            auth: member,
            location: '/members',
            redirect: '/home',
          ),
          (
            name: '有 member.manage 的普通成员可以进成员页',
            auth: managingMember,
            location: '/members',
            redirect: null,
          ),
          // 8. 已登录不该停在过渡页 / 公开页。
          (
            name: '已登录停在登录页会被送去角色首页',
            auth: owner,
            location: '/login',
            redirect: '/home',
          ),
          (
            name: '已登录停在 splash 会被送去角色首页',
            auth: owner,
            location: '/splash',
            redirect: '/home',
          ),
          (
            name: '已登录停在注册页会被送去角色首页',
            auth: member,
            location: '/register',
            redirect: '/home',
          ),
          (
            name: '已登录停在改密页（不需要改密）会被送去角色首页',
            auth: owner,
            location: '/change-password',
            redirect: '/home',
          ),
          // 共同可达页：字典对租户只读开放，但仍需登录。
          (
            name: 'owner 可以进字典页',
            auth: owner,
            location: '/dictionaries',
            redirect: null,
          ),
          (
            name: '普通成员可以进字典页',
            auth: member,
            location: '/dictionaries',
            redirect: null,
          ),
          (
            name: '未登录进不了字典页',
            auth: signedOut,
            location: '/dictionaries',
            redirect: '/login',
          ),
        ];

    for (final testCase in cases) {
      test(testCase.name, () {
        expect(
          authRedirect(testCase.auth, testCase.location),
          testCase.redirect,
        );
      });
    }
  });

  /* -------------------------------------------------- 循环与落点安全性 */

  test('无权地址一律回角色首页，且任何状态都不会形成 redirect 循环', () {
    final states = <String, AuthState>{
      'restoring': const AuthState(AuthPhase.restoring),
      'signedOut': const AuthState(AuthPhase.unauthenticated),
      '待改密 owner': AuthState(
        AuthPhase.authenticated,
        session: ownerSession(mustChangePassword: true),
      ),
      '平台管理员': AuthState(
        AuthPhase.authenticated,
        session: platformAdminSession(),
      ),
      'owner': AuthState(AuthPhase.authenticated, session: ownerSession()),
      'member': AuthState(AuthPhase.authenticated, session: memberSession()),
      'member+manage': AuthState(
        AuthPhase.authenticated,
        session: memberSession(
          permissionCodes: const <String>['member.manage'],
        ),
      ),
    };

    for (final entry in states.entries) {
      for (final location in _allLocations) {
        // 反复应用 redirect，直到到达固定点。真实路由最多跳一次，
        // 这里留 3 跳余量：一旦某个状态和某个地址互相指着转，
        // 就说明守卫写成了环，必须在用例里炸出来而不是等到线上白屏。
        var current = location;
        var hops = 0;
        while (true) {
          final next = authRedirect(entry.value, current);
          if (next == null) break;
          current = next;
          hops++;
          expect(
            hops,
            lessThan(4),
            reason: '${entry.key} 访问 $location 时进入了重定向循环（当前停在 $current）',
          );
        }

        // 固定点本身必须是稳定的：再算一次不该又被踢走。
        expect(
          authRedirect(entry.value, current),
          isNull,
          reason: '${entry.key} 在 $current 上仍会被重定向',
        );

        // 并按设计规格校验落点确实属于该角色：平台管理员只能落在平台区，
        // 租户用户只能落在租户区。这正是"无权地址统一回角色首页"的实质。
        if (entry.value.phase == AuthPhase.restoring) {
          // 会话还没恢复完，splash 是它唯一的合法落点。
          expect(current, '/splash');
          continue;
        }
        final session = entry.value.session;
        if (session == null) {
          expect(
            isPublicLocation(current),
            isTrue,
            reason: '未登录落点 $current 不是公开页',
          );
          continue;
        }
        if (session.profile.mustChangePassword) {
          expect(current, '/change-password');
          continue;
        }
        if (session.profile.accountType == AccountType.platformAdmin) {
          expect(
            isPlatformLocation(current),
            isTrue,
            reason: '平台管理员落点 $current 越界',
          );
        } else {
          expect(
            isPlatformLocation(current),
            isFalse,
            reason: '租户用户落点 $current 越界',
          );
        }
      }
    }
  });

  /* -------------------------------------------------------- 路由表注册 */

  test('路由表注册了全部稳定地址，且字面量路由排在参数路由之前', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final routes = container
        .read(routerProvider)
        .configuration
        .routes
        .whereType<GoRoute>()
        .toList();
    final paths = <String>[for (final route in routes) route.path];

    expect(
      paths,
      containsAll(<String>[
        '/splash',
        '/login',
        '/register',
        '/change-password',
        '/platform/groups',
        '/platform/groups/new',
        '/platform/groups/:groupId',
        '/home',
        '/invitations',
        '/members',
        '/members/:membershipId/permissions',
        '/dictionaries',
      ]),
    );
    // `/platform/groups/new` 会被 `/platform/groups/:groupId` 一并匹配，
    // 声明顺序决定了谁先命中——顺序错了「新建组」就会变成 groupId='new' 的详情页。
    expect(
      paths.indexOf('/platform/groups/new'),
      lessThan(paths.indexOf('/platform/groups/:groupId')),
    );
  });

  /* ------------------------------------------------------ 真实路由器闭环 */

  group('真实 GoRouter 闭环', () {
    Future<ProviderContainer> pumpApp(
      WidgetTester tester,
      AuthRepository repository,
    ) async {
      final container = ProviderContainer(
        overrides: <Override>[
          // 应用外壳在已登录态会建立会话作用域，作用域需要应用级 Dio。
          dioProvider.overrideWithValue(
            Dio(BaseOptions(baseUrl: 'https://api.example.test')),
          ),
          authRepositoryProvider.overrideWithValue(repository),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const CBizDocsApp(),
        ),
      );
      await tester.pumpAndSettle();
      return container;
    }

    testWidgets('application restore drives the real router to home', (
      WidgetTester tester,
    ) async {
      await pumpApp(tester, StaticAuthRepository(ownerSession()));

      expect(find.text('首页'), findsOneWidget);
    });

    testWidgets('未登录打开受保护地址会被真实路由器拦回登录页', (WidgetTester tester) async {
      final container = await pumpApp(
        tester,
        const StaticAuthRepository.signedOut(),
      );

      expect(find.text('登录'), findsOneWidget);

      container.read(routerProvider).go('/members');
      await tester.pumpAndSettle();

      expect(find.text('登录'), findsOneWidget);
    });

    testWidgets('平台管理员打开租户地址会被真实路由器送回平台列表', (WidgetTester tester) async {
      final container = await pumpApp(
        tester,
        StaticAuthRepository(platformAdminSession()),
      );

      expect(find.text('平台组管理'), findsOneWidget);

      container.read(routerProvider).go('/home');
      await tester.pumpAndSettle();

      expect(find.text('平台组管理'), findsOneWidget);
    });

    testWidgets('owner 打开平台地址会被真实路由器送回租户首页', (WidgetTester tester) async {
      final container = await pumpApp(
        tester,
        StaticAuthRepository(ownerSession()),
      );

      container.read(routerProvider).go('/platform/groups');
      await tester.pumpAndSettle();

      expect(find.text('首页'), findsOneWidget);
    });

    testWidgets('普通成员打开成员页会被真实路由器送回租户首页', (WidgetTester tester) async {
      final container = await pumpApp(
        tester,
        StaticAuthRepository(memberSession()),
      );

      container.read(routerProvider).go('/members');
      await tester.pumpAndSettle();

      expect(find.text('首页'), findsOneWidget);
    });
  });
}
