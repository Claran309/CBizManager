import 'package:c_biz_docs_manager/core/auth/auth_models.dart';
import 'package:c_biz_docs_manager/core/bizdate/bizdate.dart';
import 'package:c_biz_docs_manager/core/money/money.dart';
import 'package:c_biz_docs_manager/features/documents/domain/document.dart';

/// 结算单的审批状态。
///
/// 一期只做单级审批：待审批 → 审批通过 / 审批驳回。通过与驳回都是终态，
/// 业务员要重新申请只能修改源单据后新建一张结算单。
enum SettlementStatus {
  pending('pending'),
  approved('approved'),
  rejected('rejected');

  const SettlementStatus(this.wireValue);

  final String wireValue;

  static SettlementStatus fromWireValue(String value) => values.firstWhere(
    (status) => status.wireValue == value,
    orElse: () => throw FormatException('未知结算状态：$value'),
  );

  /// 是否终态（已审批过，不可再次审批）。
  bool get isTerminal => this == approved || this == rejected;
}

/// 审批记录中的动作，覆盖「申请」与两次审批结论。
enum SettlementAction {
  submitted('submitted'),
  approved('approved'),
  rejected('rejected');

  const SettlementAction(this.wireValue);

  final String wireValue;

  static SettlementAction fromWireValue(String value) => values.firstWhere(
    (action) => action.wireValue == value,
    orElse: () => throw FormatException('未知审批动作：$value'),
  );
}

/// 结算单里出现的用户摘要（申请人 / 审批人 / 源单据业务员）。
///
/// 与单据列表行的 [DocumentBusinessUser]（宽松解析）不同，结算里的 UserSummary
/// 是**完整**的：后端 `Summary` 明确注释「列表行带完整字段（用户名/账号类型），
/// 否则客户端按契约校验账号类型枚举时会被空串卡住」。所以这里对四个字段都做
/// 强校验，`account_type` 走 [AccountType.fromWireValue]（空串/未知值抛错）。
final class SettlementUser {
  const SettlementUser({
    required this.id,
    required this.username,
    required this.displayName,
    required this.accountType,
  });

  final int id;
  final String username;
  final String displayName;
  final AccountType accountType;

  factory SettlementUser.fromJson(Map<String, Object?> json) {
    final id = json['id'];
    if (id is! int || id < 1) {
      throw const FormatException('用户 id 无效');
    }
    final username = json['username'];
    if (username is! String || username.isEmpty) {
      throw const FormatException('用户 username 无效');
    }
    final displayName = json['display_name'];
    if (displayName is! String || displayName.isEmpty) {
      throw const FormatException('用户 display_name 无效');
    }
    final accountType = json['account_type'];
    if (accountType is! String) {
      throw const FormatException('用户 account_type 无效');
    }
    return SettlementUser(
      id: id,
      username: username,
      displayName: displayName,
      accountType: AccountType.fromWireValue(accountType),
    );
  }
}

/// 结算单列表行（对应契约 `SettlementSummaryData`）。
final class SettlementSummary {
  const SettlementSummary({
    required this.settlementId,
    required this.settlementNo,
    required this.status,
    required this.requester,
    required this.inboundTotal,
    required this.outboundTotal,
    required this.grossProfit,
    required this.sourceCount,
    required this.version,
    required this.createdAt,
    required this.updatedAt,
    this.decidedAt,
    this.decisionRemark,
  });

  final int settlementId;
  final String settlementNo;
  final SettlementStatus status;
  final SettlementUser requester;
  final Amount inboundTotal;
  final Amount outboundTotal;

  /// 毛利润 = 出库合计 − 入库合计，允许为负。
  final Amount grossProfit;
  final int sourceCount;
  final int version;
  final DateTime? decidedAt;
  final String? decisionRemark;
  final DateTime createdAt;
  final DateTime updatedAt;

  factory SettlementSummary.fromJson(Map<String, Object?> json) =>
      SettlementSummary(
        settlementId: _readPositiveInt(json, 'settlement_id'),
        settlementNo: _readString(json, 'settlement_no'),
        status: SettlementStatus.fromWireValue(_readString(json, 'status')),
        requester: SettlementUser.fromJson(_readObject(json, 'requester')),
        inboundTotal: _readAmount(json, 'inbound_total'),
        outboundTotal: _readAmount(json, 'outbound_total'),
        grossProfit: _readAmount(json, 'gross_profit'),
        sourceCount: _readInt(json, 'source_count'),
        version: _readInt(json, 'version'),
        decidedAt: json['decided_at'] == null
            ? null
            : DateTime.parse(json['decided_at'] as String).toUtc(),
        decisionRemark: json['decision_remark'] as String?,
        createdAt: _readDateTime(json, 'created_at'),
        updatedAt: _readDateTime(json, 'updated_at'),
      );
}

/// 结算单引用的源单据快照（对应契约 `SourceData`）。
final class SettlementSource {
  const SettlementSource({
    required this.documentId,
    required this.kind,
    required this.documentNo,
    required this.businessUser,
    required this.businessDate,
    required this.amount,
    required this.released,
  });

  final int documentId;
  final DocumentKind kind;
  final String documentNo;
  final SettlementUser businessUser;
  final DateTime businessDate;
  final Amount amount;

