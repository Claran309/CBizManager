import 'package:c_biz_docs_manager/core/presentation/responsive_scaffold.dart';
import 'package:c_biz_docs_manager/features/documents/application/document_controller.dart';
import 'package:c_biz_docs_manager/features/documents/domain/document.dart';
import 'package:c_biz_docs_manager/features/home/presentation/tenant_shell.dart';
import 'package:c_biz_docs_manager/core/auth/auth_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 单据填写页：新建或编辑入库/出库单。
///
/// 金额一律由服务端按「单价 × 数量」计算，客户端只填数量与单价、**不展示也不
/// 计算金额** —— 提交成功后由详情页展示服务端算好的金额与大写。这样做是为了
/// 避免客户端再算出一份与后端不一致的「第二个真相」。
class DocumentFormPage extends ConsumerStatefulWidget {
  const DocumentFormPage({required this.kind, this.documentId, super.key});

  final DocumentKind kind;

  /// 为 null 表示新建；非 null 表示编辑已有单据。
  final int? documentId;

  @override
  ConsumerState<DocumentFormPage> createState() => _DocumentFormPageState();
}

class _DocumentFormPageState extends ConsumerState<DocumentFormPage> {
  final TextEditingController _businessDateController = TextEditingController();
  final TextEditingController _remarkController = TextEditingController();
  final TextEditingController _shippingUnitController = TextEditingController();
  SaleAmountType? _saleAmountType;

  /// 往来单位分组（含各自明细）。
  final List<_PartyDraftState> _parties = <_PartyDraftState>[
    _PartyDraftState(),
  ];

  bool get _isOutbound => widget.kind == DocumentKind.outbound;

