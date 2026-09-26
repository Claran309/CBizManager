import 'dart:convert';
import 'dart:io';

import 'package:c_biz_docs_manager/core/auth/auth_models.dart';
import 'package:c_biz_docs_manager/core/network/page_result.dart';
import 'package:c_biz_docs_manager/features/documents/domain/document.dart';
import 'package:c_biz_docs_manager/features/finance/domain/finance.dart';
import 'package:c_biz_docs_manager/features/platform/domain/platform_group.dart';
import 'package:c_biz_docs_manager/features/reports/domain/report.dart';
import 'package:c_biz_docs_manager/features/settlements/domain/settlement.dart';
import 'package:flutter_test/flutter_test.dart';

/// 真实后端报文的解析契约测试。
///
/// 夹具 `test/fixtures/real_backend/payloads.json` 是**真后端**（Go + 真 MySQL）
/// 对同一套客户端请求的真实响应，由 `.workbuddy/tmp/e2e_real_backend.py` 抓取。
///
/// 为什么需要它：客户端的 `fromJson` 是**严格**的（缺字段、类型不符一律抛
/// FormatException）。只对着测试替身（FakeBackend）跑，永远证明不了「真后端发来的
/// 报文客户端吃得下」—— 替身的形状是我们自己写的，两边一起错就测不出来。
/// 这里把真实报文灌进同一批解析器，任何字段名/类型/可空性漂移都会立刻报错。
void main() {
  late Map<String, Object?> fixtures;

  setUpAll(() {
    final file = File('test/fixtures/real_backend/payloads.json');
    fixtures = jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
  });

  Map<String, Object?> payload(String name) {
    final value = fixtures[name];
    if (value is! Map) {
      throw StateError('夹具缺少 $name（实际条目：${fixtures.keys.toList()..sort()}）');
    }
    return Map<String, Object?>.from(value);
  }

  test('夹具覆盖了各模块的代表性响应', () {
    expect((fixtures.keys.toList()..sort()), <String>[
      'create_group',
      'document_detail',
      'document_list',
      'owner_me',
      'report_inbound_stats',
      'report_overview',
      'report_snapshot_create',
      'settlement_approved',
      'settlement_detail_pending',
      'statement_after_payment',
      'statement_before_payment',
      'statement_outbound_receipt',
    ]);
  });

  test('/auth/me 真实报文能被严格解析为 AuthProfile', () {
    final profile = AuthProfile.fromJson(payload('owner_me'));

    expect(profile.accountType, AccountType.groupOwner);
    expect(profile.memberType, MemberType.owner);
    expect(profile.mustChangePassword, isFalse);
    expect(profile.group, isNotNull);
    expect(profile.group!.id, greaterThan(0));
    // 主账号的权限是隐式的，服务端下发空数组。
    expect(profile.hasPermission('report.view'), isTrue);
  });

  test('建组响应能被解析为 CreateGroupResult（group.id/name + owner）', () {
    final result = CreateGroupResult.fromJson(payload('create_group'));

    expect(result.groupId, greaterThan(0));
    expect(result.groupName, isNotEmpty);
    expect(result.owner.username, isNotEmpty);
    expect(result.owner.displayName, isNotEmpty);
  });

  test('单据详情真实报文能被严格解析（含明细与单价小数位）', () {
    final doc = DocumentDetail.fromJson(payload('document_detail'));

    expect(doc.kind, DocumentKind.inbound);
    expect(doc.documentNo, startsWith('RK20260922-'));
    expect(doc.totalAmount.format(), '100000.00');
    // 大写来自服务端，客户端只透传（**不假定前缀**：实测真后端是 `RMB…`）。
    expect(doc.totalAmountUpper, contains('元'));

    final item = doc.parties.first.items.first;
    expect(item.productName, '螺纹钢');
    expect(item.quantity.format(), '10.000');
    expect(item.unitPrice.format(), '10000.0000');
    expect(item.priceTaxMode, PriceTaxMode.taxIncluded);
    expect(item.amount.format(), '100000.00');
  });

  test('单据列表真实报文能被解析为分页结果', () {
    final page = PageResult<DocumentSummary>.fromJson(
      payload('document_list'),
      DocumentSummary.fromJson,
    );

    expect(page.page, greaterThanOrEqualTo(1));
    expect(page.pageSize, greaterThanOrEqualTo(1));
    expect(page.items, isNotEmpty);
    final summary = page.items.first;
    expect(summary.kind, DocumentKind.inbound);
    expect(summary.status, DocumentStatus.submitted);
    expect(summary.partyNames, isNotEmpty);
  });

  test('结算单真实报文能被严格解析（待审批与已审批两种形态）', () {
    final pending = SettlementDetail.fromJson(
      payload('settlement_detail_pending'),
    );
    expect(pending.status, SettlementStatus.pending);
    expect(pending.settlementNo, startsWith('JS202609-'));
    expect(pending.inboundTotal.format(), '100000.00');
    expect(pending.outboundTotal.format(), '120000.00');
    expect(pending.grossProfit.format(), '20000.00');
    expect(pending.sources, hasLength(2));
    expect(pending.sources.first.released, isFalse);
    expect(pending.approvalRecords, isNotEmpty);

    final approved = SettlementDetail.fromJson(payload('settlement_approved'));
    expect(approved.status, SettlementStatus.approved);
    expect(approved.decidedBy, isNotNull);
    expect(approved.decidedAt, isNotNull);
  });

  test('结清视图真实报文能被严格解析（入库：已付/未付/开票）', () {
    final before = FinanceStatement.fromJson(
      payload('statement_before_payment'),
    );
    expect(before.documentKind, DocumentKind.inbound);
    expect(before.unpaidAmount.format(), '100000.00');
    expect(before.paidAmount.format(), '0.00');
    expect(before.invoiceStatus, InvoiceStatus.none);
    // 入库单不涉收款，服务端给 0（不是缺字段）。
    expect(before.receivedAmount.format(), '0.00');
    expect(before.records, isEmpty);

    final after = FinanceStatement.fromJson(payload('statement_after_payment'));
    expect(after.paidAmount.format(), '30000.00');
    expect(after.unpaidAmount.format(), '70000.00');
    expect(after.records, hasLength(1));
    final record = after.records.first;
    expect(record.kind, FinanceKind.payment);
    expect(record.method, FinanceMethod.privateCard);
    // 脱敏：只留后 4 位。
    expect(record.cardTail, '1234');
  });

  test('出库单结清视图：开票状态恒为 not_applicable（不是 none）', () {
    final outbound = FinanceStatement.fromJson(
      payload('statement_outbound_receipt'),
    );
    expect(outbound.documentKind, DocumentKind.outbound);
    expect(outbound.receivedAmount.format(), '40000.00');
    expect(outbound.unreceivedAmount.format(), '80000.00');
    expect(outbound.invoiceStatus, InvoiceStatus.notApplicable);
  });

  test('看板真实报文能被严格解析（比率是 ppm 整数）', () {
    final overview = ReportOverview.fromJson(payload('report_overview'));

    expect(overview.period, '2026-09');
    expect(overview.inboundAmount.format(), '100000.00');
    expect(overview.outboundAmount.format(), '120000.00');
    expect(overview.grossProfit.format(), '20000.00');
    expect(overview.paidAmount.format(), '30000.00');
    expect(overview.receivedAmount.format(), '40000.00');
    expect(overview.grossMarginPpm, isA<int>());
    expect(overview.saleAmountTypes, isNotEmpty);
  });

  test('入库统计真实报文能被严格解析（含明细聚合行）', () {
    final stats = InboundStats.fromJson(payload('report_inbound_stats'));

    expect(stats.documentCount, greaterThan(0));
    expect(stats.amountTotal.format(), '100000.00');
    expect(stats.items, isNotEmpty);
    expect(stats.items.first.productName, isNotEmpty);
  });

  test('总结算快照真实报文能被严格解析', () {
    final created = CreateSnapshotResult.fromJson(
      payload('report_snapshot_create'),
    );

    expect(created.snapshots, isNotEmpty);
    final snapshot = created.snapshots.first;
    expect(snapshot.snapshotNo, startsWith('ZJS202609-'));
    expect(snapshot.scope, ReportScope.company);
    expect(snapshot.period, '2026-09');
    expect(snapshot.inboundAmount.format(), '100000.00');
    expect(snapshot.outboundAmount.format(), '120000.00');
    expect(snapshot.grossProfit.format(), '20000.00');
    // 公司维度快照：服务端回「全零值占位」的 business_user（id=0、username 空），
    // 客户端**有意**把它解析成 null（公司维度没有业务员，留个 id=0 的假用户会骗 UI）。
    // 这条是真实报文验证过的约定，不是猜测。
    expect(snapshot.businessUser, isNull);
    expect(snapshot.snapshotNo, isNotEmpty);
    expect(snapshot.batchNo, isNotEmpty);
  });
}
