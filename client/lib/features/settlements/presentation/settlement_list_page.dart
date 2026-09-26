import 'package:c_biz_docs_manager/core/auth/auth_controller.dart';
import 'package:c_biz_docs_manager/core/presentation/async_state_view.dart';
import 'package:c_biz_docs_manager/core/presentation/responsive_scaffold.dart';
import 'package:c_biz_docs_manager/features/home/presentation/tenant_shell.dart';
import 'package:c_biz_docs_manager/features/settlements/application/settlement_controller.dart';
import 'package:c_biz_docs_manager/features/settlements/domain/settlement.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

/// 结算单列表页。
///
/// 业务员在这里申请结算、审批人在这里查看全组结算单；数据范围由服务端按
/// `document.view_others` 收敛，客户端不猜。
class SettlementListPage extends ConsumerStatefulWidget {
  const SettlementListPage({super.key});

  @override
  ConsumerState<SettlementListPage> createState() => _SettlementListPageState();
}

class _SettlementListPageState extends ConsumerState<SettlementListPage> {
  late final SettlementController _controller;
  SettlementStatus? _statusFilter;

  @override
  void initState() {
    super.initState();
    _controller = ref.read(settlementControllerProvider.notifier);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _controller.load(SettlementQuery(status: _statusFilter));
    });
  }

  @override
  Widget build(BuildContext context) {
    final profile = ref.watch(authControllerProvider).session?.profile;
    final state = ref.watch(settlementControllerProvider);

    return ResponsiveScaffold(
      title: '结算单',
      destinations: tenantDestinations(profile),
      currentRoute: '/settlements',
      actions: <Widget>[
        IconButton(
          tooltip: '刷新',
          onPressed: _controller.refresh,
          icon: const Icon(Icons.refresh),
        ),
        IconButton(
          tooltip: '申请结算',
          onPressed: () => context.go('/settlements/new'),
          icon: const Icon(Icons.add),
        ),
      ],
      body: Column(
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: DropdownButton<SettlementStatus?>(
                    value: _statusFilter,
                    isExpanded: true,
                    hint: const Text('全部状态'),
                    items: <DropdownMenuItem<SettlementStatus?>>[
                      const DropdownMenuItem<SettlementStatus?>(
                        value: null,
                        child: Text('全部状态'),
                      ),
                      for (final status in SettlementStatus.values)
                        DropdownMenuItem<SettlementStatus?>(
                          value: status,
                          child: Text(_statusLabel(status)),
                        ),
                    ],
                    onChanged: (SettlementStatus? value) {
                      setState(() => _statusFilter = value);
                      _controller.load(SettlementQuery(status: value));
                    },
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: AsyncStateView(
              isLoading: state.isLoading && state.items.isEmpty,
              failure: state.items.isEmpty ? state.failure : null,
              isEmpty: state.items.isEmpty,
              onRetry: _controller.refresh,
              emptyMessage: '暂无结算单',
              child: _SettlementList(items: state.items),
            ),
          ),
        ],
      ),
    );
  }
}

/// 结算单列表：窄屏卡片、宽屏表格。
class _SettlementList extends StatelessWidget {
  const _SettlementList({required this.items});

  final List<SettlementSummary> items;

  @override
  Widget build(BuildContext context) {
    final isWide =
        MediaQuery.sizeOf(context).width >= kResponsiveScaffoldBreakpoint;
    return isWide
        ? _SettlementTable(items: items)
        : _SettlementCardList(items: items);
  }
}

class _SettlementCardList extends StatelessWidget {
  const _SettlementCardList({required this.items});

  final List<SettlementSummary> items;

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: items.length,
      itemBuilder: (BuildContext context, int index) {
        final item = items[index];
        return Card(
          margin: const EdgeInsets.only(bottom: 12),
          child: ListTile(
            title: Text(item.settlementNo),
            subtitle: Text(
              '${item.requester.displayName} · ${item.sourceCount} 张源单',
            ),
            trailing: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: <Widget>[
                Text(
                  item.grossProfit.format(),
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                Text(
                  _statusLabel(item.status),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
            onTap: () => context.go('/settlements/${item.settlementId}'),
          ),
        );
      },
    );
  }
}

class _SettlementTable extends StatelessWidget {
  const _SettlementTable({required this.items});

  final List<SettlementSummary> items;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: DataTable(
        columns: const <DataColumn>[
          DataColumn(label: Text('结算单号')),
          DataColumn(label: Text('状态')),
          DataColumn(label: Text('申请人')),
          DataColumn(label: Text('入库合计')),
          DataColumn(label: Text('出库合计')),
          DataColumn(label: Text('毛利')),
          DataColumn(label: Text('操作')),
        ],
        rows: <DataRow>[
          for (final item in items)
            DataRow(
              cells: <DataCell>[
                DataCell(Text(item.settlementNo)),
                DataCell(Text(_statusLabel(item.status))),
                DataCell(Text(item.requester.displayName)),
                DataCell(Text(item.inboundTotal.format())),
                DataCell(Text(item.outboundTotal.format())),
                DataCell(Text(item.grossProfit.format())),
                DataCell(
                  TextButton(
                    onPressed: () =>
                        context.go('/settlements/${item.settlementId}'),
                    child: const Text('查看'),
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

String _statusLabel(SettlementStatus status) => switch (status) {
  SettlementStatus.pending => '待审批',
  SettlementStatus.approved => '审批通过',
  SettlementStatus.rejected => '审批驳回',
};
