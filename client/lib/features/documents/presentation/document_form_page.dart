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

  /// 已回填过详情的单据 id（回填只做一次，之后用户的编辑不再被覆盖）。
  int? _loadedDetailId;

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

  /// 用详情回填表单（只在首次拿到该单据时执行）。
  ///
  /// 不做这一步的话，编辑一个已有单据会看到一片空白输入框，用户一保存就把
  /// 原内容覆盖成空 —— 所以它不只是体验问题。
  void _backfill(DocumentDetail detail) {
    if (_loadedDetailId == detail.documentId) return;
    _loadedDetailId = detail.documentId;
    _businessDateController.text = _formatDate(detail.businessDate);
    _remarkController.text = detail.remark ?? '';
    _shippingUnitController.text = detail.shippingUnit ?? '';
    _saleAmountType = detail.saleAmountType;
    for (final party in _parties) {
      party.dispose();
    }
    _parties
      ..clear()
      ..addAll(<_PartyDraftState>[
        for (final party in detail.parties) _PartyDraftState.fromParty(party),
      ]);
    if (_parties.isEmpty) _parties.add(_PartyDraftState());
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

  /// 把表单内容组装成 [DocumentDraft]。
  DocumentDraft _draftOf(DocumentStatus status) => DocumentDraft(
    status: status,
    businessDate: _businessDateController.text.trim(),
    shippingUnit: _isOutbound && _shippingUnitController.text.trim().isNotEmpty
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

  /// 新建：以指定状态创建（草稿 `draft` 或直接提交 `submitted`）。
  Future<void> _create(DocumentStatus status) async {
    await ref
        .read(documentControllerProvider(widget.kind).notifier)
        .create(_draftOf(status));
  }

  /// 保存对已有单据的修改（仅草稿可编辑）。
  Future<void> _save() async {
    final detail = ref.read(documentControllerProvider(widget.kind)).detail;
    if (detail == null) return;
    await ref
        .read(documentControllerProvider(widget.kind).notifier)
        .update(
          detail.documentId,
          _draftOf(DocumentStatus.draft),
          detail.version,
        );
  }

  /// 提交已有草稿：先把当前表单内容落库，再走提交（版本以落库后的为准）。
  Future<void> _submitExisting() async {
    final controller = ref.read(
      documentControllerProvider(widget.kind).notifier,
    );
    await _save();
    if (!mounted) return;
    final after = ref.read(documentControllerProvider(widget.kind)).detail;
    if (after != null && after.status == DocumentStatus.draft) {
      await controller.submit(after.documentId, after.version);
    }
  }

  /// 作废已有单据（草稿或已提交都可作废）。
  Future<void> _void() async {
    final detail = ref.read(documentControllerProvider(widget.kind)).detail;
    if (detail == null) return;
    await ref
        .read(documentControllerProvider(widget.kind).notifier)
        .voidDocument(detail.documentId, detail.version);
  }

  @override
  Widget build(BuildContext context) {
    final profile = ref.watch(authControllerProvider).session?.profile;
    final state = ref.watch(documentControllerProvider(widget.kind));

    // 详情到货后回填**一次**表单（之后再刷新不覆盖用户的编辑）。
    //
    // 用 build 里的 postFrame 而不是 ref.listen：listen 只在后续变化时触发，
    // 若详情在本帧之前就已就绪（例如从别处切回来）就会漏掉回填。
    final loaded = state.detail;
    if (loaded != null && _loadedDetailId != loaded.documentId) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final detail = ref.read(documentControllerProvider(widget.kind)).detail;
        if (detail != null && _loadedDetailId != detail.documentId) {
          setState(() => _backfill(detail));
        }
      });
    }

    // 新建时 status 为 null；已提交 / 已作废都是只读态（状态机：仅草稿可编辑）。
    final status = state.detail?.status;
    final readOnly =
        status == DocumentStatus.submitted || status == DocumentStatus.voided;

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
            enabled: !readOnly,
            decoration: const InputDecoration(
              labelText: '业务日期',
              hintText: '如 2026-09-22',
            ),
          ),
          const SizedBox(height: 12),
          if (_isOutbound) ...<Widget>[
            TextField(
              controller: _shippingUnitController,
              enabled: !readOnly,
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
              onChanged: readOnly
                  ? null
                  : (SaleAmountType? value) =>
                        setState(() => _saleAmountType = value),
            ),
            const SizedBox(height: 12),
          ],
          TextField(
            controller: _remarkController,
            enabled: !readOnly,
            decoration: const InputDecoration(labelText: '备注'),
          ),
          const SizedBox(height: 24),
          for (var i = 0; i < _parties.length; i++)
            _PartySection(
              index: i,
              state: _parties[i],
              isOutbound: _isOutbound,
              readOnly: readOnly,
              onRemove: !readOnly && _parties.length > 1
                  ? () => _removePartyAt(i)
                  : null,
              onChanged: () => setState(() {}),
            ),
          if (!readOnly)
            TextButton.icon(
              onPressed: _addParty,
              icon: const Icon(Icons.add),
              label: Text(_isOutbound ? '添加客户' : '添加入库公司'),
            ),
          const SizedBox(height: 24),
          _FormActions(
            status: status,
            isWriting: state.isWriting,
            onSaveDraft: () => _create(DocumentStatus.draft),
            onSubmitNew: () => _create(DocumentStatus.submitted),
            onSave: _save,
            onSubmitExisting: _submitExisting,
            onVoid: _void,
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

/// 底部动作区：按单据状态裁剪（状态机 `draft → submitted → voided`）。
///
/// - 新建（status 为 null）：可保存草稿，也可直接提交；
/// - 草稿：可保存修改、提交、作废；
/// - 已提交：只能作废（内容不可再编辑）；
/// - 已作废：无任何动作。
class _FormActions extends StatelessWidget {
  const _FormActions({
    required this.status,
    required this.isWriting,
    required this.onSaveDraft,
    required this.onSubmitNew,
    required this.onSave,
    required this.onSubmitExisting,
    required this.onVoid,
  });

  final DocumentStatus? status;
  final bool isWriting;
  final VoidCallback onSaveDraft;
  final VoidCallback onSubmitNew;
  final VoidCallback onSave;
  final VoidCallback onSubmitExisting;
  final VoidCallback onVoid;

  @override
  Widget build(BuildContext context) {
    if (status == DocumentStatus.voided) {
      return Text(
        '该单据已作废，不可再修改。',
        style: TextStyle(color: Theme.of(context).colorScheme.error),
      );
    }
    if (status == DocumentStatus.submitted) {
      return Wrap(
        spacing: 12,
        runSpacing: 12,
        children: <Widget>[
          OutlinedButton(
            onPressed: isWriting ? null : onVoid,
            child: const Text('作废'),
          ),
        ],
      );
    }
    if (status == null) {
      return Wrap(
        spacing: 12,
        runSpacing: 12,
        children: <Widget>[
          FilledButton(
            onPressed: isWriting ? null : onSaveDraft,
            child: const Text('保存草稿'),
          ),
          OutlinedButton(
            onPressed: isWriting ? null : onSubmitNew,
            child: const Text('提交'),
          ),
        ],
      );
    }
    // 草稿。
    return Wrap(
      spacing: 12,
      runSpacing: 12,
      children: <Widget>[
        FilledButton(
          onPressed: isWriting ? null : onSave,
          child: const Text('保存'),
        ),
        OutlinedButton(
          onPressed: isWriting ? null : onSubmitExisting,
          child: const Text('提交'),
        ),
        OutlinedButton(
          onPressed: isWriting ? null : onVoid,
          child: const Text('作废'),
        ),
      ],
    );
  }
}

/// 一个往来单位分组的表单态（含明细行）。
class _PartyDraftState {
  _PartyDraftState();

  /// 用详情里的一个分组回填。
  factory _PartyDraftState.fromParty(DocumentParty party) {
    final state = _PartyDraftState();
    state.nameController.text = party.partyName;
    for (final item in state.items) {
      item.dispose();
    }
    state.items
      ..clear()
      ..addAll(<_ItemDraftState>[
        for (final item in party.items) _ItemDraftState.fromItem(item),
      ]);
    if (state.items.isEmpty) state.items.add(_ItemDraftState());
    return state;
  }

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
  _ItemDraftState();

  /// 用详情里的一条明细回填（数量/单价保持服务端返回的字符串，不重新格式化）。
  factory _ItemDraftState.fromItem(DocumentItem item) {
    final state = _ItemDraftState();
    state.nameController.text = item.productName;
    state.modelController.text = item.productModel ?? '';
    state.unitController.text = item.unit ?? '';
    state.quantityController.text = item.quantity.format();
    state.unitPriceController.text = item.unitPrice.format();
    state.priceTaxMode = item.priceTaxMode;
    return state;
  }

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
    required this.readOnly,
    required this.onRemove,
    required this.onChanged,
  });

  final int index;
  final _PartyDraftState state;
  final bool isOutbound;
  final bool readOnly;
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
                    enabled: !widget.readOnly,
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
                readOnly: widget.readOnly,
                onRemove: widget.state.items.length > 1
                    ? () => _removeItemAt(i)
                    : null,
              ),
            if (!widget.readOnly)
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
  const _ItemRow({
    required this.state,
    required this.readOnly,
    required this.onRemove,
  });

  final _ItemDraftState state;
  final bool readOnly;
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
              enabled: !readOnly,
              decoration: const InputDecoration(labelText: '品名', isDense: true),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: state.modelController,
              enabled: !readOnly,
              decoration: const InputDecoration(labelText: '型号', isDense: true),
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 72,
            child: TextField(
              controller: state.unitController,
              enabled: !readOnly,
              decoration: const InputDecoration(labelText: '单位', isDense: true),
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 88,
            child: TextField(
              controller: state.quantityController,
              enabled: !readOnly,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: '数量', isDense: true),
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 100,
            child: TextField(
              controller: state.unitPriceController,
              enabled: !readOnly,
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
            onChanged: readOnly
                ? null
                : (PriceTaxMode? value) {
                    if (value != null) {
                      state.priceTaxMode = value;
                    }
                  },
          ),
          if (!readOnly && onRemove != null)
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

String _formatDate(DateTime date) =>
    '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
