import 'dart:convert';

import 'package:c_biz_docs_manager/core/error/app_failure.dart';
import 'package:c_biz_docs_manager/features/documents/data/document_repository.dart';
import 'package:c_biz_docs_manager/features/documents/domain/document.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

/// 单据仓储的契约测试。
///
/// 用假适配器记录真实请求，断言方法 / 路径 / query / 请求体拼装正确，
/// 以及「kind 由构造参数决定、请求体不带 kind/amount」等口径。
void main() {
  group('DioDocumentRepository 请求拼装', () {
    test('inbound 与 outbound 走不同路径前缀', () async {
      final inbound = _recorder((options) => (200, _pageEnvelope()));
      final outbound = _recorder((options) => (200, _pageEnvelope()));

      await _repo(
        inbound.adapter,
        DocumentKind.inbound,
      ).list(const DocumentQuery(page: 1, pageSize: 20));
      await _repo(
        outbound.adapter,
        DocumentKind.outbound,
      ).list(const DocumentQuery(page: 1, pageSize: 20));

      expect(inbound.adapter.requests.single.path, '/api/v1/inbound-documents');
      expect(
        outbound.adapter.requests.single.path,
        '/api/v1/outbound-documents',
      );
    });

    test('list 拼对 query，可选筛选用「有才带」', () async {
      final recorder = _recorder((options) => (200, _pageEnvelope()));
      await _repo(recorder.adapter, DocumentKind.inbound).list(
        const DocumentQuery(
          page: 2,
          pageSize: 50,
          status: DocumentStatus.submitted,
          keyword: '华东',
          month: '2026-09',
          businessUserId: 7,
        ),
      );

      final request = recorder.adapter.requests.single;
      expect(request.method, 'GET');
      expect(request.queryParameters, <String, Object?>{
        'page': 2,
        'page_size': 50,
        'status': 'submitted',
        'keyword': '华东',
        'month': '2026-09',
        'business_user_id': 7,
      });
    });

    test('list 不筛时不带可选键', () async {
      final recorder = _recorder((options) => (200, _pageEnvelope()));
      await _repo(
        recorder.adapter,
        DocumentKind.inbound,
      ).list(const DocumentQuery(page: 1, pageSize: 20));
      final query = recorder.adapter.requests.single.queryParameters;
      expect(query.containsKey('status'), isFalse);
      expect(query.containsKey('month'), isFalse);
      expect(query.containsKey('business_user_id'), isFalse);
      expect(query.containsKey('keyword'), isFalse);
    });

    test('create 请求体不带 kind/amount，金额字段是字符串', () async {
      final recorder = _recorder((options) => (200, _detailEnvelope()));
      await _repo(recorder.adapter, DocumentKind.outbound).create(
        DocumentDraft(
          status: DocumentStatus.draft,
          businessDate: '2026-09-22',
          shippingUnit: '吨',
          saleAmountType: SaleAmountType.vatSpecial,
          parties: <PartyDraft>[
            PartyDraft(
              partyName: '华东钢贸',
              contactPhone: '13800000000',
              items: <ItemDraft>[
                ItemDraft(
                  productName: '螺纹钢',
                  productModel: 'HRB400',
                  unit: '吨',
                  quantity: '17.050',
                  unitPrice: '2975.4300',
                  priceTaxMode: PriceTaxMode.taxIncluded,
                ),
              ],
            ),
          ],
        ),
      );

      final request = recorder.adapter.requests.single;
      expect(request.method, 'POST');
      expect(request.path, '/api/v1/outbound-documents');
      final body = request.data as Map<String, Object?>;
      expect(body.containsKey('kind'), isFalse, reason: 'kind 由路由决定');
      expect(body['status'], 'draft');
      expect(body['business_date'], '2026-09-22');
      expect(body['shipping_unit'], '吨');
      expect(body['sale_amount_type'], 'Y-1');
      final party = (body['parties'] as List).single as Map<String, Object?>;
      expect(party['party_name'], '华东钢贸');
      expect(party['contact_phone'], '13800000000');
      final item = (party['items'] as List).single as Map<String, Object?>;
      // 明细行不提交 amount（服务端算），且数量/单价是字符串。
      expect(item.containsKey('amount'), isFalse);
      expect(item['quantity'], '17.050');
      expect(item['unit_price'], '2975.4300');
      expect(item['price_tax_mode'], 'tax_included');
    });

    test('update 请求体带 version，整体替换', () async {
      final recorder = _recorder((options) => (200, _detailEnvelope()));
      await _repo(recorder.adapter, DocumentKind.inbound).update(
        42,
        DocumentDraft(
          status: DocumentStatus.submitted,
          businessDate: '2026-09-22',
          parties: <PartyDraft>[
            PartyDraft(
              partyName: '华东钢贸',
              items: <ItemDraft>[
                ItemDraft(
                  productName: '螺纹钢',
                  quantity: '10.000',
                  unitPrice: '3000.0000',
                  priceTaxMode: PriceTaxMode.taxExcluded,
                ),
              ],
            ),
          ],
        ),
        3,
      );

      final request = recorder.adapter.requests.single;
      expect(request.method, 'PUT');
      expect(request.path, '/api/v1/inbound-documents/42');
      final body = request.data as Map<String, Object?>;
      expect(body['version'], 3);
      expect(body['status'], 'submitted');
    });

    test('submit 与 void 只带 version', () async {
      final recorder = _recorder((options) => (200, _detailEnvelope()));
      final repo = _repo(recorder.adapter, DocumentKind.inbound);

      await repo.submit(42, 3);
      await repo.voidDocument(42, 4);

      expect(recorder.adapter.requests, hasLength(2));
      expect(recorder.adapter.requests[0].method, 'POST');
      expect(
        recorder.adapter.requests[0].path,
        '/api/v1/inbound-documents/42/submit',
      );
      expect(recorder.adapter.requests[0].data, <String, Object?>{
        'version': 3,
      });
      expect(
        recorder.adapter.requests[1].path,
        '/api/v1/inbound-documents/42/void',
      );
      expect(recorder.adapter.requests[1].data, <String, Object?>{
        'version': 4,
      });
    });

    test('get 解析详情', () async {
      final recorder = _recorder((options) => (200, _detailEnvelope()));
      final detail = await _repo(
        recorder.adapter,
        DocumentKind.inbound,
      ).get(42);

      expect(
        recorder.adapter.requests.single.path,
        '/api/v1/inbound-documents/42',
      );
      expect(detail.documentId, 42);
      expect(detail.documentNo, 'RK20260922-0001');
      expect(detail.parties.single.items.single.amount.format(), '50731.08');
    });
  });

  group('DioDocumentRepository 错误映射', () {
    test('409 冲突 → ConflictFailure', () async {
      final recorder = _recorder(
        (options) => (409, _errorEnvelope('RESOURCE_VERSION_CONFLICT', '已被修改')),
      );
      await expectLater(
        _repo(recorder.adapter, DocumentKind.inbound).submit(42, 1),
        throwsA(isA<ConflictFailure>()),
      );
    });

    test('403 → ForbiddenFailure', () async {
      final recorder = _recorder(
        (options) => (403, _errorEnvelope('FORBIDDEN', '无权限')),
      );
      await expectLater(
        _repo(recorder.adapter, DocumentKind.inbound).get(42),
        throwsA(isA<ForbiddenFailure>()),
      );
    });

    test('断网 → NetworkFailure', () async {
      final recorder = _recorder(
        (options) => throw DioException.connectionError(
          requestOptions: options,
          reason: 'offline',
        ),
      );
      await expectLater(
        _repo(recorder.adapter, DocumentKind.inbound).get(42),
        throwsA(isA<NetworkFailure>()),
      );
    });

    test('200 但金额是数字 → ServerFailure（不伪装成功）', () async {
      final recorder = _recorder(
        (options) => (
          200,
          _okEnvelope(<String, Object?>{
            ..._detailData(),
            'total_amount': 50731.08, // 数字而非字符串
          }),
        ),
      );
      await expectLater(
        _repo(recorder.adapter, DocumentKind.inbound).get(42),
        throwsA(isA<ServerFailure>()),
      );
    });
  });
}

