import 'package:c_biz_docs_manager/features/platform/domain/platform_group.dart';
import 'package:flutter/material.dart';

/// 交接组主账号的对话框。
///
/// 它**只负责收集用户意图**：不发请求、不碰任何 Provider，确认时通过
/// `Navigator.pop` 交出一个 [OwnerChangeDraft]。这样做有两个好处：
///
/// - 详情页可以把它当纯函数用（`final draft = await ChangeOwnerDialog.show(...)`），
///   拿到 null 就是用户取消，拿到 draft 才去调 Controller；「用户改主意了」
///   这条路径上不会有任何半成品请求发出去。
/// - 单测可以直接弹它、断言它交出来的 draft 长什么样，不必连带搭一套状态容器。
///
/// 两种交接模式在契约里是**字段互斥**的，所以这里一次只渲染一组控件，
/// 而不是把所有输入框都摆出来再让用户猜哪些该填 —— 后者迟早会有人两组都填，
/// 得到一个服务端无法解释的请求。
final class ChangeOwnerDialog extends StatefulWidget {
  const ChangeOwnerDialog({required this.detail, super.key});

  /// 打开对话框那一刻的详情快照。
  ///
  /// 这里刻意用快照而不是自己去读 Controller：对话框是个瞬时界面，
  /// 它展示的候选列表与版本号应当与用户点「交接」时看到的那一屏完全一致。
  /// 若期间组被别处改过，服务端会用 409 拒绝，由详情页重读后再让用户确认
  /// —— 这比对话框自己偷偷刷新数据、却仍按旧意图提交要安全得多。
  final PlatformGroupDetail detail;

  /// 弹出对话框并等待用户确认；取消或直接关闭时返回 null。
  static Future<OwnerChangeDraft?> show(
    BuildContext context,
    PlatformGroupDetail detail,
  ) => showDialog<OwnerChangeDraft>(
    context: context,
    builder: (BuildContext _) => ChangeOwnerDialog(detail: detail),
  );

  @override
  State<ChangeOwnerDialog> createState() => _ChangeOwnerDialogState();
}

final class _ChangeOwnerDialogState extends State<ChangeOwnerDialog> {
  /// 新建账号模式的字段校验器。existing 模式走的是另一条分支，
  /// 校验的是「选没选人」，所以这个 Form 只在 new 模式下参与。
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();

  final TextEditingController _usernameController = TextEditingController();
  final TextEditingController _displayNameController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();

  late OwnerChangeMode _mode;

  /// 选中的候选成员关系 ID；null 表示还没选。
  int? _membershipId;

  bool _obscurePassword = true;

  /// existing 模式下「一个都没选」的内联提示开关。
  ///
  /// 单选列表没有 validator 可用（不是表单控件），所以这个错误得自己管：
  /// 不用 SnackBar 是因为它会在对话框上方飘一条、几秒后又消失，
  /// 用户还没读完就没了。
  bool _showMembershipError = false;

  List<OwnerCandidate> get _candidates => widget.detail.ownerCandidates;

  @override
  void initState() {
    super.initState();
    // 候选人一个都没有时直接落到「新建账号」：existing 模式下用户面对的是一个
    // 空列表，无从下手。让他自己去发现右上角的模式切换，是最没必要的一次挫败。
    // （候选人只含 active 普通成员，见 `PlatformGroupDetail.ownerCandidates`。）
    _mode = _candidates.isEmpty
        ? OwnerChangeMode.newAccount
        : OwnerChangeMode.existingMember;
  }

