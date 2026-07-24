import 'dart:async';

import 'package:c_biz_docs_manager/core/auth/auth_models.dart';
import 'package:c_biz_docs_manager/core/network/api_client.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

final class ControlledAdapter implements HttpClientAdapter {
  ControlledAdapter({required this.failRefresh});

  final bool failRefresh;
  final Map<String, int> calls = <String, int>{};
  final Map<String, List<String?>> authorizationHeaders =
      <String, List<String?>>{};

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final attempt = (calls[options.path] ?? 0) + 1;
    calls[options.path] = attempt;
    authorizationHeaders
        .putIfAbsent(options.path, () => <String?>[])
        .add(options.headers['Authorization'] as String?);
    if (options.path == '/auth/refresh') {
      return ResponseBody.fromString(
        failRefresh ? '{"code":"AUTH_REFRESH_INVALID"}' : '{"ok":true}',
        failRefresh ? 401 : 200,
        headers: <String, List<String>>{
          Headers.contentTypeHeader: <String>[Headers.jsonContentType],
        },
      );
    }
    return ResponseBody.fromString(
      attempt == 1 ? '{"code":"AUTH_TOKEN_EXPIRED"}' : '{"ok":true}',
      attempt == 1 ? 401 : 200,
      headers: <String, List<String>>{
        Headers.contentTypeHeader: <String>[Headers.jsonContentType],
      },
    );
  }
}

void main() {
  test(
    'three concurrent 401 responses share one refresh and retry once',
    () async {
      final adapter = ControlledAdapter(failRefresh: false);
      final accessTokens = InMemoryAccessTokenStore()..accessToken = 'expired';
      var refreshes = 0;
      var clears = 0;
      final client = ApiClient(
        dio: Dio(BaseOptions(baseUrl: 'https://example.test'))
          ..httpClientAdapter = adapter,
        accessTokens: accessTokens,
        refreshSession: () async {
          refreshes++;
          await Future<void>.delayed(const Duration(milliseconds: 10));
          return AuthSession(accessToken: 'fresh');
        },
        clearSession: () async => clears++,
      );

      final responses = await Future.wait(<Future<Response<dynamic>>>[
        client.dio.get<dynamic>('/one'),
        client.dio.get<dynamic>('/two'),
        client.dio.get<dynamic>('/three'),
      ]);

      expect(responses, hasLength(3));
      expect(refreshes, 1);
      expect(clears, 0);
      expect(accessTokens.accessToken, 'fresh');
      expect(adapter.calls['/one'], 2);
      expect(adapter.calls['/two'], 2);
      expect(adapter.calls['/three'], 2);
      expect(adapter.authorizationHeaders['/one'], <String?>[
        'Bearer expired',
        'Bearer fresh',
      ]);
      expect(adapter.authorizationHeaders['/two'], <String?>[
        'Bearer expired',
        'Bearer fresh',
      ]);
      expect(adapter.authorizationHeaders['/three'], <String?>[
        'Bearer expired',
        'Bearer fresh',
      ]);
    },
  );

  test(
    'separate failed refresh flights each clear their session once',
    () async {
      final adapter = ControlledAdapter(failRefresh: true);
      var refreshes = 0;
      var clears = 0;
      final client = ApiClient(
        dio: Dio(BaseOptions(baseUrl: 'https://example.test'))
          ..httpClientAdapter = adapter,
        accessTokens: InMemoryAccessTokenStore()..accessToken = 'expired',
        refreshSession: () async {
          refreshes++;
          throw StateError('refresh rejected');
        },
        clearSession: () async => clears++,
      );

      await expectLater(
        client.dio.get<dynamic>('/first-session'),
        throwsA(isA<DioException>()),
      );
      client.accessTokens.accessToken = 'expired-after-login';
      await expectLater(
        client.dio.get<dynamic>('/second-session'),
        throwsA(isA<DioException>()),
      );

      expect(refreshes, 2);
      expect(clears, 2);
    },
  );

  test(
    'refresh failure clears one session and never recursively retries',
    () async {
      final adapter = ControlledAdapter(failRefresh: true);
      var refreshes = 0;
      var clears = 0;
      final client = ApiClient(
        dio: Dio(BaseOptions(baseUrl: 'https://example.test'))
          ..httpClientAdapter = adapter,
        accessTokens: InMemoryAccessTokenStore()..accessToken = 'expired',
        refreshSession: () async {
          refreshes++;
          throw DioException.badResponse(
            statusCode: 401,
            requestOptions: RequestOptions(path: '/auth/refresh'),
            response: Response<void>(
              requestOptions: RequestOptions(path: '/auth/refresh'),
              statusCode: 401,
            ),
          );
        },
        clearSession: () async => clears++,
      );

      await expectLater(
        client.dio.get<dynamic>('/protected'),
        throwsA(isA<DioException>()),
      );

      expect(refreshes, 1);
      expect(clears, 1);
      expect(adapter.calls['/protected'], 1);
    },
  );

  test(
    'a 401 from the refresh endpoint never starts another refresh',
    () async {
      final adapter = ControlledAdapter(failRefresh: true);
      var refreshes = 0;
      var clears = 0;
      final client = ApiClient(
        dio: Dio(BaseOptions(baseUrl: 'https://example.test'))
          ..httpClientAdapter = adapter,
        accessTokens: InMemoryAccessTokenStore(),
        refreshSession: () async {
          refreshes++;
          return const AuthSession(accessToken: 'should-not-be-used');
        },
        clearSession: () async => clears++,
      );

      await expectLater(
        client.dio.post<dynamic>('/auth/refresh'),
        throwsA(isA<DioException>()),
      );

      expect(refreshes, 0);
      expect(clears, 0);
      expect(adapter.calls['/auth/refresh'], 1);
    },
  );
}
