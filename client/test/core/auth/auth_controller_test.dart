import 'dart:async';

import 'package:c_biz_docs_manager/core/auth/auth_controller.dart';
import 'package:c_biz_docs_manager/core/auth/auth_models.dart';
import 'package:c_biz_docs_manager/core/auth/auth_repository.dart';
import 'package:c_biz_docs_manager/core/error/app_failure.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/auth_fixtures.dart';

final class FakeControllerAuthRepository implements AuthRepository {
  AuthSession session = ownerSession();
  AuthSession changedSession = AuthSession(
    accessToken: 'access',
    profile: ownerProfile(),
  );
  Object? restoreError;
  Object? logoutError;
  Object? registerError;
  Object? changePasswordError;
  var loginCalls = 0;
  var restoreCalls = 0;
  var logoutCalls = 0;
  var registerCalls = 0;
  var changePasswordCalls = 0;
  RegistrationResult registration = const RegistrationResult(
    username: 'sales',
    groupName: 'Finance',
  );

  /// 非空时让 [register] 挂起，用来观察提交中的状态。
  Completer<void>? registerGate;

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
  Future<RegistrationResult> register(RegistrationDraft draft) async {
    registerCalls++;
    final gate = registerGate;
    if (gate != null) {
      await gate.future;
    }
    final error = registerError;
    if (error != null) {
      throw error;
    }
    return registration;
  }

  @override
  Future<AuthSession> changePassword(
    String currentPassword,
    String newPassword,
  ) async {
    changePasswordCalls++;
    final error = changePasswordError;
    if (error != null) {
      throw error;
    }
    return changedSession;
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

  test('注册成功保持未登录，并把用户名预填给登录页', () async {
    final repository = FakeControllerAuthRepository();
    final container = createContainer(repository);
    final controller = container.read(authControllerProvider.notifier);

    final result = await controller.register(_draft);

    expect(result.username, 'sales');
    expect(repository.registerCalls, 1);
    final state = container.read(authControllerProvider);
    // 注册不签发令牌，流程结束后仍停在未登录：用户必须自己用新账号登录一次。
    expect(state.phase, AuthPhase.unauthenticated);
    expect(state.session, isNull);
    expect(state.loginPrefill, 'sales');
    expect(state.isSubmitting, isFalse);
    expect(state.failure, isNull);
  });

  test('注册进行中标记提交态，防止用户重复提交', () async {
    final repository = FakeControllerAuthRepository()
      ..registerGate = Completer<void>();
    final container = createContainer(repository);
    final controller = container.read(authControllerProvider.notifier);

    final pending = controller.register(_draft);
    await Future<void>.delayed(Duration.zero);
    expect(container.read(authControllerProvider).isSubmitting, isTrue);

    repository.registerGate!.complete();
    await pending;
    expect(container.read(authControllerProvider).isSubmitting, isFalse);
  });

  test('注册失败把失败详情留在状态里，并原样抛给页面', () async {
    const failure = ValidationFailure('注册信息有误', <String, String>{
      'username': '该用户名已被占用',
    });
    final repository = FakeControllerAuthRepository()..registerError = failure;
    final container = createContainer(repository);
    final controller = container.read(authControllerProvider.notifier);

    await expectLater(controller.register(_draft), throwsA(same(failure)));

    final state = container.read(authControllerProvider);
    expect(state.failure, same(failure));
    expect(state.phase, AuthPhase.unauthenticated);
    expect(state.isSubmitting, isFalse);
    // 失败的注册不该留下任何预填值，否则登录框会填上一个没建成的账号。
    expect(state.loginPrefill, isNull);
  });

  test('改密成功替换完整会话，强制改密标记随之清零', () async {
    final repository = FakeControllerAuthRepository()
      ..session = ownerSession(mustChangePassword: true);
    final container = createContainer(repository);
    final controller = container.read(authControllerProvider.notifier);
    await controller.login('owner', 'password');
    expect(
      container.read(authControllerProvider).session?.mustChangePassword,
      isTrue,
    );

    await controller.changePassword('old-password', 'new-password');

    final state = container.read(authControllerProvider);
    expect(repository.changePasswordCalls, 1);
    expect(state.phase, AuthPhase.authenticated);
    expect(state.session?.profile.mustChangePassword, isFalse);
    expect(state.session?.scopeKey, '11:7:group_owner:owner:false:');
    expect(state.failure, isNull);
    expect(state.isSubmitting, isFalse);
  });

  test('改密失败保留原已登录会话，只把失败详情写进状态', () async {
    const failure = UnauthenticatedFailure('当前密码错误');
    final repository = FakeControllerAuthRepository()
      ..session = ownerSession(mustChangePassword: true)
      ..changePasswordError = failure;
    final container = createContainer(repository);
    final controller = container.read(authControllerProvider.notifier);
    await controller.login('owner', 'password');

    await controller.changePassword('wrong-password', 'new-password');

    final state = container.read(authControllerProvider);
    // 改密失败不能把用户踢回登录页：会话依然有效，只是这次操作没成功。
    expect(state.phase, AuthPhase.authenticated);
    expect(state.session?.mustChangePassword, isTrue);
    expect(state.failure, same(failure));
    expect(state.isSubmitting, isFalse);
  });

  test('clearFailure 只清失败详情，不影响其它状态', () async {
    final repository = FakeControllerAuthRepository()
      ..registerError = const ValidationFailure('注册信息有误', <String, String>{
        'username': '该用户名已被占用',
      });
    final container = createContainer(repository);
    final controller = container.read(authControllerProvider.notifier);
    await expectLater(
      controller.register(_draft),
      throwsA(isA<ValidationFailure>()),
    );

    controller.clearFailure();

    final state = container.read(authControllerProvider);
    expect(state.failure, isNull);
    expect(state.phase, AuthPhase.unauthenticated);
    expect(state.isSubmitting, isFalse);
  });

  test('登出清空会话、失败详情与预填用户名', () async {
    final repository = FakeControllerAuthRepository();
    final container = createContainer(repository);
    final controller = container.read(authControllerProvider.notifier);

    await controller.register(_draft);
    expect(container.read(authControllerProvider).loginPrefill, 'sales');

    await controller.login('sales', 'password123');
    await controller.logout();

    final state = container.read(authControllerProvider);
    expect(state.phase, AuthPhase.unauthenticated);
    expect(state.session, isNull);
    expect(state.failure, isNull);
    // 预填是「刚注册完」这一次流程的产物，登出后不应该继续残留。
    expect(state.loginPrefill, isNull);
  });

  test('会话失效回调同样清空会话、失败详情与预填用户名', () async {
    final repository = FakeControllerAuthRepository();
    final invalidator = AuthSessionInvalidator();
    final container = createContainer(repository, invalidator: invalidator);
    final controller = container.read(authControllerProvider.notifier);

    await controller.register(_draft);
    await controller.login('sales', 'password123');

    invalidator.invalidate();

    final state = container.read(authControllerProvider);
    expect(state.phase, AuthPhase.unauthenticated);
    expect(state.session, isNull);
    expect(state.loginPrefill, isNull);
    expect(state.failure, isNull);
  });
}

const _draft = RegistrationDraft(
  invitationCode: 'INV-1',
  username: 'sales',
  displayName: 'Sales',
  password: 'password123',
);
