import 'package:flutter/material.dart';

/// 邀请码管理页。
///
/// **仅组主账号可进入**：邀请码是「谁能加入这个组」的凭证，
/// 普通成员即使持有 `member.manage` 也不该看到生成/撤销入口。
///
/// 本类目前是**占位实现**，后续会用真实页面替换。
final class InvitationsPage extends StatelessWidget {
  const InvitationsPage({super.key});

  @override
  Widget build(BuildContext context) =>
      const Scaffold(body: Center(child: Text('邀请码')));
}
