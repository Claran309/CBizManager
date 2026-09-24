import 'package:c_biz_docs_manager/core/auth/auth_controller.dart';
import 'package:c_biz_docs_manager/core/error/app_failure.dart';
import 'package:c_biz_docs_manager/core/presentation/async_state_view.dart';
import 'package:c_biz_docs_manager/core/presentation/failure_presenter.dart';
import 'package:c_biz_docs_manager/core/presentation/responsive_scaffold.dart';
import 'package:c_biz_docs_manager/features/dictionaries/application/dictionary_controller.dart';
import 'package:c_biz_docs_manager/features/dictionaries/domain/dictionary_entry.dart';
import 'package:c_biz_docs_manager/features/dictionaries/presentation/dictionary_editor_dialog.dart';
import 'package:c_biz_docs_manager/features/home/presentation/tenant_shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

/// 字典状态的界面文案。
String dictionaryStatusLabel(DictionaryStatus status) => switch (status) {
  DictionaryStatus.active => '启用中',
  DictionaryStatus.disabled => '已停用',
};

/// 辅助字典页：进项公司 / 客户 / 品名 / 型号 / 单位 / 出货单位**六种 kind 共用一页**。
///
/// 六种 kind 的结构完全一样（名称 + 可选父级 + 可选联系电话 + 状态），
/// 分成六个页面只会得到六份要同步修改的重复代码，还得为「切到品名页」再设计一套导航。
/// 用顶部的 kind 下拉切换，一个页面就够，也与填写单据时选字典的顺序一致。
///
/// **所有租户用户都能进入**：普通成员至少需要读字典来填单，所以路由守卫不拦。
/// 写入口（新增 / 编辑 / 启停，以及「已停用」筛选）按 `dictionary.manage` 裁剪，
/// 普通成员看到的是一个纯只读页面 —— 而不是一堆点了才报 403 的按钮。
final class DictionariesPage extends ConsumerStatefulWidget {
  const DictionariesPage({super.key});

  @override
  ConsumerState<DictionariesPage> createState() => _DictionariesPageState();
}

final class _DictionariesPageState extends ConsumerState<DictionariesPage> {
  /// 状态筛选的「启用中」取值。
  ///
  /// 它对应的查询参数是 **null**（详见 [DictionaryQuery.status]）：
  /// 契约里根本没有「两种状态一起返回」的取值，所以筛选器只有两项 ——
  /// 摆一个点了没用的「全部」比少一个选项更糟。
  static const String _activeFilter = 'active';

  /// 状态筛选的「已停用」取值。显式筛选需要 `dictionary.manage`。
  static const String _disabledFilter = 'disabled';

  /// 父级筛选的「全部品名」取值。
  ///
  /// 同成员页：`DropdownButton` 里的 null 表达的是「没选」，
  /// 拿它当选项值会把 hint 一起顶掉，所以用字符串哨兵。
  static const String _allParents = 'all';

  late final DictionaryController _controller;
  final TextEditingController _keywordController = TextEditingController();

  DictionaryKind _kind = DictionaryKind.customer;
  String _statusFilter = _activeFilter;
  String _parentFilter = _allParents;

  /// 对话框是否开着。
  ///
  /// 用它让页面在 editor 期间**不重复报错**：错误已经由对话框内联呈现，
  /// 页面再飘一条同内容的提示条就是同一条错误说两遍（而且会被对话框挡住）。
  bool _editorOpen = false;

