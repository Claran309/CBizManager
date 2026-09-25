import 'package:c_biz_docs_manager/app/router.dart';
import 'package:c_biz_docs_manager/core/auth/auth_controller.dart';
import 'package:c_biz_docs_manager/core/auth/auth_models.dart';
import 'package:c_biz_docs_manager/core/money/money.dart';
import 'package:c_biz_docs_manager/core/network/page_result.dart';
import 'package:c_biz_docs_manager/features/settlements/data/settlement_repository.dart';
import 'package:c_biz_docs_manager/features/settlements/domain/settlement.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
// `Override` 在 Riverpod 3 里由 misc.dart 导出。
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

import '../../support/auth_fixtures.dart';
import '../../support/fake_auth_repository.dart';

/// 结算页面测试：列表渲染 + 详情审批按钮按权限裁剪 + 驳回必填备注。
///
/// 用真实 router + 假认证仓储：restore 后守卫落点由身份决定，
/// 再手动 navigate 到目标地址，保证页面拿到的 profile 是「真认证态」。
void main() {
  testWidgets('列表渲染结算单', (WidgetTester tester) async {
    _setScreenSize(tester, const Size(1280, 800));
    final repository = FakeSettlementRepository()
      ..listResult = <SettlementSummary>[_summary(9)];

    await _pump(tester, repository, '/settlements');

    expect(find.text('JS202609-0009'), findsOneWidget);
  });

  testWidgets('详情页：有 settlement.approve 权限显示通过/驳回按钮', (
    WidgetTester tester,
  ) async {
    _setScreenSize(tester, const Size(1280, 800));
    final repository = FakeSettlementRepository()
      ..detailResult = _detail(9, status: SettlementStatus.pending);

    await _pump(
      tester,
      repository,
      '/settlements/9',
      permissionCodes: const <String>['settlement.approve'],
    );

    expect(find.widgetWithText(FilledButton, '通过'), findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, '驳回'), findsOneWidget);
  });

  testWidgets('详情页：无 settlement.approve 权限不显示审批按钮', (
    WidgetTester tester,
  ) async {
    _setScreenSize(tester, const Size(1280, 800));
    final repository = FakeSettlementRepository()
      ..detailResult = _detail(9, status: SettlementStatus.pending);

    await _pump(tester, repository, '/settlements/9');

    expect(find.widgetWithText(FilledButton, '通过'), findsNothing);
    expect(find.widgetWithText(OutlinedButton, '驳回'), findsNothing);
  });

  testWidgets('已审批（终态）不显示审批按钮', (WidgetTester tester) async {
    _setScreenSize(tester, const Size(1280, 800));
    final repository = FakeSettlementRepository()
      ..detailResult = _detail(9, status: SettlementStatus.approved);

    await _pump(
      tester,
      repository,
      '/settlements/9',
      permissionCodes: const <String>['settlement.approve'],
    );

    expect(find.widgetWithText(FilledButton, '通过'), findsNothing);
    expect(find.text('审批通过'), findsWidgets);
  });

  testWidgets('驳回弹对话框，备注为空时本地拦下不发请求', (WidgetTester tester) async {
    _setScreenSize(tester, const Size(1280, 800));
    final repository = FakeSettlementRepository()
      ..detailResult = _detail(9, status: SettlementStatus.pending);

    await _pump(
      tester,
      repository,
      '/settlements/9',
      permissionCodes: const <String>['settlement.approve'],
    );

    await tester.tap(find.widgetWithText(OutlinedButton, '驳回'));
    await tester.pumpAndSettle();

    // 对话框里点「驳回」（备注为空），本地拦下、不发请求。
    await tester.tap(find.widgetWithText(FilledButton, '驳回').last);
    await tester.pumpAndSettle();

    expect(repository.rejectCalls, 0);
  });
}

/* ---------------------------------------------------------------- 夹具 */

void _setScreenSize(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

/// 搭真实 router + 假认证仓储，restore 后 navigate 到 [location]。
Future<void> _pump(
  WidgetTester tester,
  FakeSettlementRepository repository,
  String location, {
  List<String> permissionCodes = const <String>[],
}) async {
  final container = ProviderContainer(
    overrides: <Override>[
      authRepositoryProvider.overrideWithValue(
        FakeAuthRepository(
          session: memberSession(permissionCodes: permissionCodes),
        ),
      ),
      settlementRepositoryProvider.overrideWithValue(repository),
    ],
  );
  addTearDown(container.dispose);

  final router = container.read(routerProvider);
  addTearDown(router.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await container.read(authControllerProvider.notifier).restore();
  await tester.pumpAndSettle();
  router.go(location);
  await tester.pumpAndSettle();
}

/* ---------------------------------------------------------------- 假仓储 */

final class FakeSettlementRepository implements SettlementRepository {
  List<SettlementSummary>? listResult;
  SettlementDetail? detailResult;
  int rejectCalls = 0;

  @override
  Future<PageResult<SettlementSummary>> list(SettlementQuery query) {
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
  Future<SettlementDetail> approve(int settlementId, int version) =>
      Future<SettlementDetail>.value(
        detailResult ??
            _detail(settlementId, status: SettlementStatus.approved),
      );

  @override
  Future<SettlementDetail> reject(
    int settlementId,
    int version,
    String remark,
  ) {
    rejectCalls++;
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
