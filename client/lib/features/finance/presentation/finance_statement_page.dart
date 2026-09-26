import 'package:c_biz_docs_manager/core/auth/auth_controller.dart';
import 'package:c_biz_docs_manager/core/presentation/async_state_view.dart';
import 'package:c_biz_docs_manager/core/presentation/responsive_scaffold.dart';
import 'package:c_biz_docs_manager/features/documents/domain/document.dart';
import 'package:c_biz_docs_manager/features/finance/application/finance_controller.dart';
import 'package:c_biz_docs_manager/features/finance/domain/finance.dart';
import 'package:c_biz_docs_manager/features/home/presentation/tenant_shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 单张单据的结清视图 + 财务登记入口。
///
/// 「已付 / 未付 / 已收 / 未收 / 开票状态」全部由服务端按记录推导，这里**直接展示
/// 服务端结果**，客户端不做任何金额运算。登记动作按单据方向决定可用的记录类型：
/// 入库单可付款与开票，出库单可收款（`kind` 由动作决定，请求体不带 kind）。
class FinanceStatementPage extends ConsumerStatefulWidget {
  const FinanceStatementPage({required this.documentId, super.key});

  final int documentId;

  @override
  ConsumerState<FinanceStatementPage> createState() =>
      _FinanceStatementPageState();
}

class _FinanceStatementPageState extends ConsumerState<FinanceStatementPage> {
  late final FinanceController _primaryController;

  @override
  void initState() {
    super.initState();
    // 结清视图与单据方向无关，但两个方向各有一个主流程（入库=付款、出库=收款），
    // 统一用「付款」这一侧加载结清视图，避免为它再单开一个 controller。
    _primaryController = ref.read(
      financeControllerProvider(FinanceKind.payment).notifier,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _load();
    });
  }

  void _load() => _primaryController.loadStatement(widget.documentId);

  /// 登记一条记录：用对应 kind 的 controller 提交，再刷新结清视图。
  Future<void> _register(FinanceKind kind, FinanceRecordDraft draft) async {
    await ref.read(financeControllerProvider(kind).notifier).create(draft);
    if (!mounted) return;
    _load();
  }

  /// 撤销一条记录（硬删除），随后刷新结清视图。
  Future<void> _revoke(FinanceKind kind, int recordId) async {
    await ref.read(financeControllerProvider(kind).notifier).revoke(recordId);
    if (!mounted) return;
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final profile = ref.watch(authControllerProvider).session?.profile;
    final state = ref.watch(financeControllerProvider(FinanceKind.payment));
    final statement = state.statement;
    final canRecord = profile?.hasPermission('finance.record') ?? false;

    return ResponsiveScaffold(
      title: '结清视图',
      destinations: tenantDestinations(profile),
      currentRoute: '/finance/statements/${widget.documentId}',
      actions: <Widget>[
        IconButton(
          tooltip: '刷新',
          onPressed: _load,
          icon: const Icon(Icons.refresh),
        ),
      ],
      body: AsyncStateView(
        isLoading: state.isLoadingStatement && statement == null,
        failure: statement == null ? state.failure : null,
        isEmpty: statement == null && !state.isLoadingStatement,
        onRetry: _load,
        emptyMessage: '该单据暂无结清数据',
        child: statement == null
            ? const SizedBox.shrink()
            : _StatementBody(
                statement: statement,
                canRecord: canRecord,
                isWriting: state.isWriting,
                onRegister: _register,
                onRevoke: _revoke,
              ),
      ),
    );
  }
}

class _StatementBody extends StatelessWidget {
  const _StatementBody({
    required this.statement,
    required this.canRecord,
    required this.isWriting,
    required this.onRegister,
    required this.onRevoke,
  });

  final FinanceStatement statement;
  final bool canRecord;
  final bool isWriting;
  final Future<void> Function(FinanceKind kind, FinanceRecordDraft draft)
  onRegister;
  final Future<void> Function(FinanceKind kind, int recordId) onRevoke;

