import 'package:c_biz_docs_manager/core/auth/auth_controller.dart';
import 'package:c_biz_docs_manager/core/presentation/async_state_view.dart';
import 'package:c_biz_docs_manager/core/presentation/responsive_scaffold.dart';
import 'package:c_biz_docs_manager/features/documents/application/document_controller.dart';
import 'package:c_biz_docs_manager/features/documents/domain/document.dart';
import 'package:c_biz_docs_manager/features/home/presentation/tenant_shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

/// 单据历史列表页。
///
/// 入库单与出库单共用本页，由 [kind] 决定标题、单号前缀与目标路由。
/// 数据范围（本人 / 全组）由服务端按 `document.view_others` 收敛，客户端不猜。
class DocumentHistoryPage extends ConsumerStatefulWidget {
  const DocumentHistoryPage({required this.kind, super.key});

  final DocumentKind kind;

  @override
  ConsumerState<DocumentHistoryPage> createState() =>
      _DocumentHistoryPageState();
}

class _DocumentHistoryPageState extends ConsumerState<DocumentHistoryPage> {
  late final DocumentController _controller;

  DocumentStatus? _statusFilter;

  @override
  void initState() {
    super.initState();
    _controller = ref.read(documentControllerProvider(widget.kind).notifier);
    // 首帧之后才碰状态：initState 期间触发状态变化会撞「build 期间改状态」断言。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _controller.load(DocumentQuery(status: _statusFilter));
    });
  }

  String get _kindSegment =>
      widget.kind == DocumentKind.outbound ? 'outbound' : 'inbound';

  String get _title => widget.kind == DocumentKind.outbound ? '出库单' : '入库单';

  @override
  Widget build(BuildContext context) {
    final profile = ref.watch(authControllerProvider).session?.profile;
    final state = ref.watch(documentControllerProvider(widget.kind));

    return ResponsiveScaffold(
      title: _title,
      destinations: tenantDestinations(profile),
      currentRoute: '/documents/$_kindSegment',
      actions: <Widget>[
        IconButton(
          tooltip: '刷新',
          onPressed: _controller.refresh,
          icon: const Icon(Icons.refresh),
        ),
        IconButton(
          tooltip: '新建$_title',
          onPressed: () => context.go('/documents/$_kindSegment/new'),
          icon: const Icon(Icons.add),
        ),
      ],
      body: Column(
        children: <Widget>[
          _DocumentFilters(
            kind: widget.kind,
            statusFilter: _statusFilter,
            onStatusChanged: (DocumentStatus? status) {
              setState(() => _statusFilter = status);
              _controller.load(DocumentQuery(status: status));
            },
          ),
          const Divider(height: 1),
          Expanded(
            child: AsyncStateView(
              // 刷新时保留旧列表：已有数据就别白屏转圈。
              isLoading: state.isLoading && state.items.isEmpty,
              failure: state.items.isEmpty ? state.failure : null,
              isEmpty: state.items.isEmpty,
              onRetry: _controller.refresh,
              emptyMessage: '暂无$_title',
              child: _DocumentList(kind: widget.kind, items: state.items),
            ),
          ),
        ],
      ),
    );
  }
}

/// 单据筛选条：状态 + 关键字（月份与业务员筛选留待页面后续细化）。
class _DocumentFilters extends StatelessWidget {
  const _DocumentFilters({
    required this.kind,
    required this.statusFilter,
    required this.onStatusChanged,
  });

  final DocumentKind kind;
  final DocumentStatus? statusFilter;
  final ValueChanged<DocumentStatus?> onStatusChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: DropdownButton<DocumentStatus?>(
        value: statusFilter,
        hint: const Text('全部状态'),
        items: <DropdownMenuItem<DocumentStatus?>>[
          const DropdownMenuItem<DocumentStatus?>(
            value: null,
            child: Text('全部状态'),
          ),
          for (final status in DocumentStatus.values)
            DropdownMenuItem<DocumentStatus?>(
              value: status,
              child: Text(_statusLabel(status)),
            ),
        ],
        onChanged: onStatusChanged,
      ),
    );
  }

  String _statusLabel(DocumentStatus status) => switch (status) {
    DocumentStatus.draft => '草稿',
    DocumentStatus.submitted => '已提交',
    DocumentStatus.voided => '已作废',
  };
}

