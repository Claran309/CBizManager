import 'package:c_biz_docs_manager/core/auth/auth_controller.dart';
import 'package:c_biz_docs_manager/core/presentation/async_state_view.dart';
import 'package:c_biz_docs_manager/core/presentation/responsive_scaffold.dart';
import 'package:c_biz_docs_manager/features/home/presentation/tenant_shell.dart';
import 'package:c_biz_docs_manager/features/reports/application/report_controller.dart';
import 'package:c_biz_docs_manager/features/reports/domain/report.dart';
import 'package:c_biz_docs_manager/features/reports/presentation/report_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

/// 报表看板（FR-BACK-01 / 02 / 03 的合计指标）。
///
/// 金额与大写直接透传服务端；比率同时展示服务端的 `*_percent` 文本与 ppm 原值。
/// **全部数字都是服务端按「全组」口径算好的**，客户端不做任何金额运算。
class ReportOverviewPage extends ConsumerStatefulWidget {
  const ReportOverviewPage({super.key});

  @override
  ConsumerState<ReportOverviewPage> createState() => _ReportOverviewPageState();
}

class _ReportOverviewPageState extends ConsumerState<ReportOverviewPage> {
  late final ReportController _controller;
  final TextEditingController _periodController = TextEditingController(
    text: currentPeriod(),
  );

  @override
  void initState() {
    super.initState();
    _controller = ref.read(reportControllerProvider.notifier);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _controller.loadOverview(
        PeriodQuery(period: _periodController.text.trim()),
      );
    });
  }

  @override
  void dispose() {
    _periodController.dispose();
    super.dispose();
  }

  void _load() {
    final period = _periodController.text.trim();
    _controller.loadOverview(PeriodQuery(period: period));
    _controller.loadBusinessUsers(period);
  }

  @override
  Widget build(BuildContext context) {
    final profile = ref.watch(authControllerProvider).session?.profile;
    final state = ref.watch(reportControllerProvider);
    final overview = state.overview;

    return ResponsiveScaffold(
      title: '报表',
      destinations: tenantDestinations(profile),
      currentRoute: '/reports',
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
              isLoading: state.isLoadingOverview && overview == null,
              failure: overview == null ? state.failure : null,
              isEmpty: overview == null && !state.isLoadingOverview,
              onRetry: _load,
              emptyMessage: '暂无数据',
              child: overview == null
                  ? const SizedBox.shrink()
                  : _OverviewBody(overview: overview),
            ),
          ),
        ],
      ),
    );
  }
}

class _OverviewBody extends StatelessWidget {
  const _OverviewBody({required this.overview});

  final ReportOverview overview;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      children: <Widget>[
        ReportMetricCard(
          title: '入库',
          primary: '${overview.inboundAmount.format()} 元',
          secondary: overview.inboundAmountUpper,
          extra: '${overview.inboundDocumentCount} 张单据',
        ),
        ReportMetricCard(
          title: '出库',
          primary: '${overview.outboundAmount.format()} 元',
          secondary: overview.outboundAmountUpper,
          extra: '${overview.outboundDocumentCount} 张单据',
        ),
        ReportMetricCard(
          title: '毛利',
          primary: '${overview.grossProfit.format()} 元',
          secondary: overview.grossProfitUpper,
          extra:
              '毛利率 ${overview.grossMarginPercent}%（${overview.grossMarginPpm} ppm）',
        ),
        ReportMetricCard(
          title: '付款',
          primary: '已付 ${overview.paidAmount.format()} 元',
          secondary:
              '未付 ${overview.unpaidAmount.format()} 元（${overview.unpaidAmountUpper}）',
          extra: '未付清 ${overview.unpaidDocumentCount} 张',
        ),
        ReportMetricCard(
          title: '开票',
          primary: '已开 ${overview.invoicedAmount.format()} 元',
          secondary:
              '未开 ${overview.uninvoicedAmount.format()} 元（${overview.uninvoicedAmountUpper}）',
          extra: '未开票 ${overview.uninvoicedDocumentCount} 张',
        ),
        ReportMetricCard(
          title: '收款',
          primary: '已收 ${overview.receivedAmount.format()} 元',
          secondary:
              '未收 ${overview.unreceivedAmount.format()} 元（${overview.unreceivedAmountUpper}）',
          extra: '未收清 ${overview.unreceivedDocumentCount} 张',
        ),
        ReportMetricCard(
          title: '往来单位',
          primary: '供应商 ${overview.supplierCount} 家',
          secondary: '客户 ${overview.customerCount} 家',
        ),
        if (overview.saleAmountTypes.isNotEmpty) ...<Widget>[
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Text(
              '销售金额分项',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
          for (final sale in overview.saleAmountTypes)
            ReportMetricCard(
              title: sale.saleAmountType.wireValue,
              primary: '${sale.amount.format()} 元',
              secondary: sale.amountUpper,
              extra: '占比 ${sale.sharePercent}%（${sale.sharePpm} ppm）',
            ),
        ],
        const SizedBox(height: 16),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: <Widget>[
            OutlinedButton(
              onPressed: () => context.go('/reports/inbound-stats'),
              child: const Text('入库统计'),
            ),
            OutlinedButton(
              onPressed: () => context.go('/reports/outbound-stats'),
              child: const Text('出库统计'),
            ),
            OutlinedButton(
              onPressed: () => context.go('/reports/summary-settlements'),
              child: const Text('总结算'),
            ),
          ],
        ),
      ],
    );
  }
}
