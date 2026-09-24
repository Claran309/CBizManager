import 'dart:convert';

import 'package:c_biz_docs_manager/core/error/app_failure.dart';
import 'package:c_biz_docs_manager/features/settlements/data/settlement_repository.dart';
import 'package:c_biz_docs_manager/features/settlements/domain/settlement.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

/// 结算仓储的契约测试。
void main() {
  group('DioSettlementRepository 请求拼装', () {
    test('list 拼对 query', () async {
      final recorder = _recorder((options) => (200, _pageEnvelope()));
      await _repo(recorder.adapter).list(
        const SettlementQuery(
          page: 2,
          pageSize: 50,
          status: SettlementStatus.pending,
          keyword: 'JS2026',
          month: '2026-09',
        ),
      );
      final request = recorder.adapter.requests.single;
      expect(request.method, 'GET');
      expect(request.path, '/api/v1/settlements');
      expect(request.queryParameters, <String, Object?>{
        'page': 2,
        'page_size': 50,
        'status': 'pending',
        'keyword': 'JS2026',
        'month': '2026-09',
      });
    });

    test('create 请求体是 remark + sources[{document_id}]', () async {
      final recorder = _recorder((options) => (200, _detailEnvelope()));
      await _repo(recorder.adapter).create(
        const SettlementDraft(sourceDocumentIds: <int>[42, 43], remark: '本月结算'),
      );
      final request = recorder.adapter.requests.single;
      expect(request.method, 'POST');
      expect(request.data, <String, Object?>{
        'remark': '本月结算',
        'sources': <Object?>[
          <String, Object?>{'document_id': 42},
          <String, Object?>{'document_id': 43},
        ],
      });
    });

    test('approve 只带 version', () async {
      final recorder = _recorder((options) => (200, _detailEnvelope()));
      await _repo(recorder.adapter).approve(9, 3);
      final request = recorder.adapter.requests.single;
      expect(request.method, 'POST');
      expect(request.path, '/api/v1/settlements/9/approve');
      expect(request.data, <String, Object?>{'version': 3});
    });

    test('reject 带 version + remark', () async {
      final recorder = _recorder((options) => (200, _detailEnvelope()));
      await _repo(recorder.adapter).reject(9, 3, '金额不符');
      final request = recorder.adapter.requests.single;
      expect(request.path, '/api/v1/settlements/9/reject');
      expect(request.data, <String, Object?>{'version': 3, 'remark': '金额不符'});
    });

    test('get 解析详情', () async {
      final recorder = _recorder((options) => (200, _detailEnvelope()));
      final detail = await _repo(recorder.adapter).get(9);
      expect(recorder.adapter.requests.single.path, '/api/v1/settlements/9');
      expect(detail.settlementNo, 'JS202609-0003');
      expect(detail.grossProfit.format(), '5000.00');
    });
  });

  group('DioSettlementRepository 错误映射', () {
    test('409 冲突 → ConflictFailure', () async {
      final recorder = _recorder(
        (options) => (409, _errorEnvelope('SETTLEMENT_STATUS_INVALID', '已审批')),
      );
      await expectLater(
        _repo(recorder.adapter).approve(9, 1),
        throwsA(isA<ConflictFailure>()),
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
        _repo(recorder.adapter).get(9),
        throwsA(isA<NetworkFailure>()),
      );
    });
  });
}

/* ---------------------------------------------------------------- 夹具 */

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

DioSettlementRepository _repo(_RecordingAdapter adapter) =>
    DioSettlementRepository(
      Dio(BaseOptions(baseUrl: 'https://api.example.test'))
        ..httpClientAdapter = adapter,
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
  'settlement_id': 9,
  'settlement_no': 'JS202609-0003',
  'status': 'pending',
  'requester': _userJson(),
  'inbound_total': '10000.00',
  'outbound_total': '15000.00',
  'gross_profit': '5000.00',
  'source_count': 2,
  'version': 2,
  'decided_at': null,
  'decision_remark': null,
  'created_at': '2026-09-22T10:00:00Z',
  'updated_at': '2026-09-22T10:00:00Z',
};

Map<String, Object?> _detailData() => <String, Object?>{
  ..._summaryData(),
  'remark': '本月结算',
  'inbound_total_upper': '人民币壹万元整',
  'outbound_total_upper': '人民币壹万伍仟元整',
  'gross_profit_upper': '人民币伍仟元整',
  'decided_by': null,
  'sources': <Object?>[],
  'approval_records': <Object?>[],
};

Map<String, Object?> _userJson() => <String, Object?>{
  'id': 7,
  'username': 'zhangsan',
  'display_name': '张三',
  'account_type': 'member',
};
