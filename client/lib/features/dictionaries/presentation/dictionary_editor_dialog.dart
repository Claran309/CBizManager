import 'package:c_biz_docs_manager/core/error/app_failure.dart';
import 'package:c_biz_docs_manager/core/presentation/failure_presenter.dart';
import 'package:c_biz_docs_manager/features/dictionaries/application/dictionary_controller.dart';
import 'package:c_biz_docs_manager/features/dictionaries/domain/dictionary_entry.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 字典 editor 关闭时交还给调用方的结果。`null` 表示用户取消。
///
/// 用密封类而不是「返回 draft 或失败」这种多态值：调用方必须把
/// 「取消了」「保存成功」「撞上冲突」分开处理，而冲突还要把原因原样带出去
/// 变成一条提示 —— 混在一个可空对象里，这三条路迟早会被写成两个 if。
sealed class DictionaryEditorResult {
  const DictionaryEditorResult();
}

/// 保存成功：Controller 已经把新数据合进列表。
final class DictionaryEditorSaved extends DictionaryEditorResult {
  const DictionaryEditorSaved();
}

/// 撞上乐观锁冲突：对话框已关闭，由调用方提示「刷新后重新操作」。
final class DictionaryEditorConflict extends DictionaryEditorResult {
  const DictionaryEditorConflict(this.failure);

  final AppFailure failure;
}

/// 新增 / 编辑一条字典条目的对话框。
///
/// **它自己完成写操作**，而不是像「交接主账号」那样只收集意图交回页面。
/// 差别在于这里的输入是**用户一个字一个字敲出来的**：把失败丢回页面、
/// 让对话框立刻关掉，等于他刚写的一屏资料因为一次网络抖动就全没了。
/// 所以校验失败与网络失败都留在对话框里内联展示，只有两种情况会关闭：
///
/// - **成功**：Controller 已把新数据合进列表，没什么可留在屏幕上；
/// - **乐观锁冲突**：手里这个 version 已经作废，重试必然再失败一次，
///   必须回列表看最新数据再重新决定（这与 `FailurePresenter` 对 409 的口径一致）。
///
/// 字段裁剪严格照 [DictionaryKindRules]，它们不是界面偏好而是后端硬约束：
/// 给「单位」多提交一个 `contact_phone` 会被直接判 `VALIDATION_FAILED`。
final class DictionaryEditorDialog extends ConsumerStatefulWidget {
  const DictionaryEditorDialog({required this.kind, this.entry, super.key});

  /// 要编辑的条目类型。**kind 一经创建不可修改**，所以编辑时它也不可编辑。
  final DictionaryKind kind;

  /// 为 null 表示新增。
  final DictionaryEntry? entry;

  /// 弹出对话框并等待结果；用户取消或直接关闭时返回 null。
  static Future<DictionaryEditorResult?> show(
    BuildContext context, {
    required DictionaryKind kind,
    DictionaryEntry? entry,
  }) => showDialog<DictionaryEditorResult>(
    context: context,
    builder: (BuildContext _) =>
        DictionaryEditorDialog(kind: kind, entry: entry),
  );

  @override
  ConsumerState<DictionaryEditorDialog> createState() =>
      _DictionaryEditorDialogState();
}

