import 'package:c_biz_docs_manager/core/error/app_failure.dart';
import 'package:c_biz_docs_manager/features/finance/data/finance_repository.dart';
import 'package:c_biz_docs_manager/features/finance/domain/finance.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 财务列表 / 登记的控制器装配点，按 [FinanceKind] 分片。
///
/// 付款 / 收款 / 开票是三个独立的记录流，用 family 按 kind 隔离。
final financeControllerProvider =
    NotifierProvider.family<FinanceController, FinanceState, FinanceKind>(
      FinanceController.new,
      dependencies: [
        paymentRepositoryProvider,
        receiptRepositoryProvider,
        invoiceRepositoryProvider,
      ],
    );

/// 财务列表 / 结清视图的状态。
final class FinanceState {
  const FinanceState({
    this.items = const <FinanceRecord>[],
    this.statement,
    this.isLoading = false,
    this.isLoadingStatement = false,
    this.isWriting = false,
    this.failure,
  });

  final List<FinanceRecord> items;

  /// 当前查看的单据结清视图；没查结清视图时为 null。
  final FinanceStatement? statement;

  final bool isLoading;
  final bool isLoadingStatement;
  final bool isWriting;
  final AppFailure? failure;

  FinanceState copyWith({
    List<FinanceRecord>? items,
    FinanceStatement? statement,
    bool? isLoading,
    bool? isLoadingStatement,
    bool? isWriting,
    AppFailure? failure,
    bool clearStatement = false,
    bool clearFailure = false,
  }) {
    return FinanceState(
      items: items ?? this.items,
      statement: clearStatement ? null : statement ?? this.statement,
      isLoading: isLoading ?? this.isLoading,
      isLoadingStatement: isLoadingStatement ?? this.isLoadingStatement,
      isWriting: isWriting ?? this.isWriting,
      failure: clearFailure ? null : failure ?? this.failure,
    );
  }
}

/// 财务列表 / 登记 / 结清视图的状态持有者。
final class FinanceController extends Notifier<FinanceState> {
  FinanceController(this.kind);

  /// 本控制器代理的记录类型（由 family 注入）。
  final FinanceKind kind;

  var _loadGeneration = 0;
  Future<void> _writeTail = Future<void>.value();
  var _disposed = false;

  var _query = const FinanceQuery();

  FinanceRepository get _repository => switch (kind) {
    FinanceKind.payment => ref.read(paymentRepositoryProvider),
    FinanceKind.receipt => ref.read(receiptRepositoryProvider),
    FinanceKind.invoice => ref.read(invoiceRepositoryProvider),
  };

  bool _isCurrent(int generation) =>
      !_disposed && generation == _loadGeneration;

  @override
  FinanceState build() {
    ref.onDispose(() {
      _disposed = true;
      _loadGeneration++;
    });
    return const FinanceState();
  }

  /// 按 [query] 加载财务记录列表。
  Future<void> load([FinanceQuery query = const FinanceQuery()]) async {
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

  Future<void> refresh() => load(_query);

  /// 查询某张单据的结清视图。
  Future<void> loadStatement(int documentId) async {
    if (_disposed) return;
    state = state.copyWith(
      isLoadingStatement: true,
      clearStatement: true,
      clearFailure: true,
    );
    try {
      final statement = await _repository.statement(documentId);
      if (_disposed) return;
      state = state.copyWith(statement: statement, clearFailure: true);
    } on AppFailure catch (failure) {
      if (_disposed) return;
      state = state.copyWith(failure: failure);
    } finally {
      if (!_disposed) {
        state = state.copyWith(isLoadingStatement: false);
      }
    }
  }

  /// 登记一条财务记录。成功后用服务端返回的最新结清视图替换 state.statement，
  /// 并重读列表。
  Future<void> create(FinanceRecordDraft draft) {
    final repository = _repository;
    return _enqueueWrite(() async {
      if (_disposed) return;
      state = state.copyWith(isWriting: true, clearFailure: true);
      try {
        final statement = await repository.create(draft);
        if (_disposed) return;
        state = state.copyWith(statement: statement, clearFailure: true);
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

  /// 撤销一条财务记录（硬删除），成功后更新结清视图并重读列表。
  Future<void> revoke(int recordId) {
    final repository = _repository;
    return _enqueueWrite(() async {
      if (_disposed) return;
      state = state.copyWith(isWriting: true, clearFailure: true);
      try {
        final statement = await repository.revoke(recordId);
        if (_disposed) return;
        state = state.copyWith(statement: statement, clearFailure: true);
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

  Future<void> _enqueueWrite(Future<void> Function() operation) {
    final result = _writeTail.then((_) => operation());
    _writeTail = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }
}
