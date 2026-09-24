import 'package:flutter/material.dart';

/// 字典页（客户、供应商、业务员等六种 kind 共用一页）。
///
/// **所有租户用户都能进入**：普通成员至少需要读取字典来填单。
/// 写入口按权限隐藏（owner 或 `dictionary.manage` 成员），
/// 但守卫不拦——只读用户访问本页是完全正常的业务路径。
///
/// 本类目前是**占位实现**，后续会用真实页面替换。
final class DictionariesPage extends StatelessWidget {
  const DictionariesPage({super.key});

  @override
  Widget build(BuildContext context) =>
      const Scaffold(body: Center(child: Text('字典')));
}
