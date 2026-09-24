import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

/// 一个导航目标。
///
/// 只描述「叫什么、长什么样、去哪」，不关心当前是宽屏还是窄屏——
/// 同一份列表在两种布局下都要用，所以不能把布局信息塞进来。
final class AppDestination {
  const AppDestination({
    required this.label,
    required this.icon,
    required this.route,
  });

  /// 导航项文字。同时用作无障碍标签：移动端图标本身没有文字，
  /// 没有 label 的导航项对读屏用户就等于不存在。
  final String label;

  final IconData icon;

  /// 目标路由（GoRouter 的 location），例如 `/members`。
  final String route;
}

/// 窄屏 / 宽屏的宽度分界（逻辑像素）。
///
/// 720 是「手机横屏 / 小平板」附近的位置：再窄就只能塞下底部几个大按钮，
/// 再宽就该把导航移到侧边、把纵向空间还给内容。
const double kResponsiveScaffoldBreakpoint = 720;

/// 通用响应式功能壳：一块内容，两种导航形态。
///
/// - 窄屏（< [kResponsiveScaffoldBreakpoint]）：`Scaffold + AppBar + NavigationBar`
///   —— 拇指可达，单手能用。
/// - 宽屏（>= 断点）：`Scaffold + AppBar + NavigationRail | VerticalDivider | body`
///   —— 导航常驻侧边，正文拿到整块高度，适合后台长时间操作。
///
/// 内容（[body]）本身不在这里做裁剪：设计上要求「不把桌面表格硬塞进手机」，
/// 那是各页面自己的责任，壳只负责给它多少空间。
final class ResponsiveScaffold extends StatelessWidget {
  const ResponsiveScaffold({
    required this.title,
    required this.destinations,
    required this.currentRoute,
    required this.body,
    this.actions = const <Widget>[],
    super.key,
  });

  final String title;

  /// 当前身份**可见的**导航项。
  ///
  /// 这里传什么，用户就看到什么：普通成员不该看到管理入口，就不该传进来。
  /// 隐藏入口只是体验与减噪，真正的授权在后端，前端不做也不该做最终裁决。
  final List<AppDestination> destinations;

  /// 当前地址，用来决定高亮哪一项。
  final String currentRoute;

  final Widget body;

  /// AppBar 上的动作按钮。图标按钮必须带 tooltip（见 [build] 里的断言）。
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    // 图标按钮没有可见文字，tooltip 是它唯一的可读名称。
    // 把这条约定写成断言，是为了让「忘了写 tooltip」在开发阶段就炸出来，
    // 而不是等到无障碍走查或者用户长按图标一片空白时才发现。
    assert(
      actions.every(
        (Widget action) => action is! IconButton || action.tooltip != null,
      ),
      'AppBar 里的 IconButton 必须提供 tooltip：图标没有可见文字，'
      '没有 tooltip 就等于没有无障碍名称。',
    );

    final selectedIndex = _resolveSelectedIndex();
    final isWide =
        MediaQuery.sizeOf(context).width >= kResponsiveScaffoldBreakpoint;

    return Scaffold(
      appBar: AppBar(title: Text(title), actions: actions),
      body: isWide
          ? Row(
              children: <Widget>[
                NavigationRail(
                  // NavigationRail 允许「没有选中项」（null），
                  // 这样当 currentRoute 不属于任何 destination 时不会瞎高亮。
                  selectedIndex: selectedIndex,
                  onDestinationSelected: (int index) => _go(context, index),
                  labelType: NavigationRailLabelType.all,
                  destinations: <NavigationRailDestination>[
                    for (final destination in destinations)
                      NavigationRailDestination(
                        icon: Icon(
                          destination.icon,
                          semanticLabel: destination.label,
                        ),
                        label: Text(destination.label),
                      ),
                  ],
                ),
                const VerticalDivider(width: 1),
                Expanded(child: body),
              ],
            )
          : body,
      bottomNavigationBar: isWide
          ? null
          : NavigationBar(
              // NavigationBar 的 selectedIndex 是非空 int 且带范围断言，
              // 传不了「无选中」；这里退回 0 只是为了让断言不炸，
              // 实际上每个用本壳的页面都至少会命中自己的列表页。
              selectedIndex: selectedIndex ?? 0,
              onDestinationSelected: (int index) => _go(context, index),
              destinations: <NavigationDestination>[
                for (final destination in destinations)
                  NavigationDestination(
                    icon: Icon(destination.icon),
                    label: destination.label,
                    // 长按显示完整名称；在窄屏上标签可能被截断。
                    tooltip: destination.label,
                  ),
              ],
            ),
    );
  }

  /// 让详情页也能高亮它的列表页。
  ///
  /// `/members/7/permissions` 应当把「成员」点亮，`/platform/groups/new`
  /// 应当把「组管理」点亮。所以先找精确匹配，再退而求其次找**最长**的路径前缀。
  /// 取最长是为了在多个前缀都能命中时（例如 `/platform/groups` 与
  /// `/platform/groups/archive` 同时存在）选中更具体的那一个。
  int? _resolveSelectedIndex() {
    int? best;
    var bestLength = -1;
    for (var index = 0; index < destinations.length; index++) {
      final route = destinations[index].route;
      final matches =
          currentRoute == route ||
          currentRoute.startsWith(route.endsWith('/') ? route : '$route/');
      if (matches && route.length > bestLength) {
        best = index;
        bestLength = route.length;
      }
    }
    return best;
  }

  void _go(BuildContext context, int index) {
    final route = destinations[index].route;
    if (route == currentRoute) {
      // 点当前项不该产生一次「重新进入」的导航：那会重建页面、
      // 丢掉滚动位置和未提交的表单。
      return;
    }
    context.go(route);
  }
}
