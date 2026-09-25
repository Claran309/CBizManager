import 'package:c_biz_docs_manager/core/auth/auth_models.dart';
import 'package:c_biz_docs_manager/core/money/money.dart';
import 'package:c_biz_docs_manager/features/documents/domain/document.dart';

/// 统计维度。
///
/// - [company] 公司维度：整个业务组在统计周期内的合计，生成 1 张快照；
/// - [businessUser] 业务员维度：单个业务员在统计周期内的合计。
enum ReportScope {
  company('company'),
  businessUser('business_user');

  const ReportScope(this.wireValue);

  final String wireValue;

  static ReportScope fromWireValue(String value) => values.firstWhere(
    (scope) => scope.wireValue == value,
    orElse: () => throw FormatException('未知统计维度：$value'),
  );

  String get label => switch (this) {
    company => '公司维度',
    businessUser => '业务员维度',
  };
}

/// 一类销售金额的分项统计（对应契约 `SaleAmountTotalData`）。
///
/// 占比以**百万分之一整数**（ppm）给出，另有服务端格式化的展示文本
/// [sharePercent]（两位小数，如 `"65.20"`）—— 三端共用同一口径，客户端不自己除。
final class SaleAmountTotal {
  const SaleAmountTotal({
    required this.saleAmountType,
    required this.amount,
    required this.amountUpper,
    required this.sharePpm,
    required this.sharePercent,
  });

  final SaleAmountType saleAmountType;
  final Amount amount;
  final String amountUpper;
  final int sharePpm;
  final String sharePercent;

  factory SaleAmountTotal.fromJson(Map<String, Object?> json) =>
      SaleAmountTotal(
        saleAmountType: SaleAmountType.fromWireValue(
          _readString(json, 'sale_amount_type'),
        ),
        amount: _readAmount(json, 'amount'),
        amountUpper: _readString(json, 'amount_upper'),
        sharePpm: _readInt(json, 'share_ppm'),
        sharePercent: _readString(json, 'share_percent'),
      );
}

/// 后台数据汇总看板（对应契约 `OverviewData`）。
final class ReportOverview {
  const ReportOverview({
    required this.period,
    required this.inboundDocumentCount,
    required this.inboundAmount,
    required this.inboundAmountUpper,
    required this.outboundDocumentCount,
    required this.outboundAmount,
    required this.outboundAmountUpper,
    required this.grossProfit,
    required this.grossProfitUpper,
    required this.grossMarginPpm,
    required this.grossMarginPercent,
    required this.paidAmount,
    required this.unpaidAmount,
    required this.unpaidAmountUpper,
    required this.unpaidDocumentCount,
    required this.invoicedAmount,
    required this.uninvoicedAmount,
    required this.uninvoicedAmountUpper,
    required this.uninvoicedDocumentCount,
    required this.receivedAmount,
    required this.unreceivedAmount,
    required this.unreceivedAmountUpper,
    required this.unreceivedDocumentCount,
    required this.supplierCount,
    required this.customerCount,
    required this.saleAmountTypes,
  });

  final String period;
  final int inboundDocumentCount;
  final Amount inboundAmount;
  final String inboundAmountUpper;
  final int outboundDocumentCount;
  final Amount outboundAmount;
  final String outboundAmountUpper;
  final Amount grossProfit;
  final String grossProfitUpper;
  final int grossMarginPpm;
  final String grossMarginPercent;
  final Amount paidAmount;
  final Amount unpaidAmount;
  final String unpaidAmountUpper;
  final int unpaidDocumentCount;
  final Amount invoicedAmount;
  final Amount uninvoicedAmount;
  final String uninvoicedAmountUpper;
  final int uninvoicedDocumentCount;
  final Amount receivedAmount;
  final Amount unreceivedAmount;
  final String unreceivedAmountUpper;
  final int unreceivedDocumentCount;
  final int supplierCount;
  final int customerCount;
  final List<SaleAmountTotal> saleAmountTypes;

