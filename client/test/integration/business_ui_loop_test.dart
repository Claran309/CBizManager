import 'package:c_biz_docs_manager/app/app.dart';
import 'package:c_biz_docs_manager/app/session_scope.dart';
import 'package:c_biz_docs_manager/core/auth/auth_controller.dart';
import 'package:c_biz_docs_manager/core/auth/auth_models.dart';
import 'package:c_biz_docs_manager/core/auth/auth_repository.dart';
import 'package:c_biz_docs_manager/core/auth/credential_store.dart';
import 'package:c_biz_docs_manager/core/network/api_client.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
// `Override` 在 Riverpod 3 里由 misc.dart 导出。
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_backend.dart';

/// 业务全链路 UI 闭环：建单 → 提交 → 申请结算 → 审批 → 登记付款 → 看结清。
///
/// 与 `document_settlement_loop_test`（驱动 Repository）互补：这里**全部通过真实
/// 页面**操作 —— 真实 `CBizDocsApp` + 真实路由 + 真实鉴权拦截器 + 假后端状态机。
/// 它验证的不只是契约，还有「页面之间真的接得上」：表单提交后单据出现在结算候选里、
/// 结算提交后跳到详情、审批后状态变化、登记付款后结清视图的未付款下降。
void main() {
  testWidgets('owner 从 UI 走通 建单→结算→审批→登记付款', (WidgetTester tester) async {
    _setScreenSize(tester, const Size(1280, 800));
    final backend = FakeBackend()
      ..seedGroupWithOwner(groupName: 'Finance', ownerUsername: 'owner');
    await _pumpApp(tester, backend);
    await tester.pumpAndSettle();
    // 1. 登录 owner。
    await tester.enterText(find.widgetWithText(TextFormField, '登录账号'), 'owner');
    await tester.enterText(
      find.widgetWithText(TextFormField, '密码'),
      'owner-pass',
    );
    await tester.tap(find.widgetWithText(FilledButton, '登录'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(AppBar, '首页'), findsOneWidget);

    // 2. 新建入库单并直接提交（10 × 10000 = 100000.00）。
    await _goTo(tester, '入库单', '入库单');
    await tester.tap(find.byTooltip('新建入库单'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, '入库公司'), '华东钢贸');
    await tester.enterText(find.widgetWithText(TextField, '品名'), '螺纹钢');
    await tester.enterText(find.widgetWithText(TextField, '数量'), '10.000');
    await tester.enterText(find.widgetWithText(TextField, '单价'), '10000.0000');
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(OutlinedButton, '提交'));
    await tester.pumpAndSettle();

    // 提交后列表里能查到这张已提交的单据（列表按提交态可见）。
    await _goTo(tester, '入库单', '入库单');
    expect(find.textContaining('RK'), findsWidgets);

    // 3. 申请结算：勾选刚建的单据并提交。
    await _goTo(tester, '结算单', '结算单');
    await tester.tap(find.byTooltip('申请结算'));
    await tester.pumpAndSettle();
    expect(find.byType(CheckboxListTile), findsOneWidget);
    await tester.tap(find.byType(CheckboxListTile));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '提交结算申请（已选 1 张）'));
    await tester.pumpAndSettle();

    // 4. 跳到结算详情，审批通过。
    expect(find.widgetWithText(AppBar, '结算单详情'), findsOneWidget);
    expect(find.text('待审批'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, '通过'));
    await tester.pumpAndSettle();
    expect(find.text('审批通过'), findsWidgets);
    // 终态：审批按钮消失。
    expect(find.widgetWithText(FilledButton, '通过'), findsNothing);

    // 5. 回到入库单，打开结清视图登记付款。
    await _goTo(tester, '入库单', '入库单');
    await tester.tap(find.text('结清').first);
    await tester.pumpAndSettle();
    expect(find.widgetWithText(AppBar, '结清视图'), findsOneWidget);
    // 尚未登记：已付 0、未付等于单据总额。
    expect(find.text('0.00'), findsWidgets);
    expect(find.text('100000.00'), findsWidgets);

    await tester.tap(find.widgetWithText(FilledButton, '登记付款'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, '金额'), '30000.00');
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '登记'));
    await tester.pumpAndSettle();

    // 6. 结清视图派生金额随登记更新（服务端算，客户端直显）。
    expect(find.text('30000.00'), findsWidgets);
    expect(find.text('70000.00'), findsWidgets);
  });
}

/* ---------------------------------------------------------------- 装配 */

void _setScreenSize(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

/// 点导航项并断言落在目标页。
Future<void> _goTo(WidgetTester tester, String label, String title) async {
  await tester.tap(
    find.descendant(
      of: find.byType(NavigationRail),
      matching: find.text(label),
    ),
  );
  await tester.pumpAndSettle();
  expect(find.widgetWithText(AppBar, title), findsOneWidget);
}

/// 装配「真实 app 壳 + 假后端」。
Future<void> _pumpApp(WidgetTester tester, FakeBackend backend) async {
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
}

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
