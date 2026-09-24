import 'dart:convert';

import 'package:c_biz_docs_manager/core/database/app_database.dart';
import 'package:c_biz_docs_manager/core/error/app_failure.dart';
import 'package:c_biz_docs_manager/core/network/page_result.dart';
import 'package:c_biz_docs_manager/features/platform/data/platform_repository.dart';
import 'package:c_biz_docs_manager/features/platform/domain/platform_group.dart';
import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/platform_fixtures.dart';

/// 一个可以按请求内容决定响应的假适配器。
///
/// 直接挂在 [Dio] 的 `httpClientAdapter` 上，而不是去 mock 仓储：这样被测的是
/// **真实的** Dio 请求拼装（路径、方法、query 参数、body 序列化），
/// 而不是我们自己对 Dio 的假设。
final class RecordingPlatformAdapter implements HttpClientAdapter {
  RecordingPlatformAdapter(this.respond);

  /// 收到一个请求就返回 `(状态码, 响应体)`。
  final (int, String) Function(RequestOptions options) respond;

  /// 按发生顺序记录下来的请求。
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
    final (statusCode, body) = respond(options);
    return ResponseBody.fromString(
      body,
      statusCode,
      headers: <String, List<String>>{
        Headers.contentTypeHeader: <String>[Headers.jsonContentType],
      },
    );
  }
}

/// 成功信封。
String _envelope(Object? data, {String requestId = 'request-1'}) =>
    jsonEncode(<String, Object?>{
      'code': 'OK',
      'message': 'success',
      'data': data,
      'request_id': requestId,
    });

/// 失败信封（契约里的 `ErrorApiResponse`）。
String _errorEnvelope(
  String code,
  String message, {
  String requestId = 'request-1',
}) => jsonEncode(<String, Object?>{
  'code': code,
  'message': message,
  'data': null,
  'request_id': requestId,
});

Dio _dioWith(RecordingPlatformAdapter adapter) =>
    Dio(BaseOptions(baseUrl: 'https://api.example.test'))
      ..httpClientAdapter = adapter;

/// 给定一个应答器，造出被测仓储。
DioPlatformRepository _repositoryWith(
  (int, String) Function(RequestOptions options) respond,
) => DioPlatformRepository(_dioWith(RecordingPlatformAdapter(respond)));

const _createDraft = CreateGroupDraft(
  name: '钢材一组',
  ownerUsername: 'owner',
  ownerDisplayName: '张三',
  ownerTemporaryPassword: 'secret123',
);

