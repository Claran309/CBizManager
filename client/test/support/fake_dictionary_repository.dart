import 'dart:async';

import 'package:c_biz_docs_manager/features/dictionaries/data/dictionary_repository.dart';
import 'package:c_biz_docs_manager/features/dictionaries/domain/dictionary_entry.dart';

/// 可编程的字典仓储假实现。
///
/// 每个方法支持三种行为，按优先级：**排队响应**（把未完成的 `Completer` 放进去，
/// 用来制造「在途」时序）→ **注入错误** → **按 kind 的固定结果 / 默认结果**。
/// 调用参数全被记录，方便断言「界面上点的确实是这一条、带的是这个 version」。
///
/// [byKind] 不是多余的：字典页会**同时**发两路 list —— 主列表（当前筛选的 kind）
/// 与「型号」的父级候选（`product_name`）。只有一个 `entries` 兜底的话，
/// 两路会拿到同一批数据，主列表就会凭空出现一堆品名。
///
/// **写方法必须返回「变更后」的实体**，这不是细节而是契约的一部分：
/// 服务端的 create / update / changeStatus 都返回修改后的那一条，
/// 控制器正是靠它把新状态合回本地列表。假实现如果原样返回旧条目，
/// 「停用后条目从筛选里消失」这类断言测的就是一个假前提 —— 会红得莫名其妙，
/// 修的方向也会被带偏。
final class FakeDictionaryRepository implements DictionaryRepository {
  /// 未在 [byKind] 里指定的 kind 的兜底结果。
  List<DictionaryEntry> entries = const <DictionaryEntry>[];

  /// 按 kind 指定的固定结果。
  final Map<DictionaryKind, List<DictionaryEntry>> byKind =
      <DictionaryKind, List<DictionaryEntry>>{};

  /// 新造条目（create）用的 groupId；契约里 `DictionaryDraft` 不带分组。
  int defaultGroupId = 10;

  /* ---------------------------------------------------------------- 列表 */

  final List<DictionaryQuery> queries = <DictionaryQuery>[];
  final List<Future<List<DictionaryEntry>>> queuedLists =
      <Future<List<DictionaryEntry>>>[];
  Object? listError;

  /// 只让**下一次**查询失败（一次性）。
  ///
  /// 用它而不是往 [queuedLists] 里塞一个 `Future.error`：后者在测试体里被创建时
  /// 还没有任何监听者，Dart 会把它当作未处理的异步错误报给测试框架，
  /// 用例就会红在一个跟被测逻辑完全无关的地方。这里是在方法**被调用时**才构造
  /// 失败的 Future，调用方紧接着 await，不存在裸露窗口。
  Object? nextListError;

  @override
  Future<List<DictionaryEntry>> list(DictionaryQuery query) {
    queries.add(query);
    final nextError = nextListError;
    if (nextError != null) {
      nextListError = null;
      return Future<List<DictionaryEntry>>.error(nextError);
    }
    if (queuedLists.isNotEmpty) return queuedLists.removeAt(0);
    final error = listError;
    if (error != null) return Future<List<DictionaryEntry>>.error(error);
    final kind = query.kind;
    if (kind != null && byKind.containsKey(kind)) {
      return Future<List<DictionaryEntry>>.value(byKind[kind]!);
    }
    return Future<List<DictionaryEntry>>.value(entries);
  }

  /// 某一 kind 最近一次查询用到的条件（找不到返回 null）。
  DictionaryQuery? lastQueryFor(DictionaryKind kind) {
    for (final query in queries.reversed) {
      if (query.kind == kind) return query;
    }
    return null;
  }

  /* ---------------------------------------------------------------- 写操作 */

  /// 三个写方法的共同失败注入点。
  Object? writeError;

  /// 写成功后直接返回的条目；设置后**跳过**默认的「按入参合成实体」行为。
  ///
  /// 只在需要返回一条跟入参无关的固定数据时用它（例如刻意造一个服务端
  /// 规范化后的名称）；验证「返回值确实带上了用户的改动」时别设置它。
  DictionaryEntry? writeResult;

  /// 只让**下一次**写失败（一次性），语义同 [nextListError]。
  Object? nextWriteError;

