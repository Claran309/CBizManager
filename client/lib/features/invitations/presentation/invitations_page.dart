import 'dart:async';

import 'package:c_biz_docs_manager/core/auth/auth_controller.dart';
import 'package:c_biz_docs_manager/core/error/app_failure.dart';
import 'package:c_biz_docs_manager/core/presentation/async_state_view.dart';
import 'package:c_biz_docs_manager/core/presentation/failure_presenter.dart';
import 'package:c_biz_docs_manager/core/presentation/responsive_scaffold.dart';
import 'package:c_biz_docs_manager/features/home/presentation/tenant_shell.dart';
import 'package:c_biz_docs_manager/features/invitations/application/invitation_controller.dart';
import 'package:c_biz_docs_manager/features/invitations/domain/invitation.dart';
import 'package:c_biz_docs_manager/features/invitations/presentation/invitation_secret_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

/// 邀请码状态的界面文案。
String invitationStatusLabel(InvitationStatus status) => switch (status) {
  InvitationStatus.active => '有效',
  InvitationStatus.expired => '已过期',
  InvitationStatus.used => '已使用',
  InvitationStatus.revoked => '已撤销',
};

/// 邀请码管理页。
///
/// **仅组主账号可进入**：邀请码是「谁能加入这个组」的凭证，
/// 普通成员即使持有 `member.manage` 也不该看到生成 / 撤销入口。
/// 真正的裁决在路由守卫（`isOwnerOnlyLocation`）与后端，本页只负责呈现。
final class InvitationsPage extends ConsumerStatefulWidget {
  const InvitationsPage({super.key});

  @override
  ConsumerState<InvitationsPage> createState() => _InvitationsPageState();
}

final class _InvitationsPageState extends ConsumerState<InvitationsPage> {
  /// 状态筛选的「全部」取值。
  ///
  /// 用字符串而不是 `InvitationStatus?` 做下拉框的 value：`null` 在
  /// `DropdownButton` 里表达的是「没选」，拿它当选项值会把 hint 一起顶掉，
  /// 用户再也选不回「全部」。
  static const String _allStatuses = 'all';

  /// 提前抓住 Controller 引用，供 [dispose] 使用。
  ///
  /// `dispose` 阶段已经不能再碰 `ref`（作用域正在拆），但页面卸载**必须**把明文
  /// 收掉，所以引用要在还能读的时候先存下来。
  late final InvitationController _controller;

  String _statusFilter = _allStatuses;

