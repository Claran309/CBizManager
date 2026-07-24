import 'package:c_biz_docs_manager/core/database/app_database.dart';
import 'package:c_biz_docs_manager/core/error/app_failure.dart';
import 'package:c_biz_docs_manager/features/members/data/member_repository.dart';
import 'package:c_biz_docs_manager/features/members/domain/member.dart';
import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

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
    final page = options.queryParameters['page'] as int? ?? 1;
    final data = malformed
        ? '{}'
        : '''{"items":[{"membership_id":$page,"user":{"username":"user-$page","display_name":"User $page"},"member_type":"member","status":"active","permission_codes":[],"version":1}],"pagination":{"page":$page,"page_size":100,"total":101}}''';
    return ResponseBody.fromString(
      '''{"code":"OK","message":"success","data":$data,"request_id":"request-1"}''',
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
  List<Member> members = const <Member>[];

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
  Future<List<Member>> listMembers() async {
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

  test(
    'native online result replaces cache and network failure falls back',
    () async {
      final repository = DefaultMemberRepository(
        remote: remote,
        database: database,
        userId: 1,
        groupId: 10,
        cacheEnabled: true,
      );

      expect(await repository.listMembers(), const <Member>[cachedMember]);
      remote.listError = const NetworkFailure('offline');
      expect(await repository.listMembers(), const <Member>[cachedMember]);
    },
  );

  test('business error is not disguised as cached data', () async {
    final repository = DefaultMemberRepository(
      remote: remote,
      database: database,
      userId: 1,
      groupId: 10,
      cacheEnabled: true,
    );
    await repository.listMembers();
    remote.listError = const ConflictFailure('stale');

    await expectLater(
      repository.listMembers(),
      throwsA(isA<ConflictFailure>()),
    );
  });

  test('web query never falls back to Drift cache', () async {
    final native = DefaultMemberRepository(
      remote: remote,
      database: database,
      userId: 1,
      groupId: 10,
      cacheEnabled: true,
    );
    await native.listMembers();
    remote.listError = const NetworkFailure('offline');
    final web = DefaultMemberRepository(
      remote: remote,
      userId: 1,
      groupId: 10,
      cacheEnabled: false,
    );

    await expectLater(web.listMembers(), throwsA(isA<NetworkFailure>()));
  });

  test('member cache never crosses user or group scope', () async {
    final ownerScope = DefaultMemberRepository(
      remote: remote,
      database: database,
      userId: 1,
      groupId: 10,
      cacheEnabled: true,
    );
    await ownerScope.listMembers();
    remote.listError = const NetworkFailure('offline');
    final otherScope = DefaultMemberRepository(
      remote: remote,
      database: database,
      userId: 2,
      groupId: 20,
      cacheEnabled: true,
    );

    expect(await otherScope.listMembers(), isEmpty);
  });

  test(
    'offline member writes fail without creating outbox operations',
    () async {
      final repository = DefaultMemberRepository(
        remote: remote,
        database: database,
        userId: 1,
        groupId: 10,
        cacheEnabled: true,
      );
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

  test(
    'remote member list follows pagination until every item is loaded',
    () async {
      final adapter = MemberResponseAdapter();
      final dio = Dio(BaseOptions(baseUrl: 'https://api.example.test'))
        ..httpClientAdapter = adapter;

      final members = await DioMemberRemoteDataSource(dio).listMembers();

      expect(members.map((member) => member.membershipId), <int>[1, 2]);
      expect(adapter.requests, hasLength(2));
    },
  );

  test(
    'malformed successful member response becomes a server failure',
    () async {
      final dio = Dio(BaseOptions(baseUrl: 'https://api.example.test'))
        ..httpClientAdapter = MemberResponseAdapter(malformed: true);

      await expectLater(
        DioMemberRemoteDataSource(dio).listMembers(),
        throwsA(isA<ServerFailure>()),
      );
    },
  );
}