  final List<DictionaryDraft> createDrafts = <DictionaryDraft>[];
  final List<({int id, DictionaryDraft draft, int version})> updateWrites =
      <({int id, DictionaryDraft draft, int version})>[];
  final List<({int id, DictionaryStatus status, int version})> statusWrites =
      <({int id, DictionaryStatus status, int version})>[];

  /// 让 [changeStatus] 挂住不返回，用来观察「写操作在途」的界面状态。
  final List<Completer<DictionaryEntry>> queuedStatusWrites =
      <Completer<DictionaryEntry>>[];

  /// create 成功时新条目的 id；不设置则取「已有条目的最大 id + 1」。
  int? nextCreatedId;

  int createCalls = 0;
  int updateCalls = 0;
  int statusWriteCalls = 0;

  @override
  Future<DictionaryEntry> create(DictionaryDraft draft) async {
    createCalls++;
    createDrafts.add(draft);
    final error = _takeWriteError();
    if (error != null) throw error;
    final result = writeResult;
    if (result != null) return result;
    return DictionaryEntry(
      id: nextCreatedId ?? _maxId() + 1,
      groupId: defaultGroupId,
      kind: draft.kind,
      name: draft.name,
      parentId: draft.parentId,
      contactPhone: draft.contactPhone,
      status: DictionaryStatus.active,
      version: 1,
    );
  }

  @override
  Future<DictionaryEntry> update(
    int id,
    DictionaryDraft draft,
    int version,
  ) async {
    updateCalls++;
    updateWrites.add((id: id, draft: draft, version: version));
    final error = _takeWriteError();
    if (error != null) throw error;
    final result = writeResult;
    if (result != null) return result;
    final entry = _requireEntry(id, 'update');
    return DictionaryEntry(
      id: entry.id,
      groupId: entry.groupId,
      // kind 不可变：以实体为准，不跟着 draft 走（服务端也拒绝改 kind）。
      kind: entry.kind,
      name: draft.name,
      parentId: draft.parentId,
      contactPhone: draft.contactPhone,
      // 编辑不动状态：启停是 changeStatus 的职责。
      status: entry.status,
      version: version + 1,
    );
  }

  @override
  Future<DictionaryEntry> changeStatus(
    int id,
    DictionaryStatus status,
    int version,
  ) async {
    statusWriteCalls++;
    statusWrites.add((id: id, status: status, version: version));
    if (queuedStatusWrites.isNotEmpty) {
      return queuedStatusWrites.removeAt(0).future;
    }
    final error = _takeWriteError();
    if (error != null) throw error;
    final result = writeResult;
    if (result != null) return result;
    final entry = _requireEntry(id, 'changeStatus');
    return DictionaryEntry(
      id: entry.id,
      groupId: entry.groupId,
      kind: entry.kind,
      name: entry.name,
      parentId: entry.parentId,
      contactPhone: entry.contactPhone,
      status: status,
      version: version + 1,
    );
  }

  /* ---------------------------------------------------------------- 内部 */

  Object? _takeWriteError() {
    final next = nextWriteError;
    if (next != null) {
      nextWriteError = null;
      return next;
    }
    return writeError;
  }

  /// 取 id 对应的条目；找不到直接抛 —— 这是**用例自己写错了**（引用了不存在的数据），
  /// 应该立刻红在一个能看懂的地方，而不是悄悄返回一条不相关的条目把断言带偏。
  DictionaryEntry _requireEntry(int id, String method) {
    final entry = _findEntry(id);
    if (entry == null) {
      throw StateError('FakeDictionaryRepository 里没有 id=$id 的条目（$method）');
    }
    return entry;
  }

  DictionaryEntry? _findEntry(int id) {
    for (final entry in entries) {
      if (entry.id == id) return entry;
    }
    for (final list in byKind.values) {
      for (final entry in list) {
        if (entry.id == id) return entry;
      }
    }
    return null;
  }

  int _maxId() {
    var max = 0;
    void consider(DictionaryEntry entry) {
      if (entry.id > max) max = entry.id;
    }

    for (final entry in entries) {
      consider(entry);
    }
    for (final list in byKind.values) {
      for (final entry in list) {
        consider(entry);
      }
    }
    return max;
  }
}