  factory ReportOverview.fromJson(Map<String, Object?> json) => ReportOverview(
    period: _readString(json, 'period'),
    inboundDocumentCount: _readInt(json, 'inbound_document_count'),
    inboundAmount: _readAmount(json, 'inbound_amount'),
    inboundAmountUpper: _readString(json, 'inbound_amount_upper'),
    outboundDocumentCount: _readInt(json, 'outbound_document_count'),
    outboundAmount: _readAmount(json, 'outbound_amount'),
    outboundAmountUpper: _readString(json, 'outbound_amount_upper'),
    grossProfit: _readAmount(json, 'gross_profit'),
    grossProfitUpper: _readString(json, 'gross_profit_upper'),
    grossMarginPpm: _readInt(json, 'gross_margin_ppm'),
    grossMarginPercent: _readString(json, 'gross_margin_percent'),
    paidAmount: _readAmount(json, 'paid_amount'),
    unpaidAmount: _readAmount(json, 'unpaid_amount'),
    unpaidAmountUpper: _readString(json, 'unpaid_amount_upper'),
    unpaidDocumentCount: _readInt(json, 'unpaid_document_count'),
    invoicedAmount: _readAmount(json, 'invoiced_amount'),
    uninvoicedAmount: _readAmount(json, 'uninvoiced_amount'),
    uninvoicedAmountUpper: _readString(json, 'uninvoiced_amount_upper'),
    uninvoicedDocumentCount: _readInt(json, 'uninvoiced_document_count'),
    receivedAmount: _readAmount(json, 'received_amount'),
    unreceivedAmount: _readAmount(json, 'unreceived_amount'),
    unreceivedAmountUpper: _readString(json, 'unreceived_amount_upper'),
    unreceivedDocumentCount: _readInt(json, 'unreceived_document_count'),
    supplierCount: _readInt(json, 'supplier_count'),
    customerCount: _readInt(json, 'customer_count'),
    saleAmountTypes: _readSaleAmountTypes(json),
  );
}

/// 明细聚合的一行（对应契约 `ItemData`）。
///
/// 按「往来单位 + 品名 + 型号 + 单位」分组，**只给金额与数量、不给已付 / 未付**：
/// 付款挂在单据而非明细，硬摊到明细行只会得到业务上经不起追问的「假精确」。
final class ReportItem {
  const ReportItem({
    required this.partyName,
    required this.productName,
    required this.documentCount,
    required this.quantity,
    required this.amount,
    required this.amountUpper,
    this.productModel,
    this.unit,
  });

  final String partyName;
  final String productName;
  final String? productModel;
  final String? unit;
  final int documentCount;
  final Quantity quantity;
  final Amount amount;
  final String amountUpper;

  factory ReportItem.fromJson(Map<String, Object?> json) => ReportItem(
    partyName: _readString(json, 'party_name'),
    productName: _readString(json, 'product_name'),
    productModel: json['product_model'] as String?,
    unit: json['unit'] as String?,
    documentCount: _readInt(json, 'document_count'),
    quantity: _readQuantity(json, 'quantity'),
    amount: _readAmount(json, 'amount'),
    amountUpper: _readString(json, 'amount_upper'),
  );
}

/// 入库统计（对应契约 `InboundStatsData`）。
///
/// 合计块是**单据粒度**精确值；[items] 明细行只给金额与数量（见 [ReportItem]）。
final class InboundStats {
  const InboundStats({
    required this.period,
    required this.documentCount,
    required this.amountTotal,
    required this.amountTotalUpper,
    required this.paidAmount,
    required this.unpaidAmount,
    required this.unpaidAmountUpper,
    required this.unpaidDocumentCount,
    required this.invoicedAmount,
    required this.uninvoicedAmount,
    required this.uninvoicedAmountUpper,
    required this.uninvoicedDocumentCount,
    required this.supplierCount,
    required this.items,
    required this.page,
    required this.pageSize,
    required this.total,
  });

  final String period;
  final int documentCount;
  final Amount amountTotal;
  final String amountTotalUpper;
  final Amount paidAmount;
  final Amount unpaidAmount;
  final String unpaidAmountUpper;
  final int unpaidDocumentCount;
  final Amount invoicedAmount;
  final Amount uninvoicedAmount;
  final String uninvoicedAmountUpper;
  final int uninvoicedDocumentCount;
  final int supplierCount;
  final List<ReportItem> items;
  final int page;
  final int pageSize;
  final int total;

