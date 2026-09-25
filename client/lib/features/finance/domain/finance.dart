import 'package:c_biz_docs_manager/core/auth/auth_models.dart';
import 'package:c_biz_docs_manager/core/bizdate/bizdate.dart';
import 'package:c_biz_docs_manager/core/money/money.dart';
import 'package:c_biz_docs_manager/features/documents/domain/document.dart';

/// 财务记录类型。
///
/// 三类记录共用一张表与一套仓储，差异只在「挂在哪种单据上、需要哪些额外字段、
/// 怎么汇总」：
/// - payment（付款）只挂入库单，单据维度看「已付 / 未付」；
/// - receipt（收款）只挂出库单，单据维度看「已收 / 未收」；
/// - invoice（开票）只挂入库单，单据维度看「已开票 / 未开票」。
///
/// 与单据方向的关系由后端 `Kind.DocumentKind()` 决定，客户端用 [documentKind]
/// 复现这条约束，用于「登记时提示单据类型不匹配」这类展示逻辑。
enum FinanceKind {
  payment('payment'),
  receipt('receipt'),
  invoice('invoice');

  const FinanceKind(this.wireValue);

  final String wireValue;

  static FinanceKind fromWireValue(String value) => values.firstWhere(
    (kind) => kind.wireValue == value,
    orElse: () => throw FormatException('未知财务记录类型：$value'),
  );

  /// 该记录类型只能挂载的单据方向。
  DocumentKind get documentKind =>
      this == receipt ? DocumentKind.outbound : DocumentKind.inbound;

  /// 是否携带付款 / 收款方式（开票没有「方式」概念）。
  bool get carriesMethod => this == payment || this == receipt;

  /// 是否携带发票号。
  bool get carriesInvoiceNo => this == invoice;

  /// 路由段（`payments` / `receipts` / `invoices`）。
  String get routeSegment => switch (this) {
    payment => 'payments',
    receipt => 'receipts',
    invoice => 'invoices',
  };

  /// 中文展示文案。
  String get label => switch (this) {
    payment => '付款',
    receipt => '收款',
    invoice => '开票',
  };
}

/// 付款 / 收款方式。
enum FinanceMethod {
  transfer('transfer'),
  privateCard('private_card'),
  publicAccount('public_account');

  const FinanceMethod(this.wireValue);

  final String wireValue;

  static FinanceMethod fromWireValue(String value) => values.firstWhere(
    (method) => method.wireValue == value,
    orElse: () => throw FormatException('未知付款方式：$value'),
  );

  String get label => switch (this) {
    transfer => '转账',
    privateCard => '对私卡',
    publicAccount => '对公账户',
  };
}

/// 单据维度的开票状态。
///
/// 不落库，由「已开票金额合计」与「单据总额」在服务端推导。出库单恒为
/// [notApplicable]（出库单不存在开票概念，回 `none` 会让客户端显示「未开票」这种
/// 误导文案）。
enum InvoiceStatus {
  none('none'),
  partial('partial'),
  full('full'),
  notApplicable('not_applicable');

  const InvoiceStatus(this.wireValue);

  final String wireValue;

  static InvoiceStatus fromWireValue(String value) => values.firstWhere(
    (status) => status.wireValue == value,
    orElse: () => throw FormatException('未知开票状态：$value'),
  );

  String get label => switch (this) {
    none => '未开票',
    partial => '部分开票',
    full => '已开票',
    notApplicable => '不适用',
  };
}

/// 一条付款 / 收款 / 开票记录（对应契约 `RecordData`）。
final class FinanceRecord {
  const FinanceRecord({
    required this.recordId,
    required this.kind,
    required this.documentId,
    required this.documentKind,
    required this.documentNo,
    required this.partyName,
    required this.businessUser,
    required this.businessDate,
    required this.amount,
    required this.amountUpper,
    required this.occurredOn,
    required this.createdBy,
    required this.createdAt,
    this.method,
    this.methodNote,
    this.cardTail,
    this.invoiceNo,
    this.remark,
  });

  final int recordId;
  final FinanceKind kind;
  final int documentId;
  final DocumentKind documentKind;
  final String documentNo;
  final String partyName;
  final AuthUser businessUser;
  final DateTime businessDate;
  final Amount amount;
  final String amountUpper;
  final DateTime occurredOn;
  final FinanceMethod? method;
  final String? methodNote;

  /// 只暴露后 4 位：完整卡号不进入系统。
  final String? cardTail;
  final String? invoiceNo;
  final String? remark;
  final AuthUser createdBy;
  final DateTime createdAt;

