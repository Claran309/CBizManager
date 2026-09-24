import 'package:c_biz_docs_manager/core/auth/auth_controller.dart';
import 'package:c_biz_docs_manager/core/auth/auth_models.dart';
import 'package:c_biz_docs_manager/core/error/app_failure.dart';
import 'package:c_biz_docs_manager/core/presentation/async_state_view.dart';
import 'package:c_biz_docs_manager/core/presentation/failure_presenter.dart';
import 'package:c_biz_docs_manager/core/presentation/responsive_scaffold.dart';
import 'package:c_biz_docs_manager/features/home/presentation/tenant_shell.dart';
import 'package:c_biz_docs_manager/features/members/application/member_controller.dart';
import 'package:c_biz_docs_manager/features/members/domain/member.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

/// 成员状态的界面文案。
String memberStatusLabel(MemberStatus status) => switch (status) {
  MemberStatus.active => '启用中',
  MemberStatus.disabled => '已停用',
  MemberStatus.removed => '已移除',
};

/// 成员列表页。
///
/// 能进来的只有两类人：组主账号（隐式持有全部权限），以及被显式授予
/// `member.manage` 的普通成员。守卫负责拦人，本页负责按角色裁剪操作入口 ——
/// 前端裁剪只是体验与减噪，真正的授权始终在后端。
final class MembersPage extends ConsumerStatefulWidget {
  const MembersPage({super.key, this.notice});

  /// 路由层带过来的提示（目前只有「membershipId 解析失败」一种）。
  final String? notice;

  @override
  ConsumerState<MembersPage> createState() => _MembersPageState();
}

final class _MembersPageState extends ConsumerState<MembersPage> {
  /// 状态筛选的「全部」取值。用字符串而不是 `MemberStatus?`：`null` 在
  /// `DropdownButton` 里表达的是「没选」，拿它当选项值会把 hint 一起顶掉。
  static const String _allStatuses = 'all';

  /// 提前抓住 Controller 引用，供页面回调使用（不必每次经过 `ref`）。
  late final MemberController _controller;

  final TextEditingController _keywordController = TextEditingController();
  String _statusFilter = _allStatuses;

