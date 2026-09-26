import 'package:c_biz_docs_manager/core/auth/auth_models.dart';
import 'package:c_biz_docs_manager/core/error/app_failure.dart';
import 'package:c_biz_docs_manager/features/home/presentation/tenant_shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/auth_fixtures.dart';
import '../../support/fake_auth_repository.dart';
import '../../support/real_router_harness.dart';

/// 把导航目的地压成路由列表，让断言读起来就是「看到哪几项」。
List<String> _routesOf(AuthProfile? profile) => <String>[
  for (final destination in tenantDestinations(profile)) destination.route,
];

List<String> _labelsOf(AuthProfile? profile) => <String>[
  for (final destination in tenantDestinations(profile)) destination.label,
];

void main() {
  /* -------------------------------------------------------- 导航裁剪 */

  group('租户导航裁剪', () {
    test('组主账号得到 首页 / 入库单 / 出库单 / 结算单 / 报表 / 邀请码 / 成员 / 字典', () {
      expect(_routesOf(ownerProfile()), <String>[
        '/home',
        '/documents/inbound',
        '/documents/outbound',
        '/settlements',
        '/reports',
        '/invitations',
        '/members',
        '/dictionaries',
      ]);
      expect(_labelsOf(ownerProfile()), <String>[
        '首页',
        '入库单',
        '出库单',
        '结算单',
        '报表',
        '邀请码',
        '成员',
        '字典',
      ]);
    });

    test('主账号的权限来自身份，不来自 permission_codes', () {
      // 服务端给主账号下发的 permission_codes 恒为空数组（权限是隐式的），
      // 所以任何「照着这份列表裁剪导航」的写法都会把主账号的管理入口全砍掉。
      final profile = ownerProfile();
      expect(profile.permissionCodes, isEmpty);
      expect(_routesOf(profile), contains('/invitations'));
      expect(_routesOf(profile), contains('/members'));
    });

    test('普通成员只有 首页 / 入库单 / 出库单 / 结算单 / 字典（无报表）', () {
      expect(_routesOf(memberProfile()), <String>[
        '/home',
        '/documents/inbound',
        '/documents/outbound',
        '/settlements',
        '/dictionaries',
      ]);
      // 报表汇总范围是「全组」，默认业务员没有 report.view。
      expect(_routesOf(memberProfile()), isNot(contains('/reports')));
    });

    test('拿到 report.view 的普通成员多一个「报表」', () {
      final routes = _routesOf(
        memberProfile(permissionCodes: const <String>['report.view']),
      );
      expect(routes, contains('/reports'));
    });

    test('拿到 member.manage 的普通成员多一个「成员」，但永远没有「邀请码」', () {
      final routes = _routesOf(
        memberProfile(permissionCodes: const <String>['member.manage']),
      );

      expect(routes, <String>[
        '/home',
        '/documents/inbound',
        '/documents/outbound',
        '/settlements',
        '/members',
        '/dictionaries',
      ]);
      // 邀请码是「谁能进这个组」的凭证，普通成员不该看见入口 ——
      // 即便他手握 member.manage，那也只是管状态，不是管准入。
      expect(routes, isNot(contains('/invitations')));
    });

    test('会话还没建立时一项导航都不给', () {
      // 宁可不显示，也不能凭空猜一个身份：猜成主账号会让一个刚被降权的
      // 账号继续看见管理入口。
      expect(tenantDestinations(null), isEmpty);
    });
  });

  /* --------------------------------------------------------- 首页 */

  group('租户首页', () {
    testWidgets('展示当前账号、归属组、账号类型与权限摘要', (WidgetTester tester) async {
      final repository = FakeAuthRepository(
        session: memberSession(
          username: 'sales',
          displayName: '李四',
          permissionCodes: const <String>['document.view_others'],
        ),
      );
      await pumpRealApp(tester, repository: repository);

      expectTenantHome();
      expect(find.text('李四'), findsOneWidget);
      expect(find.text('sales'), findsOneWidget);
      expect(find.text('Finance'), findsOneWidget);
      expect(find.text('业务员'), findsOneWidget);
      expect(find.text('已授予 1 项权限'), findsOneWidget);
      expect(find.text('document.view_others'), findsOneWidget);
    });

    testWidgets('不展示访问令牌', (WidgetTester tester) async {
      final repository = FakeAuthRepository(
        session: memberSession(accessToken: 'TOKEN-MUST-NOT-RENDER'),
      );
      await pumpRealApp(tester, repository: repository);

      expectTenantHome();
      // 令牌是凭据：截图、投屏、旁人一眼都能拿走它。它只该待在内存里的
      // AccessTokenStore，不该出现在任何 Widget 树里。
      expect(find.text('TOKEN-MUST-NOT-RENDER'), findsNothing);
    });

    testWidgets('主账号看到全部八项导航', (WidgetTester tester) async {
      await pumpRealApp(
        tester,
        repository: FakeAuthRepository(session: ownerSession()),
      );

      expectTenantHome();
      expectDestination('首页', visible: true);
      expectDestination('入库单', visible: true);
      expectDestination('出库单', visible: true);
      expectDestination('结算单', visible: true);
      expectDestination('报表', visible: true);
      expectDestination('邀请码', visible: true);
      expectDestination('成员', visible: true);
      expectDestination('字典', visible: true);
    });

    testWidgets('普通成员看到 首页 / 入库单 / 出库单 / 结算单 / 字典，看不见成员、邀请码与报表', (
      WidgetTester tester,
    ) async {
      await pumpRealApp(
        tester,
        repository: FakeAuthRepository(session: memberSession()),
      );

      expectTenantHome();
      expectDestination('首页', visible: true);
      expectDestination('入库单', visible: true);
      expectDestination('出库单', visible: true);
      expectDestination('结算单', visible: true);
      expectDestination('字典', visible: true);
      expectDestination('成员', visible: false);
      expectDestination('邀请码', visible: false);
      expectDestination('报表', visible: false);
    });

    testWidgets('拿到 member.manage 的普通成员多看到「成员」，仍看不到「邀请码」', (
      WidgetTester tester,
    ) async {
      await pumpRealApp(
        tester,
        repository: FakeAuthRepository(
          session: memberSession(
            permissionCodes: const <String>['member.manage'],
          ),
        ),
      );

      expectTenantHome();
      expectDestination('成员', visible: true);
      expectDestination('邀请码', visible: false);
    });

    testWidgets('主账号的权限摘要说「组内全部权限」，不列空的权限码', (WidgetTester tester) async {
      await pumpRealApp(
        tester,
        repository: FakeAuthRepository(session: ownerSession()),
      );

      expectTenantHome();
      // 照 permission_codes 渲染会得出「没有任何权限」这种与事实相反的画面。
      expect(find.text('组内全部权限'), findsOneWidget);
      expect(find.text('暂无额外权限'), findsNothing);
    });

    testWidgets('没有任何权限的业务员看到的是「暂无额外权限」', (WidgetTester tester) async {
      await pumpRealApp(
        tester,
        repository: FakeAuthRepository(session: memberSession()),
      );

      expectTenantHome();
      expect(find.text('暂无额外权限'), findsOneWidget);
      expect(find.text('组内全部权限'), findsNothing);
    });

    testWidgets('退出登录要确认，取消则什么都不发生', (WidgetTester tester) async {
      final repository = FakeAuthRepository(session: ownerSession());
      await pumpRealApp(tester, repository: repository);

      await tester.tap(find.byTooltip('退出登录'));
      await tester.pumpAndSettle();
      expect(find.text('退出后需要重新输入账号密码。确定退出吗？'), findsOneWidget);

      await tester.tap(find.widgetWithText(TextButton, '取消'));
      await tester.pumpAndSettle();

      expect(repository.logoutCalls, 0);
      expectTenantHome();
    });

    testWidgets('确认退出后登出一次，并由守卫送回登录页', (WidgetTester tester) async {
      final repository = FakeAuthRepository(session: ownerSession());
      await pumpRealApp(tester, repository: repository);

      await tester.tap(find.byTooltip('退出登录'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '退出'));
      await tester.pumpAndSettle();

      expect(repository.logoutCalls, 1);
      expect(find.widgetWithText(FilledButton, '登录'), findsOneWidget);
    });

    testWidgets('未登录状态下的页面不会凭空长出导航', (WidgetTester tester) async {
      final repository = FakeAuthRepository()
        ..restoreFailure = const UnauthenticatedFailure('未登录');
      await pumpRealApp(tester, repository: repository);

      // 守卫会把未登录用户拦在登录页，租户壳根本不会渲染 ——
      // 这条断言看着像废话，但它守的是「守卫先于页面」这个前提：
      // 一旦有人把 /home 从守卫里漏掉，这里立刻会看到一堆导航项。
      expect(find.widgetWithText(FilledButton, '登录'), findsOneWidget);
      expectDestination('字典', visible: false);
    });
  });
}
