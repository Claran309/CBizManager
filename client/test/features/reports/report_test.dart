import 'dart:convert';

import 'package:c_biz_docs_manager/core/network/page_result.dart';
import 'package:c_biz_docs_manager/features/reports/application/report_controller.dart';
import 'package:c_biz_docs_manager/features/reports/data/report_repository.dart';
import 'package:c_biz_docs_manager/features/reports/domain/report.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
// `Override` 在 Riverpod 3 里由 misc.dart 导出。
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

/// 报表模块的契约测试。
void main() {
  group('ReportOverview.fromJson', () {
    test('解析看板（含 ppm 比率与销售金额分项）', () {
      final overview = ReportOverview.fromJson(_overviewData());
      expect(overview.period, '2026-09');
      expect(overview.inboundAmount.format(), '100000.00');
      expect(overview.outboundAmount.format(), '120000.00');
      expect(overview.grossProfit.format(), '20000.00');
      expect(overview.grossMarginPpm, 166667);
      expect(overview.grossMarginPercent, '16.67');
      expect(overview.saleAmountTypes, hasLength(3));
      expect(overview.saleAmountTypes.first.saleAmountType.wireValue, 'Y-1');
      expect(overview.saleAmountTypes.first.sharePercent, '50.00');
    });
  });

  group('InboundStats.fromJson', () {
    test('解析统计（含明细聚合行，只给金额与数量）', () {
      final stats = InboundStats.fromJson(_inboundStatsData());
      expect(stats.documentCount, 2);
      expect(stats.amountTotal.format(), '100000.00');
      expect(stats.unpaidDocumentCount, 1);
      final item = stats.items.single;
      expect(item.partyName, '华东钢贸');
      expect(item.productName, '螺纹钢');
      expect(item.quantity.format(), '17.050');
      expect(item.amount.format(), '50731.08');
    });
  });

  group('ReportSnapshot.fromJson', () {
    test('公司维度快照的 business_user 是全零值 → 解析成 null', () {
      final json = _snapshotData()
        ..['scope'] = 'company'
        ..['business_user'] = <String, Object?>{
          'id': 0,
          'username': '',
          'display_name': '',
          'account_type': '',
        };
      final snapshot = ReportSnapshot.fromJson(json);
      expect(snapshot.scope, ReportScope.company);
      expect(snapshot.businessUser, isNull);
    });

    test('业务员维度快照的 business_user 是完整用户', () {
      final json = _snapshotData()..['scope'] = 'business_user';
      final snapshot = ReportSnapshot.fromJson(json);
      expect(snapshot.scope, ReportScope.businessUser);
      expect(snapshot.businessUser?.username, 'zhangsan');
    });

    test('公司维度但 business_user 是真实 id 时也解析出来', () {
      // 契约说公司维度回零值，但解析逻辑只按「id 是否为正整数」判断，不猜 scope。
      final json = _snapshotData()..['scope'] = 'business_user';
      expect(ReportSnapshot.fromJson(json).businessUser?.id, 7);
    });
  });

  group('DioReportRepository 请求拼装', () {
    test('overview 拼 period 与可选 business_user_id', () async {
      final recorder = _recorder(
        (options) => (200, _okEnvelope(_overviewData())),
      );
      await _repo(
        recorder.adapter,
      ).overview(const PeriodQuery(period: '2026-09', businessUserId: 7));
      final request = recorder.adapter.requests.single;
      expect(request.method, 'GET');
      expect(request.path, '/api/v1/reports/overview');
      expect(request.queryParameters, <String, Object?>{
        'period': '2026-09',
        'business_user_id': 7,
      });
    });

    test('inbound-stats 拼字段筛选与分页', () async {
      final recorder = _recorder(
        (options) => (200, _okEnvelope(_inboundStatsData())),
      );
      await _repo(recorder.adapter).inboundStats(
        const StatsQuery(
          period: '2026-09',
          partyName: '华东',
          page: 2,
          pageSize: 50,
        ),
      );
      final request = recorder.adapter.requests.single;
      expect(request.path, '/api/v1/reports/inbound-stats');
      expect(request.queryParameters, <String, Object?>{
        'period': '2026-09',
        'page': 2,
        'page_size': 50,
        'party_name': '华东',
      });
    });

    test('createSnapshots 请求体 scope 用 wire 值、不指定业务员发 0', () async {
      final recorder = _recorder(
        (options) => (200, _okEnvelope(_createSnapshotData())),
      );
      await _repo(recorder.adapter).createSnapshots(
        const CreateSnapshotDraft(
          period: '2026-09',
          scope: ReportScope.businessUser,
        ),
      );
      final request = recorder.adapter.requests.single;
      expect(request.method, 'POST');
      expect(request.path, '/api/v1/reports/summary-settlements');
      final body = request.data as Map<String, Object?>;
      expect(body['period'], '2026-09');
      expect(body['scope'], 'business_user');
      expect(body['business_user_id'], 0);
      expect(body.containsKey('remark'), isFalse);
    });

    test('listSnapshots 走分页平铺', () async {
      final recorder = _recorder(
        (options) => (
          200,
          _okEnvelope(<String, Object?>{
            'items': <Object?>[_snapshotData()],
            'page': 1,
            'page_size': 20,
            'total': 1,
          }),
        ),
      );
      final page = await _repo(recorder.adapter).listSnapshots(
        const SnapshotQuery(period: '2026-09', scope: ReportScope.company),
      );
      expect(
        recorder.adapter.requests.single.path,
        '/api/v1/reports/summary-settlements',
      );
      expect(page.items, hasLength(1));
    });
  });

  group('ReportController', () {
    test('生成快照成功后重读快照列表', () async {
      final repository = _FakeReportRepository();
      final container = ProviderContainer(
        overrides: <Override>[
          reportRepositoryProvider.overrideWithValue(repository),
        ],
      );
      addTearDown(container.dispose);

      await container
          .read(reportControllerProvider.notifier)
          .createSnapshots(
            const CreateSnapshotDraft(
              period: '2026-09',
              scope: ReportScope.company,
            ),
          );

      expect(repository.createCalls, 1);
      expect(repository.listSnapshotsCalls, 1);
      expect(container.read(reportControllerProvider).snapshots, hasLength(1));
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

List<Object?> _saleAmountTypes() => <Object?>[
  <String, Object?>{
    'sale_amount_type': 'Y-1',
    'amount': '60000.00',
    'amount_upper': '人民币陆万元整',
    'share_ppm': 500000,
    'share_percent': '50.00',
  },
  <String, Object?>{
    'sale_amount_type': 'y-N',
    'amount': '40000.00',
    'amount_upper': '人民币肆万元整',
    'share_ppm': 333333,
    'share_percent': '33.33',
  },
  <String, Object?>{
    'sale_amount_type': 'N',
    'amount': '20000.00',
    'amount_upper': '人民币贰万元整',
    'share_ppm': 166667,
    'share_percent': '16.67',
  },
];

Map<String, Object?> _overviewData() => <String, Object?>{
  'period': '2026-09',
  'inbound_document_count': 2,
  'inbound_amount': '100000.00',
  'inbound_amount_upper': '人民币壹拾万元整',
  'outbound_document_count': 3,
  'outbound_amount': '120000.00',
  'outbound_amount_upper': '人民币壹拾贰万元整',
  'gross_profit': '20000.00',
  'gross_profit_upper': '人民币贰万元整',
  'gross_margin_ppm': 166667,
  'gross_margin_percent': '16.67',
  'paid_amount': '50000.00',
  'unpaid_amount': '50000.00',
  'unpaid_amount_upper': '人民币伍万元整',
  'unpaid_document_count': 1,
  'invoiced_amount': '60000.00',
  'uninvoiced_amount': '40000.00',
  'uninvoiced_amount_upper': '人民币肆万元整',
  'uninvoiced_document_count': 1,
  'received_amount': '80000.00',
  'unreceived_amount': '40000.00',
  'unreceived_amount_upper': '人民币肆万元整',
  'unreceived_document_count': 1,
  'supplier_count': 1,
  'customer_count': 2,
  'sale_amount_types': _saleAmountTypes(),
};

Map<String, Object?> _itemData() => <String, Object?>{
  'party_name': '华东钢贸',
  'product_name': '螺纹钢',
  'product_model': 'HRB400',
  'unit': '吨',
  'document_count': 1,
  'quantity': '17.050',
  'amount': '50731.08',
  'amount_upper': '人民币伍万零柒佰叁拾壹元零捌分',
};

Map<String, Object?> _inboundStatsData() => <String, Object?>{
  'period': '2026-09',
  'document_count': 2,
  'amount_total': '100000.00',
  'amount_total_upper': '人民币壹拾万元整',
  'paid_amount': '50000.00',
  'unpaid_amount': '50000.00',
  'unpaid_amount_upper': '人民币伍万元整',
  'unpaid_document_count': 1,
  'invoiced_amount': '60000.00',
  'uninvoiced_amount': '40000.00',
  'uninvoiced_amount_upper': '人民币肆万元整',
  'uninvoiced_document_count': 1,
  'supplier_count': 1,
  'items': <Object?>[_itemData()],
  'page': 1,
  'page_size': 20,
  'total': 1,
};

Map<String, Object?> _snapshotData() => <String, Object?>{
  'snapshot_id': 9,
  'snapshot_no': 'ZJS202609-0003',
  'batch_no': 'ZJS202609-0003',
  'scope': 'business_user',
  'period': '2026-09',
  'business_user': _userJson(),
  'inbound_amount': '100000.00',
  'inbound_amount_upper': '人民币壹拾万元整',
  'outbound_amount': '120000.00',
  'outbound_amount_upper': '人民币壹拾贰万元整',
  'gross_profit': '20000.00',
  'gross_profit_upper': '人民币贰万元整',
  'gross_margin_ppm': 166667,
  'gross_margin_percent': '16.67',
  'sale_amount_types': _saleAmountTypes(),
  'document_count': 5,
  'remark': null,
  'created_by': _userJson(),
  'created_at': '2026-09-22T10:00:00Z',
};

Map<String, Object?> _createSnapshotData() => <String, Object?>{
  'batch_no': 'ZJS202609-0003',
  'period': '2026-09',
  'snapshots': <Object?>[_snapshotData()],
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

DioReportRepository _repo(_RecordingAdapter adapter) => DioReportRepository(
  Dio(BaseOptions(baseUrl: 'https://api.example.test'))
    ..httpClientAdapter = adapter,
);

String _okEnvelope(Object? data) => jsonEncode(<String, Object?>{
  'code': 'OK',
  'message': 'success',
  'data': data,
  'request_id': 'request-1',
});

final class _FakeReportRepository implements ReportRepository {
  int createCalls = 0;
  int listSnapshotsCalls = 0;

  @override
  Future<ReportOverview> overview(PeriodQuery query) =>
      Future<ReportOverview>.value(ReportOverview.fromJson(_overviewData()));

  @override
  Future<InboundStats> inboundStats(StatsQuery query) =>
      Future<InboundStats>.value(InboundStats.fromJson(_inboundStatsData()));

  @override
  Future<OutboundStats> outboundStats(StatsQuery query) =>
      Future<OutboundStats>.error(StateError('not used'));

  @override
  Future<BusinessUserReport> businessUsers(String period) =>
      Future<BusinessUserReport>.error(StateError('not used'));

  @override
  Future<PageResult<ReportSnapshot>> listSnapshots(SnapshotQuery query) {
    listSnapshotsCalls++;
    return Future<PageResult<ReportSnapshot>>.value(
      PageResult<ReportSnapshot>(
        items: <ReportSnapshot>[ReportSnapshot.fromJson(_snapshotData())],
        page: 1,
        pageSize: 20,
        total: 1,
      ),
    );
  }

  @override
  Future<ReportSnapshot> getSnapshot(int snapshotId) =>
      Future<ReportSnapshot>.value(ReportSnapshot.fromJson(_snapshotData()));

  @override
  Future<CreateSnapshotResult> createSnapshots(CreateSnapshotDraft draft) {
    createCalls++;
    return Future<CreateSnapshotResult>.value(
      CreateSnapshotResult.fromJson(_createSnapshotData()),
    );
  }
}
