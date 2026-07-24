import 'package:c_biz_docs_manager/core/auth/auth_models.dart';
import 'package:c_biz_docs_manager/core/auth/auth_repository.dart';
import 'package:c_biz_docs_manager/core/auth/credential_store.dart';
import 'package:c_biz_docs_manager/core/auth/web_credential_store.dart';
import 'package:flutter_test/flutter_test.dart';

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
  var logoutCalls = 0;
  String? receivedRefreshToken;
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
  Future<void> logout({required bool web, String? accessToken}) async {
    logoutCalls++;
  }
}

void main() {
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
      final credentials = FakeCredentialStore()..token = 'refresh';
      final accessTokens = InMemoryAccessTokenStore()..accessToken = 'access';
      final repository = DefaultAuthRepository(
        remote: remote,
        credentials: credentials,
        accessTokens: accessTokens,
        platform: AuthPlatform.native,
      );

      await repository.logout();
      expect(accessTokens.accessToken, isNull);
      expect(credentials.token, isNull);
      expect(remote.logoutCalls, 1);
    },
  );
}
