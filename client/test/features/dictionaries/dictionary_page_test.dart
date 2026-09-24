import 'dart:convert';

import 'package:c_biz_docs_manager/core/auth/auth_controller.dart';
import 'package:c_biz_docs_manager/core/auth/auth_models.dart';
import 'package:c_biz_docs_manager/core/auth/auth_repository.dart';
import 'package:c_biz_docs_manager/core/error/app_failure.dart';
import 'package:c_biz_docs_manager/features/dictionaries/application/dictionary_controller.dart';
import 'package:c_biz_docs_manager/features/dictionaries/domain/dictionary_entry.dart';
import 'package:c_biz_docs_manager/features/dictionaries/presentation/dictionaries_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
// `Override` 在 Riverpod 3 里由 misc.dart 导出，主入口只给常用的那一组。
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import '../../support/auth_fixtures.dart';
import '../../support/dictionary_fixtures.dart';
import '../../support/fake_dictionary_repository.dart';

/// 只关心「会话是谁」的认证仓储替身；登录 / 注册 / 改密不属于本文件的关注点。
///
/// 字典页要读 `authControllerProvider` 才知道「这个身份能不能写」，
/// 而界面裁剪必须由用例说了算 —— 所以身份从这里灌进去。
final class _SessionAuthRepository implements AuthRepository {
  const _SessionAuthRepository(this._session);

  final AuthSession _session;

  @override
  Future<AuthSession> login(String username, String password) async => _session;

  @override
  Future<AuthSession> restore() async => _session;

  @override
  Future<void> logout() async {}

  @override
  Future<RegistrationResult> register(RegistrationDraft draft) =>
      throw UnsupportedError('字典页面测试不覆盖注册');

  @override
  Future<AuthSession> changePassword(
    String currentPassword,
    String newPassword,
  ) => throw UnsupportedError('字典页面测试不覆盖改密');
}

/// 把测试窗口设成指定逻辑尺寸（devicePixelRatio 固定 1，数值即逻辑像素）。
void _setScreenSize(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

/// 只搭字典页与首页两条路由的最小应用。
///
/// 刻意**不**套 `CBizDocsApp`：那会由会话作用域把真实 Dio 装配进
/// `dictionaryRepositoryProvider`，用例就会去发真请求。页面本身不关心是谁装的仓储，
/// 所以这里直接把假仓储覆盖进去。
Future<ProviderContainer> _pumpApp(
  WidgetTester tester,
  FakeDictionaryRepository repository, {
  required AuthSession session,
}) async {
  final router = GoRouter(
    initialLocation: '/dictionaries',
    routes: <RouteBase>[
      GoRoute(
        path: '/dictionaries',
        builder: (BuildContext context, GoRouterState state) =>
            const DictionariesPage(),
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
      dictionaryRepositoryProvider.overrideWithValue(repository),
      authRepositoryProvider.overrideWithValue(_SessionAuthRepository(session)),
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

/// 打开某个下拉并点它的某一项。
///
/// 用 `.last` 而不是「唯一匹配」：下拉**打开后**，按钮自己显示的那一项（当前值）
/// 会和菜单里的同一项一起命中 `find.text(label)`，唯一匹配的写法会直接
/// `Found 2 widgets` 报错。实测一个初始值为 `A`、选项为 `A`/`B` 的下拉：
/// 关闭态 `A=1 / B=0`，打开态 `A=2 / B=1` —— 也就是说会撞上重复的只有
/// 「点回当前已选中的那一项」，点其它项仍然只有一个匹配。
/// 而弹出的菜单走在 overlay 上的新路由、遍历顺序排在页面内容之后，
/// 所以「刚弹出的那一项」永远是最后一个匹配，`.last` 在两种场景下都对。
Future<void> _tapMenuItem(WidgetTester tester, String label) async {
  await tester.tap(find.text(label).last);
  await tester.pumpAndSettle();
}

/// 切换顶部的 kind 下拉。
Future<void> _selectKind(WidgetTester tester, DictionaryKind kind) async {
  await tester.tap(find.byType(DropdownButton<DictionaryKind>));
  await tester.pumpAndSettle();
  await _tapMenuItem(tester, kind.label);
}

/// 把 SnackBar 的自动关闭定时器跑完（**可选清理**，不是必需项）。
///
/// SnackBar 4 秒后自己消失，那确实是个真实定时器；但实测表明**不等它跑完
/// 用例也不会变红**（收尾不会报「还有定时器没结束」）。留着它是为了让用例
/// 在「屏幕上什么都不剩」的干净状态下结束，属于防御性清理。
Future<void> _settleSnackBar(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 5));
  await tester.pumpAndSettle();
}

/// 名称输入框（表单里第一个 `TextFormField`；联系电话排在它后面）。
Finder _nameField() => find.byType(TextFormField).first;

/// 伪造一个「长得像 JWT」的令牌，载荷里写着客户端**绝不该相信**的权限声明。
///
/// 用来钉住那条铁律：界面裁剪只认 `/auth/me` 下发的 `permission_codes`，
/// 绝不本地解码令牌去猜身份（令牌载荷客户端可读可改）。
String _forgedToken(String permissionCode) {
  String segment(Object payload) =>
      base64Url.encode(utf8.encode(jsonEncode(payload))).replaceAll('=', '');
  return '${segment(<String, Object?>{'alg': 'none'})}.'
      '${segment(<String, Object?>{
        'permissions': <String>[permissionCode],
      })}'
      '.signature';
}

