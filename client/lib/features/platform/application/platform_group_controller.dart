import 'package:c_biz_docs_manager/core/error/app_failure.dart';
import 'package:c_biz_docs_manager/features/platform/data/platform_repository.dart';
import 'package:c_biz_docs_manager/features/platform/domain/platform_group.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 平台组列表的状态持有者。
///
/// [dependencies] 这一行是必须的：Riverpod 3 的传递式作用域只会把
/// 「显式声明了依赖」的 Provider 挂到覆盖了该依赖的那个容器里。这里依赖的是
/// [platformRepositoryProvider]，它由平台管理员的会话作用域覆盖 —— 声明之后，
/// 本 Controller 就跟着那个作用域一起生灭，登出即销毁，不会把上一个管理员的
/// 组列表留在根容器里被下一个会话读到。
final platformGroupControllerProvider =
    NotifierProvider<PlatformGroupController, PlatformGroupState>(
      PlatformGroupController.new,
      dependencies: [platformRepositoryProvider],
    );

final class PlatformGroupState {
  const PlatformGroupState({
    this.items = const <PlatformGroup>[],
    this.query = const PlatformGroupQuery(),
    this.isLoading = false,
    this.isWriting = false,
    this.failure,
  });

  /// 当前这一页的组。
  final List<PlatformGroup> items;

  /// 当前生效的筛选与分页条件；[PlatformGroupController.refresh] 会复用它。
  final PlatformGroupQuery query;

  /// 是否正在加载（首次加载或换筛选条件）。
  final bool isLoading;

  /// 是否有写操作在途（启停组）。界面据此禁用按钮，避免重复提交。
  final bool isWriting;

  /// 最近一次失败，成功后清空。由展示层翻译成文案。
  final AppFailure? failure;

  PlatformGroupState copyWith({
    List<PlatformGroup>? items,
    PlatformGroupQuery? query,
    bool? isLoading,
    bool? isWriting,
    AppFailure? failure,
    bool clearFailure = false,
  }) {
    return PlatformGroupState(
      items: items ?? this.items,
      query: query ?? this.query,
      isLoading: isLoading ?? this.isLoading,
      isWriting: isWriting ?? this.isWriting,
      // 失败要做「清除」和「保留」两件事，用一个 bool 明确区分，
      // 不能靠传 null 表达清除——传 null 同时也是「不改」的意思。
      failure: clearFailure ? null : failure ?? this.failure,
    );
  }
}

/// 平台组列表的加载与启停。
final class PlatformGroupController extends Notifier<PlatformGroupState> {
  /// 加载轮次。每次 [load] 自增，回来的结果必须还是最新一轮才允许写 state。
  var _loadGeneration = 0;

  /// 写操作队列的尾巴。启停要排队执行：并发点两个组的开关时，
  /// 两个请求会各自拿到同一个 `version` 系列，交错执行必然有一个撞 409。
  Future<void> _writeTail = Future<void>.value();

  /// 会话作用域是否已销毁。销毁后写 state 会抛错，更糟的是会把上一个人的
  /// 数据画到新会话的界面上，所以每个写入点都要先看这个标记。
  var _disposed = false;

  PlatformRepository get _repository => ref.read(platformRepositoryProvider);

  bool _isCurrent(int generation) =>
      !_disposed && generation == _loadGeneration;

  @override
  PlatformGroupState build() {
    ref.onDispose(() {
      _disposed = true;
      // 让在途的 load 结果立刻作废。
      _loadGeneration++;
    });
    return const PlatformGroupState();
  }

  /// 按 [query] 加载一页。
  ///
  /// 只取一页：平台组列表由界面翻页（后台只有 100 来个组，运维也更关心
  /// 「第 1 页有几组停用」而不是一次性拉全）。
  Future<void> load(PlatformGroupQuery query) async {
    final generation = ++_loadGeneration;
    if (_disposed) return;
    // query 立刻写进 state：即使这次请求还没回来，refresh 也应该按新条件刷，
    // 而不是按上一次的条件。
    state = state.copyWith(query: query, isLoading: true, clearFailure: true);
    try {
      final page = await _repository.listGroups(query);
      if (_isCurrent(generation)) {
        state = state.copyWith(items: page.items, clearFailure: true);
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
  Future<void> refresh() => load(state.query);

  /// 停用或启用一个组。
  ///
  /// 把 [group] 整个传进来而不是只传 id：乐观锁需要它身上那个 `version`，
  /// 而列表里每一行恰好就有最新的一份。成功后服务端会回一个 version +1 的摘要，
  /// 用它替换列表项 —— 否则用户紧接着再点一次这个组，用的还是旧 version，
  /// 会白白撞一次 409。
  Future<void> changeStatus(PlatformGroup group, GroupStatus status) {
    // 先取好仓储：写操作是排队的，真正执行时可能已经不在这个作用域里，
    // 那时碰 ref 会抛错。
    final repository = _repository;
    return _enqueueWrite(() async {
      if (_disposed) return;
      state = state.copyWith(isWriting: true, clearFailure: true);
      try {
        final updated = await repository.changeStatus(
          group.id,
          status,
          group.version,
        );
        if (_disposed) return;
        state = state.copyWith(
          items: _replaceGroup(state.items, updated),
          clearFailure: true,
        );
      } on AppFailure catch (failure) {
        if (_disposed) return;
        // 列表这一层只如实报告失败：409 说明手上的数据旧了，展示层会按
        // FailurePresenter 的 shouldRefresh 提示「刷新后重试」，由用户决定
        // 什么时候重看这份全平台列表（自动刷新会把他的翻页位置也冲掉）。
        state = state.copyWith(failure: failure);
      } finally {
        if (!_disposed) {
          state = state.copyWith(isWriting: false);
        }
      }
    });
  }

  /// 把写操作追加到串行队列。
  ///
  /// 返回的是**这一次**操作的结果，而队列尾巴只关心「前一个结束了」，
  /// 所以尾巴上挂了空错误处理：某一次写失败不该让后续写永远无法开始。
  Future<void> _enqueueWrite(Future<void> Function() operation) {
    final result = _writeTail.then((_) => operation());
    _writeTail = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }
}

List<PlatformGroup> _replaceGroup(
  List<PlatformGroup> items,
  PlatformGroup updated,
) => <PlatformGroup>[
  for (final group in items)
    if (group.id == updated.id) updated else group,
];