  @override
  void initState() {
    super.initState();
    _controller = ref.read(invitationControllerProvider.notifier);
    // 首帧之后才能碰状态：在 build 期间写 state 会触发「构建中改状态」的断言。
    // 也不能等用户手动刷新 —— 页面存在的意义就是展示列表。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _controller.load(status: _selectedStatus);
    });
  }

  @override
  void dispose() {
    // **明文生命周期的最后一道防线**：离开本页（返回首页、跳成员页、按返回键都算）
    // 就把明文收掉。
    //
    // 为什么不指望 Riverpod 自己回收：`invitationControllerProvider` 的生命周期跟着
    // **会话作用域**走，不跟着页面走 —— 它要跨页面复用，所以不能是 autoDispose。
    // 于是「路由离开」这件事本身不会销毁 Controller，不在这里主动清一次，
    // 明文会一直挂在状态里，直到用户登出或者又去查看了另一条。
    // Controller 自己也在 `ref.onDispose` 里清了，那是作用域销毁时的兜底，
    // 与这里覆盖的是两个不同的时刻。
    //
    // 但**不能在这里同步地清**：dispose 期间本 Element 已经进入 defunct 状态，
    // Riverpod 把新状态推给监听者时会撞上「不要重建已销毁的 Element」的断言
    // （`_lifecycleState != _ElementLifecycle.defunct`）。推到下一个微任务，
    // 等这一轮卸载流程彻底走完再清 —— 那时监听订阅已经摘掉，这次改动只会落在
    // 状态里，不会再触发任何 build。
    scheduleMicrotask(_controller.clearSecret);
    super.dispose();
  }

  InvitationStatus? get _selectedStatus =>
      _statusFilter == _allStatuses || _statusFilter.isEmpty
      ? null
      : InvitationStatus.fromWireValue(_statusFilter);

  void _onStatusChanged(String value) {
    setState(() => _statusFilter = value);
    // 换筛选条件立刻重新拉取，而不是等用户再点一次「筛选」：
    // 一个只有状态下拉的单选筛选器，多一次确认点击没有任何信息增量。
    _controller.load(status: _selectedStatus);
  }

  /// 把写操作的失败提示出来。
  ///
  /// 列表已经有数据时，失败不该把整张表换成错误页 —— 用户会连自己刚点的是哪一行
  /// 都看不见了。这种情况只在下方飘一条提示（冲突时附带「刷新」动作）；
  /// 列表为空（首次加载就失败）才交给 [AsyncStateView] 整页呈现，
  /// 这样同一条错误不会说两遍。
  void _presentFailure(AppFailure failure) {
    final presentation = FailurePresenter.present(failure);
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text(presentation.message),
        action: presentation.shouldRefresh
            ? SnackBarAction(label: '刷新', onPressed: _controller.refresh)
            : null,
      ),
    );
  }

  Future<void> _createInvitation() => _controller.create();

  Future<void> _reveal(InvitationSummary invitation) =>
      _controller.reveal(invitation.id);

  Future<void> _confirmRevoke(InvitationSummary invitation) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('撤销邀请码'),
        // 对话框里只报编号与状态：这是用户做决定所需的全部信息。
        // **明文绝不进对话框** —— 弹层会被截图、被投屏、被旁人瞟到，
        // 而它的用途只有一个「确认要不要撤销」。
        content: Text(
          '邀请码 #${invitation.id}（${invitationStatusLabel(invitation.status)}）'
          '撤销后立即失效，无法再用于注册。确定撤销吗？',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('撤销'),
          ),
        ],
      ),
    );
    // 用户取消（或点了遮罩）就什么都不做：撤销是不可逆的，宁可让他多点一次。
    if (confirmed != true || !mounted) return;

    // 整个摘要传下去而不是只传 id：乐观锁要用它身上的 version，
    // 而列表里这一行恰好就拿着最新的一份。
    await _controller.revoke(invitation);
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(invitationControllerProvider);
    final controller = ref.read(invitationControllerProvider.notifier);

    ref.listen<InvitationState>(invitationControllerProvider, (
      InvitationState? previous,
      InvitationState next,
    ) {
      final failure = next.failure;
      if (failure == null || next.items.isEmpty) return;
      _presentFailure(failure);
    });

    return ResponsiveScaffold(
      title: '邀请码',
      // 导航项随身份裁剪（本页只有组主账号进得来，见 tenantDestinations）。
      destinations: tenantDestinations(
        ref.watch(authControllerProvider).session?.profile,
      ),
      currentRoute: '/invitations',
      actions: <Widget>[
        IconButton(
          tooltip: '刷新',
          onPressed: controller.refresh,
          icon: const Icon(Icons.refresh),
        ),
        IconButton(
          tooltip: '生成邀请码',
          // 写操作在途时禁用：邀请码是「建一张消耗一个名额」的凭证，
          // 连点两下不该变成两张。
          onPressed: state.isWriting ? null : _createInvitation,
          icon: const Icon(Icons.add),
        ),
        IconButton(
          tooltip: '返回首页',
          onPressed: () => context.go('/home'),
          icon: const Icon(Icons.home_outlined),
        ),
      ],
      body: Column(
        children: <Widget>[
          // 明文面板自己读 `InvitationState.visibleSecret`，页面不替它传值。
          const InvitationSecretPanel(),
          _InvitationFilters(
            statusFilter: _statusFilter,
            onStatusChanged: _onStatusChanged,
          ),
          const Divider(height: 1),
          Expanded(
            child: AsyncStateView(
              // 刷新时保留旧列表：已有数据就别再白屏转圈。
              isLoading: state.isLoading && state.items.isEmpty,
              failure: state.items.isEmpty ? state.failure : null,
              isEmpty: state.items.isEmpty,
              onRetry: controller.refresh,
              emptyMessage: '还没有邀请码，点右上角「生成」创建一张',
              child: LayoutBuilder(
                builder: (BuildContext context, BoxConstraints constraints) {
                  // 按**内容区**宽度判断而不是屏幕宽度：宽屏下左边还有导航栏，
                  // 用屏幕宽度会让表格挤进一条比它实际宽度更窄的缝里。
                  final isWide =
                      constraints.maxWidth >= kResponsiveScaffoldBreakpoint;
                  return isWide
                      ? _InvitationTable(
                          items: state.items,
                          isWriting: state.isWriting,
                          onReveal: _reveal,
                          onRevoke: _confirmRevoke,
                        )
                      : _InvitationCardList(
                          items: state.items,
                          isWriting: state.isWriting,
                          onReveal: _reveal,
                          onRevoke: _confirmRevoke,
                        );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 状态筛选条。
final class _InvitationFilters extends StatelessWidget {
  const _InvitationFilters({
    required this.statusFilter,
    required this.onStatusChanged,
  });

  final String statusFilter;
  final ValueChanged<String> onStatusChanged;

  @override
  Widget build(BuildContext context) {
    // Wrap 而不是 Row：将来加了搜索框，窄屏放不下时自动折行，
    // 而不是把最后一个控件挤出可视区（横向 overflow 在测试里是硬失败）。
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Wrap(
        spacing: 12,
        runSpacing: 12,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: <Widget>[
          DropdownButton<String>(
            value: statusFilter,
            items: <DropdownMenuItem<String>>[
              const DropdownMenuItem<String>(
                value: _InvitationsPageState._allStatuses,
                child: Text('全部状态'),
              ),
              for (final status in InvitationStatus.values)
                DropdownMenuItem<String>(
                  value: status.wireValue,
                  child: Text(invitationStatusLabel(status)),
                ),
            ],
            onChanged: (String? value) {
              if (value != null) onStatusChanged(value);
            },
          ),
        ],
      ),
    );
  }
}

/// 一条邀请码在两种布局里都要显示的时间信息。
///
/// 抽成函数是为了让卡片与表格显示**完全相同的几个时刻**：一处改了字段、
/// 另一处忘了改，用户切到宽屏就会看到不一样的列。
List<String> invitationTimeLines(InvitationSummary item) {
  // 先落到局部变量上，让空判定与取值在同一个作用域里 ——
  // 直接写 `item.usedAt!` 依赖字段提升，而 Dart 的字段提升只对**私有** final
  // 字段生效，公开字段这里拿不到提升，编译器会直接报错。
  final usedAt = item.usedAt;
  final revokedAt = item.revokedAt;
  return <String>[
    '有效期至 ${formatInvitationTime(item.expiresAt)}',
    '创建于 ${formatInvitationTime(item.createdAt)}',
    if (usedAt != null) '使用于 ${formatInvitationTime(usedAt)}',
    if (revokedAt != null) '撤销于 ${formatInvitationTime(revokedAt)}',
  ];
}

/// 窄屏形态：纵向卡片，一行一张。
final class _InvitationCardList extends StatelessWidget {
  const _InvitationCardList({
    required this.items,
    required this.isWriting,
    required this.onReveal,
    required this.onRevoke,
  });

  final List<InvitationSummary> items;
  final bool isWriting;
  final ValueChanged<InvitationSummary> onReveal;
  final ValueChanged<InvitationSummary> onRevoke;

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      itemCount: items.length,
      itemBuilder: (BuildContext context, int index) {
        final item = items[index];
        return Card(
          margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: ListTile(
            title: Text('邀请码 #${item.id}'),
            subtitle: Column(
              // mainAxisSize.min：ListTile 给 subtitle 的高度是按内容算的，
              // Column 默认要占满可用高度，会把它撑成一块多余的空白。
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                for (final line in invitationTimeLines(item))
                  Text(line, style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                _InvitationStatusChip(status: item.status),
                // 只有 active 才给出操作入口。used / revoked / expired 的明文
                // 服务端已经清掉（查看只会得到 INVITATION_NOT_REVEALABLE），
                // 摆一个必然失败的按钮是纯粹的误导。
                if (item.status.isOpen) ...<Widget>[
                  IconButton(
                    tooltip: '查看明文',
                    onPressed: isWriting ? null : () => onReveal(item),
                    icon: const Icon(Icons.visibility_outlined),
                  ),
                  IconButton(
                    tooltip: '撤销该邀请码',
                    onPressed: isWriting ? null : () => onRevoke(item),
                    icon: const Icon(Icons.block),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}

/// 宽屏形态：紧凑表格，一屏能看几十条。
final class _InvitationTable extends StatelessWidget {
  const _InvitationTable({
    required this.items,
    required this.isWriting,
    required this.onReveal,
    required this.onRevoke,
  });

  final List<InvitationSummary> items;
  final bool isWriting;
  final ValueChanged<InvitationSummary> onReveal;
  final ValueChanged<InvitationSummary> onRevoke;

  @override
  Widget build(BuildContext context) {
    // 两层滚动：外层纵向、内层横向。七列在窄一点的宽屏上仍会超宽，
    // 没有横向滚动就会被裁掉（而裁掉的多半是最右边的「操作」列）。
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: DataTable(
          columns: const <DataColumn>[
            DataColumn(label: Text('编号')),
            DataColumn(label: Text('状态')),
            DataColumn(label: Text('有效期至')),
            DataColumn(label: Text('创建时间')),
            DataColumn(label: Text('使用时间')),
            DataColumn(label: Text('撤销时间')),
            DataColumn(label: Text('操作')),
          ],
          rows: <DataRow>[
            for (final item in items)
              DataRow(
                cells: <DataCell>[
                  DataCell(Text('#${item.id}')),
                  DataCell(_InvitationStatusChip(status: item.status)),
                  DataCell(Text(formatInvitationTime(item.expiresAt))),
                  DataCell(Text(formatInvitationTime(item.createdAt))),
                  // 没有发生过的事用「—」而不是留空：空格子看起来像
                  // 「这一列没加载出来」，破折号才读得出「本来就没有」。
                  DataCell(
                    Text(
                      item.usedAt == null
                          ? '—'
                          : formatInvitationTime(item.usedAt!),
                    ),
                  ),
                  DataCell(
                    Text(
                      item.revokedAt == null
                          ? '—'
                          : formatInvitationTime(item.revokedAt!),
                    ),
                  ),
                  DataCell(
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        if (item.status.isOpen) ...<Widget>[
                          TextButton(
                            onPressed: isWriting ? null : () => onReveal(item),
                            child: const Text('查看'),
                          ),
                          TextButton(
                            onPressed: isWriting ? null : () => onRevoke(item),
                            child: const Text('撤销'),
                          ),
                        ] else
                          const Text('—'),
                      ],
                    ),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

/// 邀请码状态标签。
final class _InvitationStatusChip extends StatelessWidget {
  const _InvitationStatusChip({required this.status});

  final InvitationStatus status;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    // 只有 active 用强调色：它是唯一「还能操作」的状态。
    // 另外三个都是终态，用中性容器色 —— 给已失效的邀请码上高亮色，
    // 会让人以为它还需要处理。
    final isOpen = status.isOpen;
    final background = isOpen
        ? scheme.secondaryContainer
        : scheme.surfaceContainerHighest;
    final foreground = isOpen
        ? scheme.onSecondaryContainer
        : scheme.onSurfaceVariant;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        invitationStatusLabel(status),
        style: theme.textTheme.labelSmall?.copyWith(color: foreground),
      ),
    );
  }
}
