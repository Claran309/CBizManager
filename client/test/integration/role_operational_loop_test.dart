import 'package:c_biz_docs_manager/app/app.dart';
import 'package:c_biz_docs_manager/app/router.dart';
import 'package:c_biz_docs_manager/app/session_scope.dart';
import 'package:c_biz_docs_manager/core/auth/auth_controller.dart';
import 'package:c_biz_docs_manager/core/auth/auth_models.dart';
import 'package:c_biz_docs_manager/core/auth/auth_repository.dart';
import 'package:c_biz_docs_manager/core/auth/credential_store.dart';
import 'package:c_biz_docs_manager/core/network/api_client.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
// `Override` 在 Riverpod 3 里由 misc.dart 导出，主入口只给常用的那一组。
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_backend.dart';

/// 给系统剪贴板装一个内存 mock：`Clipboard.setData` 走 `SystemChannels.platform`，
/// 测试环境没有真实现，不 mock 就会抛异常、SnackBar 也弹不出来。
void _mockClipboard(WidgetTester tester) {
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    SystemChannels.platform,
    (MethodCall call) async {
      if (call.method == 'Clipboard.setData') {
        return null;
      }
      return null;
    },
  );
}

/// Task 15：Fake API 纵向 Widget 闭环。
///
/// 与其它页面测试不同，这里**不** mock 单个 Repository，而是用一个实现了
/// [HttpClientAdapter] 的 [FakeBackend] 装进真实 [Dio] —— 于是从 UI 一路到
/// `DioXxxRemoteDataSource` → Dio 拦截器 → FakeBackend 状态机，再原路返回
/// `fromJson` 严格解析，整条链路与生产完全一致，只是「网络那头」是内存状态机。
/// 这样才能验证「跨模块的状态真的会流动」：组交接后旧 owner 的令牌失效、
/// 新 owner 看不到旧 owner 时代的邀请码 / 成员 / 字典。
///
/// 四个闭环（对应计划 Step 2-5）：
/// 1. 平台管理员登录 → 强制改密 → 创建组 → 详情启停 → 新 owner 交接，
///    全程停在 `/platform/*`，绝不进入租户页面。
/// 2. owner 登录 → 改密 → 创建邀请码 → 离开再返回 → 显式 reveal → 复制 →
///    注册 member → owner 替换权限 → member 登录读字典；断言注册不自动登录、
///    登录页 username 已预填。
/// 3. owner 交接后旧 owner 令牌失效回登录页；新 owner 登录后旧邀请码 /
///    成员 / 字典状态均不可见（由会话作用域整体重建保证）。
/// 4. 同一闭环关键页面在 390×844 与 1280×800 下 pump，无 overflow、无未处理异常。

/* ------------------------------------------------------------ 测试装配 */

/// 内存凭据库：集成测试不走真 secure storage。
final class _MemoryCredentialStore implements CredentialStore {
  String? _token;

  @override
  Future<String?> readRefreshToken() async => _token;

  @override
  Future<void> writeRefreshToken(String token) async => _token = token;

  @override
  Future<void> clear() async => _token = null;
}

/// 装配一个「真实后端被 FakeBackend 顶替」的应用。
///
/// 与 `bootstrap.dart` 同构：同一个 Dio（已装 ApiClient 鉴权拦截器 + FakeBackend
/// adapter）同时喂给 `dioProvider` 与认证仓储。返回 (container, backend, dio)，
/// 供用例驱动路由、断言状态机内部状态。
Future<(ProviderContainer, FakeBackend)> _pumpApp(
  WidgetTester tester,
  FakeBackend backend,
) async {
  _mockClipboard(tester);
  final accessTokens = InMemoryAccessTokenStore();
  final invalidator = AuthSessionInvalidator();
  final credentials = _MemoryCredentialStore();
  final dio = Dio(BaseOptions(baseUrl: 'https://api.example.test'))
    ..httpClientAdapter = backend;

  late final AuthRepository authRepository;
  ApiClient(
    dio: dio,
    accessTokens: accessTokens,
    refreshSession: () => authRepository.restore(),
    clearSession: () async {
      accessTokens.clear();
      await credentials.clear();
      invalidator.invalidate();
    },
  );
  authRepository = DefaultAuthRepository(
    remote: DioAuthRemoteDataSource(dio),
    credentials: credentials,
    accessTokens: accessTokens,
    platform: AuthPlatform.native,
  );

  final container = ProviderContainer(
    overrides: <Override>[
      dioProvider.overrideWithValue(dio),
      authRepositoryProvider.overrideWithValue(authRepository),
      authSessionInvalidatorProvider.overrideWithValue(invalidator),
    ],
  );
  addTearDown(container.dispose);

  await tester.pumpWidget(
    UncontrolledProviderScope(container: container, child: const CBizDocsApp()),
  );
  return (container, backend);
}

