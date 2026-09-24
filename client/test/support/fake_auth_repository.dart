import 'dart:async';

import 'package:c_biz_docs_manager/core/auth/auth_models.dart';
import 'package:c_biz_docs_manager/core/auth/auth_repository.dart';
import 'package:c_biz_docs_manager/core/error/app_failure.dart';

import 'auth_fixtures.dart';

/// 可编程的认证仓储替身。
///
/// 与其它模块的假仓储同一套优先级：**排队响应 → 一次性错误 → 常驻错误 →
/// 默认结果**。
/// - 排队响应：往队里塞一个未完成的 `Completer.future`，就能把请求挂在
///   「提交中」，用来断言按钮被禁用而不用真的等一次网络往返；
/// - 一次性错误：造「第一次失败、第二次成功」，例如「密码输错一次再改对」；
/// - 常驻错误：验证页面每次都给出提示，而不是只在第一次。
///
/// 所有入参都会原样记下来：认证这几个接口的参数里有密码，用例必须能
/// 逐字断言「到底提交了什么、有没有多提交一个字段」，只测「调用过一次」是不够的。
final class FakeAuthRepository implements AuthRepository {
  FakeAuthRepository({AuthSession? session})
    : session = session ?? ownerSession();

  /// 登录 / 恢复 / 改密成功时交回的会话。
  AuthSession session;

  /// 非空时 [restore] 直接抛出它 —— 模拟「本地没有可用凭据」，即未登录。
  AppFailure? restoreFailure;

  /// 一次性失败：被取用一次后自动清空。
  AppFailure? nextLoginFailure;
  AppFailure? nextRegisterFailure;
  AppFailure? nextChangePasswordFailure;

  /// 常驻失败：每次调用都抛。
  AppFailure? loginFailure;
  AppFailure? registerFailure;
  AppFailure? changePasswordFailure;

  /// 排队响应：非空时优先取队首，**压过**错误与默认结果。
  final List<Future<AuthSession>> queuedLogins = <Future<AuthSession>>[];

  final List<({String username, String password})> loginCalls =
      <({String username, String password})>[];
  final List<RegistrationDraft> registerCalls = <RegistrationDraft>[];
  final List<({String currentPassword, String newPassword})>
  changePasswordCalls = <({String currentPassword, String newPassword})>[];
  int restoreCalls = 0;
  int logoutCalls = 0;

  @override
  Future<AuthSession> login(String username, String password) {
    loginCalls.add((username: username, password: password));
    if (queuedLogins.isNotEmpty) {
      return queuedLogins.removeAt(0);
    }
    final failure = _takeOnce(
      once: nextLoginFailure,
      clearOnce: () => nextLoginFailure = null,
      always: loginFailure,
    );
    if (failure != null) {
      return Future<AuthSession>.error(failure);
    }
    return Future<AuthSession>.value(session);
  }

  @override
  Future<AuthSession> restore() async {
    restoreCalls++;
    final failure = restoreFailure;
    if (failure != null) {
      throw failure;
    }
    return session;
  }

  @override
  Future<RegistrationResult> register(RegistrationDraft draft) {
    registerCalls.add(draft);
    final failure = _takeOnce(
      once: nextRegisterFailure,
      clearOnce: () => nextRegisterFailure = null,
      always: registerFailure,
    );
    if (failure != null) {
      return Future<RegistrationResult>.error(failure);
    }
    // 注册**不签发令牌**：这里也照契约只回摘要，不回会话。
    return Future<RegistrationResult>.value(
      RegistrationResult(username: draft.username, groupName: 'Finance'),
    );
  }

  @override
  Future<AuthSession> changePassword(
    String currentPassword,
    String newPassword,
  ) {
    changePasswordCalls.add((
      currentPassword: currentPassword,
      newPassword: newPassword,
    ));
    final failure = _takeOnce(
      once: nextChangePasswordFailure,
      clearOnce: () => nextChangePasswordFailure = null,
      always: changePasswordFailure,
    );
    if (failure != null) {
      return Future<AuthSession>.error(failure);
    }
    // 改密后服务端用同一个令牌重读身份，`must_change_password` 随之清零。
    return Future<AuthSession>.value(session);
  }

  @override
  Future<void> logout() async {
    logoutCalls++;
  }

  /* ---------------------------------------------------------------- 内部 */

  /// 「一次性错误 → 常驻错误」二选一，取走一次性错误后把它清空。
  AppFailure? _takeOnce({
    required AppFailure? once,
    required void Function() clearOnce,
    required AppFailure? always,
  }) {
    if (once != null) {
      clearOnce();
      return once;
    }
    return always;
  }
}
