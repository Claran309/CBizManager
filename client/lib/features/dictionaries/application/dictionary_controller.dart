import 'package:c_biz_docs_manager/core/error/app_failure.dart';
import 'package:c_biz_docs_manager/features/dictionaries/data/dictionary_repository.dart';
import 'package:c_biz_docs_manager/features/dictionaries/domain/dictionary_entry.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Bootstrap or a future authenticated scope must provide the concrete
/// repository after the active user and group are known.
final dictionaryRepositoryProvider = Provider<DictionaryRepository>((Ref ref) {
  throw StateError('DictionaryRepository has not been configured');
});

final dictionaryControllerProvider =
    NotifierProvider<DictionaryController, DictionaryState>(
      DictionaryController.new,
      // 同 MemberController：显式声明依赖，让 Riverpod 的传递式作用域把本
      // Controller 挂到覆盖了仓储的那个会话作用域里，而不是挂在根容器
      // 被所有账号共享（那会导致换组后还能看到上一个组的字典）。
      dependencies: [dictionaryRepositoryProvider],
    );

final class DictionaryState {
  const DictionaryState({
    this.items = const <DictionaryEntry>[],
    this.parentOptions = const <DictionaryEntry>[],
    this.isLoading = false,
    this.isLoadingParents = false,
    this.isWriting = false,
    this.failure,
  });

  final List<DictionaryEntry> items;

  /// 可以当作「型号」父级的品名候选（同组、启用中的 `product_name`）。
  ///
  /// 与 [items] 分开：它服务的是**编辑器的父级下拉**与「型号」筛选的父级下拉，
  /// 与当前正在看的那一页条目无关。混进 items 会让主列表凭空多出一批品名。
  final List<DictionaryEntry> parentOptions;

  final bool isLoading;
  final bool isLoadingParents;
  final bool isWriting;
  final AppFailure? failure;

  DictionaryState copyWith({
    List<DictionaryEntry>? items,
    List<DictionaryEntry>? parentOptions,
    bool? isLoading,
    bool? isLoadingParents,
    bool? isWriting,
    AppFailure? failure,
    bool clearFailure = false,
  }) {
    return DictionaryState(
      items: items ?? this.items,
      parentOptions: parentOptions ?? this.parentOptions,
      isLoading: isLoading ?? this.isLoading,
      isLoadingParents: isLoadingParents ?? this.isLoadingParents,
      isWriting: isWriting ?? this.isWriting,
      failure: clearFailure ? null : failure ?? this.failure,
    );
  }
}

/// Owns dictionary screen state and retains the latest query for refreshes.
final class DictionaryController extends Notifier<DictionaryState> {
  DictionaryQuery? _query;
  var _loadGeneration = 0;
  Future<void> _writeTail = Future<void>.value();

  /// 会话作用域是否已销毁。
  ///
  /// 理由与 MemberController 一致：切账号瞬间可能有请求在途，
  /// 让它把上一个组的字典写进新会话的界面，比抛个错还糟糕。
  var _disposed = false;

  DictionaryRepository get _repository =>
      ref.read(dictionaryRepositoryProvider);

  /// 在途结果是否还允许写回状态。
  bool _isCurrent(int generation) =>
      !_disposed && generation == _loadGeneration;

  @override
  DictionaryState build() {
    ref.onDispose(() {
      _disposed = true;
      _loadGeneration++;
    });
    return const DictionaryState();
  }

