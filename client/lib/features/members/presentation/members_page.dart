import 'package:flutter/material.dart';

/// 成员列表页。
///
/// 数据范围规则（守卫层只做「能不能进」的判断，服务端仍做最终授权）：
/// 组主账号隐式持有组内全部权限，可直接进入；普通成员只有被显式授予
/// `member.manage` 才放行。
///
/// 本类目前是**占位实现**，后续会用真实页面替换。
final class MembersPage extends StatelessWidget {
  const MembersPage({super.key});

  @override
  Widget build(BuildContext context) =>
      const Scaffold(body: Center(child: Text('成员')));
}
