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
}) {
  return ProviderScope(
    overrides: <Override>[
      inboundDocumentRepositoryProvider.overrideWithValue(repository),
      outboundDocumentRepositoryProvider.overrideWithValue(repository),
    ],
    child: MaterialApp(home: DocumentFormPage(kind: kind)),
  );
}

final class FakeDocumentRepository implements DocumentRepository {
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
      Future<DocumentDetail>.error(StateError('not used'));

  @override
  Future<DocumentDetail> create(DocumentDraft draft) =>
      Future<DocumentDetail>.error(StateError('not used'));

  @override
  Future<DocumentDetail> update(
    int documentId,
    DocumentDraft draft,
    int version,
  ) => Future<DocumentDetail>.error(StateError('not used'));

  @override
  Future<DocumentDetail> submit(int documentId, int version) =>
      Future<DocumentDetail>.error(StateError('not used'));

  @override
  Future<DocumentDetail> voidDocument(int documentId, int version) =>
      Future<DocumentDetail>.error(StateError('not used'));
}