  /// 该源单据是否已被释放（结算单被驳回），可以重新申请结算。
  final bool released;

  factory SettlementSource.fromJson(Map<String, Object?> json) =>
      SettlementSource(
        documentId: _readPositiveInt(json, 'document_id'),
        kind: DocumentKind.fromWireValue(_readString(json, 'kind')),
        documentNo: _readString(json, 'document_no'),
        businessUser: SettlementUser.fromJson(
          _readObject(json, 'business_user'),
        ),
        businessDate: parseDate(_readString(json, 'business_date')),
        amount: _readAmount(json, 'amount'),
        released: json['released'] as bool,
      );
}

/// 审批链路上的一条记录（对应契约 `ApprovalRecordData`）。
final class SettlementApprovalRecord {
  const SettlementApprovalRecord({
    required this.action,
    required this.operator,
    required this.createdAt,
    this.remark,
  });

  final SettlementAction action;
  final SettlementUser operator;
  final String? remark;
  final DateTime createdAt;

  factory SettlementApprovalRecord.fromJson(Map<String, Object?> json) =>
      SettlementApprovalRecord(
        action: SettlementAction.fromWireValue(_readString(json, 'action')),
        operator: SettlementUser.fromJson(_readObject(json, 'operator')),
        remark: json['remark'] as String?,
        createdAt: _readDateTime(json, 'created_at'),
      );
}

/// 结算单详情（对应契约 `SettlementData`）：主表 + 源单据快照 + 审批记录。
final class SettlementDetail {
  const SettlementDetail({
    required this.settlementId,
    required this.settlementNo,
    required this.status,
    required this.requester,
    required this.inboundTotal,
    required this.outboundTotal,
    required this.grossProfit,
    required this.sourceCount,
    required this.inboundUpper,
    required this.outboundUpper,
    required this.grossProfitUpper,
    required this.version,
    required this.createdAt,
    required this.updatedAt,
    required this.sources,
    required this.approvalRecords,
    this.remark,
    this.decidedAt,
    this.decidedBy,
    this.decisionRemark,
  });

  final int settlementId;
  final String settlementNo;
  final SettlementStatus status;
  final SettlementUser requester;
  final String? remark;
  final Amount inboundTotal;
  final Amount outboundTotal;
  final Amount grossProfit;
  final int sourceCount;

  /// 三项金额的人民币大写，服务端生成，客户端直接展示。
  final String inboundUpper;
  final String outboundUpper;
  final String grossProfitUpper;
  final int version;
  final DateTime? decidedAt;
  final SettlementUser? decidedBy;
  final String? decisionRemark;
  final DateTime createdAt;
  final DateTime updatedAt;
  final List<SettlementSource> sources;
  final List<SettlementApprovalRecord> approvalRecords;

  factory SettlementDetail.fromJson(Map<String, Object?> json) =>
      SettlementDetail(
        settlementId: _readPositiveInt(json, 'settlement_id'),
        settlementNo: _readString(json, 'settlement_no'),
        status: SettlementStatus.fromWireValue(_readString(json, 'status')),
        requester: SettlementUser.fromJson(_readObject(json, 'requester')),
        remark: json['remark'] as String?,
        inboundTotal: _readAmount(json, 'inbound_total'),
        outboundTotal: _readAmount(json, 'outbound_total'),
        grossProfit: _readAmount(json, 'gross_profit'),
        sourceCount: _readInt(json, 'source_count'),
        inboundUpper: _readString(json, 'inbound_total_upper'),
        outboundUpper: _readString(json, 'outbound_total_upper'),
        grossProfitUpper: _readString(json, 'gross_profit_upper'),
        version: _readInt(json, 'version'),
        decidedAt: json['decided_at'] == null
            ? null
            : DateTime.parse(json['decided_at'] as String).toUtc(),
        decidedBy: json['decided_by'] == null
            ? null
            : SettlementUser.fromJson(_readObject(json, 'decided_by')),
        decisionRemark: json['decision_remark'] as String?,
        createdAt: _readDateTime(json, 'created_at'),
        updatedAt: _readDateTime(json, 'updated_at'),
        sources: <SettlementSource>[
          for (final source in _readObjectList(json, 'sources'))
            SettlementSource.fromJson(source),
        ],
        approvalRecords: <SettlementApprovalRecord>[
          for (final record in _readObjectList(json, 'approval_records'))
            SettlementApprovalRecord.fromJson(record),
        ],
      );
}

/* --------------------------------------------------------- 查询与写入草稿 */

/// 结算单列表查询条件。
final class SettlementQuery {
  const SettlementQuery({
    this.status,
    this.keyword,
    this.requesterUserId,
    this.month,
    this.page = 1,
    this.pageSize = 20,
  });

  final SettlementStatus? status;

  /// 同时匹配结算单号。
  final String? keyword;
  final int? requesterUserId;

  /// 形如 `2026-09` 的创建月份。
  final String? month;
  final int page;
  final int pageSize;
}

/// 提交结算申请的写入草稿：勾选的源单据 + 可选备注。
final class SettlementDraft {
  const SettlementDraft({required this.sourceDocumentIds, this.remark});

  final List<int> sourceDocumentIds;
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
