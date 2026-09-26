import 'package:c_biz_docs_manager/core/money/money.dart';
import 'package:c_biz_docs_manager/core/network/page_result.dart';
import 'package:c_biz_docs_manager/features/documents/data/document_repository.dart';
import 'package:c_biz_docs_manager/features/documents/domain/document.dart';
import 'package:c_biz_docs_manager/features/documents/presentation/document_form_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
// `Override` 在 Riverpod 3 里由 misc.dart 导出。
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

/// 单据填写页的页面测试。
void main() {
  testWidgets('渲染单据头字段与明细行', (WidgetTester tester) async {
    _setScreenSize(tester, const Size(1280, 800));
    final repository = FakeDocumentRepository();

    await tester.pumpWidget(_app(repository));
    await tester.pumpAndSettle();

    expect(find.text('业务日期'), findsOneWidget);
    expect(find.text('品名'), findsOneWidget);
    expect(find.text('数量'), findsOneWidget);
    expect(find.text('单价'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, '保存草稿'), findsOneWidget);
  });

  testWidgets('出库单显示运输单位与销售金额类型', (WidgetTester tester) async {
    _setScreenSize(tester, const Size(1280, 800));
    final repository = FakeDocumentRepository();

    await tester.pumpWidget(_app(repository, kind: DocumentKind.outbound));
    await tester.pumpAndSettle();

    expect(find.text('运输单位'), findsOneWidget);
    expect(find.text('销售金额类型'), findsOneWidget);
  });

  testWidgets('添加明细与添加入库公司', (WidgetTester tester) async {
    _setScreenSize(tester, const Size(1280, 800));
    final repository = FakeDocumentRepository();

    await tester.pumpWidget(_app(repository));
    await tester.pumpAndSettle();

    // 初始一个分组、一个明细行。
    expect(find.text('品名'), findsOneWidget);

    await tester.tap(find.text('添加明细'));
    await tester.pumpAndSettle();
    // 同一分组里变两个明细行。
    expect(find.text('品名'), findsNWidgets(2));

    await tester.tap(find.text('添加入库公司'));
    await tester.pumpAndSettle();
    // 第一个分组 2 个明细 + 第二个分组 1 个明细 = 3 个品名。
    expect(find.text('品名'), findsNWidgets(3));
  });

  testWidgets('新建页提供「保存草稿」与「提交」两个动作', (WidgetTester tester) async {
    _setScreenSize(tester, const Size(1280, 800));
    await tester.pumpWidget(_app(FakeDocumentRepository()));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(FilledButton, '保存草稿'), findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, '提交'), findsOneWidget);
    // 还没保存过，没有可作废的对象。
    expect(find.widgetWithText(OutlinedButton, '作废'), findsNothing);
  });

  testWidgets('编辑草稿：回填原内容，可保存/提交/作废', (WidgetTester tester) async {
    _setScreenSize(tester, const Size(1280, 800));
    final repository = FakeDocumentRepository()
      ..detailResult = _detail(42, status: DocumentStatus.draft);

    await tester.pumpWidget(_app(repository, documentId: 42));
    await tester.pumpAndSettle();

    // 回填：原有明细内容出现在输入框里（不回填的话编辑一次就把内容清空了）。
    expect(find.text('螺纹钢'), findsOneWidget);
    expect(find.text('17.050'), findsOneWidget);
    expect(find.text('2975.4300'), findsOneWidget);

    expect(find.widgetWithText(FilledButton, '保存'), findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, '提交'), findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, '作废'), findsOneWidget);

    await tester.tap(find.widgetWithText(OutlinedButton, '作废'));
    await tester.pumpAndSettle();
    expect(repository.voidCalls, 1);
  });

  testWidgets('已提交单据只读，只剩「作废」', (WidgetTester tester) async {
    _setScreenSize(tester, const Size(1280, 800));
    final repository = FakeDocumentRepository()
      ..detailResult = _detail(42, status: DocumentStatus.submitted);

    await tester.pumpWidget(_app(repository, documentId: 42));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(OutlinedButton, '作废'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, '保存'), findsNothing);
    expect(find.widgetWithText(OutlinedButton, '提交'), findsNothing);
    // 只读：不能再加明细，输入框也禁用。
    expect(find.text('添加明细'), findsNothing);
    final productField = tester.widget<TextField>(
      find.widgetWithText(TextField, '螺纹钢'),
    );
    expect(productField.enabled, isFalse);
  });

  testWidgets('已作废单据没有任何动作', (WidgetTester tester) async {
    _setScreenSize(tester, const Size(1280, 800));
    final repository = FakeDocumentRepository()
      ..detailResult = _detail(42, status: DocumentStatus.voided);

    await tester.pumpWidget(_app(repository, documentId: 42));
    await tester.pumpAndSettle();

    expect(find.text('该单据已作废，不可再修改。'), findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, '作废'), findsNothing);
  });
}

