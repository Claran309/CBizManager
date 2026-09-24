import 'package:c_biz_docs_manager/app/app.dart';
import 'package:c_biz_docs_manager/app/router.dart';
import 'package:c_biz_docs_manager/app/session_scope.dart';
import 'package:c_biz_docs_manager/core/auth/auth_controller.dart';
import 'package:c_biz_docs_manager/core/auth/auth_models.dart';
import 'package:c_biz_docs_manager/core/auth/auth_repository.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/auth_fixtures.dart';

/// 只关心会话本身的路由守卫替身；注册与改密不属于本文件的关注点。
final class StaticAuthRepository implements AuthRepository {
  const StaticAuthRepository(this.session);

  final AuthSession session;

  @override
  Future<AuthSession> login(String username, String password) async => session;

  @override
  Future<void> logout() async {}

  @override
  Future<AuthSession> restore() async => session;

  @override
  Future<RegistrationResult> register(RegistrationDraft draft) =>
      throw UnsupportedError('路由守卫测试不覆盖注册');

  @override
  Future<AuthSession> changePassword(
    String currentPassword,
    String newPassword,
  ) => throw UnsupportedError('路由守卫测试不覆盖改密');
}

void main() {
  test('restoring state stays on splash without redirect loops', () {
    const state = AuthState(AuthPhase.restoring);

    expect(authRedirect(state, '/home'), '/splash');
    expect(authRedirect(state, '/splash'), isNull);
  });

  test('unauthenticated routes stay on login and protect app pages', () {
    const state = AuthState(AuthPhase.unauthenticated);

    expect(authRedirect(state, '/home'), '/login');
    expect(authRedirect(state, '/login'), isNull);
  });

  test('password change is mandatory before authenticated app routes', () {
    final state = AuthState(
      AuthPhase.authenticated,
      session: ownerSession(mustChangePassword: true),
    );

    expect(authRedirect(state, '/home'), '/change-password');
    expect(authRedirect(state, '/change-password'), isNull);
  });

  test('normal authentication enters home and leaves home stable', () {
    final state = AuthState(AuthPhase.authenticated, session: ownerSession());

    expect(authRedirect(state, '/login'), '/home');
    expect(authRedirect(state, '/home'), isNull);
  });

  testWidgets('application restore drives the real router to home', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          // 这里刻意照着 bootstrap 的方式装配：一旦进入已登录态，
          // 应用外壳就会建立会话作用域，而作用域需要应用级的 Dio。
          // 不提供它，就说明"真实装配缺少应用级依赖"，应当当场失败。
          dioProvider.overrideWithValue(
            Dio(BaseOptions(baseUrl: 'https://api.example.test')),
          ),
          authRepositoryProvider.overrideWithValue(
            StaticAuthRepository(ownerSession()),
          ),
        ],
        child: const CBizDocsApp(),
      ),
    );

    await tester.pumpAndSettle();

    expect(find.text('首页'), findsOneWidget);
  });
}
