import 'package:c_biz_docs_manager/app/app.dart';
import 'package:c_biz_docs_manager/app/session_scope.dart';
import 'package:c_biz_docs_manager/core/auth/auth_controller.dart';
import 'package:c_biz_docs_manager/core/auth/auth_models.dart';
import 'package:c_biz_docs_manager/core/auth/auth_repository.dart';
import 'package:c_biz_docs_manager/core/auth/credential_store.dart';
import 'package:c_biz_docs_manager/core/auth/native_credential_store.dart';
import 'package:c_biz_docs_manager/core/auth/web_credential_store.dart';
import 'package:c_biz_docs_manager/core/config/app_config.dart';
import 'package:c_biz_docs_manager/core/network/api_client.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

Future<void> bootstrap() async {
  WidgetsFlutterBinding.ensureInitialized();

  final config = AppConfig.fromEnvironment();
  final platform = kIsWeb ? AuthPlatform.web : AuthPlatform.native;
  final credentials = kIsWeb ? WebCredentialStore() : NativeCredentialStore();
  final accessTokens = InMemoryAccessTokenStore();
  final invalidator = AuthSessionInvalidator();
  final dio = Dio(BaseOptions(baseUrl: config.apiBaseUrl));

  late final AuthRepository authRepository;
  ApiClient(
    dio: dio,
    accessTokens: accessTokens,
    refreshSession: () => authRepository.restore(),
    clearSession: () =>
        _clearLocalSession(accessTokens, credentials, invalidator),
  );
  authRepository = DefaultAuthRepository(
    remote: DioAuthRemoteDataSource(dio),
    credentials: credentials,
    accessTokens: accessTokens,
    platform: platform,
  );

  runApp(
    ProviderScope(
      overrides: [
        // 应用级依赖在这里落地一次：会话作用域内的业务 Repository
        // 会复用同一个 Dio（它已被 ApiClient 装上鉴权拦截器），
        // 而不是各自再造一个没有令牌的客户端。
        dioProvider.overrideWithValue(dio),
        authRepositoryProvider.overrideWithValue(authRepository),
        authSessionInvalidatorProvider.overrideWithValue(invalidator),
      ],
      child: const CBizDocsApp(),
    ),
  );
}

Future<void> _clearLocalSession(
  AccessTokenStore accessTokens,
  CredentialStore credentials,
  AuthSessionInvalidator invalidator,
) async {
  accessTokens.clear();
  try {
    await credentials.clear();
  } finally {
    invalidator.invalidate();
  }
}
