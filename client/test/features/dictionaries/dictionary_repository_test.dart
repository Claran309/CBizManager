import 'package:c_biz_docs_manager/core/database/app_database.dart';
import 'package:c_biz_docs_manager/core/error/app_failure.dart';
import 'package:c_biz_docs_manager/features/dictionaries/data/dictionary_repository.dart';
import 'package:c_biz_docs_manager/features/dictionaries/domain/dictionary_entry.dart';
import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

final class RecordingDictionaryAdapter implements HttpClientAdapter {
  RecordingDictionaryAdapter({this.malformed = false});

  final bool malformed;
  final List<RequestOptions> requests = <RequestOptions>[];

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final page = options.queryParameters['page'] as int? ?? 1;
    final responseData = options.method == 'GET'
        ? malformed
              ? '{}'
              : '''{"items":[{"id":$page,"group_id":10,"kind":"customer","name":"Customer $page","parent_id":null,"contact_phone":null,"status":"active","version":1}],"pagination":{"page":$page,"page_size":100,"total":101}}'''
        : '''{"id":5,"group_id":10,"kind":"customer","name":"Customer B","parent_id":null,"contact_phone":"456","status":"active","version":2}''';
    return ResponseBody.fromString(
      '''{"code":"OK","message":"success","data":$responseData,"request_id":"request-1"}''',
      200,
      headers: <String, List<String>>{
        Headers.contentTypeHeader: <String>[Headers.jsonContentType],
      },
    );
  }
}

final class FakeDictionaryRemote implements DictionaryRemoteDataSource {
  Object? listError;
  Object? writeError;
  List<DictionaryEntry> entries = const <DictionaryEntry>[];

  @override
  Future<DictionaryEntry> changeStatus(
    int id,
    DictionaryStatus status,
    int version,
  ) async {
    final error = writeError;
    if (error != null) throw error;
    return entries.single;
  }

  @override
  Future<DictionaryEntry> create(DictionaryDraft draft) async {
    final error = writeError;
    if (error != null) throw error;
    return entries.single;
  }

  @override
  Future<List<DictionaryEntry>> list(DictionaryQuery query) async {
    final error = listError;
    if (error != null) throw error;
    return entries;
  }

  @override
  Future<DictionaryEntry> update(
    int id,
    DictionaryDraft draft,
    int version,
  ) async {
    final error = writeError;
    if (error != null) throw error;
    return entries.single;
  }
}

const dictionaryEntry = DictionaryEntry(
  id: 5,
  groupId: 10,
  kind: DictionaryKind.customer,
  name: 'Customer A',
  contactPhone: '123',
  status: DictionaryStatus.active,
  version: 1,
);

