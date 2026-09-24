import 'package:c_biz_docs_manager/core/auth/auth_controller.dart';
import 'package:c_biz_docs_manager/core/presentation/failure_presenter.dart';
import 'package:c_biz_docs_manager/core/presentation/form_feedback.dart';
import 'package:c_biz_docs_manager/core/presentation/password_field.dart';
import 'package:c_biz_docs_manager/core/presentation/responsive_scaffold.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 修改密码页。
///
/// 两种进入方式，同一个页面：
/// - **强制改密**：`must_change_password` 为真时，守卫把用户锁在本页，
///   除「退出登录」外任何业务地址都会被重定向回来；
/// - 自愿改密：将来可以从首页进来自行修改。
///
/// **本页刻意不渲染租户导航**（传空列表）：强制改密期间所有业务入口都会被守卫
/// 弹回本页，摆一排点了就回来的导航项，等于让用户以为功能坏了。
///
/// 改密成功后**不自己导航**：Controller 会用同一个令牌重读 `/auth/me`、
/// 拿到 `must_change_password=false` 的新快照，守卫随即把地址换成角色首页。
final class ChangePasswordPage extends ConsumerStatefulWidget {
  const ChangePasswordPage({super.key});

  @override
  ConsumerState<ChangePasswordPage> createState() => _ChangePasswordPageState();
}

final class _ChangePasswordPageState extends ConsumerState<ChangePasswordPage>
    with ServerFieldErrorsMixin<ChangePasswordPage> {
  /// 本页渲染的字段名（与契约 `ChangePasswordRequest` 一致）。
  ///
  /// `confirm_password` 不在其中：它是纯粹的本地相等校验，不进请求体。
  @override
  Set<String> get formFieldNames => const <String>{
    'current_password',
    'new_password',
  };

  @override
  final GlobalKey<FormState> formKey = GlobalKey<FormState>();

  final TextEditingController _currentPasswordController =
      TextEditingController();
  final TextEditingController _newPasswordController = TextEditingController();
  final TextEditingController _confirmPasswordController =
      TextEditingController();

  @override
  void dispose() {
    _currentPasswordController.dispose();
    _newPasswordController.dispose();
    _confirmPasswordController.dispose();
    super.dispose();
  }

  String? _validateConfirmPassword(String? value) {
    if ((value ?? '').isEmpty) {
      return '请再次输入新密码';
    }
    if (value != _newPasswordController.text) {
      return '两次输入的新密码不一致';
    }
    return null;
  }

  Future<void> _confirmLogout() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('退出登录'),
        content: const Text('退出后需要重新输入账号密码。确定退出吗？'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('退出'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) {
      return;
    }
    // 不改密码也必须能退出：否则一个拿不到旧密码的用户就被永久锁在这个页面上了。
    await ref.read(authControllerProvider.notifier).logout();
  }

  Future<void> _submit() async {
    if (!(formKey.currentState?.validate() ?? false)) {
      return;
    }
    clearAllServerErrors();

    await ref
        .read(authControllerProvider.notifier)
        .changePassword(
          _currentPasswordController.text,
          _newPasswordController.text,
        );
    if (!mounted) {
      return;
    }

    final auth = ref.read(authControllerProvider);
    // 失败时**保留已登录会话**（Controller 有意如此）：用户依旧是合法登录态，
    // 只是这次没改成功，不能被踢回登录页 —— 那会让人以为自己被登出了。
    final failure = auth.failure;
    if (failure == null) {
      return;
    }
    final presentation = FailurePresenter.present(failure);
    if (!presentFieldErrors(presentation)) {
      showMessage(presentation.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final state = ref.watch(authControllerProvider);
    final mustChangePassword =
        state.session?.profile.mustChangePassword ?? false;

    return ResponsiveScaffold(
      title: '修改密码',
      // 空列表 ⇒ 不渲染任何导航（见文件头注释）。
      destinations: const <AppDestination>[],
      currentRoute: '/change-password',
      actions: <Widget>[
        IconButton(
          tooltip: '退出登录',
          onPressed: state.isSubmitting ? null : _confirmLogout,
          icon: const Icon(Icons.logout),
        ),
      ],
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
                    if (mustChangePassword) ...<Widget>[
                      // 说清「为什么我一登录就被拦在这里」：不说的话，
                      // 用户只会觉得这个系统坏了。
                      Card(
                        margin: EdgeInsets.zero,
                        color: theme.colorScheme.secondaryContainer,
                        child: const Padding(
                          padding: EdgeInsets.all(12),
                          child: Text('当前密码是初始密码或已被重置，请先修改后再使用系统。'),
                        ),
                      ),
                      const SizedBox(height: 16),
                    ],
                    PasswordField(
                      controller: _currentPasswordController,
                      label: '当前密码',
                      textInputAction: TextInputAction.next,
                      validator: (String? value) => validateRequired(
                        'current_password',
                        value,
                        '请输入当前密码',
                      ),
                      onChanged: (_) => clearServerError('current_password'),
                    ),
                    const SizedBox(height: 12),
                    PasswordField(
                      controller: _newPasswordController,
                      label: '新密码',
                      helperText: '不少于 8 位',
                      // 长度下限 8 照抄契约（`minLength: 8`）。
                      textInputAction: TextInputAction.next,
                      validator: (String? value) => validateMinLength(
                        'new_password',
                        value,
                        8,
                        '新密码不少于 8 位',
                      ),
                      onChanged: (_) => clearServerError('new_password'),
                    ),
                    const SizedBox(height: 12),
                    PasswordField(
                      controller: _confirmPasswordController,
                      label: '确认新密码',
                      textInputAction: TextInputAction.done,
                      validator: _validateConfirmPassword,
                    ),
                    const SizedBox(height: 24),
                    FilledButton(
                      onPressed: state.isSubmitting ? null : _submit,
                      child: state.isSubmitting
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Text('保存'),
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