/* ---------------------------------------------------------------- 夹具 */

void _setScreenSize(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

Widget _app(
  FakeDocumentRepository repository, {
  DocumentKind kind = DocumentKind.inbound,
  int? documentId,
}) {
  return ProviderScope(
    overrides: <Override>[
      inboundDocumentRepositoryProvider.overrideWithValue(repository),
      outboundDocumentRepositoryProvider.overrideWithValue(repository),
    ],
    child: MaterialApp(
      home: DocumentFormPage(kind: kind, documentId: documentId),
    ),
  );
}

/// 一张详情夹具：一个往来单位 + 一条明细（数量/单价用服务端会返回的固定位数）。
DocumentDetail _detail(
  int id, {
  DocumentStatus status = DocumentStatus.draft,
}) => DocumentDetail(
  documentId: id,
  kind: DocumentKind.inbound,
  documentNo: 'RK20260922-000$id',
  status: status,
  businessUser: const DocumentBusinessUser(
    id: 7,
    displayName: '张三',
    username: 'zhangsan',
    accountType: 'member',
  ),
  businessDate: DateTime.utc(2026, 9, 22),
  totalAmount: Amount.parse('50731.08'),
  totalAmountUpper: '人民币伍万零柒佰叁拾壹元零捌分',
  version: 1,
  createdAt: DateTime.utc(2026, 9, 22),
  updatedAt: DateTime.utc(2026, 9, 22),
  parties: <DocumentParty>[
    DocumentParty(
      partyId: 1,
      position: 1,
      partyName: '华东钢贸',
      subtotal: Amount.parse('50731.08'),
      items: <DocumentItem>[
        DocumentItem(
          itemId: 101,
          position: 1,
          productName: '螺纹钢',
          productModel: 'HRB400',
          unit: '吨',
          quantity: Quantity.parse('17.050'),
          unitPrice: UnitPrice.parse('2975.4300'),
          priceTaxMode: PriceTaxMode.taxIncluded,
          amount: Amount.parse('50731.08'),
        ),
      ],
    ),
  ],
);

final class FakeDocumentRepository implements DocumentRepository {
  DocumentDetail? detailResult;
  int voidCalls = 0;

  @override
  Future<PageResult<DocumentSummary>> list(DocumentQuery query) =>
      Future<PageResult<DocumentSummary>>.value(
        const PageResult<DocumentSummary>(
          items: <DocumentSummary>[],
          page: 1,
          pageSize: 20,
          total: 0,
        ),
      );

  @override
  Future<DocumentDetail> get(int documentId) =>
      Future<DocumentDetail>.value(detailResult ?? _detail(documentId));

  @override
  Future<DocumentDetail> create(DocumentDraft draft) =>
      Future<DocumentDetail>.value(_detail(1, status: draft.status));

  @override
  Future<DocumentDetail> update(
    int documentId,
    DocumentDraft draft,
    int version,
  ) => Future<DocumentDetail>.value(_detail(documentId));

  @override
  Future<DocumentDetail> submit(int documentId, int version) =>
      Future<DocumentDetail>.value(
        _detail(documentId, status: DocumentStatus.submitted),
      );

  @override
  Future<DocumentDetail> voidDocument(int documentId, int version) {
    voidCalls++;
    return Future<DocumentDetail>.value(
      _detail(documentId, status: DocumentStatus.voided),
    );
  }
}
