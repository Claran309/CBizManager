import 'dart:async';

import 'package:c_biz_docs_manager/app/router.dart';
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
    return MaterialApp.router(
      title: 'CBizDocsManager',
      routerConfig: router,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF246B56)),
        useMaterial3: true,
      ),
    );
  }
}
