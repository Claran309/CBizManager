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
    );

final class DictionaryState {
  const DictionaryState({
    this.items = const <DictionaryEntry>[],
    this.isLoading = false,
    this.isWriting = false,
    this.failure,
  });

  final List<DictionaryEntry> items;
  final bool isLoading;
  final bool isWriting;
  final AppFailure? failure;

  DictionaryState copyWith({
    List<DictionaryEntry>? items,
    bool? isLoading,
    bool? isWriting,
    AppFailure? failure,
    bool clearFailure = false,
  }) {
    return DictionaryState(
      items: items ?? this.items,
      isLoading: isLoading ?? this.isLoading,
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

  DictionaryRepository get _repository =>
      ref.read(dictionaryRepositoryProvider);

  @override
  DictionaryState build() => const DictionaryState();

  Future<void> load(DictionaryQuery query) async {
    final generation = ++_loadGeneration;
    _query = query;
    state = state.copyWith(isLoading: true, clearFailure: true);
    try {
      final items = await _repository.list(query);
      if (generation == _loadGeneration) {
        state = state.copyWith(items: items, clearFailure: true);
      }
    } on AppFailure catch (failure) {
      if (generation == _loadGeneration) {
        state = state.copyWith(failure: failure);
      }
    } finally {
      if (generation == _loadGeneration) {
        state = state.copyWith(isLoading: false);
      }
    }
  }

  Future<void> refresh() async {
    final query = _query;
    if (query != null) await load(query);
  }

  Future<void> create(DictionaryDraft draft) async {
    await _enqueueWrite(
      () => _write(() => _repository.create(draft), append: true),
    );
  }

  Future<void> update(int id, DictionaryDraft draft, int version) async {
    await _enqueueWrite(
      () => _write(() => _repository.update(id, draft, version)),
    );
  }

  Future<void> changeStatus(
    int id,
    DictionaryStatus status,
    int version,
  ) async {
    await _enqueueWrite(
      () => _write(() => _repository.changeStatus(id, status, version)),
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
    state = state.copyWith(isWriting: true, clearFailure: true);
    try {
      final updated = await operation();
      final query = _query;
      var items = state.items;
      if (query == null || _matches(updated, query)) {
        items = append
            ? <DictionaryEntry>[...items, updated]
            : _replaceDictionaryEntry(items, updated);
      } else {
        items = <DictionaryEntry>[
          for (final item in items)
            if (item.id != updated.id) item,
        ];
      }
      state = state.copyWith(items: items, clearFailure: true);
    } on AppFailure catch (failure) {
      state = state.copyWith(failure: failure);
    } finally {
      state = state.copyWith(isWriting: false);
    }
  }
}

bool _matches(DictionaryEntry entry, DictionaryQuery query) {
  final keyword = query.keyword?.trim().toLowerCase();
  return (query.kind == null || entry.kind == query.kind) &&
      (query.parentId == null || entry.parentId == query.parentId) &&
      (query.status == null || entry.status == query.status) &&
      (keyword == null ||
          keyword.isEmpty ||
          entry.name.toLowerCase().contains(keyword));
}

List<DictionaryEntry> _replaceDictionaryEntry(
  List<DictionaryEntry> items,
  DictionaryEntry updated,
) => <DictionaryEntry>[
  for (final item in items)
    if (item.id == updated.id) updated else item,
];
