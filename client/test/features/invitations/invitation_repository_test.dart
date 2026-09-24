import 'dart:convert';

import 'package:c_biz_docs_manager/core/error/app_failure.dart';
import 'package:c_biz_docs_manager/core/network/page_result.dart';
import 'package:c_biz_docs_manager/features/invitations/data/invitation_repository.dart';
import 'package:c_biz_docs_manager/features/invitations/domain/invitation.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/invitation_fixtures.dart';

/// 一个可以按请求内容决定响应的假适配器。
///
/// 直接挂在 [Dio] 的 `httpClientAdapter` 上，而不是去 mock 仓储：这样被测的是
/// **真实的** Dio 请求拼装（路径、方法、query 参数、body 序列化），
/// 而不是我们自己对 Dio 的假设。
final class RecordingInvitationAdapter implements HttpClientAdapter {
  RecordingInvitationAdapter(this.respond);

  /// 收到一个请求就返回 `(状态码, 响应体)`。
  final (int, String) Function(RequestOptions options) respond;

  /// 额外的响应头。
  ///
  /// 查看明文的接口在真实服务端上固定带 `Cache-Control: no-store`；用例需要能
  /// 造出这个形态，才能验证「多了一个响应头也不影响解析」。
  Map<String, List<String>> extraHeaders = <String, List<String>>{};

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
        ...extraHeaders,
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

Dio _dioWith(RecordingInvitationAdapter adapter) =>
    Dio(BaseOptions(baseUrl: 'https://api.example.test'))
      ..httpClientAdapter = adapter;

void main() {
  test('列表请求带上分页与状态筛选，并按一页解析', () async {
    final adapter = RecordingInvitationAdapter(
      (_) => (200, _envelope(invitationPageJson())),
    );

    final PageResult<InvitationSummary> page = await DioInvitationRepository(
      _dioWith(adapter),
    ).list(status: InvitationStatus.used, page: 2, pageSize: 50);

    final request = adapter.requests.single;
    expect(request.method, 'GET');
    expect(request.path, '/api/v1/groups/invitations');
    expect(request.queryParameters, <String, Object?>{
      'page': 2,
      'page_size': 50,
      'status': 'used',
    });
    // 只取一页：翻页由界面决定，仓储自作主张拉全会让「共 N 条」与「当前页」
    // 的语义混在一起。
    expect(adapter.requests, hasLength(1));
    expect(page.items.single.id, 9);
    expect(page.items.single.status, InvitationStatus.active);
    expect((page.page, page.pageSize, page.total), (1, 20, 1));
  });

  test('不筛状态时请求参数里不出现 status', () async {
    final adapter = RecordingInvitationAdapter(
      (_) => (200, _envelope(invitationPageJson(items: const <Object?>[]))),
    );

    await DioInvitationRepository(_dioWith(adapter)).list();

    // 显式传 status=null 会被序列化成空串，服务端按非法枚举拒绝，
    // 于是「不筛状态」反而报 400 —— 必须确认键根本不存在。
    expect(adapter.requests.single.queryParameters, <String, Object?>{
      'page': 1,
      'page_size': 20,
    });
  });

  test('创建时不指定有效期也要发一个空对象，而不是空 body', () async {
    final adapter = RecordingInvitationAdapter(
      (_) => (201, _envelope(invitationSecretJson())),
    );

    final secret = await DioInvitationRepository(_dioWith(adapter)).create();

    final request = adapter.requests.single;
    expect(request.method, 'POST');
    expect(request.path, '/api/v1/groups/invitations');
    // 服务端的 ShouldBindJSON 在空 body 上直接报 EOF 回 400，而契约里
    // expires_in_days 是**可选**的（缺省 7 天），所以「不指定」必须能跑通。
    expect(request.data, <String, Object?>{});
    expect(secret.code, 'INV-ABCD-EFGH');
    expect(secret.invitationId, 9);
  });

  test('指定有效期时带上 expires_in_days', () async {
    final adapter = RecordingInvitationAdapter(
      (_) => (201, _envelope(invitationSecretJson())),
    );

    await DioInvitationRepository(_dioWith(adapter)).create(expiresInDays: 15);

    expect(adapter.requests.single.data, <String, Object?>{
      'expires_in_days': 15,
    });
  });

  test('查看明文用 POST 打到 /secret，响应带 no-store 也照常解析', () async {
    final adapter =
        RecordingInvitationAdapter(
            (_) => (
              200,
              _envelope(invitationSecretJson(invitationCode: 'PLAIN-CODE')),
            ),
          )
          // 真实服务端给这个响应固定加 no-store；客户端不去读它，但也不能因为它
          // 存在就解析失败。
          ..extraHeaders = <String, List<String>>{
            'cache-control': <String>['no-store'],
            'pragma': <String>['no-cache'],
          };

    final secret = await DioInvitationRepository(
      _dioWith(adapter),
    ).revealSecret(9);

    final request = adapter.requests.single;
    expect(request.method, 'POST');
    expect(request.path, '/api/v1/groups/invitations/9/secret');
    expect(secret.code, 'PLAIN-CODE');
  });

  test('撤销只提交版本号', () async {
    final adapter = RecordingInvitationAdapter(
      (_) => (
        200,
        _envelope(invitationSummaryJson(status: 'revoked', version: 2)),
      ),
    );

    final invitation = await DioInvitationRepository(
      _dioWith(adapter),
    ).revoke(9, 1);

    final request = adapter.requests.single;
    expect(request.method, 'POST');
    expect(request.path, '/api/v1/groups/invitations/9/revoke');
    expect(request.data, <String, Object?>{'version': 1});
    // 服务端回显撤销后的摘要，客户端拿它替换列表里的旧行。
    expect(invitation.status, InvitationStatus.revoked);
    expect(invitation.version, 2);
  });

  test('四种展示状态都能解析', () async {
    for (final status in InvitationStatus.values) {
      final adapter = RecordingInvitationAdapter(
        (_) =>
            (200, _envelope(invitationSummaryJson(status: status.wireValue))),
      );

      final invitation = await DioInvitationRepository(
        _dioWith(adapter),
      ).revoke(9, 1);

      expect(invitation.status, status);
    }
  });

  test('未使用 / 未撤销时，字段缺失或显式给 null 都能解析', () async {
    final missing = RecordingInvitationAdapter(
      (_) => (200, _envelope(invitationSummaryJson())),
    );
    final explicitNull = RecordingInvitationAdapter(
      (_) => (
        200,
        _envelope(
          invitationSummaryJson(includeOptionalTimes: true, status: 'used'),
        ),
      ),
    );

    final first = await DioInvitationRepository(_dioWith(missing)).revoke(9, 1);
    final second = await DioInvitationRepository(
      _dioWith(explicitNull),
    ).revoke(9, 1);

    // Go 侧给这两个字段加了 omitempty（缺失），契约又标了 nullable（显式 null）——
    // 两种形态在真实响应里都会出现，少支持一种就会在生产上解析失败。
    expect((first.usedAt, first.revokedAt), (null, null));
    expect((second.usedAt, second.revokedAt), (null, null));
  });

  test('已使用的时间会被归一成 UTC', () async {
    final adapter = RecordingInvitationAdapter(
      (_) => (
        200,
        _envelope(
          invitationSummaryJson(
            status: 'used',
            usedAt: '2026-02-10T08:00:00+08:00',
          ),
        ),
      ),
    );

    final invitation = await DioInvitationRepository(
      _dioWith(adapter),
    ).revoke(9, 1);

    expect(invitation.usedAt, DateTime.utc(2026, 2, 10));
  });

  test('未知状态不静默降级，而是变成 ServerFailure', () async {
    final adapter = RecordingInvitationAdapter(
      (_) => (200, _envelope(invitationSummaryJson(status: 'pending'))),
    );

    // 把未知状态当成 active，会让一个已经被撤销的邀请码在界面上重新长出
    // 「查看 / 撤销」按钮 —— 宁可整页报错。
    await expectLater(
      DioInvitationRepository(_dioWith(adapter)).list(),
      throwsA(isA<ServerFailure>()),
    );
  });

  test('明文不会出现在 toString 里', () {
    final secret = domainSecret(code: 'SUPER-SECRET-CODE');

    // toString 必然会出现在断言失败信息、调试打印和异常堆栈里，
    // 那是明文泄漏最常见的途径。
    expect(secret.toString(), isNot(contains('SUPER-SECRET-CODE')));
    expect(secret.toString(), contains('9'));
  });

  test('版本冲突映射成 ConflictFailure 并保留服务端文案', () async {
    final adapter = RecordingInvitationAdapter(
      (_) => (
        409,
        _errorEnvelope(
          'RESOURCE_VERSION_CONFLICT',
          '邀请码已被其他请求修改',
          requestId: 'req-9',
        ),
      ),
    );

    await expectLater(
      DioInvitationRepository(_dioWith(adapter)).revoke(9, 1),
      throwsA(
        isA<ConflictFailure>()
            .having((e) => e.message, 'message', '邀请码已被其他请求修改')
            .having((e) => e.requestId, 'requestId', 'req-9'),
      ),
    );
  });

  test('断网时映射成 NetworkFailure', () async {
    final adapter = RecordingInvitationAdapter((options) {
      throw DioException.connectionError(
        requestOptions: options,
        reason: 'offline',
      );
    });

    // 邀请码明文与撤销都不进 Outbox：离线排队等网络恢复再偷偷发出去，
    // 意味着用户以为撤销了、而邀请码在等待期间一直有效。
    //
    // 这里只断言类型：映射出的是 NetworkFailure 就说明「断网走的是需要联网
    // 的那条路径」。具体文案（「该操作需要联网」那句）由 FailurePresenter 负责，
    // 它有自己的测试；在仓储层断言那句话等于把展示层的措辞焊进数据层。
    await expectLater(
      DioInvitationRepository(_dioWith(adapter)).list(),
      throwsA(isA<NetworkFailure>()),
    );
  });
}
