import 'package:flutter/material.dart';

/// 邀请码注册页。
///
/// 唯一一个「未登录也能访问」的业务相关页面：组内子账号凭邀请码自助注册。
/// 注册**不建立会话**，成功后回到登录页。
///
/// 本类目前是**占位实现**，后续会用真实的表单替换。
final class RegisterPage extends StatelessWidget {
  const RegisterPage({super.key});

  @override
  Widget build(BuildContext context) =>
      const Scaffold(body: Center(child: Text('邀请码注册')));
}