  @override
  void initState() {
    super.initState();
    _controller = ref.read(dictionaryControllerProvider.notifier);
    // 首帧之后再拉：initState 期间触发状态变化会撞上「build 期间改状态」的断言。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _reload();
    });
  }

  @override
  void dispose() {
    _keywordController.dispose();
    super.dispose();
  }

  /// 当前身份是否能写字典。
  ///
  /// 从 `/auth/me` 下发的权限码判定，**绝不本地解码 JWT 去猜**：
  /// 令牌载荷客户端可读可改，用它做界面裁剪等于把权限交给攻击者。
  /// 主账号隐式持有组内全部权限（`hasPermission` 内部已处理）。
  bool get _canManage {
    final profile = ref.read(authControllerProvider).session?.profile;
    return profile != null && profile.hasPermission('dictionary.manage');
  }

  /// 本次查询的状态条件。
  ///
  /// 没权限时即使本地残留着「已停用」的选择也一律退回默认口径：
  /// 显式筛已停用需要 `dictionary.manage`，发出去只会拿到一个 403。
  DictionaryStatus? get _status =>
      _canManage && _statusFilter == _disabledFilter
      ? DictionaryStatus.disabled
      : null;

  /// 本次查询的父级条件（只有「型号」用得上）。
  int? get _parentFilterId {
    if (!_kind.usesParent || _parentFilter == _allParents) return null;
    return int.tryParse(_parentFilter);
  }

  String? get _keyword {
    final text = _keywordController.text.trim();
    return text.isEmpty ? null : text;
  }

  DictionaryQuery get _query => DictionaryQuery(
    kind: _kind,
    parentId: _parentFilterId,
    status: _status,
    keyword: _keyword,
  );

  String get _emptyMessage {
    if (_keyword != null) {
      return '没有名称匹配「${_keywordController.text.trim()}」的${_kind.label}';
    }
    if (_status == DictionaryStatus.disabled) {
      return '没有已停用的${_kind.label}';
    }
    return '还没有${_kind.label}';
  }

  void _reload() {
    _controller.load(_query);
    // 父级候选与主列表**并发**拉：两者互不依赖，串起来只是白等一个往返。
    // 只有型号页需要它（父级筛选的下拉 + 行里显示所属品名），
    // 其他 kind 拉它是白费一个请求。
    if (_kind.usesParent) {
      _controller.loadParentOptions();
    }
  }

  void _changeKind(DictionaryKind kind) {
    if (kind == _kind) return;
    setState(() {
      _kind = kind;
      // 换 kind 就丢掉上一个 kind 的父级筛选：它是「型号」专属的，
      // 留着会在下次切回型号时悄悄带上一个用户早就忘了的条件。
      _parentFilter = _allParents;
    });
    _reload();
  }

  void _changeStatusFilter(String value) {
    setState(() => _statusFilter = value);
    _reload();
  }

  void _changeParentFilter(String value) {
    setState(() => _parentFilter = value);
    _reload();
  }

  /// 把失败提示出来。
  ///
  /// 列表已经有数据时只飘一条提示条（冲突时附带「重新加载」动作）：
  /// 把整张列表换成错误页会让用户连自己刚动的是哪一条都看不见了。
  /// 列表为空时交给 [AsyncStateView] 整页呈现，同一条错误不说两遍。
  void _presentFailure(AppFailure failure) {
    final presentation = FailurePresenter.present(failure);
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text(presentation.message),
        action: presentation.shouldRefresh
            ? SnackBarAction(label: '重新加载', onPressed: _reload)
            : null,
      ),
    );
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  /// 打开新增 / 编辑对话框。
  ///
  /// [entry] 为 null 表示新增。编辑时**连条目一起传下去**：对话框要用它身上的
  /// `version` 做乐观锁，也要用它现有的字段播种表单。
  Future<void> _openEditor({DictionaryEntry? entry}) async {
    // 新增用当前正在看的 kind；编辑用这一行自己的 kind ——
    // 列表可能刚刚被冲突重读刷新过，两者不一定还是同一个。
    final kind = entry?.kind ?? _kind;
    _editorOpen = true;
    try {
      final result = await DictionaryEditorDialog.show(
        context,
        kind: kind,
        entry: entry,
      );
      if (!mounted || result == null) return;
      switch (result) {
        case DictionaryEditorSaved():
          _showMessage(entry == null ? '已新增${kind.label}' : '已保存${kind.label}');
        case DictionaryEditorConflict(:final failure):
          // 控制器已经在冲突路径里完成了重读，这里只负责把「为什么没保存上」
          // 说清楚，让用户对着最新数据重新决定。
          _presentFailure(failure);
      }
    } finally {
      _editorOpen = false;
    }
  }

  Future<void> _changeStatus(
    DictionaryEntry entry,
    DictionaryStatus target,
  ) async {
    final enabling = target == DictionaryStatus.active;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: Text('${dictionaryStatusLabel(target)}${entry.kind.label}'),
        content: Text(
          enabling
              ? '启用「${entry.name}」后，填单时会重新出现在候选里。确定吗？'
              : '停用「${entry.name}」后，填单时不再出现在候选里；'
                    '已经保存的单据不受影响。确定吗？',
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

    // 整个条目传下去：乐观锁要用它身上的 version，列表里这一行恰好拿着最新的一份。
    await _controller.changeStatus(entry.id, target, entry.version);
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(dictionaryControllerProvider);
    final profile = ref.watch(authControllerProvider).session?.profile;
    // 主账号隐式持有组内全部权限（hasPermission 内部已处理）。
    final canManage =
        profile != null && profile.hasPermission('dictionary.manage');

    ref.listen<DictionaryState>(dictionaryControllerProvider, (
      DictionaryState? previous,
      DictionaryState next,
    ) {
      final failure = next.failure;
      if (failure == null) return;
      // editor 开着时由对话框自己内联呈现。
      if (_editorOpen) return;
      // 列表为空时整页交给 AsyncStateView（它自己会把失败显示出来）。
      if (next.items.isEmpty) return;
      _presentFailure(failure);
    });

    final rows = <DictionaryRow>[
      for (final entry in state.items)
        DictionaryRow(
          entry: entry,
          parentName: _parentNameOf(entry, state.parentOptions),
        ),
    ];

    final actions = DictionaryRowActions(
      canManage: canManage,
      isWriting: state.isWriting,
    );

    return ResponsiveScaffold(
      title: '辅助字典',
      // 导航项随身份裁剪（见 tenantDestinations）。
      destinations: tenantDestinations(profile),
      currentRoute: '/dictionaries',
      actions: <Widget>[
        // 写入口整体隐藏而不是点了报 403：只读用户看到的就是一个纯只读页面。
        if (canManage)
          IconButton(
            tooltip: '新增${_kind.label}',
            onPressed: state.isWriting ? null : () => _openEditor(),
            icon: const Icon(Icons.add),
          ),
        IconButton(
          tooltip: '刷新',
          onPressed: _reload,
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
          _DictionaryFilters(
            kind: _kind,
            canManage: canManage,
            statusFilter: _statusFilter,
            parentFilter: _parentFilter,
            parentOptions: state.parentOptions,
            isLoadingParents: state.isLoadingParents,
            keywordController: _keywordController,
            onKindChanged: _changeKind,
            onStatusChanged: _changeStatusFilter,
            onParentChanged: _changeParentFilter,
            onSearch: _reload,
            onReloadParents: _controller.loadParentOptions,
          ),
          const Divider(height: 1),
          Expanded(
            child: AsyncStateView(
              // 刷新时保留旧列表：已有数据就别再白屏转圈。
              isLoading: state.isLoading && state.items.isEmpty,
              failure: state.items.isEmpty ? state.failure : null,
              isEmpty: state.items.isEmpty,
              onRetry: _reload,
              emptyMessage: _emptyMessage,
              child: LayoutBuilder(
                builder: (BuildContext context, BoxConstraints constraints) {
                  // 按内容区宽度判断而不是屏幕宽度：宽屏下左边还有导航栏。
                  final isWide =
                      constraints.maxWidth >= kResponsiveScaffoldBreakpoint;
                  return isWide
                      ? _DictionaryTable(
                          rows: rows,
                          actions: actions,
                          onChangeStatus: _changeStatus,
                          onEdit: (DictionaryEntry entry) =>
                              _openEditor(entry: entry),
                        )
                      : _DictionaryCardList(
                          rows: rows,
                          actions: actions,
                          onChangeStatus: _changeStatus,
                          onEdit: (DictionaryEntry entry) =>
                              _openEditor(entry: entry),
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

/// 一行字典条目的展示数据。
///
/// 抽出来是为了让卡片与表格**用同一套规则**决定这一行显示什么：
/// 一处改了另一处忘了改，用户切个屏宽就会看到不一样的东西。
final class DictionaryRow {
  const DictionaryRow({required this.entry, required this.parentName});

  final DictionaryEntry entry;

  /// 型号所属品名的显示名；不是型号时为 null。
  final String? parentName;

  /// 「附加信息」的内容：客户显示联系电话、型号显示所属品名，其余 kind 为空。
  ///
  /// 这不是界面偏好，是后端字段规则的另一面：只有客户有联系电话、
  /// 只有型号有父级（见 [DictionaryKindRules]）。
  String? get extra {
    final kind = entry.kind;
    if (kind.acceptsContactPhone) return entry.contactPhone;
    if (kind.usesParent) return parentName;
    return null;
  }
}

/// 一行条目的操作可用性。
final class DictionaryRowActions {
  const DictionaryRowActions({
    required this.canManage,
    required this.isWriting,
  });

  /// 是否有 `dictionary.manage`。
  final bool canManage;

  final bool isWriting;

  /// 编辑与启停都归 `dictionary.manage`。前端裁剪只是减噪，
  /// 真正的授权始终在后端。
  bool get isEnabled => canManage && !isWriting;
}

/// 关键词与筛选条。
final class _DictionaryFilters extends StatelessWidget {
  const _DictionaryFilters({
    required this.kind,
    required this.canManage,
    required this.statusFilter,
    required this.parentFilter,
    required this.parentOptions,
    required this.isLoadingParents,
    required this.keywordController,
    required this.onKindChanged,
    required this.onStatusChanged,
    required this.onParentChanged,
    required this.onSearch,
    required this.onReloadParents,
  });

  final DictionaryKind kind;
  final bool canManage;
  final String statusFilter;
  final String parentFilter;
  final List<DictionaryEntry> parentOptions;
  final bool isLoadingParents;
  final TextEditingController keywordController;
  final ValueChanged<DictionaryKind> onKindChanged;
  final ValueChanged<String> onStatusChanged;
  final ValueChanged<String> onParentChanged;
  final VoidCallback onSearch;
  final VoidCallback onReloadParents;

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
          DropdownButton<DictionaryKind>(
            value: kind,
            items: <DropdownMenuItem<DictionaryKind>>[
              for (final value in DictionaryKind.values)
                DropdownMenuItem<DictionaryKind>(
                  value: value,
                  child: Text(value.label),
                ),
            ],
            onChanged: (DictionaryKind? value) {
              if (value != null) onKindChanged(value);
            },
          ),
          if (kind.usesParent) _parentFilter(),
          // 状态筛选只给有权限的人看：显式筛「已停用」需要 `dictionary.manage`，
          // 把它摆给没权限的人等于请他去点一个必然被拒的选项。
          if (canManage)
            DropdownButton<String>(
              value: statusFilter,
              items: const <DropdownMenuItem<String>>[
                DropdownMenuItem<String>(
                  value: _DictionariesPageState._activeFilter,
                  child: Text('启用中'),
                ),
                DropdownMenuItem<String>(
                  value: _DictionariesPageState._disabledFilter,
                  child: Text('已停用'),
                ),
              ],
              onChanged: (String? value) {
                if (value != null) onStatusChanged(value);
              },
            ),
          SizedBox(
            width: 220,
            child: TextField(
              controller: keywordController,
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => onSearch(),
              decoration: InputDecoration(
                labelText: '${kind.label}名称',
                isDense: true,
                border: const OutlineInputBorder(),
              ),
            ),
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

  /// 「型号」页专属的父级品名筛选。
  ///
  /// 候选为空时**不给一个空下拉**：拉不到和确实没有是两回事，
  /// 空下拉会让人以为「这个筛选点了没用」，而他真正需要的是重试。
  Widget _parentFilter() {
    if (parentOptions.isEmpty) {
      if (isLoadingParents) {
        return const Text('正在加载品名…');
      }
      return TextButton(
        onPressed: onReloadParents,
        child: const Text('重新加载品名'),
      );
    }

    final hasSelection =
        parentFilter == _DictionariesPageState._allParents ||
        parentOptions.any((DictionaryEntry option) {
          return '${option.id}' == parentFilter;
        });

    return DropdownButton<String>(
      value: parentFilter,
      items: <DropdownMenuItem<String>>[
        const DropdownMenuItem<String>(
          value: _DictionariesPageState._allParents,
          child: Text('全部品名'),
        ),
        for (final option in parentOptions)
          DropdownMenuItem<String>(
            value: '${option.id}',
            child: Text(option.name),
          ),
        // 选中项被别处停用后就不在候选里了。不补一个占位项，
        // DropdownButton 会直接断言「value 不在 items 里」把页面搞崩。
        if (!hasSelection)
          DropdownMenuItem<String>(
            value: parentFilter,
            child: Text('品名 #$parentFilter'),
          ),
      ],
      onChanged: (String? value) {
        if (value != null) onParentChanged(value);
      },
    );
  }
}

/// 字典状态的彩色标签。
///
/// 状态筛选把「已停用」也摆出来的时候，光看名称分辨不出这一行是活的还是废的，
/// 所以列表里必须有这个标签（不只是筛选器上的文字）。
final class DictionaryStatusChip extends StatelessWidget {
  const DictionaryStatusChip({required this.status, super.key});

  final DictionaryStatus status;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    // 已停用用「弱化」而不是「错误」色：停用是正常的经营动作
    // （这个客户不再合作了），不是出了错，标红会让人以为要去处理它。
    final (background, foreground) = switch (status) {
      DictionaryStatus.active => (
        scheme.secondaryContainer,
        scheme.onSecondaryContainer,
      ),
      DictionaryStatus.disabled => (
        scheme.surfaceContainerHighest,
        scheme.onSurfaceVariant,
      ),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        dictionaryStatusLabel(status),
        style: theme.textTheme.labelSmall?.copyWith(color: foreground),
      ),
    );
  }
}

/// 状态修改菜单。
///
/// 只列出后端支持的两个状态，当前状态那一项置灰而不是隐藏 ——
/// 隐藏会让用户以为「少了点什么」，置灰才读得出「已经是这个状态了」。
final class _DictionaryStatusMenu extends StatelessWidget {
  const _DictionaryStatusMenu({
    required this.entry,
    required this.actions,
    required this.onSelected,
  });

  final DictionaryEntry entry;
  final DictionaryRowActions actions;
  final ValueChanged<DictionaryStatus> onSelected;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<DictionaryStatus>(
      tooltip: actions.isEnabled ? '修改状态' : '该条目状态不可修改',
      enabled: actions.isEnabled,
      onSelected: onSelected,
      itemBuilder: (BuildContext context) => <PopupMenuEntry<DictionaryStatus>>[
        for (final status in DictionaryStatus.values)
          PopupMenuItem<DictionaryStatus>(
            value: status,
            enabled: status != entry.status,
            child: Text(dictionaryStatusLabel(status)),
          ),
      ],
    );
  }
}

/// 窄屏形态：纵向卡片，一行一条。
final class _DictionaryCardList extends StatelessWidget {
  const _DictionaryCardList({
    required this.rows,
    required this.actions,
    required this.onChangeStatus,
    required this.onEdit,
  });

  final List<DictionaryRow> rows;
  final DictionaryRowActions actions;
  final void Function(DictionaryEntry entry, DictionaryStatus status)
  onChangeStatus;
  final ValueChanged<DictionaryEntry> onEdit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return ListView.builder(
      itemCount: rows.length,
      itemBuilder: (BuildContext context, int index) {
        final row = rows[index];
        final entry = row.entry;
        final extra = row.extra;

        return Card(
          margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: ListTile(
            title: Text(entry.name),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                if (extra != null) Text(extra),
                const SizedBox(height: 4),
                // 状态与版本放在副标题里而不是行尾：窄屏的行尾只放操作按钮，
                // 塞进去就会把名称挤成一行省略号。
                Row(
                  children: <Widget>[
                    DictionaryStatusChip(status: entry.status),
                    const SizedBox(width: 8),
                    Text(
                      '版本 ${entry.version}',
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
              ],
            ),
            // 只读用户这里什么都不给：一个「点了就报 403」的按钮
            // 比没有按钮更让人困惑。
            trailing: !actions.canManage
                ? null
                : Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      _DictionaryStatusMenu(
                        entry: entry,
                        actions: actions,
                        onSelected: (DictionaryStatus status) =>
                            onChangeStatus(entry, status),
                      ),
                      IconButton(
                        tooltip: '编辑',
                        onPressed: actions.isEnabled
                            ? () => onEdit(entry)
                            : null,
                        icon: const Icon(Icons.edit_outlined),
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
final class _DictionaryTable extends StatelessWidget {
  const _DictionaryTable({
    required this.rows,
    required this.actions,
    required this.onChangeStatus,
    required this.onEdit,
  });

  final List<DictionaryRow> rows;
  final DictionaryRowActions actions;
  final void Function(DictionaryEntry entry, DictionaryStatus status)
  onChangeStatus;
  final ValueChanged<DictionaryEntry> onEdit;

  @override
  Widget build(BuildContext context) {
    // 两层滚动：外层纵向、内层横向。列加起来在窄一点的宽屏上仍会超宽，
    // 没有横向滚动就会被裁掉（而裁掉的多半是最右边的「操作」列）。
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: DataTable(
          columns: const <DataColumn>[
            DataColumn(label: Text('名称')),
            DataColumn(label: Text('附加信息')),
            DataColumn(label: Text('状态')),
            DataColumn(label: Text('数据版本'), numeric: true),
            DataColumn(label: Text('操作')),
          ],
          rows: <DataRow>[
            for (final row in rows)
              DataRow(
                cells: <DataCell>[
                  DataCell(Text(row.entry.name)),
                  DataCell(Text(row.extra ?? '—')),
                  DataCell(DictionaryStatusChip(status: row.entry.status)),
                  DataCell(Text('${row.entry.version}')),
                  DataCell(
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        if (actions.canManage) ...<Widget>[
                          _DictionaryStatusMenu(
                            entry: row.entry,
                            actions: actions,
                            onSelected: (DictionaryStatus status) =>
                                onChangeStatus(row.entry, status),
                          ),
                          TextButton(
                            onPressed: actions.isEnabled
                                ? () => onEdit(row.entry)
                                : null,
                            child: const Text('编辑'),
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

/// 型号所属品名的显示名。
///
/// 候选里找不到就如实显示编号：品名可能刚被别处停用了（那时它不在候选里），
/// 也可能这一次就没拉到候选。编一个名字出来会让用户以为这条型号挂得好好的。
String? _parentNameOf(DictionaryEntry entry, List<DictionaryEntry> parents) {
  final id = entry.parentId;
  if (id == null) return null;
  for (final parent in parents) {
    if (parent.id == id) return parent.name;
  }
  return '品名 #$id';
}
