import 'package:c_biz_docs_manager/core/auth/auth_models.dart';
import 'package:c_biz_docs_manager/core/presentation/responsive_scaffold.dart';
import 'package:flutter/material.dart';

/// 租户侧（组主账号 / 业务员）共用的导航定义。
///
/// 为什么要有这一处：五个租户页面（首页 / 邀请码 / 成员 / 成员权限 / 字典）
/// 以前各自持有一份**单项**列表，而 [ResponsiveScaffold] 在目的地少于两项时
/// 干脆不渲染导航 —— 也就是说整条租户链路实际上没有导航，业务员在字典页想去
/// 首页只能手改地址栏。集中到这里之后，导航项随身份裁剪，
/// 也不会再出现「某个页面漏加某一项、于是从那个页面到不了某个功能」。
///
/// [profile] 为 null 表示会话还没建立（恢复中，或页面被单独构造出来）。
/// 这时**一项都不给**：宁可不显示导航，也不能凭空猜一个身份 ——
/// 猜成主账号会让一个刚被降权的账号继续看见管理入口。
List<AppDestination> tenantDestinations(AuthProfile? profile) {
  if (profile == null) {
    return const <AppDestination>[];
  }
  return <AppDestination>[
    _homeDestination,
    // 邀请码决定「谁能进这个组」，只有组主账号该看见它。
    // 守卫里的 owner-only 规则负责最终裁决，这里只负责不给普通成员一个
    // 「点了会被弹回首页」的假入口。
    if (profile.accountType == AccountType.groupOwner) _invitationsDestination,
    // 成员管理：主账号隐式持有组内全部权限（`AuthProfile.hasPermission`
    // 内部已经处理），普通成员必须拿到服务端显式下发的 member.manage。
    if (profile.hasPermission('member.manage')) _membersDestination,
    // 字典是填单的前置数据，所有租户用户都要能读，所以恒在。
    _dictionariesDestination,
  ];
}

/// 租户首页：[AppDestination.label] 同时用作导航项文字与 AppBar 标题。
///
/// 两处文案一致是有意的 —— 它们指同一件事，写岔了用户会以为自己点错了。
const AppDestination _homeDestination = AppDestination(
  label: '首页',
  icon: Icons.dashboard_outlined,
  route: '/home',
);

const AppDestination _invitationsDestination = AppDestination(
  label: '邀请码',
  icon: Icons.vpn_key_outlined,
  route: '/invitations',
);

const AppDestination _membersDestination = AppDestination(
  label: '成员',
  icon: Icons.group_outlined,
  route: '/members',
);

const AppDestination _dictionariesDestination = AppDestination(
  label: '字典',
  icon: Icons.menu_book_outlined,
  route: '/dictionaries',
);