  factory FinanceRecord.fromJson(Map<String, Object?> json) => FinanceRecord(
    recordId: _readPositiveInt(json, 'record_id'),
    kind: FinanceKind.fromWireValue(_readString(json, 'kind')),
    documentId: _readPositiveInt(json, 'document_id'),
    documentKind: DocumentKind.fromWireValue(
      _readString(json, 'document_kind'),
    ),
    documentNo: _readString(json, 'document_no'),
    partyName: _readString(json, 'party_name'),
    businessUser: AuthUser.fromJson(_readObject(json, 'business_user')),
    businessDate: parseDate(_readString(json, 'business_date')),
    amount: _readAmount(json, 'amount'),
    amountUpper: _readString(json, 'amount_upper'),
    occurredOn: parseDate(_readString(json, 'occurred_on')),
    method: json['method'] == null
        ? null
        : FinanceMethod.fromWireValue(json['method'] as String),
    methodNote: json['method_note'] as String?,
    cardTail: json['card_tail'] as String?,
    invoiceNo: json['invoice_no'] as String?,
    remark: json['remark'] as String?,
    createdBy: AuthUser.fromJson(_readObject(json, 'created_by')),
    createdAt: _readDateTime(json, 'created_at'),
  );
}

/// 单张单据的结清视图（对应契约 `StatementData`）。
///
/// 三类金额只在适用的单据方向取值，不适用方向恒为 0，客户端不判断单据类型：
/// - 入库单：paid / unpaid / invoiced / uninvoiced + invoice_status；
/// - 出库单：received / unreceived。
final class FinanceStatement {
  const FinanceStatement({
    required this.documentId,
    required this.documentKind,
    required this.documentNo,
    required this.partyName,
    required this.businessUser,
    required this.businessDate,
    required this.totalAmount,
    required this.totalUpper,
    required this.paidAmount,
    required this.unpaidAmount,
    required this.invoicedAmount,
    required this.uninvoicedAmount,
    required this.invoiceStatus,
    required this.receivedAmount,
    required this.unreceivedAmount,
    required this.paymentCount,
    required this.receiptCount,
    required this.invoiceCount,
    required this.records,
  });

  final int documentId;
  final DocumentKind documentKind;
  final String documentNo;
  final String partyName;
  final AuthUser businessUser;
  final DateTime businessDate;
  final Amount totalAmount;
  final String totalUpper;

  final Amount paidAmount;
  final Amount unpaidAmount;
  final Amount invoicedAmount;
  final Amount uninvoicedAmount;
  final InvoiceStatus invoiceStatus;

  final Amount receivedAmount;
  final Amount unreceivedAmount;

  final int paymentCount;
  final int receiptCount;
  final int invoiceCount;

  final List<FinanceRecord> records;

  factory FinanceStatement.fromJson(Map<String, Object?> json) =>
      FinanceStatement(
        documentId: _readPositiveInt(json, 'document_id'),
        documentKind: DocumentKind.fromWireValue(
          _readString(json, 'document_kind'),
        ),
        documentNo: _readString(json, 'document_no'),
        partyName: _readString(json, 'party_name'),
        businessUser: AuthUser.fromJson(_readObject(json, 'business_user')),
        businessDate: parseDate(_readString(json, 'business_date')),
        totalAmount: _readAmount(json, 'total_amount'),
        totalUpper: _readString(json, 'total_amount_upper'),
        paidAmount: _readAmount(json, 'paid_amount'),
        unpaidAmount: _readAmount(json, 'unpaid_amount'),
        invoicedAmount: _readAmount(json, 'invoiced_amount'),
        uninvoicedAmount: _readAmount(json, 'uninvoiced_amount'),
        invoiceStatus: InvoiceStatus.fromWireValue(
          _readString(json, 'invoice_status'),
        ),
        receivedAmount: _readAmount(json, 'received_amount'),
        unreceivedAmount: _readAmount(json, 'unreceived_amount'),
        paymentCount: _readInt(json, 'payment_count'),
        receiptCount: _readInt(json, 'receipt_count'),
        invoiceCount: _readInt(json, 'invoice_count'),
        records: <FinanceRecord>[
          for (final record in _readObjectList(json, 'records'))
            FinanceRecord.fromJson(record),
        ],
      );
}

/// 财务记录列表查询条件。
final class FinanceQuery {
  const FinanceQuery({
    this.documentId,
    this.keyword,
    this.method,
    this.businessUserId,
    this.month,
    this.dateFrom,
    this.dateTo,
    this.page = 1,
    this.pageSize = 20,
  });

  final int? documentId;
  final String? keyword;
  final FinanceMethod? method;
  final int? businessUserId;
  final String? month;
  final String? dateFrom;
  final String? dateTo;
  final int page;
  final int pageSize;
}

/// 登记财务记录的写入草稿（对应契约 `CreateRequest`）。
///
/// 没有 `kind`（由路由决定）。`method` 三态字段互斥由表单层保证：
/// - transfer 可带 method_note、不能带 card_tail；
/// - private_card 必带 card_tail、不能带 method_note；
/// - public_account 两者都不能带；
/// - invoice_no 仅开票可填。
final class FinanceRecordDraft {
  const FinanceRecordDraft({
    required this.documentId,
    required this.amount,
    required this.occurredOn,
    this.method,
    this.methodNote,
    this.cardTail,
    this.invoiceNo,
    this.remark,
  });

  final int documentId;

  /// 金额字符串（如 `"30000.00"`），服务端解析。
  final String amount;

  /// 实际发生日期，兼容五种写法。
  final String occurredOn;
  final FinanceMethod? method;
  final String? methodNote;

  /// 卡号后 4 位。
  final String? cardTail;
  final String? invoiceNo;
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
