import 'package:c_biz_docs_manager/core/presentation/responsive_scaffold.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

/// 导航项顺序即真实底稿：首页、邀请码、成员、字典。
const _destinations = <AppDestination>[
  AppDestination(label: '首页', icon: Icons.home_outlined, route: '/home'),
  AppDestination(
    label: '邀请码',
    icon: Icons.vpn_key_outlined,
    route: '/invitations',
  ),
  AppDestination(label: '成员', icon: Icons.group_outlined, route: '/members'),
  AppDestination(
    label: '字典',
    icon: Icons.list_alt_outlined,
    route: '/dictionaries',
  ),
];

const _membersIndex = 2;

/// 把测试窗口设成指定逻辑尺寸。
///
/// devicePixelRatio 固定为 1，这样 physicalSize 的数值就等于逻辑像素，
/// 断言里可以直接写 390 / 1280，不用再心里换算一遍。
void _setScreenSize(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

Widget _shell({
  required String title,
  required String currentRoute,
  List<Widget> actions = const <Widget>[],
}) => ResponsiveScaffold(
  title: title,
  destinations: _destinations,
  currentRoute: currentRoute,
  actions: actions,
  body: Text('正文-$currentRoute'),
);

void main() {
  group('窄屏（390x844）', () {
    testWidgets('使用 AppBar + NavigationBar，且不出现 NavigationRail', (
      WidgetTester tester,
    ) async {
      _setScreenSize(tester, const Size(390, 844));

      await tester.pumpWidget(
        MaterialApp(
          home: _shell(title: '成员', currentRoute: '/members'),
        ),
      );

      expect(find.byType(AppBar), findsOneWidget);
      expect(find.byType(NavigationBar), findsOneWidget);
      expect(find.byType(NavigationRail), findsNothing);
      expect(find.text('成员'), findsWidgets);
      // 横向 overflow 会被 flutter_test 记成异常，这里显式收口。
      expect(tester.takeException(), isNull);
    });

    testWidgets('四个导航项都渲染出来，并高亮当前地址', (WidgetTester tester) async {
      _setScreenSize(tester, const Size(390, 844));

      await tester.pumpWidget(
        MaterialApp(
          home: _shell(title: '成员', currentRoute: '/members'),
        ),
      );

      final bar = tester.widget<NavigationBar>(find.byType(NavigationBar));
      expect(bar.destinations, hasLength(_destinations.length));
      expect(bar.selectedIndex, _membersIndex);
    });

    testWidgets('详情页会把它的列表页点亮', (WidgetTester tester) async {
      _setScreenSize(tester, const Size(390, 844));

      await tester.pumpWidget(
        MaterialApp(
          home: _shell(title: '成员权限', currentRoute: '/members/7/permissions'),
        ),
      );

      final bar = tester.widget<NavigationBar>(find.byType(NavigationBar));
      expect(bar.selectedIndex, _membersIndex);
    });

    testWidgets('地址不属于任何导航项时退回第一项（NavigationBar 不接受空选中）', (
      WidgetTester tester,
    ) async {
      _setScreenSize(tester, const Size(390, 844));

      await tester.pumpWidget(
        MaterialApp(
          home: _shell(title: '未知', currentRoute: '/unknown'),
        ),
      );

      final bar = tester.widget<NavigationBar>(find.byType(NavigationBar));
      expect(bar.selectedIndex, 0);
    });
  });

  group('宽屏（1280x800）', () {
    testWidgets('使用 NavigationRail + 分隔线，且不出现 NavigationBar', (
      WidgetTester tester,
    ) async {
      _setScreenSize(tester, const Size(1280, 800));

      await tester.pumpWidget(
        MaterialApp(
          home: _shell(title: '成员', currentRoute: '/members'),
        ),
      );

      expect(find.byType(NavigationRail), findsOneWidget);
      expect(find.byType(NavigationBar), findsNothing);
      expect(find.byType(VerticalDivider), findsOneWidget);
      expect(find.byType(Expanded), findsWidgets);
      expect(tester.takeException(), isNull);
    });

    testWidgets('侧栏高亮当前地址，且无匹配时允许空选中', (WidgetTester tester) async {
      _setScreenSize(tester, const Size(1280, 800));

      await tester.pumpWidget(
        MaterialApp(
          home: _shell(title: '成员权限', currentRoute: '/members/7/permissions'),
        ),
      );
      expect(
        tester
            .widget<NavigationRail>(find.byType(NavigationRail))
            .selectedIndex,
        _membersIndex,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: _shell(title: '未知', currentRoute: '/unknown'),
        ),
      );
      // NavigationRail 的 selectedIndex 可为 null，语义上"没有选中项"
      // 比"假装选中第一项"更准确。
      expect(
        tester
            .widget<NavigationRail>(find.byType(NavigationRail))
            .selectedIndex,
        isNull,
      );
    });

    testWidgets('断点两侧切换会换掉导航形态', (WidgetTester tester) async {
      _setScreenSize(tester, const Size(719, 800));
      await tester.pumpWidget(
        MaterialApp(
          home: _shell(title: '成员', currentRoute: '/members'),
        ),
      );
      expect(find.byType(NavigationBar), findsOneWidget);

      _setScreenSize(tester, const Size(720, 800));
      await tester.pumpWidget(
        MaterialApp(
          home: _shell(title: '成员', currentRoute: '/members'),
        ),
      );
      expect(find.byType(NavigationRail), findsOneWidget);
      expect(find.byType(NavigationBar), findsNothing);
    });
  });

  group('无障碍与动作按钮', () {
    testWidgets('图标按钮缺少 tooltip 会在开发期直接抛断言', (WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: _shell(
            title: '成员',
            currentRoute: '/members',
            actions: <Widget>[
              IconButton(onPressed: () {}, icon: const Icon(Icons.add)),
            ],
          ),
        ),
      );

      expect(tester.takeException(), isA<AssertionError>());
    });

    testWidgets('带 tooltip 的图标按钮可以正常渲染', (WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: _shell(
            title: '成员',
            currentRoute: '/members',
            actions: <Widget>[
              IconButton(
                tooltip: '新建成员',
                onPressed: () {},
                icon: const Icon(Icons.add),
              ),
            ],
          ),
        ),
      );

      expect(tester.takeException(), isNull);
      expect(find.byType(IconButton), findsOneWidget);
    });

    testWidgets('导航项带 tooltip 与语义标签', (WidgetTester tester) async {
      _setScreenSize(tester, const Size(390, 844));

      await tester.pumpWidget(
        MaterialApp(
          home: _shell(title: '成员', currentRoute: '/members'),
        ),
      );

      final bar = tester.widget<NavigationBar>(find.byType(NavigationBar));
      expect(
        <String?>[
          for (final destination in bar.destinations)
            (destination as NavigationDestination).tooltip,
        ],
        <String?>['首页', '邀请码', '成员', '字典'],
      );
    });
  });

  group('导航跳转', () {
    /// 只在底部导航栏里找标签，避免误点到 AppBar 标题上——
    /// 那样点击会落在不可交互的位置，用例会「因为什么都没发生而通过」。
    Finder navItem(String label) => find
        .descendant(of: find.byType(NavigationBar), matching: find.text(label))
        .first;

    Widget routerApp() {
      final router = GoRouter(
        initialLocation: '/members',
        routes: <RouteBase>[
          GoRoute(
            path: '/members',
            builder: (BuildContext context, GoRouterState state) =>
                _shell(title: '成员', currentRoute: '/members'),
          ),
          GoRoute(
            path: '/dictionaries',
            builder: (BuildContext context, GoRouterState state) =>
                _shell(title: '字典', currentRoute: '/dictionaries'),
          ),
        ],
      );
      addTearDown(router.dispose);
      return MaterialApp.router(routerConfig: router);
    }

    testWidgets('点击导航项跳到对应路由', (WidgetTester tester) async {
      _setScreenSize(tester, const Size(390, 844));

      await tester.pumpWidget(routerApp());
      expect(find.text('正文-/members'), findsOneWidget);

      await tester.tap(navItem('字典'));
      await tester.pumpAndSettle();

      expect(find.text('正文-/dictionaries'), findsOneWidget);
      expect(find.text('正文-/members'), findsNothing);
    });

    testWidgets('点击当前项不会重新导航', (WidgetTester tester) async {
      _setScreenSize(tester, const Size(390, 844));

      await tester.pumpWidget(routerApp());

      // 点自己不该重建页面：那会丢掉滚动位置与未提交的表单。
      await tester.tap(navItem('成员'));
      await tester.pumpAndSettle();

      expect(find.text('正文-/members'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
