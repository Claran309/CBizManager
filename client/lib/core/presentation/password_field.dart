import 'package:flutter/material.dart';

/// 密码输入框：自带「显示 / 隐藏」开关。
///
/// 三个认证页加起来有五个密码输入（登录一个、注册两个、改密两个），
/// 每个都手写一遍 `obscureText` 状态与眼睛按钮，迟早在其中一处出问题：
/// 要么忘了 obscure（密码直接显示在屏幕上），要么图标按钮忘了 tooltip
/// （读屏用户听到的是一个没有名字的按钮）。
///
/// 可见性状态留在本组件内部，**不往上传**：它纯属这一个输入框的显示细节，
/// 页面没有任何理由知道它。密码文本本身也只在外部传入的 [controller] 里，
/// 不额外复制、不进任何 Provider。
final class PasswordField extends StatefulWidget {
  const PasswordField({
    required this.controller,
    required this.label,
    this.helperText,
    this.validator,
    this.onChanged,
    this.textInputAction,
    this.enabled = true,
    super.key,
  });

  final TextEditingController controller;

  /// 输入框标签，同时用作无障碍名称。
  final String label;

  /// 标签下方的补充说明（例如密码强度要求）。
  final String? helperText;

  final FormFieldValidator<String>? validator;

  final ValueChanged<String>? onChanged;

  final TextInputAction? textInputAction;

  final bool enabled;

  @override
  State<PasswordField> createState() => _PasswordFieldState();
}

final class _PasswordFieldState extends State<PasswordField> {
  bool _obscured = true;

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: widget.controller,
      enabled: widget.enabled,
      obscureText: _obscured,
      // 密码一律不参与自动填充建议：本项目的登录账号是组内自建的，
      // 让系统去猜「保存的密码」只会给错候选。
      autofillHints: const <String>[],
      textInputAction: widget.textInputAction,
      decoration: InputDecoration(
        labelText: widget.label,
        helperText: widget.helperText,
        border: const OutlineInputBorder(),
        suffixIcon: IconButton(
          // 图标按钮没有可见文字，tooltip 是它唯一的可读名称。
          tooltip: _obscured ? '显示密码' : '隐藏密码',
          onPressed: () => setState(() => _obscured = !_obscured),
          icon: Icon(
            _obscured
                ? Icons.visibility_outlined
                : Icons.visibility_off_outlined,
          ),
        ),
      ),
      validator: widget.validator,
      onChanged: widget.onChanged,
    );
  }
}
