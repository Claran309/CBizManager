import 'package:flutter/material.dart';

/// 登录页。
///
/// 未登录态下的默认落点。注册入口（`/register`）同样属于公开区域，
/// 但注册成功后要回到这里并预填用户名，而不是自动进入业务区。
///
/// 本类目前是**占位实现**，后续会用真实的表单替换。
final class LoginPage extends StatelessWidget {
  const LoginPage({super.key});

  @override
  Widget build(BuildContext context) =>
      const Scaffold(body: Center(child: Text('登录')));
}
