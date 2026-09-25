import 'dart:convert';

import 'package:c_biz_docs_manager/core/network/page_result.dart';
import 'package:c_biz_docs_manager/features/finance/application/finance_controller.dart';
import 'package:c_biz_docs_manager/features/finance/data/finance_repository.dart';
import 'package:c_biz_docs_manager/features/finance/domain/finance.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
// `Override` 在 Riverpod 3 里由 misc.dart 导出。
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

/// 财务模块的契约测试：枚举 + domain 解析 + repository 请求拼装 + controller 时序。
void main() {
  group('FinanceKind 枚举', () {
    test('wire 值与挂载方向', () {
      expect(FinanceKind.payment.wireValue, 'payment');
      expect(FinanceKind.receipt.wireValue, 'receipt');
      expect(FinanceKind.invoice.wireValue, 'invoice');
      expect(FinanceKind.payment.documentKind.wireValue, 'inbound');
      expect(FinanceKind.receipt.documentKind.wireValue, 'outbound');
      expect(FinanceKind.invoice.documentKind.wireValue, 'inbound');
      expect(FinanceKind.payment.carriesMethod, isTrue);
      expect(FinanceKind.receipt.carriesMethod, isTrue);
      expect(FinanceKind.invoice.carriesMethod, isFalse);
      expect(FinanceKind.invoice.carriesInvoiceNo, isTrue);
      expect(() => FinanceKind.fromWireValue('x'), throwsFormatException);
    });
  });

  group('FinanceRecord.fromJson', () {
    test('解析记录（business_user/created_by 是完整 UserSummary）', () {
      final record = FinanceRecord.fromJson(_recordData());
      expect(record.kind, FinanceKind.payment);
      expect(record.amount.format(), '30000.00');
      expect(record.amountUpper, '人民币叁万元整');
      expect(record.businessUser.username, 'zhangsan');
      expect(record.createdBy.username, 'admin');
      expect(record.cardTail, '1234');
    });

    test('business_user 缺 username 抛错（严格解析）', () {
      final json = _recordData();
      (json['business_user'] as Map<String, Object?>)['username'] = '';
      expect(() => FinanceRecord.fromJson(json), throwsFormatException);
    });
  });

  group('FinanceStatement.fromJson', () {
    test('入库单结清视图：paid/unpaid/invoiced 有值，received 恒 0', () {
      final statement = FinanceStatement.fromJson(_statementData());
      expect(statement.documentKind.wireValue, 'inbound');
      expect(statement.paidAmount.format(), '30000.00');
      expect(statement.unpaidAmount.format(), '70000.00');
      expect(statement.invoiceStatus, InvoiceStatus.partial);
      expect(statement.receivedAmount.isZero, isTrue);
      expect(statement.records, hasLength(1));
    });

    test('出库单结清视图：invoice_status 恒 not_applicable', () {
      final json = _statementData()
        ..['document_kind'] = 'outbound'
        ..['invoice_status'] = 'not_applicable';
      final statement = FinanceStatement.fromJson(json);
      expect(statement.invoiceStatus, InvoiceStatus.notApplicable);
    });
  });

  group('DioFinanceRepository 请求拼装', () {
    test('kind 决定路径前缀', () async {
      final payment = _recorder((options) => (200, _pageEnvelope()));
      final receipt = _recorder((options) => (200, _pageEnvelope()));
      await _repo(
        payment.adapter,
        FinanceKind.payment,
      ).list(const FinanceQuery());
      await _repo(
        receipt.adapter,
        FinanceKind.receipt,
      ).list(const FinanceQuery());
      expect(payment.adapter.requests.single.path, '/api/v1/finance/payments');
      expect(receipt.adapter.requests.single.path, '/api/v1/finance/receipts');
    });

    test('create 请求体无 kind，method 可选省略', () async {
      final recorder = _recorder((options) => (200, _statementEnvelope()));
      await _repo(recorder.adapter, FinanceKind.payment).create(
        const FinanceRecordDraft(
          documentId: 42,
          amount: '30000.00',
          occurredOn: '2026-09-22',
          method: FinanceMethod.privateCard,
          cardTail: '1234',
        ),
      );
      final body =
          recorder.adapter.requests.single.data as Map<String, Object?>;
      expect(body.containsKey('kind'), isFalse);
      expect(body['document_id'], 42);
      expect(body['amount'], '30000.00');
      expect(body['occurred_on'], '2026-09-22');
      expect(body['method'], 'private_card');
      expect(body['card_tail'], '1234');
      expect(body.containsKey('method_note'), isFalse);
    });

    test('revoke 走 /revoke', () async {
      final recorder = _recorder((options) => (200, _statementEnvelope()));
      await _repo(recorder.adapter, FinanceKind.payment).revoke(7);
      expect(
        recorder.adapter.requests.single.path,
        '/api/v1/finance/payments/7/revoke',
      );
    });

    test('statement 走独立路径（不分 kind）', () async {
      final recorder = _recorder((options) => (200, _statementEnvelope()));
      await _repo(recorder.adapter, FinanceKind.invoice).statement(42);
      expect(
        recorder.adapter.requests.single.path,
        '/api/v1/finance/statements/42',
      );
    });
  });

  group('FinanceController', () {
    test('登记成功后用服务端返回的结清视图替换 state.statement', () async {
      final repository = _FakeFinanceRepository();
      final container = ProviderContainer(
        overrides: <Override>[
          paymentRepositoryProvider.overrideWithValue(repository),
          receiptRepositoryProvider.overrideWithValue(repository),
          invoiceRepositoryProvider.overrideWithValue(repository),
        ],
      );
      addTearDown(container.dispose);
      repository.statementResult = FinanceStatement.fromJson(_statementData());

      await container
          .read(financeControllerProvider(FinanceKind.payment).notifier)
          .create(
            const FinanceRecordDraft(
              documentId: 42,
              amount: '30000.00',
              occurredOn: '2026-09-22',
            ),
          );

      final state = container.read(
        financeControllerProvider(FinanceKind.payment),
      );
      expect(state.statement?.paidAmount.format(), '30000.00');
      expect(repository.createCalls, 1);
    });
  });
}

