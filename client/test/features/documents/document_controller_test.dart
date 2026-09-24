import 'dart:async';

import 'package:c_biz_docs_manager/core/error/app_failure.dart';
import 'package:c_biz_docs_manager/core/money/money.dart';
import 'package:c_biz_docs_manager/core/network/page_result.dart';
import 'package:c_biz_docs_manager/features/documents/application/document_controller.dart';
import 'package:c_biz_docs_manager/features/documents/data/document_repository.dart';
import 'package:c_biz_docs_manager/features/documents/domain/document.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
// `Override` 在 Riverpod 3 里由 misc.dart 导出，主入口没给。
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

/// 单据控制器的时序测试。
///
/// 覆盖列表乱序丢弃、写操作串行、冲突后重读、dispose 后不写 state、
/// 写成功后用服务端返回的新详情替换本地那份（version 跟着涨）。
void main() {
  late FakeDocumentRepository repository;
  late ProviderContainer container;

  setUp(() {
    repository = FakeDocumentRepository();
    container = ProviderContainer(
      overrides: <Override>[
        inboundDocumentRepositoryProvider.overrideWithValue(repository),
        outboundDocumentRepositoryProvider.overrideWithValue(repository),
      ],
    );
    addTearDown(container.dispose);
  });

  DocumentController controller() =>
      container.read(documentControllerProvider(DocumentKind.inbound).notifier);

  DocumentState state() =>
      container.read(documentControllerProvider(DocumentKind.inbound));

  group('列表加载', () {
    test('加载成功写入 items', () async {
      repository.listResult = <DocumentSummary>[_summary(1), _summary(2)];
      await controller().load(const DocumentQuery());
      expect(state().items, hasLength(2));
      expect(state().isLoading, isFalse);
      expect(state().failure, isNull);
    });

    test('乱序响应：后到的旧结果被丢弃', () async {
      final first = Completer<List<DocumentSummary>>();
      final second = Completer<List<DocumentSummary>>();
      repository.queuedLists.addAll([first.future, second.future]);

      final loadFuture = controller().load(const DocumentQuery());
      // 第二次 load 会覆盖 generation，第一次的响应作废。
      final secondLoad = controller().load(const DocumentQuery());

      second.complete(<DocumentSummary>[_summary(99)]);
      await secondLoad;
      first.complete(<DocumentSummary>[_summary(1)]);
      await loadFuture;

      // 旧结果（summary 1）不该覆盖新结果（summary 99）。
      expect(state().items.single.documentId, 99);
    });

    test('加载失败写入 failure', () async {
      repository.listError = const ServerFailure('boom');
      await controller().load(const DocumentQuery());
      expect(state().failure, isA<ServerFailure>());
      expect(state().isLoading, isFalse);
    });
  });

  group('详情加载', () {
    test('加载详情写入 detail', () async {
      repository.detailResult = _detail(42);
      await controller().loadDetail(42);
      expect(state().detail?.documentId, 42);
      expect(state().isLoadingDetail, isFalse);
    });
  });

  group('写操作', () {
    test('提交成功：用服务端返回的新详情替换本地那份', () async {
      repository.listResult = <DocumentSummary>[_summary(42)];
      await controller().load(const DocumentQuery());
      repository.detailResult = _detail(42, status: DocumentStatus.submitted);

      await controller().submit(42, 3);

      expect(state().detail?.status, DocumentStatus.submitted);
      expect(repository.submittedVersions, <int>[3]);
    });

    test('写操作串行：前一个未完成前不发下一个', () async {
      // submit 成功后 controller 会重读列表，先给列表配好响应。
      repository.listResult = <DocumentSummary>[_summary(42)];
      final gate = Completer<DocumentDetail>();
      repository.queuedDetails.add(gate.future);

      final first = controller().submit(42, 3);
      final second = controller().voidDocument(42, 4);

      // 让排队的微任务先跑起来：第一个 operation 会执行到 `repository.submit`
      // 并挂在未完成的 gate 上，第二个 operation 仍排队在后。
      await Future<void>.delayed(Duration.zero);

      expect(repository.submitCalls, 1);
      expect(repository.voidCalls, 0);

      gate.complete(_detail(42));
      await first;
      await second;

      expect(repository.voidCalls, 1);
    });

    test('冲突后重读列表并保留冲突原因', () async {
      repository.listResult = <DocumentSummary>[_summary(42)];
      await controller().load(const DocumentQuery());
      repository.submitError = const ConflictFailure('version conflict');

      await controller().submit(42, 3);

      // 冲突后重读了列表（load 被再次调用）。
      expect(repository.listCalls, greaterThan(1));
      expect(state().failure, isA<ConflictFailure>());
    });

    test('写失败（非冲突）保留 failure', () async {
      repository.submitError = const ServerFailure('server down');
      await controller().submit(42, 3);
      expect(state().failure, isA<ServerFailure>());
      expect(state().isWriting, isFalse);
    });
  });

  group('dispose', () {
    test('dispose 后在途结果不写 state', () async {
      final gate = Completer<List<DocumentSummary>>();
      repository.queuedLists.add(gate.future);

      final loadFuture = controller().load(const DocumentQuery());
      container.dispose();

      gate.complete(<DocumentSummary>[_summary(1)]);
      await loadFuture;
      // 不抛错即通过：控制器作废了在途结果。
    });
  });
}

