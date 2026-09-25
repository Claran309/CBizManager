import 'package:c_biz_docs_manager/core/error/app_failure.dart';
import 'package:c_biz_docs_manager/core/network/api_envelope.dart';
import 'package:c_biz_docs_manager/core/network/error_mapper.dart';
import 'package:c_biz_docs_manager/core/network/page_result.dart';
import 'package:c_biz_docs_manager/features/reports/domain/report.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 报表仓储的装配点。
///
/// 默认实现直接抛 [StateError]：报表仓储只该由租户会话作用域装配
/// （汇总统计的可见范围是「全组」，需要 `report.view` 权限）。
final reportRepositoryProvider = Provider<ReportRepository>((Ref ref) {
  throw StateError('ReportRepository has not been configured');
});

/// 报表的数据入口（只读，除生成总结算快照）。
abstract interface class ReportRepository {
  /// 后台数据汇总看板。
  Future<ReportOverview> overview(PeriodQuery query);

  /// 入库统计（含明细聚合分页）。
  Future<InboundStats> inboundStats(StatsQuery query);

  /// 出库统计（含明细聚合分页）。
  Future<OutboundStats> outboundStats(StatsQuery query);

  /// 业务员维度利润统计。
  Future<BusinessUserReport> businessUsers(String period);

  /// 分页查询总结算快照。
  Future<PageResult<ReportSnapshot>> listSnapshots(SnapshotQuery query);

  /// 查询一张总结算快照。
  Future<ReportSnapshot> getSnapshot(int snapshotId);

  /// 生成月度总结算快照。
  Future<CreateSnapshotResult> createSnapshots(CreateSnapshotDraft draft);
}

/// 走 HTTP 的报表仓储。
final class DioReportRepository implements ReportRepository {
  DioReportRepository(this._dio);

  final Dio _dio;

  static const _path = '/api/v1/reports';

  @override
  Future<ReportOverview> overview(PeriodQuery query) => _guard(() async {
    final response = await _dio.get<Object?>(
      '$_path/overview',
      queryParameters: <String, Object?>{
        'period': query.period,
        if (query.businessUserId != null)
          'business_user_id': query.businessUserId,
      },
    );
    return ReportOverview.fromJson(_readData(response.data));
  });

  @override
  Future<InboundStats> inboundStats(StatsQuery query) => _guard(() async {
    final response = await _dio.get<Object?>(
      '$_path/inbound-stats',
      queryParameters: _statsParams(query),
    );
    return InboundStats.fromJson(_readData(response.data));
  });

  @override
  Future<OutboundStats> outboundStats(StatsQuery query) => _guard(() async {
    final response = await _dio.get<Object?>(
      '$_path/outbound-stats',
      queryParameters: _statsParams(query),
    );
    return OutboundStats.fromJson(_readData(response.data));
  });

  @override
  Future<BusinessUserReport> businessUsers(String period) => _guard(() async {
    final response = await _dio.get<Object?>(
      '$_path/business-users',
      queryParameters: <String, Object?>{'period': period},
    );
    return BusinessUserReport.fromJson(_readData(response.data));
  });

  @override
  Future<PageResult<ReportSnapshot>> listSnapshots(SnapshotQuery query) =>
      _guard(() async {
        final response = await _dio.get<Object?>(
          '$_path/summary-settlements',
          queryParameters: <String, Object?>{
            'page': query.page,
            'page_size': query.pageSize,
            if (query.period != null && query.period!.isNotEmpty)
              'period': query.period,
            if (query.scope != null) 'scope': query.scope!.wireValue,
            if (query.businessUserId != null)
              'business_user_id': query.businessUserId,
          },
        );
        return PageResult<ReportSnapshot>.fromJson(
          _readData(response.data),
          ReportSnapshot.fromJson,
        );
      });

  @override
  Future<ReportSnapshot> getSnapshot(int snapshotId) => _guard(() async {
    final response = await _dio.get<Object?>(
      '$_path/summary-settlements/$snapshotId',
    );
    return ReportSnapshot.fromJson(_readData(response.data));
  });

  @override
  Future<CreateSnapshotResult> createSnapshots(CreateSnapshotDraft draft) =>
      _guard(() async {
        final response = await _dio.post<Object?>(
          '$_path/summary-settlements',
          data: <String, Object?>{
            'period': draft.period,
            'scope': draft.scope.wireValue,
            // business_user_id 是 uint64，缺省发 0（契约里 0 表示「不指定」）。
            'business_user_id': draft.businessUserId ?? 0,
            'remark': ?draft.remark,
          },
        );
        return CreateSnapshotResult.fromJson(_readData(response.data));
      });

  Map<String, Object?> _statsParams(StatsQuery query) => <String, Object?>{
    'period': query.period,
    'page': query.page,
    'page_size': query.pageSize,
    if (query.businessUserId != null) 'business_user_id': query.businessUserId,
    if (query.partyName != null && query.partyName!.isNotEmpty)
      'party_name': query.partyName,
    if (query.productName != null && query.productName!.isNotEmpty)
      'product_name': query.productName,
    if (query.productModel != null && query.productModel!.isNotEmpty)
      'product_model': query.productModel,
  };
}

Future<T> _guard<T>(Future<T> Function() operation) async {
  try {
    return await operation();
  } on DioException catch (error) {
    throw mapDioFailure(error);
  } on FormatException {
    throw const ServerFailure('Invalid server response');
  } on TypeError {
    throw const ServerFailure('Invalid server response');
  }
}

Map<String, Object?> _readData(Object? raw) {
  if (raw is! Map) {
    throw const FormatException('API response must be an object');
  }
  final envelope = ApiEnvelope<Map<String, Object?>>.fromJson(
    Map<String, Object?>.from(raw),
    (value) => Map<String, Object?>.from(value as Map),
  );
  final data = envelope.data;
  if (data == null) {
    throw const FormatException('API response data is required');
  }
  return data;
}
