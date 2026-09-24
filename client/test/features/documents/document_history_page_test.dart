import 'package:c_biz_docs_manager/core/error/app_failure.dart';
import 'package:c_biz_docs_manager/core/money/money.dart';
import 'package:c_biz_docs_manager/core/network/page_result.dart';
import 'package:c_biz_docs_manager/features/documents/data/document_repository.dart';
import 'package:c_biz_docs_manager/features/documents/domain/document.dart';
import 'package:c_biz_docs_manager/features/documents/presentation/document_history_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
// `Override` 在 Riverpod 3 里由 misc.dart 导出。
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

/// 单据历史页的页面测试。
///
/// 只搭历史页与新建页两条最小路由（不套 CBizDocsApp），把假仓储覆盖进
/// controller 的装配点，断言「页面拿着状态做了什么」。
void main() {
  testWidgets('加载并渲染入库单列表', (WidgetTester tester) async {
    _setScreenSize(tester, const Size(1280, 800));
    final repository = FakeDocumentRepository()
      ..listResult = <DocumentSummary>[
        _summary(1, kind: DocumentKind.inbound),
        _summary(2, kind: DocumentKind.inbound),
      ];

    await tester.pumpWidget(_app(repository, kind: DocumentKind.inbound));
    await tester.pumpAndSettle();

    expect(find.text('RK20260922-0001'), findsOneWidget);
    expect(find.text('RK20260922-0002'), findsOneWidget);
  });

  testWidgets('AppBar 显示方向标题，新建按钮跳填写页', (WidgetTester tester) async {
    _setScreenSize(tester, const Size(1280, 800));
    final repository = FakeDocumentRepository()
      ..listResult = <DocumentSummary>[];

    await tester.pumpWidget(_app(repository, kind: DocumentKind.outbound));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(AppBar, '出库单'), findsOneWidget);

    await tester.tap(find.byTooltip('新建出库单'));
    await tester.pumpAndSettle();
    // 跳到了填写页（占位文本）。
    expect(find.text('填写页'), findsOneWidget);
  });

  testWidgets('加载失败显示失败视图可重试', (WidgetTester tester) async {
    _setScreenSize(tester, const Size(390, 844));
    final repository = FakeDocumentRepository()
      ..listError = const ServerFailure('boom');

    await tester.pumpWidget(_app(repository, kind: DocumentKind.inbound));
    await tester.pumpAndSettle();

    expect(find.text('重试'), findsOneWidget);
  });

  testWidgets('空列表显示空态文案', (WidgetTester tester) async {
    _setScreenSize(tester, const Size(1280, 800));
    final repository = FakeDocumentRepository()
      ..listResult = <DocumentSummary>[];

    await tester.pumpWidget(_app(repository, kind: DocumentKind.inbound));
    await tester.pumpAndSettle();

    expect(find.text('暂无入库单'), findsOneWidget);
  });
}

/* ---------------------------------------------------------------- 夹具 */

void _setScreenSize(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

Widget _app(FakeDocumentRepository repository, {required DocumentKind kind}) {
  final segment = kind == DocumentKind.outbound ? 'outbound' : 'inbound';
  final router = GoRouter(
    initialLocation: '/documents/$segment',
    routes: <RouteBase>[
      GoRoute(
        path: '/documents/:kind',
        builder: (BuildContext context, GoRouterState state) =>
            DocumentHistoryPage(
              kind: DocumentKind.fromWireValue(state.pathParameters['kind']!),
            ),
      ),
      GoRoute(
        path: '/documents/:kind/new',
        builder: (BuildContext context, GoRouterState state) =>
            const Scaffold(body: Center(child: Text('填写页'))),
      ),
    ],
  );
  addTearDown(router.dispose);
  return ProviderScope(
    overrides: <Override>[
      inboundDocumentRepositoryProvider.overrideWithValue(repository),
      outboundDocumentRepositoryProvider.overrideWithValue(repository),
    ],
    child: MaterialApp.router(routerConfig: router),
  );
}

/* ---------------------------------------------------------------- 假仓储 */

final class FakeDocumentRepository implements DocumentRepository {
  List<DocumentSummary>? listResult;
  Object? listError;
  DocumentDetail? detailResult;

  @override
  Future<PageResult<DocumentSummary>> list(DocumentQuery query) {
    if (listError != null) {
      return Future<PageResult<DocumentSummary>>.error(listError!);
    }
    final items = listResult ?? <DocumentSummary>[];
    return Future<PageResult<DocumentSummary>>.value(
      PageResult<DocumentSummary>(
        items: items,
        page: 1,
        pageSize: 20,
        total: items.length,
      ),
    );
  }

  @override
  Future<DocumentDetail> get(int documentId) =>
      Future<DocumentDetail>.value(detailResult ?? _detail(documentId));

  @override
  Future<DocumentDetail> create(DocumentDraft draft) =>
      Future<DocumentDetail>.value(detailResult ?? _detail(1));

  @override
  Future<DocumentDetail> update(
    int documentId,
    DocumentDraft draft,
    int version,
  ) => Future<DocumentDetail>.value(detailResult ?? _detail(documentId));

  @override
  Future<DocumentDetail> submit(int documentId, int version) =>
      Future<DocumentDetail>.value(
        detailResult ?? _detail(documentId, status: DocumentStatus.submitted),
      );

  @override
  Future<DocumentDetail> voidDocument(int documentId, int version) =>
      Future<DocumentDetail>.value(
        detailResult ?? _detail(documentId, status: DocumentStatus.voided),
      );
}

/* ---------------------------------------------------------------- 构造数据 */

DocumentSummary _summary(int id, {required DocumentKind kind}) =>
    DocumentSummary(
      documentId: id,
      kind: kind,
      documentNo: kind == DocumentKind.outbound
          ? 'CK20260922-000$id'
          : 'RK20260922-000$id',
      status: DocumentStatus.draft,
      businessDate: DateTime.utc(2026, 9, 22),
      businessUser: const DocumentBusinessUser(
        id: 7,
        displayName: '张三',
        username: '',
        accountType: '',
      ),
      partyNames: const <String>['华东钢贸'],
      itemCount: 1,
      totalAmount: Amount.parse('100.00'),
      version: 1,
      createdAt: DateTime.utc(2026, 9, 22),
      updatedAt: DateTime.utc(2026, 9, 22),
    );

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
  totalAmount: Amount.parse('100.00'),
  totalAmountUpper: '人民币壹佰元整',
  version: 1,
  createdAt: DateTime.utc(2026, 9, 22),
  updatedAt: DateTime.utc(2026, 9, 22),
  parties: const <DocumentParty>[],
);
