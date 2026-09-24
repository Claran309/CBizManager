import 'package:c_biz_docs_manager/core/presentation/responsive_scaffold.dart';
import 'package:c_biz_docs_manager/features/platform/domain/platform_group.dart';
import 'package:flutter/material.dart';

/// 平台侧页面共用的展示件。
///
/// 三个页面（列表、详情、新建）用同一个导航壳与同一套文案，散落在各文件里
/// 迟早会出现「列表页叫『已停用』、详情页叫『停用』」这种不一致。

/// 平台管理员可见的导航目的地。
///
/// 目前只有「组管理」一项 —— 平台侧的功能就只有它。少于两项时
/// [ResponsiveScaffold] 会直接不渲染导航（见其 [build] 的说明），所以这里
/// 维持成一个列表：将来平台侧加了审计日志之类的功能，只改这一处即可。
const List<AppDestination> platformDestinations = <AppDestination>[
  AppDestination(
    label: '组管理',
    icon: Icons.business_outlined,
    route: '/platform/groups',
  ),
];

/// 组状态的界面文案。
String groupStatusLabel(GroupStatus status) => switch (status) {
  GroupStatus.active => '启用中',
  GroupStatus.disabled => '已停用',
};

/// 组状态的彩色标签。
///
/// 停用态用 `error` 色而不是灰：它意味着整组人当下**登不进来**，
/// 是运维需要立刻看见的事，不是一条中性的历史信息。
final class GroupStatusChip extends StatelessWidget {
  const GroupStatusChip({required this.status, super.key});

  final GroupStatus status;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isActive = status == GroupStatus.active;
    final foreground = isActive
        ? scheme.onSecondaryContainer
        : scheme.onErrorContainer;
    final background = isActive
        ? scheme.secondaryContainer
        : scheme.errorContainer;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        groupStatusLabel(status),
        style: Theme.of(
          context,
        ).textTheme.labelSmall?.copyWith(color: foreground),
      ),
    );
  }
}
