import 'package:c_biz_docs_manager/core/presentation/failure_presenter.dart';
import 'package:c_biz_docs_manager/core/presentation/responsive_scaffold.dart';
import 'package:c_biz_docs_manager/features/platform/application/create_group_controller.dart';
import 'package:c_biz_docs_manager/features/platform/domain/platform_group.dart';
import 'package:c_biz_docs_manager/features/platform/presentation/platform_shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

/// 新建业务组页（平台管理员）：一次创建组及其组主账号。
///
/// 主账号资料是**必填**的 —— 契约里 `CreateGroupRequest` 就把四项全标了 required，
/// 服务端不会代生成初始密码。所以界面有责任把「这串密码要安全地交给本人」说清楚，
/// 否则最常见的结局是管理员随手设一个 12345678 然后再也不改。
final class CreateGroupPage extends ConsumerStatefulWidget {
  const CreateGroupPage({super.key});

  @override
  ConsumerState<CreateGroupPage> createState() => _CreateGroupPageState();
}

final class _CreateGroupPageState extends ConsumerState<CreateGroupPage> {
  /// 本页负责渲染的字段名（与契约字段名一致）。
  ///
  /// 服务端 `ValidationFailure.fields` 的键就是 snake_case 的契约字段名，
  /// 所以这张表同时充当「这条字段错误我能不能展示」的判据：不在表里的
  /// （比如 `body`）说明本页无处安放，得退回统一提示条。
  static const Set<String> _fieldNames = <String>{
    'name',
    'owner_username',
    'owner_display_name',
    'owner_temporary_password',
  };

  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();

  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _ownerUsernameController =
      TextEditingController();
  final TextEditingController _ownerDisplayNameController =
      TextEditingController();
  final TextEditingController _passwordController = TextEditingController();

  bool _obscurePassword = true;

  /// 服务端返回的逐字段错误。
  ///
  /// 它不是常驻状态：用户一改动某个字段，该字段上的服务端错误立刻清掉
  /// （见 [_clearServerError]）—— 否则「组名已存在」会一直挂在那里，
  /// 哪怕用户已经把组名改成了别的。
  Map<String, String> _serverFieldErrors = const <String, String>{};

  @override
  void dispose() {
    // Controller 必须显式释放：它们持有的是原生文本编辑资源。
    _nameController.dispose();
    _ownerUsernameController.dispose();
    _ownerDisplayNameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  String? _validateRequired(String field, String? value, String message) {
    final serverError = _serverFieldErrors[field];
    if (serverError != null) return serverError;
    if (value == null || value.trim().isEmpty) return message;
    return null;
  }

  /// 初始密码的校验：服务端错误优先，其次才是本地规则。
  ///
  /// 长度下限 8 照抄契约（`minLength: 8`）。本地先拦一道，用户不必为一个
  /// 明确可知的规则白等一次往返；而服务端错误优先，是因为它知道更多
  /// （比如「与历史密码重复」这种本地无法判断的约束）。
  String? _validatePassword(String? value) {
    final serverError = _serverFieldErrors['owner_temporary_password'];
    if (serverError != null) return serverError;
    final password = value ?? '';
    if (password.isEmpty) return '请输入初始密码';
    if (password.length < 8) return '初始密码不少于 8 位';
    return null;
  }

  void _clearServerError(String field) {
    if (!_serverFieldErrors.containsKey(field)) return;
    setState(() {
      // 复制一份再删，避免直接改动上一份状态里的 Map（状态对象应当是不可变的）。
      _serverFieldErrors = Map<String, String>.of(_serverFieldErrors)
        ..remove(field);
    });
  }

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    // 表单内容变了，上一轮的服务端错误一律作废。
    if (_serverFieldErrors.isNotEmpty) {
      setState(() => _serverFieldErrors = const <String, String>{});
    }

    final result = await ref
        .read(createGroupControllerProvider.notifier)
        .submit(
          CreateGroupDraft(
            name: _nameController.text.trim(),
            ownerUsername: _ownerUsernameController.text.trim(),
            ownerDisplayName: _ownerDisplayNameController.text.trim(),
            // 密码不 trim：前导/尾随空格是合法密码字符，改动它会让主人
            // 「明明输对了却登不上」。
            ownerTemporaryPassword: _passwordController.text,
          ),
        );
    if (!mounted || result != null) return;

    final failure = ref.read(createGroupControllerProvider).failure;
    if (failure == null) return;

    final presentation = FailurePresenter.present(failure);
    final fieldErrors = presentation.fieldErrors;
    final canPlaceAllErrors =
        fieldErrors.isNotEmpty && fieldErrors.keys.every(_fieldNames.contains);
    if (canPlaceAllErrors) {
      // 每条错误都挂到了对应输入框下方，就不再弹提示条说第二遍。
      setState(() => _serverFieldErrors = fieldErrors);
      _formKey.currentState?.validate();
      return;
    }
    _showMessage(presentation.message);
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(createGroupControllerProvider);

    ref.listen<CreateGroupState>(createGroupControllerProvider, (
      CreateGroupState? previous,
      CreateGroupState next,
    ) {
      final groupId = next.createdGroupId;
      if (groupId == null || !mounted) return;
      // 先把结果清掉再跳：否则用户从详情页返回本页时，这个还在的值会立刻
      // 把他又弹回详情（原因见 CreateGroupState.createdGroupId 的注释）。
      ref.read(createGroupControllerProvider.notifier).reset();
      context.go('/platform/groups/$groupId');
    });

    return ResponsiveScaffold(
      title: '新建业务组',
      destinations: platformDestinations,
      currentRoute: '/platform/groups/new',
      actions: <Widget>[
        IconButton(
          tooltip: '返回组列表',
          onPressed: () => context.go('/platform/groups'),
          icon: const Icon(Icons.arrow_back),
        ),
      ],
      body: _buildForm(state),
    );
  }

