import 'package:flutter/material.dart';

/// 租户用户（组主账号 / 业务员）的首页。
///
/// 平台管理员**不会**落到这里：它的角色首页是 `/platform/groups`。
/// 所以本页可以放心假设「当前会话一定带着 group」，不需要再判空兜底。
///
/// 本类目前是**占位实现**，后续会用真实的响应式功能壳替换。
final class TenantHomePage extends StatelessWidget {
  const TenantHomePage({super.key});

  @override
  Widget build(BuildContext context) =>
      const Scaffold(body: Center(child: Text('首页')));
}
