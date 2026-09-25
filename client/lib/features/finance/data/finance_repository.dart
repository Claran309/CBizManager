import 'package:c_biz_docs_manager/core/error/app_failure.dart';
import 'package:c_biz_docs_manager/core/network/api_envelope.dart';
import 'package:c_biz_docs_manager/core/network/error_mapper.dart';
import 'package:c_biz_docs_manager/core/network/page_result.dart';
import 'package:c_biz_docs_manager/features/finance/domain/finance.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 财务仓储的装配点（付款 / 收款 / 开票各一个）。
///
/// 默认实现直接抛 [StateError]：财务仓储只该由租户会话作用域装配。
final paymentRepositoryProvider = Provider<FinanceRepository>((Ref ref) {
  throw StateError('PaymentRepository has not been configured');
});

final receiptRepositoryProvider = Provider<FinanceRepository>((Ref ref) {
  throw StateError('ReceiptRepository has not been configured');
});

final invoiceRepositoryProvider = Provider<FinanceRepository>((Ref ref) {
  throw StateError('InvoiceRepository has not been configured');
});

/// 财务记录的数据入口。
///
/// `kind` 由装配方用 [DioFinanceRepository] 的构造参数决定（付款/收款/开票），
/// 接口本身不含 kind。
abstract interface class FinanceRepository {
  /// 分页查询财务记录。
  Future<PageResult<FinanceRecord>> list(FinanceQuery query);

  /// 登记一条财务记录，返回该单据最新的结清视图（一次往返拿全派生金额）。
  Future<FinanceStatement> create(FinanceRecordDraft draft);

  /// 撤销一条财务记录（硬删除），返回该单据最新的结清视图。
  Future<FinanceStatement> revoke(int recordId);

  /// 查询单张单据的结清视图。
  Future<FinanceStatement> statement(int documentId);
}

/// 走 HTTP 的财务仓储。
final class DioFinanceRepository implements FinanceRepository {
  DioFinanceRepository(this._dio, this._kind);

  final Dio _dio;

  /// 记录类型，决定请求路径前缀。
  final FinanceKind _kind;

  /// 记录列表 / 登记 / 撤销的路径前缀（`/api/v1/finance/payments` 等）。
  String get _path => '/api/v1/finance/${_kind.routeSegment}';

  @override
  Future<PageResult<FinanceRecord>> list(FinanceQuery query) =>
      _guard(() async {
        final response = await _dio.get<Object?>(
          _path,
          queryParameters: <String, Object?>{
            'page': query.page,
            'page_size': query.pageSize,
            if (query.documentId != null) 'document_id': query.documentId,
            if (query.keyword != null && query.keyword!.isNotEmpty)
              'keyword': query.keyword,
            if (query.method != null) 'method': query.method!.wireValue,
            if (query.businessUserId != null)
              'business_user_id': query.businessUserId,
            if (query.month != null && query.month!.isNotEmpty)
              'month': query.month,
            if (query.dateFrom != null && query.dateFrom!.isNotEmpty)
              'date_from': query.dateFrom,
            if (query.dateTo != null && query.dateTo!.isNotEmpty)
              'date_to': query.dateTo,
          },
        );
        return PageResult<FinanceRecord>.fromJson(
          _readData(response.data),
          FinanceRecord.fromJson,
        );
      });

  @override
  Future<FinanceStatement> create(FinanceRecordDraft draft) => _guard(() async {
    final response = await _dio.post<Object?>(
      _path,
      data: <String, Object?>{
        'document_id': draft.documentId,
        'amount': draft.amount,
        'occurred_on': draft.occurredOn,
        // method 可选：不指定方式时省略，而不是发显式 null。
        'method': ?draft.method?.wireValue,
        'method_note': ?draft.methodNote,
        'card_tail': ?draft.cardTail,
        'invoice_no': ?draft.invoiceNo,
        'remark': ?draft.remark,
      },
    );
    return FinanceStatement.fromJson(_readData(response.data));
  });

  @override
  Future<FinanceStatement> revoke(int recordId) => _guard(() async {
    final response = await _dio.post<Object?>('$_path/$recordId/revoke');
    return FinanceStatement.fromJson(_readData(response.data));
  });

  @override
  Future<FinanceStatement> statement(int documentId) => _guard(() async {
    final response = await _dio.get<Object?>(
      '/api/v1/finance/statements/$documentId',
    );
    return FinanceStatement.fromJson(_readData(response.data));
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
