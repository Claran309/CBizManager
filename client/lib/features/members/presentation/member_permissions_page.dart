import 'package:c_biz_docs_manager/core/auth/auth_controller.dart';
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

/// 成员权限替换页。
///
/// **仅组主账号可进入**：这是「谁能看哪张单子」的授权入口，普通成员即便拥有
/// `member.manage` 也只能管理状态、不能改权限，否则等于把提权能力交到被管理者手里。
/// 拦人的是路由守卫（`isOwnerOnlyLocation`）与后端，本页不做角色判断 ——
/// 前端裁剪只是体验与减噪，真正的授权始终在后端。
///
/// [membershipId] 由路由层解析后注入：页面自己不碰 URL，「地址写错怎么办」
/// 只有一个地方需要关心（解析失败回成员列表并提示）。
final class MemberPermissionsPage extends ConsumerStatefulWidget {
  const MemberPermissionsPage({required this.membershipId, super.key});

  /// 已在路由层校验为正整数的成员编号。
  final int membershipId;

  @override
  ConsumerState<MemberPermissionsPage> createState() =>
      _MemberPermissionsPageState();
}

final class _MemberPermissionsPageState
    extends ConsumerState<MemberPermissionsPage> {
  /// 本地草稿：用户**当前勾选**的权限码集合。
  ///
  /// 为什么不直接把勾选写回 `MemberState.permissions`：勾选是「还没提交的意图」，
  /// 它不是服务端事实。写回状态会让列表页也看到一份没保存的权限，
  /// 而且「用户改主意了、想放弃这次修改」这件事将无从谈起。
  ///
  /// 为 null 表示「还没有基线可改」——此时页面显示加载态，不摆一堆空复选框。
  Set<String>? _draft;

  /// 草稿是基于哪一版快照播种的。
  ///
  /// 版本一变（保存成功、冲突后重读、换了个成员）就重新播种：把上一版的勾选
  /// 当作这一版的起点，用户就会拿着一个过期基线去整体替换 —— 保存下去等于
  /// 把别人刚做的授权改动顺手抹掉。
  int? _draftVersion;

  @override
  void initState() {
    super.initState();
    // 首帧之后再拉数据：initState 期间读 Controller 并触发状态变化会撞上
    // 「build 期间改状态」的断言。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final controller = ref.read(memberControllerProvider.notifier);
      // 目录与快照**并发**拉取：两者互不依赖（一个来自固定常量表、
      // 一个来自这条成员记录），串起来只是白等一个往返。
      controller.loadPermissionCatalog();
      controller.loadPermissions(widget.membershipId);
    });
  }

  MemberController get _controller =>
      ref.read(memberControllerProvider.notifier);

  /// 把失败提示出来。
  ///
  /// 页面上已经有内容时只飘一条提示条（冲突时附带「重新加载」动作）：
  /// 把整页换成错误视图会让刚看过的成员名、版本号、已勾选项统统消失，
  /// 而用户往往正需要照着它们判断下一步。真正「什么都没有」的首次加载失败
  /// 才交给 [AsyncStateView] 整页呈现，同一条错误不会说两遍。
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

  void _reload() => _controller.loadPermissions(widget.membershipId);

  void _toggle(String code, bool selected) {
    final draft = _draft;
    if (draft == null) return;
    setState(() {
      if (selected) {
        draft.add(code);
      } else {
        draft.remove(code);
      }
    });
  }

  Future<void> _save() async {
    final draft = _draft;
    // 版本号取自**快照**而不是页面状态：它必须是服务端给的那一份，
    // 少了它这个整体替换就没有乐观锁，谁都可能覆盖谁。
    final snapshot = ref.read(memberControllerProvider).permissions;
    if (draft == null || snapshot == null) return;
    await _controller.replacePermissions(
      widget.membershipId,
      // 传副本：Controller 会把集合放到状态里，页面之后还要继续改这个草稿。
      Set<String>.of(draft),
      snapshot.version,
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(memberControllerProvider);
    final snapshot = state.permissions;
    // 状态里挂着的可能还是**上一个**成员（切换到本页时的中间态），
    // 编号对不上就不当基线用 —— 否则会拿着 A 的权限去渲染 B 的页面。
    final hasSnapshot =
        snapshot != null && snapshot.membershipId == widget.membershipId;

    ref.listen<MemberState>(memberControllerProvider, (
      MemberState? previous,
      MemberState next,
    ) {
      final failure = next.failure;
      final incoming = next.permissions;
      final hasSnapshotNow =
          incoming != null && incoming.membershipId == widget.membershipId;

      // 已经由页面内联呈现的失败就不再飘提示条，同一条错误不说两遍：
      // - 没有快照 → 整页交给 AsyncStateView；
      // - 目录为空 → 正文里那张「权限目录加载失败」的卡片，且它带重试按钮。
      final shownInline = !hasSnapshotNow || next.permissionCatalog.isEmpty;
      if (failure != null &&
          !identical(failure, previous?.failure) &&
          !shownInline) {
        _presentFailure(failure);
      }

      if (incoming == null || !hasSnapshotNow) return;
      if (_draftVersion == incoming.version) return;
      // 重新播种。冲突后被重读也走这里：提示条留着，勾选状态回到服务端的最新值，
      // 用户看着新基线重新决定要不要改 —— **绝不自动重提**，
      // 那等于替他做了一个他并不知道自己在做的决定。
      setState(() {
        _draft = Set<String>.of(incoming.permissionCodes);
        _draftVersion = incoming.version;
      });
    });

    // 导航项随身份裁剪（普通成员的壳里不该出现「邀请码」）。
    final profile = ref.watch(authControllerProvider).session?.profile;

    final member = _memberOf(state.items);
    final draft = _draft;
    final hasChanges =
        hasSnapshot &&
        draft != null &&
        !_sameCodes(draft, snapshot.permissionCodes);

    return ResponsiveScaffold(
      title: member == null ? '成员权限' : '成员权限 · ${member.displayName}',
      destinations: tenantDestinations(profile),
      // 权限页是成员功能的下级页面，让「成员」这一项保持高亮
      // （ResponsiveScaffold 会按最长路径前缀匹配）。
      currentRoute: '/members/${widget.membershipId}/permissions',
      actions: <Widget>[
        IconButton(
          tooltip: '返回成员列表',
          onPressed: () => context.go('/members'),
          icon: const Icon(Icons.arrow_back),
        ),
        IconButton(
          tooltip: '重新加载',
          onPressed: state.isWriting ? null : _reload,
          icon: const Icon(Icons.refresh),
        ),
      ],
      body: AsyncStateView(
        isLoading: state.isLoadingPermissions && !hasSnapshot,
        failure: hasSnapshot ? null : state.failure,
        isEmpty: !hasSnapshot,
        onRetry: _reload,
        emptyMessage: '没有取到该成员的权限',
        child: !hasSnapshot
            ? const SizedBox.shrink()
            : _PermissionsBody(
                member: member,
                membershipId: widget.membershipId,
                version: snapshot.version,
                catalog: state.permissionCatalog,
                isLoadingCatalog: state.isLoadingCatalog,
                draft: draft ?? const <String>{},
                isWriting: state.isWriting,
                hasChanges: hasChanges,
                onToggle: _toggle,
                onReloadCatalog: _controller.loadPermissionCatalog,
                onSave: _save,
                onBack: () => context.go('/members'),
              ),
      ),
    );
  }

  /// 从列表快照里找出当前这个成员。
  ///
  /// 用户几乎总是从成员列表点进来的，所以列表里通常就有他。找不到（例如直接
  /// 敲地址进来、或列表被筛选过）也不是错误 —— 头部退化成只显示编号即可，
  /// 权限快照本身才是本页的主体。
  Member? _memberOf(List<Member> items) {
    for (final item in items) {
      if (item.membershipId == widget.membershipId) return item;
    }
    return null;
  }
}

