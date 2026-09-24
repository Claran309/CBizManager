import 'package:flutter/material.dart';

/// 成员权限替换页。
///
/// **仅组主账号可进入**：这是「谁能看哪张单子」的授权入口，
/// 普通成员即便拥有 `member.manage` 也只能管理状态、不能改权限，
/// 否则等于把提权能力交到被管理者手里。
///
/// 本类目前是**占位实现**，后续会用真实页面替换（届时接收 `:membershipId`）。
final class MemberPermissionsPage extends StatelessWidget {
  const MemberPermissionsPage({super.key});

  @override
  Widget build(BuildContext context) =>
      const Scaffold(body: Center(child: Text('成员权限')));
}
