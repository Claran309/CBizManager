import 'package:c_biz_docs_manager/core/auth/auth_controller.dart';
import 'package:c_biz_docs_manager/core/bizdate/bizdate.dart';
import 'package:c_biz_docs_manager/core/presentation/failure_presenter.dart';
import 'package:c_biz_docs_manager/core/presentation/responsive_scaffold.dart';
import 'package:c_biz_docs_manager/features/documents/application/document_controller.dart';
import 'package:c_biz_docs_manager/features/documents/domain/document.dart';
import 'package:c_biz_docs_manager/features/home/presentation/tenant_shell.dart';
import 'package:c_biz_docs_manager/features/settlements/application/settlement_controller.dart';
import 'package:c_biz_docs_manager/features/settlements/domain/settlement.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

/// 申请结算：勾选某个周期的已提交单据，提交结算申请。
///
/// 候选单据来自「已提交」的入库/出库单（按业务月份筛）。**「是否已被有效结算单占用」
/// 由服务端裁决** —— 客户端不做这层判断，撞占用时把 `SETTLEMENT_SOURCE_IN_USE`
/// 显示出来即可，避免两端各算一次导致口径漂移。
class SettlementCreatePage extends ConsumerStatefulWidget {
  const SettlementCreatePage({super.key});

  @override
  ConsumerState<SettlementCreatePage> createState() =>
      _SettlementCreatePageState();
}

class _SettlementCreatePageState extends ConsumerState<SettlementCreatePage> {
  final TextEditingController _periodController = TextEditingController(
    text: formatMonth(DateTime.now()),
  );
  final TextEditingController _remarkController = TextEditingController();

  /// 已勾选的源单据 id。
  final Set<int> _selected = <int>{};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _loadCandidates();
    });
  }

  @override
  void dispose() {
    _periodController.dispose();
    _remarkController.dispose();
    super.dispose();
  }

  void _loadCandidates() {
    final query = DocumentQuery(
      status: DocumentStatus.submitted,
      month: _periodController.text.trim(),
    );
    ref
        .read(documentControllerProvider(DocumentKind.inbound).notifier)
        .load(query);
    ref
        .read(documentControllerProvider(DocumentKind.outbound).notifier)
        .load(query);
  }

  Future<void> _submit() async {
    if (_selected.isEmpty) return;
    await ref
        .read(settlementControllerProvider.notifier)
        .create(
          SettlementDraft(
            sourceDocumentIds: _selected.toList(growable: false),
            remark: _remarkController.text.trim().isEmpty
                ? null
                : _remarkController.text.trim(),
          ),
        );
  }

  @override
  Widget build(BuildContext context) {
    final profile = ref.watch(authControllerProvider).session?.profile;
    final inbound = ref.watch(documentControllerProvider(DocumentKind.inbound));
    final outbound = ref.watch(
      documentControllerProvider(DocumentKind.outbound),
    );
    final settlement = ref.watch(settlementControllerProvider);

    final candidates = <DocumentSummary>[...inbound.items, ...outbound.items];

    // 申请成功后 state.detail 会被写入，页面据此离开（状态驱动导航）。
    if (settlement.detail != null && !settlement.isWriting) {
      final created = settlement.detail!;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        // 先复位再跳：否则下次再进申请页会被立刻弹走。
        ref.read(settlementControllerProvider.notifier).clearDetail();
        context.go('/settlements/${created.settlementId}');
      });
    }

    return ResponsiveScaffold(
      title: '申请结算',
      destinations: tenantDestinations(profile),
      currentRoute: '/settlements/new',
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: TextField(
                  controller: _periodController,
                  decoration: const InputDecoration(
                    labelText: '业务月份',
                    hintText: '如 2026-09',
                    isDense: true,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              FilledButton(
                onPressed: _loadCandidates,
                child: const Text('查询单据'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _remarkController,
            decoration: const InputDecoration(labelText: '备注（可选）'),
          ),
          const SizedBox(height: 16),
          const Text('勾选要结算的单据', style: TextStyle(fontWeight: FontWeight.bold)),
          if (candidates.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Text('该月份没有可结算的已提交单据'),
            ),
          for (final doc in candidates)
            CheckboxListTile(
              value: _selected.contains(doc.documentId),
              onChanged: (bool? checked) {
                setState(() {
                  if (checked ?? false) {
                    _selected.add(doc.documentId);
                  } else {
                    _selected.remove(doc.documentId);
                  }
                });
              },
              title: Text(doc.documentNo),
              subtitle: Text(
                '${doc.kind == DocumentKind.outbound ? '出库' : '入库'} · '
                '${doc.businessUser.displayName} · ${doc.partyNames.join('、')}',
              ),
              secondary: Text(doc.totalAmount.format()),
            ),
          if (settlement.failure != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                FailurePresenter.present(settlement.failure!).message,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: settlement.isWriting || _selected.isEmpty
                ? null
                : _submit,
            child: Text('提交结算申请（已选 ${_selected.length} 张）'),
          ),
        ],
      ),
    );
  }
}
