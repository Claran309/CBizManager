import 'package:c_biz_docs_manager/core/auth/auth_controller.dart';
import 'package:c_biz_docs_manager/core/money/money.dart';
import 'package:c_biz_docs_manager/core/presentation/async_state_view.dart';
import 'package:c_biz_docs_manager/core/presentation/responsive_scaffold.dart';
import 'package:c_biz_docs_manager/features/home/presentation/tenant_shell.dart';
import 'package:c_biz_docs_manager/features/settlements/application/settlement_controller.dart';
import 'package:c_biz_docs_manager/features/settlements/domain/settlement.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 结算单详情与审批页。
///
/// 展示金额快照（入库/出库/毛利 + 大写）、源单据、审批记录；
/// 「通过 / 驳回」按钮按 `settlement.approve` 权限裁剪，驳回必须填备注（本地拦，
/// 不发请求）。审批通过与驳回都是终态，已审批的单据不再显示审批按钮。
class SettlementDetailPage extends ConsumerStatefulWidget {
  const SettlementDetailPage({required this.settlementId, super.key});

  final int settlementId;

  @override
  ConsumerState<SettlementDetailPage> createState() =>
      _SettlementDetailPageState();
}

class _SettlementDetailPageState extends ConsumerState<SettlementDetailPage> {
  late final SettlementController _controller;

  @override
  void initState() {
    super.initState();
    _controller = ref.read(settlementControllerProvider.notifier);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _controller.loadDetail(widget.settlementId);
    });
  }

  @override
  Widget build(BuildContext context) {
    final profile = ref.watch(authControllerProvider).session?.profile;
    final state = ref.watch(settlementControllerProvider);
    final detail = state.detail;

    return ResponsiveScaffold(
      title: '结算单详情',
      destinations: tenantDestinations(profile),
      currentRoute: '/settlements/${widget.settlementId}',
      body: AsyncStateView(
        isLoading: state.isLoadingDetail,
        failure: detail == null ? state.failure : null,
        isEmpty: detail == null && !state.isLoadingDetail,
        onRetry: () => _controller.loadDetail(widget.settlementId),
        emptyMessage: '结算单不存在',
        child: detail == null
            ? const SizedBox.shrink()
            : _SettlementDetailView(
                detail: detail,
                canApprove:
                    profile?.hasPermission('settlement.approve') ?? false,
                isWriting: state.isWriting,
                onApprove: () =>
                    _controller.approve(detail.settlementId, detail.version),
                onReject: () => _confirmReject(detail),
              ),
      ),
    );
  }

  /// 驳回：弹出对话框，备注为空时本地拦下、不发请求。
  Future<void> _confirmReject(SettlementDetail detail) async {
    final remarkController = TextEditingController();
    final remark = await showDialog<String>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('驳回结算单'),
        content: TextField(
          controller: remarkController,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: '驳回原因',
            hintText: '必填，说明驳回理由',
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              final text = remarkController.text.trim();
              if (text.isEmpty) {
                // 本地拦下：不给服务端发一个必填字段缺失的请求。
                return;
              }
              Navigator.of(context).pop(text);
            },
            child: const Text('驳回'),
          ),
        ],
      ),
    );
    remarkController.dispose();
    if (remark != null && remark.isNotEmpty) {
      await _controller.reject(detail.settlementId, detail.version, remark);
    }
  }
}

/// 结算单详情的静态展示。
class _SettlementDetailView extends StatelessWidget {
  const _SettlementDetailView({
    required this.detail,
    required this.canApprove,
    required this.isWriting,
    required this.onApprove,
    required this.onReject,
  });

  final SettlementDetail detail;
  final bool canApprove;
  final bool isWriting;
  final VoidCallback onApprove;
  final VoidCallback onReject;

  @override
  Widget build(BuildContext context) {
    final isTerminal = detail.status.isTerminal;
    // 审批按钮只在「待审批 + 有审批权限」时显示；已审批（终态）不再显示。
    final showApproveActions = canApprove && !isTerminal;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: <Widget>[
        _InfoRow(label: '结算单号', value: detail.settlementNo),
        _InfoRow(label: '状态', value: _statusLabel(detail.status)),
        _InfoRow(label: '申请人', value: detail.requester.displayName),
        _InfoRow(label: '源单据数', value: '${detail.sourceCount} 张'),
        const Divider(),
        _AmountRow(
          label: '入库合计',
          amount: detail.inboundTotal,
          upper: detail.inboundUpper,
        ),
        _AmountRow(
          label: '出库合计',
          amount: detail.outboundTotal,
          upper: detail.outboundUpper,
        ),
        _AmountRow(
          label: '毛利',
          amount: detail.grossProfit,
          upper: detail.grossProfitUpper,
        ),
        if (detail.decisionRemark != null) ...<Widget>[
          const Divider(),
          _InfoRow(label: '审批意见', value: detail.decisionRemark!),
        ],
        if (showApproveActions) ...<Widget>[
          const SizedBox(height: 24),
          Row(
            children: <Widget>[
              Expanded(
                child: FilledButton(
                  onPressed: isWriting ? null : onApprove,
                  child: const Text('通过'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton(
                  onPressed: isWriting ? null : onReject,
                  child: const Text('驳回'),
                ),
              ),
            ],
          ),
        ],
        const SizedBox(height: 16),
        const Text('源单据', style: TextStyle(fontWeight: FontWeight.bold)),
        for (final source in detail.sources) _SourceRow(source: source),
        if (detail.approvalRecords.isNotEmpty) ...<Widget>[
          const SizedBox(height: 16),
          const Text('审批记录', style: TextStyle(fontWeight: FontWeight.bold)),
          for (final record in detail.approvalRecords)
            _RecordRow(record: record),
        ],
      ],
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(width: 88, child: Text(label)),
          Expanded(child: Text(value)),
        ],
      ),
    );
  }
}

class _AmountRow extends StatelessWidget {
  const _AmountRow({
    required this.label,
    required this.amount,
    required this.upper,
  });

  final String label;
  final Amount amount;
  final String upper;

  @override
  Widget build(BuildContext context) {
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
                Text(amount.format()),
                Text(upper, style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SourceRow extends StatelessWidget {
  const _SourceRow({required this.source});

  final SettlementSource source;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      title: Text(source.documentNo),
      subtitle: Text(
        '${source.businessUser.displayName} · ${_formatDate(source.businessDate)}${source.released ? ' · 已释放' : ''}',
      ),
      trailing: Text(source.amount.format()),
    );
  }
}

class _RecordRow extends StatelessWidget {
  const _RecordRow({required this.record});

  final SettlementApprovalRecord record;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      title: Text(
        '${record.operator.displayName} · ${_actionLabel(record.action)}',
      ),
      subtitle: record.remark == null ? null : Text(record.remark!),
      trailing: Text(_formatDateTime(record.createdAt)),
    );
  }
}

String _statusLabel(SettlementStatus status) => switch (status) {
  SettlementStatus.pending => '待审批',
  SettlementStatus.approved => '审批通过',
  SettlementStatus.rejected => '审批驳回',
};

String _actionLabel(SettlementAction action) => switch (action) {
  SettlementAction.submitted => '提交申请',
  SettlementAction.approved => '审批通过',
  SettlementAction.rejected => '审批驳回',
};

String _formatDate(DateTime date) =>
    '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

String _formatDateTime(DateTime date) =>
    '${_formatDate(date)} ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
