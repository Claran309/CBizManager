import 'package:c_biz_docs_manager/core/error/app_failure.dart';
import 'package:c_biz_docs_manager/features/members/data/member_repository.dart';
import 'package:c_biz_docs_manager/features/members/domain/member.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Bootstrap or a future authenticated scope must provide the concrete
/// repository after the active user and group are known.
final memberRepositoryProvider = Provider<MemberRepository>((Ref ref) {
  throw StateError('MemberRepository has not been configured');
});

final memberControllerProvider =
    NotifierProvider<MemberController, MemberState>(
      MemberController.new,
      // 声明「本 Controller 属于 memberRepositoryProvider 所在的作用域」。
      //
      // Riverpod 3 的传递式作用域（transitive scoping）会据此把本 Provider
      // 挂载到**覆盖了该仓储的那个容器**里，也就是认证会话作用域；
      // 没被覆盖时（例如平台管理员）才退回根容器。
      //
      // 少了这一行，本 Controller 会挂在根容器上被所有会话共享：
      // 换账号时它不会重建，上一个人的成员列表会被下一个会话直接读到。
      // 这里读的是 ref.read 而不是 build 里的 watch，Riverpod 无从自动推断，
      // 所以必须手动声明。
      dependencies: [memberRepositoryProvider],
    );

final class MemberState {
  const MemberState({
    this.items = const <Member>[],
    this.permissionCatalog = const <PermissionCatalogItem>[],
    this.permissions,
    this.isLoading = false,
    this.isWriting = false,
    this.isLoadingCatalog = false,
    this.isLoadingPermissions = false,
    this.failure,
  });

  final List<Member> items;

  /// 后端认可的固定权限目录。权限页的复选框由它渲染 —— 客户端不维护自己的一份。
  final List<PermissionCatalogItem> permissionCatalog;

  /// 当前打开的权限页里那一份权限快照；没进权限页时为 null。
  ///
  /// 与邀请码明文同样的道理：它是「此刻屏幕上展示的那一份」，
  /// 换目标时必须先清掉，否则用户会按着上一个人的勾选状态做决定。
  final MemberPermissions? permissions;

  final bool isLoading;
  final bool isWriting;
  final bool isLoadingCatalog;
  final bool isLoadingPermissions;
  final AppFailure? failure;

  /// 权限页正在展示谁。列表页用它判断「要不要把这一行的权限也画出来」。
  int? get permissionsMembershipId => permissions?.membershipId;

  MemberState copyWith({
    List<Member>? items,
    List<PermissionCatalogItem>? permissionCatalog,
    MemberPermissions? permissions,
    bool? isLoading,
    bool? isWriting,
    bool? isLoadingCatalog,
    bool? isLoadingPermissions,
    AppFailure? failure,
    bool clearPermissions = false,
    bool clearFailure = false,
  }) {
    return MemberState(
      items: items ?? this.items,
      permissionCatalog: permissionCatalog ?? this.permissionCatalog,
      // 传 null 既能表达「不改」也能表达「清空」，所以清空要靠显式开关。
      permissions: clearPermissions ? null : permissions ?? this.permissions,
      isLoading: isLoading ?? this.isLoading,
      isWriting: isWriting ?? this.isWriting,
      isLoadingCatalog: isLoadingCatalog ?? this.isLoadingCatalog,
      isLoadingPermissions: isLoadingPermissions ?? this.isLoadingPermissions,
      failure: clearFailure ? null : failure ?? this.failure,
    );
  }
}

/// Owns member screen state so widgets never need to call Dio directly.
final class MemberController extends Notifier<MemberState> {
  var _loadGeneration = 0;
  Future<void> _writeTail = Future<void>.value();

  /// 会话作用域是否已销毁。
  ///
  /// 销毁后仍然可能有一次在途请求回到这里（切账号的瞬间最容易发生），
  /// 此时写 state 会抛错，更糟的是会把上一个人的数据写到新会话的界面上。
  /// 所以每个写入点都要先看这个标记。
  var _disposed = false;