  factory InboundStats.fromJson(Map<String, Object?> json) => InboundStats(
    period: _readString(json, 'period'),
    documentCount: _readInt(json, 'document_count'),
    amountTotal: _readAmount(json, 'amount_total'),
    amountTotalUpper: _readString(json, 'amount_total_upper'),
    paidAmount: _readAmount(json, 'paid_amount'),
    unpaidAmount: _readAmount(json, 'unpaid_amount'),
    unpaidAmountUpper: _readString(json, 'unpaid_amount_upper'),
    unpaidDocumentCount: _readInt(json, 'unpaid_document_count'),
    invoicedAmount: _readAmount(json, 'invoiced_amount'),
    uninvoicedAmount: _readAmount(json, 'uninvoiced_amount'),
    uninvoicedAmountUpper: _readString(json, 'uninvoiced_amount_upper'),
    uninvoicedDocumentCount: _readInt(json, 'uninvoiced_document_count'),
    supplierCount: _readInt(json, 'supplier_count'),
    items: _readItems(json),
    page: _readInt(json, 'page'),
    pageSize: _readInt(json, 'page_size'),
    total: _readInt(json, 'total'),
  );
}

/// 出库统计（对应契约 `OutboundStatsData`）。
final class OutboundStats {
  const OutboundStats({
    required this.period,
    required this.documentCount,
    required this.amountTotal,
    required this.amountTotalUpper,
    required this.receivedAmount,
    required this.unreceivedAmount,
    required this.unreceivedAmountUpper,
    required this.unreceivedDocumentCount,
    required this.customerCount,
    required this.saleAmountTypes,
    required this.items,
    required this.page,
    required this.pageSize,
    required this.total,
  });

  final String period;
  final int documentCount;
  final Amount amountTotal;
  final String amountTotalUpper;
  final Amount receivedAmount;
  final Amount unreceivedAmount;
  final String unreceivedAmountUpper;
  final int unreceivedDocumentCount;
  final int customerCount;
  final List<SaleAmountTotal> saleAmountTypes;
  final List<ReportItem> items;
  final int page;
  final int pageSize;
  final int total;

  factory OutboundStats.fromJson(Map<String, Object?> json) => OutboundStats(
    period: _readString(json, 'period'),
    documentCount: _readInt(json, 'document_count'),
    amountTotal: _readAmount(json, 'amount_total'),
    amountTotalUpper: _readString(json, 'amount_total_upper'),
    receivedAmount: _readAmount(json, 'received_amount'),
    unreceivedAmount: _readAmount(json, 'unreceived_amount'),
    unreceivedAmountUpper: _readString(json, 'unreceived_amount_upper'),
    unreceivedDocumentCount: _readInt(json, 'unreceived_document_count'),
    customerCount: _readInt(json, 'customer_count'),
    saleAmountTypes: _readSaleAmountTypes(json),
    items: _readItems(json),
    page: _readInt(json, 'page'),
    pageSize: _readInt(json, 'page_size'),
    total: _readInt(json, 'total'),
  );
}

/// 单个业务员的利润统计行（对应契约 `BusinessUserSummaryData`）。
final class BusinessUserSummary {
  const BusinessUserSummary({
    required this.businessUser,
    required this.inboundAmount,
    required this.outboundAmount,
    required this.grossProfit,
    required this.grossProfitUpper,
    required this.documentCount,
  });

  final AuthUser businessUser;
  final Amount inboundAmount;
  final Amount outboundAmount;
  final Amount grossProfit;
  final String grossProfitUpper;
  final int documentCount;

  factory BusinessUserSummary.fromJson(Map<String, Object?> json) =>
      BusinessUserSummary(
        businessUser: AuthUser.fromJson(_readObject(json, 'business_user')),
        inboundAmount: _readAmount(json, 'inbound_amount'),
        outboundAmount: _readAmount(json, 'outbound_amount'),
        grossProfit: _readAmount(json, 'gross_profit'),
        grossProfitUpper: _readString(json, 'gross_profit_upper'),
        documentCount: _readInt(json, 'document_count'),
      );
}

/// 业务员利润统计的合计行（对应契约 `BusinessUserTotalsData`）。
final class BusinessUserTotals {
  const BusinessUserTotals({
    required this.inboundAmount,
    required this.outboundAmount,
    required this.grossProfit,
    required this.grossProfitUpper,
    required this.documentCount,
  });

  final Amount inboundAmount;
  final Amount outboundAmount;
  final Amount grossProfit;
  final String grossProfitUpper;
  final int documentCount;

