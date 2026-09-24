import 'package:flutter/material.dart';

/// 强制改密页。
///
/// 当服务端 `must_change_password=true` 时，这是唯一允许停留的页面：
/// 连 `/home` 与 `/platform/groups` 都要被挡回去。做成硬门槛而不是
/// 可跳过的提示，是因为后端不会因为「用户懒得改」就放宽其它接口。
///
/// 本类目前是**占位实现**，后续会用真实的表单替换。
final class ChangePasswordPage extends StatelessWidget {
  const ChangePasswordPage({super.key});

  @override
  Widget build(BuildContext context) =>
      const Scaffold(body: Center(child: Text('修改密码')));
}