  Widget _buildForm(CreateGroupState state) {
    final theme = Theme.of(context);

    return Form(
      key: _formKey,
      // 用户碰过某个字段之后就一直校验它：比每次提交才报错更及时，
      // 也不会在用户还没开始填的时候就满屏红字。
      autovalidateMode: AutovalidateMode.onUserInteraction,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          Center(
            child: ConstrainedBox(
              // 限宽：桌面端输入框拉满 1280 像素的话，一行文字长到眼睛要来回扫。
              constraints: const BoxConstraints(maxWidth: 560),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Text('业务组信息', style: theme.textTheme.titleMedium),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _nameController,
                    decoration: const InputDecoration(
                      labelText: '业务组名称',
                      border: OutlineInputBorder(),
                    ),
                    validator: (String? value) =>
                        _validateRequired('name', value, '请输入业务组名称'),
                    onChanged: (_) => _clearServerError('name'),
                  ),
                  const SizedBox(height: 24),
                  Text('组主账号', style: theme.textTheme.titleMedium),
                  const SizedBox(height: 4),
                  Text(
                    '主账号由平台创建，创建后请把账号与初始密码安全地交给本人。',
                    style: theme.textTheme.bodySmall,
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _ownerUsernameController,
                    decoration: const InputDecoration(
                      labelText: '登录账号',
                      border: OutlineInputBorder(),
                    ),
                    validator: (String? value) =>
                        _validateRequired('owner_username', value, '请输入登录账号'),
                    onChanged: (_) => _clearServerError('owner_username'),
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _ownerDisplayNameController,
                    decoration: const InputDecoration(
                      labelText: '姓名',
                      border: OutlineInputBorder(),
                    ),
                    validator: (String? value) =>
                        _validateRequired('owner_display_name', value, '请输入姓名'),
                    onChanged: (_) => _clearServerError('owner_display_name'),
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _passwordController,
                    obscureText: _obscurePassword,
                    decoration: InputDecoration(
                      labelText: '初始密码',
                      helperText: '不少于 8 位，交付后请要求本人尽快修改',
                      border: const OutlineInputBorder(),
                      suffixIcon: IconButton(
                        tooltip: _obscurePassword ? '显示密码' : '隐藏密码',
                        onPressed: () => setState(
                          () => _obscurePassword = !_obscurePassword,
                        ),
                        icon: Icon(
                          _obscurePassword
                              ? Icons.visibility_outlined
                              : Icons.visibility_off_outlined,
                        ),
                      ),
                    ),
                    validator: _validatePassword,
                    onChanged: (_) =>
                        _clearServerError('owner_temporary_password'),
                  ),
                  const SizedBox(height: 24),
                  FilledButton(
                    // 提交中禁用是防重复提交的最后一道闸：Controller 里已经
                    // 用「判空 + 置位不夹 await」挡住并发，这里再从交互上
                    // 让用户看见「正在处理」。
                    onPressed: state.isSubmitting ? null : _submit,
                    child: state.isSubmitting
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('创建'),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
