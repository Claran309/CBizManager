import 'package:c_biz_docs_manager/core/database/app_database.dart';
import 'package:c_biz_docs_manager/core/error/app_failure.dart';
import 'package:c_biz_docs_manager/core/network/api_envelope.dart';
import 'package:c_biz_docs_manager/core/network/error_mapper.dart';
import 'package:c_biz_docs_manager/features/dictionaries/domain/dictionary_entry.dart';
import 'package:dio/dio.dart';

abstract interface class DictionaryRepository {
  Future<List<DictionaryEntry>> list(DictionaryQuery query);
  Future<DictionaryEntry> create(DictionaryDraft draft);
  Future<DictionaryEntry> update(int id, DictionaryDraft draft, int version);
  Future<DictionaryEntry> changeStatus(
    int id,
    DictionaryStatus status,
    int version,
  );
}

abstract interface class DictionaryRemoteDataSource
    implements DictionaryRepository {}

final class DefaultDictionaryRepository implements DictionaryRepository {
  DefaultDictionaryRepository({
    required this.remote,
    this.database,
    required this.userId,
    required this.groupId,
    required this.cacheEnabled,
  }) : assert(!cacheEnabled || database != null);

  final DictionaryRemoteDataSource remote;
  final AppDatabase? database;
  final int userId;
  final int groupId;
  final bool cacheEnabled;

  @override
  Future<List<DictionaryEntry>> list(DictionaryQuery query) async {
    final canCache = cacheEnabled && _isCanonicalKindQuery(query);
    try {
      final entries = await remote.list(query);
      if (canCache) {
        await database!.replaceCachedDictionaryEntries(
          userId: userId,
          groupId: groupId,
          kind: query.kind!.wireValue,
          entries: <CachedDictionaryWrite>[
            for (final entry in entries)
              CachedDictionaryWrite(
                dictionaryId: entry.id,
                name: entry.name,
                parentId: entry.parentId,
                contact: entry.contactPhone,
                status: entry.status.wireValue,
                version: entry.version,
              ),
          ],
        );
      }
      return entries;
    } on NetworkFailure {
      if (!cacheEnabled) rethrow;
      return _readCached(query);
    }
  }

  Future<List<DictionaryEntry>> _readCached(DictionaryQuery query) async {
    final kinds = query.kind == null
        ? DictionaryKind.values
        : <DictionaryKind>[query.kind!];
    final entries = <DictionaryEntry>[];
    for (final kind in kinds) {
      final rows = await database!.listCachedDictionaryEntries(
        userId: userId,
        groupId: groupId,
        kind: kind.wireValue,
      );
      entries.addAll(<DictionaryEntry>[
        for (final row in rows)
          DictionaryEntry(
            id: row.dictionaryId,
            groupId: row.groupId,
            kind: DictionaryKind.fromWireValue(row.kind),
            name: row.name,
            parentId: row.parentId,
            contactPhone: row.contact,
            status: DictionaryStatus.fromWireValue(row.status),
            version: row.version,
          ),
      ]);
    }
    return entries.where((entry) => _matchesQuery(entry, query)).toList();
  }

  bool _isCanonicalKindQuery(DictionaryQuery query) =>
      query.kind != null &&
      query.parentId == null &&
      query.status == null &&
      (query.keyword == null || query.keyword!.isEmpty);

  @override
  Future<DictionaryEntry> create(DictionaryDraft draft) => remote.create(draft);

  @override
  Future<DictionaryEntry> update(int id, DictionaryDraft draft, int version) =>
      remote.update(id, draft, version);

  @override
  Future<DictionaryEntry> changeStatus(
    int id,
    DictionaryStatus status,
    int version,
  ) => remote.changeStatus(id, status, version);
}

