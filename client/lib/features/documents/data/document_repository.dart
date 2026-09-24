import 'package:c_biz_docs_manager/core/error/app_failure.dart';
import 'package:c_biz_docs_manager/core/network/api_envelope.dart';
import 'package:c_biz_docs_manager/core/network/error_mapper.dart';
import 'package:c_biz_docs_manager/core/network/page_result.dart';
import 'package:c_biz_docs_manager/features/documents/domain/document.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 单据仓储的装配点（入库单）。
///
/// 默认实现直接抛 [StateError]：单据仓储只该由租户会话作用域装配，
/// 否则会在没登录 / 没进组的情况下发起请求。
final inboundDocumentRepositoryProvider = Provider<DocumentRepository>((
  Ref ref,
) {
  throw StateError('InboundDocumentRepository has not been configured');
});

/// 单据仓储的装配点（出库单）。
final outboundDocumentRepositoryProvider = Provider<DocumentRepository>((
  Ref ref,
) {
  throw StateError('OutboundDocumentRepository has not been configured');
});

/// 单据的数据入口。
///
/// 入库单与出库单是同一套结构，只有 `kind` 不同；本接口**不含 kind**，
/// 由装配方用 [DioDocumentRepository] 的构造参数决定它代理的是哪一种。
abstract interface class DocumentRepository {
  /// 分页查询单据。
  Future<PageResult<DocumentSummary>> list(DocumentQuery query);

  /// 查询单据详情（含往来单位与明细）。
  Future<DocumentDetail> get(int documentId);

  /// 创建单据，返回服务端算好金额的完整详情。
  Future<DocumentDetail> create(DocumentDraft draft);

  /// 整体替换单据内容；[version] 为乐观锁凭据。
  Future<DocumentDetail> update(
    int documentId,
    DocumentDraft draft,
    int version,
  );

  /// 提交单据；[version] 为乐观锁凭据。
  Future<DocumentDetail> submit(int documentId, int version);

  /// 作废单据；[version] 为乐观锁凭据。
  Future<DocumentDetail> voidDocument(int documentId, int version);
}

/// 走 HTTP 的单据仓储。
///
/// 只依赖一个 [Dio]，**不接受** `AppDatabase` / Outbox：单据写操作是与服务端
/// 状态强交互的（金额计算、单号生成、乐观锁、状态机），离线排队等网络恢复再
/// 偷偷执行，会产出「单号错位、金额漂移、状态冲突」这类无法自愈的脏数据。
final class DioDocumentRepository implements DocumentRepository {
  DioDocumentRepository(this._dio, this._kind);

  final Dio _dio;

  /// 单据方向。决定请求路径前缀（`/inbound-documents` / `/outbound-documents`）。
  final DocumentKind _kind;

  /// 契约里的路径前缀，不含 `/api/v1`。
  String get _path {
    final segment = _kind == DocumentKind.outbound
        ? 'outbound-documents'
        : 'inbound-documents';
    return '/api/v1/$segment';
  }

  @override
  Future<PageResult<DocumentSummary>> list(DocumentQuery query) =>
      _guard(() async {
        final response = await _dio.get<Object?>(
          _path,
          queryParameters: <String, Object?>{
            'page': query.page,
            'page_size': query.pageSize,
            // 可选筛选用「有才带」：显式传 null 会被序列化成空串、服务端按
            // 非法枚举拒绝，于是「不筛」反而 400。
            if (query.status != null) 'status': query.status!.wireValue,
            if (query.keyword != null && query.keyword!.isNotEmpty)
              'keyword': query.keyword,
            if (query.month != null && query.month!.isNotEmpty)
              'month': query.month,
            if (query.businessUserId != null)
              'business_user_id': query.businessUserId,
            if (query.dateFrom != null && query.dateFrom!.isNotEmpty)
              'date_from': query.dateFrom,
            if (query.dateTo != null && query.dateTo!.isNotEmpty)
              'date_to': query.dateTo,
          },
        );
        return PageResult<DocumentSummary>.fromJson(
          _readData(response.data),
          DocumentSummary.fromJson,
        );
      });

  @override
  Future<DocumentDetail> get(int documentId) => _guard(() async {
    final response = await _dio.get<Object?>('$_path/$documentId');
    return DocumentDetail.fromJson(_readData(response.data));
  });

  @override
  Future<DocumentDetail> create(DocumentDraft draft) => _guard(() async {
    final response = await _dio.post<Object?>(_path, data: _draftBody(draft));
    return DocumentDetail.fromJson(_readData(response.data));
  });

  @override
  Future<DocumentDetail> update(
    int documentId,
    DocumentDraft draft,
    int version,
  ) => _guard(() async {
    final response = await _dio.put<Object?>(
      '$_path/$documentId',
      data: <String, Object?>{'version': version, ..._draftBody(draft)},
    );
    return DocumentDetail.fromJson(_readData(response.data));
  });

  @override
  Future<DocumentDetail> submit(int documentId, int version) =>
      _guard(() async {
        final response = await _dio.post<Object?>(
          '$_path/$documentId/submit',
          data: <String, Object?>{'version': version},
        );
        return DocumentDetail.fromJson(_readData(response.data));
      });

  @override
  Future<DocumentDetail> voidDocument(int documentId, int version) =>
      _guard(() async {
        final response = await _dio.post<Object?>(
          '$_path/$documentId/void',
          data: <String, Object?>{'version': version},
        );
        return DocumentDetail.fromJson(_readData(response.data));
      });

  /// 把写入草稿拼成请求体。
  ///
  /// 可选字段用 null-aware 元素（`'key': ?value`）：值为 null 时整条 entry 被省略，
  /// 于是「不指定业务员 / 运输单位 / 销售类型」发出去的就是不带的合法请求，
  /// 而不是显式 null（服务端 `ShouldBindJSON` 对多余 null 字段可能拒绝）。
  Map<String, Object?> _draftBody(DocumentDraft draft) => <String, Object?>{
    'status': draft.status.wireValue,
    'business_date': draft.businessDate,
    'business_user_id': ?draft.businessUserId,
    'shipping_unit': ?draft.shippingUnit,
    'sale_amount_type': ?draft.saleAmountType?.wireValue,
    'remark': ?draft.remark,
    'parties': <Object?>[
      for (final party in draft.parties)
        <String, Object?>{
          'party_name': party.partyName,
          'contact_phone': ?party.contactPhone,
          'dictionary_entry_id': ?party.dictionaryEntryId,
          'items': <Object?>[
            for (final item in party.items)
              <String, Object?>{
                'product_name': item.productName,
                'product_model': ?item.productModel,
                'unit': ?item.unit,
                'quantity': item.quantity,
                'weight': ?item.weight,
                'unit_price': item.unitPrice,
                'price_tax_mode': item.priceTaxMode.wireValue,
                'remark': ?item.remark,
              },
          ],
        },
    ],
  };
}

/// 把传输层与契约解析的异常统一收敛成 [AppFailure]。
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

/// 拆开统一响应信封，取出 `data` 对象。
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
