import 'package:c_biz_docs_manager/core/database/app_database.dart';
import 'package:c_biz_docs_manager/core/error/app_failure.dart';
import 'package:c_biz_docs_manager/core/network/api_envelope.dart';
import 'package:c_biz_docs_manager/core/network/error_mapper.dart';
import 'package:c_biz_docs_manager/features/members/domain/member.dart';
import 'package:dio/dio.dart';

abstract interface class MemberRepository {
  /// 按 [query] 查询成员。
  ///
  /// 不用分页参数：组员规模是「一个业务组的业务员」，一次拉完（数据源内部翻页）
  /// 比让用户在一片搜索结果里翻页更符合实际用法。
  Future<List<Member>> listMembers(MemberQuery query);

  /// 后端认可的固定权限目录。
  Future<List<PermissionCatalogItem>> getPermissionCatalog();

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
  Future<List<Member>> listMembers(MemberQuery query) async {
    try {
      final members = await remote.listMembers(query);
      // 只有**不带筛选**的结果才配写进缓存：它是权威全量。
      // 带 keyword/status 的响应只是一个子集（甚至可能是空集），
      // 覆盖写会让下一次「全部成员」查询从缓存里读出一条残缺的名单 ——
      // 而缓存恰恰是断网时唯一的兜底，它一旦残缺就再没有任何东西能纠正。
      if (cacheEnabled && query.isUnfiltered) {
        await _writeCachedMembers(members);
      }
      return members;
    } on NetworkFailure {
      // 带筛选时**不回退缓存**：缓存里存的是全量，
      // 把它当作「筛选结果」交给页面，用户会看到一堆不匹配的成员，
      // 还以为筛选生效了 —— 这比直接报「需要联网」更糟。
      if (!cacheEnabled || !query.isUnfiltered) rethrow;
      return _readCachedMembers();
    }
  }

  Future<void> _writeCachedMembers(List<Member> members) async {
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

  @override
  Future<List<PermissionCatalogItem>> getPermissionCatalog() =>
      // 目录是后端固化的常量表，断网时没有可信的本地副本可退 —— 也不该有：
      // 缓存一份权限清单，等于在客户端留下第二份「后端认可哪些权限」的真相。
      remote.getPermissionCatalog();

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
          // 本地缓存表只存展示所需字段，没有账号 ID；
          // 用 0 表示「这一份来自缓存，不知道账号 ID」。
          //
          // 界面上「这是不是我本人」的判断因此对缓存数据一律不成立 ——
          // 宁可少禁用一次按钮（服务端还会再拒一次），
          // 也不要凭猜测把某一行标成「你自己」。
          userId: 0,
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
  static const _catalogPath = '/api/v1/groups/permission-catalog';
  static const _pageSize = 100;

  @override
  Future<List<Member>> listMembers(MemberQuery query) => _guard(() async {
    final members = <Member>[];
    var page = 1;
    while (true) {
      final response = await _dio.get<Object?>(
        _path,
        queryParameters: <String, Object?>{
          ...query.toQueryParameters(),
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
      // 每页都要带上同样的筛选条件 —— 漏了的话第二页会突然「变宽」，
      // 用户看到的是「筛选结果里混进了不该出现的人」。
      if (items.isEmpty || page * _pageSize >= total) break;
      page++;
    }
    return members;
  });

  @override
  Future<List<PermissionCatalogItem>> getPermissionCatalog() =>
      _guard(() async {
        final response = await _dio.get<Object?>(_catalogPath);
        final data = _readData(response.data);
        final items = data['items'];
        if (items is! List) {
          throw const FormatException('Permission catalog items are required');
        }
        return <PermissionCatalogItem>[
          for (final item in items)
            PermissionCatalogItem.fromJson(
              Map<String, Object?>.from(item as Map),
            ),
        ];
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