  @override
  void dispose() {
    _usernameController.dispose();
    _displayNameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  void _confirm() {
    final version = widget.detail.group.version;

    if (_mode == OwnerChangeMode.existingMember) {
      final membershipId = _membershipId;
      if (membershipId == null) {
        setState(() => _showMembershipError = true);
        return;
      }
      Navigator.of(context).pop(
        ExistingMemberOwnerDraft(membershipId: membershipId, version: version),
      );
      return;
    }

    if (!(_formKey.currentState?.validate() ?? false)) {
      return;
    }
    Navigator.of(context).pop(
      NewAccountOwnerDraft(
        // 账号与显示名去首尾空白：那几乎总是误输入。密码**不**动，
        // 前导或尾随空格是合法的密码字符，trim 掉会让用户「明明输对了却登不上」。
        username: _usernameController.text.trim(),
        displayName: _displayNameController.text.trim(),
        temporaryPassword: _passwordController.text,
        version: version,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return AlertDialog(
      title: const Text('交接主账号'),
      // 可滚动：窄屏上候选人多、或者弹出软键盘时，固定高度必然 overflow。
      content: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              '当前主账号：${widget.detail.group.owner.displayName}'
              '（${widget.detail.group.owner.username}）',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 16),
            SegmentedButton<OwnerChangeMode>(
              // 紧凑排布 + 不显示选中对勾：对话框内宽有限，勾图标会把文字挤到换行。
              showSelectedIcon: false,
              segments: const <ButtonSegment<OwnerChangeMode>>[
                ButtonSegment<OwnerChangeMode>(
                  value: OwnerChangeMode.existingMember,
                  label: Text('现有成员'),
                ),
                ButtonSegment<OwnerChangeMode>(
                  value: OwnerChangeMode.newAccount,
                  label: Text('新建账号'),
                ),
              ],
              selected: <OwnerChangeMode>{_mode},
              onSelectionChanged: (Set<OwnerChangeMode> selection) {
                setState(() {
                  _mode = selection.first;
                  _showMembershipError = false;
                });
              },
            ),
            const SizedBox(height: 16),
            if (_mode == OwnerChangeMode.existingMember)
              _buildCandidatePicker(theme)
            else
              _buildNewAccountForm(),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _confirm, child: const Text('确认交接')),
      ],
    );
  }

  /// existing 模式：从候选人里挑一个。
  ///
  /// 用 ListTile + 自绘单选图标，而不是 `RadioListTile`：后者的
  /// `groupValue` / `onChanged` 已在当前 Flutter 版本标记废弃，换成新 API
  /// 又要求把整个列表包进 `RadioGroup`；而这里只是「点一行选中一行」，
  /// 自绘反而更短、更稳，也不受版本更替影响。
  Widget _buildCandidatePicker(ThemeData theme) {
    if (_candidates.isEmpty) {
      // initState 已经把模式切走了，正常走不到这里；留着是为了将来有人在
      // onSelectionChanged 里放宽限制时不至于渲染出一个空的「现有成员」页。
      return const Text('该组暂无可提升的活跃成员，请改用「新建账号」。');
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text('选择要提升为组主账号的成员：', style: theme.textTheme.bodySmall),
        const SizedBox(height: 4),
        for (final candidate in _candidates)
          ListTile(
            dense: true,
            // 用 membershipId 而不是 user.id 作为选中值：交接针对的是「成员关系」，
            // 同一个用户在不同组里是不同的关系，只有关系 ID 能唯一定位目标。
            selected: _membershipId == candidate.membershipId,
            leading: Icon(
              _membershipId == candidate.membershipId
                  ? Icons.radio_button_checked
                  : Icons.radio_button_unchecked,
              color: _membershipId == candidate.membershipId
                  ? theme.colorScheme.primary
                  : null,
            ),
            title: Text(candidate.user.displayName),
            subtitle: Text(candidate.user.username),
            onTap: () => setState(() {
              _membershipId = candidate.membershipId;
              _showMembershipError = false;
            }),
          ),
        if (_showMembershipError) ...<Widget>[
          const SizedBox(height: 8),
          Text(
            '请选择一位成员',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.error,
            ),
          ),
        ],
      ],
    );
  }

  /// new 模式：填新账号资料。
  Widget _buildNewAccountForm() {
    return Form(
      key: _formKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          TextFormField(
            controller: _usernameController,
            autofocus: false,
            decoration: const InputDecoration(
              labelText: '登录账号',
              border: OutlineInputBorder(),
            ),
            validator: (String? value) =>
                (value == null || value.trim().isEmpty) ? '请输入登录账号' : null,
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: _displayNameController,
            decoration: const InputDecoration(
              labelText: '姓名',
              border: OutlineInputBorder(),
            ),
            validator: (String? value) =>
                (value == null || value.trim().isEmpty) ? '请输入姓名' : null,
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: _passwordController,
            obscureText: _obscurePassword,
            decoration: InputDecoration(
              labelText: '初始密码',
              helperText: '不少于 8 位，请交付给本人后要求其尽快修改',
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(
                tooltip: _obscurePassword ? '显示密码' : '隐藏密码',
                onPressed: () =>
                    setState(() => _obscurePassword = !_obscurePassword),
                icon: Icon(
                  _obscurePassword
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined,
                ),
              ),
            ),
            // 长度下限照抄契约（`minLength: 8`）：本地先拦一道，
            // 用户不必为一个明确可知的规则多等一次往返。
            validator: (String? value) {
              final password = value ?? '';
              if (password.isEmpty) return '请输入初始密码';
              if (password.length < 8) return '初始密码不少于 8 位';
              return null;
            },
          ),
        ],
      ),
    );
  }
}
