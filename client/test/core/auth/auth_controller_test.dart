import 'package:c_biz_docs_manager/core/auth/auth_controller.dart';
import 'package:c_biz_docs_manager/core/auth/auth_models.dart';
import 'package:c_biz_docs_manager/core/auth/auth_repository.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/auth_fixtures.dart';

final class FakeControllerAuthRepository implements AuthRepository {
  AuthSession session = ownerSession();
  Object? restoreError;
  Object? logoutError;
  var loginCalls = 0;
  var restoreCalls = 0;
  var logoutCalls = 0;

  @override
  Future<AuthSession> login(String username, String password) async {
    loginCalls++;
    return session;
  }

  @override
  Future<AuthSession> restore() async {
    restoreCalls++;
    final error = restoreError;
    if (error != null) {
      throw error;
    }
    return session;
  }

  @override
  Future<void> logout() async {
    logoutCalls++;
    final error = logoutError;
    if (error != null) {
      throw error;
    }
  }
}

ProviderContainer createContainer(
  FakeControllerAuthRepository repository, {
  AuthSessionInvalidator? invalidator,
}) {
  final container = ProviderContainer(
    overrides: [
      authRepositoryProvider.overrideWithValue(repository),
      if (invalidator != null)
        authSessionInvalidatorProvider.overrideWithValue(invalidator),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  test('restore moves from restoring to authenticated on success', () async {
    final repository = FakeControllerAuthRepository();
    final container = createContainer(repository);

    expect(container.read(authControllerProvider).phase, AuthPhase.restoring);
    await container.read(authControllerProvider.notifier).restore();

    final state = container.read(authControllerProvider);
    expect(state.phase, AuthPhase.authenticated);
    expect(state.session?.accessToken, 'access');
    expect(repository.restoreCalls, 1);
  });

  test('restore failure becomes unauthenticated', () async {
    final repository = FakeControllerAuthRepository()
      ..restoreError = StateError('expired');
    final container = createContainer(repository);

    await container.read(authControllerProvider.notifier).restore();

    expect(
      container.read(authControllerProvider).phase,
      AuthPhase.unauthenticated,
    );
  });

  test(
    'login authenticates and logout clears state despite remote error',
    () async {
      final repository = FakeControllerAuthRepository();
      final container = createContainer(repository);
      final controller = container.read(authControllerProvider.notifier);

      await controller.login('user', 'password');
      expect(
        container.read(authControllerProvider).phase,
        AuthPhase.authenticated,
      );

      repository.logoutError = StateError('offline');
      await expectLater(controller.logout(), throwsStateError);
      expect(
        container.read(authControllerProvider).phase,
        AuthPhase.unauthenticated,
      );
    },
  );

  test('refresh invalidation clears the authenticated state', () async {
    final repository = FakeControllerAuthRepository();
    final invalidator = AuthSessionInvalidator();
    final container = createContainer(repository, invalidator: invalidator);
    final controller = container.read(authControllerProvider.notifier);
    await controller.login('user', 'password');

    invalidator.invalidate();

    expect(
      container.read(authControllerProvider).phase,
      AuthPhase.unauthenticated,
    );
  });
}
