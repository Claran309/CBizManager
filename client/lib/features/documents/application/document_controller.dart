import 'package:c_biz_docs_manager/core/error/app_failure.dart';
import 'package:c_biz_docs_manager/features/documents/data/document_repository.dart';
import 'package:c_biz_docs_manager/features/documents/domain/document.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 单据列表 / 详情 / 写操作的控制器装配点，按 [DocumentKind] 分片。
///
/// 入库单与出库单是两个独立的页面与状态，用一个 family 按 kind 隔离；
/// kind 是编译期就确定的两个枚举值，family 的缓存键稳定，不会重复建实例。
///
/// `dependencies` 声明两个方向各自的仓储装配点：Riverpod 3 的传递式作用域
/// 据此把本 Controller 挂到「覆盖了这两个仓储的那个容器」（认证会话作用域），
/// 换账号时整体重建，上一个人的单据列表不会漏给下一个会话。
final documentControllerProvider =
    NotifierProvider.family<DocumentController, DocumentState, DocumentKind>(
      DocumentController.new,
      dependencies: [
        inboundDocumentRepositoryProvider,
        outboundDocumentRepositoryProvider,
      ],
    );

/// 单据列表 / 详情页的状态。
final class DocumentState {
  const DocumentState({
    this.items = const <DocumentSummary>[],
    this.detail,
    this.isLoading = false,
    this.isLoadingDetail = false,
    this.isWriting = false,
    this.failure,
  });

  /// 当前筛选条件下的单据列表。
  final List<DocumentSummary> items;

  /// 当前打开的单据详情；没进详情页时为 null。
  final DocumentDetail? detail;

  final bool isLoading;
  final bool isLoadingDetail;
  final bool isWriting;
  final AppFailure? failure;

  DocumentState copyWith({
    List<DocumentSummary>? items,
    DocumentDetail? detail,
    bool? isLoading,
    bool? isLoadingDetail,
    bool? isWriting,
    AppFailure? failure,
    bool clearDetail = false,
    bool clearFailure = false,
  }) {
    return DocumentState(
      items: items ?? this.items,
      detail: clearDetail ? null : detail ?? this.detail,
      isLoading: isLoading ?? this.isLoading,
      isLoadingDetail: isLoadingDetail ?? this.isLoadingDetail,
      isWriting: isWriting ?? this.isWriting,
      failure: clearFailure ? null : failure ?? this.failure,
    );
  }
}

/// 单据列表 / 详情 / 写操作的状态持有者。
///
/// 时序沿用项目里成员 / 邀请码 Controller 已验证的三件套：
/// `_loadGeneration`（乱序丢弃）、`_writeTail`（写操作串行）、`_disposed`（销毁后不写）。
final class DocumentController extends Notifier<DocumentState> {
  DocumentController(this.kind);

  /// 本控制器代理的单据方向（由 family 注入）。
  final DocumentKind kind;

  var _loadGeneration = 0;
  Future<void> _writeTail = Future<void>.value();
  var _disposed = false;

  /// 当前筛选条件，供 [refresh] 与冲突后的重读复用。
  var _query = const DocumentQuery();

  DocumentRepository get _repository => kind == DocumentKind.outbound
      ? ref.read(outboundDocumentRepositoryProvider)
      : ref.read(inboundDocumentRepositoryProvider);

  bool _isCurrent(int generation) =>
      !_disposed && generation == _loadGeneration;

  @override
  DocumentState build() {
    ref.onDispose(() {
      _disposed = true;
      // 让在途的 load 结果立刻作废。
      _loadGeneration++;
    });
    return const DocumentState();
  }

  /// 按 [query] 加载单据列表。
  Future<void> load([DocumentQuery query = const DocumentQuery()]) async {
    final generation = ++_loadGeneration;
    if (_disposed) return;
    // 立刻记住条件：即使这次请求还没回来，refresh 也应该按新条件刷。
    _query = query;
    state = state.copyWith(isLoading: true, clearFailure: true);
    try {
      final page = await _repository.list(query);
      if (_isCurrent(generation)) {
        state = state.copyWith(items: page.items, clearFailure: true);
      }
    } on AppFailure catch (failure) {
      if (_isCurrent(generation)) {
        state = state.copyWith(failure: failure);
      }
    } finally {
      if (_isCurrent(generation)) {
        state = state.copyWith(isLoading: false);
      }
    }
  }

  /// 用当前筛选条件重新加载。
  Future<void> refresh() => load(_query);

