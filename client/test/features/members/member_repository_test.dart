import 'dart:convert';

import 'package:c_biz_docs_manager/core/database/app_database.dart';
import 'package:c_biz_docs_manager/core/error/app_failure.dart';
import 'package:c_biz_docs_manager/features/members/data/member_repository.dart';
import 'package:c_biz_docs_manager/features/members/domain/member.dart';
import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

/// 按路径分发的假适配器：成员列表按页应答，权限目录单条应答。
///
/// 分页 fixed 成「两台车」的样子（total = 101、每页 100），是为了让
/// 「数据源自己翻页直到拉完」这条行为有可断言的证据。
final class MemberResponseAdapter implements HttpClientAdapter {
  MemberResponseAdapter({this.malformed = false});

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
    final Object? data;
    if (options.path.endsWith('/permission-catalog')) {
      data = malformed
          ? <String, Object?>{}
          : <String, Object?>{
              'items': <Object?>[
                <String, Object?>{
                  'code': 'member.manage',
                  'name': '成员管理',
                  'description': '可以新增、停用成员',
                },
              ],
            };
    } else {
      final page = options.queryParameters['page'] as int? ?? 1;
      data = malformed
          ? <String, Object?>{}
          : <String, Object?>{
              'items': <Object?>[
                <String, Object?>{
                  'membership_id': page,
                  'user': <String, Object?>{
                    'id': 100 + page,
                    'username': 'user-$page',
                    'display_name': 'User $page',
                  },
                  'member_type': 'member',
                  'status': 'active',
                  'permission_codes': <Object?>[],
                  'version': 1,
                },
              ],
              'pagination': <String, Object?>{
                'page': page,
                'page_size': 100,
                'total': 101,
              },
            };
    }
    return ResponseBody.fromString(
      jsonEncode(<String, Object?>{
        'code': 'OK',
        'message': 'success',
        'data': data,
        'request_id': 'request-1',
      }),
      200,
      headers: <String, List<String>>{
        Headers.contentTypeHeader: <String>[Headers.jsonContentType],
      },
    );
  }
}

final class FakeMemberRemote implements MemberRemoteDataSource {
  Object? listError;
  Object? writeError;
  Object? catalogError;
  List<Member> members = const <Member>[];
  List<PermissionCatalogItem> catalog = const <PermissionCatalogItem>[];

  /// 记录每次查询带的条件，用来断言「点的筛选确实传下去了」。
  final List<MemberQuery> queries = <MemberQuery>[];

  @override
  Future<Member> changeStatus(
    int membershipId,
    MemberStatus status,
    int version,
  ) async {
    final error = writeError;
    if (error != null) throw error;
    return members.single;
  }

  @override
  Future<List<PermissionCatalogItem>> getPermissionCatalog() async {
    final error = catalogError;
    if (error != null) throw error;
    return catalog;
  }

  @override
  Future<MemberPermissions> getPermissions(int membershipId) async {
    final error = listError;
    if (error != null) throw error;
    return MemberPermissions(
      membershipId: membershipId,
      permissionCodes: members.single.permissionCodes,
      version: members.single.version,
    );
  }

  @override
  Future<List<Member>> listMembers(MemberQuery query) async {
    queries.add(query);
    final error = listError;
    if (error != null) throw error;
    return members;
  }

  @override
  Future<MemberPermissions> replacePermissions(
    int membershipId,
    Set<String> codes,
    int version,
  ) async {
    final error = writeError;
    if (error != null) throw error;
    return MemberPermissions(
      membershipId: membershipId,
      permissionCodes: codes,
      version: version + 1,
    );
  }
}

const cachedMember = Member(
  membershipId: 7,
  userId: 101,
  username: 'alice',
  displayName: 'Alice',
  memberType: 'member',
  status: MemberStatus.active,
  permissionCodes: <String>{'member.manage'},
  version: 1,
);

/// 第二个人：用来验证「筛选结果不能覆盖全量缓存」。
const filteredMember = Member(
  membershipId: 8,
  userId: 102,
  username: 'bob',
  displayName: 'Bob',
  memberType: 'member',
  status: MemberStatus.disabled,
  permissionCodes: <String>{},
  version: 1,
);

