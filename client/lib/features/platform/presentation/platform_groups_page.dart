import 'package:c_biz_docs_manager/core/auth/auth_controller.dart';
import 'package:c_biz_docs_manager/core/error/app_failure.dart';
import 'package:c_biz_docs_manager/core/presentation/async_state_view.dart';
import 'package:c_biz_docs_manager/core/presentation/failure_presenter.dart';
import 'package:c_biz_docs_manager/core/presentation/responsive_scaffold.dart';
import 'package:c_biz_docs_manager/features/platform/application/platform_group_controller.dart';
import 'package:c_biz_docs_manager/features/platform/domain/platform_group.dart';
import 'package:c_biz_docs_manager/features/platform/presentation/platform_shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

/// 平台组列表页（平台管理员的角色首页）。
///
/// 只有 `platform_admin` 能进入 `/platform/*`；租户用户访问会被守卫送回 `/home`。
final class PlatformGroupsPage extends ConsumerStatefulWidget {
  const PlatformGroupsPage({super.key, this.notice});

  /// 路由层带过来的提示（目前只有「groupId 解析失败」一种）。
  ///
  /// 用参数而不是让页面自己读地址栏：页面不需要知道 URL 长什么样，
  /// 路由层才是唯一解析地址的地方。
  final String? notice;

  @override
  ConsumerState<PlatformGroupsPage> createState() => _PlatformGroupsPageState();
}

final class _PlatformGroupsPageState extends ConsumerState<PlatformGroupsPage> {
  final TextEditingController _keywordController = TextEditingController();

  /// 状态筛选的当前取值。用字符串而不是 `GroupStatus?` 是因为下拉框需要一个
  /// 「全部」选项 —— `null` 在 `DropdownButton` 里表达的是「没选」，
  /// 用它当选项值会连 hint 一起顶掉，用户再也选不回「全部」。
  static const String _allStatuses = 'all';
  String _statusFilter = _allStatuses;

