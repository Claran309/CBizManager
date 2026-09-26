import 'package:c_biz_docs_manager/app/router.dart';
import 'package:c_biz_docs_manager/core/auth/auth_controller.dart';
import 'package:c_biz_docs_manager/core/auth/auth_models.dart';
import 'package:c_biz_docs_manager/core/money/money.dart';
import 'package:c_biz_docs_manager/core/network/page_result.dart';
import 'package:c_biz_docs_manager/features/documents/data/document_repository.dart';
import 'package:c_biz_docs_manager/features/documents/domain/document.dart';
import 'package:c_biz_docs_manager/features/settlements/data/settlement_repository.dart';
import 'package:c_biz_docs_manager/features/settlements/domain/settlement.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
// `Override` 在 Riverpod 3 里由 misc.dart 导出。
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

import '../../support/auth_fixtures.dart';
import '../../support/fake_auth_repository.dart';

/// 申请结算页测试：列出候选单据、勾选后提交、把选中的 id 交给仓储。
void main() {
  testWidgets('列出可结算单据，勾选后可提交且带上选中的 id', (WidgetTester tester) async {
    _setScreenSize(tester, const Size(1280, 800));
    // 入库/出库各一个假仓储：候选清单只由入库侧提供，避免同一条单据出现两次。
    final inbound = FakeDocumentRepository()
      ..listResult = <DocumentSummary>[_summary(42, DocumentKind.inbound)];
    final outbound = FakeDocumentRepository();
    final settlements = FakeSettlementRepository();

    await _pump(
      tester,
      inbound: inbound,
      outbound: outbound,
      settlements: settlements,
    );

    // 候选项出现。
    expect(find.text('RK20260922-0042'), findsOneWidget);
    // 未勾选时提交按钮禁用。
    final before = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, '提交结算申请（已选 0 张）'),
    );
    expect(before.onPressed, isNull);

    await tester.tap(find.byType(CheckboxListTile));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '提交结算申请（已选 1 张）'));
    await tester.pumpAndSettle();

    expect(settlements.lastDraft?.sourceDocumentIds, <int>[42]);
  });

  testWidgets('该月份没有候选单据时给出空提示', (WidgetTester tester) async {
    _setScreenSize(tester, const Size(1280, 800));
    final inbound = FakeDocumentRepository();
    final outbound = FakeDocumentRepository();
    final settlements = FakeSettlementRepository();

    await _pump(
      tester,
      inbound: inbound,
      outbound: outbound,
      settlements: settlements,
    );

    expect(find.text('该月份没有可结算的已提交单据'), findsOneWidget);
  });
}

/* ---------------------------------------------------------------- 夹具 */

void _setScreenSize(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

Future<void> _pump(
  WidgetTester tester, {
  required FakeDocumentRepository inbound,
  required FakeDocumentRepository outbound,
  required FakeSettlementRepository settlements,
}) async {
  final container = ProviderContainer(
    overrides: <Override>[
      authRepositoryProvider.overrideWithValue(
        FakeAuthRepository(session: memberSession()),
      ),
      inboundDocumentRepositoryProvider.overrideWithValue(inbound),
      outboundDocumentRepositoryProvider.overrideWithValue(outbound),
      settlementRepositoryProvider.overrideWithValue(settlements),
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
  router.go('/settlements/new');
  await tester.pumpAndSettle();
}

/* ---------------------------------------------------------------- 假仓储 */

final class FakeDocumentRepository implements DocumentRepository {
  List<DocumentSummary> listResult = <DocumentSummary>[];

  @override
  Future<PageResult<DocumentSummary>> list(DocumentQuery query) =>
      Future<PageResult<DocumentSummary>>.value(
        PageResult<DocumentSummary>(
          items: listResult,
          page: 1,
          pageSize: 20,
          total: listResult.length,
        ),
      );

  @override
  Future<DocumentDetail> get(int documentId) =>
      Future<DocumentDetail>.error(StateError('not used'));

  @override
  Future<DocumentDetail> create(DocumentDraft draft) =>
      Future<DocumentDetail>.error(StateError('not used'));

  @override
  Future<DocumentDetail> update(int d, DocumentDraft draft, int version) =>
      Future<DocumentDetail>.error(StateError('not used'));

  @override
  Future<DocumentDetail> submit(int documentId, int version) =>
      Future<DocumentDetail>.error(StateError('not used'));

  @override
  Future<DocumentDetail> voidDocument(int documentId, int version) =>
      Future<DocumentDetail>.error(StateError('not used'));
}

final class FakeSettlementRepository implements SettlementRepository {
  SettlementDraft? lastDraft;

  @override
  Future<SettlementDetail> create(SettlementDraft draft) {
    lastDraft = draft;
    return Future<SettlementDetail>.value(_detail(9));
  }

  @override
  Future<PageResult<SettlementSummary>> list(SettlementQuery query) =>
      Future<PageResult<SettlementSummary>>.value(
        const PageResult<SettlementSummary>(
          items: <SettlementSummary>[],
          page: 1,
          pageSize: 20,
          total: 0,
        ),
      );

  @override
  Future<SettlementDetail> get(int settlementId) =>
      Future<SettlementDetail>.value(_detail(settlementId));

  @override
  Future<SettlementDetail> approve(int settlementId, int version) =>
      Future<SettlementDetail>.error(StateError('not used'));

  @override
  Future<SettlementDetail> reject(int s, int v, String remark) =>
      Future<SettlementDetail>.error(StateError('not used'));
}

/* ---------------------------------------------------------------- 数据 */

DocumentSummary _summary(int id, DocumentKind kind) => DocumentSummary(
  documentId: id,
  kind: kind,
  documentNo: 'RK20260922-00$id',
  status: DocumentStatus.submitted,
  businessDate: DateTime.utc(2026, 9, 22),
  businessUser: const DocumentBusinessUser(
    id: 7,
    displayName: '张三',
    username: 'zhangsan',
    accountType: 'member',
  ),
  partyNames: const <String>['华东钢贸'],
  itemCount: 1,
  totalAmount: Amount.parse('100000.00'),
  version: 1,
  createdAt: DateTime.utc(2026, 9, 22),
  updatedAt: DateTime.utc(2026, 9, 22),
);

SettlementDetail _detail(int id) => SettlementDetail(
  settlementId: id,
  settlementNo: 'JS202609-000$id',
  status: SettlementStatus.pending,
  requester: const AuthUser(
    id: 7,
    username: 'zhangsan',
    displayName: '张三',
    accountType: AccountType.member,
  ),
  inboundTotal: Amount.parse('100000.00'),
  outboundTotal: Amount.parse('0.00'),
  grossProfit: Amount.parse('-100000.00'),
  sourceCount: 1,
  inboundUpper: '人民币壹拾万元整',
  outboundUpper: '人民币零元整',
  grossProfitUpper: '人民币负壹拾万元整',
  version: 1,
  createdAt: DateTime.utc(2026, 9, 22),
  updatedAt: DateTime.utc(2026, 9, 22),
  sources: const <SettlementSource>[],
  approvalRecords: const <SettlementApprovalRecord>[],
);
