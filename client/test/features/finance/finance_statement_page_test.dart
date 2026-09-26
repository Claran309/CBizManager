import 'package:c_biz_docs_manager/app/router.dart';
import 'package:c_biz_docs_manager/core/auth/auth_controller.dart';
import 'package:c_biz_docs_manager/core/network/page_result.dart';
import 'package:c_biz_docs_manager/features/finance/data/finance_repository.dart';
import 'package:c_biz_docs_manager/features/finance/domain/finance.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
// `Override` 在 Riverpod 3 里由 misc.dart 导出。
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

import '../../support/auth_fixtures.dart';
import '../../support/fake_auth_repository.dart';

/// 结清视图页测试：派生金额直接展示服务端结果；登记入口按 finance.record 裁剪；
/// 入库单给「付款/开票」，出库单只给「收款」。
void main() {
  testWidgets('入库单结清视图展示已付/未付/开票状态，并给付款与开票入口', (WidgetTester tester) async {
    _setScreenSize(tester, const Size(1280, 800));
    final repository = FakeFinanceRepository()
      ..statementResult = _inboundStatement();

    await _pump(
      tester,
      repository,
      documentId: 42,
      permissionCodes: const <String>['finance.record'],
    );

    expect(find.text('100000.00'), findsOneWidget); // 单据总额
    expect(find.text('30000.00'), findsWidgets); // 已付
    expect(find.text('70000.00'), findsWidgets); // 未付
    expect(find.text('部分开票'), findsOneWidget); // 服务端推导的开票状态
    expect(find.widgetWithText(FilledButton, '登记付款'), findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, '登记开票'), findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, '登记收款'), findsNothing);
  });

  testWidgets('出库单结清视图展示已收/未收，只给收款入口', (WidgetTester tester) async {
    _setScreenSize(tester, const Size(1280, 800));
    final repository = FakeFinanceRepository()
      ..statementResult = _outboundStatement();

    await _pump(
      tester,
      repository,
      documentId: 43,
      permissionCodes: const <String>['finance.record'],
    );

    expect(find.text('40000.00'), findsWidgets); // 已收
    expect(find.text('80000.00'), findsWidgets); // 未收
    expect(find.widgetWithText(FilledButton, '登记收款'), findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, '登记开票'), findsNothing);
  });

  testWidgets('无 finance.record 权限不显示登记与撤销入口', (WidgetTester tester) async {
    _setScreenSize(tester, const Size(1280, 800));
    final repository = FakeFinanceRepository()
      ..statementResult = _inboundStatement();

    await _pump(tester, repository, documentId: 42);

    expect(find.widgetWithText(FilledButton, '登记付款'), findsNothing);
    expect(find.widgetWithText(OutlinedButton, '登记开票'), findsNothing);
    expect(find.byTooltip('撤销该记录'), findsNothing);
  });
}

/* ---------------------------------------------------------------- 夹具 */

void _setScreenSize(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

Future<void> _pump(
  WidgetTester tester,
  FakeFinanceRepository repository, {
  required int documentId,
  List<String> permissionCodes = const <String>[],
}) async {
  final container = ProviderContainer(
    overrides: <Override>[
      authRepositoryProvider.overrideWithValue(
        FakeAuthRepository(
          session: memberSession(permissionCodes: permissionCodes),
        ),
      ),
      paymentRepositoryProvider.overrideWithValue(repository),
      receiptRepositoryProvider.overrideWithValue(repository),
      invoiceRepositoryProvider.overrideWithValue(repository),
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
  router.go('/finance/statements/$documentId');
  await tester.pumpAndSettle();
}

/* ---------------------------------------------------------------- 假仓储 */

final class FakeFinanceRepository implements FinanceRepository {
  FinanceStatement? statementResult;

  @override
  Future<FinanceStatement> statement(int documentId) =>
      Future<FinanceStatement>.value(statementResult!);

  @override
  Future<FinanceStatement> create(FinanceRecordDraft draft) =>
      Future<FinanceStatement>.value(statementResult!);

  @override
  Future<FinanceStatement> revoke(int recordId) =>
      Future<FinanceStatement>.value(statementResult!);

  @override
  Future<PageResult<FinanceRecord>> list(FinanceQuery query) =>
      Future<PageResult<FinanceRecord>>.value(
        const PageResult<FinanceRecord>(
          items: <FinanceRecord>[],
          page: 1,
          pageSize: 20,
          total: 0,
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

Map<String, Object?> _base(String documentKind) => <String, Object?>{
  'document_id': 42,
  'document_kind': documentKind,
  'document_no': documentKind == 'outbound'
      ? 'CK20260922-0001'
      : 'RK20260922-0001',
  'party_name': '华东钢贸',
  'business_user': _userJson(),
  'business_date': '2026-09-22',
  'total_amount': '100000.00',
  'total_amount_upper': '人民币壹拾万元整',
  'paid_amount': '0.00',
  'unpaid_amount': '0.00',
  'paid_amount_upper': '人民币零元整',
  'unpaid_amount_upper': '人民币零元整',
  'invoiced_amount': '0.00',
  'uninvoiced_amount': '0.00',
  'invoiced_amount_upper': '人民币零元整',
  'uninvoiced_amount_upper': '人民币零元整',
  'invoice_status': 'none',
  'received_amount': '0.00',
  'unreceived_amount': '0.00',
  'received_amount_upper': '人民币零元整',
  'unreceived_amount_upper': '人民币零元整',
  'payment_count': 0,
  'receipt_count': 0,
  'invoice_count': 0,
  'records': <Object?>[],
};

FinanceStatement _inboundStatement() => FinanceStatement.fromJson(
  _base('inbound')
    ..['paid_amount'] = '30000.00'
    ..['unpaid_amount'] = '70000.00'
    ..['invoiced_amount'] = '50000.00'
    ..['uninvoiced_amount'] = '50000.00'
    ..['invoice_status'] = 'partial'
    ..['records'] = <Object?>[
      <String, Object?>{
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
        'created_by': _userJson(),
        'created_at': '2026-09-22T10:00:00Z',
      },
    ],
);

FinanceStatement _outboundStatement() => FinanceStatement.fromJson(
  _base('outbound')
    ..['received_amount'] = '40000.00'
    ..['unreceived_amount'] = '80000.00'
    ..['invoice_status'] = 'not_applicable',
);
