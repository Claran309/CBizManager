import 'package:c_biz_docs_manager/core/auth/auth_models.dart';
import 'package:c_biz_docs_manager/core/auth/auth_repository.dart';
import 'package:c_biz_docs_manager/core/auth/credential_store.dart';
import 'package:c_biz_docs_manager/core/auth/web_credential_store.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/auth_fixtures.dart';

final class RecordingAuthAdapter implements HttpClientAdapter {
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
    final responseBody = options.uri.path.endsWith('/me')
        ? '''{"code":"OK","message":"success","data":{
             "user":{"id":11,"username":"owner","display_name":"Owner","account_type":"group_owner"},
             "group":{"id":7,"name":"Finance"},
             "member_type":"owner",
             "must_change_password":true,
             "permission_codes":[]
           },"request_id":"request-1"}'''
        : '''{"code":"OK","message":"success","data":{"access_token":"access","refresh_token":"refresh","access_expires_at":"2026-07-24T19:00:00Z","refresh_expires_at":"2026-07-25T19:00:00Z"},"request_id":"request-1"}''';
    return ResponseBody.fromString(
      responseBody,
      200,
      headers: <String, List<String>>{
        Headers.contentTypeHeader: <String>[Headers.jsonContentType],
      },
    );
  }
}

final class FakeCredentialStore implements CredentialStore {
  String? token;
  var writes = 0;
  var clears = 0;

  @override
  Future<void> clear() async {
    clears++;
    token = null;
  }

  @override
  Future<String?> readRefreshToken() async => token;

  @override
  Future<void> writeRefreshToken(String token) async {
    writes++;
    this.token = token;
  }
}

final class FailingCredentialStore implements CredentialStore {
  @override
  Future<void> clear() async {}

  @override
  Future<String?> readRefreshToken() async => null;

  @override
  Future<void> writeRefreshToken(String token) =>
      Future<void>.error(StateError('secure storage unavailable'));
}

final class FakeAuthRemoteDataSource implements AuthRemoteDataSource {
  var nativeLoginCalls = 0;
  var webLoginCalls = 0;
  var nativeRefreshCalls = 0;
  var webRefreshCalls = 0;
  var meCalls = 0;
  var logoutCalls = 0;
  Object? logoutError;
  String? receivedRefreshToken;

  /// 服务端 `/auth/me` 的身份快照，默认与 [RecordingAuthAdapter] 的响应保持一致。
  AuthProfile profile = ownerProfile(mustChangePassword: true);
  TokenResponse response = TokenResponse(
    accessToken: 'access',
    refreshToken: 'refresh',
    accessExpiresAt: DateTime.utc(2026, 7, 24, 19),
    refreshExpiresAt: DateTime.utc(2026, 7, 25, 19),
  );

  @override
  Future<TokenResponse> loginNative(String username, String password) async {
    nativeLoginCalls++;
    return response;
  }

  @override
  Future<TokenResponse> loginWeb(String username, String password) async {
    webLoginCalls++;
    return response;
  }

  @override
  Future<TokenResponse> refreshNative(String refreshToken) async {
    nativeRefreshCalls++;
    receivedRefreshToken = refreshToken;
    return response;
  }

  @override
  Future<TokenResponse> refreshWeb() async {
    webRefreshCalls++;
    return response;
  }

  @override
  Future<AuthProfile> me(String accessToken) async {
    meCalls++;
    return profile;
  }

  @override
  Future<void> logout({required bool web, String? accessToken}) async {
    logoutCalls++;
    final error = logoutError;
    if (error != null) {
      throw error;
    }
  }
}

