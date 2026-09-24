import 'dart:async';

import 'package:c_biz_docs_manager/core/error/app_failure.dart';
import 'package:c_biz_docs_manager/core/network/page_result.dart';
import 'package:c_biz_docs_manager/features/invitations/data/invitation_repository.dart';
import 'package:c_biz_docs_manager/features/invitations/domain/invitation.dart';
import 'package:c_biz_docs_manager/features/invitations/presentation/invitation_secret_panel.dart';
import 'package:c_biz_docs_manager/features/invitations/presentation/invitations_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
// `Override` 在 Riverpod 3 里由 misc.dart 导出，主入口只给常用的那一组。
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import '../../support/fake_invitation_repository.dart';
import '../../support/invitation_fixtures.dart';

/// 把测试窗口设成指定逻辑尺寸。
///
/// devicePixelRatio 固定为 1，这样 physicalSize 的数值就等于逻辑像素，
/// 断言里可以直接写 390 / 1280，不用再心里换算一遍。
void _setScreenSize(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

/// 只搭邀请码页与租户首页两条路由的最小应用。
///
/// 刻意**不**套 `CBizDocsApp`：那会由会话作用域把真实 Dio 装配进
/// `invitationRepositoryProvider`，用例就会去发真请求。页面本身不关心是谁装的仓储，
/// 所以这里直接把假仓储覆盖进去 —— 测试要盯的是「页面拿着状态做了什么」，
/// 而不是「装配置」本身（那属于 session_scope 的用例）。
///
/// 返回 router 是为了让「离开页面再回来」的用例能真的走一次路由切换，
/// 而不是靠重建整棵树来伪造。
(Widget, GoRouter) _app(
  FakeInvitationRepository repository, {
  String initialLocation = '/invitations',
}) {
  final router = GoRouter(
    initialLocation: initialLocation,
    routes: <RouteBase>[
      GoRoute(
        path: '/invitations',
        builder: (BuildContext context, GoRouterState state) =>
            const InvitationsPage(),
      ),
      GoRoute(
        path: '/home',
        builder: (BuildContext context, GoRouterState state) =>
            const Scaffold(body: Center(child: Text('首页'))),
      ),
    ],
  );
  addTearDown(router.dispose);
  return (
    ProviderScope(
      overrides: <Override>[
        invitationRepositoryProvider.overrideWithValue(repository),
      ],
      child: MaterialApp.router(routerConfig: router),
    ),
    router,
  );
}

/// 一页邀请码的夹具，四行覆盖四种展示状态。
PageResult<InvitationSummary> _fourStatusPage() => domainInvitationPage(
  items: <InvitationSummary>[
    domainInvitation(id: 9, status: InvitationStatus.active),
    domainInvitation(
      id: 10,
      status: InvitationStatus.used,
      usedAt: DateTime.utc(2026, 2, 10),
    ),
    domainInvitation(id: 11, status: InvitationStatus.expired),
    domainInvitation(
      id: 12,
      status: InvitationStatus.revoked,
      revokedAt: DateTime.utc(2026, 2, 12),
    ),
  ],
  total: 4,
);

/// 断言「当前屏幕上没有明文」。
///
/// 判据是面板那句标题还在不在，**不是** `find.byType(InvitationSecretPanel)`：
/// 没有明文时面板会退化成 `SizedBox.shrink()`，但 widget 本身仍然挂在树上，
/// 用 byType 断言会永远失败（本用例第一版就是这么红的）。
void _expectNoSecretShowing() => expect(find.text('邀请码明文'), findsNothing);

void main() {
  late FakeInvitationRepository repository;

  /// 剪贴板调用记录。
  ///
  /// `Clipboard.setData` 走的是 `SystemChannels.platform`，测试环境不会真的有剪贴板，
  /// 所以把它拦下来记录调用 —— 这样既能断言「复制的是明文」，也能断言
  /// 「反馈提示里没有明文」。
  late List<MethodCall> clipboardCalls;

  setUp(() {
    repository = FakeInvitationRepository();
    clipboardCalls = <MethodCall>[];
  });

  /// 装好剪贴板拦截器。只有关心复制的用例才调它，
  /// 免得所有用例都被一个 platform 通道替身影响。
  void mockClipboard(WidgetTester tester) {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (MethodCall call) async {
        clipboardCalls.add(call);
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
  }

  /// 最近一次写进剪贴板的文本。
  String lastCopiedText() {
    final call = clipboardCalls.lastWhere(
      (MethodCall call) => call.method == 'Clipboard.setData',
    );
    return (call.arguments as Map<Object?, Object?>)['text']! as String;
  }

  /* -------------------------------------------------------- 布局与首屏 */

  group('邀请码列表', () {
    testWidgets('窄屏用卡片列出四种状态，宽屏换成表格', (WidgetTester tester) async {
      _setScreenSize(tester, const Size(390, 844));
      repository.listResult = _fourStatusPage();

      final (Widget app, GoRouter _) = _app(repository);
      await tester.pumpWidget(app);
      await tester.pumpAndSettle();

      expect(find.byType(Card), findsNWidgets(4));
      // 窄屏不该出现桌面表格：那是「把桌面布局硬塞进手机」的典型症状。
      expect(find.byType(DataTable), findsNothing);
      expect(find.text('邀请码 #9'), findsOneWidget);
      expect(find.text('有效'), findsOneWidget);
      expect(find.text('已使用'), findsOneWidget);
      expect(find.text('已过期'), findsOneWidget);
      expect(find.text('已撤销'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('宽屏表格展示全部时间列，且时间按本地时区呈现', (WidgetTester tester) async {
      _setScreenSize(tester, const Size(1280, 800));
      final used = DateTime.utc(2026, 2, 10, 4, 30);
      repository.listResult = domainInvitationPage(
        items: <InvitationSummary>[domainInvitation(id: 9, usedAt: used)],
      );

      final (Widget app, GoRouter _) = _app(repository);
      await tester.pumpWidget(app);
      await tester.pumpAndSettle();

      expect(find.byType(DataTable), findsOneWidget);
      expect(find.byType(Card), findsNothing);
      expect(find.text('有效期至'), findsOneWidget); // 表格里它是列头
      expect(find.text('创建时间'), findsOneWidget);
      expect(find.text('使用时间'), findsOneWidget);
      expect(find.text('撤销时间'), findsOneWidget);
      // 用同一个格式化函数算出期望值：写死 '2026-02-10 12:30' 会让用例
      // 在非 UTC+8 的机器上红掉（CI 与本机时区并不保证一致）。
      expect(find.text(formatInvitationTime(used)), findsOneWidget);
      // 没发生过的时刻显示破折号，而不是空格子。
      expect(find.text('—'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('首屏只拉一次列表，且绝不会顺手批量查看明文', (WidgetTester tester) async {
      repository.listResult = _fourStatusPage();

      final (Widget app, GoRouter _) = _app(repository);
      await tester.pumpWidget(app);
      await tester.pumpAndSettle();

      expect(repository.listCalls, hasLength(1));
      expect(repository.listCalls.single.status, isNull);
      // 「列表页永不批量 reveal」是这条功能的底线：四行各来一次，
      // 就等于把四份可用凭证同时摊在屏幕上。
      expect(repository.revealRequests, isEmpty);
    });

    testWidgets('只有 active 行给出查看与撤销入口', (WidgetTester tester) async {
      _setScreenSize(tester, const Size(390, 844));
      repository.listResult = _fourStatusPage();

      final (Widget app, GoRouter _) = _app(repository);
      await tester.pumpWidget(app);
      await tester.pumpAndSettle();

      // 四行里只有 #9 是 active。
      expect(find.byTooltip('查看明文'), findsOneWidget);
      expect(find.byTooltip('撤销该邀请码'), findsOneWidget);
    });

    testWidgets('换状态筛选会重新拉取，且把状态带下去', (WidgetTester tester) async {
      _setScreenSize(tester, const Size(390, 844));
      // 列表只放一条 active：屏幕上就不会出现「已撤销」这几个字，
      // 菜单项是唯一匹配，不必靠 `.last` 去赌和状态标签的先后顺序。
      repository.listResult = domainInvitationPage();

      final (Widget app, GoRouter _) = _app(repository);
      await tester.pumpWidget(app);
      await tester.pumpAndSettle();

      await tester.tap(find.byType(DropdownButton<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('已撤销').last);
      await tester.pumpAndSettle();

      expect(repository.listCalls, hasLength(2));
      expect(repository.listCalls.last.status, InvitationStatus.revoked);
    });

    testWidgets('首次加载失败整页呈现错误并可重试', (WidgetTester tester) async {
      _setScreenSize(tester, const Size(390, 844));
      repository.listError = const ServerFailure('列表炸了', requestId: 'req-1');

      final (Widget app, GoRouter _) = _app(repository);
      await tester.pumpWidget(app);
      await tester.pumpAndSettle();

      expect(find.text('列表炸了'), findsOneWidget);
      expect(find.text('重试'), findsOneWidget);

      // 重试前把错误撤掉，验证按钮真的重新发了请求。
      repository.listError = null;
      repository.listResult = _fourStatusPage();
      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();

      expect(find.text('邀请码 #9'), findsOneWidget);
    });
  });

  /* ------------------------------------------------------------ 明文 */

  group('邀请码明文', () {
    testWidgets('查看一条后明文上屏，复制进剪贴板且反馈里不含明文', (WidgetTester tester) async {
      _setScreenSize(tester, const Size(390, 844));
      mockClipboard(tester);
      repository.listResult = _fourStatusPage();
      repository.revealResult = domainSecret(
        invitationId: 9,
        code: 'INV-SECRET-9',
      );

      final (Widget app, GoRouter _) = _app(repository);
      await tester.pumpWidget(app);
      await tester.pumpAndSettle();

      _expectNoSecretShowing();

      await tester.tap(find.byTooltip('查看明文'));
      await tester.pumpAndSettle();

      expect(repository.revealRequests, <int>[9]);
      expect(find.text('INV-SECRET-9'), findsOneWidget);

      await tester.tap(find.widgetWithText(FilledButton, '复制'));
      await tester.pumpAndSettle();

      expect(lastCopiedText(), 'INV-SECRET-9');
      // 成功反馈只是一句「已复制」，**绝不能**把明文再写一遍 ——
      // 那会被截图、被读屏念出来、被投屏给整个会议室看。
      expect(
        find.descendant(
          of: find.byType(SnackBar),
          matching: find.textContaining('INV-SECRET-9'),
        ),
        findsNothing,
      );
    });

    testWidgets('生成邀请码直接把新明文摆出来，不必再去列表里查看一次', (WidgetTester tester) async {
      _setScreenSize(tester, const Size(390, 844));
      mockClipboard(tester);
      repository.listResult = _fourStatusPage();
      repository.createResult = domainSecret(
        invitationId: 99,
        code: 'INV-NEW-99',
      );

      final (Widget app, GoRouter _) = _app(repository);
      await tester.pumpWidget(app);
      await tester.pumpAndSettle();

      // create 成功后 Controller 会刷新列表，而真实的列表响应里新码就在第一行。
      // 夹具必须照着来：列表里找不到它，Controller 会（正确地）把明文收掉，
      // 用例就会红在一个「实现没问题」的地方。
      repository.listResult = domainInvitationPage(
        items: <InvitationSummary>[
          domainInvitation(id: 99),
          domainInvitation(id: 9),
        ],
        total: 2,
      );

      await tester.tap(find.byTooltip('生成邀请码'));
      await tester.pumpAndSettle();

      // create 响应是唯一一次能拿到明文的机会，页面必须直接用上它。
      expect(repository.createRequests, hasLength(1));
      expect(repository.revealRequests, isEmpty);
      expect(find.text('INV-NEW-99'), findsOneWidget);

      await tester.tap(find.widgetWithText(FilledButton, '复制'));
      await tester.pumpAndSettle();
      expect(lastCopiedText(), 'INV-NEW-99');
    });

    testWidgets('查看另一条时旧明文立刻消失，不给「看错人」的机会', (WidgetTester tester) async {
      _setScreenSize(tester, const Size(390, 844));
      repository.listResult = domainInvitationPage(
        items: <InvitationSummary>[
          domainInvitation(id: 9),
          domainInvitation(id: 10),
        ],
        total: 2,
      );
      repository.revealResult = domainSecret(
        invitationId: 9,
        code: 'INV-SECRET-9',
      );

      final (Widget app, GoRouter _) = _app(repository);
      await tester.pumpWidget(app);
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('查看明文').first);
      await tester.pumpAndSettle();
      expect(find.text('INV-SECRET-9'), findsOneWidget);

      // 第二条的响应挂住不返回，模拟「网络还没回来」的那段时间。
      final blocker = Completer<InvitationSecret>();
      repository.queuedReveals.add(blocker.future);

      await tester.tap(find.byTooltip('查看明文').last);
      await tester.pump();

      // 旧明文必须在这一刻就消失：它还留在屏幕上，用户就会以为
      // 看到的是自己刚点的那一条，然后把它发给别人。
      expect(find.text('INV-SECRET-9'), findsNothing);
      _expectNoSecretShowing();

      blocker.complete(domainSecret(invitationId: 10, code: 'INV-SECRET-10'));
      await tester.pumpAndSettle();
      expect(find.text('INV-SECRET-10'), findsOneWidget);
    });

    testWidgets('收起按钮把明文清掉', (WidgetTester tester) async {
      _setScreenSize(tester, const Size(390, 844));
      repository.listResult = _fourStatusPage();
      repository.revealResult = domainSecret(
        invitationId: 9,
        code: 'INV-SECRET-9',
      );

      final (Widget app, GoRouter _) = _app(repository);
      await tester.pumpWidget(app);
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('查看明文'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, '收起'));
      await tester.pumpAndSettle();

      expect(find.text('INV-SECRET-9'), findsNothing);
      _expectNoSecretShowing();
    });

    testWidgets('离开页面后明文不再残留，回来也不会重新出现', (WidgetTester tester) async {
      _setScreenSize(tester, const Size(390, 844));
      repository.listResult = _fourStatusPage();
      repository.revealResult = domainSecret(
        invitationId: 9,
        code: 'INV-SECRET-9',
      );

      final (Widget app, GoRouter router) = _app(repository);
      await tester.pumpWidget(app);
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('查看明文'));
      await tester.pumpAndSettle();
      expect(find.text('INV-SECRET-9'), findsOneWidget);

      await tester.tap(find.byTooltip('返回首页'));
      await tester.pumpAndSettle();
      expect(find.text('首页'), findsOneWidget);

      router.go('/invitations');
      await tester.pumpAndSettle();

      // Controller 的生命周期跟着会话作用域而不是页面走，所以「路由离开」
      // 本身不会销毁它 —— 这条断言守的正是页面 dispose 里那次显式 clearSecret()。
      expect(find.text('INV-SECRET-9'), findsNothing);
      _expectNoSecretShowing();
      // 列表照常重新加载，说明页面本身是正常回来的。
      expect(find.text('邀请码 #9'), findsOneWidget);
    });
  });

  /* ------------------------------------------------------------ 撤销 */

  group('撤销邀请码', () {
    testWidgets('撤销要先确认，对话框只报编号与状态、不含明文', (WidgetTester tester) async {
      _setScreenSize(tester, const Size(390, 844));
      repository.listResult = _fourStatusPage();
      repository.revealResult = domainSecret(
        invitationId: 9,
        code: 'INV-SECRET-9',
      );

      final (Widget app, GoRouter _) = _app(repository);
      await tester.pumpWidget(app);
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('查看明文'));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('撤销该邀请码'));
      await tester.pumpAndSettle();

      // 列表卡片标题也叫「邀请码 #9」，所以把范围收进对话框再断言，
      // 否则找到两个也不知道是哪一个对。
      expect(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.textContaining('邀请码 #9'),
        ),
        findsOneWidget,
      );
      expect(find.textContaining('有效'), findsWidgets);
      // 弹层会被截图、被投屏 —— 明文不该出现在这里。
      expect(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.textContaining('INV-SECRET-9'),
        ),
        findsNothing,
      );
      // 还没确认，不该发请求。
      expect(repository.revokeRequests, isEmpty);

      await tester.tap(find.widgetWithText(TextButton, '取消'));
      await tester.pumpAndSettle();

      expect(repository.revokeRequests, isEmpty);
    });

    testWidgets('确认后带版本号撤销，并立刻清掉对应明文', (WidgetTester tester) async {
      _setScreenSize(tester, const Size(390, 844));
      repository.listResult = domainInvitationsWithVersion();
      repository.revealResult = domainSecret(
        invitationId: 9,
        code: 'INV-SECRET-9',
      );
      repository.revokeResult = domainInvitation(
        id: 9,
        status: InvitationStatus.revoked,
        version: 5,
        revokedAt: DateTime.utc(2026, 2, 12),
      );

      final (Widget app, GoRouter _) = _app(repository);
      await tester.pumpWidget(app);
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('查看明文'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('撤销该邀请码'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '撤销'));
      await tester.pumpAndSettle();

      // version 必须原样回传：它是乐观锁的全部依据。
      expect(repository.revokeRequests, <({int invitationId, int version})>[
        (invitationId: 9, version: 4),
      ]);
      // 撤销成功后明文立即消失 —— 它已经不是有效凭证了，
      // 继续留在屏幕上只会被人复制走。
      expect(find.text('INV-SECRET-9'), findsNothing);
      _expectNoSecretShowing();
      // 列表里那一行换成服务端回的新摘要：状态变已撤销、操作入口消失。
      expect(find.text('已撤销'), findsWidgets);
      expect(find.byTooltip('查看明文'), findsNothing);
    });

    testWidgets('撤销撞版本冲突时保留提示、并清掉可能已失效的明文', (WidgetTester tester) async {
      _setScreenSize(tester, const Size(390, 844));
      repository.listResult = _fourStatusPage();
      repository.revealResult = domainSecret(
        invitationId: 9,
        code: 'INV-SECRET-9',
      );
      repository.revokeError = const ConflictFailure(
        '邀请码已被修改',
        requestId: 'req-409',
      );

      final (Widget app, GoRouter _) = _app(repository);
      await tester.pumpWidget(app);
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('查看明文'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('撤销该邀请码'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '撤销'));
      await tester.pumpAndSettle();

      // 冲突说明这个邀请码的状态已经不掌握在我们手里了，
      // 无法确认它还有效，就不该继续把明文留在屏幕上。
      expect(find.text('INV-SECRET-9'), findsNothing);
      // 列表非空时失败只飘提示条，不把整张列表换成错误页。
      expect(find.byType(SnackBar), findsOneWidget);
      expect(find.text('数据已被其他操作修改，请刷新后重新操作'), findsOneWidget);
      expect(find.widgetWithText(SnackBarAction, '刷新'), findsOneWidget);
    });
  });

  /* ------------------------------------------------------------ 组装 */

  testWidgets('空白列表给出可操作的引导而不是一片沉默', (WidgetTester tester) async {
    _setScreenSize(tester, const Size(390, 844));
    repository.listResult = domainInvitationPage(
      items: const <InvitationSummary>[],
      total: 0,
    );

    final (Widget app, GoRouter _) = _app(repository);
    await tester.pumpWidget(app);
    await tester.pumpAndSettle();

    expect(find.textContaining('还没有邀请码'), findsOneWidget);
  });

  testWidgets('写操作在途时禁用生成按钮，防止连点建出两张', (WidgetTester tester) async {
    _setScreenSize(tester, const Size(390, 844));
    repository.listResult = _fourStatusPage();
    final blocker = Completer<InvitationSecret>();
    repository.queuedCreates.add(blocker.future);

    final (Widget app, GoRouter _) = _app(repository);
    await tester.pumpWidget(app);
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('生成邀请码'));
    // 只 pump 一帧：请求还挂在 Completer 上，写操作处于在途状态。
    await tester.pump();

    // 不能用 byTooltip 直接取 IconButton：那个 finder 命中的是 IconButton
    // 内部的 Tooltip，转不成 IconButton。按图标找才是按钮本身。
    expect(
      tester
          .widget<IconButton>(find.widgetWithIcon(IconButton, Icons.add))
          .onPressed,
      isNull,
    );

    blocker.complete(domainSecret(invitationId: 99, code: 'INV-NEW-99'));
    await tester.pumpAndSettle();

    expect(
      tester
          .widget<IconButton>(find.widgetWithIcon(IconButton, Icons.add))
          .onPressed,
      isNotNull,
    );
  });
}

/// 一份带非 1 版本号的列表：用来证明撤销回传的是**这一行的** version，
/// 而不是什么默认值。
PageResult<InvitationSummary> domainInvitationsWithVersion() =>
    domainInvitationPage(
      items: <InvitationSummary>[domainInvitation(id: 9, version: 4)],
    );
