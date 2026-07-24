import 'package:c_biz_docs_manager/core/database/app_database.dart';
import 'package:c_biz_docs_manager/core/error/app_failure.dart';
import 'package:c_biz_docs_manager/core/network/api_envelope.dart';
import 'package:c_biz_docs_manager/core/network/error_mapper.dart';
import 'package:c_biz_docs_manager/features/members/domain/member.dart';
import 'package:dio/dio.dart';

abstract interface class MemberRepository {
  Future<List<Member>> listMembers();

  Future<Member> changeStatus(
    int membershipId,
    MemberStatus status,
    int version,
  );

  Future<MemberPermissions> getPermissions(int membershipId);

  Future<MemberPermissions> replacePermissions(
    int membershipId,
    Set<String> codes,
    int version,
  );
}

abstract interface class MemberRemoteDataSource implements MemberRepository {}

final class DefaultMemberRepository implements MemberRepository {
  DefaultMemberRepository({
    required this.remote,
    this.database,
    required this.userId,
    required this.groupId,
    required this.cacheEnabled,
  }) : assert(!cacheEnabled || database != null);

  final MemberRemoteDataSource remote;
  final AppDatabase? database;
  final int userId;
  final int groupId;
  final bool cacheEnabled;

  @override
  Future<List<Member>> listMembers() async {
    try {
      final members = await remote.listMembers();
      if (cacheEnabled) {
        final db = database!;
        await db.replaceCachedMembers(
          userId: userId,
          groupId: groupId,
          entries: <CachedMemberWrite>[
            for (final member in members)
              CachedMemberWrite(
                membershipId: member.membershipId,
                username: member.username,
                displayName: member.displayName,
                memberType: member.memberType,
                status: member.status.wireValue,
                version: member.version,
              ),
          ],
        );
        for (final member in members) {
          await db.replaceCachedMemberPermissions(
            userId: userId,
            groupId: groupId,
            membershipId: member.membershipId,
            permissionCodes: member.permissionCodes,
            version: member.version,
          );
        }
      }
      return members;
    } on NetworkFailure {
      if (!cacheEnabled) rethrow;
      return _readCachedMembers();
    }
  }

  Future<List<Member>> _readCachedMembers() async {
    final db = database!;
    final rows = await db.listCachedMembers(userId: userId, groupId: groupId);
    final result = <Member>[];
    for (final row in rows) {
      final permissions = await db.getCachedMemberPermissions(
        userId: userId,
        groupId: groupId,
        membershipId: row.membershipId,
      );
      result.add(
        Member(
          membershipId: row.membershipId,
          username: row.username,
          displayName: row.displayName,
          memberType: row.memberType,
          status: MemberStatus.fromWireValue(row.status),
          permissionCodes: permissions?.permissionCodes ?? <String>{},
          version: row.version,
        ),
      );
    }
    return result;
  }

  @override
  Future<Member> changeStatus(
    int membershipId,
    MemberStatus status,
    int version,
  ) => remote.changeStatus(membershipId, status, version);

  @override
  Future<MemberPermissions> getPermissions(int membershipId) async {
    try {
      final permissions = await remote.getPermissions(membershipId);
      if (cacheEnabled) {
        await database!.replaceCachedMemberPermissions(
          userId: userId,
          groupId: groupId,
          membershipId: membershipId,
          permissionCodes: permissions.permissionCodes,
          version: permissions.version,
        );
      }
      return permissions;
    } on NetworkFailure {
      if (!cacheEnabled) rethrow;
      final cached = await database!.getCachedMemberPermissions(
        userId: userId,
        groupId: groupId,
        membershipId: membershipId,
      );
      if (cached == null) rethrow;
      return MemberPermissions(
        membershipId: membershipId,
        permissionCodes: cached.permissionCodes,
        version: cached.version,
      );
    }
  }

  @override
  Future<MemberPermissions> replacePermissions(
    int membershipId,
    Set<String> codes,
    int version,
  ) => remote.replacePermissions(membershipId, codes, version);
}

final class DioMemberRemoteDataSource implements MemberRemoteDataSource {
  DioMemberRemoteDataSource(this._dio);

  final Dio _dio;
  static const _path = '/api/v1/groups/members';
  static const _pageSize = 100;

  @override
  Future<List<Member>> listMembers() => _guard(() async {
    final members = <Member>[];
    var page = 1;
    while (true) {
      final response = await _dio.get<Object?>(
        _path,
        queryParameters: <String, Object?>{
          'page': page,
          'page_size': _pageSize,
        },
      );
      final data = _readData(response.data);
      final items = data['items'];
      if (items is! List) {
        throw const FormatException('Member items are required');
      }
      members.addAll(<Member>[
        for (final item in items)
          Member.fromJson(Map<String, Object?>.from(item as Map)),
      ]);
      final total = _readPaginationTotal(data);
      if (items.isEmpty || page * _pageSize >= total) break;
      page++;
    }
    return members;
  });

  @override
  Future<Member> changeStatus(
    int membershipId,
    MemberStatus status,
    int version,
  ) => _guard(() async {
    final response = await _dio.patch<Object?>(
      '$_path/$membershipId/status',
      data: <String, Object?>{'status': status.wireValue, 'version': version},
    );
    return Member.fromJson(_readData(response.data));
  });

  @override
  Future<MemberPermissions> getPermissions(int membershipId) =>
      _guard(() async {
        final response = await _dio.get<Object?>(
          '$_path/$membershipId/permissions',
        );
        return MemberPermissions.fromJson(_readData(response.data));
      });

  @override
  Future<MemberPermissions> replacePermissions(
    int membershipId,
    Set<String> codes,
    int version,
  ) => _guard(() async {
    final sortedCodes = codes.toList()..sort();
    final response = await _dio.put<Object?>(
      '$_path/$membershipId/permissions',
      data: <String, Object?>{
        'permission_codes': sortedCodes,
        'version': version,
      },
    );
    return MemberPermissions.fromJson(_readData(response.data));
  });
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
