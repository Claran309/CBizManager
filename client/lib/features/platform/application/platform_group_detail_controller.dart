import 'package:c_biz_docs_manager/core/error/app_failure.dart';
import 'package:c_biz_docs_manager/features/platform/data/platform_repository.dart';
import 'package:c_biz_docs_manager/features/platform/domain/platform_group.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 某个组的治理详情状态，按 groupId 分片。
///
/// 用 family 而不是「一个 Controller 装当前组」：详情页可以被连着打开多个
/// （在列表里进进出出），若共用一个实例，从 A 组退出来进 B 组的瞬间，
/// 界面上会先闪过 A 组的主账号与成员数 —— 那是最容易让人误操作的一种错。
/// family 让每个 groupId 各有一份互不干扰的状态。
///
/// 用**非** autoDispose：本项目的会话级 Provider 都由认证作用域整体销毁，
/// 少一层自动销毁就少一处「被读了却立刻销毁」的时序陷阱；代价只是同时浏览过的
/// 组会各自留一份状态，量级（几十个组）完全可以忽略。
final platformGroupDetailControllerProvider =
    NotifierProvider.family<
      PlatformGroupDetailController,
      PlatformGroupDetailState,
      int
    >(
      PlatformGroupDetailController.new,
      dependencies: [platformRepositoryProvider],
    );

final class PlatformGroupDetailState {
  const PlatformGroupDetailState({
    this.detail,
    this.isLoading = false,
    this.isWriting = false,
    this.failure,
  });

  /// 详情本体；首次加载完成前为 null。
  final PlatformGroupDetail? detail;

  final bool isLoading;

  /// 是否有写操作在途（启停 / 交接主账号）。
  final bool isWriting;

  final AppFailure? failure;

  PlatformGroupDetailState copyWith({
    PlatformGroupDetail? detail,
    bool? isLoading,
    bool? isWriting,
    AppFailure? failure,
    bool clearFailure = false,
  }) {
    return PlatformGroupDetailState(
      detail: detail ?? this.detail,
      isLoading: isLoading ?? this.isLoading,
      isWriting: isWriting ?? this.isWriting,
      failure: clearFailure ? null : failure ?? this.failure,
    );
  }
}

/// 单个组的详情加载、启停与主账号交接。
final class PlatformGroupDetailController
    extends Notifier<PlatformGroupDetailState> {
  /// [groupId] 由 family 在构造时注入（Riverpod 3 的 family 创建函数接收参数），
  /// 之后不再变化 —— 所以它可以是 final 字段，也没有「参数变了要重建」的问题。
  PlatformGroupDetailController(this.groupId);

  /// 本实例负责的组 id。
  final int groupId;

  var _loadGeneration = 0;
  Future<void> _writeTail = Future<void>.value();
  var _disposed = false;

  PlatformRepository get _repository => ref.read(platformRepositoryProvider);

  bool _isCurrent(int generation) =>
      !_disposed && generation == _loadGeneration;

  @override
  PlatformGroupDetailState build() {
    ref.onDispose(() {
      _disposed = true;
      _loadGeneration++;
    });
    return const PlatformGroupDetailState();
  }

  Future<void> load() async {
    final generation = ++_loadGeneration;
    if (_disposed) return;
    state = state.copyWith(isLoading: true, clearFailure: true);
    try {
      final detail = await _repository.getGroup(groupId);
      if (_isCurrent(generation)) {
        state = state.copyWith(detail: detail, clearFailure: true);
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

  Future<void> refresh() => load();

  /// 停用或启用本组。版本号取自当前详情 —— 界面上的操作按钮只有在详情到手后
  /// 才会渲染出来，所以正常路径下一定拿得到。
  Future<void> changeStatus(GroupStatus status) {
    final repository = _repository;
    final current = state.detail;
    if (_disposed || current == null) {
      // 详情还没到手就点按钮：界面不会渲染出这种按钮，真发生了说明有竞态。
      // 静默不做事比把页面崩掉稳妥，毕竟用户的目标已经无从执行了。
      return Future<void>.value();
    }
    final version = current.group.version;
    return _enqueueWrite(() async {
      if (_disposed) return;
      state = state.copyWith(isWriting: true, clearFailure: true);
      try {
        final updated = await repository.changeStatus(groupId, status, version);
        if (_disposed) return;
        // 只换摘要：启停组不改变成员构成，计数与候选人还是原来那一份。
        state = state.copyWith(
          detail: _withGroup(state.detail, updated),
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

  /// 交接主账号。
  ///
  /// [draft] 里的 version 由调用方从当前详情取；这里刻意**不**替它改成最新值：
  /// 交接是个不可逆的敏感操作，如果对话框打开期间组被别处改过，正确做法是
  /// 让服务端拒绝、我们重读一份最新详情让用户重新确认，而不是拿着旧界面的
  /// 意图去盖新数据。
  Future<void> changeOwner(OwnerChangeDraft draft) {
    final repository = _repository;
    if (_disposed) return Future<void>.value();
    return _enqueueWrite(() async {
      if (_disposed) return;
      state = state.copyWith(isWriting: true, clearFailure: true);
      try {
        final detail = await repository.changeOwner(groupId, draft);
        if (_disposed) return;
        state = state.copyWith(detail: detail, clearFailure: true);
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

  /// 冲突后的处理：先把最新详情拉回来，再把冲突原因放回状态。
  ///
  /// 两件事都要做，顺序也不能反：
  /// - 不重读，用户面前的 version 与候选列表都已经是错的，他再点一次还会撞；
  /// - 只重读不保留失败，用户会以为操作成功了（数据确实「变了」，只是没变成
  ///   他要的样子），所以失败提示必须留到下一次成功操作之前。
  ///
  /// 如果重读本身也失败了，则保留那个更新的失败（断网比版本冲突更紧迫），
  /// 不必再塞回旧的冲突原因。
  Future<void> _reloadAfterConflict(AppFailure conflict) async {
    await load();
    if (_disposed) return;
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

/// 只替换详情里的摘要部分，其余保持不动。
PlatformGroupDetail? _withGroup(
  PlatformGroupDetail? detail,
  PlatformGroup group,
) => detail == null
    ? null
    : PlatformGroupDetail(
        group: group,
        memberCounts: detail.memberCounts,
        ownerCandidates: detail.ownerCandidates,
      );
