import 'package:c_biz_docs_manager/core/error/app_failure.dart';
import 'package:c_biz_docs_manager/features/reports/data/report_repository.dart';
import 'package:c_biz_docs_manager/features/reports/domain/report.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 报表控制器装配点。
///
/// `dependencies` 声明报表仓储装配点，挂到会话作用域、换账号整体重建。
final reportControllerProvider =
    NotifierProvider<ReportController, ReportState>(
      ReportController.new,
      dependencies: [reportRepositoryProvider],
    );

/// 报表各视图的状态。
///
/// 一个 controller 承载五个只读视图（看板 / 入库统计 / 出库统计 / 业务员利润 /
/// 总结算快照），各视图有独立的加载标志；成功/失败共用一个 [failure]。
final class ReportState {
  const ReportState({
    this.overview,
    this.inboundStats,
    this.outboundStats,
    this.businessUsers,
    this.snapshots = const <ReportSnapshot>[],
    this.isLoadingOverview = false,
    this.isLoadingInboundStats = false,
    this.isLoadingOutboundStats = false,
    this.isLoadingBusinessUsers = false,
    this.isLoadingSnapshots = false,
    this.isWriting = false,
    this.failure,
  });

  final ReportOverview? overview;
  final InboundStats? inboundStats;
  final OutboundStats? outboundStats;
  final BusinessUserReport? businessUsers;
  final List<ReportSnapshot> snapshots;

  final bool isLoadingOverview;
  final bool isLoadingInboundStats;
  final bool isLoadingOutboundStats;
  final bool isLoadingBusinessUsers;
  final bool isLoadingSnapshots;
  final bool isWriting;
  final AppFailure? failure;

  ReportState copyWith({
    ReportOverview? overview,
    InboundStats? inboundStats,
    OutboundStats? outboundStats,
    BusinessUserReport? businessUsers,
    List<ReportSnapshot>? snapshots,
    bool? isLoadingOverview,
    bool? isLoadingInboundStats,
    bool? isLoadingOutboundStats,
    bool? isLoadingBusinessUsers,
    bool? isLoadingSnapshots,
    bool? isWriting,
    AppFailure? failure,
    bool clearFailure = false,
  }) {
    return ReportState(
      overview: overview ?? this.overview,
      inboundStats: inboundStats ?? this.inboundStats,
      outboundStats: outboundStats ?? this.outboundStats,
      businessUsers: businessUsers ?? this.businessUsers,
      snapshots: snapshots ?? this.snapshots,
      isLoadingOverview: isLoadingOverview ?? this.isLoadingOverview,
      isLoadingInboundStats:
          isLoadingInboundStats ?? this.isLoadingInboundStats,
      isLoadingOutboundStats:
          isLoadingOutboundStats ?? this.isLoadingOutboundStats,
      isLoadingBusinessUsers:
          isLoadingBusinessUsers ?? this.isLoadingBusinessUsers,
      isLoadingSnapshots: isLoadingSnapshots ?? this.isLoadingSnapshots,
      isWriting: isWriting ?? this.isWriting,
      failure: clearFailure ? null : failure ?? this.failure,
    );
  }
}

/// 报表各视图的状态持有者。
///
/// 四个独立加载各有自己的 generation（乱序丢弃）、快照生成走写队列（串行）。
/// 报表**只有「看全组」一种数据范围**，无 `report.view` 权限时服务端直接 403 ——
/// 客户端不返回空报表，避免用户误以为「本月确实没数据」。
final class ReportController extends Notifier<ReportState> {
  final Map<String, int> _generations = <String, int>{};
  Future<void> _writeTail = Future<void>.value();
  var _disposed = false;

  ReportRepository get _repository => ref.read(reportRepositoryProvider);

  int _bump(String view) => _generations[view] = (_generations[view] ?? 0) + 1;

  bool _isCurrent(String view, int generation) =>
      !_disposed && generation == (_generations[view] ?? 0);

  @override
  ReportState build() {
    ref.onDispose(() {
      _disposed = true;
      // 让所有在途结果立刻作废。
      for (final key in _generations.keys) {
        _generations[key] = _generations[key]! + 1;
      }
    });
    return const ReportState();
  }

