import 'package:c_biz_docs_manager/core/auth/auth_models.dart';
import 'package:c_biz_docs_manager/core/auth/credential_store.dart';
import 'package:c_biz_docs_manager/core/auth/web_cookie_reader.dart';
import 'package:c_biz_docs_manager/core/network/api_envelope.dart';
import 'package:dio/dio.dart';

/// Isolates endpoint selection and transport details from session lifecycle.
abstract interface class AuthRemoteDataSource {
  Future<TokenResponse> loginNative(String username, String password);

  Future<TokenResponse> loginWeb(String username, String password);

  Future<TokenResponse> refreshNative(String refreshToken);

  Future<TokenResponse> refreshWeb();

  Future<void> logout({required bool web, String? accessToken});
}

abstract interface class AuthRepository {
  Future<AuthSession> login(String username, String password);

  Future<AuthSession> restore();

  Future<void> logout();
}

/// Manages the split-token policy: access tokens stay in memory, while native
/// refresh tokens are kept in secure storage and rotated after every refresh.
final class DefaultAuthRepository implements AuthRepository {
  DefaultAuthRepository({
    required this.remote,
    required this.credentials,
    required this.accessTokens,
    required this.platform,
  });

  final AuthRemoteDataSource remote;
  final CredentialStore credentials;
  final AccessTokenStore accessTokens;
  final AuthPlatform platform;

  @override
  Future<AuthSession> login(String username, String password) async {
    final response = platform == AuthPlatform.web
        ? await remote.loginWeb(username, password)
        : await remote.loginNative(username, password);
    return _accept(response);
  }

  @override
  Future<AuthSession> restore() async {
    if (platform == AuthPlatform.web) {
      return _accept(await remote.refreshWeb());
    }

    final refreshToken = await credentials.readRefreshToken();
    if (refreshToken == null || refreshToken.isEmpty) {
      throw StateError('No native refresh token is available');
    }
    return _accept(await remote.refreshNative(refreshToken));
  }

  @override
  Future<void> logout() async {
    try {
      await remote.logout(
        web: platform == AuthPlatform.web,
        accessToken: accessTokens.accessToken,
      );
    } finally {
      // Local credentials must be removed even if a disconnected client cannot
      // notify the server. Secure-storage failures still surface to the caller.
      accessTokens.clear();
      await credentials.clear();
    }
  }

  Future<AuthSession> _accept(TokenResponse response) async {
    if (platform == AuthPlatform.native) {
      final refreshToken = response.refreshToken;
      if (refreshToken == null || refreshToken.isEmpty) {
        throw StateError('Native authentication response has no refresh token');
      }
      // Persist first: a storage failure must not leave a usable in-memory
      // session whose refresh rotation was never safely recorded.
      await credentials.writeRefreshToken(refreshToken);
    }
    accessTokens.accessToken = response.accessToken;
    return AuthSession(
      accessToken: response.accessToken,
      accessExpiresAt: response.accessExpiresAt,
    );
  }
}

/// Concrete endpoint adapter shared by the repository and application wiring.
/// It decodes the project's response envelope but never logs credentials.
final class DioAuthRemoteDataSource implements AuthRemoteDataSource {
  DioAuthRemoteDataSource(
    this._dio, {
    String csrfCookieName = 'cbiz_csrf',
    String? Function()? csrfTokenReader,
  }) : _csrfTokenReader =
           csrfTokenReader ?? (() => readBrowserCookie(csrfCookieName));

  final Dio _dio;
  final String? Function() _csrfTokenReader;

  static const _apiPrefix = '/api/v1/auth';

  @override
  Future<TokenResponse> loginNative(String username, String password) =>
      _postTokens('$_apiPrefix/login', <String, Object?>{
        'username': username,
        'password': password,
      });

  @override
  Future<TokenResponse> loginWeb(String username, String password) =>
      _postTokens('$_apiPrefix/web/login', <String, Object?>{
        'username': username,
        'password': password,
      }, options: _webOptions(requireCSRF: false));

  @override
  Future<TokenResponse> refreshNative(String refreshToken) => _postTokens(
    '$_apiPrefix/refresh',
    <String, Object?>{'refresh_token': refreshToken},
  );

  @override
  Future<TokenResponse> refreshWeb() => _postTokens(
    '$_apiPrefix/web/refresh',
    null,
    options: _webOptions(requireCSRF: true),
  );

  @override
  Future<void> logout({required bool web, String? accessToken}) async {
    if (web) {
      await _dio.post<void>(
        '$_apiPrefix/web/logout',
        options: _webOptions(requireCSRF: true),
      );
      return;
    }
    if (accessToken == null || accessToken.isEmpty) {
      throw StateError('Native logout requires an access token');
    }
    await _dio.post<void>(
      '$_apiPrefix/logout',
      options: Options(
        headers: <String, Object?>{'Authorization': 'Bearer $accessToken'},
      ),
    );
  }

  Future<TokenResponse> _postTokens(
    String path,
    Object? body, {
    Options? options,
  }) async {
    final response = await _dio.post<Object?>(
      path,
      data: body,
      options: options,
    );
    final raw = response.data;
    if (raw is! Map) {
      throw const FormatException('Authentication response must be an object');
    }
    final envelope = ApiEnvelope<Map<String, Object?>>.fromJson(
      Map<String, Object?>.from(raw),
      (Object? value) {
        if (value is! Map) {
          throw const FormatException('Authentication data must be an object');
        }
        return Map<String, Object?>.from(value);
      },
    );
    final data = envelope.data;
    if (data == null) {
      throw const FormatException('Authentication response data is required');
    }
    final accessToken = data['access_token'];
    if (accessToken is! String || accessToken.isEmpty) {
      throw const FormatException(
        'Authentication response access_token is required',
      );
    }
    return TokenResponse(
      accessToken: accessToken,
      refreshToken: data['refresh_token'] as String?,
      accessExpiresAt: _readDate(data['access_expires_at']),
      refreshExpiresAt: _readDate(data['refresh_expires_at']),
    );
  }

  Options _webOptions({required bool requireCSRF}) {
    final headers = <String, Object?>{};
    if (requireCSRF) {
      final token = _csrfTokenReader();
      if (token == null || token.isEmpty) {
        throw StateError('Web authentication requires a CSRF cookie');
      }
      headers['X-CSRF-Token'] = token;
    }
    // Dio's browser adapter consumes this per-request flag and sets
    // XMLHttpRequest.withCredentials, including for the login Set-Cookie.
    return Options(
      headers: headers,
      extra: <String, Object?>{'withCredentials': true},
    );
  }

  DateTime? _readDate(Object? value) {
    if (value == null) {
      return null;
    }
    if (value is! String) {
      throw const FormatException(
        'Authentication expiry must be an ISO-8601 string',
      );
    }
    return DateTime.parse(value).toUtc();
  }
}
