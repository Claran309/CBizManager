import 'package:c_biz_docs_manager/core/auth/auth_models.dart';
import 'package:c_biz_docs_manager/core/auth/auth_repository.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

enum AuthPhase { restoring, authenticated, unauthenticated }

final class AuthState {
  const AuthState(this.phase, {this.session})
    : assert(
        phase != AuthPhase.authenticated || session != null,
        'Authenticated state requires a session',
      );

  final AuthPhase phase;
  final AuthSession? session;
}

/// Bootstrap must override this provider with the concrete repository.
final authRepositoryProvider = Provider<AuthRepository>((Ref ref) {
  throw StateError('AuthRepository has not been configured');
});

/// Bridges network refresh failures into Riverpod without coupling Dio to a
/// provider container.
final class AuthSessionInvalidator {
  final Set<void Function()> _listeners = <void Function()>{};

  void addListener(void Function() listener) => _listeners.add(listener);

  void removeListener(void Function() listener) => _listeners.remove(listener);

  void invalidate() {
    for (final listener in List<void Function()>.of(_listeners)) {
      listener();
    }
  }
}

final authSessionInvalidatorProvider = Provider<AuthSessionInvalidator>(
  (Ref ref) => AuthSessionInvalidator(),
);

final authControllerProvider = NotifierProvider<AuthController, AuthState>(
  AuthController.new,
);

/// Owns authentication state so pages and route guards never call Dio.
final class AuthController extends Notifier<AuthState> {
  @override
  AuthState build() {
    final invalidator = ref.read(authSessionInvalidatorProvider);
    invalidator.addListener(invalidateSession);
    ref.onDispose(() => invalidator.removeListener(invalidateSession));
    return const AuthState(AuthPhase.restoring);
  }

  Future<void> restore() async {
    state = const AuthState(AuthPhase.restoring);
    try {
      final session = await ref.read(authRepositoryProvider).restore();
      state = AuthState(AuthPhase.authenticated, session: session);
    } catch (_) {
      state = const AuthState(AuthPhase.unauthenticated);
    }
  }

  Future<void> login(String username, String password) async {
    final session = await ref
        .read(authRepositoryProvider)
        .login(username, password);
    state = AuthState(AuthPhase.authenticated, session: session);
  }

  Future<void> logout() async {
    try {
      await ref.read(authRepositoryProvider).logout();
    } finally {
      state = const AuthState(AuthPhase.unauthenticated);
    }
  }

  /// Refresh cleanup already removed local credentials before this callback.
  void invalidateSession() {
    state = const AuthState(AuthPhase.unauthenticated);
  }
}