  /// 当前筛选条件。[load] 会记住它，供 [refresh] 与冲突后的重读复用。
  var _query = const MemberQuery();

  MemberRepository get _repository => ref.read(memberRepositoryProvider);

  /// 在途结果是否还允许写回状态。已有更新的一轮请求或已被销毁时都不允许。
  bool _isCurrent(int generation) =>
      !_disposed && generation == _loadGeneration;

  @override
  MemberState build() {
    ref.onDispose(() {
      _disposed = true;
      // 让在途的 load 结果立刻作废。
      _loadGeneration++;
    });
    return const MemberState();
  }

  /// 按 [query] 加载成员；不传表示拉全部。
  Future<void> load([MemberQuery query = const MemberQuery()]) async {
    final generation = ++_loadGeneration;
    if (_disposed) return;
    // 立刻记住条件：即使这次请求还没回来，refresh 也应该按新条件刷。
    _query = query;
    state = state.copyWith(isLoading: true, clearFailure: true);
    try {
      final items = await _repository.listMembers(query);
      if (_isCurrent(generation)) {
        state = state.copyWith(items: items, clearFailure: true);
      }
    } on AppFailure catch (failure) {
      if (_isCurrent(generation)) {
        state = state.copyWith(failure: failure);
      }
    } finally {
      if (_isCurrent(generation)) {
        state = state.copyWith(isLoading: false);
      }
    }
  }

  /// 用当前筛选条件重新加载。
  Future<void> refresh() => load(_query);

  /// 加载后端认可的固定权限目录。
  ///
  /// 已经拿到就不重复拉：权限页进入时会并发拉「目录 + 这一份权限」，
  /// 每进一次都重拉目录只是白发一次请求 —— 这张表是后端固化的常量。
  Future<void> loadPermissionCatalog() async {
    if (_disposed) return;
    if (state.permissionCatalog.isNotEmpty) return;
    state = state.copyWith(isLoadingCatalog: true, clearFailure: true);
    try {
      final catalog = await _repository.getPermissionCatalog();
      if (_disposed) return;
      state = state.copyWith(permissionCatalog: catalog, clearFailure: true);
    } on AppFailure catch (failure) {
      if (_disposed) return;
      state = state.copyWith(failure: failure);
    } finally {
      if (!_disposed) {
        state = state.copyWith(isLoadingCatalog: false);
      }
    }
  }

  /// 读取某个成员的权限快照（权限页的基线）。
  Future<void> loadPermissions(int membershipId) async {
    if (_disposed) return;
    // **先清掉上一份再拉**：用户点开 B 的权限页时，屏幕上若还留着 A 的勾选状态，
    // 他会以为那就是 B 现在的权限，然后拿一个错的基线去改，
    // 保存下去就是把 B 的权限替换成了 A 的那一套。
    state = state.copyWith(
      isLoadingPermissions: true,
      clearPermissions: true,
      clearFailure: true,
    );
    try {
      final permissions = await _repository.getPermissions(membershipId);
      if (_disposed) return;
      state = state.copyWith(
        permissions: permissions,
        items: _withPermissions(state.items, permissions),
        clearFailure: true,
      );
    } on AppFailure catch (failure) {
      if (_disposed) return;
      state = state.copyWith(failure: failure);
    } finally {
      if (!_disposed) {
        state = state.copyWith(isLoadingPermissions: false);
      }
    }
  }

