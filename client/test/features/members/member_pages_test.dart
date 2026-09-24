import 'package:c_biz_docs_manager/core/auth/auth_controller.dart';
import 'package:c_biz_docs_manager/core/auth/auth_models.dart';
import 'package:c_biz_docs_manager/core/auth/auth_repository.dart';
import 'package:c_biz_docs_manager/core/error/app_failure.dart';
import 'package:c_biz_docs_manager/features/members/application/member_controller.dart';
import 'package:c_biz_docs_manager/features/members/domain/member.dart';
import 'package:c_biz_docs_manager/features/members/presentation/member_permissions_page.dart';
import 'package:c_biz_docs_manager/features/members/presentation/members_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
// `Override` 在 Riverpod 3 里由 misc.dart 导出，主入口只给常用的那一组。
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import '../../support/auth_fixtures.dart';
import '../../support/fake_member_repository.dart';
import '../../support/member_fixtures.dart';

/// 只关心「会话是谁」的认证仓储替身；登录 / 注册 / 改密不属于本文件的关注点。
///
/// 为什么页面测试需要一个认证替身：成员页要读 `authControllerProvider` 才知道
/// 「谁能管状态、谁能改权限」。守卫在真实应用里负责拦人，而这里要盯的是
/// 「拿到这个身份之后，页面画出了哪些入口」—— 所以身份必须由用例说了算。
final class _StaticAuthRepository implements AuthRepository {
  const _StaticAuthRepository(this._session);

  final AuthSession _session;

  @override
  Future<AuthSession> login(String username, String password) async => _session;

  @override
  Future<AuthSession> restore() async => _session;

  @override
  Future<void> logout() async {}

  @override
  Future<RegistrationResult> register(RegistrationDraft draft) =>
      throw UnsupportedError('成员页面测试不覆盖注册');

  @override
  Future<AuthSession> changePassword(
    String currentPassword,
    String newPassword,
  ) => throw UnsupportedError('成员页面测试不覆盖改密');
}