  bool get _isInbound => statement.documentKind == DocumentKind.inbound;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: <Widget>[
        Text(statement.documentNo, style: theme.textTheme.titleMedium),
        Text(
          '${statement.partyName} · ${statement.businessUser.displayName} · '
          '${_formatDate(statement.businessDate)}',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 12),
        _MetricRow(
          label: '单据总额',
          value: statement.totalAmount.format(),
          upper: statement.totalUpper,
        ),
        const Divider(),
        if (_isInbound) ...<Widget>[
          _MetricRow(label: '已付', value: statement.paidAmount.format()),
          _MetricRow(label: '未付', value: statement.unpaidAmount.format()),
          _MetricRow(label: '已开票', value: statement.invoicedAmount.format()),
          _MetricRow(label: '未开票', value: statement.uninvoicedAmount.format()),
          _MetricRow(label: '开票状态', value: statement.invoiceStatus.label),
        ] else ...<Widget>[
          _MetricRow(label: '已收', value: statement.receivedAmount.format()),
          _MetricRow(label: '未收', value: statement.unreceivedAmount.format()),
        ],
        const SizedBox(height: 16),
        if (canRecord) _registerActions(context),
        const SizedBox(height: 16),
        const Text('登记记录', style: TextStyle(fontWeight: FontWeight.bold)),
        if (statement.records.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Text('暂无记录'),
          ),
        for (final record in statement.records)
          _RecordTile(
            record: record,
            canRevoke: canRecord && !isWriting,
            onRevoke: () => onRevoke(record.kind, record.recordId),
          ),
      ],
    );
  }

  /// 按单据方向给出可用的登记动作。
  Widget _registerActions(BuildContext context) {
    final actions = <Widget>[
      if (_isInbound)
        FilledButton(
          onPressed: () => _openRegister(context, FinanceKind.payment),
          child: const Text('登记付款'),
        )
      else
        FilledButton(
          onPressed: () => _openRegister(context, FinanceKind.receipt),
          child: const Text('登记收款'),
        ),
      if (_isInbound)
        OutlinedButton(
          onPressed: () => _openRegister(context, FinanceKind.invoice),
          child: const Text('登记开票'),
        ),
    ];
    return Wrap(spacing: 12, runSpacing: 12, children: actions);
  }

  Future<void> _openRegister(BuildContext context, FinanceKind kind) async {
    final draft = await FinanceRecordDialog.show(
      context,
      kind: kind,
      documentId: statement.documentId,
    );
    if (draft != null) {
      await onRegister(kind, draft);
    }
  }
}

class _MetricRow extends StatelessWidget {
  const _MetricRow({required this.label, required this.value, this.upper});

  final String label;
  final String value;
  final String? upper;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(width: 88, child: Text(label)),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(value),
                if (upper != null)
                  Text(upper!, style: theme.textTheme.bodySmall),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _RecordTile extends StatelessWidget {
  const _RecordTile({
    required this.record,
    required this.canRevoke,
    required this.onRevoke,
  });

  final FinanceRecord record;
  final bool canRevoke;
  final VoidCallback onRevoke;

  @override
  Widget build(BuildContext context) {
    final extra = <String>[
      if (record.method != null) record.method!.label,
      if (record.cardTail != null) '尾号${record.cardTail}',
      if (record.methodNote != null) record.methodNote!,
      if (record.invoiceNo != null) '发票号 ${record.invoiceNo}',
    ].join(' · ');
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      title: Text('${record.kind.label} ${record.amount.format()}'),
      subtitle: Text(
        '${_formatDate(record.occurredOn)} · ${record.createdBy.displayName}'
        '${extra.isEmpty ? '' : ' · $extra'}',
      ),
      trailing: canRevoke
          ? IconButton(
              tooltip: '撤销该记录',
              onPressed: onRevoke,
              icon: const Icon(Icons.undo),
            )
          : null,
    );
  }
}

/// 登记财务记录的对话框：金额 + 发生日期 + 类型相关字段。
///
/// 「方式」三态字段互斥：转账可备注、对私卡必填后 4 位、对公账户两者都不带；
/// 开票只填发票号。这样就不会造出自相矛盾的请求。
final class FinanceRecordDialog extends StatefulWidget {
  const FinanceRecordDialog({
    required this.kind,
    required this.documentId,
    super.key,
  });

  final FinanceKind kind;
  final int documentId;

  static Future<FinanceRecordDraft?> show(
    BuildContext context, {
    required FinanceKind kind,
    required int documentId,
  }) => showDialog<FinanceRecordDraft>(
    context: context,
    builder: (BuildContext context) =>
        FinanceRecordDialog(kind: kind, documentId: documentId),
  );

