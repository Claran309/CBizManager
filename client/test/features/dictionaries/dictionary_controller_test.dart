import 'dart:async';

import 'package:c_biz_docs_manager/core/error/app_failure.dart';
import 'package:c_biz_docs_manager/features/dictionaries/application/dictionary_controller.dart';
import 'package:c_biz_docs_manager/features/dictionaries/domain/dictionary_entry.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
// `Override` 在 Riverpod 3 里由 misc.dart 导出，主入口只给常用的那一组。
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

import '../../support/dictionary_fixtures.dart';
import '../../support/fake_dictionary_repository.dart';

void main() {
  late FakeDictionaryRepository repository;

  setUp(() => repository = FakeDictionaryRepository());

  ({ProviderContainer container, DictionaryController controller})
  setUpContainer() {
    final container = ProviderContainer(
      overrides: <Override>[
        dictionaryRepositoryProvider.overrideWithValue(repository),
      ],
    );
    addTearDown(container.dispose);
    return (
      container: container,
      controller: container.read(dictionaryControllerProvider.notifier),
    );
  }

  DictionaryState stateOf(ProviderContainer container) =>
      container.read(dictionaryControllerProvider);

  const customerQuery = DictionaryQuery(kind: DictionaryKind.customer);

  /* ---------------------------------------------------------------- 加载 */

  test('controller loads entries and exposes write failure', () async {
    repository.entries = const <DictionaryEntry>[controllerDictionaryEntry];
    final (:ProviderContainer container, :DictionaryController controller) =
        setUpContainer();

    await controller.load(customerQuery);
    expect(stateOf(container).items, hasLength(1));
    // 「启用中」就是用 null 表达（服务端无 status 参数时收敛为 active）。
    expect(repository.queries.single.status, isNull);

    repository.writeError = const NetworkFailure('offline');
    await controller.changeStatus(5, DictionaryStatus.disabled, 1);
    expect(stateOf(container).failure, isA<NetworkFailure>());
  });

  test(
    'newer dictionary query cannot be overwritten by an older response',
    () async {
      final first = Completer<List<DictionaryEntry>>();
      final second = Completer<List<DictionaryEntry>>();
      repository.queuedLists.addAll(<Future<List<DictionaryEntry>>>[
        first.future,
        second.future,
      ]);
      final (:ProviderContainer container, :DictionaryController controller) =
          setUpContainer();

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

      expect(stateOf(container).items, const <DictionaryEntry>[
        newerDictionaryEntry,
      ]);
    },
  );

  test(
    'dictionary writes are serialized and keep writing state accurate',
    () async {
      final first = Completer<DictionaryEntry>();
      final second = Completer<DictionaryEntry>();
      repository
        ..entries = const <DictionaryEntry>[controllerDictionaryEntry]
        ..queuedStatusWrites.addAll(<Completer<DictionaryEntry>>[
          first,
          second,
        ]);
      final (:ProviderContainer container, :DictionaryController controller) =
          setUpContainer();
      await controller.load(customerQuery);

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
      expect(stateOf(container).isWriting, isTrue);

      second.complete(controllerDictionaryEntry);
      await secondWrite;

      final state = stateOf(container);
      expect(state.isWriting, isFalse);
      expect(state.items, const <DictionaryEntry>[controllerDictionaryEntry]);
    },
  );

  /* ------------------------------------------------------------ 状态口径 */

  test('status 为 null 等于只看启用中：停用后条目从列表里摘掉', () async {
    repository.entries = const <DictionaryEntry>[controllerDictionaryEntry];
    final (:ProviderContainer container, :DictionaryController controller) =
        setUpContainer();
    await controller.load(customerQuery);

    await controller.changeStatus(5, DictionaryStatus.disabled, 1);

    // 服务端的 null status 只会返回启用中的条目，本地合并必须跟同一套口径 ——
    // 否则刚停用的一条会继续留在「启用中」的列表里，看起来像筛选没生效。
    expect(stateOf(container).items, isEmpty);
  });

  test('显式筛已停用时，重新启用的条目会被摘掉', () async {
    repository.entries = const <DictionaryEntry>[disabledDictionaryEntry];
    final (:ProviderContainer container, :DictionaryController controller) =
        setUpContainer();
    await controller.load(
      const DictionaryQuery(
        kind: DictionaryKind.customer,
        status: DictionaryStatus.disabled,
      ),
    );

    await controller.changeStatus(5, DictionaryStatus.active, 2);

    expect(stateOf(container).items, isEmpty);
    // 显式筛选不是 canonical query，不该被本地「启用中」的默认口径吃掉。
    expect(repository.statusWrites.single.status, DictionaryStatus.active);
  });

  /* ---------------------------------------------------------------- 冲突 */

  test('撞版本冲突时重读列表并保留冲突提示', () async {
    repository.entries = const <DictionaryEntry>[controllerDictionaryEntry];
    final (:ProviderContainer container, :DictionaryController controller) =
        setUpContainer();
    await controller.load(customerQuery);
    repository.writeError = const ConflictFailure('版本过期');

    await controller.changeStatus(5, DictionaryStatus.disabled, 1);

    // 初始一次 + 冲突后重读一次。
    expect(repository.queries, hasLength(2));
    // 「刷新不等于成功」：数据确实变了，只是没变成用户要的样子，
    // 提示必须留到用户重新做决定之后（load 内部会 clearFailure，顺序不能反）。
    expect(stateOf(container).failure, isA<ConflictFailure>());
    expect(stateOf(container).isWriting, isFalse);
  });

  test('冲突后重读本身也失败时，保留那个更新的失败', () async {
    repository.entries = const <DictionaryEntry>[controllerDictionaryEntry];
    final (:ProviderContainer container, :DictionaryController controller) =
        setUpContainer();
    await controller.load(customerQuery);
    repository
      ..nextListError = const NetworkFailure('offline')
      ..writeError = const ConflictFailure('版本过期');

    await controller.changeStatus(5, DictionaryStatus.disabled, 1);

    // 「连不上」比「版本过期」更紧迫：用户先得能连上，才谈得上重新决定。
    expect(stateOf(container).failure, isA<NetworkFailure>());
  });

  /* ---------------------------------------------------------------- 创建 */

  test('创建成功的条目追加在列表末尾', () async {
    repository
      ..entries = const <DictionaryEntry>[controllerDictionaryEntry]
      ..writeResult = buildDictionaryEntry(
        id: 9,
        name: 'Customer B',
        contactPhone: '13800000000',
      );
    final (:ProviderContainer container, :DictionaryController controller) =
        setUpContainer();
    await controller.load(customerQuery);

    await controller.create(
      const DictionaryDraft(
        kind: DictionaryKind.customer,
        name: 'Customer B',
        contactPhone: '13800000000',
      ),
    );

    final items = stateOf(container).items;
    expect(items, hasLength(2));
    expect(items.last.id, 9);
    expect(items.first.id, 5);
  });

  /* ------------------------------------------------------------ 父级候选 */

  test('父级候选只保留启用中的品名', () async {
    repository.byKind[DictionaryKind.productName] = const <DictionaryEntry>[
      newerDictionaryEntry,
      disabledProductNameDictionaryEntry,
    ];
    final (:ProviderContainer container, :DictionaryController controller) =
        setUpContainer();

    await controller.loadParentOptions();

    // 型号必须挂在启用中的品名下，把已停用的品名摆进下拉只会让用户选中一个
    // 必然被 DICTIONARY_PARENT_INVALID 拒绝的父级。
    expect(stateOf(container).parentOptions, const <DictionaryEntry>[
      newerDictionaryEntry,
    ]);
    expect(stateOf(container).isLoadingParents, isFalse);
    // 候选走的是「同组启用中的品名」，也就是 canonical query（无额外筛选），
    // 会顺带把品名写进本地兜底缓存，断网填单时品名候选有据可依。
    expect(repository.queries.single.kind, DictionaryKind.productName);
    expect(repository.queries.single.status, isNull);
  });

  test('父级候选每次都重新拉，不会因为「已经拿到」就跳过', () async {
    repository.byKind[DictionaryKind.productName] = const <DictionaryEntry>[
      newerDictionaryEntry,
    ];
    final (:ProviderContainer container, :DictionaryController controller) =
        setUpContainer();

    await controller.loadParentOptions();
    await controller.loadParentOptions();

    // 用户在别处新建了一条品名之后，下拉里必须能看到它 ——
    // 「已经拿到就跳过」会让型号永远挂不到刚建的品名下。
    expect(repository.queries, hasLength(2));
  });

  test('父级候选拉取失败如实上报，重试能恢复', () async {
    repository
      ..byKind[DictionaryKind.productName] = const <DictionaryEntry>[
        newerDictionaryEntry,
      ]
      ..listError = const NetworkFailure('offline');
    final (:ProviderContainer container, :DictionaryController controller) =
        setUpContainer();

    await controller.loadParentOptions();
    expect(stateOf(container).failure, isA<NetworkFailure>());
    expect(stateOf(container).parentOptions, isEmpty);

    repository.listError = null;
    await controller.loadParentOptions();

    expect(stateOf(container).parentOptions, hasLength(1));
    expect(stateOf(container).failure, isNull);
  });
}
