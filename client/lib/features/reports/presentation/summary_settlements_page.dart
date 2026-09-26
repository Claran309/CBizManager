import 'package:c_biz_docs_manager/core/auth/auth_controller.dart';
import 'package:c_biz_docs_manager/core/presentation/async_state_view.dart';
import 'package:c_biz_docs_manager/core/presentation/responsive_scaffold.dart';
import 'package:c_biz_docs_manager/features/home/presentation/tenant_shell.dart';
import 'package:c_biz_docs_manager/features/reports/application/report_controller.dart';
import 'package:c_biz_docs_manager/features/reports/domain/report.dart';
import 'package:c_biz_docs_manager/features/reports/presentation/report_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 月度总结算快照列表与生成入口。
///
/// 快照**生成即冻结**（无修改接口），要更正只能重新生成。
class SummarySettlementsPage extends ConsumerStatefulWidget {
  const SummarySettlementsPage({super.key});

  @override
  ConsumerState<SummarySettlementsPage> createState() =>
      _SummarySettlementsPageState();
}

class _SummarySettlementsPageState
    extends ConsumerState<SummarySettlementsPage> {
  late final ReportController _controller;
  final TextEditingController _periodController = TextEditingController(
    text: currentPeriod(),
  );
  ReportScope _scope = ReportScope.company;

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
    _controller.loadSnapshots(
      SnapshotQuery(period: _periodController.text.trim()),
    );
  }

  Future<void> _generate() async {
    await _controller.createSnapshots(
      CreateSnapshotDraft(period: _periodController.text.trim(), scope: _scope),
    );
  }

  @override
  Widget build(BuildContext context) {
    final profile = ref.watch(authControllerProvider).session?.profile;
    final state = ref.watch(reportControllerProvider);

    return ResponsiveScaffold(
      title: '总结算',
      destinations: tenantDestinations(profile),
      currentRoute: '/reports/summary-settlements',
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
            child: Column(
              children: <Widget>[
                Row(
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
                    SizedBox(
                      width: 160,
                      child: DropdownButtonFormField<ReportScope>(
                        initialValue: _scope,
                        decoration: const InputDecoration(
                          labelText: '维度',
                          isDense: true,
                        ),
                        items: <DropdownMenuItem<ReportScope>>[
                          for (final scope in ReportScope.values)
                            DropdownMenuItem<ReportScope>(
                              value: scope,
                              child: Text(scope.label),
                            ),
                        ],
                        onChanged: (ReportScope? value) {
                          if (value != null) setState(() => _scope = value);
                        },
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  children: <Widget>[
                    FilledButton(
                      onPressed: state.isWriting ? null : _generate,
                      child: const Text('生成总结算'),
                    ),
                    const SizedBox(width: 12),
                    OutlinedButton(onPressed: _load, child: const Text('查询')),
                  ],
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: AsyncStateView(
              isLoading: state.isLoadingSnapshots && state.snapshots.isEmpty,
              failure: state.snapshots.isEmpty ? state.failure : null,
              isEmpty: state.snapshots.isEmpty && !state.isLoadingSnapshots,
              onRetry: _load,
              emptyMessage: '暂无总结算快照',
              child: ListView.builder(
                padding: const EdgeInsets.all(16),
                itemCount: state.snapshots.length,
                itemBuilder: (BuildContext context, int index) =>
                    _SnapshotCard(snapshot: state.snapshots[index]),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SnapshotCard extends StatelessWidget {
  const _SnapshotCard({required this.snapshot});

  final ReportSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final businessUser = snapshot.businessUser;
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(snapshot.snapshotNo, style: theme.textTheme.titleMedium),
            Text(
              '批次 ${snapshot.batchNo} · ${snapshot.period} · ${snapshot.scope.label}'
              '${businessUser == null ? '' : ' · ${businessUser.displayName}'}',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 4),
            Text('入库 ${snapshot.inboundAmount.format()} 元'),
            Text('出库 ${snapshot.outboundAmount.format()} 元'),
            Text(
              '毛利 ${snapshot.grossProfit.format()} 元'
              '（${snapshot.grossProfitUpper}，毛利率 ${snapshot.grossMarginPercent}%）',
            ),
            Text(
              '${snapshot.documentCount} 张单据',
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}
