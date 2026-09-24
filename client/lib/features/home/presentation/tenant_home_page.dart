import 'package:c_biz_docs_manager/core/auth/auth_controller.dart';
import 'package:c_biz_docs_manager/core/auth/auth_models.dart';
import 'package:c_biz_docs_manager/core/presentation/responsive_scaffold.dart';
import 'package:c_biz_docs_manager/features/home/presentation/tenant_shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 账号类型的界面文案。
///
/// 单独抽出来是因为「account_type」是契约字段名，直接显示给业务员看没有意义；
/// 而 `member` 更要翻成「业务员」——在这个业务里，组内子账号就是跑单的人。
String accountTypeLabel(AccountType type) => switch (type) {
  AccountType.platformAdmin => '平台管理员',
  AccountType.groupOwner => '组主账号',
  AccountType.member => '业务员',
};

/// 租户用户（组主账号 / 业务员）的首页。
///
/// 平台管理员**不会**落到这里：它的角色首页是 `/platform/groups`，
/// 守卫会把两者分开。所以本页可以放心假设「当前会话一定带着 group」。
///
/// 本页只呈现身份摘要，**不展示任何令牌**：访问令牌是凭据，一旦渲染到屏幕上，
/// 截图、投屏、旁人一眼都能拿走它；它只该存在于内存里的
/// `AccessTokenStore`，不该出现在任何 Widget 树里。
final class TenantHomePage extends ConsumerStatefulWidget {
  const TenantHomePage({super.key});

  @override
  ConsumerState<TenantHomePage> createState() => _TenantHomePageState();
}

final class _TenantHomePageState extends ConsumerState<TenantHomePage> {
  Future<void> _confirmLogout() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('退出登录'),
        content: const Text('退出后需要重新输入账号密码。确定退出吗？'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('退出'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    // 登出是**无条件成功**的：仓储会把本地凭据清干净，就算网络断了也一样。
    // 之后路由守卫（refreshListenable 会收到通知）把地址换成登录页，本页随之卸载，
    // 所以这里不需要、也不该自己导航。
    await ref.read(authControllerProvider.notifier).logout();
  }

  @override
  Widget build(BuildContext context) {
    final profile = ref.watch(authControllerProvider).session?.profile;

    return ResponsiveScaffold(
      title: '首页',
      destinations: tenantDestinations(profile),
      currentRoute: '/home',
      actions: <Widget>[
        IconButton(
          tooltip: '退出登录',
          onPressed: _confirmLogout,
          icon: const Icon(Icons.logout),
        ),
      ],
      body: switch (profile) {
        // 正常流程走不到这里（守卫会把未登录用户送去登录页）；留着是为了让
        // 「页面先于会话建立了一帧」不至于崩在一句 `profile.user` 上。
        null => const Center(child: Text('正在加载账号信息')),
        final AuthProfile profile => _buildSummary(profile),
      },
    );
  }

  Widget _buildSummary(AuthProfile profile) {
    final theme = Theme.of(context);
    // 平台管理员不属于任何组，但守卫不会把它放进本页；租户身份的组合自洽性
    // 由 `AuthProfile._validateIdentityCombination` 保证，所以 group 必不为 null。
    final groupName = profile.group?.name ?? '—';

    return ListView(
      padding: const EdgeInsets.all(16),
      children: <Widget>[
        Center(
          child: ConstrainedBox(
            // 限宽：桌面端把身份信息拉满整屏会让眼睛来回扫。
            constraints: const BoxConstraints(maxWidth: 560),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Text('当前账号', style: theme.textTheme.titleMedium),
                const SizedBox(height: 8),
                Card(
                  margin: EdgeInsets.zero,
                  child: ListTile(
                    leading: const Icon(Icons.person_outline),
                    title: Text(profile.user.displayName),
                    subtitle: Text(profile.user.username),
                  ),
                ),
                const SizedBox(height: 24),
                Text('归属与角色', style: theme.textTheme.titleMedium),
                const SizedBox(height: 8),
                Card(
                  margin: EdgeInsets.zero,
                  child: Column(
                    children: <Widget>[
                      ListTile(
                        leading: const Icon(Icons.business_outlined),
                        title: const Text('所属业务组'),
                        trailing: Text(groupName),
                      ),
                      const Divider(height: 1),
                      ListTile(
                        leading: const Icon(Icons.badge_outlined),
                        title: const Text('账号类型'),
                        trailing: Text(accountTypeLabel(profile.accountType)),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),
                Text('权限', style: theme.textTheme.titleMedium),
                const SizedBox(height: 8),
                _PermissionSummary(profile: profile),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// 权限摘要。
///
/// 主账号**不列权限码**：它隐式持有组内全部权限，服务端下发的
/// `permission_codes` 对它是空数组（见 `AuthProfile.permissionCodes` 的注释），
/// 照实渲染会得到「没有任何权限」这种与事实相反的画面。
final class _PermissionSummary extends StatelessWidget {
  const _PermissionSummary({required this.profile});

  final AuthProfile profile;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final codes = profile.permissionCodes.toList()..sort();

    if (profile.accountType == AccountType.groupOwner) {
      return Card(
        margin: EdgeInsets.zero,
        child: ListTile(
          leading: const Icon(Icons.verified_user_outlined),
          title: const Text('组内全部权限'),
          subtitle: const Text('主账号隐式持有组内所有权限，无需逐项授予。'),
        ),
      );
    }

    if (codes.isEmpty) {
      return Card(
        margin: EdgeInsets.zero,
        child: ListTile(
          leading: const Icon(Icons.lock_outline),
          title: const Text('暂无额外权限'),
          subtitle: const Text('需要更多功能时，请联系组主账号在「成员」页为你的账号授权。'),
        ),
      );
    }

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('已授予 ${codes.length} 项权限', style: theme.textTheme.bodyMedium),
            const SizedBox(height: 8),
            // Wrap 而不是 Column：权限码长短不一，窄屏上换行比截断可读。
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                for (final code in codes)
                  Chip(label: Text(code), visualDensity: VisualDensity.compact),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
