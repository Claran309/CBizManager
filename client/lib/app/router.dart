import 'package:c_biz_docs_manager/core/auth/auth_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

String? authRedirect(AuthState auth, String location) {
  if (auth.phase == AuthPhase.restoring) {
    return location == '/splash' ? null : '/splash';
  }
  if (auth.phase == AuthPhase.unauthenticated) {
    return location == '/login' ? null : '/login';
  }
  if (auth.session!.mustChangePassword) {
    return location == '/change-password' ? null : '/change-password';
  }
  if (location == '/splash' ||
      location == '/login' ||
      location == '/change-password') {
    return '/home';
  }
  return null;
}

final routerProvider = Provider<GoRouter>((Ref ref) {
  final refresh = _AuthRouterRefresh(ref);
  ref.onDispose(refresh.dispose);
  return GoRouter(
    initialLocation: '/splash',
    refreshListenable: refresh,
    redirect: (BuildContext context, GoRouterState state) =>
        authRedirect(ref.read(authControllerProvider), state.matchedLocation),
    routes: <RouteBase>[
      GoRoute(
        path: '/splash',
        builder: (BuildContext context, GoRouterState state) =>
            const _RouteShell(label: '正在恢复会话'),
      ),
      GoRoute(
        path: '/login',
        builder: (BuildContext context, GoRouterState state) =>
            const _RouteShell(label: '登录'),
      ),
      GoRoute(
        path: '/change-password',
        builder: (BuildContext context, GoRouterState state) =>
            const _RouteShell(label: '修改密码'),
      ),
      GoRoute(
        path: '/home',
        builder: (BuildContext context, GoRouterState state) =>
            const _RouteShell(label: '首页'),
      ),
    ],
  );
});

final class _AuthRouterRefresh extends ChangeNotifier {
  _AuthRouterRefresh(Ref ref) {
    _subscription = ref.listen<AuthState>(authControllerProvider, (
      AuthState? previous,
      AuthState next,
    ) {
      notifyListeners();
    });
  }

  late final ProviderSubscription<AuthState> _subscription;

  @override
  void dispose() {
    _subscription.close();
    super.dispose();
  }
}

final class _RouteShell extends StatelessWidget {
  const _RouteShell({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Scaffold(body: Center(child: Text(label)));
  }
}
