import 'package:flutter/material.dart';

/// 平台组列表页（平台管理员的角色首页）。
///
/// 只有 `platform_admin` 能进入 `/platform/*`；租户用户访问会被守卫送回 `/home`。
///
/// 本类目前是**占位实现**，后续会用真实的响应式页面替换。
final class PlatformGroupsPage extends StatelessWidget {
  const PlatformGroupsPage({super.key});

  @override
  Widget build(BuildContext context) =>
      const Scaffold(body: Center(child: Text('平台组管理')));
}
