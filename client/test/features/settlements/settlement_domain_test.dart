import 'package:c_biz_docs_manager/features/settlements/domain/settlement.dart';
import 'package:flutter_test/flutter_test.dart';

/// 结算领域模型的契约测试。
///
/// 逐条对齐后端 `internal/settlement/{model,dto}.go`：状态机（pending→approved/rejected，
/// 都终态）、金额快照、源单据 released、审批记录 action，以及「requester 是完整 UserSummary」。
void main() {
  group('枚举', () {
    test('SettlementStatus 状态机', () {
      expect(SettlementStatus.pending.wireValue, 'pending');
      expect(SettlementStatus.approved.wireValue, 'approved');
      expect(SettlementStatus.rejected.wireValue, 'rejected');
      expect(SettlementStatus.approved.isTerminal, isTrue);
      expect(SettlementStatus.rejected.isTerminal, isTrue);
      expect(SettlementStatus.pending.isTerminal, isFalse);
      expect(() => SettlementStatus.fromWireValue('x'), throwsFormatException);
    });

    test('SettlementAction', () {
      expect(SettlementAction.submitted.wireValue, 'submitted');
      expect(SettlementAction.approved.wireValue, 'approved');
      expect(SettlementAction.rejected.wireValue, 'rejected');
      expect(() => SettlementAction.fromWireValue('x'), throwsFormatException);
    });
  });

  group('SettlementUser（严格解析）', () {
    test('完整 UserSummary 严格解析', () {
      final user = SettlementUser.fromJson(<String, Object?>{
        'id': 7,
        'username': 'zhangsan',
        'display_name': '张三',
        'account_type': 'member',
      });
      expect(user.id, 7);
      expect(user.username, 'zhangsan');
      expect(user.displayName, '张三');
      expect(user.accountType.name, 'member');
    });

    test('account_type 空串或非法抛错', () {
      expect(
        () => SettlementUser.fromJson(<String, Object?>{
          'id': 7,
          'username': 'zhangsan',
          'display_name': '张三',
          'account_type': '',
        }),
        throwsFormatException,
      );
      expect(
        () => SettlementUser.fromJson(<String, Object?>{
          'id': 7,
          'username': 'zhangsan',
          'display_name': '张三',
          'account_type': 'unknown',
        }),
        throwsFormatException,
      );
    });
  });

  group('SettlementSummary（列表行）', () {
    test('解析列表行（无大写字段、无 sources/records）', () {
      final summary = SettlementSummary.fromJson(<String, Object?>{
        'settlement_id': 9,
        'settlement_no': 'JS202609-0003',
        'status': 'pending',
        'requester': _userJson(),
        'inbound_total': '10000.00',
        'outbound_total': '15000.00',
        'gross_profit': '5000.00',
        'source_count': 3,
        'version': 2,
        'decided_at': null,
        'decision_remark': null,
        'created_at': '2026-09-22T10:00:00Z',
        'updated_at': '2026-09-22T10:00:00Z',
      });

      expect(summary.settlementId, 9);
      expect(summary.settlementNo, 'JS202609-0003');
      expect(summary.status, SettlementStatus.pending);
      expect(summary.requester.displayName, '张三');
      expect(summary.inboundTotal.format(), '10000.00');
      expect(summary.outboundTotal.format(), '15000.00');
      expect(summary.grossProfit.format(), '5000.00');
      expect(summary.sourceCount, 3);
      expect(summary.version, 2);
    });

    test('金额字段必须是字符串', () {
      final json = _summaryJson()..['inbound_total'] = 10000.00;
      expect(() => SettlementSummary.fromJson(json), throwsFormatException);
    });
  });

  group('SettlementDetail（详情）', () {
    test('解析详情：sources + approval_records + 大写', () {
      final detail = SettlementDetail.fromJson(<String, Object?>{
        'settlement_id': 9,
        'settlement_no': 'JS202609-0003',
        'status': 'approved',
        'requester': _userJson(),
        'remark': '本月结算',
        'inbound_total': '10000.00',
        'outbound_total': '15000.00',
        'gross_profit': '5000.00',
        'source_count': 2,
        'inbound_total_upper': '人民币壹万元整',
        'outbound_total_upper': '人民币壹万伍仟元整',
        'gross_profit_upper': '人民币伍仟元整',
        'version': 3,
        'decided_at': '2026-09-22T11:00:00Z',
        'decided_by': _userJson(id: 8, username: 'admin'),
        'decision_remark': '同意',
        'created_at': '2026-09-22T10:00:00Z',
        'updated_at': '2026-09-22T11:00:00Z',
        'sources': <Object?>[
          <String, Object?>{
            'document_id': 42,
            'kind': 'inbound',
            'document_no': 'RK20260922-0001',
            'business_user': _userJson(),
            'business_date': '2026-09-22',
            'amount': '10000.00',
            'released': false,
          },
        ],
        'approval_records': <Object?>[
          <String, Object?>{
            'action': 'submitted',
            'operator': _userJson(),
            'remark': null,
            'created_at': '2026-09-22T10:00:00Z',
          },
          <String, Object?>{
            'action': 'approved',
            'operator': _userJson(id: 8, username: 'admin'),
            'remark': '同意',
            'created_at': '2026-09-22T11:00:00Z',
          },
        ],
      });

      expect(detail.status, SettlementStatus.approved);
      expect(detail.inboundUpper, '人民币壹万元整');
      expect(detail.decidedBy?.username, 'admin');
      expect(detail.decisionRemark, '同意');

      final source = detail.sources.single;
      expect(source.documentNo, 'RK20260922-0001');
      expect(source.kind.wireValue, 'inbound');
      expect(source.released, isFalse);
      expect(source.amount.format(), '10000.00');

      expect(detail.approvalRecords, hasLength(2));
      expect(detail.approvalRecords.first.action, SettlementAction.submitted);
      expect(detail.approvalRecords.last.action, SettlementAction.approved);
    });

    test('毛利润允许为负', () {
      final json = _detailJson()..['gross_profit'] = '-5000.00';
      final detail = SettlementDetail.fromJson(json);
      expect(detail.grossProfit.format(), '-5000.00');
      expect(detail.grossProfit.isNegative, isTrue);
    });
  });
}

