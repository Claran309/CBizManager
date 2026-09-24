import 'package:flutter/material.dart';

/// 组详情页，由平台管理员使用（启停、owner 交接）。
///
/// 本类目前是**占位实现**，后续会用真实页面替换：届时它会接收路由参数
/// `:groupId`，解析失败时退回平台组列表并提示校验错误。
final class PlatformGroupDetailPage extends StatelessWidget {
  const PlatformGroupDetailPage({super.key});

  @override
  Widget build(BuildContext context) =>
      const Scaffold(body: Center(child: Text('组详情')));
}