  @override
  void initState() {
    super.initState();
    _controller = ref.read(memberControllerProvider.notifier);
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
  void didUpdateWidget(MembersPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    final notice = widget.notice;
    // 从 `/members/abc/permissions` 被重定向过来时本页可能已经在树上
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

  MemberStatus? get _selectedStatus =>
      _statusFilter == _allStatuses || _statusFilter.isEmpty
      ? null
      : MemberStatus.fromWireValue(_statusFilter);

  String? get _keyword {
    final text = _keywordController.text.trim();
    return text.isEmpty ? null : text;
  }

  void _loadFirstPage() {
    // 换筛选条件要回到「从第一页开始」：成员查询是一次拉全量（数据源内部翻页），
    // 所以这里只需要把条件交出去。
    _controller.load(MemberQuery(keyword: _keyword, status: _selectedStatus));
  }

  /// 入口地址里的提示码 → 给用户看的一句话。
  String _noticeMessage(String notice) => switch (notice) {
    'invalid_membership_id' => '成员编号无效，已返回成员列表',
    _ => '地址无效，已返回成员列表',
  };

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  /// 把写操作的失败提示出来。
  ///
  /// 列表已经有数据时，失败不该把整张表换成错误页 —— 用户会连自己刚点的是哪一行
  /// 都看不见了。这种情况只在下方飘一条提示（冲突时附带「刷新」动作）；
  /// 列表为空（首次加载就失败）才交给 [AsyncStateView] 整页呈现。
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

  Future<void> _changeStatus(Member member, MemberStatus target) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: Text('${memberStatusLabel(target)}成员'),
        content: Text(
          target == MemberStatus.active
              ? '恢复「${member.displayName}」的登录资格？'
              : '把「${member.displayName}」置为${memberStatusLabel(target)}后，'
                    '该账号将无法登录，但历史单据仍然保留。确定吗？',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    // 整个成员传下去：乐观锁要用它身上的 version，列表里这一行恰好拿着最新的一份。
    await _controller.changeStatus(member.membershipId, target, member.version);
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(memberControllerProvider);
    final profile = ref.watch(authControllerProvider).session?.profile;

    ref.listen<MemberState>(memberControllerProvider, (
      MemberState? previous,
      MemberState next,
    ) {
      final failure = next.failure;
      if (failure == null || next.items.isEmpty) return;
      _presentFailure(failure);
    });

    // 主账号隐式持有组内全部权限（hasPermission 内部已处理）。
    final canManageStatus =
        profile != null &&
        (profile.accountType == AccountType.groupOwner ||
            profile.hasPermission('member.manage'));

    // **改权限只给组主账号**。普通成员即使拿到 `member.manage` 也只能管状态：
    // 把授权入口交给被管理者，等于给他一条自己给自己提权的路。
    final canManagePermissions = profile?.accountType == AccountType.groupOwner;

    final currentUserId = profile?.user.id;

    return ResponsiveScaffold(
      title: '成员',
      // 导航按身份裁剪：普通成员看到的壳里不会出现「邀请码」这种
      // 点了就被守卫弹回来的假入口。见 tenantDestinations。
      destinations: tenantDestinations(profile),
      currentRoute: '/members',
      actions: <Widget>[
        IconButton(
          tooltip: '刷新',
          onPressed: _controller.refresh,
          icon: const Icon(Icons.refresh),
        ),
        IconButton(
          tooltip: '返回首页',
          onPressed: () => context.go('/home'),
          icon: const Icon(Icons.home_outlined),
        ),
      ],
      body: Column(
        children: <Widget>[
          _MemberFilters(
            keywordController: _keywordController,
            statusFilter: _statusFilter,
            onStatusChanged: (String value) {
              setState(() => _statusFilter = value);
              _loadFirstPage();
            },
            onSearch: _loadFirstPage,
          ),
          const Divider(height: 1),
          Expanded(
            child: AsyncStateView(
              // 刷新时保留旧列表：已有数据就别再白屏转圈。
              isLoading: state.isLoading && state.items.isEmpty,
              failure: state.items.isEmpty ? state.failure : null,
              isEmpty: state.items.isEmpty,
              onRetry: _controller.refresh,
              emptyMessage: '没有符合条件的成员',
              child: LayoutBuilder(
                builder: (BuildContext context, BoxConstraints constraints) {
                  // 按内容区宽度判断而不是屏幕宽度：宽屏下左边还有导航栏。
                  final isWide =
                      constraints.maxWidth >= kResponsiveScaffoldBreakpoint;
                  return isWide
                      ? _MemberTable(
                          members: state.items,
                          isWriting: state.isWriting,
                          canManageStatus: canManageStatus,
                          canManagePermissions: canManagePermissions,
                          currentUserId: currentUserId,
                          onStatusSelected: _changeStatus,
                          onOpenPermissions: _openPermissions,
                        )
                      : _MemberCardList(
                          members: state.items,
                          isWriting: state.isWriting,
                          canManageStatus: canManageStatus,
                          canManagePermissions: canManagePermissions,
                          currentUserId: currentUserId,
                          onStatusSelected: _changeStatus,
                          onOpenPermissions: _openPermissions,
                        );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _openPermissions(Member member) =>
      context.go('/members/${member.membershipId}/permissions');
}

/// 关键词与状态筛选条。
final class _MemberFilters extends StatelessWidget {
  const _MemberFilters({
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
    // Wrap 而不是 Row：窄屏放不下时自动折行，而不是把最后一个控件挤出可视区
    // （横向 overflow 在测试里是硬失败）。
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
                labelText: '姓名或用户名',
                isDense: true,
                border: OutlineInputBorder(),
              ),
            ),
          ),
          DropdownButton<String>(
            value: statusFilter,
            items: <DropdownMenuItem<String>>[
              const DropdownMenuItem<String>(
                value: _MembersPageState._allStatuses,
                child: Text('全部状态'),
              ),
              for (final status in MemberStatus.values)
                DropdownMenuItem<String>(
                  value: status.wireValue,
                  child: Text(memberStatusLabel(status)),
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

/// 成员状态的彩色标签。
final class MemberStatusChip extends StatelessWidget {
  const MemberStatusChip({required this.status, super.key});

  final MemberStatus status;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    // 已移除用 error 色：它是「这个人已经不在组里了」，与「暂时停用」不是一回事，
    // 混成一个颜色会让管理员反复去点一个早就该消失的账号。
    final (background, foreground) = switch (status) {
      MemberStatus.active => (
        scheme.secondaryContainer,
        scheme.onSecondaryContainer,
      ),
      MemberStatus.disabled => (
        scheme.surfaceContainerHighest,
        scheme.onSurfaceVariant,
      ),
      MemberStatus.removed => (scheme.errorContainer, scheme.onErrorContainer),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        memberStatusLabel(status),
        style: theme.textTheme.labelSmall?.copyWith(color: foreground),
      ),
    );
  }
}

/// 一行成员共用的展示与权限判定。
///
/// 抽出来是为了让卡片与表格**用同一套规则**决定「这个按钮该不该给」：
/// 一处改了另一处忘了改，用户切到宽屏就会看到不一样的入口。
final class MemberRowActions {
  const MemberRowActions({
    required this.isWriting,
    required this.canManageStatus,
    required this.canManagePermissions,
    required this.currentUserId,
  });

  final bool isWriting;
  final bool canManageStatus;
  final bool canManagePermissions;
  final int? currentUserId;

  /// 这一行的状态是否被保护、不允许改。
  ///
  /// 两种保护对象：
  /// - **组主账号**：把他停用就等于整个组没人能管理了；
  /// - **当前账号自己**：停用自己是不可逆的自锁（下一个请求就会 401），
  ///   这属于「误点一下账号就废了」的操作，界面上必须堵死。
  bool isProtected(Member member) =>
      member.isGroupOwner || member.userId == currentUserId;

  bool get isStatusEnabled => canManageStatus && !isWriting;
}

/// 状态修改菜单。
///
/// 只列出后端支持的三个状态，当前状态那一项置灰而不是隐藏 ——
/// 隐藏会让用户以为「少了点什么」，置灰才读得出「已经是这个状态了」。
final class _MemberStatusMenu extends StatelessWidget {
  const _MemberStatusMenu({
    required this.member,
    required this.actions,
    required this.onSelected,
  });

  final Member member;
  final MemberRowActions actions;
  final ValueChanged<MemberStatus> onSelected;

  @override
  Widget build(BuildContext context) {
    final disabled = !actions.isStatusEnabled || actions.isProtected(member);
    return PopupMenuButton<MemberStatus>(
      tooltip: disabled ? '该成员状态不可修改' : '修改状态',
      enabled: !disabled,
      onSelected: onSelected,
      itemBuilder: (BuildContext context) => <PopupMenuEntry<MemberStatus>>[
        for (final status in MemberStatus.values)
          PopupMenuItem<MemberStatus>(
            value: status,
            enabled: status != member.status,
            child: Text(memberStatusLabel(status)),
          ),
      ],
    );
  }
}

/// 窄屏形态：纵向卡片，一行一个人。
final class _MemberCardList extends StatelessWidget {
  const _MemberCardList({
    required this.members,
    required this.isWriting,
    required this.canManageStatus,
    required this.canManagePermissions,
    required this.currentUserId,
    required this.onStatusSelected,
    required this.onOpenPermissions,
  });

  final List<Member> members;
  final bool isWriting;
  final bool canManageStatus;
  final bool canManagePermissions;
  final int? currentUserId;
  final void Function(Member member, MemberStatus status) onStatusSelected;
  final ValueChanged<Member> onOpenPermissions;

  @override
  Widget build(BuildContext context) {
    final actions = MemberRowActions(
      isWriting: isWriting,
      canManageStatus: canManageStatus,
      canManagePermissions: canManagePermissions,
      currentUserId: currentUserId,
    );

    return ListView.builder(
      itemCount: members.length,
      itemBuilder: (BuildContext context, int index) {
        final member = members[index];
        return Card(
          margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: ListTile(
            title: Text('${member.displayName}（${member.username}）'),
            subtitle: Text(
              '${member.isGroupOwner ? '组主账号' : '业务员'} · '
              '数据版本 ${member.version}',
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                MemberStatusChip(status: member.status),
                if (canManageStatus)
                  _MemberStatusMenu(
                    member: member,
                    actions: actions,
                    onSelected: (status) => onStatusSelected(member, status),
                  ),
                if (canManagePermissions)
                  IconButton(
                    tooltip: '调整权限',
                    onPressed: isWriting
                        ? null
                        : () => onOpenPermissions(member),
                    icon: const Icon(Icons.tune),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// 宽屏形态：紧凑表格。
final class _MemberTable extends StatelessWidget {
  const _MemberTable({
    required this.members,
    required this.isWriting,
    required this.canManageStatus,
    required this.canManagePermissions,
    required this.currentUserId,
    required this.onStatusSelected,
    required this.onOpenPermissions,
  });

  final List<Member> members;
  final bool isWriting;
  final bool canManageStatus;
  final bool canManagePermissions;
  final int? currentUserId;
  final void Function(Member member, MemberStatus status) onStatusSelected;
  final ValueChanged<Member> onOpenPermissions;

  @override
  Widget build(BuildContext context) {
    final actions = MemberRowActions(
      isWriting: isWriting,
      canManageStatus: canManageStatus,
      canManagePermissions: canManagePermissions,
      currentUserId: currentUserId,
    );

    // 两层滚动：外层纵向、内层横向。列加起来在窄一点的宽屏上仍会超宽，
    // 没有横向滚动就会被裁掉（而裁掉的多半是最右边的「操作」列）。
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: DataTable(
          columns: const <DataColumn>[
            DataColumn(label: Text('姓名')),
            DataColumn(label: Text('用户名')),
            DataColumn(label: Text('角色')),
            DataColumn(label: Text('状态')),
            DataColumn(label: Text('数据版本'), numeric: true),
            DataColumn(label: Text('操作')),
          ],
          rows: <DataRow>[
            for (final member in members)
              DataRow(
                cells: <DataCell>[
                  DataCell(Text(member.displayName)),
                  DataCell(Text(member.username)),
                  DataCell(Text(member.isGroupOwner ? '组主账号' : '业务员')),
                  DataCell(MemberStatusChip(status: member.status)),
                  DataCell(Text('${member.version}')),
                  DataCell(
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        if (canManageStatus)
                          _MemberStatusMenu(
                            member: member,
                            actions: actions,
                            onSelected: (status) =>
                                onStatusSelected(member, status),
                          ),
                        if (canManagePermissions)
                          TextButton(
                            onPressed: isWriting
                                ? null
                                : () => onOpenPermissions(member),
                            child: const Text('权限'),
                          )
                        else if (!canManageStatus)
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