/* ---------------------------------------------------------------- 夹具 */

Map<String, Object?> _userJson({int id = 7, String username = 'zhangsan'}) =>
    <String, Object?>{
      'id': id,
      'username': username,
      'display_name': '张三',
      'account_type': 'member',
    };

Map<String, Object?> _recordData() => <String, Object?>{
  'record_id': 1,
  'kind': 'payment',
  'document_id': 42,
  'document_kind': 'inbound',
  'document_no': 'RK20260922-0001',
  'party_name': '华东钢贸',
  'business_user': _userJson(),
  'business_date': '2026-09-22',
  'amount': '30000.00',
  'amount_upper': '人民币叁万元整',
  'occurred_on': '2026-09-22',
  'method': 'private_card',
  'method_note': null,
  'card_tail': '1234',
  'invoice_no': null,
  'remark': null,
  'created_by': _userJson(id: 8, username: 'admin'),
  'created_at': '2026-09-22T10:00:00Z',
};

Map<String, Object?> _statementData() => <String, Object?>{
  'document_id': 42,
  'document_kind': 'inbound',
  'document_no': 'RK20260922-0001',
  'party_name': '华东钢贸',
  'business_user': _userJson(),
  'business_date': '2026-09-22',
  'total_amount': '100000.00',
  'total_amount_upper': '人民币壹拾万元整',
  'paid_amount': '30000.00',
  'unpaid_amount': '70000.00',
  'paid_amount_upper': '人民币叁万元整',
  'unpaid_amount_upper': '人民币柒万元整',
  'invoiced_amount': '50000.00',
  'uninvoiced_amount': '50000.00',
  'invoiced_amount_upper': '人民币伍万元整',
  'uninvoiced_amount_upper': '人民币伍万元整',
  'invoice_status': 'partial',
  'received_amount': '0.00',
  'unreceived_amount': '0.00',
  'received_amount_upper': '人民币零元整',
  'unreceived_amount_upper': '人民币零元整',
  'payment_count': 1,
  'receipt_count': 0,
  'invoice_count': 1,
  'records': <Object?>[_recordData()],
};

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

DioFinanceRepository _repo(_RecordingAdapter adapter, FinanceKind kind) =>
    DioFinanceRepository(
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

String _pageEnvelope() => _okEnvelope(<String, Object?>{
  'items': <Object?>[_recordData()],
  'page': 1,
  'page_size': 20,
  'total': 1,
});

String _statementEnvelope() => _okEnvelope(_statementData());

final class _FakeFinanceRepository implements FinanceRepository {
  FinanceStatement? statementResult;
  int createCalls = 0;

  @override
  Future<PageResult<FinanceRecord>> list(FinanceQuery query) =>
      Future<PageResult<FinanceRecord>>.value(
        PageResult<FinanceRecord>(
          items: <FinanceRecord>[FinanceRecord.fromJson(_recordData())],
          page: 1,
          pageSize: 20,
          total: 1,
        ),
      );

  @override
  Future<FinanceStatement> create(FinanceRecordDraft draft) {
    createCalls++;
    return Future<FinanceStatement>.value(
      statementResult ?? FinanceStatement.fromJson(_statementData()),
    );
  }

  @override
  Future<FinanceStatement> revoke(int recordId) =>
      Future<FinanceStatement>.value(
        statementResult ?? FinanceStatement.fromJson(_statementData()),
      );

  @override
  Future<FinanceStatement> statement(int documentId) =>
      Future<FinanceStatement>.value(
        statementResult ?? FinanceStatement.fromJson(_statementData()),
      );
}