/// 从本地缓存读回来的那一份。
///
/// 缓存表只存展示所需的字段，**没有账号 ID**，所以 `userId` 是 0。
/// 这是刻意的：界面判断「这一行是不是我自己」宁可判不出来（少禁用一次按钮，
/// 服务端还会再拒一次），也不能凭猜把某一行标成「你自己」。
const cachedMemberFromCache = Member(
  membershipId: 7,
  userId: 0,
  username: 'alice',
  displayName: 'Alice',
  memberType: 'member',
  status: MemberStatus.active,
  permissionCodes: <String>{'member.manage'},
  version: 1,
);

void main() {
  late AppDatabase database;
  late FakeMemberRemote remote;

  setUp(() {
    database = AppDatabase.forTesting(NativeDatabase.memory());
    remote = FakeMemberRemote()..members = const <Member>[cachedMember];
  });
  tearDown(() => database.close());

  DefaultMemberRepository nativeRepository() => DefaultMemberRepository(
    remote: remote,
    database: database,
    userId: 1,
    groupId: 10,
    cacheEnabled: true,
  );

  group('缓存与降级', () {
    test(
      'native online result replaces cache and network failure falls back',
      () async {
        final repository = nativeRepository();

        expect(
          await repository.listMembers(const MemberQuery()),
          const <Member>[cachedMember],
        );
        remote.listError = const NetworkFailure('offline');
        expect(
          await repository.listMembers(const MemberQuery()),
          const <Member>[cachedMemberFromCache],
        );
      },
    );

    test('business error is not disguised as cached data', () async {
      final repository = nativeRepository();
      await repository.listMembers(const MemberQuery());
      remote.listError = const ConflictFailure('stale');

      await expectLater(
        repository.listMembers(const MemberQuery()),
        throwsA(isA<ConflictFailure>()),
      );
    });

    test('web query never falls back to Drift cache', () async {
      await nativeRepository().listMembers(const MemberQuery());
      remote.listError = const NetworkFailure('offline');
      final web = DefaultMemberRepository(
        remote: remote,
        userId: 1,
        groupId: 10,
        cacheEnabled: false,
      );

      await expectLater(
        web.listMembers(const MemberQuery()),
        throwsA(isA<NetworkFailure>()),
      );
    });

    test('member cache never crosses user or group scope', () async {
      await nativeRepository().listMembers(const MemberQuery());
      remote.listError = const NetworkFailure('offline');
      final otherScope = DefaultMemberRepository(
        remote: remote,
        database: database,
        userId: 2,
        groupId: 20,
        cacheEnabled: true,
      );

      expect(await otherScope.listMembers(const MemberQuery()), isEmpty);
    });

    test('带筛选的在线结果不覆盖全量缓存', () async {
      final repository = nativeRepository();
      // 先存下一份权威全量。
      await repository.listMembers(const MemberQuery());

      // 服务端在筛选条件下只返回可能更窄的一份，它不该成为新的「全量」。
      remote.members = const <Member>[filteredMember];
      expect(
        await repository.listMembers(const MemberQuery(keyword: 'bob')),
        const <Member>[filteredMember],
      );

      // 断网后再拉全量：读回来的必须是最初那份（缓存里没有账号 ID，
      // 所以 userId 退化成 0），而不是被筛选结果顶掉的名单。
      remote.listError = const NetworkFailure('offline');
      expect(await repository.listMembers(const MemberQuery()), const <Member>[
        cachedMemberFromCache,
      ]);
    });

    test('带筛选时断网不回退缓存，因为缓存是全量而不是筛选结果', () async {
      final repository = nativeRepository();
      await repository.listMembers(const MemberQuery());
      remote.listError = const NetworkFailure('offline');

      // 把全量缓存当作「关键词 alice 的搜索结果」返回给页面，
      // 用户会看到一堆不匹配的人，还以为筛选生效了 —— 宁可明确报需要联网。
      await expectLater(
        repository.listMembers(const MemberQuery(keyword: 'alice')),
        throwsA(isA<NetworkFailure>()),
      );
      await expectLater(
        repository.listMembers(
          const MemberQuery(status: MemberStatus.disabled),
        ),
        throwsA(isA<NetworkFailure>()),
      );
    });

    test('空白关键词等同于不筛选，仍然走缓存写回与降级', () async {
      final repository = nativeRepository();
      await repository.listMembers(const MemberQuery(keyword: '   '));

      remote.listError = const NetworkFailure('offline');
      expect(
        await repository.listMembers(const MemberQuery(keyword: '   ')),
        const <Member>[cachedMemberFromCache],
      );
    });

    test(
      'offline member writes fail without creating outbox operations',
      () async {
        final repository = nativeRepository();
        remote.writeError = const NetworkFailure('offline');

        await expectLater(
          repository.changeStatus(7, MemberStatus.disabled, 1),
          throwsA(isA<NetworkFailure>()),
        );
        await expectLater(
          repository.replacePermissions(7, const <String>{}, 1),
          throwsA(isA<NetworkFailure>()),
        );
        expect(
          await database.listOutboxOperations(userId: 1, groupId: 10),
          isEmpty,
        );
      },
    );
  });

  group('远端数据源', () {
    Dio dioWith(MemberResponseAdapter adapter) =>
        Dio(BaseOptions(baseUrl: 'https://api.example.test'))
          ..httpClientAdapter = adapter;

    test('筛选条件在每一页请求里都带着', () async {
      final adapter = MemberResponseAdapter();

      final members = await DioMemberRemoteDataSource(dioWith(adapter))
          .listMembers(
            const MemberQuery(
              keyword: ' alice ',
              status: MemberStatus.disabled,
            ),
          );

      // 两页都拉到了（total=101、page_size=100）。
      expect(members.map((member) => member.membershipId), <int>[1, 2]);
      expect(adapter.requests, hasLength(2));
      for (final request in adapter.requests) {
        // 关键词已去掉首尾空白：`' alice '` 原样发出去，服务端的模糊匹配
        // 会因为那个空格而搜不到人。
        expect(request.queryParameters['keyword'], 'alice');
        expect(request.queryParameters['status'], 'disabled');
      }
    });

    test('不筛选时请求里不出现 keyword 与 status', () async {
      final adapter = MemberResponseAdapter();
      await DioMemberRemoteDataSource(
        dioWith(adapter),
      ).listMembers(const MemberQuery());

      // 显式传 status=null 会被序列化成空串 → 服务端按非法枚举 400，
      // 于是「不筛状态」反而失败。
      expect(
        adapter.requests.first.queryParameters.containsKey('keyword'),
        isFalse,
      );
      expect(
        adapter.requests.first.queryParameters.containsKey('status'),
        isFalse,
      );
    });

    test(
      'remote member list follows pagination until every item is loaded',
      () async {
        final adapter = MemberResponseAdapter();

        final members = await DioMemberRemoteDataSource(
          dioWith(adapter),
        ).listMembers(const MemberQuery());

        expect(members.map((member) => member.membershipId), <int>[1, 2]);
        // 账号 ID 必须解析出来：界面判断「这是不是我本人」只能靠它。
        expect(members.map((member) => member.userId), <int>[101, 102]);
        expect(adapter.requests, hasLength(2));
      },
    );

    test(
      'malformed successful member response becomes a server failure',
      () async {
        final dio = dioWith(MemberResponseAdapter(malformed: true));

        await expectLater(
          DioMemberRemoteDataSource(dio).listMembers(const MemberQuery()),
          throwsA(isA<ServerFailure>()),
        );
      },
    );

    test('权限目录按契约解析，且打进目录地址', () async {
      final adapter = MemberResponseAdapter();

      final catalog = await DioMemberRemoteDataSource(
        dioWith(adapter),
      ).getPermissionCatalog();

      expect(adapter.requests.single.path, '/api/v1/groups/permission-catalog');
      expect(catalog, hasLength(1));
      expect(catalog.single.code, 'member.manage');
      expect(catalog.single.name, '成员管理');
      expect(catalog.single.description, '可以新增、停用成员');
    });

    test('目录结构不合法时收敛成 ServerFailure 而不是空目录', () async {
      final dio = dioWith(MemberResponseAdapter(malformed: true));

      // 返回空目录比报错更危险：权限页会渲染出「一个权限都没有」的复选框列表，
      // 用户以为这个组根本没有可分配的权限。
      await expectLater(
        DioMemberRemoteDataSource(dio).getPermissionCatalog(),
        throwsA(isA<ServerFailure>()),
      );
    });
  });

  group('权限目录的缓存策略', () {
    test('目录不写本地缓存，也不在断网时回退', () async {
      remote.catalog = const <PermissionCatalogItem>[
        PermissionCatalogItem(
          code: 'member.manage',
          name: '成员管理',
          description: 'x',
        ),
      ];
      final repository = nativeRepository();

      expect(await repository.getPermissionCatalog(), hasLength(1));
      remote.catalogError = const NetworkFailure('offline');
      await expectLater(
        repository.getPermissionCatalog(),
        throwsA(isA<NetworkFailure>()),
      );
    });
  });
}
