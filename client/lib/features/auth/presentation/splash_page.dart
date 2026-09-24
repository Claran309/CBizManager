import 'package:flutter/material.dart';

/// 会话恢复页。
///
/// 应用启动到 `/auth/me` 返回之前的唯一停留点：此时还不知道用户是谁，
/// 任何业务入口都不该渲染。
///
/// 本类目前是**占位实现**，只需要是一个具名、可独立替换的路由目标类，
/// 好让多角色守卫矩阵能脱离页面细节先落地。
final class SplashPage extends StatelessWidget {
  const SplashPage({super.key});

  @override
  Widget build(BuildContext context) =>
      const Scaffold(body: Center(child: Text('正在恢复会话')));
}