  @override
  State<FinanceRecordDialog> createState() => _FinanceRecordDialogState();
}

class _FinanceRecordDialogState extends State<FinanceRecordDialog> {
  final TextEditingController _amountController = TextEditingController();
  final TextEditingController _occurredOnController = TextEditingController(
    text: _today(),
  );
  final TextEditingController _methodNoteController = TextEditingController();
  final TextEditingController _cardTailController = TextEditingController();
  final TextEditingController _invoiceNoController = TextEditingController();
  FinanceMethod _method = FinanceMethod.transfer;
  String? _error;

  static String _today() {
    final now = DateTime.now();
    return '${now.year}-${now.month.toString().padLeft(2, '0')}-'
        '${now.day.toString().padLeft(2, '0')}';
  }

  @override
  void dispose() {
    _amountController.dispose();
    _occurredOnController.dispose();
    _methodNoteController.dispose();
    _cardTailController.dispose();
    _invoiceNoController.dispose();
    super.dispose();
  }

  void _submit() {
    final amount = _amountController.text.trim();
    final occurredOn = _occurredOnController.text.trim();
    if (amount.isEmpty || occurredOn.isEmpty) {
      setState(() => _error = '请填写金额与发生日期');
      return;
    }
    if (widget.kind.carriesMethod) {
      final cardTail = _cardTailController.text.trim();
      if (_method == FinanceMethod.privateCard && cardTail.isEmpty) {
        setState(() => _error = '对私卡必须填写卡号后 4 位');
        return;
      }
    }
    Navigator.of(context).pop(
      FinanceRecordDraft(
        documentId: widget.documentId,
        amount: amount,
        occurredOn: occurredOn,
        method: widget.kind.carriesMethod ? _method : null,
        // 三态字段互斥：只有转账带备注、只有对私卡带尾号。
        methodNote: _method == FinanceMethod.transfer
            ? _nonEmpty(_methodNoteController.text)
            : null,
        cardTail: _method == FinanceMethod.privateCard
            ? _nonEmpty(_cardTailController.text)
            : null,
        invoiceNo: widget.kind.carriesInvoiceNo
            ? _nonEmpty(_invoiceNoController.text)
            : null,
      ),
    );
  }

  String? _nonEmpty(String value) {
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('登记${widget.kind.label}'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            TextField(
              controller: _amountController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: '金额',
                hintText: '如 30000.00',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _occurredOnController,
              decoration: const InputDecoration(
                labelText: '发生日期',
                hintText: '如 2026-09-22',
              ),
            ),
            if (widget.kind.carriesMethod) ...<Widget>[
              const SizedBox(height: 12),
              DropdownButtonFormField<FinanceMethod>(
                initialValue: _method,
                decoration: const InputDecoration(labelText: '方式'),
                items: <DropdownMenuItem<FinanceMethod>>[
                  for (final method in FinanceMethod.values)
                    DropdownMenuItem<FinanceMethod>(
                      value: method,
                      child: Text(method.label),
                    ),
                ],
                onChanged: (FinanceMethod? value) {
                  if (value != null) setState(() => _method = value);
                },
              ),
              if (_method == FinanceMethod.transfer) ...<Widget>[
                const SizedBox(height: 12),
                TextField(
                  controller: _methodNoteController,
                  decoration: const InputDecoration(
                    labelText: '备注（可选，如 微信/支付宝）',
                  ),
                ),
              ],
              if (_method == FinanceMethod.privateCard) ...<Widget>[
                const SizedBox(height: 12),
                TextField(
                  controller: _cardTailController,
                  decoration: const InputDecoration(labelText: '卡号后 4 位'),
                ),
              ],
            ],
            if (widget.kind.carriesInvoiceNo) ...<Widget>[
              const SizedBox(height: 12),
              TextField(
                controller: _invoiceNoController,
                decoration: const InputDecoration(labelText: '发票号（可选）'),
              ),
            ],
            if (_error != null) ...<Widget>[
              const SizedBox(height: 12),
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _submit, child: const Text('登记')),
      ],
    );
  }
}

String _formatDate(DateTime date) =>
    '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
