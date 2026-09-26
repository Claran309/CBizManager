import 'package:c_biz_docs_manager/core/auth/auth_controller.dart';
import 'package:c_biz_docs_manager/core/presentation/async_state_view.dart';
import 'package:c_biz_docs_manager/core/presentation/responsive_scaffold.dart';
import 'package:c_biz_docs_manager/features/documents/domain/document.dart';
import 'package:c_biz_docs_manager/features/home/presentation/tenant_shell.dart';
import 'package:c_biz_docs_manager/features/reports/application/report_controller.dart';
import 'package:c_biz_docs_manager/features/reports/domain/report.dart';
import 'package:c_biz_docs_manager/features/reports/presentation/report_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 入库 / 出库统计页（FR-BACK-02 / 03）。
///
/// 合计块是单据粒度的精确数字；明细行只给金额与数量（付款挂单据不挂明细，
/// 摊到明细只会有「假精确」）。
class ReportStatsPage extends ConsumerStatefulWidget {
  const ReportStatsPage({required this.kind, super.key});

  final DocumentKind kind;

  @override
  ConsumerState<ReportStatsPage> createState() => _ReportStatsPageState();
}

class _ReportStatsPageState extends ConsumerState<ReportStatsPage> {
  late final ReportController _controller;
  final TextEditingController _periodController = TextEditingController(
    text: currentPeriod(),
  );

  bool get _isInbound => widget.kind == DocumentKind.inbound;

  @override
  void initState() {
    super.initState();
    _controller = ref.read(reportControllerProvider.notifier);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _load();
    });
  }

  @override
  void dispose() {
    _periodController.dispose();
    super.dispose();
  }

  void _load() {
    final query = StatsQuery(period: _periodController.text.trim());
    if (_isInbound) {
      _controller.loadInboundStats(query);
    } else {
      _controller.loadOutboundStats(query);
    }
  }

  /// 数据未到时返回占位（`AsyncStateView` 会用 loading / 空态覆盖它）。
  Widget _statsBody(ReportState state) {
    if (_isInbound) {
      final stats = state.inboundStats;
      return stats == null
          ? const SizedBox.shrink()
          : _InboundStatsBody(stats: stats);
    }
    final stats = state.outboundStats;
    return stats == null
        ? const SizedBox.shrink()
        : _OutboundStatsBody(stats: stats);
  }

  @override
  Widget build(BuildContext context) {
    final profile = ref.watch(authControllerProvider).session?.profile;
    final state = ref.watch(reportControllerProvider);
    final title = _isInbound ? '入库统计' : '出库统计';
    final hasData = _isInbound
        ? state.inboundStats != null
        : state.outboundStats != null;
    final isLoading = _isInbound
        ? state.isLoadingInboundStats
        : state.isLoadingOutboundStats;

    return ResponsiveScaffold(
      title: title,
      destinations: tenantDestinations(profile),
      currentRoute: _isInbound
          ? '/reports/inbound-stats'
          : '/reports/outbound-stats',
      actions: <Widget>[
        IconButton(
          tooltip: '刷新',
          onPressed: _load,
          icon: const Icon(Icons.refresh),
        ),
      ],
      body: Column(
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: TextField(
                    controller: _periodController,
                    decoration: const InputDecoration(
                      labelText: '统计周期',
                      hintText: '如 2026-09',
                      isDense: true,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                FilledButton(onPressed: _load, child: const Text('查询')),
              ],
            ),
          ),
          Expanded(
            child: AsyncStateView(
              isLoading: isLoading && !hasData,
              failure: hasData ? null : state.failure,
              isEmpty: !hasData && !isLoading,
              onRetry: _load,
              emptyMessage: '暂无数据',
              // child 实参会被提前求值（不受 isEmpty/isLoading 控制），所以这里
              // 必须先判空 —— 首帧数据还没到，直接 `!` 会崩。
              child: _statsBody(state),
            ),
          ),
        ],
      ),
    );
  }
}

class _InboundStatsBody extends StatelessWidget {
  const _InboundStatsBody({required this.stats});

  final InboundStats stats;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      children: <Widget>[
        ReportMetricCard(
          title: '金额合计',
          primary: '${stats.amountTotal.format()} 元',
          secondary: stats.amountTotalUpper,
          extra: '${stats.documentCount} 张单据 · 供应商 ${stats.supplierCount} 家',
        ),
        ReportMetricCard(
          title: '付款情况',
          primary: '已付 ${stats.paidAmount.format()} 元',
          secondary:
              '未付 ${stats.unpaidAmount.format()} 元（${stats.unpaidAmountUpper}）',
          extra: '未付清 ${stats.unpaidDocumentCount} 张',
        ),
        ReportMetricCard(
          title: '开票状态',
          primary: '已开 ${stats.invoicedAmount.format()} 元',
          secondary:
              '未开 ${stats.uninvoicedAmount.format()} 元（${stats.uninvoicedAmountUpper}）',
          extra: '未开票 ${stats.uninvoicedDocumentCount} 张',
        ),
        const SizedBox(height: 8),
        _ItemRows(items: stats.items),
      ],
    );
  }
}

class _OutboundStatsBody extends StatelessWidget {
  const _OutboundStatsBody({required this.stats});

  final OutboundStats stats;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      children: <Widget>[
        ReportMetricCard(
          title: '金额合计',
          primary: '${stats.amountTotal.format()} 元',
          secondary: stats.amountTotalUpper,
          extra: '${stats.documentCount} 张单据 · 客户 ${stats.customerCount} 家',
        ),
        ReportMetricCard(
          title: '收款情况',
          primary: '已收 ${stats.receivedAmount.format()} 元',
          secondary:
              '未收 ${stats.unreceivedAmount.format()} 元（${stats.unreceivedAmountUpper}）',
          extra: '未收清 ${stats.unreceivedDocumentCount} 张',
        ),
        for (final sale in stats.saleAmountTypes)
          ReportMetricCard(
            title: sale.saleAmountType.wireValue,
            primary: '${sale.amount.format()} 元',
            secondary: sale.amountUpper,
            extra: '占比 ${sale.sharePercent}%（${sale.sharePpm} ppm）',
          ),
        const SizedBox(height: 8),
        _ItemRows(items: stats.items),
      ],
    );
  }
}

/// 明细聚合行：只给金额与数量。
class _ItemRows extends StatelessWidget {
  const _ItemRows({required this.items});

  final List<ReportItem> items;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 8),
        child: Text('暂无明细'),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 8),
          child: Text('明细汇总', style: TextStyle(fontWeight: FontWeight.bold)),
        ),
        for (final item in items)
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: Text(
              item.productModel == null
                  ? item.productName
                  : '${item.productName} · ${item.productModel}',
            ),
            subtitle: Text(
              '${item.partyName} · 数量 ${item.quantity.format()}'
              '${item.unit == null ? '' : ' ${item.unit}'}',
            ),
            trailing: Text(item.amount.format()),
          ),
      ],
    );
  }
}