  factory BusinessUserTotals.fromJson(Map<String, Object?> json) =>
      BusinessUserTotals(
        inboundAmount: _readAmount(json, 'inbound_amount'),
        outboundAmount: _readAmount(json, 'outbound_amount'),
        grossProfit: _readAmount(json, 'gross_profit'),
        grossProfitUpper: _readString(json, 'gross_profit_upper'),
        documentCount: _readInt(json, 'document_count'),
      );
}

/// 业务员维度利润统计（对应契约 `BusinessUserReportData`）。
final class BusinessUserReport {
  const BusinessUserReport({
    required this.period,
    required this.items,
    required this.summary,
  });

  final String period;
  final List<BusinessUserSummary> items;
  final BusinessUserTotals summary;

  factory BusinessUserReport.fromJson(Map<String, Object?> json) =>
      BusinessUserReport(
        period: _readString(json, 'period'),
        items: <BusinessUserSummary>[
          for (final item in _readObjectList(json, 'items'))
            BusinessUserSummary.fromJson(item),
        ],
        summary: BusinessUserTotals.fromJson(_readObject(json, 'summary')),
      );
}

/// 一张月度总结算快照（对应契约 `SnapshotData`）。
///
/// 快照**生成即冻结**：无 version、无修改接口，要更正只能重新生成。
final class ReportSnapshot {
  const ReportSnapshot({
    required this.snapshotId,
    required this.snapshotNo,
    required this.batchNo,
    required this.scope,
    required this.period,
    required this.inboundAmount,
    required this.inboundAmountUpper,
    required this.outboundAmount,
    required this.outboundAmountUpper,
    required this.grossProfit,
    required this.grossProfitUpper,
    required this.grossMarginPpm,
    required this.grossMarginPercent,
    required this.saleAmountTypes,
    required this.documentCount,
    required this.createdBy,
    required this.createdAt,
    this.businessUser,
    this.remark,
  });

  final int snapshotId;
  final String snapshotNo;
  final String batchNo;
  final ReportScope scope;
  final String period;

  /// 业务员维度快照的业务员；**公司维度快照为 null**（后端回全零值）。
  final AuthUser? businessUser;

  final Amount inboundAmount;
  final String inboundAmountUpper;
  final Amount outboundAmount;
  final String outboundAmountUpper;
  final Amount grossProfit;
  final String grossProfitUpper;
  final int grossMarginPpm;
  final String grossMarginPercent;
  final List<SaleAmountTotal> saleAmountTypes;
  final int documentCount;
  final String? remark;
  final AuthUser createdBy;
  final DateTime createdAt;

  factory ReportSnapshot.fromJson(Map<String, Object?> json) => ReportSnapshot(
    snapshotId: _readPositiveInt(json, 'snapshot_id'),
    snapshotNo: _readString(json, 'snapshot_no'),
    batchNo: _readString(json, 'batch_no'),
    scope: ReportScope.fromWireValue(_readString(json, 'scope')),
    period: _readString(json, 'period'),
    // 公司维度快照的 business_user 是全零值（id=0/username 空）→ 解析成 null。
    businessUser: _readOptionalUser(json, 'business_user'),
    inboundAmount: _readAmount(json, 'inbound_amount'),
    inboundAmountUpper: _readString(json, 'inbound_amount_upper'),
    outboundAmount: _readAmount(json, 'outbound_amount'),
    outboundAmountUpper: _readString(json, 'outbound_amount_upper'),
    grossProfit: _readAmount(json, 'gross_profit'),
    grossProfitUpper: _readString(json, 'gross_profit_upper'),
    grossMarginPpm: _readInt(json, 'gross_margin_ppm'),
    grossMarginPercent: _readString(json, 'gross_margin_percent'),
    saleAmountTypes: _readSaleAmountTypes(json),
    documentCount: _readInt(json, 'document_count'),
    remark: json['remark'] as String?,
    createdBy: AuthUser.fromJson(_readObject(json, 'created_by')),
    createdAt: _readDateTime(json, 'created_at'),
  );
}

/// 生成月度总结算的响应（对应契约 `CreateSnapshotData`）。
///
/// 一次可能生成多张（业务员维度），带上批次号供整批展示。
final class CreateSnapshotResult {
  const CreateSnapshotResult({
    required this.batchNo,
    required this.period,
    required this.snapshots,
  });

  final String batchNo;
  final String period;
  final List<ReportSnapshot> snapshots;