  @override
  void initState() {
    super.initState();
    // 首帧之前不能碰 Controller 的状态（会触发「build 期间改状态」），
    // 但也不该推迟到用户手动刷新 —— 页面存在的意义就是展示列表。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _loadFirstPage();
      final notice = widget.notice;
      if (notice != null) {
        _showMessage(_noticeMessage(notice));
      }
    });
  }

  @override
  void didUpdateWidget(PlatformGroupsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    final notice = widget.notice;
    // 从 `/platform/groups/abc` 被重定向过来时，本页可能已经在树上
    // （GoRouter 只换了 query 参数），initState 不会再跑一次 ——
    // 提示得在这里补，否则用户点了错误链接却什么反馈都没有。
    if (notice != null && notice != oldWidget.notice) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _showMessage(_noticeMessage(notice));
      });
    }
  }

  @override
  void dispose() {
    _keywordController.dispose();
    super.dispose();
  }

  GroupStatus? get _selectedStatus =>
      _statusFilter == _allStatuses || _statusFilter.isEmpty
      ? null
      : GroupStatus.fromWireValue(_statusFilter);

  void _loadFirstPage() {
    ref
        .read(platformGroupControllerProvider.notifier)
        .load(
          PlatformGroupQuery(
            keyword: _keyword,
            status: _selectedStatus,
            // 换筛选条件要回第一页：停在原来的页码上很可能什么都查不到，
            // 而用户看到的是一个「空列表」而不是「页码越界」。
            page: 1,
          ),
        );
  }

  String? get _keyword {
    final text = _keywordController.text.trim();
    return text.isEmpty ? null : text;
  }

  /// 入口地址里的提示码 → 给用户看的一句话。
  String _noticeMessage(String notice) => switch (notice) {
    'invalid_group_id' => '组编号无效，已返回组列表',
    _ => '地址无效，已返回组列表',
  };

  void _showMessage(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
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
            ? SnackBarAction(
                label: '刷新',
                onPressed: ref
                    .read(platformGroupControllerProvider.notifier)
                    .refresh,
              )
            : null,
      ),
    );
  }

  Future<void> _confirmStatusChange(PlatformGroup group) async {
    final target = group.status == GroupStatus.active
        ? GroupStatus.disabled
        : GroupStatus.active;
    final isDisabling = target == GroupStatus.disabled;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: Text(isDisabling ? '停用业务组' : '启用业务组'),
        content: Text(
          isDisabling
              ? '停用「${group.name}」会撤销该组全部成员的登录会话，'
                    '组内数据将无法访问。确定停用吗？'
              : '启用「${group.name}」后，该组成员可以重新登录。确定启用吗？',
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

    await ref
        .read(platformGroupControllerProvider.notifier)
        .changeStatus(group, target);
  }

  Future<void> _confirmLogout() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('退出登录'),
        content: const Text('退出后需要重新输入账号密码。确定退出吗？'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('退出'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    // 登出后路由守卫会把地址换成登录页，本页随之卸载。
    await ref.read(authControllerProvider.notifier).logout();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(platformGroupControllerProvider);
    final controller = ref.read(platformGroupControllerProvider.notifier);

    ref.listen<PlatformGroupState>(platformGroupControllerProvider, (
      PlatformGroupState? previous,
      PlatformGroupState next,
    ) {
      final failure = next.failure;
      if (failure == null || next.items.isEmpty) return;
      _presentFailure(failure);
    });

    return ResponsiveScaffold(
      title: '平台组管理',
      destinations: platformDestinations,
      currentRoute: '/platform/groups',
      actions: <Widget>[
        IconButton(
          tooltip: '刷新',
          onPressed: controller.refresh,
          icon: const Icon(Icons.refresh),
        ),
        IconButton(
          tooltip: '新建组',
          onPressed: () => context.go('/platform/groups/new'),
          icon: const Icon(Icons.add),
        ),
        IconButton(
          tooltip: '退出登录',
          onPressed: _confirmLogout,
          icon: const Icon(Icons.logout),
        ),
      ],
      body: Column(
        children: <Widget>[
          _GroupFilters(
            keywordController: _keywordController,
            statusFilter: _statusFilter,
            onStatusChanged: (String value) =>
                setState(() => _statusFilter = value),
            onSearch: _loadFirstPage,
          ),
          const Divider(height: 1),
          Expanded(
            child: AsyncStateView(
              // 刷新时保留旧列表：已有数据就别再白屏转圈，
              // 加载中由 AppBar 那个刷新按钮的禁用态与列表自身表达。
              isLoading: state.isLoading && state.items.isEmpty,
              failure: state.items.isEmpty ? state.failure : null,
              isEmpty: state.items.isEmpty,
              onRetry: controller.refresh,
              emptyMessage: '没有符合条件的业务组',
              child: LayoutBuilder(
                builder: (BuildContext context, BoxConstraints constraints) {
                  // 按**内容区**宽度判断，而不是屏幕宽度：宽屏下左侧还有导航栏，
                  // 用屏幕宽度会让表格挤进一条比它实际宽度更宽的缝里。
                  final isWide =
                      constraints.maxWidth >= kResponsiveScaffoldBreakpoint;
                  return isWide
                      ? _GroupTable(
                          groups: state.items,
                          isWriting: state.isWriting,
                          onOpen: _openDetail,
                          onToggleStatus: _confirmStatusChange,
                        )
                      : _GroupCardList(
                          groups: state.items,
                          isWriting: state.isWriting,
                          onOpen: _openDetail,
                          onToggleStatus: _confirmStatusChange,
                        );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _openDetail(PlatformGroup group) =>
      context.go('/platform/groups/${group.id}');
}

/// 关键词与状态筛选条。
final class _GroupFilters extends StatelessWidget {
  const _GroupFilters({
    required this.keywordController,
    required this.statusFilter,
    required this.onStatusChanged,
    required this.onSearch,
  });

  final TextEditingController keywordController;
  final String statusFilter;
  final ValueChanged<String> onStatusChanged;
  final VoidCallback onSearch;

  @override
  Widget build(BuildContext context) {
    // Wrap 而不是 Row：窄屏上三个控件放不下时自动折行，
    // 而不是把最后一个挤出可视区（横向 overflow 在测试里是硬失败）。
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Wrap(
        spacing: 12,
        runSpacing: 12,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: <Widget>[
          SizedBox(
            width: 220,
            child: TextField(
              controller: keywordController,
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => onSearch(),
              decoration: const InputDecoration(
                labelText: '组名关键词',
                isDense: true,
                border: OutlineInputBorder(),
              ),
            ),
          ),
          DropdownButton<String>(
            value: statusFilter,
            items: <DropdownMenuItem<String>>[
              const DropdownMenuItem<String>(
                value: _PlatformGroupsPageState._allStatuses,
                child: Text('全部状态'),
              ),
              for (final status in GroupStatus.values)
                DropdownMenuItem<String>(
                  value: status.wireValue,
                  child: Text(groupStatusLabel(status)),
                ),
            ],
            onChanged: (String? value) {
              if (value != null) onStatusChanged(value);
            },
          ),
          FilledButton.tonalIcon(
            onPressed: onSearch,
            icon: const Icon(Icons.search),
            label: const Text('筛选'),
          ),
        ],
      ),
    );
  }
}

/// 窄屏形态：卡片列表，一行一个组。
final class _GroupCardList extends StatelessWidget {
  const _GroupCardList({
    required this.groups,
    required this.isWriting,
    required this.onOpen,
    required this.onToggleStatus,
  });

  final List<PlatformGroup> groups;
  final bool isWriting;
  final ValueChanged<PlatformGroup> onOpen;
  final ValueChanged<PlatformGroup> onToggleStatus;

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      itemCount: groups.length,
      itemBuilder: (BuildContext context, int index) {
        final group = groups[index];
        return Card(
          margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: ListTile(
            title: Text(group.name),
            subtitle: Text(
              '主账号 ${group.owner.displayName}（${group.owner.username}）· '
              '${group.memberCount} 人',
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                GroupStatusChip(status: group.status),
                IconButton(
                  // 图标按钮没有可见文字，tooltip 是它唯一的名称；
                  // 文案随目标状态变化，读屏用户才知道这一按会发生什么。
                  tooltip: group.status == GroupStatus.active ? '停用该组' : '启用该组',
                  onPressed: isWriting ? null : () => onToggleStatus(group),
                  icon: Icon(
                    group.status == GroupStatus.active
                        ? Icons.block
                        : Icons.play_circle_outline,
                  ),
                ),
              ],
            ),
            onTap: () => onOpen(group),
          ),
        );
      },
    );
  }
}

/// 宽屏形态：紧凑表格，一屏能看几十个组。
final class _GroupTable extends StatelessWidget {
  const _GroupTable({
    required this.groups,
    required this.isWriting,
    required this.onOpen,
    required this.onToggleStatus,
  });

  final List<PlatformGroup> groups;
  final bool isWriting;
  final ValueChanged<PlatformGroup> onOpen;
  final ValueChanged<PlatformGroup> onToggleStatus;

  @override
  Widget build(BuildContext context) {
    // 两层滚动：外层纵向、内层横向。表格列加起来在窄一点的宽屏上仍会超宽，
    // 没有横向滚动就会被裁掉（而裁掉的恰好是最右边的「操作」列）。
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: DataTable(
          columns: const <DataColumn>[
            DataColumn(label: Text('组名')),
            DataColumn(label: Text('状态')),
            DataColumn(label: Text('主账号')),
            DataColumn(label: Text('成员数'), numeric: true),
            DataColumn(label: Text('数据版本'), numeric: true),
            DataColumn(label: Text('操作')),
          ],
          rows: <DataRow>[
            for (final group in groups)
              DataRow(
                cells: <DataCell>[
                  DataCell(Text(group.name), onTap: () => onOpen(group)),
                  DataCell(GroupStatusChip(status: group.status)),
                  DataCell(
                    Text('${group.owner.displayName}（${group.owner.username}）'),
                  ),
                  DataCell(Text('${group.memberCount}')),
                  DataCell(Text('${group.version}')),
                  DataCell(
                    TextButton(
                      onPressed: isWriting ? null : () => onToggleStatus(group),
                      child: Text(
                        group.status == GroupStatus.active ? '停用' : '启用',
                      ),
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
