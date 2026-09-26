import 'package:c_biz_docs_manager/app/router.dart';
import 'package:c_biz_docs_manager/core/auth/auth_controller.dart';
import 'package:c_biz_docs_manager/core/network/page_result.dart';
import 'package:c_biz_docs_manager/features/reports/data/report_repository.dart';
import 'package:c_biz_docs_manager/features/reports/domain/report.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
// `Override` 在 Riverpod 3 里由 misc.dart 导出。
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

import '../../support/auth_fixtures.dart';
import '../../support/fake_auth_repository.dart';

/// 报表页面测试：看板 / 统计 / 总结算渲染，以及入口按 report.view 裁剪。
///
/// 用真实 router + 假认证仓储：restore 后 navigate 到目标地址。
void main() {
  testWidgets('看板展示入库/出库/毛利金额', (WidgetTester tester) async {
    _setScreenSize(tester, const Size(1280, 800));
    final repository = FakeReportRepository();

    await _pump(tester, repository, '/reports', permissionCodes: _viewCodes);

    expect(find.text('100000.00 元'), findsOneWidget); // 入库
    expect(find.text('120000.00 元'), findsOneWidget); // 出库
    expect(find.text('20000.00 元'), findsOneWidget); // 毛利
  });

  testWidgets('入库统计页展示明细行', (WidgetTester tester) async {
    _setScreenSize(tester, const Size(1280, 800));
    final repository = FakeReportRepository();

    await _pump(
      tester,
      repository,
      '/reports/inbound-stats',
      permissionCodes: _viewCodes,
    );

    expect(find.text('螺纹钢 · HRB400'), findsOneWidget);
  });

  testWidgets('总结算页展示快照并带生成按钮', (WidgetTester tester) async {
    _setScreenSize(tester, const Size(1280, 800));
    final repository = FakeReportRepository();

    await _pump(
      tester,
      repository,
      '/reports/summary-settlements',
      permissionCodes: _viewCodes,
    );

    expect(find.text('ZJS202609-0003'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, '生成总结算'), findsOneWidget);
  });

  testWidgets('无 report.view 权限时访问 /reports 被守卫送回首页', (
    WidgetTester tester,
  ) async {
    _setScreenSize(tester, const Size(1280, 800));
    final repository = FakeReportRepository();

    // 没有任何权限的业务员。
    await _pump(
      tester,
      repository,
      '/reports',
      permissionCodes: const <String>[],
    );

    // 守卫把它送回 /home：看到租户首页标题，而不是报表看板。
    expect(find.widgetWithText(AppBar, '首页'), findsOneWidget);
    expect(find.widgetWithText(AppBar, '报表'), findsNothing);
  });
}

const List<String> _viewCodes = <String>['report.view'];

/* ---------------------------------------------------------------- 夹具 */

void _setScreenSize(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

Future<void> _pump(
  WidgetTester tester,
  FakeReportRepository repository,
  String location, {
  required List<String> permissionCodes,
}) async {
  final container = ProviderContainer(
    overrides: <Override>[
      authRepositoryProvider.overrideWithValue(
        FakeAuthRepository(
          session: memberSession(permissionCodes: permissionCodes),
        ),
      ),
      reportRepositoryProvider.overrideWithValue(repository),
    ],
  );
  addTearDown(container.dispose);

  final router = container.read(routerProvider);
  addTearDown(router.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await container.read(authControllerProvider.notifier).restore();
  await tester.pumpAndSettle();
  router.go(location);
  await tester.pumpAndSettle();
}

/* ---------------------------------------------------------------- 假仓储 */

final class FakeReportRepository implements ReportRepository {
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
  Future<PageResult<ReportSnapshot>> listSnapshots(SnapshotQuery query) =>
      Future<PageResult<ReportSnapshot>>.value(
        PageResult<ReportSnapshot>(
          items: <ReportSnapshot>[ReportSnapshot.fromJson(_snapshotData())],
          page: 1,
          pageSize: 20,
          total: 1,
        ),
      );

  @override
  Future<ReportSnapshot> getSnapshot(int snapshotId) =>
      Future<ReportSnapshot>.value(ReportSnapshot.fromJson(_snapshotData()));

  @override
  Future<CreateSnapshotResult> createSnapshots(CreateSnapshotDraft draft) =>
      Future<CreateSnapshotResult>.value(
        CreateSnapshotResult(
          batchNo: 'ZJS202609-0003',
          period: draft.period,
          snapshots: <ReportSnapshot>[ReportSnapshot.fromJson(_snapshotData())],
        ),
      );
}

/* ---------------------------------------------------------------- 数据 */

Map<String, Object?> _userJson() => <String, Object?>{
  'id': 7,
  'username': 'zhangsan',
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
  'items': <Object?>[
    <String, Object?>{
      'party_name': '华东钢贸',
      'product_name': '螺纹钢',
      'product_model': 'HRB400',
      'unit': '吨',
      'document_count': 1,
      'quantity': '17.050',
      'amount': '50731.08',
      'amount_upper': '人民币伍万零柒佰叁拾壹元零捌分',
    },
  ],
  'page': 1,
  'page_size': 20,
  'total': 1,
};

Map<String, Object?> _snapshotData() => <String, Object?>{
  'snapshot_id': 9,
  'snapshot_no': 'ZJS202609-0003',
  'batch_no': 'ZJS202609-0003',
  'scope': 'company',
  'period': '2026-09',
  'business_user': <String, Object?>{
    'id': 0,
    'username': '',
    'display_name': '',
    'account_type': '',
  },
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
