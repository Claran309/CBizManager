import 'package:c_biz_docs_manager/core/auth/auth_models.dart';
import 'package:c_biz_docs_manager/core/auth/credential_store.dart';
import 'package:c_biz_docs_manager/core/auth/web_cookie_reader.dart';
import 'package:c_biz_docs_manager/core/error/app_failure.dart';
import 'package:c_biz_docs_manager/core/network/api_envelope.dart';
import 'package:c_biz_docs_manager/core/network/error_mapper.dart';
import 'package:dio/dio.dart';

/// Isolates endpoint selection and transport details from session lifecycle.
abstract interface class AuthRemoteDataSource {
  Future<TokenResponse> loginNative(String username, String password);

  Future<TokenResponse> loginWeb(String username, String password);

  Future<TokenResponse> refreshNative(String refreshToken);

  Future<TokenResponse> refreshWeb();

  Future<AuthProfile> me(String accessToken);

  Future<void> logout({required bool web, String? accessToken});

  Future<RegistrationResult> register(RegistrationDraft draft);

  Future<void> changePassword(String currentPassword, String newPassword);
}

abstract interface class AuthRepository {
  Future<AuthSession> login(String username, String password);

  Future<AuthSession> restore();

  Future<RegistrationResult> register(RegistrationDraft draft);

  Future<AuthSession> changePassword(
    String currentPassword,
    String newPassword,
  );

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
  Future<RegistrationResult> register(RegistrationDraft draft) async {
    // 注册不建立会话：本地既不写刷新令牌、也不设访问令牌。用户必须自己用新账号
    // 登录一次，否则新人会被静默当成已登录，绕过登录页与强制改密两道关。
    return remote.register(draft);
  }

  @override
  Future<AuthSession> changePassword(
    String currentPassword,
    String newPassword,
  ) async {
    await remote.changePassword(currentPassword, newPassword);
    final accessToken = accessTokens.accessToken;
    if (accessToken == null || accessToken.isEmpty) {
      throw StateError('Changing a password requires an active access token');
    }
    // 服务端改密既不吊销当前访问令牌、也不签发新的，所以这里既不能重新登录、
    // 也不能把密码存起来；只需用同一个令牌重读身份，拿到 must_change_password=false
    // 的新快照。改密不产生新令牌，因此没有可用的过期时间，accessExpiresAt 留空。
    final profile = await remote.me(accessToken);
    return AuthSession(accessToken: accessToken, profile: profile);
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
    final profile = await remote.me(response.accessToken);
    accessTokens.accessToken = response.accessToken;
    return AuthSession(
      accessToken: response.accessToken,
      profile: profile,
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
  Future<AuthProfile> me(String accessToken) => _guard(() async {
    final response = await _dio.get<Object?>(
      '$_apiPrefix/me',
      options: Options(
        headers: <String, Object?>{'Authorization': 'Bearer $accessToken'},
      ),
    );
    // 身份的唯一来源是服务端响应体。这里刻意不解析 access token 的 JWT 载荷：
    // 那部分是客户端可读可改的，用它判定角色等于把权限交给攻击者。
    return AuthProfile.fromJson(
      _decodeEnvelopeData(response.data, 'Current-user response'),
    );
  });

  @override
  Future<void> logout({required bool web, String? accessToken}) =>
      _guard(() async {
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
      });

  @override
  Future<RegistrationResult> register(RegistrationDraft draft) =>
      _guard(() async {
        final response = await _dio.post<Object?>(
          '$_apiPrefix/register',
          data: <String, Object?>{
            'invitation_code': draft.invitationCode,
            'username': draft.username,
            'display_name': draft.displayName,
            'password': draft.password,
          },
        );
        // 注册响应里没有 access_token，也就无从解析出一个会话 —— 这正是契约本意。
        return RegistrationResult.fromJson(
          _decodeEnvelopeData(response.data, 'Registration response'),
        );
      });

  @override
  Future<void> changePassword(String currentPassword, String newPassword) =>
      _guard(() async {
        // 鉴权头由 ApiClient 的拦截器统一注入，这里不自己拼 Bearer：
        // 多一份拼装就多一份与刷新逻辑不一致的可能。
        final response = await _dio.put<Object?>(
          '$_apiPrefix/password',
          data: <String, Object?>{
            'current_password': currentPassword,
            'new_password': newPassword,
          },
        );
        final data = _decodeEnvelopeData(
          response.data,
          'Password change response',
        );
        if (data['changed'] != true) {
          // 200 却没说改成功，说明契约被破坏。此时静默通过会让客户端误以为强制改密
          // 已经解除，把用户卡在改密页与业务页之间来回弹。
          throw const FormatException(
            'Password change response must report changed=true',
          );
        }
      });

  Future<TokenResponse> _postTokens(
    String path,
    Object? body, {
    Options? options,
  }) => _guard(() async {
    final response = await _dio.post<Object?>(
      path,
      data: body,
      options: options,
    );
    final data = _decodeEnvelopeData(response.data, 'Authentication response');
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
  });

  /// 解出响应 Envelope 的 data 对象。
  ///
  /// 本项目所有接口都包在 `{code, message, data, request_id}` 里，且 `data`
  /// 必须是对象；集中解析可以避免每个 endpoint 各写一遍、也避免各处漏校验。
  Map<String, Object?> _decodeEnvelopeData(Object? raw, String label) {
    if (raw is! Map) {
      throw FormatException('$label must be an object');
    }
    final envelope = ApiEnvelope<Map<String, Object?>>.fromJson(
      Map<String, Object?>.from(raw),
      (Object? value) {
        if (value is! Map) {
          throw FormatException('$label data must be an object');
        }
        return Map<String, Object?>.from(value);
      },
    );
    final data = envelope.data;
    if (data == null) {
      throw FormatException('$label data is required');
    }
    return data;
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

/// 把传输层与契约解析的异常统一收敛成 [AppFailure]。
///
/// 与 dictionaries / members 仓储里的同名辅助保持一致：只有变成 [AppFailure]，
/// 上层 Controller 的 `on AppFailure catch` 才接得住。否则改密的「当前密码错误」
/// 或一次网络抖动会以原始 [DioException] 逃逸出状态机，页面既拿不到失败详情，
/// 也没法把字段错误映射到对应的输入框。
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