void main() {
  late AppDatabase database;
  late FakeDictionaryRemote remote;
  const query = DictionaryQuery(kind: DictionaryKind.customer);

  setUp(() {
    database = AppDatabase.forTesting(NativeDatabase.memory());
    remote = FakeDictionaryRemote()
      ..entries = const <DictionaryEntry>[dictionaryEntry];
  });
  tearDown(() => database.close());

  test(
    'native dictionary query caches and only network errors fall back',
    () async {
      final repository = DefaultDictionaryRepository(
        remote: remote,
        database: database,
        userId: 1,
        groupId: 10,
        cacheEnabled: true,
      );
      expect(await repository.list(query), const <DictionaryEntry>[
        dictionaryEntry,
      ]);
      remote.listError = const NetworkFailure('offline');
      expect(await repository.list(query), const <DictionaryEntry>[
        dictionaryEntry,
      ]);
      remote.listError = const ConflictFailure('bad query');
      await expectLater(
        repository.list(query),
        throwsA(isA<ConflictFailure>()),
      );
    },
  );

  test('web dictionary query never reads native cache', () async {
    final native = DefaultDictionaryRepository(
      remote: remote,
      database: database,
      userId: 1,
      groupId: 10,
      cacheEnabled: true,
    );
    await native.list(query);
    remote.listError = const NetworkFailure('offline');
    final web = DefaultDictionaryRepository(
      remote: remote,
      userId: 1,
      groupId: 10,
      cacheEnabled: false,
    );
    await expectLater(web.list(query), throwsA(isA<NetworkFailure>()));
  });

  test('filtered queries fall back to the matching full-kind cache', () async {
    final repository = DefaultDictionaryRepository(
      remote: remote,
      database: database,
      userId: 1,
      groupId: 10,
      cacheEnabled: true,
    );
    await repository.list(query);
    remote.listError = const NetworkFailure('offline');

    final entries = await repository.list(
      const DictionaryQuery(
        kind: DictionaryKind.customer,
        status: DictionaryStatus.active,
        keyword: 'customer a',
      ),
    );

    expect(entries, const <DictionaryEntry>[dictionaryEntry]);
  });

  test('dictionary cache never crosses user or group scope', () async {
    final ownerScope = DefaultDictionaryRepository(
      remote: remote,
      database: database,
      userId: 1,
      groupId: 10,
      cacheEnabled: true,
    );
    await ownerScope.list(query);
    remote.listError = const NetworkFailure('offline');
    final otherScope = DefaultDictionaryRepository(
      remote: remote,
      database: database,
      userId: 2,
      groupId: 20,
      cacheEnabled: true,
    );

    expect(await otherScope.list(query), isEmpty);
  });

  test('offline dictionary writes fail and never enter the outbox', () async {
    final repository = DefaultDictionaryRepository(
      remote: remote,
      database: database,
      userId: 1,
      groupId: 10,
      cacheEnabled: true,
    );
    remote.writeError = const NetworkFailure('offline');
    const draft = DictionaryDraft(
      kind: DictionaryKind.customer,
      name: 'Customer B',
    );

    await expectLater(repository.create(draft), throwsA(isA<NetworkFailure>()));
    await expectLater(
      repository.update(5, draft, 1),
      throwsA(isA<NetworkFailure>()),
    );
    await expectLater(
      repository.changeStatus(5, DictionaryStatus.disabled, 1),
      throwsA(isA<NetworkFailure>()),
    );
    expect(
      await database.listOutboxOperations(userId: 1, groupId: 10),
      isEmpty,
    );
  });

  test('update request omits immutable dictionary kind', () async {
    final adapter = RecordingDictionaryAdapter();
    final dio = Dio(BaseOptions(baseUrl: 'https://api.example.test'))
      ..httpClientAdapter = adapter;
    final remote = DioDictionaryRemoteDataSource(dio);

    await remote.update(
      5,
      const DictionaryDraft(
        kind: DictionaryKind.customer,
        name: 'Customer B',
        contactPhone: '456',
      ),
      1,
    );

    expect(adapter.requests.single.data, <String, Object?>{
      'name': 'Customer B',
      'parent_id': null,
      'contact_phone': '456',
      'version': 1,
    });
  });

  test('remote dictionary list follows pagination until complete', () async {
    final adapter = RecordingDictionaryAdapter();
    final dio = Dio(BaseOptions(baseUrl: 'https://api.example.test'))
      ..httpClientAdapter = adapter;

    final entries = await DioDictionaryRemoteDataSource(
      dio,
    ).list(const DictionaryQuery(kind: DictionaryKind.customer));

    expect(entries.map((entry) => entry.id), <int>[1, 2]);
    expect(adapter.requests, hasLength(2));
  });

  test(
    'malformed successful dictionary response becomes a server failure',
    () async {
      final dio = Dio(BaseOptions(baseUrl: 'https://api.example.test'))
        ..httpClientAdapter = RecordingDictionaryAdapter(malformed: true);

      await expectLater(
        DioDictionaryRemoteDataSource(
          dio,
        ).list(const DictionaryQuery(kind: DictionaryKind.customer)),
        throwsA(isA<ServerFailure>()),
      );
    },
  );
}
