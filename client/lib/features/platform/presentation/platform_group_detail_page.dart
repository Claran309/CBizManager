import 'package:c_biz_docs_manager/core/error/app_failure.dart';
import 'package:c_biz_docs_manager/core/presentation/async_state_view.dart';
import 'package:c_biz_docs_manager/core/presentation/failure_presenter.dart';
import 'package:c_biz_docs_manager/core/presentation/responsive_scaffold.dart';
import 'package:c_biz_docs_manager/features/platform/application/platform_group_detail_controller.dart';
import 'package:c_biz_docs_manager/features/platform/domain/platform_group.dart';
import 'package:c_biz_docs_manager/features/platform/presentation/change_owner_dialog.dart';
import 'package:c_biz_docs_manager/features/platform/presentation/platform_shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

/// 单个业务组的治理详情页（平台管理员）。
///
/// [groupId] 由路由层解析后注入 —— 页面自己不碰 URL，解析失败的处理也留在路由层
/// （回列表并提示），这样「地址写错」这件事只有一个地方需要关心。
final class PlatformGroupDetailPage extends ConsumerStatefulWidget {
  const PlatformGroupDetailPage({required this.groupId, super.key});

  /// 已在路由层校验为正整数的组 ID。
  final int groupId;

  @override
  ConsumerState<PlatformGroupDetailPage> createState() =>
      _PlatformGroupDetailPageState();
}