  /// 加载某个单据的详情。
  Future<void> loadDetail(int documentId) async {
    if (_disposed) return;
    // 先清掉上一份详情：用户点开 B 单时，屏幕上若还留着 A 单的字段，
    // 他会以为那就是 B 的内容。
    state = state.copyWith(
      isLoadingDetail: true,
      clearDetail: true,
      clearFailure: true,
    );
    try {
      final detail = await _repository.get(documentId);
      if (_disposed) return;
      state = state.copyWith(detail: detail, clearFailure: true);
    } on AppFailure catch (failure) {
      if (_disposed) return;
      state = state.copyWith(failure: failure);
    } finally {
      if (!_disposed) {
        state = state.copyWith(isLoadingDetail: false);
      }
    }
  }

  /// 创建单据。成功后把服务端返回的详情放进 state（页面据此导航到详情页），
  /// 并重读列表让新单出现在第一行。
  Future<void> create(DocumentDraft draft) {
    final repository = _repository;
    return _enqueueWrite(() async {
      if (_disposed) return;
      state = state.copyWith(isWriting: true, clearFailure: true);
      try {
        final detail = await repository.create(draft);
        if (_disposed) return;
        state = state.copyWith(detail: detail, clearFailure: true);
        // 列表行与详情是不同类型（Summary vs Detail），无法原地替换那一条，
        // 重读列表是最省心的一致化方式。
        await load(_query);
      } on AppFailure catch (failure) {
        if (_disposed) return;
        state = state.copyWith(failure: failure);
      } finally {
        if (!_disposed) {
          state = state.copyWith(isWriting: false);
        }
      }
    });
  }

  /// 整体替换单据内容。
  Future<void> update(int documentId, DocumentDraft draft, int version) {
    final repository = _repository;
    return _enqueueWrite(() async {
      if (_disposed) return;
      state = state.copyWith(isWriting: true, clearFailure: true);
      try {
        final detail = await repository.update(documentId, draft, version);
        if (_disposed) return;
        state = state.copyWith(detail: detail, clearFailure: true);
        await load(_query);
      } on ConflictFailure catch (failure) {
        if (_disposed) return;
        await _reloadAfterConflict(failure);
      } on AppFailure catch (failure) {
        if (_disposed) return;
        state = state.copyWith(failure: failure);
      } finally {
        if (!_disposed) {
          state = state.copyWith(isWriting: false);
        }
      }
    });
  }

  /// 提交单据。
  Future<void> submit(int documentId, int version) {
    final repository = _repository;
    return _enqueueWrite(() async {
      if (_disposed) return;
      state = state.copyWith(isWriting: true, clearFailure: true);
      try {
        final detail = await repository.submit(documentId, version);
        if (_disposed) return;
        state = state.copyWith(detail: detail, clearFailure: true);
        await load(_query);
      } on ConflictFailure catch (failure) {
        if (_disposed) return;
        await _reloadAfterConflict(failure);
      } on AppFailure catch (failure) {
        if (_disposed) return;
        state = state.copyWith(failure: failure);
      } finally {
        if (!_disposed) {
          state = state.copyWith(isWriting: false);
        }
      }
    });
  }

  /// 作废单据。
  Future<void> voidDocument(int documentId, int version) {
    final repository = _repository;
    return _enqueueWrite(() async {
      if (_disposed) return;
      state = state.copyWith(isWriting: true, clearFailure: true);
      try {
        final detail = await repository.voidDocument(documentId, version);
        if (_disposed) return;
        state = state.copyWith(detail: detail, clearFailure: true);
        await load(_query);
      } on ConflictFailure catch (failure) {
        if (_disposed) return;
        await _reloadAfterConflict(failure);
      } on AppFailure catch (failure) {
        if (_disposed) return;
        state = state.copyWith(failure: failure);
      } finally {
        if (!_disposed) {
          state = state.copyWith(isWriting: false);
        }
      }
    });
  }

  /// 409 之后重读列表，让用户基于最新数据重新决定。
  ///
  /// **顺序不能反**：`load` 内部会 `clearFailure`，所以必须先重读、再把冲突原因
  /// 放回去，否则刷新会把提示顺手擦掉。另外「刷新不等于成功」，这条提示要一直
  /// 留到用户下一次成功操作之前。
  Future<void> _reloadAfterConflict(ConflictFailure conflict) async {
    await load(_query);
    if (_disposed) return;
    // 重读本身也失败（比如断网）时保留那个更新的失败。
    if (state.failure == null) {
      state = state.copyWith(failure: conflict);
    }
  }

  Future<void> _enqueueWrite(Future<void> Function() operation) {
    final result = _writeTail.then((_) => operation());
    _writeTail = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }
}
