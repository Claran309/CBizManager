import 'dart:async';

import 'package:c_biz_docs_manager/core/error/app_failure.dart';
import 'package:c_biz_docs_manager/features/platform/data/platform_repository.dart';
import 'package:c_biz_docs_manager/features/platform/domain/platform_group.dart';
import 'package:c_biz_docs_manager/features/platform/presentation/create_group_page.dart';
import 'package:c_biz_docs_manager/features/platform/presentation/platform_group_detail_page.dart';
import 'package:c_biz_docs_manager/features/platform/presentation/platform_groups_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
// `Override` 在 Riverpod 3 里由 misc.dart 导出，主入口只给常用的那一组。
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import '../../support/fake_platform_repository.dart';
import '../../support/platform_fixtures.dart';

/// 把测试窗口设成指定逻辑尺寸。
///
/// devicePixelRatio 固定为 1，这样 physicalSize 的数值就等于逻辑像素，
/// 断言里可以直接写 390 / 1280，不用再心里换算一遍。
void _setScreenSize(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

/// 只搭平台侧三条路由的最小应用。
///
/// 刻意**不**套 `CBizDocsApp`：那会由会话作用域把真实 Dio 装配进
/// `platformRepositoryProvider`，用例就会去发真请求。页面本身不关心是谁装的仓储，
/// 所以这里直接把假仓储覆盖进去 —— 测试要盯的是「页面拿着状态做了什么」，
/// 而不是「装配置」本身（那属于 session_scope 的用例）。
Widget _app(
  FakePlatformRepository repository, {
  String initialLocation = '/platform/groups',
}) {
  final router = GoRouter(
    initialLocation: initialLocation,
    routes: <RouteBase>[
      GoRoute(
        path: '/platform/groups',
        builder: (BuildContext context, GoRouterState state) =>
            PlatformGroupsPage(notice: state.uri.queryParameters['notice']),
      ),
      GoRoute(
        path: '/platform/groups/new',
        builder: (BuildContext context, GoRouterState state) =>
            const CreateGroupPage(),
      ),
      GoRoute(
        path: '/platform/groups/:groupId',
        builder: (BuildContext context, GoRouterState state) =>
            PlatformGroupDetailPage(
              groupId: int.parse(state.pathParameters['groupId']!),
            ),
      ),
    ],
  );
  addTearDown(router.dispose);
  return ProviderScope(
    overrides: <Override>[
      platformRepositoryProvider.overrideWithValue(repository),
    ],
    child: MaterialApp.router(routerConfig: router),
  );
}

void main() {
  late FakePlatformRepository repository;

  setUp(() => repository = FakePlatformRepository());

  /* ------------------------------------------------------------ 组列表页 */

  group('组列表页', () {
    testWidgets('窄屏用卡片列表展示组名、主账号与成员数', (WidgetTester tester) async {
      _setScreenSize(tester, const Size(390, 844));
      repository.listResult = domainGroupPage();

      await tester.pumpWidget(_app(repository));
      await tester.pumpAndSettle();

      expect(find.text('钢材一组'), findsOneWidget);
      expect(find.textContaining('张三（owner）'), findsOneWidget);
      // 窄屏不该出现桌面表格：那是「把桌面布局硬塞进手机」的典型症状。
      expect(find.byType(DataTable), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('宽屏用紧凑表格展示，且不出现卡片列表', (WidgetTester tester) async {
      _setScreenSize(tester, const Size(1280, 800));
      repository.listResult = domainGroupPage();

      await tester.pumpWidget(_app(repository));
      await tester.pumpAndSettle();

      expect(find.byType(DataTable), findsOneWidget);
      expect(find.text('钢材一组'), findsOneWidget);
      // 表格里同时给出数据版本，运维一屏就能看出哪个组被改过。
      expect(find.text('数据版本'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('关键词与状态筛选传成查询条件，且回到第一页', (WidgetTester tester) async {
      _setScreenSize(tester, const Size(390, 844));
      repository.listResult = domainGroupPage();

      await tester.pumpWidget(_app(repository));
      await tester.pumpAndSettle();
      // 首屏已经加载过一次（page=1、无筛选）。
      expect(repository.listQueries, hasLength(1));

      await tester.enterText(find.byType(TextField).first, '钢材');
      await tester.tap(find.byType(DropdownButton<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('已停用').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('筛选'));
      await tester.pumpAndSettle();

      final query = repository.listQueries.last;
      expect(query.keyword, '钢材');
      expect(query.status, GroupStatus.disabled);
      // 换筛选条件必须回第一页：停在原页码上很可能什么都查不到，
      // 而用户看到的会是一个「空列表」而不是「页码越界」。
      expect(query.page, 1);
    });

    testWidgets('筛选条件为空时不把空串当关键词传下去', (WidgetTester tester) async {
      repository.listResult = domainGroupPage();

      await tester.pumpWidget(_app(repository));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField).first, '   ');
      await tester.tap(find.text('筛选'));
      await tester.pumpAndSettle();

      // 全是空白的输入等于「不筛」：传一个空串下去会被服务端当成
      // 「组名必须为空」这样的规则，结果一条都查不到。
      expect(repository.listQueries.last.keyword, isNull);
      expect(repository.listQueries.last.status, isNull);
    });

    testWidgets('刷新按钮用当前筛选条件重新请求', (WidgetTester tester) async {
      repository.listResult = domainGroupPage();

      await tester.pumpWidget(_app(repository));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('刷新'));
      await tester.pumpAndSettle();

      expect(repository.listQueries, hasLength(2));
      expect(repository.listQueries.last, repository.listQueries.first);
    });

    testWidgets('首次加载失败显示错误视图，点重试后恢复', (WidgetTester tester) async {
      repository.listError = const NetworkFailure('offline');

      await tester.pumpWidget(_app(repository));
      await tester.pumpAndSettle();

      expect(find.text('网络不可用，该操作需要联网，请检查网络后重试'), findsOneWidget);

      repository
        ..listError = null
        ..listResult = domainGroupPage();
      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();

      expect(find.text('钢材一组'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('从无效的组地址返回时会带上提示', (WidgetTester tester) async {
      repository.listResult = domainGroupPage();

      await tester.pumpWidget(
        _app(
          repository,
          initialLocation: '/platform/groups?notice=invalid_group_id',
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('组编号无效，已返回组列表'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('点一行进入对应组的详情页', (WidgetTester tester) async {
      _setScreenSize(tester, const Size(390, 844));
      repository
        ..listResult = domainGroupPage()
        ..detailResult = domainDetail();

      await tester.pumpWidget(_app(repository));
      await tester.pumpAndSettle();

      await tester.tap(find.text('钢材一组'));
      await tester.pumpAndSettle();

      expect(find.textContaining('组详情'), findsOneWidget);
      expect(repository.detailRequests, <int>[7]);
    });

    testWidgets('新建按钮进入新建页', (WidgetTester tester) async {
      repository.listResult = domainGroupPage();

      await tester.pumpWidget(_app(repository));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('新建组'));
      await tester.pumpAndSettle();

      expect(find.text('新建业务组'), findsOneWidget);
      expect(find.text('组主账号'), findsOneWidget);
    });
  });

  /* ------------------------------------------------------------ 启停操作 */

  group('启停组', () {
    testWidgets('点停用要先确认，确认后才发请求', (WidgetTester tester) async {
      _setScreenSize(tester, const Size(390, 844));
      repository
        ..listResult = domainGroupPage()
        ..statusResult = domainGroup(status: GroupStatus.disabled, version: 4);

      await tester.pumpWidget(_app(repository));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('停用该组'));
      await tester.pumpAndSettle();
      // 停用会踢掉整组人的会话，属于高危操作，必须先问一句。
      expect(find.text('停用业务组'), findsOneWidget);
      expect(repository.changeStatusCalls, 0);

      await tester.tap(find.widgetWithText(FilledButton, '停用'));
      await tester.pumpAndSettle();

      expect(repository.changeStatusCalls, 1);
      expect(find.text('已停用'), findsOneWidget);
    });

    testWidgets('取消确认不发请求', (WidgetTester tester) async {
      _setScreenSize(tester, const Size(390, 844));
      repository.listResult = domainGroupPage();

      await tester.pumpWidget(_app(repository));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('停用该组'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, '取消'));
      await tester.pumpAndSettle();

      expect(repository.changeStatusCalls, 0);
      expect(find.text('启用中'), findsOneWidget);
    });

    testWidgets('版本冲突时列表保留并提示刷新，而不是换成整页错误', (WidgetTester tester) async {
      _setScreenSize(tester, const Size(390, 844));
      repository
        ..listResult = domainGroupPage()
        ..statusError = const ConflictFailure('version 不等于 3');

      await tester.pumpWidget(_app(repository));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('停用该组'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '停用'));
      await tester.pumpAndSettle();

      // 冲突时刻意丢掉服务端底层文案，只告诉用户「该做什么」。
      expect(find.text('数据已被其他操作修改，请刷新后重新操作'), findsOneWidget);
      expect(find.text('刷新'), findsOneWidget);
      // 列表不能被错误视图顶掉：用户刚点的是哪一行必须还在眼前。
      expect(find.text('钢材一组'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('宽屏在表格里同样能停用', (WidgetTester tester) async {
      _setScreenSize(tester, const Size(1280, 800));
      repository
        ..listResult = domainGroupPage()
        ..statusResult = domainGroup(status: GroupStatus.disabled, version: 4);

      await tester.pumpWidget(_app(repository));
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(TextButton, '停用'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '停用'));
      await tester.pumpAndSettle();

      expect(repository.changeStatusCalls, 1);
      expect(tester.takeException(), isNull);
    });

    testWidgets('宽屏下表格出现启动而非停用（已停用的组）', (WidgetTester tester) async {
      _setScreenSize(tester, const Size(1280, 800));
      repository.listResult = domainGroupPage(
        items: <PlatformGroup>[domainGroup(status: GroupStatus.disabled)],
      );

      await tester.pumpWidget(_app(repository));
      await tester.pumpAndSettle();

      expect(find.widgetWithText(TextButton, '启用'), findsOneWidget);
      expect(find.text('已停用'), findsOneWidget);
    });
  });

  /* -------------------------------------------------------------- 详情页 */

  group('组详情页', () {
    testWidgets('展示版本、主账号与三类成员计数（窄屏）', (WidgetTester tester) async {
      _setScreenSize(tester, const Size(390, 844));
      repository.detailResult = domainDetail(
        group: domainGroup(version: 9, memberCount: 33),
        memberCounts: domainMemberCounts(active: 11, disabled: 2, removed: 4),
      );

      await tester.pumpWidget(
        _app(repository, initialLocation: '/platform/groups/7'),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('组详情'), findsOneWidget);
      expect(find.text('张三（owner）'), findsOneWidget);
      expect(find.text('9'), findsOneWidget);
      expect(find.text('33 人'), findsOneWidget);
      expect(find.text('11'), findsOneWidget);
      expect(find.text('2'), findsOneWidget);
      expect(find.text('4'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('详情页在宽屏也不溢出', (WidgetTester tester) async {
      _setScreenSize(tester, const Size(1280, 800));
      repository.detailResult = domainDetail();

      await tester.pumpWidget(
        _app(repository, initialLocation: '/platform/groups/7'),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('组详情'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('详情加载失败显示错误视图，点重试后恢复', (WidgetTester tester) async {
      repository.detailError = const ServerFailure('boom', requestId: 'req-1');

      await tester.pumpWidget(
        _app(repository, initialLocation: '/platform/groups/7'),
      );
      await tester.pumpAndSettle();

      expect(find.text('请求 ID：req-1'), findsOneWidget);

      repository
        ..detailError = null
        ..detailResult = domainDetail();
      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();

      expect(find.text('交接主账号'), findsOneWidget);
    });

    testWidgets('详情页里停用同样要先确认', (WidgetTester tester) async {
      repository
        ..detailResult = domainDetail()
        ..statusResult = domainGroup(status: GroupStatus.disabled, version: 4);

      await tester.pumpWidget(
        _app(repository, initialLocation: '/platform/groups/7'),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('停用该组'));
      await tester.pumpAndSettle();
      expect(find.text('停用业务组'), findsOneWidget);

      await tester.tap(find.widgetWithText(FilledButton, '停用'));
      await tester.pumpAndSettle();

      expect(repository.changeStatusCalls, 1);
    });
  });

  /* -------------------------------------------------------- 主账号交接 */

  group('主账号交接', () {
    testWidgets('现有成员模式提交关系 ID 与版本号', (WidgetTester tester) async {
      repository
        ..detailResult = domainDetail()
        ..ownerResult = domainDetail();

      await tester.pumpWidget(
        _app(repository, initialLocation: '/platform/groups/7'),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('交接主账号'));
      await tester.pumpAndSettle();

      // 默认停在「现有成员」模式，并列出候选人（显示姓名与账号）。
      expect(find.text('李四'), findsOneWidget);
      expect(find.text('sales'), findsOneWidget);

      await tester.tap(find.text('李四'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认交接'));
      await tester.pumpAndSettle();

      expect(repository.ownerDrafts, hasLength(1));
      final draft = repository.ownerDrafts.single;
      expect(draft, isA<ExistingMemberOwnerDraft>());
      expect((draft as ExistingMemberOwnerDraft).membershipId, 9);
      // 交接是敏感操作，必须带着用户看到的那一版 version 走乐观锁。
      expect(draft.version, 3);
    });

    testWidgets('一个人都没选时不允许交接', (WidgetTester tester) async {
      repository.detailResult = domainDetail();

      await tester.pumpWidget(
        _app(repository, initialLocation: '/platform/groups/7'),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('交接主账号'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认交接'));
      await tester.pumpAndSettle();

      expect(find.text('请选择一位成员'), findsOneWidget);
      expect(repository.ownerDrafts, isEmpty);
    });

    testWidgets('新建账号模式提交账号资料', (WidgetTester tester) async {
      repository
        ..detailResult = domainDetail()
        ..ownerResult = domainDetail();

      await tester.pumpWidget(
        _app(repository, initialLocation: '/platform/groups/7'),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('交接主账号'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('新建账号'));
      await tester.pumpAndSettle();

      // 两种模式的控件互斥：切到新建账号后，候选人列表不该还留在屏幕上。
      expect(find.text('李四'), findsNothing);

      await tester.enterText(
        find.widgetWithText(TextFormField, '登录账号'),
        'zhangsan',
      );
      await tester.enterText(find.widgetWithText(TextFormField, '姓名'), '张三');
      await tester.enterText(
        find.widgetWithText(TextFormField, '初始密码'),
        'password123',
      );
      await tester.tap(find.text('确认交接'));
      await tester.pumpAndSettle();

      expect(repository.ownerDrafts, hasLength(1));
      final draft = repository.ownerDrafts.single;
      expect(draft, isA<NewAccountOwnerDraft>());
      final newAccount = draft as NewAccountOwnerDraft;
      expect(newAccount.username, 'zhangsan');
      expect(newAccount.displayName, '张三');
      expect(newAccount.temporaryPassword, 'password123');
      expect(newAccount.version, 3);
    });

    testWidgets('新建账号密码不足 8 位时被本地拦下', (WidgetTester tester) async {
      repository.detailResult = domainDetail();

      await tester.pumpWidget(
        _app(repository, initialLocation: '/platform/groups/7'),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('交接主账号'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('新建账号'));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.widgetWithText(TextFormField, '登录账号'),
        'zhangsan',
      );
      await tester.enterText(find.widgetWithText(TextFormField, '姓名'), '张三');
      await tester.enterText(
        find.widgetWithText(TextFormField, '初始密码'),
        'short',
      );
      await tester.tap(find.text('确认交接'));
      await tester.pumpAndSettle();

      // 契约的 minLength 是 8；本地先拦一道，用户不必为一个明确可知的规则
      // 白等一次往返。
      expect(find.text('初始密码不少于 8 位'), findsOneWidget);
      expect(repository.ownerDrafts, isEmpty);
    });

    testWidgets('没有候选人时默认落到新建账号模式', (WidgetTester tester) async {
      repository.detailResult = domainDetail(
        ownerCandidates: const <OwnerCandidate>[],
      );

      await tester.pumpWidget(
        _app(repository, initialLocation: '/platform/groups/7'),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('交接主账号'));
      await tester.pumpAndSettle();

      // 候选人一个都没有时，把用户丢在一个空列表前面等他自己发现切换按钮，
      // 是最没必要的一次挫败 —— 直接给可用的那条路。
      expect(find.widgetWithText(TextFormField, '登录账号'), findsOneWidget);
    });

    testWidgets('用户取消对话框时不留痕迹', (WidgetTester tester) async {
      repository.detailResult = domainDetail();

      await tester.pumpWidget(
        _app(repository, initialLocation: '/platform/groups/7'),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('交接主账号'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();

      expect(repository.ownerDrafts, isEmpty);
      expect(find.text('交接主账号'), findsOneWidget);
    });

    testWidgets('交接遇到版本冲突会重读详情并保留提示', (WidgetTester tester) async {
      repository
        ..detailResult = domainDetail()
        ..ownerError = const ConflictFailure('version 不等于 3');

      await tester.pumpWidget(
        _app(repository, initialLocation: '/platform/groups/7'),
      );
      await tester.pumpAndSettle();
      expect(repository.detailRequests, hasLength(1));

      await tester.tap(find.text('交接主账号'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('李四'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认交接'));
      await tester.pumpAndSettle();

      // 先重读（手上的 version 与候选列表都已经过期），再把冲突原因放回界面。
      expect(repository.detailRequests, hasLength(2));
      expect(find.text('数据已被其他操作修改，请刷新后重新操作'), findsOneWidget);
    });
  });

  /* ------------------------------------------------------------ 新建组页 */

  group('新建组页', () {
    testWidgets('填写四项后提交正确草稿并跳转详情', (WidgetTester tester) async {
      repository
        ..createResult = domainCreateResult(groupId: 21)
        ..detailResult = domainDetail(group: domainGroup(id: 21));

      await tester.pumpWidget(
        _app(repository, initialLocation: '/platform/groups/new'),
      );
      await tester.pumpAndSettle();

      await tester.enterText(
        find.widgetWithText(TextFormField, '业务组名称'),
        '钢材一组',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, '登录账号'),
        'zhangsan',
      );
      await tester.enterText(find.widgetWithText(TextFormField, '姓名'), '张三');
      await tester.enterText(
        find.widgetWithText(TextFormField, '初始密码'),
        'password123',
      );

      await tester.tap(find.byType(FilledButton));
      await tester.pumpAndSettle();

      expect(repository.createDrafts, hasLength(1));
      final draft = repository.createDrafts.single;
      expect(draft.name, '钢材一组');
      expect(draft.ownerUsername, 'zhangsan');
      expect(draft.ownerDisplayName, '张三');
      expect(draft.ownerTemporaryPassword, 'password123');
      // 成功后直接进新组的详情，用户不必自己回列表再找。
      expect(find.textContaining('组详情'), findsOneWidget);
      expect(repository.detailRequests, <int>[21]);
    });

    testWidgets('必填项为空时不发请求', (WidgetTester tester) async {
      await tester.pumpWidget(
        _app(repository, initialLocation: '/platform/groups/new'),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byType(FilledButton));
      await tester.pumpAndSettle();

      expect(find.text('请输入业务组名称'), findsOneWidget);
      expect(repository.createDrafts, isEmpty);
    });

    testWidgets('初始密码少于 8 位时不发请求', (WidgetTester tester) async {
      await tester.pumpWidget(
        _app(repository, initialLocation: '/platform/groups/new'),
      );
      await tester.pumpAndSettle();

      await tester.enterText(
        find.widgetWithText(TextFormField, '业务组名称'),
        '钢材一组',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, '登录账号'),
        'zhangsan',
      );
      await tester.enterText(find.widgetWithText(TextFormField, '姓名'), '张三');
      await tester.enterText(
        find.widgetWithText(TextFormField, '初始密码'),
        'short',
      );

      await tester.tap(find.byType(FilledButton));
      await tester.pumpAndSettle();

      expect(find.text('初始密码不少于 8 位'), findsOneWidget);
      expect(repository.createDrafts, isEmpty);
    });

    testWidgets('提交中禁用创建按钮，防止连点建成两个组', (WidgetTester tester) async {
      final gate = Completer<CreateGroupResult>();
      repository
        ..queuedCreateWrites.add(gate.future)
        ..detailResult = domainDetail(group: domainGroup(id: 21));

      await tester.pumpWidget(
        _app(repository, initialLocation: '/platform/groups/new'),
      );
      await tester.pumpAndSettle();

      await tester.enterText(
        find.widgetWithText(TextFormField, '业务组名称'),
        '钢材一组',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, '登录账号'),
        'zhangsan',
      );
      await tester.enterText(find.widgetWithText(TextFormField, '姓名'), '张三');
      await tester.enterText(
        find.widgetWithText(TextFormField, '初始密码'),
        'password123',
      );

      await tester.tap(find.byType(FilledButton));
      // 只 pump 一帧：请求挂在 gate 上，此时按钮应当已经禁用。
      await tester.pump();

      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull,
      );
      expect(repository.createDrafts, hasLength(1));

      gate.complete(domainCreateResult(groupId: 21));
      await tester.pumpAndSettle();

      expect(find.textContaining('组详情'), findsOneWidget);
    });

    testWidgets('服务端字段错误挂到对应输入框，其余错误走提示条', (WidgetTester tester) async {
      repository.createError = const ValidationFailure(
        '请求参数有误',
        <String, String>{'owner_username': '登录账号已被占用'},
      );

      await tester.pumpWidget(
        _app(repository, initialLocation: '/platform/groups/new'),
      );
      await tester.pumpAndSettle();

      await tester.enterText(
        find.widgetWithText(TextFormField, '业务组名称'),
        '钢材一组',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, '登录账号'),
        'zhangsan',
      );
      await tester.enterText(find.widgetWithText(TextFormField, '姓名'), '张三');
      await tester.enterText(
        find.widgetWithText(TextFormField, '初始密码'),
        'password123',
      );

      await tester.tap(find.byType(FilledButton));
      await tester.pumpAndSettle();

      expect(find.text('登录账号已被占用'), findsOneWidget);
    });

    testWidgets('非字段类失败用提示条说明', (WidgetTester tester) async {
      repository.createError = const NetworkFailure('offline');

      await tester.pumpWidget(
        _app(repository, initialLocation: '/platform/groups/new'),
      );
      await tester.pumpAndSettle();

      await tester.enterText(
        find.widgetWithText(TextFormField, '业务组名称'),
        '钢材一组',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, '登录账号'),
        'zhangsan',
      );
      await tester.enterText(find.widgetWithText(TextFormField, '姓名'), '张三');
      await tester.enterText(
        find.widgetWithText(TextFormField, '初始密码'),
        'password123',
      );

      await tester.tap(find.byType(FilledButton));
      await tester.pumpAndSettle();

      expect(find.text('网络不可用，该操作需要联网，请检查网络后重试'), findsOneWidget);
    });

    testWidgets('新建页在窄屏与宽屏都不溢出', (WidgetTester tester) async {
      for (final size in <Size>[const Size(390, 844), const Size(1280, 800)]) {
        _setScreenSize(tester, size);
        await tester.pumpWidget(
          _app(repository, initialLocation: '/platform/groups/new'),
        );
        await tester.pumpAndSettle();

        expect(find.text('新建业务组'), findsOneWidget, reason: '尺寸 $size');
        expect(tester.takeException(), isNull, reason: '尺寸 $size');
      }
    });
  });
}