final class _PlatformGroupDetailPageState
    extends ConsumerState<PlatformGroupDetailPage> {
  @override
  void initState() {
    super.initState();
    // 首帧之后再拉数据：initState 期间读 Controller 并触发状态变化会撞上
    // 「build 期间改状态」的断言。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _controller.load();
    });
  }

  PlatformGroupDetailController get _controller =>
      ref.read(platformGroupDetailControllerProvider(widget.groupId).notifier);

  /// 把写操作的失败提示出来。
  ///
  /// 详情已经在手时用 SnackBar：把整页换成错误视图会让刚看过的组名、版本号、
  /// 成员数统统消失，而用户往往正需要照着它们判断下一步。真正「什么都没有」
  /// 的首次加载失败才交给 [AsyncStateView] 整页呈现，同一条错误不会说两遍。
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

  Future<void> _confirmStatusChange(GroupStatus current) async {
    final target = current == GroupStatus.active
        ? GroupStatus.disabled
        : GroupStatus.active;
    final isDisabling = target == GroupStatus.disabled;
    final name = ref
        .read(platformGroupDetailControllerProvider(widget.groupId))
        .detail
        ?.group
        .name;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: Text(isDisabling ? '停用业务组' : '启用业务组'),
        content: Text(
          isDisabling
              ? '停用「${name ?? '该组'}」会撤销该组全部成员的登录会话，'
                    '组内数据将无法访问。确定停用吗？'
              : '启用「${name ?? '该组'}」后，该组成员可以重新登录。确定启用吗？',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(isDisabling ? '停用' : '启用'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _controller.changeStatus(target);
  }

  Future<void> _openOwnerDialog(PlatformGroupDetail detail) async {
    // 对话框返回 null 就是用户取消 —— 这种情况不该留下任何痕迹，
    // 所以这里只在拿到 draft 时才去调 Controller。
    final draft = await ChangeOwnerDialog.show(context, detail);
    if (draft == null || !mounted) return;
    await _controller.changeOwner(draft);
  }

  @override
  Widget build(BuildContext context) {
    final provider = platformGroupDetailControllerProvider(widget.groupId);
    final state = ref.watch(provider);
    final controller = ref.read(provider.notifier);
    final detail = state.detail;

    ref.listen<PlatformGroupDetailState>(provider, (
      PlatformGroupDetailState? previous,
      PlatformGroupDetailState next,
    ) {
      final failure = next.failure;
      if (failure == null || next.detail == null) return;
      _presentFailure(failure);
    });

    return ResponsiveScaffold(
      title: detail == null ? '组详情' : '组详情 · ${detail.group.name}',
      destinations: platformDestinations,
      currentRoute: '/platform/groups/${widget.groupId}',
      actions: <Widget>[
        IconButton(
          tooltip: '返回组列表',
          onPressed: () => context.go('/platform/groups'),
          icon: const Icon(Icons.arrow_back),
        ),
        IconButton(
          tooltip: '刷新',
          // 写操作在途时禁用：此时页面上的 version 与候选列表都在变，
          // 中途重读会让人分不清自己看到的是哪一版。
          onPressed: state.isWriting ? null : controller.refresh,
          icon: const Icon(Icons.refresh),
        ),
      ],
      body: AsyncStateView(
        // 首次加载才整页转圈；已有详情时刷新不白屏（详见列表页同名说明）。
        isLoading: state.isLoading && detail == null,
        failure: detail == null ? state.failure : null,
        isEmpty: detail == null,
        onRetry: controller.refresh,
        emptyMessage: '组数据不可用',
        child: detail == null
            ? const SizedBox.shrink()
            : _DetailBody(
                detail: detail,
                isWriting: state.isWriting,
                onToggleStatus: () => _confirmStatusChange(detail.group.status),
                onChangeOwner: () => _openOwnerDialog(detail),
              ),
      ),
    );
  }
}

/// 详情正文：基本信息 + 成员统计 + 治理操作。
final class _DetailBody extends StatelessWidget {
  const _DetailBody({
    required this.detail,
    required this.isWriting,
    required this.onToggleStatus,
    required this.onChangeOwner,
  });

  final PlatformGroupDetail detail;
  final bool isWriting;
  final VoidCallback onToggleStatus;
  final VoidCallback onChangeOwner;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final group = detail.group;
    final counts = detail.memberCounts;
    final isActive = group.status == GroupStatus.active;

    // 单列可滚动 + 限宽居中：窄屏不挤，超宽屏上行长也不会拉到读不下去。
    return ListView(
      padding: const EdgeInsets.all(16),
      children: <Widget>[
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Row(
                          children: <Widget>[
                            Expanded(
                              child: Text(
                                group.name,
                                style: theme.textTheme.titleLarge,
                              ),
                            ),
                            GroupStatusChip(status: group.status),
                          ],
                        ),
                        const SizedBox(height: 12),
                        _InfoRow(
                          label: '主账号',
                          value:
                              '${group.owner.displayName}'
                              '（${group.owner.username}）',
                        ),
                        // 版本号是乐观锁凭据，展示出来是为了让运维在排查
                        // 「为什么一直提示数据被改过」时有个可对照的数字。
                        _InfoRow(label: '数据版本', value: '${group.version}'),
                        _InfoRow(
                          label: '成员总数',
                          value: '${group.memberCount} 人',
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Text('成员构成', style: theme.textTheme.titleMedium),
                const SizedBox(height: 8),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Wrap(
                      spacing: 24,
                      runSpacing: 12,
                      children: <Widget>[
                        _CountTile(label: '正常', value: counts.active),
                        _CountTile(label: '已停用', value: counts.disabled),
                        _CountTile(label: '已移除', value: counts.removed),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                Text('治理操作', style: theme.textTheme.titleMedium),
                const SizedBox(height: 8),
                // 停用是高危操作，用 outlined 而不是 filled：filled 会被当成
                // 「推荐动作」，而这里没有哪个动作是推荐的。
                OutlinedButton.icon(
                  onPressed: isWriting ? null : onToggleStatus,
                  icon: Icon(
                    isActive ? Icons.block : Icons.play_circle_outline,
                  ),
                  label: Text(isActive ? '停用该组' : '启用该组'),
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: isWriting ? null : onChangeOwner,
                  icon: const Icon(Icons.swap_horiz),
                  label: const Text('交接主账号'),
                ),
                if (isWriting) ...<Widget>[
                  const SizedBox(height: 16),
                  const Center(child: CircularProgressIndicator()),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// 「标签：值」一行。
final class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 80,
            child: Text(label, style: theme.textTheme.bodySmall),
          ),
          Expanded(child: Text(value, style: theme.textTheme.bodyMedium)),
        ],
      ),
    );
  }
}

/// 成员构成里的一个数字块。
final class _CountTile extends StatelessWidget {
  const _CountTile({required this.label, required this.value});

  final String label;
  final int value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text('$value', style: theme.textTheme.headlineSmall),
        Text(label, style: theme.textTheme.bodySmall),
      ],
    );
  }
}