final class DioDictionaryRemoteDataSource
    implements DictionaryRemoteDataSource {
  DioDictionaryRemoteDataSource(this._dio);

  final Dio _dio;
  static const _path = '/api/v1/dictionaries';
  static const _pageSize = 100;

  @override
  Future<List<DictionaryEntry>> list(DictionaryQuery query) => _guard(() async {
    final entries = <DictionaryEntry>[];
    var page = 1;
    while (true) {
      final response = await _dio.get<Object?>(
        _path,
        queryParameters: <String, Object?>{
          if (query.kind != null) 'kind': query.kind!.wireValue,
          if (query.parentId != null) 'parent_id': query.parentId,
          if (query.status != null) 'status': query.status!.wireValue,
          if (query.keyword != null && query.keyword!.isNotEmpty)
            'keyword': query.keyword,
          'page': page,
          'page_size': _pageSize,
        },
      );
      final data = _readData(response.data);
      final items = data['items'];
      if (items is! List) {
        throw const FormatException('Dictionary items are required');
      }
      entries.addAll(<DictionaryEntry>[
        for (final item in items)
          DictionaryEntry.fromJson(Map<String, Object?>.from(item as Map)),
      ]);
      final total = _readPaginationTotal(data);
      if (items.isEmpty || page * _pageSize >= total) break;
      page++;
    }
    return entries;
  });

  @override
  Future<DictionaryEntry> create(DictionaryDraft draft) => _guard(() async {
    final response = await _dio.post<Object?>(
      _path,
      data: <String, Object?>{
        'kind': draft.kind.wireValue,
        ..._mutableDraftJson(draft),
      },
    );
    return DictionaryEntry.fromJson(_readData(response.data));
  });

  @override
  Future<DictionaryEntry> update(int id, DictionaryDraft draft, int version) =>
      _guard(() async {
        final data = _mutableDraftJson(draft)..['version'] = version;
        final response = await _dio.put<Object?>('$_path/$id', data: data);
        return DictionaryEntry.fromJson(_readData(response.data));
      });

  @override
  Future<DictionaryEntry> changeStatus(
    int id,
    DictionaryStatus status,
    int version,
  ) => _guard(() async {
    final response = await _dio.patch<Object?>(
      '$_path/$id/status',
      data: <String, Object?>{'status': status.wireValue, 'version': version},
    );
    return DictionaryEntry.fromJson(_readData(response.data));
  });

  Map<String, Object?> _mutableDraftJson(DictionaryDraft draft) =>
      <String, Object?>{
        'name': draft.name,
        'parent_id': draft.parentId,
        'contact_phone': draft.contactPhone,
      };
}

Future<T> _guard<T>(Future<T> Function() operation) async {
  try {
    return await operation();
  } on DioException catch (error) {
    throw mapDioFailure(error);
  } on FormatException {
    throw const ServerFailure('Invalid server response');
  } on TypeError {
    throw const ServerFailure('Invalid server response');
  }
}

int _readPaginationTotal(Map<String, Object?> data) {
  final pagination = data['pagination'];
  if (pagination is! Map) {
    throw const FormatException('Pagination is required');
  }
  final total = pagination['total'];
  if (total is! int || total < 0) {
    throw const FormatException('Pagination total is invalid');
  }
  return total;
}

bool _matchesQuery(DictionaryEntry entry, DictionaryQuery query) {
  final keyword = query.keyword?.trim().toLowerCase();
  return (query.kind == null || entry.kind == query.kind) &&
      (query.parentId == null || entry.parentId == query.parentId) &&
      (query.status == null || entry.status == query.status) &&
      (keyword == null ||
          keyword.isEmpty ||
          entry.name.toLowerCase().contains(keyword));
}

Map<String, Object?> _readData(Object? raw) {
  if (raw is! Map) {
    throw const FormatException('API response must be an object');
  }
  final envelope = ApiEnvelope<Map<String, Object?>>.fromJson(
    Map<String, Object?>.from(raw),
    (value) => Map<String, Object?>.from(value as Map),
  );
  final data = envelope.data;
  if (data == null) {
    throw const FormatException('API response data is required');
  }
  return data;
}