  Future<void> changeStatus(
    int membershipId,
    MemberStatus status,
    int version,
  ) {
    // 先取好仓储：dispose 之后再碰 ref 会抛错，而写操作是排队的，
    // 真正执行时可能已经不在这个作用域里了。
    final repository = _repository;
    return _enqueueWrite(() async {
      if (_disposed) return;
      state = state.copyWith(isWriting: true, clearFailure: true);
      try {
        final updated = await repository.changeStatus(
          membershipId,
          status,
          version,
        );
        if (_disposed) return;
        state = state.copyWith(
          items: _replaceMember(state.items, updated),
          clearFailure: true,
        );
      } on ConflictFailure catch (failure) {
        if (_disposed) return;
        await _reloadAfterConflict(failure);
      } on AppFailure catch (failure) {
        if (_disposed) return;
        state = state.copyWith(failure: failure);
      } finally {
        if (!_disposed) {
          state = state.copyWith(isWriting: false);
        }
      }
    });
  }

  Future<void> replacePermissions(
    int membershipId,
    Set<String> codes,
    int version,
  ) {
    final repository = _repository;
    return _enqueueWrite(() async {
      if (_disposed) return;
      state = state.copyWith(isWriting: true, clearFailure: true);
      try {
        final permissions = await repository.replacePermissions(
          membershipId,
          codes,
          version,
        );
        if (_disposed) return;
        state = state.copyWith(
          items: _withPermissions(state.items, permissions),
          // 保存成功后把新快照作为本地基线：否则用户紧接着再改一次，
          // 手里拿的还是旧 version，会白撞一次 409。
          permissions: permissions,
          clearFailure: true,
        );
      } on ConflictFailure catch (failure) {
        if (_disposed) return;
        // 冲突后连这份权限详情一起重读：用户手里的草稿是基于旧 version 的，
        // 得让他看着最新的勾选状态重新决定要改什么。
        await _reloadAfterConflict(failure, membershipId: membershipId);
      } on AppFailure catch (failure) {
        if (_disposed) return;
        state = state.copyWith(failure: failure);
      } finally {
        if (!_disposed) {
          state = state.copyWith(isWriting: false);
        }
      }
    });
  }

  /// 409 之后重读一次，让用户基于最新数据重新决定。
  ///
  /// **顺序不能反**：`load` 与 `loadPermissions` 内部都会 `clearFailure`，
  /// 所以必须先重读、再把冲突原因放回去，否则刷新会把提示顺手擦掉。
  /// 另外「刷新不等于成功」——数据确实变了，只是没变成用户要的样子，
  /// 这条提示要一直留到用户下一次成功操作之前。
  Future<void> _reloadAfterConflict(
    ConflictFailure conflict, {
    int? membershipId,
  }) async {
    await load(_query);
    if (_disposed) return;
    // 只在「权限页确实开着这个成员」时才重读详情：否则会凭空去拉一份
    // 当前界面根本没在看的权限快照。
    if (membershipId != null && state.permissionsMembershipId == membershipId) {
      await loadPermissions(membershipId);
      if (_disposed) return;
    }
    // 重读本身也失败（比如断网）时保留那个更新的失败：
    // 「连不上」比「版本过期」更紧迫，也更需要用户先处理。
    if (state.failure == null) {
      state = state.copyWith(failure: conflict);
    }
  }

  Future<void> _enqueueWrite(Future<void> Function() operation) {
    final result = _writeTail.then((_) => operation());
    _writeTail = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }
}

List<Member> _replaceMember(List<Member> items, Member updated) => <Member>[
  for (final member in items)
    if (member.membershipId == updated.membershipId) updated else member,
];

/// 把一份权限快照落回列表里对应那一行。
///
/// 列表行与权限页展示的是同一份权限，两处必须一起更新：只改权限页、列表行还是旧的
/// version，用户回到列表再点一次「权限」就会拿着过期版本去改。
List<Member> _withPermissions(
  List<Member> items,
  MemberPermissions permissions,
) => <Member>[
  for (final member in items)
    if (member.membershipId == permissions.membershipId)
      Member(
        membershipId: member.membershipId,
        userId: member.userId,
        username: member.username,
        displayName: member.displayName,
        memberType: member.memberType,
        status: member.status,
        permissionCodes: permissions.permissionCodes,
        version: permissions.version,
      )
    else
      member,
];