/// 权限正文：成员概要 + 可分配权限复选框 + 保存。
final class _PermissionsBody extends StatelessWidget {
  const _PermissionsBody({
    required this.member,
    required this.membershipId,
    required this.version,
    required this.catalog,
    required this.isLoadingCatalog,
    required this.draft,
    required this.isWriting,
    required this.hasChanges,
    required this.onToggle,
    required this.onReloadCatalog,
    required this.onSave,
    required this.onBack,
  });

  final Member? member;
  final int membershipId;
  final int version;
  final List<PermissionCatalogItem> catalog;
  final bool isLoadingCatalog;

  /// 当前勾选。**由快照播种**，不是由目录播种 —— 这一点很关键，见 [extraCodes]。
  final Set<String> draft;

  final bool isWriting;
  final bool hasChanges;
  final void Function(String code, bool selected) onToggle;
  final VoidCallback onReloadCatalog;
  final VoidCallback onSave;
  final VoidCallback onBack;

  /// 「成员身上有、但当前目录里没有」的权限码。
  ///
  /// 目录由服务端下发，客户端不维护自己的一份 —— 但也**不能**因为目录里没写
  /// 就把它从草稿里抹掉：真出现了这种码（后端新加的、已下线的、或目录接口
  /// 只返回了一个子集），静默丢弃等于让管理员在毫不知情的情况下收回了一项权限。
  /// 所以这里照旧显示出来，让他自己决定留还是去掉。
  List<String> get extraCodes {
    final known = <String>{for (final item in catalog) item.code};
    final extras = <String>[
      for (final code in draft)
        if (!known.contains(code)) code,
    ];
    return extras..sort();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final selectedCount = draft.length;
    // 没有改动就别让他点：整体替换会推进版本号，白点一次就是一次无意义的
    // 乐观锁冲突来源（也让「数据已被修改」的提示变得廉价）。
    final canSave = hasChanges && !isWriting;

    // 只有**拿到目录之后**才谈得上「目录之外的权限」。
    //
    // 目录为空时（还在加载、或加载失败）每个权限码都会被算成「目录之外」，
    // 于是页面会凭空告诉管理员「这些码已经没人认了，取消勾选即可收回」——
    // 而真实原因只是这一次没拉到目录。这种情况已经由正文里那张
    // 「权限目录加载失败」的卡片说明，不该再叠一层误导。
    final showExtras = catalog.isNotEmpty && extraCodes.isNotEmpty;

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
                        Text(
                          member == null
                              ? '成员 #$membershipId'
                              : '${member!.displayName}'
                                    '（${member!.username}）',
                          style: theme.textTheme.titleLarge,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          member == null
                              ? '成员角色未知'
                              : (member!.isGroupOwner ? '组主账号' : '业务员'),
                          style: theme.textTheme.bodySmall,
                        ),
                        // 版本号是乐观锁凭据，展示出来是为了让管理员在反复遇到
                        // 「数据已被其他操作修改」时有个可对照的数字。
                        Text('数据版本 $version', style: theme.textTheme.bodySmall),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                // Wrap 而不是 Row：窄屏放不下时自动折行，
                // 而不是把右边的计数挤出可视区（横向 overflow 在测试里是硬失败）。
                Wrap(
                  spacing: 12,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: <Widget>[
                    Text('可分配权限', style: theme.textTheme.titleMedium),
                    Text(
                      '已选 $selectedCount 项',
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                _CatalogSection(
                  catalog: catalog,
                  isLoading: isLoadingCatalog,
                  draft: draft,
                  enabled: !isWriting,
                  onToggle: onToggle,
                  onReload: onReloadCatalog,
                ),
                if (showExtras) ...<Widget>[
                  const SizedBox(height: 20),
                  Text('目录之外的权限', style: theme.textTheme.titleMedium),
                  const SizedBox(height: 4),
                  Text(
                    '这些权限码不在服务端当前的权限目录里。它们不会被自动去掉，'
                    '取消勾选即可收回。',
                    style: theme.textTheme.bodySmall,
                  ),
                  const SizedBox(height: 8),
                  Card(
                    child: Column(
                      children: <Widget>[
                        for (final code in extraCodes)
                          CheckboxListTile(
                            value: true,
                            onChanged: isWriting
                                ? null
                                : (bool? selected) =>
                                      onToggle(code, selected ?? false),
                            title: Text(code),
                            subtitle: const Text('不在当前权限目录中'),
                          ),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: 24),
                FilledButton.icon(
                  onPressed: canSave ? onSave : null,
                  icon: const Icon(Icons.save_outlined),
                  label: const Text('保存权限'),
                ),
                const SizedBox(height: 8),
                Text(
                  hasChanges
                      ? '保存后会整体替换该成员的权限：未勾选的会被收回，'
                            '勾选的会立即生效。'
                      : '权限没有改动。',
                  style: theme.textTheme.bodySmall,
                ),
                if (isWriting) ...<Widget>[
                  const SizedBox(height: 16),
                  const Center(child: CircularProgressIndicator()),
                ],
                const SizedBox(height: 12),
                TextButton.icon(
                  onPressed: isWriting ? null : onBack,
                  icon: const Icon(Icons.arrow_back),
                  label: const Text('返回成员列表'),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// 权限目录这一段：加载中 / 拉取失败可重试 / 正常渲染复选框。
///
/// 目录为空**不等于**「这个成员没有权限可分配」：它更可能是这次没拉到。
/// 两种情况给的东西必须不一样，否则管理员会把「加载失败」读成「这组没有权限」，
/// 然后按着那份空清单去整体替换 —— 那是一次大面积误收回。
final class _CatalogSection extends StatelessWidget {
  const _CatalogSection({
    required this.catalog,
    required this.isLoading,
    required this.draft,
    required this.enabled,
    required this.onToggle,
    required this.onReload,
  });

  final List<PermissionCatalogItem> catalog;
  final bool isLoading;
  final Set<String> draft;
  final bool enabled;
  final void Function(String code, bool selected) onToggle;
  final VoidCallback onReload;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (catalog.isEmpty) {
      if (isLoading) {
        return const Padding(
          padding: EdgeInsets.symmetric(vertical: 24),
          child: Center(child: CircularProgressIndicator()),
        );
      }
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text('权限目录加载失败', style: theme.textTheme.bodyMedium),
              const SizedBox(height: 8),
              TextButton(onPressed: onReload, child: const Text('重新加载目录')),
            ],
          ),
        ),
      );
    }

    return Card(
      child: Column(
        children: <Widget>[
          for (final item in catalog)
            CheckboxListTile(
              value: draft.contains(item.code),
              onChanged: enabled
                  ? (bool? selected) => onToggle(item.code, selected ?? false)
                  : null,
              title: Text(item.name),
              subtitle: Text('${item.description}\n${item.code}'),
            ),
        ],
      ),
    );
  }
}

/// 两个权限码集合是否完全相同。
///
/// 只比长度再比包含关系，不做排序：集合语义下这就等价，也不必为一次比较
/// 去复制并排序两个集合。
bool _sameCodes(Set<String> left, Set<String> right) =>
    left.length == right.length && left.containsAll(right);