/* ---------------------------------------------------------------- 夹具 */

/// 记录请求、按回调应答的假适配器。
final class _RecordingAdapter implements HttpClientAdapter {
  _RecordingAdapter(this.respond);

  (int, String) Function(RequestOptions options) respond;
  final List<RequestOptions> requests = <RequestOptions>[];

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final (statusCode, body) = respond(options);
    return ResponseBody.fromString(
      body,
      statusCode,
      headers: <String, List<String>>{
        Headers.contentTypeHeader: <String>[Headers.jsonContentType],
      },
    );
  }
}

final class _Recorder {
  _Recorder((int, String) Function(RequestOptions options) respond)
    : adapter = _RecordingAdapter(respond);

  final _RecordingAdapter adapter;
}

_Recorder _recorder((int, String) Function(RequestOptions options) respond) =>
    _Recorder(respond);

DioDocumentRepository _repo(_RecordingAdapter adapter, DocumentKind kind) =>
    DioDocumentRepository(
      Dio(BaseOptions(baseUrl: 'https://api.example.test'))
        ..httpClientAdapter = adapter,
      kind,
    );

String _okEnvelope(Object? data) => jsonEncode(<String, Object?>{
  'code': 'OK',
  'message': 'success',
  'data': data,
  'request_id': 'request-1',
});

