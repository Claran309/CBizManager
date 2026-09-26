import 'package:c_biz_docs_manager/core/auth/auth_controller.dart';
import 'package:c_biz_docs_manager/core/auth/auth_models.dart';
import 'package:c_biz_docs_manager/core/auth/auth_repository.dart';
import 'package:c_biz_docs_manager/core/auth/credential_store.dart';
import 'package:c_biz_docs_manager/core/error/app_failure.dart';
import 'package:c_biz_docs_manager/core/network/api_client.dart';
import 'package:c_biz_docs_manager/features/documents/data/document_repository.dart';
import 'package:c_biz_docs_manager/features/documents/domain/document.dart';
import 'package:c_biz_docs_manager/features/finance/data/finance_repository.dart';
import 'package:c_biz_docs_manager/features/finance/domain/finance.dart';
import 'package:c_biz_docs_manager/features/reports/data/report_repository.dart';
import 'package:c_biz_docs_manager/features/reports/domain/report.dart';
import 'package:c_biz_docs_manager/features/settlements/data/settlement_repository.dart';
import 'package:c_biz_docs_manager/features/settlements/domain/settlement.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_backend.dart';

/// Task 11：单据 → 结算 → 财务 → 报表的纵向闭环。
///
/// 这里驱动的是**真实的 Repository**（`DioDocumentRepository` 等）→ 真实 Dio →
/// 真实鉴权拦截器 → [FakeBackend] 状态机 → 再原路 `fromJson` 严格解析。
/// 与生产链路只差「网络那头」换成了内存状态机，所以能验证跨模块的状态真的会流动：
///
/// - 结算引用源单据后，同一单据不能被第二张有效结算单再引用；
/// - 财务登记后，结清视图的「未付 / 未收」随已登记金额下降；
/// - 累计登记超过单据总额被拒；
/// - 这些金额最终体现在看板口径里。
void main() {
  late FakeBackend backend;
  late DioDocumentRepository inboundRepo;
  late DioDocumentRepository outboundRepo;
  late DioSettlementRepository settlementRepo;
  late DioFinanceRepository paymentRepo;
  late DioFinanceRepository receiptRepo;
  late DioReportRepository reportRepo;

  setUp(() async {
    backend = FakeBackend()..seedGroupWithOwner(ownerUsername: 'owner');

    final accessTokens = InMemoryAccessTokenStore();
    final credentials = _MemoryCredentialStore();
    final invalidator = AuthSessionInvalidator();
    final dio = Dio(BaseOptions(baseUrl: 'https://api.example.test'))
      ..httpClientAdapter = backend;

    late final AuthRepository authRepository;
    ApiClient(
      dio: dio,
      accessTokens: accessTokens,
      refreshSession: () => authRepository.restore(),
      clearSession: () async {
        accessTokens.clear();
        await credentials.clear();
        invalidator.invalidate();
      },
    );
    authRepository = DefaultAuthRepository(
      remote: DioAuthRemoteDataSource(dio),
      credentials: credentials,
      accessTokens: accessTokens,
      platform: AuthPlatform.native,
    );
    // 登录以拿到令牌（拦截器会把它注入每个业务请求）。
    await authRepository.login('owner', 'owner-pass');

    inboundRepo = DioDocumentRepository(dio, DocumentKind.inbound);
    outboundRepo = DioDocumentRepository(dio, DocumentKind.outbound);
    settlementRepo = DioSettlementRepository(dio);
    paymentRepo = DioFinanceRepository(dio, FinanceKind.payment);
    receiptRepo = DioFinanceRepository(dio, FinanceKind.receipt);
    reportRepo = DioReportRepository(dio);
  });

  test('owner 建单 → 结算审批 → 登记收付款 → 结清与看板口径联动', () async {
    // 1. 建入库单（10 万）并提交。
    final inbound = await inboundRepo.create(
      _draft('inbound', quantity: '10.000', unitPrice: '10000.0000'),
    );
    final inboundSubmitted = await inboundRepo.submit(inbound.documentId, 1);
    expect(inboundSubmitted.status, DocumentStatus.submitted);
    expect(inboundSubmitted.totalAmount.format(), '100000.00');
    expect(inboundSubmitted.documentNo, startsWith('RK20260922-'));

    // 2. 建出库单（12 万）并提交。
    final outbound = await outboundRepo.create(
      _draft('outbound', quantity: '12.000', unitPrice: '10000.0000'),
    );
    await outboundRepo.submit(outbound.documentId, 1);

    // 3. 申请结算：引用两张源单据。
    final settlement = await settlementRepo.create(
      SettlementDraft(
        sourceDocumentIds: <int>[inbound.documentId, outbound.documentId],
        remark: '本月结算',
      ),
    );
    expect(settlement.status, SettlementStatus.pending);
    expect(settlement.inboundTotal.format(), '100000.00');
    expect(settlement.outboundTotal.format(), '120000.00');
    expect(settlement.grossProfit.format(), '20000.00');
    expect(settlement.sources, hasLength(2));

    // 4. 同一张源单据不能再被第二张有效结算单引用。
    await expectLater(
      settlementRepo.create(
        SettlementDraft(sourceDocumentIds: <int>[inbound.documentId]),
      ),
      throwsA(isA<ConflictFailure>()),
    );

    // 5. 审批通过。
    final approved = await settlementRepo.approve(settlement.settlementId, 1);
    expect(approved.status, SettlementStatus.approved);
    expect(approved.decidedBy?.username, 'owner');

    // 6. 登记部分付款（3 万）：结清视图的「未付」从 10 万降到 7 万。
    final beforePayment = await paymentRepo.statement(inbound.documentId);
    expect(beforePayment.unpaidAmount.format(), '100000.00');

    await paymentRepo.create(
      FinanceRecordDraft(
        documentId: inbound.documentId,
        amount: '30000.00',
        occurredOn: '2026-09-22',
        method: FinanceMethod.privateCard,
        cardTail: '1234',
      ),
    );
    final afterPayment = await paymentRepo.statement(inbound.documentId);
    expect(afterPayment.paidAmount.format(), '30000.00');
    expect(afterPayment.unpaidAmount.format(), '70000.00');
    expect(afterPayment.invoiceStatus, InvoiceStatus.none);

    // 7. 登记收款（4 万）：出库单「未收」从 12 万降到 8 万。
    await receiptRepo.create(
      FinanceRecordDraft(
        documentId: outbound.documentId,
        amount: '40000.00',
        occurredOn: '2026-09-22',
        method: FinanceMethod.transfer,
      ),
    );
    final outboundStatement = await receiptRepo.statement(outbound.documentId);
    expect(outboundStatement.receivedAmount.format(), '40000.00');
    expect(outboundStatement.unreceivedAmount.format(), '80000.00');

    // 8. 累计登记超过单据总额被拒。
    await expectLater(
      paymentRepo.create(
        FinanceRecordDraft(
          documentId: inbound.documentId,
          amount: '80000.00',
          occurredOn: '2026-09-22',
        ),
      ),
      throwsA(isA<AppFailure>()),
    );

    // 9. 看板口径：入库 10 万 / 出库 12 万 / 毛利 2 万 / 已付 3 万 / 已收 4 万。
    final overview = await reportRepo.overview(
      const PeriodQuery(period: '2026-09'),
    );
    expect(overview.inboundAmount.format(), '100000.00');
    expect(overview.outboundAmount.format(), '120000.00');
    expect(overview.grossProfit.format(), '20000.00');
    expect(overview.paidAmount.format(), '30000.00');
    expect(overview.receivedAmount.format(), '40000.00');
    expect(overview.inboundDocumentCount, 1);
    expect(overview.outboundDocumentCount, 1);
    expect(overview.period, '2026-09');
  });

  test('驳回释放源单据，可以重新申请结算', () async {
    final inbound = await inboundRepo.create(
      _draft('inbound', quantity: '1.000', unitPrice: '100.0000'),
    );
    await inboundRepo.submit(inbound.documentId, 1);

    final first = await settlementRepo.create(
      SettlementDraft(sourceDocumentIds: <int>[inbound.documentId]),
    );
    await settlementRepo.reject(first.settlementId, 1, '金额不符');

    // 被驳回后源单据释放，可以重新申请。
    final second = await settlementRepo.create(
      SettlementDraft(sourceDocumentIds: <int>[inbound.documentId]),
    );
    expect(second.status, SettlementStatus.pending);
    expect(second.settlementId, isNot(first.settlementId));
  });
}

/// 一张最小可用的单据草稿（单个往来单位 + 单条明细）。
DocumentDraft _draft(
  String kind, {
  required String quantity,
  required String unitPrice,
}) => DocumentDraft(
  status: DocumentStatus.draft,
  businessDate: '2026-09-22',
  shippingUnit: kind == 'outbound' ? '吨' : null,
  saleAmountType: kind == 'outbound' ? SaleAmountType.vatSpecial : null,
  parties: <PartyDraft>[
    PartyDraft(
      partyName: kind == 'outbound' ? '华东客户' : '华东钢贸',
      items: <ItemDraft>[
        ItemDraft(
          productName: '螺纹钢',
          productModel: 'HRB400',
          unit: '吨',
          quantity: quantity,
          unitPrice: unitPrice,
          priceTaxMode: PriceTaxMode.taxIncluded,
        ),
      ],
    ),
  ],
);

/// 内存凭据库：集成测试不走真 secure storage。
final class _MemoryCredentialStore implements CredentialStore {
  String? _token;

  @override
  Future<String?> readRefreshToken() async => _token;

  @override
  Future<void> writeRefreshToken(String token) async => _token = token;

  @override
  Future<void> clear() async => _token = null;
}
