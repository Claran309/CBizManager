import 'package:flutter/material.dart';

/// 新建组页，由平台管理员使用。
///
/// 本类目前是**占位实现**，后续会用真实的表单替换（组名 + owner 账号资料）。
final class CreateGroupPage extends StatelessWidget {
  const CreateGroupPage({super.key});

  @override
  Widget build(BuildContext context) =>
      const Scaffold(body: Center(child: Text('新建组')));
}
