import 'package:c_biz_docs_manager/features/invitations/application/invitation_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 把契约里的 UTC 时间转成本地时间后格式化（形如 `2026-03-01 08:00`）。
///
/// wire model 一律保持 UTC（见 `domain/invitation.dart` 的说明），只有到了屏幕上
/// 才换成用户手表的时区 ——「什么时候过期」这句话必须按用户所在地的时间理解，
/// 直接把 `2026-03-01T00:00:00Z` 摆给业务员看是在逼他自己做时区换算。
///
/// 刻意不引 `intl`：一个固定格式的短时间戳不值得为此背上一份本地化数据表，
/// 而列表与面板必须用同一个函数，否则两处会各显示一种格式。
String formatInvitationTime(DateTime value) {
  final local = value.toLocal();
  String two(int number) => number.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)} '
      '${two(local.hour)}:${two(local.minute)}';
}

/// 展示中的邀请码明文面板。
///
/// **它只从 `InvitationState.visibleSecret` 取数，构造函数不接受任何 secret 参数。**
/// 这不是风格偏好：明文一旦能被当作参数在 widget 树里传来传去，迟早会有人把它塞进
/// `const`、缓存进某个 State、或者顺手传给另一个页面 —— 那时「一次只保留一份、
/// 该消失时立刻消失」的规则就形同虚设。唯一的取数口就是 Controller 的那一个字段，
/// 而那个字段的生命周期由 [InvitationController] 集中管理。
///
/// 明文为空时整块不占位（[SizedBox.shrink]）：留一个空壳卡片会让人以为加载失败了。
final class InvitationSecretPanel extends ConsumerWidget {
  const InvitationSecretPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final secret = ref.watch(invitationControllerProvider).visibleSecret;
    if (secret == null) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final onContainer = scheme.onTertiaryContainer;

    return Card(
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 0),
      // tertiaryContainer：与普通内容区明显区分的一块「临时高亮」，
      // 用来提醒用户这里的东西是易逝的、需要马上处理掉的。
      color: scheme.tertiaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(Icons.vpn_key, size: 18, color: onContainer),
                const SizedBox(width: 8),
                Text(
                  '邀请码明文',
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: onContainer,
                  ),
                ),
                const Spacer(),
                TextButton(
                  // 收起是用户主动放弃这份明文，等同于 clearSecret()：
                  // 状态一清，本面板下一帧就整块消失。
                  onPressed: ref
                      .read(invitationControllerProvider.notifier)
                      .clearSecret,
                  child: const Text('收起'),
                ),
              ],
            ),
            Text(
              '关闭或离开本页后不再显示，请立即复制保存',
              style: theme.textTheme.bodySmall?.copyWith(color: onContainer),
            ),
            const SizedBox(height: 12),
            // SelectableText：复制按钮可能被禁用或失败，用户至少要能手动选中。
            // 字距调宽是因为邀请码里全是形近字符（0/O、1/I），挤在一起极易抄错。
            SelectableText(
              secret.code,
              style: theme.textTheme.headlineSmall?.copyWith(
                color: onContainer,
                fontWeight: FontWeight.bold,
                letterSpacing: 2,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '有效期至 ${formatInvitationTime(secret.expiresAt)}',
              style: theme.textTheme.bodySmall?.copyWith(color: onContainer),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: () => _copyToClipboard(context, secret.code),
              icon: const Icon(Icons.copy_outlined),
              label: const Text('复制'),
            ),
          ],
        ),
      ),
    );
  }
}

/// 把明文写进系统剪贴板，并给一次**不含明文**的成功反馈。
///
/// 反馈里绝不能出现 code：这条提示会被截图、被读屏念出来、被投屏给会议室看，
/// 而它的全部目的只是告诉用户「按对了」。所以 SnackBar 是 `const` 的固定文案，
/// 想顺手把 code 拼进去都得先改掉这个 const。
Future<void> _copyToClipboard(BuildContext context, String code) async {
  await Clipboard.setData(ClipboardData(text: code));
  // 剪贴板是异步的，回来时页面可能已经卸载（用户点完立刻返回）。
  if (!context.mounted) return;
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(const SnackBar(content: Text('已复制到剪贴板')));
}