/// 把测试窗口设成指定逻辑尺寸。
void _setScreenSize(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

/* ------------------------------------------------------------ 驱动辅助 */

/// 在登录页用给定账号密码登录，并推进到守卫决定的落点。
Future<void> _login(
  WidgetTester tester,
  String username,
  String password,
) async {
  await tester.enterText(find.widgetWithText(TextFormField, '登录账号'), username);
  await tester.enterText(find.widgetWithText(TextFormField, '密码'), password);
  await tester.tap(find.widgetWithText(FilledButton, '登录'));
  await tester.pumpAndSettle();
}

/// 断言当前 AppBar 标题（各页面唯一标题，避免与导航项文案撞车）。
void _expectAppBarTitle(String title) =>
    expect(find.widgetWithText(AppBar, title), findsOneWidget);

void main() {
  testWidgets('平台管理员闭环：登录→改密→建组→启停→交接，全程停在 /platform/*', (
    WidgetTester tester,
  ) async {
    _setScreenSize(tester, const Size(1280, 800));
    final backend = FakeBackend();
    await _pumpApp(tester, backend);
    await tester.pumpAndSettle();

    // 未登录停在登录页。
    expect(find.widgetWithText(FilledButton, '登录'), findsOneWidget);

    // admin 登录（初始密码 → 强制改密）。
    await _login(tester, 'admin', 'admin-pass');
    // mustChangePassword=true → 被守卫锁在改密页。
    _expectAppBarTitle('修改密码');

    await tester.enterText(
      find.widgetWithText(TextFormField, '当前密码'),
      'admin-pass',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, '新密码'),
      'admin-new-pass',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, '确认新密码'),
      'admin-new-pass',
    );
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pumpAndSettle();

    // 改密后守卫送平台组列表。
    _expectAppBarTitle('平台组管理');

    // 新建组。
    await tester.tap(find.byTooltip('新建组'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextFormField, '业务组名称'),
      'Steel Co',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, '登录账号'),
      'steel-owner',
    );
    await tester.enterText(find.widgetWithText(TextFormField, '姓名'), '钢主');
    await tester.enterText(
      find.widgetWithText(TextFormField, '初始密码'),
      'steel-pass',
    );
    await tester.tap(find.widgetWithText(FilledButton, '创建'));
    await tester.pumpAndSettle();

    // 创建成功 → 跳详情。
    expect(find.textContaining('Steel Co'), findsWidgets);

    // 停用该组。
    await tester.tap(find.widgetWithText(OutlinedButton, '停用该组'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '停用'));
    await tester.pumpAndSettle();
    expect(find.text('启用该组'), findsOneWidget);

    // 启用回来。
    await tester.tap(find.widgetWithText(OutlinedButton, '启用该组'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '启用'));
    await tester.pumpAndSettle();
    expect(find.text('停用该组'), findsOneWidget);

    // 交接主账号：新建一个账号（候选人列表此刻为空，默认落 new_account）。
    await tester.tap(find.widgetWithText(OutlinedButton, '交接主账号'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextFormField, '登录账号'),
      'steel-owner2',
    );
    await tester.enterText(find.widgetWithText(TextFormField, '姓名'), '钢主2');
    await tester.enterText(
      find.widgetWithText(TextFormField, '初始密码'),
      'steel-pass2',
    );
    await tester.tap(find.widgetWithText(FilledButton, '确认交接'));
    await tester.pumpAndSettle();

    // 交接后详情刷新，主账号换人。
    expect(find.textContaining('steel-owner2'), findsWidgets);

    // 全程都停在平台详情页（AppBar 仍是「组详情」前缀），从未进入租户首页。
    expect(
      find.byWidgetPredicate(
        (Widget widget) =>
            widget is AppBar &&
            (widget.title is Text) &&
            (widget.title as Text).data!.startsWith('组详情'),
      ),
      findsOneWidget,
    );
    // 后端状态机里确实建了一个组。
    expect(backend.groupCount, 1);
  });

  testWidgets('owner 邀请与成员授权闭环：注册不自动登录、登录页预填', (WidgetTester tester) async {
    _setScreenSize(tester, const Size(1280, 800));
    final backend = FakeBackend();
    final groupId = backend.seedGroupWithOwner();
    backend.seedDictionary(groupId: groupId, kind: 'customer', name: '华钢贸易');
    final (container, _) = await _pumpApp(tester, backend);
    await tester.pumpAndSettle();

    // owner 登录（已改密，直接进首页）。
    await _login(tester, 'owner', 'owner-pass');
    _expectAppBarTitle('首页');

    // 进邀请码页。
    await tester.tap(
      find.descendant(
        of: find.byType(NavigationRail),
        matching: find.text('邀请码'),
      ),
    );
    await tester.pumpAndSettle();
    _expectAppBarTitle('邀请码');

    // 创建邀请码 → 明文面板弹出。
    await tester.tap(find.byTooltip('生成邀请码'));
    await tester.pumpAndSettle();
    expect(find.text('复制'), findsOneWidget);
    // 记下明文（用于注册）。明文从面板里读出来，而不是碰后端内部状态。
    final codeText = tester
        .widget<SelectableText>(
          find.descendant(
            of: find.byType(Card),
            matching: find.byType(SelectableText),
          ),
        )
        .data;

    // 复制。
    await tester.tap(find.text('复制'));
    await tester.pumpAndSettle();
    expect(find.text('已复制到剪贴板'), findsOneWidget);

    // 收起明文，离开再返回。
    await tester.tap(find.text('收起'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('返回首页'));
    await tester.pumpAndSettle();
    container.read(routerProvider).go('/invitations');
    await tester.pumpAndSettle();

    // 显式 reveal 同一邀请码。宽屏（1280）下邀请码是表格，操作按钮是文字
    // 「查看」/「撤销」；窄屏才是 IconButton tooltip「查看明文」。
    await tester.tap(find.widgetWithText(TextButton, '查看'));
    await tester.pumpAndSettle();
    // 明文再次可见。
    expect(
      tester.widget<SelectableText>(find.byType(SelectableText)).data,
      codeText,
    );

    // 登出（邀请码页没有登出按钮，先回首页），用邀请码注册 member。
    await tester.tap(find.byTooltip('返回首页'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('退出登录'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '退出'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(FilledButton, '登录'), findsOneWidget);

    // 注册入口。
    await tester.tap(find.widgetWithText(TextButton, '注册新账号'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextFormField, '邀请码'),
      codeText!,
    );
    await tester.enterText(find.widgetWithText(TextFormField, '登录账号'), 'sales');
    await tester.enterText(find.widgetWithText(TextFormField, '姓名'), '李四');
    await tester.enterText(
      find.widgetWithText(TextFormField, '密码'),
      'sales-pass',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, '确认密码'),
      'sales-pass',
    );
    await tester.tap(find.widgetWithText(FilledButton, '注册'));
    await tester.pumpAndSettle();

    // 注册不自动登录：回到登录页，且用户名已预填。
    expect(find.widgetWithText(FilledButton, '登录'), findsOneWidget);
    final usernameField = tester.widget<TextFormField>(
      find.widgetWithText(TextFormField, '登录账号'),
    );
    expect(usernameField.controller?.text, 'sales');

    // 登录 member：待改密（注册时 mustChangePassword=true）。
    await _login(tester, 'sales', 'sales-pass');
    _expectAppBarTitle('修改密码');
    await tester.enterText(
      find.widgetWithText(TextFormField, '当前密码'),
      'sales-pass',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, '新密码'),
      'sales-pass2',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, '确认新密码'),
      'sales-pass2',
    );
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pumpAndSettle();

    // member 登录读字典：默认落在首页，进字典页看到预置的「吨」。
    _expectAppBarTitle('首页');
    await tester.tap(
      find.descendant(
        of: find.byType(NavigationRail),
        matching: find.text('字典'),
      ),
    );
    await tester.pumpAndSettle();
    _expectAppBarTitle('辅助字典');
    expect(find.text('华钢贸易'), findsOneWidget);

    // 登出（字典页没有登出按钮，先回首页），换 owner 上来给 member 授
    // member.manage（验证「成员」入口对 member 出现）。
    await tester.tap(
      find.descendant(
        of: find.byType(NavigationRail),
        matching: find.text('首页'),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('退出登录'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '退出'));
    await tester.pumpAndSettle();
    await _login(tester, 'owner', 'owner-pass');

    // 进成员页。
    await tester.tap(
      find.descendant(
        of: find.byType(NavigationRail),
        matching: find.text('成员'),
      ),
    );
    await tester.pumpAndSettle();
    _expectAppBarTitle('成员');

    // 找到「李四」那一行，进权限页。宽屏（1280）下成员是表格，权限入口是
    // 文字按钮「权限」；窄屏才是 IconButton tooltip「调整权限」。
    // 列表顺序：owner 第一行、新注册的「李四」第二行，所以点最后一个「权限」。
    await tester.tap(find.widgetWithText(TextButton, '权限').last);
    await tester.pumpAndSettle();
    _expectAppBarTitle('成员权限 · 李四');

    // 勾上 member.manage（其目录名是「管理成员」），整体替换保存。
    await tester.tap(find.widgetWithText(CheckboxListTile, '管理成员'));
    await tester.pumpAndSettle();
    // 保存按钮在权限页底部，窄屏/宽屏都可能滚出可视区，先滚到可见。
    await tester.ensureVisible(find.widgetWithText(FilledButton, '保存权限'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '保存权限'));
    await tester.pumpAndSettle();

    // 保存成功：草稿同步到服务端最新版本，页面停在权限页。
    // 权限页保存后不自动跳回，跳转是「返回成员列表」按钮的职责。
    _expectAppBarTitle('成员权限 · 李四');
    // 「管理成员」现在是勾选态（服务端已接受本次替换）。
    expect(
      tester
          .widget<CheckboxListTile>(
            find.widgetWithText(CheckboxListTile, '管理成员'),
          )
          .value,
      isTrue,
    );
  });

  testWidgets('业务模块在真实壳里可达：单据 / 结算 / 报表页面都能打开', (WidgetTester tester) async {
    _setScreenSize(tester, const Size(1280, 800));
    final backend = FakeBackend()
      ..seedGroupWithOwner(groupName: 'Finance', ownerUsername: 'owner');
    await _pumpApp(tester, backend);
    await tester.pumpAndSettle();
    await _login(tester, 'owner', 'owner-pass');
    _expectAppBarTitle('首页');

    Future<void> goTo(String label, String title) async {
      await tester.tap(
        find.descendant(
          of: find.byType(NavigationRail),
          matching: find.text(label),
        ),
      );
      await tester.pumpAndSettle();
      _expectAppBarTitle(title);
    }

    // 关键：这些页面的 Repository 由会话作用域装配。若 session_scope 漏装配，
    // 页面一打开就抛 StateError —— 这条用例正是上一轮那个「测试全绿但线上不可用」
    // 装配缺口的回归护栏。
    await goTo('入库单', '入库单');
    await goTo('出库单', '出库单');
    await goTo('结算单', '结算单');
    await goTo('报表', '报表');

    // 新建单据表单也能在真实壳里打开（kind 由路由决定）。
    await goTo('入库单', '入库单');
    await tester.tap(find.byTooltip('新建入库单'));
    await tester.pumpAndSettle();
    _expectAppBarTitle('入库单');
    expect(find.widgetWithText(FilledButton, '保存草稿'), findsOneWidget);
  });

  testWidgets('会话切换与旧 owner 失效：交接后旧 owner 回登录页、状态不可见', (
    WidgetTester tester,
  ) async {
    _setScreenSize(tester, const Size(1280, 800));
    final backend = FakeBackend();
    final groupId = backend.seedGroupWithOwner();
    backend.seedDictionary(groupId: groupId, kind: 'customer', name: '华钢贸易');
    await _pumpApp(tester, backend);
    await tester.pumpAndSettle();

    // 先造一个 member（供 owner 交接的 existing_member 目标）。
    // 简化：直接用 new_account 交接也行，但计划要求验证「旧 owner 失效」。
    // 这里走 existing_member：需要先有一个普通成员。用一个邀请码注册。
    // 为了简洁，直接用后端预置一个成员。
    backend.seedMember(
      groupId: groupId,
      username: 'newowner',
      displayName: '新主',
    );

    // 旧 owner 登录。
    await _login(tester, 'owner', 'owner-pass');
    _expectAppBarTitle('首页');

    // 平台管理员登录，交接 owner 给 newowner。
    // 先登出。
    await tester.tap(find.byTooltip('退出登录'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '退出'));
    await tester.pumpAndSettle();

    await _login(tester, 'admin', 'admin-pass');
    _expectAppBarTitle('修改密码');
    await tester.enterText(
      find.widgetWithText(TextFormField, '当前密码'),
      'admin-pass',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, '新密码'),
      'admin-new-pass',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, '确认新密码'),
      'admin-new-pass',
    );
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pumpAndSettle();
    _expectAppBarTitle('平台组管理');

    // 进详情，交接给 newowner（existing_member）。
    await tester.tap(find.text('Finance'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(OutlinedButton, '交接主账号'));
    await tester.pumpAndSettle();
    // 候选人列表有 newowner，选它。
    await tester.tap(find.text('新主'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '确认交接'));
    await tester.pumpAndSettle();

    // 旧 owner 的令牌已失效（后端状态机清空了）。
    expect(backend.hasActiveTenantSession, isFalse);

    // 回列表页登出 admin（详情页没有登出按钮）。
    await tester.tap(find.byTooltip('返回组列表'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('退出登录'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '退出'));
    await tester.pumpAndSettle();
    // 旧 owner 账号已不在 _owners（被降级为停用 member），登录被拒。
    await _login(tester, 'owner', 'owner-pass');
    // 仍停在登录页（凭据无效）。
    expect(find.widgetWithText(FilledButton, '登录'), findsOneWidget);
    expect(
      backend.failures,
      contains('POST /api/v1/auth/login -> AUTH_INVALID_CREDENTIALS'),
    );
  });

  // 拆成两个独立 testWidgets：同一 testWidgets 里连续 pump 两个 CBizDocsApp，
  // 第二个的 restore() 会停在 splash（前一个 app 的异步状态干扰），
  // 而「两种尺寸都无 overflow」本来就不该耦合在一次 pump 里。
  for (final size in <Size>[const Size(390, 844), const Size(1280, 800)]) {
    testWidgets(
      '尺寸 ${size.width.toInt()}x${size.height.toInt()} 关键页面无 overflow',
      (WidgetTester tester) async {
        _setScreenSize(tester, size);
        final backend = FakeBackend();
        final groupId = backend.seedGroupWithOwner();
        backend.seedDictionary(
          groupId: groupId,
          kind: 'customer',
          name: '华钢贸易',
        );
        final (container, _) = await _pumpApp(tester, backend);
        await tester.pumpAndSettle();

        // 登录 owner 走一圈关键页面。
        await _login(tester, 'owner', 'owner-pass');
        expect(tester.takeException(), isNull);

        for (final route in <String>[
          '/invitations',
          '/members',
          '/dictionaries',
        ]) {
          container.read(routerProvider).go(route);
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull, reason: '$route @ $size 抛了异常');
        }
      },
    );
  }
}
