import 'package:c_biz_docs_manager/core/auth/auth_controller.dart';
import 'package:c_biz_docs_manager/core/presentation/failure_presenter.dart';
import 'package:c_biz_docs_manager/core/presentation/form_feedback.dart';
import 'package:c_biz_docs_manager/core/presentation/password_field.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

/// 登录页。
///
/// 未登录态下的默认落点。注册入口（`/register`）同样属于公开区域，
/// 但注册成功后要回到这里并**预填用户名**，而不是自动进入业务区 ——
/// 注册不签发令牌，用户必须自己用新账号登录一次。
///
/// 本页不持有任何业务入口：登录成功后的去向完全由路由守卫决定
/// （角色首页 / 强制改密页），页面自己不做角色判断。
final class LoginPage extends ConsumerStatefulWidget {
  const LoginPage({super.key});

  @override
  ConsumerState<LoginPage> createState() => _LoginPageState();
}

final class _LoginPageState extends ConsumerState<LoginPage>
    with ServerFieldErrorsMixin<LoginPage> {
  /// 本页渲染的字段名（与契约 `LoginRequest` 一致）。
  @override
  Set<String> get formFieldNames => const <String>{'username', 'password'};

  @override
  final GlobalKey<FormState> formKey = GlobalKey<FormState>();

  final TextEditingController _usernameController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();

  @override
  void initState() {
    super.initState();
    // 注册成功后会被带回本页，用户名必须已经填好 —— 让人刚设完账号又要手打一遍
    // 是最没必要的摩擦。
    final prefill = ref.read(authControllerProvider).loginPrefill;
    if (prefill != null && prefill.isNotEmpty) {
      _usernameController.text = prefill;
    }
  }

  @override
  void dispose() {
    // Controller 必须显式释放：它们持有的是原生文本编辑资源。
    // 密码只活在这一个 Controller 里，随页面一起消失，不进任何 Provider。
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!(formKey.currentState?.validate() ?? false)) {
      return;
    }
    // 表单内容变了，上一轮的服务端错误一律作废。
    clearAllServerErrors();

    await ref
        .read(authControllerProvider.notifier)
        .login(
          _usernameController.text.trim(),
          // 密码不 trim：前导 / 尾随空格是合法密码字符，改动它会让主人
          // 「明明输对了却登不上」。
          _passwordController.text,
        );
    if (!mounted) {
      return;
    }

    final auth = ref.read(authControllerProvider);
    // 成功时**不自己导航**：认证状态一变，路由守卫就会把地址换成角色首页
    // （GoRouter 的 refreshListenable 订阅了 AuthState）。这里再 go 一次
    // 会和守卫抢跑，出现两次导航甚至闪屏。
    if (auth.phase == AuthPhase.authenticated) {
      return;
    }

    // 「本次是否失败」靠 failure 非空判定：login 开工前会清掉旧的失败，
    // 所以读到的非空值一定属于这一次。
    final failure = auth.failure;
    if (failure == null) {
      return;
    }
    final presentation = FailurePresenter.present(failure);
    // 能挂到输入框下方的（比如「账号不能为空」）就不再说第二遍。
    if (!presentFieldErrors(presentation)) {
      showMessage(presentation.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isSubmitting = ref.watch(
      authControllerProvider.select((AuthState state) => state.isSubmitting),
    );

    return Scaffold(
      body: SafeArea(
        child: Center(
          // 窄屏 + 软键盘弹出时可用高度会变小，套一层滚动容器才不会溢出。
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              // 限宽：桌面端把输入框拉满整屏，一行文字长到眼睛要来回扫。
              constraints: const BoxConstraints(maxWidth: 420),
              child: Form(
                key: formKey,
                // 用户碰过某个字段之后就一直校验它：比每次提交才报错更及时，
                // 也不会在用户还没开始填的时候就满屏红字。
                autovalidateMode: AutovalidateMode.onUserInteraction,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    Text(
                      '登录',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.headlineSmall,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '请使用组内下发的账号登录。',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodySmall,
                    ),
                    const SizedBox(height: 24),
                    TextFormField(
                      controller: _usernameController,
                      decoration: const InputDecoration(
                        labelText: '登录账号',
                        border: OutlineInputBorder(),
                      ),
                      textInputAction: TextInputAction.next,
                      validator: (String? value) =>
                          validateRequired('username', value, '请输入登录账号'),
                      onChanged: (_) => clearServerError('username'),
                    ),
                    const SizedBox(height: 12),
                    PasswordField(
                      controller: _passwordController,
                      label: '密码',
                      textInputAction: TextInputAction.done,
                      validator: (String? value) =>
                          validateRequired('password', value, '请输入密码'),
                      onChanged: (_) => clearServerError('password'),
                    ),
                    const SizedBox(height: 24),
                    FilledButton(
                      // 提交中禁用是防重复提交的最后一道闸：Controller 里已经
                      // 用「判空 + 置位不夹 await」挡住并发，这里再从交互上
                      // 让用户看见「正在处理」。
                      onPressed: isSubmitting ? null : _submit,
                      child: isSubmitting
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Text('登录'),
                    ),
                    const SizedBox(height: 8),
                    TextButton(
                      onPressed: isSubmitting
                          ? null
                          : () => context.go('/register'),
                      child: const Text('注册新账号'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