  Future<void> load(DictionaryQuery query) async {
    final generation = ++_loadGeneration;
    if (_disposed) return;
    _query = query;
    state = state.copyWith(isLoading: true, clearFailure: true);
    try {
      final items = await _repository.list(query);
      if (_isCurrent(generation)) {
        state = state.copyWith(items: items, clearFailure: true);
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

  Future<void> refresh() async {
    final query = _query;
    if (query != null) await load(query);
  }

  /// 读取「可作为型号父级」的品名候选。
  ///
  /// **刻意不做「已经拿到就跳过」的缓存**：用户在别处新建了一条品名之后，
  /// 这里必须能重新拉到它，否则新建型号时下拉里找不到刚建好的品名。
  /// 调用点只有两个（切到「型号」筛选、打开型号 editor），频率很低，
  /// 每次重拉一个请求的代价远小于「看不到刚建的数据」。
  ///
  /// 走的就是普通 list 查询，所以这条请求也会顺带把品名写进本地兜底缓存
  /// （无额外筛选 = canonical query），断网填单的品名候选因此有据可依。
  Future<void> loadParentOptions() async {
    if (_disposed) return;
    state = state.copyWith(isLoadingParents: true, clearFailure: true);
    try {
      final options = await _repository.list(
        const DictionaryQuery(kind: DictionaryKind.productName),
      );
      if (_disposed) return;
      state = state.copyWith(
        // 服务端的 null status 已经只会返回启用中的条目，这里再过滤一次是**防御性**的：
        // 万一将来服务端口径变了，宁可下拉里少一个选项，也不要让用户选中一个
        // 必然被 DICTIONARY_PARENT_INVALID 拒绝的父级。
        parentOptions: <DictionaryEntry>[
          for (final option in options)
            if (option.status == DictionaryStatus.active) option,
        ],
        clearFailure: true,
      );
    } on AppFailure catch (failure) {
      if (_disposed) return;
      state = state.copyWith(failure: failure);
    } finally {
      if (!_disposed) {
        state = state.copyWith(isLoadingParents: false);
      }
    }
  }

  Future<void> create(DictionaryDraft draft) async {
    // 先取好仓储：写操作是排队的，真正执行时作用域可能已经销毁，
    // 那时再碰 ref 会抛错。下同。
    final repository = _repository;
    await _enqueueWrite(
      () => _write(() => repository.create(draft), append: true),
    );
  }

  Future<void> update(int id, DictionaryDraft draft, int version) async {
    final repository = _repository;
    await _enqueueWrite(
      () => _write(() => repository.update(id, draft, version)),
    );
  }

  Future<void> changeStatus(
    int id,
    DictionaryStatus status,
    int version,
  ) async {
    final repository = _repository;
    await _enqueueWrite(
      () => _write(() => repository.changeStatus(id, status, version)),
    );
  }

  Future<void> _enqueueWrite(Future<void> Function() operation) {
    final result = _writeTail.then((_) => operation());
    _writeTail = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  Future<void> _write(
    Future<DictionaryEntry> Function() operation, {
    bool append = false,
  }) async {
    if (_disposed) return;
    state = state.copyWith(isWriting: true, clearFailure: true);
    try {
      final updated = await operation();
      if (_disposed) return;
      state = state.copyWith(
        items: _merge(updated, append: append),
        clearFailure: true,
      );
    } on ConflictFailure catch (failure) {
      if (_disposed) return;
      // 冲突说明本地这一份（含 version）已经不成立了，必须把最新数据读回来再让用户决定。
      // **顺序不能反**：refresh 内部会 clearFailure，所以先 await 重读、再把冲突原因放回去 ——
      // 「刷新不等于成功」：数据确实变了，只是没变成用户要的样子，
      // 提示要一直留到用户下一次成功操作之前。
      await refresh();
      if (_disposed) return;
      // 重读本身也失败（例如断网）时保留那个更新的失败：「连不上」比「版本过期」更紧迫。
      if (state.failure == null) {
        state = state.copyWith(failure: failure);
      }
    } on AppFailure catch (failure) {
      if (_disposed) return;
      state = state.copyWith(failure: failure);
    } finally {
      if (!_disposed) {
        state = state.copyWith(isWriting: false);
      }
    }
  }

  /// 把写结果合回当前列表：匹配当前筛选就替换/追加，不匹配就从列表里摘掉。
  ///
  /// 两个方向都必须做，少一个都会让界面与筛选口径打架：
  /// - **不匹配要摘掉**：用户正在看「启用中」的列表，把一条刚停用的条目留在里面
  ///   （还挂着「已停用」标签）会让他以为筛选没生效。
  /// - **匹配但不在列表里要补回去**：连续两次写（例如「停用」之后又「启用」）时，
  ///   第一次已经把条目摘掉了，第二次的写结果必须能重新出现 —— 只做替换的话
  ///   列表会凭空少一条，而服务端下一次全量查询一定会把它带回来，
  ///   界面就会与「刷新一下又有了」这种灵异现象撞车。
  List<DictionaryEntry> _merge(
    DictionaryEntry updated, {
    required bool append,
  }) {
    final query = _query;
    if (query != null && !_matches(updated, query)) {
      return <DictionaryEntry>[
        for (final item in state.items)
          if (item.id != updated.id) item,
      ];
    }
    if (append) {
      return <DictionaryEntry>[...state.items, updated];
    }
    return _upsertDictionaryEntry(state.items, updated);
  }
}

bool _matches(DictionaryEntry entry, DictionaryQuery query) {
  final keyword = query.keyword?.trim().toLowerCase();
  return (query.kind == null || entry.kind == query.kind) &&
      (query.parentId == null || entry.parentId == query.parentId) &&
      // `query.status == null` 在服务端等于「只看启用中」（详见 DictionaryQuery.status），
      // 本地判断必须跟同一套口径：否则刚被停用的条目会继续留在「启用中」的列表里。
      entry.status == (query.status ?? DictionaryStatus.active) &&
      (keyword == null ||
          keyword.isEmpty ||
          entry.name.toLowerCase().contains(keyword));
}

/// 用 [updated] 顶掉列表里同 id 的那一条；列表里没有就补在末尾。
///
/// 补的时候追加在末尾而不是插回原位：服务端的排序依据（名称 / 创建时间）
/// 客户端并不知道，与其猜一个可能错的位置，不如如实表达「它现在可见了」。
List<DictionaryEntry> _upsertDictionaryEntry(
  List<DictionaryEntry> items,
  DictionaryEntry updated,
) {
  var replaced = false;
  final result = <DictionaryEntry>[];
  for (final item in items) {
    if (item.id == updated.id) {
      result.add(updated);
      replaced = true;
    } else {
      result.add(item);
    }
  }
  if (!replaced) {
    result.add(updated);
  }
  return result;
}
