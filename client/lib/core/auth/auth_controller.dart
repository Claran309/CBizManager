import 'package:c_biz_docs_manager/core/auth/auth_models.dart';
import 'package:c_biz_docs_manager/core/auth/auth_repository.dart';
import 'package:c_biz_docs_manager/core/error/app_failure.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

enum AuthPhase { restoring, authenticated, unauthenticated }

final class AuthState {
  const AuthState(
    this.phase, {
    this.session,
    this.isSubmitting = false,
    this.failure,
    this.loginPrefill,
  }) : assert(
         phase != AuthPhase.authenticated || session != null,
         'Authenticated state requires a session',
       ),
       assert(
         phase == AuthPhase.authenticated || session == null,
         'Only an authenticated state may carry a session',
       );

  final AuthPhase phase;
  final AuthSession? session;

  /// 登录 / 注册 / 改密的提交中标记：页面据此禁用按钮，避免重复提交。
  final bool isSubmitting;

  /// 最近一次认证操作的失败详情，供表单内联渲染。
  /// 由 [AuthController.clearFailure] 或下一次操作清除。
  final AppFailure? failure;

  /// 注册成功带回来的用户名，用于把登录页的用户名输入框预填好。
  final String? loginPrefill;
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

  /// 登录并建立会话。
  ///
  /// **失败时把详情写进状态、把异常吞掉**，而不是抛给页面：页面在 `await`
  /// 之后读一次状态就能拿到失败原因，不需要在 UI 层再包一层 `try/catch` ——
  /// 那一层迟早会有人忘了写，而「点了登录却什么也没提示」是最难受的一种坏。
  /// 「本次是否失败」不用另开返回值：开工时会重建一个不带 failure 的状态，
  /// 所以 `await` 之后读到的非空 `failure` 一定属于这一次。
  ///
  /// 失败后落在 [AuthPhase.unauthenticated]，**不是**保留原来的 phase。
  /// 与 [changePassword] 不同，这里没有「必须留住已有会话」的包袱：
  /// 登录的语义就是「试图建立会话」，没建立起来就一定是未登录。
  /// 保留 `restoring` 尤其危险 —— 守卫只允许 `restoring` 停在 `/splash`，
  /// 用户会被永久留在启动页上。
  Future<void> login(String username, String password) async {
    // 预填的用户名要留住：一次输错密码不该顺手把登录框里的账号也抹掉。
    final prefill = state.loginPrefill;
    state = AuthState(
      AuthPhase.unauthenticated,
      isSubmitting: true,
      loginPrefill: prefill,
    );
    try {
      final session = await ref
          .read(authRepositoryProvider)
          .login(username, password);
      state = AuthState(AuthPhase.authenticated, session: session);
    } on AppFailure catch (failure) {
      state = AuthState(
        AuthPhase.unauthenticated,
        failure: failure,
        loginPrefill: prefill,
      );
    }
  }

  /// 用邀请码注册组内子账号。
  ///
  /// 注册**不建立会话**：成功后仍停在未登录，只把用户名列进
  /// [AuthState.loginPrefill] 供登录页预填。
  ///
  /// 失败时把详情写进状态后**原样抛出**。这里与 [changePassword] 的处理方式不同，
  /// 是因为调用方必须能区分成功与失败（成功要跳回登录页），而返回类型
  /// [RegistrationResult] 没法用空值表达失败，只能靠异常传递。
  Future<RegistrationResult> register(RegistrationDraft draft) async {
    assert(
      state.phase != AuthPhase.authenticated,
      '注册只对未登录用户开放；已登录状态下调用属于流程错误',
    );
    final prefill = state.loginPrefill;
    state = AuthState(
      AuthPhase.unauthenticated,
      isSubmitting: true,
      loginPrefill: prefill,
    );
    try {
      final result = await ref.read(authRepositoryProvider).register(draft);
      state = AuthState(
        AuthPhase.unauthenticated,
        loginPrefill: result.username,
      );
      return result;
    } on AppFailure catch (failure) {
      // 失败的注册不能留下预填值，否则登录框会填上一个根本没建成的账号。
      state = AuthState(
        AuthPhase.unauthenticated,
        failure: failure,
        loginPrefill: prefill,
      );
      rethrow;
    }
  }

  /// 修改当前账号密码，成功后用新的身份快照整体替换会话。
  ///
  /// 失败时**保留原已登录会话**：用户依旧是合法登录态，只是这次改密没成功，
  /// 所以不能被踢回登录页（那会让人以为自己被登出了）。
  Future<void> changePassword(
    String currentPassword,
    String newPassword,
  ) async {
    final phase = state.phase;
    final previous = state.session;
    state = AuthState(phase, session: previous, isSubmitting: true);
    try {
      final session = await ref
          .read(authRepositoryProvider)
          .changePassword(currentPassword, newPassword);
      state = AuthState(AuthPhase.authenticated, session: session);
    } on AppFailure catch (failure) {
      state = AuthState(phase, session: previous, failure: failure);
    }
  }

  /// 只清掉失败详情，其余状态（会话、预填、提交中标记）原样保留。
  void clearFailure() {
    if (state.failure == null) {
      return;
    }
    state = AuthState(
      state.phase,
      session: state.session,
      isSubmitting: state.isSubmitting,
      loginPrefill: state.loginPrefill,
    );
  }

  Future<void> logout() async {
    try {
      await ref.read(authRepositoryProvider).logout();
    } finally {
      // 登出要连失败详情与预填一起清掉：它们是上一次流程的残留，
      // 留到下一个人的登录页上就是信息泄漏。
      state = const AuthState(AuthPhase.unauthenticated);
    }
  }

  /// Refresh cleanup already removed local credentials before this callback.
  void invalidateSession() {
    state = const AuthState(AuthPhase.unauthenticated);
  }
}
