import 'package:c_biz_docs_manager/app/app.dart';
import 'package:c_biz_docs_manager/app/router.dart';
import 'package:c_biz_docs_manager/core/auth/auth_controller.dart';
import 'package:c_biz_docs_manager/core/auth/auth_models.dart';
import 'package:c_biz_docs_manager/core/auth/auth_repository.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

final class StaticAuthRepository implements AuthRepository {
  const StaticAuthRepository(this.session);

  final AuthSession session;

  @override
  Future<AuthSession> login(String username, String password) async => session;

  @override
  Future<void> logout() async {}

  @override
  Future<AuthSession> restore() async => session;
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
    const state = AuthState(
      AuthPhase.authenticated,
      session: AuthSession(accessToken: 'access', mustChangePassword: true),
    );

    expect(authRedirect(state, '/home'), '/change-password');
    expect(authRedirect(state, '/change-password'), isNull);
  });

  test('normal authentication enters home and leaves home stable', () {
    const state = AuthState(
      AuthPhase.authenticated,
      session: AuthSession(accessToken: 'access'),
    );

    expect(authRedirect(state, '/login'), '/home');
    expect(authRedirect(state, '/home'), isNull);
  });

  testWidgets('application restore drives the real router to home', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          authRepositoryProvider.overrideWithValue(
            const StaticAuthRepository(AuthSession(accessToken: 'access')),
          ),
        ],
        child: const CBizDocsApp(),
      ),
    );

    await tester.pumpAndSettle();

    expect(find.text('首页'), findsOneWidget);
  });
}
