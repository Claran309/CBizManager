import 'package:c_biz_docs_manager/core/auth/auth_controller.dart';
import 'package:c_biz_docs_manager/core/auth/auth_models.dart';
import 'package:c_biz_docs_manager/core/error/app_failure.dart';
import 'package:c_biz_docs_manager/core/presentation/failure_presenter.dart';
import 'package:c_biz_docs_manager/core/presentation/form_feedback.dart';
import 'package:c_biz_docs_manager/core/presentation/password_field.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

/// 邀请码注册页（组内子账号自助注册）。
///
/// 两条硬规则，都由服务端与领域层共同保证：
/// - **必须携带邀请码**：它是「允许加入这个组」的唯一凭证，没有它注册无从谈起；
/// - **注册不建立会话**：服务端不签发令牌，成功后仍停在未登录态，
///   用户必须自己用新账号登录一次。否则新人会被静默当成已登录，
///   顺手绕开登录页与强制改密两道关。
final class RegisterPage extends ConsumerStatefulWidget {
  const RegisterPage({super.key});

  @override
  ConsumerState<RegisterPage> createState() => _RegisterPageState();
}

final class _RegisterPageState extends ConsumerState<RegisterPage>
    with ServerFieldErrorsMixin<RegisterPage> {
  /// 本页渲染的字段名（与契约 `RegisterRequest` 一致）。
  ///
  /// `confirm_password` **不在其中**：它是纯粹的本地相等校验，
  /// 不进请求体，服务端也不会返回它的字段错误。
  @override
  Set<String> get formFieldNames => const <String>{
    'invitation_code',
    'username',
    'display_name',
    'password',
  };

  @override
  final GlobalKey<FormState> formKey = GlobalKey<FormState>();

  final TextEditingController _invitationCodeController =
      TextEditingController();
  final TextEditingController _usernameController = TextEditingController();
  final TextEditingController _displayNameController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  final TextEditingController _confirmPasswordController =
      TextEditingController();

  @override
  void dispose() {
    _invitationCodeController.dispose();
    _usernameController.dispose();
    _displayNameController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    super.dispose();
  }

  /// 确认密码：只做本地相等校验。
  ///
  /// 服务端不知道「确认密码」这个概念，所以这里没有服务端错误可优先，
  /// 也就不能用 [validateRequired]。
  String? _validateConfirmPassword(String? value) {
    if ((value ?? '').isEmpty) {
      return '请再次输入密码';
    }
    if (value != _passwordController.text) {
      return '两次输入的密码不一致';
    }
    return null;
  }

  Future<void> _submit() async {
    if (!(formKey.currentState?.validate() ?? false)) {
      return;
    }
    clearAllServerErrors();

    try {
      await ref
          .read(authControllerProvider.notifier)
          .register(
            RegistrationDraft(
              // 邀请码与账号名按「可以复制的文本」处理：前后空格几乎一定是
              // 粘贴时带进来的，留着它只会换来一个「邀请码无效」。
              invitationCode: _invitationCodeController.text.trim(),
              username: _usernameController.text.trim(),
              displayName: _displayNameController.text.trim(),
              // 密码不 trim：空格是合法密码字符，改动它会让用户
              // 「明明输对了却登不上」。
              password: _passwordController.text,
            ),
          );
    } on AppFailure catch (failure) {
      // Controller 把失败详情写进状态之后原样抛出 —— 只有异常能让调用方
      // 区分「注册成功」与「注册失败」，而成功与失败的去向完全不同。
      if (!mounted) {
        return;
      }
      final presentation = FailurePresenter.present(failure);
      if (!presentFieldErrors(presentation)) {
        showMessage(presentation.message);
      }
      return;
    }

    if (!mounted) {
      return;
    }
    // 成功：回登录页。用户名已经由 Controller 写进 `AuthState.loginPrefill`，
    // 登录页会在 initState 里把它预填好。
    // 用 go 而不是 push：注册页不该留在返回栈里 —— 「返回」回到一个
    // 已经用过的注册表单，只会让人怀疑自己是不是又注册了一次。
    context.go('/login');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isSubmitting = ref.watch(
      authControllerProvider.select((AuthState state) => state.isSubmitting),
    );

    return Scaffold(
      appBar: AppBar(
        title: const Text('注册新账号'),
        leading: IconButton(
          tooltip: '返回登录',
          onPressed: isSubmitting ? null : () => context.go('/login'),
          icon: const Icon(Icons.arrow_back),
        ),
      ),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Form(
                key: formKey,
                autovalidateMode: AutovalidateMode.onUserInteraction,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    Text(
                      '请向组主账号索要邀请码，一个邀请码只能注册一个账号。',
                      style: theme.textTheme.bodySmall,
                    ),
                    const SizedBox(height: 16),
                    TextFormField(
                      controller: _invitationCodeController,
                      decoration: const InputDecoration(
                        labelText: '邀请码',
                        border: OutlineInputBorder(),
                      ),
                      textInputAction: TextInputAction.next,
                      validator: (String? value) =>
                          validateRequired('invitation_code', value, '请输入邀请码'),
                      onChanged: (_) => clearServerError('invitation_code'),
                    ),
                    const SizedBox(height: 12),
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
                    TextFormField(
                      controller: _displayNameController,
                      decoration: const InputDecoration(
                        labelText: '姓名',
                        border: OutlineInputBorder(),
                      ),
                      textInputAction: TextInputAction.next,
                      validator: (String? value) =>
                          validateRequired('display_name', value, '请输入姓名'),
                      onChanged: (_) => clearServerError('display_name'),
                    ),
                    const SizedBox(height: 12),
                    PasswordField(
                      controller: _passwordController,
                      label: '密码',
                      helperText: '不少于 8 位',
                      textInputAction: TextInputAction.next,
                      // 长度下限 8 照抄契约（`minLength: 8`）。本地先拦一道，
                      // 用户不必为一个明确可知的规则白等一次往返。
                      validator: (String? value) =>
                          validateMinLength('password', value, 8, '密码不少于 8 位'),
                      onChanged: (_) => clearServerError('password'),
                    ),
                    const SizedBox(height: 12),
                    PasswordField(
                      controller: _confirmPasswordController,
                      label: '确认密码',
                      textInputAction: TextInputAction.done,
                      validator: _validateConfirmPassword,
                    ),
                    const SizedBox(height: 24),
                    FilledButton(
                      onPressed: isSubmitting ? null : _submit,
                      child: isSubmitting
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Text('注册'),
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
