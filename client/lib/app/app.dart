import 'dart:async';

import 'package:c_biz_docs_manager/app/router.dart';
import 'package:c_biz_docs_manager/app/session_scope.dart';
import 'package:c_biz_docs_manager/core/auth/auth_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final class CBizDocsApp extends ConsumerStatefulWidget {
  const CBizDocsApp({super.key});

  @override
  ConsumerState<CBizDocsApp> createState() => _CBizDocsAppState();
}

final class _CBizDocsAppState extends ConsumerState<CBizDocsApp> {
  @override
  void initState() {
    super.initState();
    unawaited(
      Future<void>.microtask(() {
        if (mounted) {
          return ref.read(authControllerProvider.notifier).restore();
        }
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    final router = ref.watch(routerProvider);
    // 只关心"当前有没有已登录会话"，不关心 isSubmitting / failure 这类
    // 表单态——它们变化时不该重建整个应用外壳。
    final session = ref.watch(
      authControllerProvider.select((AuthState state) => state.session),
    );

    final app = MaterialApp.router(
      title: 'CBizDocsManager',
      routerConfig: router,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF246B56)),
        useMaterial3: true,
      ),
    );

    final activeSession = session;
    if (activeSession == null) {
      // 未登录（会话恢复中、已登出、或改密前尚未建立完整会话）时**不**装配
      // 任何会话级依赖：此时界面上只有 splash / login，
      // 它们没有任何理由能读到某个组的数据。
      return app;
    }

    // 已登录：把整个应用包进会话作用域。会话键变化或登出时，
    // 这个 ProviderScope 会被卸载，里面的 Repository / Controller 一起销毁。
    return AuthenticatedSessionScope(session: activeSession, child: app);
  }
}
