import 'dart:async';

import 'package:c_biz_docs_manager/core/error/app_failure.dart';
import 'package:c_biz_docs_manager/features/dictionaries/application/dictionary_controller.dart';
import 'package:c_biz_docs_manager/features/dictionaries/data/dictionary_repository.dart';
import 'package:c_biz_docs_manager/features/dictionaries/domain/dictionary_entry.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

final class FakeDictionaryRepository implements DictionaryRepository {
  List<DictionaryEntry> entries = const <DictionaryEntry>[];
  List<Future<List<DictionaryEntry>>> listResults =
      <Future<List<DictionaryEntry>>>[];
  List<Completer<DictionaryEntry>> statusWrites =
      <Completer<DictionaryEntry>>[];
  int statusWriteCalls = 0;
  Object? writeError;

  @override
  Future<DictionaryEntry> changeStatus(
    int id,
    DictionaryStatus status,
    int version,
  ) async {
    statusWriteCalls++;
    if (statusWrites.isNotEmpty) {
      return statusWrites.removeAt(0).future;
    }
    final error = writeError;
    if (error != null) throw error;
    return entries.single;
  }

  @override
  Future<DictionaryEntry> create(DictionaryDraft draft) async => entries.single;

  @override
  Future<List<DictionaryEntry>> list(DictionaryQuery query) async {
    if (listResults.isNotEmpty) return listResults.removeAt(0);
    return entries;
  }

  @override
  Future<DictionaryEntry> update(
    int id,
    DictionaryDraft draft,
    int version,
  ) async => entries.single;
}

void main() {
  test('controller loads entries and exposes write failure', () async {
    final repository = FakeDictionaryRepository()
      ..entries = const <DictionaryEntry>[controllerDictionaryEntry];
    final container = ProviderContainer(
      overrides: [dictionaryRepositoryProvider.overrideWithValue(repository)],
    );
    addTearDown(container.dispose);
    final controller = container.read(dictionaryControllerProvider.notifier);

    await controller.load(const DictionaryQuery(kind: DictionaryKind.customer));
    expect(container.read(dictionaryControllerProvider).items, hasLength(1));

    repository.writeError = const NetworkFailure('offline');
    await controller.changeStatus(5, DictionaryStatus.disabled, 1);
    expect(
      container.read(dictionaryControllerProvider).failure,
      isA<NetworkFailure>(),
    );
  });

  test(
    'newer dictionary query cannot be overwritten by an older response',
    () async {
      final first = Completer<List<DictionaryEntry>>();
      final second = Completer<List<DictionaryEntry>>();
      final repository = FakeDictionaryRepository()
        ..listResults = <Future<List<DictionaryEntry>>>[
          first.future,
          second.future,
        ];
      final container = ProviderContainer(
        overrides: [dictionaryRepositoryProvider.overrideWithValue(repository)],
      );
      addTearDown(container.dispose);
      final controller = container.read(dictionaryControllerProvider.notifier);

      final olderLoad = controller.load(
        const DictionaryQuery(kind: DictionaryKind.customer),
      );
      final newerLoad = controller.load(
        const DictionaryQuery(kind: DictionaryKind.productName),
      );
      second.complete(const <DictionaryEntry>[newerDictionaryEntry]);
      await newerLoad;
      first.complete(const <DictionaryEntry>[controllerDictionaryEntry]);
      await olderLoad;

      expect(
        container.read(dictionaryControllerProvider).items,
        const <DictionaryEntry>[newerDictionaryEntry],
      );
    },
  );

  test(
    'dictionary writes are serialized and keep writing state accurate',
    () async {
      final first = Completer<DictionaryEntry>();
      final second = Completer<DictionaryEntry>();
      final repository = FakeDictionaryRepository()
        ..entries = const <DictionaryEntry>[controllerDictionaryEntry]
        ..statusWrites = <Completer<DictionaryEntry>>[first, second];
      final container = ProviderContainer(
        overrides: [dictionaryRepositoryProvider.overrideWithValue(repository)],
      );
      addTearDown(container.dispose);
      final controller = container.read(dictionaryControllerProvider.notifier);
      await controller.load(
        const DictionaryQuery(kind: DictionaryKind.customer),
      );

      final firstWrite = controller.changeStatus(
        5,
        DictionaryStatus.disabled,
        1,
      );
      final secondWrite = controller.changeStatus(
        5,
        DictionaryStatus.active,
        2,
      );
      await Future<void>.delayed(Duration.zero);
      expect(repository.statusWriteCalls, 1);
      first.complete(disabledDictionaryEntry);
      await firstWrite;
      await Future<void>.delayed(Duration.zero);
      expect(repository.statusWriteCalls, 2);
      expect(container.read(dictionaryControllerProvider).isWriting, isTrue);
      second.complete(controllerDictionaryEntry);
      await secondWrite;

      final state = container.read(dictionaryControllerProvider);
      expect(state.isWriting, isFalse);
      expect(state.items, const <DictionaryEntry>[controllerDictionaryEntry]);
    },
  );
}

const controllerDictionaryEntry = DictionaryEntry(
  id: 5,
  groupId: 10,
  kind: DictionaryKind.customer,
  name: 'Customer A',
  status: DictionaryStatus.active,
  version: 1,
);

const disabledDictionaryEntry = DictionaryEntry(
  id: 5,
  groupId: 10,
  kind: DictionaryKind.customer,
  name: 'Customer A',
  status: DictionaryStatus.disabled,
  version: 2,
);

const newerDictionaryEntry = DictionaryEntry(
  id: 6,
  groupId: 10,
  kind: DictionaryKind.productName,
  name: 'Product A',
  status: DictionaryStatus.active,
  version: 1,
);