  @override
  void initState() {
    super.initState();
    _businessDateController.text = _today();
    // 编辑已有单据时，首帧后拉详情回填。
    if (widget.documentId != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ref
            .read(documentControllerProvider(widget.kind).notifier)
            .loadDetail(widget.documentId!);
      });
    }
  }

  @override
  void dispose() {
    _businessDateController.dispose();
    _remarkController.dispose();
    _shippingUnitController.dispose();
    super.dispose();
  }

  String _today() {
    final now = DateTime.now();
    return '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
  }

  void _addParty() => setState(() => _parties.add(_PartyDraftState()));

  void _removePartyAt(int index) {
    if (_parties.length == 1) return; // 至少保留一个往来单位。
    setState(() => _parties.removeAt(index));
  }

  /// 把表单内容组装成 [DocumentDraft] 并提交。
  Future<void> _submit() async {
    final controller = ref.read(
      documentControllerProvider(widget.kind).notifier,
    );
    final draft = DocumentDraft(
      status: DocumentStatus.draft,
      businessDate: _businessDateController.text.trim(),
      shippingUnit:
          _isOutbound && _shippingUnitController.text.trim().isNotEmpty
          ? _shippingUnitController.text.trim()
          : null,
      saleAmountType: _isOutbound ? _saleAmountType : null,
      remark: _remarkController.text.trim().isEmpty
          ? null
          : _remarkController.text.trim(),
      parties: <PartyDraft>[
        for (final party in _parties)
          PartyDraft(
            partyName: party.nameController.text.trim(),
            items: <ItemDraft>[
              for (final item in party.items)
                ItemDraft(
                  productName: item.nameController.text.trim(),
                  productModel: item.modelController.text.trim().isEmpty
                      ? null
                      : item.modelController.text.trim(),
                  unit: item.unitController.text.trim().isEmpty
                      ? null
                      : item.unitController.text.trim(),
                  quantity: item.quantityController.text.trim(),
                  unitPrice: item.unitPriceController.text.trim(),
                  priceTaxMode: item.priceTaxMode,
                ),
            ],
          ),
      ],
    );

    if (widget.documentId == null) {
      await controller.create(draft);
    } else {
      final detail = ref.read(documentControllerProvider(widget.kind)).detail;
      if (detail != null) {
        await controller.update(widget.documentId!, draft, detail.version);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final profile = ref.watch(authControllerProvider).session?.profile;
    final state = ref.watch(documentControllerProvider(widget.kind));

    return ResponsiveScaffold(
      title: _isOutbound ? '出库单' : '入库单',
      destinations: tenantDestinations(profile),
      currentRoute:
          '/documents/${_isOutbound ? 'outbound' : 'inbound'}${widget.documentId != null ? '/${widget.documentId}' : '/new'}',
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          TextField(
            controller: _businessDateController,
            decoration: const InputDecoration(
              labelText: '业务日期',
              hintText: '如 2026-09-22',
            ),
          ),
          const SizedBox(height: 12),
          if (_isOutbound) ...<Widget>[
            TextField(
              controller: _shippingUnitController,
              decoration: const InputDecoration(labelText: '运输单位'),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<SaleAmountType>(
              initialValue: _saleAmountType,
              decoration: const InputDecoration(labelText: '销售金额类型'),
              items: <DropdownMenuItem<SaleAmountType>>[
                for (final type in SaleAmountType.values)
                  DropdownMenuItem<SaleAmountType>(
                    value: type,
                    child: Text(_saleTypeLabel(type)),
                  ),
              ],
              onChanged: (SaleAmountType? value) =>
                  setState(() => _saleAmountType = value),
            ),
            const SizedBox(height: 12),
          ],
          TextField(
            controller: _remarkController,
            decoration: const InputDecoration(labelText: '备注'),
          ),
          const SizedBox(height: 24),
          for (var i = 0; i < _parties.length; i++)
            _PartySection(
              index: i,
              state: _parties[i],
              isOutbound: _isOutbound,
              onRemove: _parties.length > 1 ? () => _removePartyAt(i) : null,
              onChanged: () => setState(() {}),
            ),
          TextButton.icon(
            onPressed: _addParty,
            icon: const Icon(Icons.add),
            label: Text(_isOutbound ? '添加客户' : '添加入库公司'),
          ),
          const SizedBox(height: 24),
          FilledButton(
            onPressed: state.isWriting ? null : _submit,
            child: Text(widget.documentId == null ? '保存草稿' : '保存'),
          ),
          const SizedBox(height: 8),
          Text(
            '金额由系统按单价×数量自动计算，保存后可见。',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }

  String _saleTypeLabel(SaleAmountType type) => switch (type) {
    SaleAmountType.vatSpecial => '专票（Y-1）',
    SaleAmountType.vatGeneral => '普票（y-N）',
    SaleAmountType.noInvoice => '不开票（N）',
  };
}

/// 一个往来单位分组的表单态（含明细行）。
class _PartyDraftState {
  final TextEditingController nameController = TextEditingController();
  final List<_ItemDraftState> items = <_ItemDraftState>[_ItemDraftState()];

  void dispose() {
    nameController.dispose();
    for (final item in items) {
      item.dispose();
    }
  }
}

/// 一条明细行的表单态。
class _ItemDraftState {
  final TextEditingController nameController = TextEditingController();
  final TextEditingController modelController = TextEditingController();
  final TextEditingController unitController = TextEditingController();
  final TextEditingController quantityController = TextEditingController();
  final TextEditingController unitPriceController = TextEditingController();
  PriceTaxMode priceTaxMode = PriceTaxMode.taxIncluded;

  void dispose() {
    nameController.dispose();
    modelController.dispose();
    unitController.dispose();
    quantityController.dispose();
    unitPriceController.dispose();
  }
}

/// 一个往来单位分组：名称 + 明细列表 + 删除按钮。
class _PartySection extends StatefulWidget {
  const _PartySection({
    required this.index,
    required this.state,
    required this.isOutbound,
    required this.onRemove,
    required this.onChanged,
  });

  final int index;
  final _PartyDraftState state;
  final bool isOutbound;
  final VoidCallback? onRemove;
  final VoidCallback onChanged;

  @override
  State<_PartySection> createState() => _PartySectionState();
}

class _PartySectionState extends State<_PartySection> {
  @override
  void dispose() {
    widget.state.dispose();
    super.dispose();
  }

  void _addItem() => setState(() => widget.state.items.add(_ItemDraftState()));

  void _removeItemAt(int index) {
    if (widget.state.items.length == 1) return;
    setState(() => widget.state.items.removeAt(index).dispose());
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: TextField(
                    controller: widget.state.nameController,
                    decoration: InputDecoration(
                      labelText: widget.isOutbound ? '客户名称' : '入库公司',
                    ),
                    onChanged: (_) => widget.onChanged(),
                  ),
                ),
                if (widget.onRemove != null)
                  IconButton(
                    tooltip: '删除该分组',
                    onPressed: widget.onRemove,
                    icon: const Icon(Icons.delete_outline),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            for (var i = 0; i < widget.state.items.length; i++)
              _ItemRow(
                state: widget.state.items[i],
                onRemove: widget.state.items.length > 1
                    ? () => _removeItemAt(i)
                    : null,
              ),
            TextButton.icon(
              onPressed: _addItem,
              icon: const Icon(Icons.add),
              label: const Text('添加明细'),
            ),
          ],
        ),
      ),
    );
  }
}

/// 一条明细行：品名 / 型号 / 单位 / 数量 / 单价 / 价税方式。
class _ItemRow extends StatelessWidget {
  const _ItemRow({required this.state, required this.onRemove});

  final _ItemDraftState state;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Expanded(
            child: TextField(
              controller: state.nameController,
              decoration: const InputDecoration(labelText: '品名', isDense: true),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: state.modelController,
              decoration: const InputDecoration(labelText: '型号', isDense: true),
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 72,
            child: TextField(
              controller: state.unitController,
              decoration: const InputDecoration(labelText: '单位', isDense: true),
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 88,
            child: TextField(
              controller: state.quantityController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: '数量', isDense: true),
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 100,
            child: TextField(
              controller: state.unitPriceController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: '单价', isDense: true),
            ),
          ),
          const SizedBox(width: 8),
          DropdownButton<PriceTaxMode>(
            value: state.priceTaxMode,
            items: <DropdownMenuItem<PriceTaxMode>>[
              for (final mode in PriceTaxMode.values)
                DropdownMenuItem<PriceTaxMode>(
                  value: mode,
                  child: Text(mode == PriceTaxMode.taxIncluded ? '含税' : '不含税'),
                ),
            ],
            onChanged: (PriceTaxMode? value) {
              if (value != null) {
                state.priceTaxMode = value;
              }
            },
          ),
          if (onRemove != null)
            IconButton(
              tooltip: '删除该明细',
              onPressed: onRemove,
              icon: const Icon(Icons.close),
            ),
        ],
      ),
    );
  }
}