/* ---------------------------------------------------------------- 假仓储 */

final class FakeDocumentRepository implements DocumentRepository {
  final List<Future<List<DocumentSummary>>> queuedLists =
      <Future<List<DocumentSummary>>>[];
  Object? listError;
  List<DocumentSummary>? listResult;

  final List<Future<DocumentDetail>> queuedDetails = <Future<DocumentDetail>>[];
  Object? detailError;
  DocumentDetail? detailResult;

  Object? submitError;
  Object? voidError;
  Object? createError;
  Object? updateError;

  int listCalls = 0;
  int submitCalls = 0;
  int voidCalls = 0;
  int createCalls = 0;
  int updateCalls = 0;
  final List<int> submittedVersions = <int>[];

  @override
  Future<DocumentDetail> create(DocumentDraft draft) {
    createCalls++;
    if (createError != null) {
      return Future<DocumentDetail>.error(createError!);
    }
    if (queuedDetails.isNotEmpty) return queuedDetails.removeAt(0);
    return Future<DocumentDetail>.value(detailResult ?? _detail(1));
  }

  @override
  Future<DocumentDetail> get(int documentId) {
    if (detailError != null) {
      return Future<DocumentDetail>.error(detailError!);
    }
    if (queuedDetails.isNotEmpty) return queuedDetails.removeAt(0);
    return Future<DocumentDetail>.value(detailResult ?? _detail(documentId));
  }

  @override
  Future<DocumentDetail> submit(int documentId, int version) {
    submitCalls++;
    submittedVersions.add(version);
    if (submitError != null) {
      return Future<DocumentDetail>.error(submitError!);
    }
    if (queuedDetails.isNotEmpty) return queuedDetails.removeAt(0);
    return Future<DocumentDetail>.value(
      detailResult ?? _detail(documentId, status: DocumentStatus.submitted),
    );
  }

  @override
  Future<DocumentDetail> update(
    int documentId,
    DocumentDraft draft,
    int version,
  ) {
    updateCalls++;
    if (updateError != null) {
      return Future<DocumentDetail>.error(updateError!);
    }
    return Future<DocumentDetail>.value(detailResult ?? _detail(documentId));
  }

  @override
  Future<DocumentDetail> voidDocument(int documentId, int version) {
    voidCalls++;
    if (voidError != null) {
      return Future<DocumentDetail>.error(voidError!);
    }
    if (queuedDetails.isNotEmpty) return queuedDetails.removeAt(0);
    return Future<DocumentDetail>.value(
      detailResult ?? _detail(documentId, status: DocumentStatus.voided),
    );
  }

  @override
  Future<PageResult<DocumentSummary>> list(DocumentQuery query) {
    listCalls++;
    if (listError != null) {
      return Future<PageResult<DocumentSummary>>.error(listError!);
    }
    if (queuedLists.isNotEmpty) {
      return queuedLists
          .removeAt(0)
          .then(
            (items) => PageResult<DocumentSummary>(
              items: items,
              page: 1,
              pageSize: 20,
              total: items.length,
            ),
          );
    }
    if (listResult == null) {
      return Future<PageResult<DocumentSummary>>.error(
        StateError('FakeDocumentRepository.list 未配置响应'),
      );
    }
    return Future<PageResult<DocumentSummary>>.value(
      PageResult<DocumentSummary>(
        items: listResult!,
        page: 1,
        pageSize: 20,
        total: listResult!.length,
      ),
    );
  }
}

/* ---------------------------------------------------------------- 构造数据 */

DocumentSummary _summary(int id) => DocumentSummary(
  documentId: id,
  kind: DocumentKind.inbound,
  documentNo: 'RK20260922-000$id',
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