void main() {
  test('登录后的会话携带服务端完整身份，而不是本地推断', () async {
    final remote = FakeAuthRemoteDataSource();
    final repository = DefaultAuthRepository(
      remote: remote,
      credentials: FakeCredentialStore(),
      accessTokens: InMemoryAccessTokenStore(),
      platform: AuthPlatform.native,
    );

    final session = await repository.login('user', 'password');

    expect(session.profile.accountType, AccountType.groupOwner);
    expect(session.profile.user.id, 11);
    expect(session.profile.group?.id, 7);
    expect(session.profile.memberType, MemberType.owner);
    expect(session.profile.permissionCodes, isEmpty);
    // 主账号隐式持有全部权限：契约规定其 permission_codes 固定为空数组，
    // 权限只能靠 account_type 推导；漏掉这一步会把主账号当成无权限的普通成员。
    expect(session.profile.hasPermission('settlement.approve'), isTrue);
    // scopeKey 绑定 user/group/role/改密态/权限，供会话级 Provider 判断是否整体重建。
    expect(session.scopeKey, '11:7:group_owner:owner:true:');
    expect(remote.meCalls, 1);
  });

  test('native login stores refresh token and restore rotates it', () async {
    final remote = FakeAuthRemoteDataSource();
    final credentials = FakeCredentialStore();
    final accessTokens = InMemoryAccessTokenStore();
    final repository = DefaultAuthRepository(
      remote: remote,
      credentials: credentials,
      accessTokens: accessTokens,
      platform: AuthPlatform.native,
    );

    final login = await repository.login('user', 'password');
    expect(login.accessToken, 'access');
    expect(login.mustChangePassword, isTrue);
    expect(credentials.token, 'refresh');
    expect(accessTokens.accessToken, 'access');

    remote.response = TokenResponse(
      accessToken: 'next-access',
      refreshToken: 'next-refresh',
      accessExpiresAt: DateTime.utc(2026, 7, 24, 20),
      refreshExpiresAt: DateTime.utc(2026, 7, 25, 20),
    );
    final restored = await repository.restore();
    expect(restored.accessToken, 'next-access');
    expect(remote.receivedRefreshToken, 'refresh');
    expect(credentials.token, 'next-refresh');
    expect(remote.meCalls, 2);
  });

  test(
    'web auth uses cookie endpoints and never persists refresh token',
    () async {
      final remote = FakeAuthRemoteDataSource();
      final credentials = WebCredentialStore();
      final repository = DefaultAuthRepository(
        remote: remote,
        credentials: credentials,
        accessTokens: InMemoryAccessTokenStore(),
        platform: AuthPlatform.web,
      );

      await repository.login('user', 'password');
      await repository.restore();
      expect(remote.webLoginCalls, 1);
      expect(remote.webRefreshCalls, 1);
      expect(await credentials.readRefreshToken(), isNull);
    },
  );

  test(
    'Dio auth adapter follows API paths and transport protections',
    () async {
      final adapter = RecordingAuthAdapter();
      final dio = Dio(BaseOptions(baseUrl: 'https://api.example.test'))
        ..httpClientAdapter = adapter;
      final remote = DioAuthRemoteDataSource(
        dio,
        csrfTokenReader: () => 'csrf-token',
      );

      await remote.loginNative('user', 'password');
      final profile = await remote.me('native-access');
      await remote.refreshWeb();
      await remote.logout(web: true);
      await remote.logout(web: false, accessToken: 'native-access');

      expect(adapter.requests.map((request) => request.uri.path), <String>[
        '/api/v1/auth/login',
        '/api/v1/auth/me',
        '/api/v1/auth/web/refresh',
        '/api/v1/auth/web/logout',
        '/api/v1/auth/logout',
      ]);
      expect(profile.mustChangePassword, isTrue);
      // 响应里的 access_token 只是一个普通字符串、并不是合法 JWT，
      // 身份依旧解析成功 —— 反证客户端没有去解码令牌声明。
      expect(profile.accountType, AccountType.groupOwner);
      expect(profile.group?.id, 7);
      expect(profile.permissionCodes, isEmpty);
      expect(
        adapter.requests[1].headers['Authorization'],
        'Bearer native-access',
      );
      expect(adapter.requests[2].headers['X-CSRF-Token'], 'csrf-token');
      expect(adapter.requests[3].headers['X-CSRF-Token'], 'csrf-token');
      expect(adapter.requests[2].extra['withCredentials'], isTrue);
      expect(adapter.requests[3].extra['withCredentials'], isTrue);
      expect(
        adapter.requests[4].headers['Authorization'],
        'Bearer native-access',
      );
    },
  );

  test(
    'native login fails closed when secure storage rejects the refresh token',
    () async {
      final accessTokens = InMemoryAccessTokenStore();
      final repository = DefaultAuthRepository(
        remote: FakeAuthRemoteDataSource(),
        credentials: FailingCredentialStore(),
        accessTokens: accessTokens,
        platform: AuthPlatform.native,
      );

      await expectLater(repository.login('user', 'password'), throwsStateError);
      expect(accessTokens.accessToken, isNull);
    },
  );

  test(
    'logout clears memory and credential store even when remote fails',
    () async {
      final remote = FakeAuthRemoteDataSource();
      remote.logoutError = StateError('network unavailable');
      final credentials = FakeCredentialStore()..token = 'refresh';
      final accessTokens = InMemoryAccessTokenStore()..accessToken = 'access';
      final repository = DefaultAuthRepository(
        remote: remote,
        credentials: credentials,
        accessTokens: accessTokens,
        platform: AuthPlatform.native,
      );

      await expectLater(repository.logout(), throwsStateError);
      expect(accessTokens.accessToken, isNull);
      expect(credentials.token, isNull);
      expect(remote.logoutCalls, 1);
    },
  );
}
