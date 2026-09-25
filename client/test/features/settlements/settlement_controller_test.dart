import 'dart:async';

import 'package:c_biz_docs_manager/core/auth/auth_models.dart';
import 'package:c_biz_docs_manager/core/error/app_failure.dart';
import 'package:c_biz_docs_manager/core/money/money.dart';
import 'package:c_biz_docs_manager/core/network/page_result.dart';
import 'package:c_biz_docs_manager/features/settlements/application/settlement_controller.dart';
import 'package:c_biz_docs_manager/features/settlements/data/settlement_repository.dart';
import 'package:c_biz_docs_manager/features/settlements/domain/settlement.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
// `Override` 在 Riverpod 3 里由 misc.dart 导出。
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

/// 结算控制器的时序测试。
void main() {
  late FakeSettlementRepository repository;
  late ProviderContainer container;

  setUp(() {
    repository = FakeSettlementRepository();
    container = ProviderContainer(
      overrides: <Override>[
        settlementRepositoryProvider.overrideWithValue(repository),
      ],
    );
    addTearDown(container.dispose);
  });

  SettlementController controller() =>
      container.read(settlementControllerProvider.notifier);

  SettlementState state() => container.read(settlementControllerProvider);

  test('加载成功写入 items', () async {
    repository.listResult = <SettlementSummary>[_summary(9)];
    await controller().load(const SettlementQuery());
    expect(state().items, hasLength(1));
    expect(state().isLoading, isFalse);
  });

  test('审批成功后替换详情并重读列表', () async {
    repository.listResult = <SettlementSummary>[_summary(9)];
    await controller().load(const SettlementQuery());
    repository.detailResult = _detail(9, status: SettlementStatus.approved);

    await controller().approve(9, 2);

    expect(state().detail?.status, SettlementStatus.approved);
    expect(repository.approveCalls, 1);
  });

  test('驳回必填 remark 传给仓储', () async {
    repository.listResult = <SettlementSummary>[_summary(9)];
    await controller().load(const SettlementQuery());
    repository.detailResult = _detail(9, status: SettlementStatus.rejected);

    await controller().reject(9, 2, '金额不符');

    expect(repository.lastRejectRemark, '金额不符');
  });

  test('审批冲突后重读列表并保留冲突原因', () async {
    repository.listResult = <SettlementSummary>[_summary(9)];
    await controller().load(const SettlementQuery());
    repository.approveError = const ConflictFailure('conflict');

    await controller().approve(9, 2);

    expect(repository.listCalls, greaterThan(1));
    expect(state().failure, isA<ConflictFailure>());
  });

  test('dispose 后在途结果不写 state', () async {
    final gate = Completer<List<SettlementSummary>>();
    repository.queuedLists.add(gate.future);

    final loadFuture = controller().load(const SettlementQuery());
    container.dispose();

    gate.complete(<SettlementSummary>[_summary(9)]);
    await loadFuture;
    // 不抛错即通过。
  });
}

/* ---------------------------------------------------------------- 假仓储 */

final class FakeSettlementRepository implements SettlementRepository {
  final List<Future<List<SettlementSummary>>> queuedLists =
      <Future<List<SettlementSummary>>>[];
  List<SettlementSummary>? listResult;
  Object? listError;
  SettlementDetail? detailResult;
  Object? approveError;
  Object? rejectError;

  int listCalls = 0;
  int approveCalls = 0;
  String? lastRejectRemark;

  @override
  Future<PageResult<SettlementSummary>> list(SettlementQuery query) {
    listCalls++;
    if (listError != null) {
      return Future<PageResult<SettlementSummary>>.error(listError!);
    }
    if (queuedLists.isNotEmpty) {
      return queuedLists
          .removeAt(0)
          .then(
            (items) => PageResult<SettlementSummary>(
              items: items,
              page: 1,
              pageSize: 20,
              total: items.length,
            ),
          );
    }
    final items = listResult ?? <SettlementSummary>[];
    return Future<PageResult<SettlementSummary>>.value(
      PageResult<SettlementSummary>(
        items: items,
        page: 1,
        pageSize: 20,
        total: items.length,
      ),
    );
  }

  @override
  Future<SettlementDetail> get(int settlementId) =>
      Future<SettlementDetail>.value(detailResult ?? _detail(settlementId));

  @override
  Future<SettlementDetail> create(SettlementDraft draft) =>
      Future<SettlementDetail>.value(detailResult ?? _detail(1));

  @override
  Future<SettlementDetail> approve(int settlementId, int version) {
    approveCalls++;
    if (approveError != null) {
      return Future<SettlementDetail>.error(approveError!);
    }
    return Future<SettlementDetail>.value(
      detailResult ?? _detail(settlementId, status: SettlementStatus.approved),
    );
  }

  @override
  Future<SettlementDetail> reject(
    int settlementId,
    int version,
    String remark,
  ) {
    lastRejectRemark = remark;
    if (rejectError != null) {
      return Future<SettlementDetail>.error(rejectError!);
    }
    return Future<SettlementDetail>.value(
      detailResult ?? _detail(settlementId, status: SettlementStatus.rejected),
    );
  }
}

/* ---------------------------------------------------------------- 构造数据 */

SettlementSummary _summary(int id) => SettlementSummary(
  settlementId: id,
  settlementNo: 'JS202609-000$id',
  status: SettlementStatus.pending,
  requester: const AuthUser(
    id: 7,
    username: 'zhangsan',
    displayName: '张三',
    accountType: AccountType.member,
  ),
  inboundTotal: Amount.parse('10000.00'),
  outboundTotal: Amount.parse('15000.00'),
  grossProfit: Amount.parse('5000.00'),
  sourceCount: 2,
  version: 1,
  createdAt: DateTime.utc(2026, 9, 22),
  updatedAt: DateTime.utc(2026, 9, 22),
);

SettlementDetail _detail(
  int id, {
  SettlementStatus status = SettlementStatus.pending,
}) => SettlementDetail(
  settlementId: id,
  settlementNo: 'JS202609-000$id',
  status: status,
  requester: const AuthUser(
    id: 7,
    username: 'zhangsan',
    displayName: '张三',
    accountType: AccountType.member,
  ),
  inboundTotal: Amount.parse('10000.00'),
  outboundTotal: Amount.parse('15000.00'),
  grossProfit: Amount.parse('5000.00'),
  sourceCount: 2,
  inboundUpper: '人民币壹万元整',
  outboundUpper: '人民币壹万伍仟元整',
  grossProfitUpper: '人民币伍仟元整',
  version: 1,
  createdAt: DateTime.utc(2026, 9, 22),
  updatedAt: DateTime.utc(2026, 9, 22),
  sources: const <SettlementSource>[],
  approvalRecords: const <SettlementApprovalRecord>[],
);