void main() {
  late FakeDictionaryRepository repository;

  setUp(() => repository = FakeDictionaryRepository());

  /* ------------------------------------------------------------- 六 kind 共页 */

  group('字典页 · 六种 kind 共用一页', () {
    testWidgets('切换 kind 就按该 kind 重新查询，没有第二个入口', (WidgetTester tester) async {
      _setScreenSize(tester, const Size(390, 844));
      repository.entries = const <DictionaryEntry>[controllerDictionaryEntry];

      await _pumpApp(tester, repository, session: ownerSession());

      // 默认落在客户：填写单据时最常维护的就是它。
      expect(
        repository.lastQueryFor(DictionaryKind.customer)?.kind,
        DictionaryKind.customer,
      );

      for (final kind in DictionaryKind.values) {
        await _selectKind(tester, kind);
        expect(
          repository.lastQueryFor(kind)?.kind,
          kind,
          reason: '切到「${kind.label}」之后应当按「${kind.label}」查询',
        );
      }
      // 六种 kind 共用一页：下拉只有一个，没有「品名页 / 单位页」这种分散入口。
      expect(find.byType(DropdownButton<DictionaryKind>), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('窄屏用卡片、宽屏用表格，两种布局都不 overflow', (WidgetTester tester) async {
      _setScreenSize(tester, const Size(390, 844));
      repository.entries = <DictionaryEntry>[
        controllerDictionaryEntry,
        buildDictionaryEntry(
          id: 6,
          name: 'Customer B',
          contactPhone: '13800000000',
        ),
      ];

      await _pumpApp(tester, repository, session: ownerSession());

      expect(find.byType(Card), findsNWidgets(2));
      expect(find.byType(DataTable), findsNothing);
      // 客户才有联系电话：它应当真的出现在行里，而不是只存在于契约里。
      expect(find.text('13800000000'), findsOneWidget);
      expect(tester.takeException(), isNull);

      // 换成宽屏再看一次：切布局最容易在另一套分支上炸出 overflow。
      _setScreenSize(tester, const Size(1280, 800));
      await tester.pumpAndSettle();

      expect(find.byType(DataTable), findsOneWidget);
      expect(find.byType(Card), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('型号那一行显示所属品名，品名不在候选里就如实显示编号', (WidgetTester tester) async {
      _setScreenSize(tester, const Size(390, 844));
      repository.byKind[DictionaryKind.productName] = const <DictionaryEntry>[
        newerDictionaryEntry,
      ];
      repository.byKind[DictionaryKind.productModel] = <DictionaryEntry>[
        productModelDictionaryEntry,
        // 父级 id 对不上任何候选：多半是那条品名刚被别处停用了。
        buildDictionaryEntry(
          id: 9,
          kind: DictionaryKind.productModel,
          name: 'HRB500 Φ32',
          parentId: 999,
        ),
      ];

      await _pumpApp(tester, repository, session: ownerSession());
      await _selectKind(tester, DictionaryKind.productModel);

      expect(find.text('Product A'), findsOneWidget);
      // 编一个名字出来会让用户以为这条型号挂得好好的，所以只报编号。
      expect(find.text('品名 #999'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  /* --------------------------------------------------------- 写入口按权限裁剪 */

  group('字典页 · 写入口按权限裁剪', () {
    testWidgets('组主账号拿得到新增 / 编辑 / 启停与状态筛选', (WidgetTester tester) async {
      _setScreenSize(tester, const Size(390, 844));
      repository.entries = const <DictionaryEntry>[controllerDictionaryEntry];

      await _pumpApp(tester, repository, session: ownerSession());

      expect(find.byTooltip('新增客户'), findsOneWidget);
      expect(find.byTooltip('编辑'), findsOneWidget);
      expect(find.byType(PopupMenuButton<DictionaryStatus>), findsOneWidget);
      // 「已停用」筛选需要 dictionary.manage，所以它对主账号可见。
      expect(
        find.widgetWithText(DropdownButton<String>, '启用中'),
        findsOneWidget,
      );
    });

    testWidgets('持 dictionary.manage 的普通成员同样看得到写入口', (
      WidgetTester tester,
    ) async {
      _setScreenSize(tester, const Size(390, 844));
      repository.entries = const <DictionaryEntry>[controllerDictionaryEntry];

      await _pumpApp(
        tester,
        repository,
        session: memberSession(
          permissionCodes: const <String>['dictionary.manage'],
        ),
      );

      expect(find.byTooltip('新增客户'), findsOneWidget);
      expect(find.byTooltip('编辑'), findsOneWidget);
      expect(find.byType(PopupMenuButton<DictionaryStatus>), findsOneWidget);
    });

    testWidgets('没有 dictionary.manage 的普通成员是一个纯只读页', (
      WidgetTester tester,
    ) async {
      _setScreenSize(tester, const Size(390, 844));
      repository.entries = const <DictionaryEntry>[controllerDictionaryEntry];

      await _pumpApp(tester, repository, session: memberSession());

      // 只读用户要能看：填单时得知道有哪些客户可选。
      expect(find.text('Customer A'), findsOneWidget);
      // 但一个写入口都不给 —— 不是「点了报 403」，是根本不出现。
      expect(find.byTooltip('新增客户'), findsNothing);
      expect(find.byTooltip('编辑'), findsNothing);
      expect(find.byType(PopupMenuButton<DictionaryStatus>), findsNothing);
      // 连「已停用」这个筛选都不给：显式筛它需要 dictionary.manage，
      // 摆出来等于请用户去点一个必然被拒的选项。
      expect(find.byType(DropdownButton<String>), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('令牌载荷里写着权限码也换不来写入口（只认 /auth/me）', (WidgetTester tester) async {
      _setScreenSize(tester, const Size(390, 844));
      repository.entries = const <DictionaryEntry>[controllerDictionaryEntry];

      final profile = memberProfile();
      // 断言前提：这份身份确实没有写权限。
      expect(profile.permissionCodes, isEmpty);

      await _pumpApp(
        tester,
        repository,
        session: AuthSession(
          // 令牌被改过：载荷里明明白白写着 dictionary.manage。
          accessToken: _forgedToken('dictionary.manage'),
          profile: profile,
        ),
      );

      // 令牌载荷客户端可读可改，拿它做界面裁剪等于把权限交给攻击者。
      expect(find.byTooltip('新增客户'), findsNothing);
      expect(find.byTooltip('编辑'), findsNothing);
      expect(find.byType(PopupMenuButton<DictionaryStatus>), findsNothing);
    });
  });

  /* ------------------------------------------------------------- 筛选与口径 */

  group('字典页 · 筛选口径', () {
    testWidgets('「启用中」用 null 表达，选「已停用」才显式带上 status', (
      WidgetTester tester,
    ) async {
      _setScreenSize(tester, const Size(1280, 800));
      repository.entries = const <DictionaryEntry>[controllerDictionaryEntry];

      await _pumpApp(tester, repository, session: ownerSession());

      // 契约里根本没有「两种状态一起返回」的取值，所以默认口径是
      // 「只看启用中」，对应查询参数为 null。
      expect(repository.queries.single.status, isNull);

      await tester.tap(find.byType(DropdownButton<String>));
      await tester.pumpAndSettle();
      await _tapMenuItem(tester, '已停用');

      expect(repository.queries.last.status, DictionaryStatus.disabled);
    });

    testWidgets('型号页会并发拉父级候选，并按父级筛选', (WidgetTester tester) async {
      _setScreenSize(tester, const Size(1280, 800));
      repository.byKind[DictionaryKind.productName] = const <DictionaryEntry>[
        newerDictionaryEntry,
      ];
      repository.byKind[DictionaryKind.productModel] = const <DictionaryEntry>[
        productModelDictionaryEntry,
      ];

      await _pumpApp(tester, repository, session: ownerSession());
      await _selectKind(tester, DictionaryKind.productModel);

      // 父级候选只有型号用得上，但它是**必须**拉的：既填筛选下拉，
      // 也用来把行里的 parent_id 翻译成品名。
      expect(
        repository.lastQueryFor(DictionaryKind.productName)?.kind,
        DictionaryKind.productName,
      );
      // 默认「全部品名」不带 parent_id。
      expect(
        repository.lastQueryFor(DictionaryKind.productModel)?.parentId,
        isNull,
      );

      await tester.tap(find.widgetWithText(DropdownButton<String>, '全部品名'));
      await tester.pumpAndSettle();
      await _tapMenuItem(tester, 'Product A');

      expect(repository.lastQueryFor(DictionaryKind.productModel)?.parentId, 6);
      expect(tester.takeException(), isNull);
    });
  });

  /* ----------------------------------------------------------------- 写操作 */

  group('字典 editor', () {
    testWidgets('新增客户提交名称与联系电话', (WidgetTester tester) async {
      _setScreenSize(tester, const Size(390, 844));
      repository.entries = const <DictionaryEntry>[controllerDictionaryEntry];

      await _pumpApp(tester, repository, session: ownerSession());

      await tester.tap(find.byTooltip('新增客户'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(AlertDialog, '新增客户'), findsOneWidget);

      await tester.enterText(_nameField(), 'Customer B');
      await tester.enterText(find.byType(TextFormField).last, '13800000000');
      await tester.tap(find.widgetWithText(FilledButton, '保存'));
      await tester.pumpAndSettle();

      final draft = repository.createDrafts.single;
      expect(draft.kind, DictionaryKind.customer);
      expect(draft.name, 'Customer B');
      expect(draft.contactPhone, '13800000000');
      // 客户不能带 parent_id：后端对客户的 parent_id 一律判非法。
      expect(draft.parentId, isNull);

      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text('Customer B'), findsOneWidget);
      expect(find.text('已新增客户'), findsOneWidget);
      await _settleSnackBar(tester);
    });

    testWidgets('新增单位一个多余字段都不提交', (WidgetTester tester) async {
      _setScreenSize(tester, const Size(390, 844));
      repository.byKind[DictionaryKind.unit] = <DictionaryEntry>[
        buildDictionaryEntry(id: 20, kind: DictionaryKind.unit, name: '吨'),
      ];
      repository.entries = const <DictionaryEntry>[controllerDictionaryEntry];

      await _pumpApp(tester, repository, session: ownerSession());
      await _selectKind(tester, DictionaryKind.unit);

      await tester.tap(find.byTooltip('新增单位'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(AlertDialog, '新增单位'), findsOneWidget);
      // 联系电话只有客户能带：给单位摆一个出来，用户填了必然被服务端拒绝。
      expect(find.text('联系电话'), findsNothing);

      await tester.enterText(_nameField(), '件');
      await tester.tap(find.widgetWithText(FilledButton, '保存'));
      await tester.pumpAndSettle();

      final draft = repository.createDrafts.single;
      expect(draft.kind, DictionaryKind.unit);
      expect(draft.name, '件');
      expect(draft.contactPhone, isNull);
      expect(draft.parentId, isNull);
      await _settleSnackBar(tester);
    });

    testWidgets('编辑带的是这一行的版本号', (WidgetTester tester) async {
      _setScreenSize(tester, const Size(390, 844));
      repository.entries = const <DictionaryEntry>[controllerDictionaryEntry];

      await _pumpApp(tester, repository, session: ownerSession());

      await tester.tap(find.byTooltip('编辑'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(AlertDialog, '编辑客户'), findsOneWidget);
      // 表单由这一行播种，用户看到的就是他点的那一条。
      final nameField = tester.widget<TextFormField>(_nameField());
      expect(nameField.controller?.text, 'Customer A');

      await tester.enterText(_nameField(), 'Customer A2');
      await tester.tap(find.widgetWithText(FilledButton, '保存'));
      await tester.pumpAndSettle();

      final write = repository.updateWrites.single;
      expect(write.id, 5);
      // 乐观锁要的是「用户看到的那个版本」—— 列表里这一行恰好拿着它。
      expect(write.version, 1);
      expect(write.draft.name, 'Customer A2');
      expect(find.text('Customer A2'), findsOneWidget);
      await _settleSnackBar(tester);
    });

    testWidgets('型号必须选父级：没选就本地拦住，一个请求都不发', (WidgetTester tester) async {
      _setScreenSize(tester, const Size(390, 844));
      repository.byKind[DictionaryKind.productName] = const <DictionaryEntry>[
        newerDictionaryEntry,
      ];
      repository.byKind[DictionaryKind.productModel] = const <DictionaryEntry>[
        productModelDictionaryEntry,
      ];

      await _pumpApp(tester, repository, session: ownerSession());
      await _selectKind(tester, DictionaryKind.productModel);

      await tester.tap(find.byTooltip('新增型号'));
      await tester.pumpAndSettle();

      await tester.enterText(_nameField(), 'HRB400 Φ25');
      await tester.tap(find.widgetWithText(FilledButton, '保存'));
      await tester.pumpAndSettle();

      // 型号的父级是必填的，本地就能判定：没必要让用户白等一个往返换回
      // 一句 DICTIONARY_PARENT_INVALID。
      expect(repository.createCalls, 0);
      expect(find.text('请选择型号所属品名'), findsOneWidget);
      expect(find.byType(AlertDialog), findsOneWidget);

      // 选上父级就能存下去了。
      await tester.tap(find.byType(DropdownButtonFormField<int>));
      await tester.pumpAndSettle();
      await _tapMenuItem(tester, 'Product A');
      await tester.tap(find.widgetWithText(FilledButton, '保存'));
      await tester.pumpAndSettle();

      final draft = repository.createDrafts.single;
      expect(draft.kind, DictionaryKind.productModel);
      expect(draft.parentId, 6);
      await _settleSnackBar(tester);
    });

    testWidgets('撞版本冲突只重读、不自动重提，并关掉对话框', (WidgetTester tester) async {
      _setScreenSize(tester, const Size(390, 844));
      repository.entries = const <DictionaryEntry>[controllerDictionaryEntry];

      await _pumpApp(tester, repository, session: ownerSession());
      repository.writeError = const ConflictFailure('版本过期');

      await tester.tap(find.byTooltip('编辑'));
      await tester.pumpAndSettle();
      await tester.enterText(_nameField(), 'Customer A2');
      await tester.tap(find.widgetWithText(FilledButton, '保存'));
      await tester.pumpAndSettle();

      // 初始一次 + 冲突后重读一次。
      expect(repository.queries, hasLength(2));
      // 只提交过一次：**绝不自动重提** —— 那等于替用户做了一个
      // 他并不知道自己在做的决定（还要带上一个他已经没看过的版本）。
      expect(repository.updateWrites, hasLength(1));
      // 手里那个 version 已经作废，重试必然再失败，所以关闭对话框，
      // 让用户对着最新数据重新决定。
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text('数据已被其他操作修改，请刷新后重新操作'), findsOneWidget);
      await _settleSnackBar(tester);
    });

    testWidgets('停用后条目从「启用中」的列表里摘掉', (WidgetTester tester) async {
      _setScreenSize(tester, const Size(390, 844));
      repository.entries = const <DictionaryEntry>[controllerDictionaryEntry];

      await _pumpApp(tester, repository, session: ownerSession());

      await tester.tap(find.byType(PopupMenuButton<DictionaryStatus>));
      await tester.pumpAndSettle();
      await _tapMenuItem(tester, '已停用');
      await tester.tap(find.widgetWithText(FilledButton, '确定'));
      await tester.pumpAndSettle();

      final write = repository.statusWrites.single;
      expect(write.id, 5);
      expect(write.status, DictionaryStatus.disabled);
      expect(write.version, 1);

      // 默认口径是「只看启用中」，停用之后它就不该留在列表里 ——
      // 留着（还挂着「已停用」标签）会让用户以为筛选没生效。
      expect(find.text('Customer A'), findsNothing);
      expect(find.byType(Card), findsNothing);
      expect(find.text('还没有客户'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