/// 把测试窗口设成指定逻辑尺寸。
///
/// devicePixelRatio 固定为 1，这样 physicalSize 的数值就等于逻辑像素，
/// 断言里可以直接写 390 / 1280，不用再心里换算一遍。
void _setScreenSize(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

/// 只搭成员列表页、权限页与首页三条路由的最小应用。
///
/// 刻意**不**套 `CBizDocsApp`：那会由会话作用域把真实 Dio 装配进
/// `memberRepositoryProvider`，用例就会去发真请求。页面本身不关心是谁装的仓储，
/// 所以这里直接把假仓储覆盖进去 —— 测试要盯的是「页面拿着状态做了什么」，
/// 而不是「装配置」本身（那属于 session_scope 的用例）。
///
/// 返回容器是为了能直接读 `authControllerProvider` 之类的状态做断言。
Future<ProviderContainer> _pumpApp(
  WidgetTester tester,
  FakeMemberRepository repository, {
  required AuthSession session,
  String initialLocation = '/members',
}) async {
  final router = GoRouter(
    initialLocation: initialLocation,
    routes: <RouteBase>[
      GoRoute(
        path: '/members',
        builder: (BuildContext context, GoRouterState state) =>
            MembersPage(notice: state.uri.queryParameters['notice']),
      ),
      GoRoute(
        path: '/members/:membershipId/permissions',
        builder: (BuildContext context, GoRouterState state) =>
            MemberPermissionsPage(
              membershipId: int.parse(state.pathParameters['membershipId']!),
            ),
      ),
      GoRoute(
        path: '/home',
        builder: (BuildContext context, GoRouterState state) =>
            const Scaffold(body: Center(child: Text('首页'))),
      ),
    ],
  );
  addTearDown(router.dispose);

  final container = ProviderContainer(
    overrides: <Override>[
      memberRepositoryProvider.overrideWithValue(repository),
      authRepositoryProvider.overrideWithValue(_StaticAuthRepository(session)),
    ],
  );
  addTearDown(container.dispose);
  // 先把身份灌进 authControllerProvider，再让页面首帧就读到它。
  await container.read(authControllerProvider.notifier).restore();

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

/// 给权限页预置一份权限快照（队列按先进先出被消费）。
void _queuePermissions(
  FakeMemberRepository repository, {
  int membershipId = 7,
  required Set<String> codes,
  required int version,
}) {
  repository.queuedPermissionReads.add(
    Future<MemberPermissions>.value(
      MemberPermissions(
        membershipId: membershipId,
        permissionCodes: codes,
        version: version,
      ),
    ),
  );
}

/// 三行成员：组主账号 / 当前登录者本人 / 普通业务员。
///
/// 顺序就是渲染顺序，所以断言可以直接按下标对准某一行 ——
/// 三个人的 userId 刻意互不相同，界面「这一行是谁」的判定才有意义。
List<Member> _threeRows({required int currentUserId}) => <Member>[
  buildMember(
    membershipId: 1,
    userId: 900,
    username: 'owner',
    displayName: '组主账号',
    memberType: 'owner',
  ),
  buildMember(
    membershipId: 2,
    userId: currentUserId,
    username: 'me',
    displayName: '我自己',
  ),
  buildMember(
    membershipId: 7,
    userId: 101,
    username: 'alice',
    displayName: 'Alice',
  ),
];

/// 读出屏幕上所有状态菜单，用来断言「哪几行的状态按钮是禁用的」。
List<PopupMenuButton<MemberStatus>> _statusMenus(WidgetTester tester) => tester
    .widgetList<PopupMenuButton<MemberStatus>>(
      find.byType(PopupMenuButton<MemberStatus>),
    )
    .toList();

/// 取出保存按钮，用来断言它在「没有改动」与「有改动」之间的启停。
bool _saveEnabled(WidgetTester tester) =>
    tester
        .widget<FilledButton>(find.widgetWithText(FilledButton, '保存权限'))
        .onPressed !=
    null;

void main() {
  late FakeMemberRepository repository;

  setUp(() => repository = FakeMemberRepository());

  /* ------------------------------------------------------------ 成员列表 */

  group('成员列表页', () {
    testWidgets('组主账号可改普通成员状态，但动不了组主账号与他自己', (WidgetTester tester) async {
      _setScreenSize(tester, const Size(390, 844));
      repository.members = _threeRows(currentUserId: 11);

      await _pumpApp(tester, repository, session: ownerSession(userId: 11));

      final menus = _statusMenus(tester);
      expect(menus, hasLength(3));
      // 第 1 行是组主账号：停用他等于整个组没人能管理；
      // 第 2 行是当前账号本人：停用自己是不可逆的自锁（下一个请求就 401）。
      // 这两种都必须堵死，只剩第 3 行可点。
      expect(menus[0].enabled, isFalse);
      expect(menus[1].enabled, isFalse);
      expect(menus[2].enabled, isTrue);
      expect(tester.takeException(), isNull);
    });

    testWidgets('组主账号在每一行都拿得到权限入口', (WidgetTester tester) async {
      _setScreenSize(tester, const Size(390, 844));
      repository.members = _threeRows(currentUserId: 11);

      await _pumpApp(tester, repository, session: ownerSession(userId: 11));

      // 权限入口对三行都给 —— 包括他自己和组主账号：调整自己的权限虽然没什么意义，
      // 但它不是「自锁」（改错了还能改回来），后端也会照常校验。
      expect(find.byTooltip('调整权限'), findsNWidgets(3));
    });

    testWidgets('持 member.manage 的普通成员能管状态，却看不到任何权限入口', (
      WidgetTester tester,
    ) async {
      _setScreenSize(tester, const Size(390, 844));
      repository.members = _threeRows(currentUserId: 22);

      await _pumpApp(
        tester,
        repository,
        session: memberSession(
          permissionCodes: const <String>['member.manage'],
          userId: 22,
        ),
      );

      expect(_statusMenus(tester), hasLength(3));
      // 把授权入口交给被管理者，等于给他一条自己给自己提权的路 —— 前端不给，
      // 后端也不认（真正的授权始终在后端）。
      expect(find.byTooltip('调整权限'), findsNothing);
    });

    testWidgets('没有 member.manage 的普通成员一个管理入口都看不到', (
      WidgetTester tester,
    ) async {
      _setScreenSize(tester, const Size(390, 844));
      repository.members = _threeRows(currentUserId: 22);

      await _pumpApp(tester, repository, session: memberSession(userId: 22));

      // 这是纵深防御：正常情况下守卫已经把他送回首页了，
      // 但万一页面被别的方式渲染出来，也不该凭空长出一堆按钮。
      expect(find.byType(PopupMenuButton<MemberStatus>), findsNothing);
      expect(find.byTooltip('调整权限'), findsNothing);
    });

    testWidgets('窄屏用卡片、宽屏用表格，两种布局都不 overflow', (WidgetTester tester) async {
      _setScreenSize(tester, const Size(390, 844));
      repository.members = _threeRows(currentUserId: 11);

      await _pumpApp(tester, repository, session: ownerSession(userId: 11));

      expect(find.byType(Card), findsNWidgets(3));
      expect(find.byType(DataTable), findsNothing);
      expect(tester.takeException(), isNull);

      // 换成宽屏再看一次：切布局最容易在另一套分支上炸出 overflow。
      _setScreenSize(tester, const Size(1280, 800));
      await tester.pumpAndSettle();

      expect(find.byType(DataTable), findsOneWidget);
      expect(find.byType(Card), findsNothing);
      // 表格里权限入口是文字按钮，出现三次（组主账号拥有全部权限）。
      expect(find.widgetWithText(TextButton, '权限'), findsNWidgets(3));
      expect(tester.takeException(), isNull);
    });

    testWidgets('无管理权的成员在宽屏表格里只看到破折号', (WidgetTester tester) async {
      _setScreenSize(tester, const Size(1280, 800));
      repository.members = <Member>[
        buildMember(
          membershipId: 7,
          userId: 101,
          username: 'alice',
          displayName: 'Alice',
        ),
      ];

      await _pumpApp(tester, repository, session: memberSession(userId: 22));

      expect(find.byType(DataTable), findsOneWidget);
      // 「—」表示这一列本来就没有东西，比空格子更读得懂。
      expect(find.text('—'), findsOneWidget);
      expect(find.widgetWithText(TextButton, '权限'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('从非法成员编号地址回来时会给出提示', (WidgetTester tester) async {
      _setScreenSize(tester, const Size(390, 844));
      repository.members = _threeRows(currentUserId: 11);

      await _pumpApp(
        tester,
        repository,
        session: ownerSession(userId: 11),
        initialLocation: '/members?notice=invalid_membership_id',
      );

      // 用户点了 `/members/abc/permissions` 这种地址被重定向回来，
      // 页面上必须有一句话解释「为什么我看到的不是权限页」。
      expect(find.text('成员编号无效，已返回成员列表'), findsOneWidget);
      expect(find.byType(Card), findsNWidgets(3));
    });
  });

  /* -------------------------------------------------------- 权限替换页 */

  group('成员权限替换页', () {
    testWidgets('复选框按服务端目录渲染，勾选状态来自该成员的快照', (WidgetTester tester) async {
      _setScreenSize(tester, const Size(390, 844));
      repository
        ..catalog = catalogFixture
        ..members = <Member>[
          buildMember(membershipId: 7, displayName: 'Alice', version: 4),
        ];
      _queuePermissions(
        repository,
        codes: const <String>{'member.manage'},
        version: 4,
      );

      await _pumpApp(
        tester,
        repository,
        session: ownerSession(),
        initialLocation: '/members/7/permissions',
      );

      // 目录只有两项，复选框就只该有两项 —— 客户端不维护自己的一份清单。
      expect(find.byType(CheckboxListTile), findsNWidgets(2));
      expect(
        tester
            .widget<CheckboxListTile>(
              find.widgetWithText(CheckboxListTile, '成员管理'),
            )
            .value,
        isTrue,
      );
      expect(
        tester
            .widget<CheckboxListTile>(
              find.widgetWithText(CheckboxListTile, '查看他人单据'),
            )
            .value,
        isFalse,
      );
      // 版本号是乐观锁凭据，摆在页面上是为了让反复撞冲突的管理员有个可对照的数字。
      expect(find.textContaining('数据版本 4'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('无改动时保存不可点，勾选后按整体集合提交并带上版本号', (WidgetTester tester) async {
      _setScreenSize(tester, const Size(390, 844));
      repository.catalog = catalogFixture;
      _queuePermissions(
        repository,
        codes: const <String>{'member.manage'},
        version: 4,
      );

      await _pumpApp(
        tester,
        repository,
        session: ownerSession(),
        initialLocation: '/members/7/permissions',
      );

      expect(_saveEnabled(tester), isFalse);
      expect(find.text('权限没有改动。'), findsOneWidget);

      await tester.tap(find.widgetWithText(CheckboxListTile, '查看他人单据'));
      await tester.pumpAndSettle();

      expect(_saveEnabled(tester), isTrue);
      await tester.ensureVisible(find.widgetWithText(FilledButton, '保存权限'));
      await tester.tap(find.widgetWithText(FilledButton, '保存权限'));
      await tester.pumpAndSettle();

      expect(repository.permissionWrites, hasLength(1));
      final write = repository.permissionWrites.single;
      expect(write.membershipId, 7);
      // 接口是**整体替换**：提交的必须是完整集合，而不是「这次勾了什么」的差量。
      expect(write.codes, <String>{'member.manage', 'document.view_others'});
      // 版本号必须原样回传：少了它这个整体替换就没有乐观锁。
      expect(write.version, 4);
    });

    testWidgets('保存成功后基线换成服务端的新版本，按钮重新变回不可点', (WidgetTester tester) async {
      _setScreenSize(tester, const Size(390, 844));
      repository.catalog = catalogFixture;
      _queuePermissions(
        repository,
        codes: const <String>{'member.manage'},
        version: 4,
      );

      await _pumpApp(
        tester,
        repository,
        session: ownerSession(),
        initialLocation: '/members/7/permissions',
      );

      await tester.tap(find.widgetWithText(CheckboxListTile, '查看他人单据'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.widgetWithText(FilledButton, '保存权限'));
      await tester.tap(find.widgetWithText(FilledButton, '保存权限'));
      await tester.pumpAndSettle();

      // 假仓储保存后返回 version+1。基线不跟着走的话，用户紧接着再改一次
      // 手里拿的还是旧 version，会白撞一次 409。
      expect(find.textContaining('数据版本 5'), findsOneWidget);
      expect(_saveEnabled(tester), isFalse);
      // 保存后的勾选状态就是服务端现在那一份，两项都该是勾上的。
      expect(
        tester
            .widget<CheckboxListTile>(
              find.widgetWithText(CheckboxListTile, '查看他人单据'),
            )
            .value,
        isTrue,
      );
    });

    testWidgets('撞版本冲突时提示、重读快照，但绝不自动重提', (WidgetTester tester) async {
      _setScreenSize(tester, const Size(390, 844));
      repository
        ..catalog = catalogFixture
        ..writeError = const ConflictFailure('版本过期', requestId: 'req-409');
      _queuePermissions(
        repository,
        codes: const <String>{'member.manage'},
        version: 4,
      );
      // 冲突后 Controller 会重读一次快照：这时候服务端已经是另一份了。
      _queuePermissions(repository, codes: const <String>{}, version: 5);

      await _pumpApp(
        tester,
        repository,
        session: ownerSession(),
        initialLocation: '/members/7/permissions',
      );

      await tester.tap(find.widgetWithText(CheckboxListTile, '查看他人单据'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.widgetWithText(FilledButton, '保存权限'));
      await tester.tap(find.widgetWithText(FilledButton, '保存权限'));
      await tester.pumpAndSettle();

      // 用户唯一的正确动作是「先看最新数据，再重新决定」，所以只提示 + 重读。
      expect(find.text('数据已被其他操作修改，请刷新后重新操作'), findsOneWidget);
      expect(repository.permissionReads, <int>[7, 7]);
      // 关键：只提交了这一次。替用户自动重提等于替他做了一个
      // 他并不知道自己在做的决定 —— 而权限替换是整体覆盖，重提的代价很大。
      expect(repository.permissionWrites, hasLength(1));
      // 草稿跟着新基线走：屏幕上现在展示的是服务端最新那一份（空）。
      expect(find.textContaining('数据版本 5'), findsOneWidget);
      expect(_saveEnabled(tester), isFalse);
    });

    testWidgets('目录之外的权限码照旧保留，不会被静默收回', (WidgetTester tester) async {
      _setScreenSize(tester, const Size(390, 844));
      repository.catalog = catalogFixture;
      _queuePermissions(
        repository,
        codes: const <String>{'member.manage', 'legacy.code'},
        version: 4,
      );

      await _pumpApp(
        tester,
        repository,
        session: ownerSession(),
        initialLocation: '/members/7/permissions',
      );

      // 目录里没有它，但它确实挂在成员身上。因为「目录里没写」就把它从
      // 提交载荷里悄悄去掉，等于让管理员在毫不知情的情况下收回了一项权限。
      expect(find.text('目录之外的权限'), findsOneWidget);
      expect(find.text('legacy.code'), findsOneWidget);

      await tester.tap(find.widgetWithText(CheckboxListTile, '成员管理'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.widgetWithText(FilledButton, '保存权限'));
      await tester.tap(find.widgetWithText(FilledButton, '保存权限'));
      await tester.pumpAndSettle();

      expect(repository.permissionWrites.single.codes, <String>{'legacy.code'});
    });

    testWidgets('目录拉取失败给的是可重试的卡片，而不是一副空清单', (WidgetTester tester) async {
      _setScreenSize(tester, const Size(390, 844));
      repository
        ..catalog = catalogFixture
        ..catalogError = const NetworkFailure('offline');
      _queuePermissions(
        repository,
        codes: const <String>{'member.manage'},
        version: 4,
      );

      await _pumpApp(
        tester,
        repository,
        session: ownerSession(),
        initialLocation: '/members/7/permissions',
      );

      // 「目录为空」绝不能呈现成「这个成员没有权限可分配」：
      // 管理员会照着那份空清单整体替换，那是一次大面积误收回。
      expect(find.text('权限目录加载失败'), findsOneWidget);
      expect(find.text('重新加载目录'), findsOneWidget);
      expect(find.byType(CheckboxListTile), findsNothing);

      repository.catalogError = null;
      await tester.tap(find.text('重新加载目录'));
      await tester.pumpAndSettle();

      expect(repository.catalogCalls, 2);
      expect(find.byType(CheckboxListTile), findsNWidgets(2));
    });
  });
}