/// 单据列表：窄屏卡片、宽屏表格。
class _DocumentList extends StatelessWidget {
  const _DocumentList({required this.kind, required this.items});

  final DocumentKind kind;
  final List<DocumentSummary> items;

  @override
  Widget build(BuildContext context) {
    final isWide =
        MediaQuery.sizeOf(context).width >= kResponsiveScaffoldBreakpoint;
    return isWide
        ? _DocumentTable(kind: kind, items: items)
        : _DocumentCardList(kind: kind, items: items);
  }
}

/// 窄屏：卡片列表，一行一单。
class _DocumentCardList extends StatelessWidget {
  const _DocumentCardList({required this.kind, required this.items});

  final DocumentKind kind;
  final List<DocumentSummary> items;

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: items.length,
      itemBuilder: (BuildContext context, int index) {
        final item = items[index];
        return _DocumentCard(kind: kind, item: item);
      },
    );
  }
}

/// 宽屏：紧凑表格。
class _DocumentTable extends StatelessWidget {
  const _DocumentTable({required this.kind, required this.items});

  final DocumentKind kind;
  final List<DocumentSummary> items;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: DataTable(
        columns: const <DataColumn>[
          DataColumn(label: Text('单号')),
          DataColumn(label: Text('状态')),
          DataColumn(label: Text('业务日期')),
          DataColumn(label: Text('往来单位')),
          DataColumn(label: Text('金额')),
          DataColumn(label: Text('操作')),
        ],
        rows: <DataRow>[
          for (final item in items)
            DataRow(
              cells: <DataCell>[
                DataCell(Text(item.documentNo)),
                DataCell(Text(_statusLabel(item.status))),
                DataCell(Text(_formatDate(item.businessDate))),
                DataCell(Text(item.partyNames.join('、'))),
                DataCell(Text(item.totalAmount.format())),
                DataCell(
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      TextButton(
                        onPressed: () => _openDetail(context, item),
                        child: const Text('查看'),
                      ),
                      TextButton(
                        onPressed: () => _openStatement(context, item),
                        child: const Text('结清'),
                      ),
                    ],
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

/// 单张单据卡片（窄屏）。
class _DocumentCard extends StatelessWidget {
  const _DocumentCard({required this.kind, required this.item});

  final DocumentKind kind;
  final DocumentSummary item;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: ListTile(
        title: Text(item.documentNo),
        subtitle: Text(
          '${_formatDate(item.businessDate)} · ${item.partyNames.join('、')}',
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: <Widget>[
                Text(
                  item.totalAmount.format(),
                  style: theme.textTheme.titleMedium,
                ),
                Text(
                  _statusLabel(item.status),
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
            IconButton(
              tooltip: '结清视图',
              onPressed: () => _openStatement(context, item),
              icon: const Icon(Icons.receipt_outlined),
            ),
          ],
        ),
        onTap: () => _openDetail(context, item),
      ),
    );
  }
}

void _openDetail(BuildContext context, DocumentSummary item) {
  final segment = item.kind == DocumentKind.outbound ? 'outbound' : 'inbound';
  context.go('/documents/$segment/${item.documentId}');
}

/// 打开该单据的结清视图（已付/未付或已收/未收 + 财务登记入口）。
void _openStatement(BuildContext context, DocumentSummary item) {
  context.go('/finance/statements/${item.documentId}');
}

String _statusLabel(DocumentStatus status) => switch (status) {
  DocumentStatus.draft => '草稿',
  DocumentStatus.submitted => '已提交',
  DocumentStatus.voided => '已作废',
};

String _formatDate(DateTime date) =>
    '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