final class _DictionaryEditorDialogState
    extends ConsumerState<DictionaryEditorDialog> {
  /// 契约里 `name` 的上限（后端 `validateDraft` 按 rune 计 191）。
  ///
  /// 本地先拦一道：用户不必为一条明确可知的规则白等一个往返。
  static const int _nameMaxLength = 191;

  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();

  late final TextEditingController _nameController;
  late final TextEditingController _phoneController;

  /// 选中的父级品名 id；只有「型号」用它。
  int? _parentId;

  /// 写操作的失败（显示在正文上方）。
  AppFailure? _failure;

  /// 父级候选拉取的失败（显示在父级那一段里，带重试）。
  ///
  /// 与 [_failure] 分开：两者该出现的位置不同 —— 写失败要顶在最上面，
  /// 候选失败要贴着那个下拉。
  AppFailure? _parentsFailure;

  bool get _isEditing => widget.entry != null;

  @override
  void initState() {
    super.initState();
    final entry = widget.entry;
    _nameController = TextEditingController(text: entry?.name ?? '');
    _phoneController = TextEditingController(text: entry?.contactPhone ?? '');
    _parentId = entry?.parentId;

    if (widget.kind.usesParent) {
      // 首帧之后再拉：initState 期间触发状态变化会撞上「build 期间改状态」的断言。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _loadParents();
      });
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _phoneController.dispose();
    super.dispose();
  }

  DictionaryController get _controller =>
      ref.read(dictionaryControllerProvider.notifier);

  /// 拉取「可作为父级」的品名候选。
  ///
  /// 每次都重拉（Controller 里没有「拿到就跳过」的缓存）：用户很可能刚在别处
  /// 新建了一条品名，这时下拉里必须能看到它。
  Future<void> _loadParents() async {
    setState(() => _parentsFailure = null);
    await _controller.loadParentOptions();
    if (!mounted) return;
    // `loadParentOptions` 开工时会先清掉上一次的失败，所以这里读到的非空失败
    // 一定是本次拉取造成的，不会把上一个操作的错误顶上来。
    setState(
      () => _parentsFailure = ref.read(dictionaryControllerProvider).failure,
    );
  }

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;

    final kind = widget.kind;
    final entry = widget.entry;
    final phone = _phoneController.text.trim();

    final draft = DictionaryDraft(
      // 名称去首尾空白：那几乎总是误输入。
      kind: kind,
      name: _nameController.text.trim(),
      // 只有型号提交 parent_id。其余 kind 带上它一律被后端判
      // `DICTIONARY_PARENT_INVALID`，客户带 parent_id 也一样。
      parentId: kind.usesParent ? _parentId : null,
      // 只有客户能带联系电话（后端对非客户带 contact_phone 判校验失败）。
      // 空字符串等价于「不填」：后端 cleanPhone 也会把它收敛成 nil，
      // 但这里先收敛掉，请求体里就不用塞一个语义模糊的空串。
      contactPhone: kind.acceptsContactPhone && phone.isNotEmpty ? phone : null,
    );

    setState(() => _failure = null);

    if (entry == null) {
      await _controller.create(draft);
    } else {
      // 版本只从**这一行**读：打开对话框时列表里那一条恰好拿着服务端给的
      // 最新 version，再回状态里绕一圈只会读到一份可能已经过期的别的东西。
      await _controller.update(entry.id, draft, entry.version);
    }
    if (!mounted) return;

    // `_write` 开工时会先 clearFailure，所以此刻读到的非空失败一定是本次造成的。
    final failure = ref.read(dictionaryControllerProvider).failure;
    if (failure == null) {
      Navigator.of(context).pop(const DictionaryEditorSaved());
      return;
    }
    if (failure is ConflictFailure) {
      // 冲突后重试不可能成功（version 已作废），而列表已经被重读过，
      // 关掉对话框、把「刷新后重新操作」交给页面提示 —— 让用户对着一个
      // 必然失败的保存按钮反复点，比什么都糟。
      Navigator.of(context).pop(DictionaryEditorConflict(failure));
      return;
    }
    // 其余失败留在对话框里内联展示，用户敲的内容一个字都不丢。
    setState(() => _failure = failure);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final state = ref.watch(dictionaryControllerProvider);
    final kind = widget.kind;
    final isWriting = state.isWriting;

    return PopScope(
      // 写操作在途时不让对话框被返回键/点外部关掉：那会把结果丢掉，
      // 用户既看不到「保存成功」，也不知道到底存没存上。
      canPop: !isWriting,
      child: AlertDialog(
        title: Text('${_isEditing ? '编辑' : '新增'}${kind.label}'),
        // 可滚动：窄屏上弹出软键盘时，固定高度必然 overflow。
        content: SingleChildScrollView(
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                if (_failure != null) ...<Widget>[
                  _EditorFailureBanner(failure: _failure!),
                  const SizedBox(height: 16),
                ],
                TextFormField(
                  controller: _nameController,
                  autofocus: true,
                  maxLength: _nameMaxLength,
                  decoration: InputDecoration(
                    labelText: '${kind.label}名称',
                    border: const OutlineInputBorder(),
                  ),
                  validator: (String? value) {
                    final name = value?.trim() ?? '';
                    if (name.isEmpty) return '请输入${kind.label}名称';
                    return null;
                  },
                ),
                if (kind.usesParent) ...<Widget>[
                  const SizedBox(height: 4),
                  _buildParentField(theme, state),
                ],
                if (kind.acceptsContactPhone) ...<Widget>[
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _phoneController,
                    keyboardType: TextInputType.phone,
                    decoration: const InputDecoration(
                      labelText: '联系电话',
                      helperText: '可以不填',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: isWriting ? null : () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: isWriting ? null : _submit,
            child: Text(isWriting ? '保存中…' : '保存'),
          ),
        ],
      ),
    );
  }

  /// 父级品名下拉。
  ///
  /// 三种状态给的东西必须不一样：**拉不到**和**确实没有**完全是两回事 ——
  /// 把加载失败读成「一条品名都没有」，用户会跑去做一件根本不需要做的事
  /// （新造一条品名），而他真正需要的是重试。
  Widget _buildParentField(ThemeData theme, DictionaryState state) {
    final parents = state.parentOptions;

    if (parents.isEmpty && state.isLoadingParents) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 12),
        child: Row(
          children: <Widget>[
            SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            SizedBox(width: 12),
            Text('正在加载品名…'),
          ],
        ),
      );
    }

    if (parents.isEmpty) {
      final failure = _parentsFailure;
      return Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                failure == null
                    ? '还没有启用中的品名。型号必须挂在品名下，'
                          '请先到「品名」页新增一条。'
                    : '品名候选加载失败：${FailurePresenter.present(failure).message}',
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 4),
              TextButton(
                onPressed: state.isWriting ? null : _loadParents,
                child: const Text('重新加载品名'),
              ),
            ],
          ),
        ),
      );
    }

    final selected = _parentId;
    final hasSelected =
        selected != null && parents.any((parent) => parent.id == selected);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        DropdownButtonFormField<int>(
          initialValue: selected,
          decoration: const InputDecoration(
            labelText: '所属品名',
            border: OutlineInputBorder(),
          ),
          items: <DropdownMenuItem<int>>[
            for (final parent in parents)
              DropdownMenuItem<int>(value: parent.id, child: Text(parent.name)),
            // 当前值不在候选里（这条型号挂着的品名被停用了，或候选没拉到全）：
            // 补一个占位项，否则 DropdownButton 会直接断言「value 不在 items 里」
            // 崩掉整个对话框。用编号而不是编一个名字 —— 我们确实不知道它叫什么。
            if (selected != null && !hasSelected)
              DropdownMenuItem<int>(
                value: selected,
                child: Text('品名 #$selected'),
              ),
          ],
          onChanged: state.isWriting
              ? null
              : (int? value) => setState(() => _parentId = value),
          validator: (int? value) => value == null ? '请选择型号所属品名' : null,
        ),
        if (selected != null && !hasSelected) ...<Widget>[
          const SizedBox(height: 8),
          Text(
            '当前所属品名不在可选的品名里（可能已被停用），请重新选择。',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.error,
            ),
          ),
        ],
      ],
    );
  }
}

/// 对话框内的失败横幅。
///
/// 不与 `AsyncStateView` 的失败视图复用：那是给整页用的（居中大图标 + 重试按钮），
/// 塞进对话框会把表单挤没了。这里要的是「一条不挡路的说明」。
final class _EditorFailureBanner extends StatelessWidget {
  const _EditorFailureBanner({required this.failure});

  final AppFailure failure;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final presentation = FailurePresenter.present(failure);
    final requestId = presentation.requestId;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            presentation.message,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onErrorContainer,
            ),
          ),
          if (requestId != null) ...<Widget>[
            const SizedBox(height: 4),
            // SelectableText：Request ID 的唯一用途就是被复制走。
            SelectableText(
              '请求 ID：$requestId',
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onErrorContainer,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
