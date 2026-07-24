import 'package:c_biz_docs_manager/core/auth/auth_models.dart';
import 'package:dio/dio.dart';

/// Wraps Dio with memory-only bearer authentication and coordinated refresh.
///
/// [refreshSession] should call `AuthRepository.restore`; it is injected to
/// avoid a cyclic dependency between the network client and authentication
/// repository. [clearSession] removes local credentials after a failed refresh.
final class ApiClient {
  ApiClient({
    required this.dio,
    required this.accessTokens,
    required this.refreshSession,
    required this.clearSession,
  }) {
    dio.interceptors.add(_AuthInterceptor(this));
  }

  static const retriedRequestExtraKey = '_retried';

  final Dio dio;
  final AccessTokenStore accessTokens;
  final Future<AuthSession> Function() refreshSession;
  final Future<void> Function() clearSession;
  Future<AuthSession>? _refreshing;
  bool _sessionClearedAfterRefreshFailure = false;

  bool canRefresh(RequestOptions options) {
    final path = options.path;
    return !path.endsWith('/auth/refresh') &&
        !path.endsWith('/auth/web/refresh') &&
        options.extra[retriedRequestExtraKey] != true;
  }

  Future<AuthSession> refreshOnce() {
    final current = _refreshing;
    if (current != null) {
      return current;
    }

    late final Future<AuthSession> pending;
    pending = _performRefresh();
    _refreshing = pending;
    return pending;
  }

  Future<AuthSession> _performRefresh() async {
    try {
      final session = await refreshSession();
      accessTokens.accessToken = session.accessToken;
      _sessionClearedAfterRefreshFailure = false;
      return session;
    } catch (_) {
      if (!_sessionClearedAfterRefreshFailure) {
        _sessionClearedAfterRefreshFailure = true;
        await clearSession();
      }
      rethrow;
    } finally {
      _refreshing = null;
    }
  }
}

final class _AuthInterceptor extends Interceptor {
  _AuthInterceptor(this._client);

  final ApiClient _client;

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    final token = _client.accessTokens.accessToken;
    if (token != null &&
        token.isNotEmpty &&
        !options.headers.containsKey('Authorization')) {
      options.headers['Authorization'] = 'Bearer $token';
    }
    handler.next(options);
  }

  @override
  void onError(DioException error, ErrorInterceptorHandler handler) async {
    final options = error.requestOptions;
    if (error.response?.statusCode != 401 || !_client.canRefresh(options)) {
      handler.next(error);
      return;
    }

    try {
      await _client.refreshOnce();
      options.extra[ApiClient.retriedRequestExtraKey] = true;
      final response = await _client.dio.fetch<Object?>(options);
      handler.resolve(response);
    } catch (_) {
      // Preserve the protected request's original 401 instead of turning it
      // into another refresh error; callers can map it to an auth-expired UI.
      handler.next(error);
    }
  }
}