/* ---------------------------------------------------------------- 夹具 */

Map<String, Object?> _userJson({int id = 7, String username = 'zhangsan'}) =>
    <String, Object?>{
      'id': id,
      'username': username,
      'display_name': '张三',
      'account_type': 'member',
    };

Map<String, Object?> _summaryJson() => <String, Object?>{
  'settlement_id': 9,
  'settlement_no': 'JS202609-0003',
  'status': 'pending',
  'requester': _userJson(),
  'inbound_total': '10000.00',
  'outbound_total': '15000.00',
  'gross_profit': '5000.00',
  'source_count': 2,
  'version': 2,
  'decided_at': null,
  'decision_remark': null,
  'created_at': '2026-09-22T10:00:00Z',
  'updated_at': '2026-09-22T10:00:00Z',
};

Map<String, Object?> _detailJson() => <String, Object?>{
  'settlement_id': 9,
  'settlement_no': 'JS202609-0003',
  'status': 'approved',
  'requester': _userJson(),
  'remark': '本月结算',
  'inbound_total': '10000.00',
  'outbound_total': '15000.00',
  'gross_profit': '5000.00',
  'source_count': 2,
  'inbound_total_upper': '人民币壹万元整',
  'outbound_total_upper': '人民币壹万伍仟元整',
  'gross_profit_upper': '人民币伍仟元整',
  'version': 3,
  'decided_at': '2026-09-22T11:00:00Z',
  'decided_by': _userJson(id: 8, username: 'admin'),
  'decision_remark': '同意',
  'created_at': '2026-09-22T10:00:00Z',
  'updated_at': '2026-09-22T11:00:00Z',
  'sources': <Object?>[],
  'approval_records': <Object?>[],
};
