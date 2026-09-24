import 'package:c_biz_docs_manager/core/error/app_failure.dart';
import 'package:c_biz_docs_manager/core/network/api_envelope.dart';
import 'package:c_biz_docs_manager/core/network/error_mapper.dart';
import 'package:c_biz_docs_manager/core/network/page_result.dart';
import 'package:c_biz_docs_manager/features/settlements/domain/settlement.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 结算仓储的装配点。
///
/// 默认实现直接抛 [StateError]：结算仓储只该由租户会话作用域装配。
final settlementRepositoryProvider = Provider<SettlementRepository>((Ref ref) {
  throw StateError('SettlementRepository has not been configured');
});

/// 结算单的数据入口。
abstract interface class SettlementRepository {
  /// 分页查询结算单。
  Future<PageResult<SettlementSummary>> list(SettlementQuery query);

  /// 查询结算单详情（含源单据快照与审批记录）。
  Future<SettlementDetail> get(int settlementId);

  /// 提交结算申请（勾选一组源单据）。
  Future<SettlementDetail> create(SettlementDraft draft);

  /// 审批通过；[version] 为乐观锁凭据。
  Future<SettlementDetail> approve(int settlementId, int version);

  /// 审批驳回；[remark] 必填（服务端要求），[version] 为乐观锁凭据。
  Future<SettlementDetail> reject(int settlementId, int version, String remark);
}

/// 走 HTTP 的结算仓储。
final class DioSettlementRepository implements SettlementRepository {
  DioSettlementRepository(this._dio);

  final Dio _dio;

  static const _path = '/api/v1/settlements';

  @override
  Future<PageResult<SettlementSummary>> list(SettlementQuery query) =>
      _guard(() async {
        final response = await _dio.get<Object?>(
          _path,
          queryParameters: <String, Object?>{
            'page': query.page,
            'page_size': query.pageSize,
            if (query.status != null) 'status': query.status!.wireValue,
            if (query.keyword != null && query.keyword!.isNotEmpty)
              'keyword': query.keyword,
            if (query.requesterUserId != null)
              'requester_user_id': query.requesterUserId,
            if (query.month != null && query.month!.isNotEmpty)
              'month': query.month,
          },
        );
        return PageResult<SettlementSummary>.fromJson(
          _readData(response.data),
          SettlementSummary.fromJson,
        );
      });

  @override
  Future<SettlementDetail> get(int settlementId) => _guard(() async {
    final response = await _dio.get<Object?>('$_path/$settlementId');
    return SettlementDetail.fromJson(_readData(response.data));
  });

  @override
  Future<SettlementDetail> create(SettlementDraft draft) => _guard(() async {
    final response = await _dio.post<Object?>(
      _path,
      data: <String, Object?>{
        'remark': ?draft.remark,
        'sources': <Object?>[
          for (final documentId in draft.sourceDocumentIds)
            <String, Object?>{'document_id': documentId},
        ],
      },
    );
    return SettlementDetail.fromJson(_readData(response.data));
  });

  @override
  Future<SettlementDetail> approve(int settlementId, int version) =>
      _guard(() async {
        final response = await _dio.post<Object?>(
          '$_path/$settlementId/approve',
          data: <String, Object?>{'version': version},
        );
        return SettlementDetail.fromJson(_readData(response.data));
      });

  @override
  Future<SettlementDetail> reject(
    int settlementId,
    int version,
    String remark,
  ) => _guard(() async {
    final response = await _dio.post<Object?>(
      '$_path/$settlementId/reject',
      // 驳回必填 remark：服务端对缺 remark 的驳回返回 SETTLEMENT_REMARK_REQUIRED。
      data: <String, Object?>{'version': version, 'remark': remark},
    );
    return SettlementDetail.fromJson(_readData(response.data));
  });
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