  factory CreateSnapshotResult.fromJson(Map<String, Object?> json) =>
      CreateSnapshotResult(
        batchNo: _readString(json, 'batch_no'),
        period: _readString(json, 'period'),
        snapshots: <ReportSnapshot>[
          for (final snapshot in _readObjectList(json, 'snapshots'))
            ReportSnapshot.fromJson(snapshot),
        ],
      );
}

/* --------------------------------------------------------- 查询与写入草稿 */

/// 看板 / 统计的周期查询（`period` 形如 `2026-09`）。
final class PeriodQuery {
  const PeriodQuery({required this.period, this.businessUserId});

  final String period;
  final int? businessUserId;
}

/// 入库 / 出库统计的查询（含字段筛选与分页）。
final class StatsQuery {
  const StatsQuery({
    required this.period,
    this.businessUserId,
    this.partyName,
    this.productName,
    this.productModel,
    this.page = 1,
    this.pageSize = 20,
  });

  final String period;
  final int? businessUserId;
  final String? partyName;
  final String? productName;
  final String? productModel;
  final int page;
  final int pageSize;
}

/// 总结算快照列表查询。
final class SnapshotQuery {
  const SnapshotQuery({
    this.period,
    this.scope,
    this.businessUserId,
    this.page = 1,
    this.pageSize = 20,
  });

  final String? period;
  final ReportScope? scope;
  final int? businessUserId;
  final int page;
  final int pageSize;
}

/// 生成总结算快照的写入草稿。
final class CreateSnapshotDraft {
  const CreateSnapshotDraft({
    required this.period,
    required this.scope,
    this.businessUserId,
    this.remark,
  });

  final String period;
  final ReportScope scope;

  /// scope = businessUser 且不指定时为该周期每个有单据的业务员各生成一张。
  final int? businessUserId;
  final String? remark;
}

/* --------------------------------------------------------- 严格解析辅助 */

Map<String, Object?> _readObject(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! Map) {
    throw FormatException('字段 "$key" 必须是对象');
  }
  return Map<String, Object?>.from(value);
}

List<Map<String, Object?>> _readObjectList(
  Map<String, Object?> json,
  String key,
) {
  final value = json[key];
  if (value is! List) {
    throw FormatException('字段 "$key" 必须是数组');
  }
  return <Map<String, Object?>>[
    for (final item in value)
      if (item is Map)
        Map<String, Object?>.from(item)
      else
        throw FormatException('字段 "$key" 的元素必须是对象'),
  ];
}

List<SaleAmountTotal> _readSaleAmountTypes(Map<String, Object?> json) =>
    <SaleAmountTotal>[
      for (final item in _readObjectList(json, 'sale_amount_types'))
        SaleAmountTotal.fromJson(item),
    ];

List<ReportItem> _readItems(Map<String, Object?> json) => <ReportItem>[
  for (final item in _readObjectList(json, 'items')) ReportItem.fromJson(item),
];

int _readInt(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! int) {
    throw FormatException('字段 "$key" 必须是整数');
  }
  return value;
}

int _readPositiveInt(Map<String, Object?> json, String key) {
  final value = _readInt(json, key);
  if (value < 1) {
    throw FormatException('字段 "$key" 必须是正整数');
  }
  return value;
}

String _readString(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! String || value.isEmpty) {
    throw FormatException('字段 "$key" 必须是非空字符串');
  }
  return value;
}

DateTime _readDateTime(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! String) {
    throw FormatException('字段 "$key" 必须是 ISO-8601 时间');
  }
  return DateTime.parse(value).toUtc();
}

Amount _readAmount(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! String) {
    throw FormatException('字段 "$key" 必须是金额字符串');
  }
  return Amount.parse(value);
}

Quantity _readQuantity(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! String) {
    throw FormatException('字段 "$key" 必须是数量字符串');
  }
  return Quantity.parse(value);
}

/// 解析可空用户：公司维度快照的 `business_user` 是**全零值**（id=0、username 空），
/// 这与「字段缺失」不同 —— 契约明确要求公司维度快照回零值对象，所以这里把
/// 「id 非正整数」视为「没有具体业务员」返回 null，而不是抛错。
AuthUser? _readOptionalUser(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! Map) {
    throw FormatException('字段 "$key" 必须是对象');
  }
  final object = Map<String, Object?>.from(value);
  final id = object['id'];
  if (id is! int || id < 1) {
    return null;
  }
  return AuthUser.fromJson(object);
}