void main() {
  test('列表请求带上分页与筛选参数，并按一页解析', () async {
    final adapter = RecordingPlatformAdapter(
      (_) => (200, _envelope(platformGroupPageJson())),
    );
    final repository = DioPlatformRepository(_dioWith(adapter));

    final PageResult<PlatformGroup> page = await repository.listGroups(
      const PlatformGroupQuery(
        keyword: '钢材',
        status: GroupStatus.disabled,
        page: 2,
        pageSize: 50,
      ),
    );

    final request = adapter.requests.single;
    expect(request.method, 'GET');
    expect(request.path, '/api/v1/platform/groups');
    expect(request.queryParameters, <String, Object?>{
      'page': 2,
      'page_size': 50,
      'status': 'disabled',
      'keyword': '钢材',
    });
    // 只取一页：平台组列表靠界面翻页，仓储自作主张把所有页拉全会让
    // 「共 N 组」与「当前页」的语义混在一起，还平白压垮服务端。
    expect(adapter.requests, hasLength(1));
    expect(page.items.single.name, '钢材一组');
    expect(page.items.single.status, GroupStatus.active);
    expect(page.items.single.memberCount, 5);
    expect((page.page, page.pageSize, page.total), (1, 20, 1));
  });

  test('不带筛选时请求里不出现 status 与 keyword', () async {
    final adapter = RecordingPlatformAdapter(
      (_) => (200, _envelope(platformGroupPageJson(items: const <Object?>[]))),
    );

    await DioPlatformRepository(
      _dioWith(adapter),
    ).listGroups(const PlatformGroupQuery());

    // 显式传一个 null 会被序列化成空串，服务端按非法枚举拒绝，
    // 于是「不筛状态」反而报 400 —— 所以这里必须确认键根本不存在。
    expect(adapter.requests.single.queryParameters, <String, Object?>{
      'page': 1,
      'page_size': 20,
    });
  });

  test('详情请求解析成员聚合与候选人', () async {
    final adapter = RecordingPlatformAdapter(
      (_) => (
        200,
        _envelope(
          platformGroupDetailJson(
            ownerCandidates: <Object?>[platformCandidateJson()],
          ),
        ),
      ),
    );

    final detail = await DioPlatformRepository(_dioWith(adapter)).getGroup(7);

    expect(adapter.requests.single.path, '/api/v1/platform/groups/7');
    expect(detail.group.version, 3);
    expect(detail.memberCounts.active, 3);
    expect(detail.ownerCandidates.single.membershipId, 9);
  });

  test('创建组提交四个必填字段并解析精简结果', () async {
    final adapter = RecordingPlatformAdapter(
      (_) => (201, _envelope(platformGroupCreatedJson())),
    );

    final result = await DioPlatformRepository(
      _dioWith(adapter),
    ).createGroup(_createDraft);

    final request = adapter.requests.single;
    expect(request.method, 'POST');
    expect(request.path, '/api/v1/platform/groups');
    expect(request.data, <String, Object?>{
      'name': '钢材一组',
      'owner_username': 'owner',
      'owner_display_name': '张三',
      'owner_temporary_password': 'secret123',
    });
    expect((result.groupId, result.groupName), (7, '钢材一组'));
    expect(result.owner.displayName, '张三');
  });

  test('启停组用 PATCH 提交状态与版本号', () async {
    final adapter = RecordingPlatformAdapter(
      (_) =>
          (200, _envelope(platformGroupJson(status: 'disabled', version: 4))),
    );

    final group = await DioPlatformRepository(
      _dioWith(adapter),
    ).changeStatus(7, GroupStatus.disabled, 3);

    final request = adapter.requests.single;
    expect(request.method, 'PATCH');
    expect(request.path, '/api/v1/platform/groups/7/status');
    expect(request.data, <String, Object?>{'status': 'disabled', 'version': 3});
    // 服务端回显的是**变更后**的摘要，客户端要拿它替换列表里的旧行。
    expect(group.status, GroupStatus.disabled);
    expect(group.version, 4);
  });

  test('交接给既有成员时请求体只有 existing_member 那一组字段', () async {
    final adapter = RecordingPlatformAdapter((options) {
      // 交接实现是「先 PUT、再重读详情」，两个请求的形状不一样，
      // 这里必须分开应答 —— 否则重读那一步会解析失败。
      if (options.method == 'PUT') {
        return (200, _envelope(platformOwnerChangedJson()));
      }
      return (200, _envelope(platformGroupDetailJson()));
    });
    final repository = DioPlatformRepository(_dioWith(adapter));

    await repository.changeOwner(
      7,
      const ExistingMemberOwnerDraft(membershipId: 9, version: 3),
    );

    final put = adapter.requests.first;
    expect(put.method, 'PUT');
    expect(put.path, '/api/v1/platform/groups/7/owner');
    expect(put.data, <String, Object?>{
      'mode': 'existing_member',
      'membership_id': 9,
      'version': 3,
    });
    // 另一种模式的字段一个都不能出现：服务端只认自己那一组，
    // 多带了它要么报 400、要么（更糟）悄悄忽略而让调用方以为生效了。
    final body = put.data! as Map<String, Object?>;
    expect(body.containsKey('username'), isFalse);
    expect(body.containsKey('display_name'), isFalse);
    expect(body.containsKey('temporary_password'), isFalse);
  });

  test('交接给新账号时请求体只有 new_account 那一组字段', () async {
    final adapter = RecordingPlatformAdapter((options) {
      if (options.method == 'PUT') {
        return (200, _envelope(platformOwnerChangedJson()));
      }
      return (200, _envelope(platformGroupDetailJson()));
    });
    final repository = DioPlatformRepository(_dioWith(adapter));

    await repository.changeOwner(
      7,
      const NewAccountOwnerDraft(
        username: 'lisi',
        displayName: '李四',
        temporaryPassword: 'secret123',
        version: 4,
      ),
    );

    final put = adapter.requests.first;
    expect(put.data, <String, Object?>{
      'mode': 'new_account',
      'username': 'lisi',
      'display_name': '李四',
      'temporary_password': 'secret123',
      'version': 4,
    });
    expect(
      (put.data! as Map<String, Object?>).containsKey('membership_id'),
      isFalse,
    );
  });

  test('交接成功后重读详情，返回的字面不是半截的写响应', () async {
    final adapter = RecordingPlatformAdapter((options) {
      if (options.method == 'PUT') {
        return (200, _envelope(platformOwnerChangedJson()));
      }
      return (
        200,
        _envelope(
          platformGroupDetailJson(
            group: platformGroupJson(
              version: 4,
              owner: platformOwnerJson(
                id: 22,
                username: 'sales',
                displayName: '李四',
              ),
            ),
          ),
        ),
      );
    });
    final repository = DioPlatformRepository(_dioWith(adapter));

    final detail = await repository.changeOwner(
      7,
      const ExistingMemberOwnerDraft(membershipId: 9, version: 3),
    );

    expect(
      adapter.requests.map((RequestOptions request) => request.method),
      <String>['PUT', 'GET'],
    );
    expect(adapter.requests.last.path, '/api/v1/platform/groups/7');
    // 写响应里没有 member_counts / owner_candidates，所以必须重读才能得到
    // 一份自洽的详情：主账号已换、被提升的人已从候选人里消失。
    expect(detail.group.version, 4);
    expect(detail.group.owner.displayName, '李四');
    expect(detail.ownerCandidates, isEmpty);
  });

  test('版本冲突映射成 ConflictFailure 并保留服务端文案', () async {
    final repository = _repositoryWith(
      (_) => (
        409,
        _errorEnvelope(
          'RESOURCE_VERSION_CONFLICT',
          '组已被其他请求修改',
          requestId: 'req-409',
        ),
      ),
    );

    await expectLater(
      repository.changeStatus(7, GroupStatus.disabled, 3),
      throwsA(
        isA<ConflictFailure>()
            .having((failure) => failure.message, 'message', '组已被其他请求修改')
            .having((failure) => failure.requestId, 'requestId', 'req-409'),
      ),
    );
  });

  test('组不存在降级为 ServerFailure，但保留文案与 request id', () async {
    final repository = _repositoryWith(
      (_) => (
        404,
        _errorEnvelope('GROUP_NOT_FOUND', '组不存在', requestId: 'req-404'),
      ),
    );

    // error_mapper 没有为 404 定义专门的失败类型，它落到兜底分支变成
    // ServerFailure；但这不代表信息丢了 —— 服务端文案与 request id 都还在，
    // 页面能如实显示「组不存在」并让用户凭 request id 找运维。
    await expectLater(
      repository.getGroup(404),
      throwsA(
        isA<ServerFailure>()
            .having((failure) => failure.message, 'message', '组不存在')
            .having((failure) => failure.requestId, 'requestId', 'req-404'),
      ),
    );
  });

  test('断网时给出需要联网的提示，而不是静默排队', () async {
    final repository = _repositoryWith(
      (options) => throw DioException.connectionError(
        requestOptions: options,
        reason: 'offline',
      ),
    );

    // 停用整个组、交接主账号这类操作具有全局破坏性，离线排队等网络恢复再
    // 偷偷执行比当场失败危险得多 —— 所以这里必须是 NetworkFailure。
    await expectLater(
      repository.changeStatus(7, GroupStatus.disabled, 3),
      throwsA(isA<NetworkFailure>()),
    );
  });

  test('成功但结构不合法的响应变成 ServerFailure', () async {
    final repository = _repositoryWith((_) => (200, '{"code":"OK"}'));

    await expectLater(
      repository.listGroups(const PlatformGroupQuery()),
      throwsA(isA<ServerFailure>()),
    );
  });

  test('平台治理数据不落本地缓存，也不进离线队列', () async {
    final database = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);

    final adapter = RecordingPlatformAdapter((options) {
      return switch (options.method) {
        'GET' when options.path.endsWith('/7') => (
          200,
          _envelope(platformGroupDetailJson()),
        ),
        'GET' => (200, _envelope(platformGroupPageJson())),
        'POST' => (201, _envelope(platformGroupCreatedJson())),
        'PATCH' => (200, _envelope(platformGroupJson(status: 'disabled'))),
        'PUT' => (200, _envelope(platformOwnerChangedJson())),
        _ => (500, _errorEnvelope('INTERNAL_ERROR', '意外的请求')),
      };
    });
    final repository = DioPlatformRepository(_dioWith(adapter));

    // 把所有写路径都跑一遍，确保「不落盘」说的是全部动作，而不是只有读。
    await repository.listGroups(const PlatformGroupQuery());
    await repository.getGroup(7);
    await repository.createGroup(_createDraft);
    await repository.changeStatus(7, GroupStatus.disabled, 3);
    await repository.changeOwner(
      7,
      const ExistingMemberOwnerDraft(membershipId: 9, version: 3),
    );

    // 平台管理员没有 group，缓存键只能是 0；任何一条数据出现在这里，
    // 都意味着有人给平台仓储接上了本地库 —— 那会把「全平台的组」塞进
    // 一个以 (user_id, group_id) 为键的表里，日后没人说得清它属于谁。
    expect(await database.listOutboxOperations(userId: 0, groupId: 0), isEmpty);
    expect(await database.listCachedMembers(userId: 0, groupId: 0), isEmpty);
    expect(
      await database.listCachedDictionaryEntries(
        userId: 0,
        groupId: 0,
        kind: 'customer',
      ),
      isEmpty,
    );
  });
}