String _errorEnvelope(String code, String message) =>
    jsonEncode(<String, Object?>{
      'code': code,
      'message': message,
      'data': null,
      'request_id': 'request-1',
    });

String _pageEnvelope() => _okEnvelope(<String, Object?>{
  'items': <Object?>[_summaryData()],
  'page': 1,
  'page_size': 20,
  'total': 1,
});

String _detailEnvelope() => _okEnvelope(_detailData());

Map<String, Object?> _summaryData() => <String, Object?>{
  'document_id': 42,
  'kind': 'inbound',
  'document_no': 'RK20260922-0001',
  'status': 'submitted',
  'business_date': '2026-09-22',
  'business_user': <String, Object?>{
    'id': 7,
    'username': '',
    'display_name': '张三',
    'account_type': '',
  },
  'shipping_unit': null,
  'sale_amount_type': null,
  'party_names': <String>['华东钢贸'],
  'item_count': 1,
  'total_amount': '50731.08',
  'version': 3,
  'submitted_at': '2026-09-22T10:00:00Z',
  'created_at': '2026-09-22T09:00:00Z',
  'updated_at': '2026-09-22T10:00:00Z',
};

Map<String, Object?> _detailData() => <String, Object?>{
  'document_id': 42,
  'kind': 'inbound',
  'document_no': 'RK20260922-0001',
  'status': 'submitted',
  'business_user': <String, Object?>{
    'id': 7,
    'username': 'zhangsan',
    'display_name': '张三',
    'account_type': 'member',
  },
  'business_date': '2026-09-22',
  'shipping_unit': null,
  'sale_amount_type': null,
  'total_amount': '50731.08',
  'total_amount_upper': '人民币伍万零柒佰叁拾壹元零捌分',
  'remark': null,
  'version': 3,
  'submitted_at': '2026-09-22T10:00:00Z',
  'created_at': '2026-09-22T09:00:00Z',
  'updated_at': '2026-09-22T10:00:00Z',
  'parties': <Object?>[
    <String, Object?>{
      'party_id': 1,
      'position': 1,
      'party_name': '华东钢贸',
      'contact_phone': null,
      'subtotal': '50731.08',
      'items': <Object?>[
        <String, Object?>{
          'item_id': 101,
          'position': 1,
          'product_name': '螺纹钢',
          'product_model': 'HRB400',
          'unit': '吨',
          'quantity': '17.050',
          'weight': null,
          'unit_price': '2975.4300',
          'price_tax_mode': 'tax_included',
          'amount': '50731.08',
          'remark': null,
        },
      ],
    },
  ],
};