  Future<void> loadOverview(PeriodQuery query) async {
    final generation = _bump('overview');
    if (_disposed) return;
    state = state.copyWith(isLoadingOverview: true, clearFailure: true);
    try {
      final overview = await _repository.overview(query);
      if (_isCurrent('overview', generation)) {
        state = state.copyWith(overview: overview, clearFailure: true);
      }
    } on AppFailure catch (failure) {
      if (_isCurrent('overview', generation)) {
        state = state.copyWith(failure: failure);
      }
    } finally {
      if (_isCurrent('overview', generation)) {
        state = state.copyWith(isLoadingOverview: false);
      }
    }
  }

  Future<void> loadInboundStats(StatsQuery query) async {
    final generation = _bump('inboundStats');
    if (_disposed) return;
    state = state.copyWith(isLoadingInboundStats: true, clearFailure: true);
    try {
      final stats = await _repository.inboundStats(query);
      if (_isCurrent('inboundStats', generation)) {
        state = state.copyWith(inboundStats: stats, clearFailure: true);
      }
    } on AppFailure catch (failure) {
      if (_isCurrent('inboundStats', generation)) {
        state = state.copyWith(failure: failure);
      }
    } finally {
      if (_isCurrent('inboundStats', generation)) {
        state = state.copyWith(isLoadingInboundStats: false);
      }
    }
  }

  Future<void> loadOutboundStats(StatsQuery query) async {
    final generation = _bump('outboundStats');
    if (_disposed) return;
    state = state.copyWith(isLoadingOutboundStats: true, clearFailure: true);
    try {
      final stats = await _repository.outboundStats(query);
      if (_isCurrent('outboundStats', generation)) {
        state = state.copyWith(outboundStats: stats, clearFailure: true);
      }
    } on AppFailure catch (failure) {
      if (_isCurrent('outboundStats', generation)) {
        state = state.copyWith(failure: failure);
      }
    } finally {
      if (_isCurrent('outboundStats', generation)) {
        state = state.copyWith(isLoadingOutboundStats: false);
      }
    }
  }

  Future<void> loadBusinessUsers(String period) async {
    final generation = _bump('businessUsers');
    if (_disposed) return;
    state = state.copyWith(isLoadingBusinessUsers: true, clearFailure: true);
    try {
      final report = await _repository.businessUsers(period);
      if (_isCurrent('businessUsers', generation)) {
        state = state.copyWith(businessUsers: report, clearFailure: true);
      }
    } on AppFailure catch (failure) {
      if (_isCurrent('businessUsers', generation)) {
        state = state.copyWith(failure: failure);
      }
    } finally {
      if (_isCurrent('businessUsers', generation)) {
        state = state.copyWith(isLoadingBusinessUsers: false);
      }
    }
  }

  Future<void> loadSnapshots(SnapshotQuery query) async {
    final generation = _bump('snapshots');
    if (_disposed) return;
    state = state.copyWith(isLoadingSnapshots: true, clearFailure: true);
    try {
      final page = await _repository.listSnapshots(query);
      if (_isCurrent('snapshots', generation)) {
        state = state.copyWith(snapshots: page.items, clearFailure: true);
      }
    } on AppFailure catch (failure) {
      if (_isCurrent('snapshots', generation)) {
        state = state.copyWith(failure: failure);
      }
    } finally {
      if (_isCurrent('snapshots', generation)) {
        state = state.copyWith(isLoadingSnapshots: false);
      }
    }
  }

  /// 生成月度总结算快照。成功后重读快照列表。
  Future<void> createSnapshots(CreateSnapshotDraft draft) {
    final repository = _repository;
    return _enqueueWrite(() async {
      if (_disposed) return;
      state = state.copyWith(isWriting: true, clearFailure: true);
      try {
        await repository.createSnapshots(draft);
        if (_disposed) return;
        state = state.copyWith(clearFailure: true);
        await loadSnapshots(SnapshotQuery(period: draft.period));
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
