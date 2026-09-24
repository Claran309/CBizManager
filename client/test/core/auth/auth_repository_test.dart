import 'package:c_biz_docs_manager/core/auth/auth_models.dart';
import 'package:c_biz_docs_manager/core/auth/auth_repository.dart';
import 'package:c_biz_docs_manager/core/auth/credential_store.dart';
import 'package:c_biz_docs_manager/core/auth/web_credential_store.dart';
import 'package:c_biz_docs_manager/core/error/app_failure.dart';
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
    return ResponseBody.fromString(
      _bodyFor(options.uri.path),
      200,
      headers: <String, List<String>>{
        Headers.contentTypeHeader: <String>[Headers.jsonContentType],
      },
    );
  }

  String _bodyFor(String path) {
    if (path.endsWith('/me')) {
      return '''{"code":"OK","message":"success","data":{
             "user":{"id":11,"username":"owner","display_name":"Owner","account_type":"group_owner"},
             "group":{"id":7,"name":"Finance"},
             "member_type":"owner",
             "must_change_password":true,
             "permission_codes":[]
           },"request_id":"request-1"}''';
    }
    if (path.endsWith('/register')) {
      return '''{"code":"OK","message":"success","data":{
             "user":{"id":22,"username":"sales","display_name":"Sales","account_type":"member"},
             "group":{"id":7,"name":"Finance"}
           },"request_id":"request-1"}''';
    }
    if (path.endsWith('/password')) {
      return '''{"code":"OK","message":"success","data":{"changed":true},"request_id":"request-1"}''';
    }
    return '''{"code":"OK","message":"success","data":{"access_token":"access","refresh_token":"refresh","access_expires_at":"2026-07-24T19:00:00Z","refresh_expires_at":"2026-07-25T19:00:00Z"},"request_id":"request-1"}''';
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
  var registerCalls = 0;
  var changePasswordCalls = 0;
  Object? logoutError;
  Object? changePasswordError;
  String? receivedRefreshToken;

  /// 最近一次 `/auth/me` 用到的访问令牌，用于断言改密后沿用了旧令牌。
  String? receivedMeToken;

  /// 最近一次注册提交的草稿。
  RegistrationDraft? receivedRegistration;

  /// 最近一次改密提交的 (当前密码, 新密码)。
  (String, String)? receivedPasswordChange;

  RegistrationResult registration = const RegistrationResult(
    username: 'sales',
    groupName: 'Finance',
  );

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
    receivedMeToken = accessToken;
    return profile;
  }

  @override
  Future<RegistrationResult> register(RegistrationDraft draft) async {
    registerCalls++;
    receivedRegistration = draft;
    return registration;
  }

  @override
  Future<void> changePassword(
    String currentPassword,
    String newPassword,
  ) async {
    changePasswordCalls++;
    receivedPasswordChange = (currentPassword, newPassword);
    final error = changePasswordError;
    if (error != null) {
      throw error;
    }
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

  test('注册只创建账号并回传用户名，不建立本地会话', () async {
    final remote = FakeAuthRemoteDataSource();
    final credentials = FakeCredentialStore();
    final accessTokens = InMemoryAccessTokenStore();
    final repository = DefaultAuthRepository(
      remote: remote,
      credentials: credentials,
      accessTokens: accessTokens,
      platform: AuthPlatform.native,
    );

    final result = await repository.register(_draft);

    expect(remote.registerCalls, 1);
    expect(remote.receivedRegistration, same(_draft));
    expect(result.username, 'sales');
    expect(result.groupName, 'Finance');
    // 注册不等于登录：服务端只回 user/group，不发令牌。客户端必须保持登出，
    // 否则新人会被静默当成已登录，绕过登录页与强制改密这两道关。
    expect(accessTokens.accessToken, isNull);
    expect(credentials.token, isNull);
    expect(credentials.writes, 0);
    expect(remote.meCalls, 0);
    expect(remote.nativeLoginCalls, 0);
  });

  test('改密后用同一个访问令牌重读身份，不重新登录也不保存密码', () async {
    final remote = FakeAuthRemoteDataSource();
    final credentials = FakeCredentialStore()..token = 'refresh';
    final accessTokens = InMemoryAccessTokenStore()..accessToken = 'access';
    final repository = DefaultAuthRepository(
      remote: remote,
      credentials: credentials,
      accessTokens: accessTokens,
      platform: AuthPlatform.native,
    );
    // 服务端在改密成功时会清掉强制改密标记，客户端必须重新读取才会拿到新身份。
    remote.profile = ownerProfile();

    final session = await repository.changePassword(
      'old-password',
      'new-password',
    );

    expect(remote.changePasswordCalls, 1);
    expect(remote.receivedPasswordChange, ('old-password', 'new-password'));
    expect(remote.meCalls, 1);
    // 改密不签发新令牌：沿用内存里已有的 access token，绝不走登录流程。
    expect(remote.receivedMeToken, 'access');
    expect(session.accessToken, 'access');
    expect(session.profile.mustChangePassword, isFalse);
    expect(session.scopeKey, '11:7:group_owner:owner:false:');
    // 新密码只是请求参数：既不落凭据存储，也不产生新的刷新令牌轮换。
    expect(credentials.writes, 0);
    expect(credentials.token, 'refresh');
    expect(remote.nativeLoginCalls, 0);
  });

  test('改密失败时不改动本地凭据，也不白跑一次身份读取', () async {
    final remote = FakeAuthRemoteDataSource()
      ..changePasswordError = const UnauthenticatedFailure('当前密码错误');
    final credentials = FakeCredentialStore()..token = 'refresh';
    final accessTokens = InMemoryAccessTokenStore()..accessToken = 'access';
    final repository = DefaultAuthRepository(
      remote: remote,
      credentials: credentials,
      accessTokens: accessTokens,
      platform: AuthPlatform.native,
    );

    await expectLater(
      repository.changePassword('wrong-password', 'new-password'),
      throwsA(isA<UnauthenticatedFailure>()),
    );

    expect(accessTokens.accessToken, 'access');
    expect(credentials.token, 'refresh');
    expect(remote.meCalls, 0);
  });

  test('Dio 认证适配器按契约提交注册与改密请求体', () async {
    final adapter = RecordingAuthAdapter();
    final dio = Dio(BaseOptions(baseUrl: 'https://api.example.test'))
      ..httpClientAdapter = adapter;
    final remote = DioAuthRemoteDataSource(dio);

    final registration = await remote.register(_draft);
    await remote.changePassword('old-password', 'new-password');

    expect(adapter.requests.map((request) => request.uri.path), <String>[
      '/api/v1/auth/register',
      '/api/v1/auth/password',
    ]);
    expect(adapter.requests[0].method, 'POST');
    expect(adapter.requests[0].data, <String, Object?>{
      'invitation_code': 'INV-1',
      'username': 'sales',
      'display_name': 'Sales',
      'password': 'password123',
    });
    expect(adapter.requests[1].method, 'PUT');
    expect(adapter.requests[1].data, <String, Object?>{
      'current_password': 'old-password',
      'new_password': 'new-password',
    });
    expect(registration.username, 'sales');
    expect(registration.groupName, 'Finance');
    // 两个请求都不带 Authorization：注册是匿名接口，改密则由 ApiClient 的
    // 拦截器统一注入 Bearer，适配器自己拼鉴权头只会多出一份真相。
    expect(
      adapter.requests.every(
        (request) => !request.headers.containsKey('Authorization'),
      ),
      isTrue,
    );
  });
}

const _draft = RegistrationDraft(
  invitationCode: 'INV-1',
  username: 'sales',
  displayName: 'Sales',
  password: 'password123',
);
