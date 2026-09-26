import 'package:c_biz_docs_manager/core/error/app_failure.dart';
import 'package:c_biz_docs_manager/features/settlements/data/settlement_repository.dart';
import 'package:c_biz_docs_manager/features/settlements/domain/settlement.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 结算列表 / 详情 / 审批的控制器装配点。
///
/// `dependencies` 声明结算仓储装配点，挂到会话作用域、换账号整体重建。
final settlementControllerProvider =
    NotifierProvider<SettlementController, SettlementState>(
      SettlementController.new,
      dependencies: [settlementRepositoryProvider],
    );

/// 结算列表 / 详情页的状态。
final class SettlementState {
  const SettlementState({
    this.items = const <SettlementSummary>[],
    this.detail,
    this.isLoading = false,
    this.isLoadingDetail = false,
    this.isWriting = false,
    this.failure,
  });

  final List<SettlementSummary> items;

  /// 当前打开的结算单详情；没进详情页时为 null。
  final SettlementDetail? detail;

  final bool isLoading;
  final bool isLoadingDetail;
  final bool isWriting;
  final AppFailure? failure;

  SettlementState copyWith({
    List<SettlementSummary>? items,
    SettlementDetail? detail,
    bool? isLoading,
    bool? isLoadingDetail,
    bool? isWriting,
    AppFailure? failure,
    bool clearDetail = false,
    bool clearFailure = false,
  }) {
    return SettlementState(
      items: items ?? this.items,
      detail: clearDetail ? null : detail ?? this.detail,
      isLoading: isLoading ?? this.isLoading,
      isLoadingDetail: isLoadingDetail ?? this.isLoadingDetail,
      isWriting: isWriting ?? this.isWriting,
      failure: clearFailure ? null : failure ?? this.failure,
    );
  }
}

/// 结算单列表 / 详情 / 审批的状态持有者。
///
/// 时序沿用项目三件套：`_loadGeneration`（乱序丢弃）、`_writeTail`（写串行）、
/// `_disposed`（销毁后不写）。与单据 Controller 同构，差异只在「无 kind 分片」。
final class SettlementController extends Notifier<SettlementState> {
  var _loadGeneration = 0;
  Future<void> _writeTail = Future<void>.value();
  var _disposed = false;

  var _query = const SettlementQuery();

  SettlementRepository get _repository =>
      ref.read(settlementRepositoryProvider);

  bool _isCurrent(int generation) =>
      !_disposed && generation == _loadGeneration;

  @override
  SettlementState build() {
    ref.onDispose(() {
      _disposed = true;
      _loadGeneration++;
    });
    return const SettlementState();
  }

  /// 按 [query] 加载结算单列表。
  Future<void> load([SettlementQuery query = const SettlementQuery()]) async {
    final generation = ++_loadGeneration;
    if (_disposed) return;
    _query = query;
    state = state.copyWith(isLoading: true, clearFailure: true);
    try {
      final page = await _repository.list(query);
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
  Future<void> refresh() => load(_query);

  /// 清空当前详情。
  ///
  /// 供「状态驱动导航」在跳走之后复位：申请结算成功后 `detail` 非空，页面据此
  /// 跳到详情页；若不清掉，下次再进申请页会立刻被再弹走一次。
  void clearDetail() {
    if (_disposed) return;
    state = state.copyWith(clearDetail: true);
  }

  /// 加载某个结算单的详情。
  Future<void> loadDetail(int settlementId) async {
    if (_disposed) return;
    state = state.copyWith(
      isLoadingDetail: true,
      clearDetail: true,
      clearFailure: true,
    );
    try {
      final detail = await _repository.get(settlementId);
      if (_disposed) return;
      state = state.copyWith(detail: detail, clearFailure: true);
    } on AppFailure catch (failure) {
      if (_disposed) return;
      state = state.copyWith(failure: failure);
    } finally {
      if (!_disposed) {
        state = state.copyWith(isLoadingDetail: false);
      }
    }
  }

  /// 提交结算申请。成功后把详情写进 state、重读列表。
  Future<void> create(SettlementDraft draft) {
    final repository = _repository;
    return _enqueueWrite(() async {
      if (_disposed) return;
      state = state.copyWith(isWriting: true, clearFailure: true);
      try {
        final detail = await repository.create(draft);
        if (_disposed) return;
        state = state.copyWith(detail: detail, clearFailure: true);
        await load(_query);
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

  /// 审批通过。
  Future<void> approve(int settlementId, int version) {
    final repository = _repository;
    return _enqueueWrite(() async {
      if (_disposed) return;
      state = state.copyWith(isWriting: true, clearFailure: true);
      try {
        final detail = await repository.approve(settlementId, version);
        if (_disposed) return;
        state = state.copyWith(detail: detail, clearFailure: true);
        await load(_query);
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

  /// 审批驳回；[remark] 必填。
  Future<void> reject(int settlementId, int version, String remark) {
    final repository = _repository;
    return _enqueueWrite(() async {
      if (_disposed) return;
      state = state.copyWith(isWriting: true, clearFailure: true);
      try {
        final detail = await repository.reject(settlementId, version, remark);
        if (_disposed) return;
        state = state.copyWith(detail: detail, clearFailure: true);
        await load(_query);
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

  /// 409 之后重读列表，让用户基于最新数据重新决定。
  Future<void> _reloadAfterConflict(ConflictFailure conflict) async {
    await load(_query);
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
