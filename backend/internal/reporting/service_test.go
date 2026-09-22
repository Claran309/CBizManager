package reporting

import (
	"context"
	"errors"
	"fmt"
	"reflect"
	"strings"
	"sync"
	"testing"
	"time"

	"CBizDocsManager/backend/internal/authorization"
	"CBizDocsManager/backend/internal/document"
	"CBizDocsManager/backend/internal/identity"
	"CBizDocsManager/backend/pkg/apperror"
	"CBizDocsManager/backend/pkg/money"
)

// fixedNow 固定「当前时间」，让「缺省查当月」与快照创建时间在断言里可预期。
var fixedNow = time.Date(2026, time.September, 22, 10, 30, 0, 0, time.UTC)

// 测试用的固定标识：组 3，业务员 7 与 8。
const (
	testGroupID = uint64(3)
	testUserID  = uint64(7)
	testOtherID = uint64(8)
)

/* ------------------------------------------------------------------ 测试桩 */

// fakeAuthorizer 用一张授权表模拟权限引擎；未列出的权限码一律拒绝。
type fakeAuthorizer struct{ granted map[authorization.Code]bool }

func (a fakeAuthorizer) Require(_ context.Context, _ identity.Principal, _ uint64, code authorization.Code) error {
	if a.granted[code] {
		return nil
	}
	return apperror.ErrForbidden
}

// auditEntry 记录一次审计写入，用于断言动作与摘要口径。
type auditEntry struct {
	action  string
	summary string
}

// fakeRepository 用内存结构模拟汇总统计仓储，便于在无数据库环境下覆盖业务规则。
type fakeRepository struct {
	mu sync.Mutex

	settlements   []DocumentSettlement
	suppliers     int64
	customers     int64
	items         map[document.Kind]ItemPage
	businessUsers []BusinessUserTotals
	users         map[uint64]identity.UserSummary
	snapshots     map[uint64]Snapshot
	nextID        uint64
	audits        []auditEntry

	settlementsErr   error
	partiesErr       error
	itemsErr         error
	businessUserErr  error
	createErr        error
	listErr          error
	findErr          error
	usersErr         error

	settlementsCalls int
	lastAggregate    AggregateQuery
	lastKind         document.Kind
	lastItemQuery    ItemQuery
	lastSnapshotQ    SnapshotQuery
	lastCreateInput  CreateSnapshotInput
}

func newFakeRepository() *fakeRepository {
	return &fakeRepository{
		items:     make(map[document.Kind]ItemPage),
		users:     make(map[uint64]identity.UserSummary),
		snapshots: make(map[uint64]Snapshot),
		nextID:    1,
	}
}

func (r *fakeRepository) seedUser(userID uint64, displayName string) {
	r.users[userID] = identity.UserSummary{
		ID: userID, Username: fmt.Sprintf("user%d", userID), DisplayName: displayName,
		AccountType: identity.AccountTypeMember,
	}
}

// seedSnapshot 直接写入一张快照，用于构造「历史快照」这类不便通过 Generate 得到的场景。
func (r *fakeRepository) seedSnapshot(snapshot Snapshot) Snapshot {
	r.mu.Lock()
	defer r.mu.Unlock()
	snapshot.ID = r.nextID
	r.nextID++
	r.snapshots[snapshot.ID] = snapshot
	return snapshot
}

func (r *fakeRepository) LoadSettlements(_ context.Context, _ uint64, query AggregateQuery) ([]DocumentSettlement, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.settlementsCalls++
	r.lastAggregate = query
	if r.settlementsErr != nil {
		return nil, r.settlementsErr
	}
	return append([]DocumentSettlement(nil), r.settlements...), nil
}

func (r *fakeRepository) CountParties(_ context.Context, _ uint64, query AggregateQuery) (int64, int64, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.lastAggregate = query
	if r.partiesErr != nil {
		return 0, 0, r.partiesErr
	}
	return r.suppliers, r.customers, nil
}

func (r *fakeRepository) LoadItems(_ context.Context, _ uint64, kind document.Kind, query ItemQuery) (ItemPage, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.lastKind = kind
	r.lastItemQuery = query
	if r.itemsErr != nil {
		return ItemPage{}, r.itemsErr
	}
	page := r.items[kind]
	page.Page, page.PageSize = query.Page, query.PageSize
	return page, nil
}

func (r *fakeRepository) LoadBusinessUserTotals(_ context.Context, _ uint64, query AggregateQuery) ([]BusinessUserTotals, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.lastAggregate = query
	if r.businessUserErr != nil {
		return nil, r.businessUserErr
	}
	return append([]BusinessUserTotals(nil), r.businessUsers...), nil
}

func (r *fakeRepository) CreateSnapshots(_ context.Context, input CreateSnapshotInput) ([]Snapshot, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.lastCreateInput = input
	if r.createErr != nil {
		return nil, r.createErr
	}
	created := make([]Snapshot, 0, len(input.Candidates))
	batchNo := ""
	for index, candidate := range input.Candidates {
		id := r.nextID
		r.nextID++
		snapshotNo := fmt.Sprintf("ZJS202609-%04d", index+1)
		if index == 0 {
			batchNo = snapshotNo
		}
		snapshot := Snapshot{
			ID: id, GroupID: input.GroupID, SnapshotNo: snapshotNo, BatchNo: batchNo,
			Scope: candidate.Scope, PeriodStart: input.PeriodStart, PeriodEnd: input.PeriodEnd,
			BusinessUserID: candidate.BusinessUserID, BusinessUserName: candidate.BusinessUserName,
			InboundAmount: candidate.InboundAmount, OutboundAmount: candidate.OutboundAmount,
			GrossProfit: candidate.GrossProfit, GrossMarginPPM: candidate.GrossMarginPPM,
			VATSpecialAmount: candidate.VATSpecialAmount, VATGeneralAmount: candidate.VATGeneralAmount,
			NoInvoiceAmount: candidate.NoInvoiceAmount,
			DocumentCount:   candidate.DocumentCount, Remark: candidate.Remark,
			CreatedBy: input.OperatorUserID, CreatedAt: input.Now,
		}
		r.snapshots[id] = snapshot
		created = append(created, snapshot)
		r.audits = append(r.audits, auditEntry{
			action:  "report.summary_settlement.generated",
			summary: fmt.Sprintf("总结算单 %s %s 生成", snapshotNo, candidate.Scope.Label()),
		})
	}
	return created, nil
}

func (r *fakeRepository) ListSnapshots(_ context.Context, _ uint64, query SnapshotQuery) (SnapshotPage, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.lastSnapshotQ = query
	if r.listErr != nil {
		return SnapshotPage{}, r.listErr
	}
	items := make([]Snapshot, 0, len(r.snapshots))
	for _, snapshot := range r.snapshots {
		if query.Scope != nil && snapshot.Scope != *query.Scope {
			continue
		}
		if query.BusinessUserID != nil && (snapshot.BusinessUserID == nil || *snapshot.BusinessUserID != *query.BusinessUserID) {
			continue
		}
		if query.PeriodStart != nil && snapshot.PeriodStart.Before(*query.PeriodStart) {
			continue
		}
		if query.PeriodEnd != nil && !snapshot.PeriodStart.Before(*query.PeriodEnd) {
			continue
		}
		items = append(items, snapshot)
	}
	return SnapshotPage{Items: items, Page: query.Page, PageSize: query.PageSize, Total: int64(len(items))}, nil
}

func (r *fakeRepository) FindSnapshot(_ context.Context, _ uint64, snapshotID uint64) (Snapshot, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.findErr != nil {
		return Snapshot{}, r.findErr
	}
	snapshot, ok := r.snapshots[snapshotID]
	if !ok {
		return Snapshot{}, ErrSnapshotNotFound
	}
	return snapshot, nil
}

func (r *fakeRepository) LoadUsers(_ context.Context, ids []uint64) (map[uint64]identity.UserSummary, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.usersErr != nil {
		return nil, r.usersErr
	}
	result := make(map[uint64]identity.UserSummary, len(ids))
	for _, id := range ids {
		if user, ok := r.users[id]; ok {
			result[id] = user
		}
	}
	return result, nil
}

/* ------------------------------------------------------------------ 辅助 */

func ownerPrincipal(groupID, userID uint64) identity.Principal {
	return identity.Principal{
		UserID: userID, GroupID: &groupID, GroupName: "钢铁一组",
		AccountType: identity.AccountTypeGroupOwner, MemberType: "owner", SessionID: 1,
	}
}

func memberPrincipal(groupID, userID uint64) identity.Principal {
	return identity.Principal{
		UserID: userID, GroupID: &groupID, GroupName: "钢铁一组",
		AccountType: identity.AccountTypeMember, MemberType: "member", SessionID: 2,
	}
}

func newTestService(repo *fakeRepository, authorizer authorization.Authorizer) *Service {
	service := NewService(repo, authorizer)
	service.now = func() time.Time { return fixedNow }
	return service
}

// ownerService 用主账号身份（拥有组内全部权限）驱动服务。
func ownerService(repo *fakeRepository) *Service {
	return newTestService(repo, fakeAuthorizer{granted: map[authorization.Code]bool{}})
}

// memberService 只授予指定权限，模拟子账号被主账号精确授权的情形。
func memberService(repo *fakeRepository, codes ...authorization.Code) *Service {
	granted := make(map[authorization.Code]bool, len(codes))
	for _, code := range codes {
		granted[code] = true
	}
	return newTestService(repo, fakeAuthorizer{granted: granted})
}

// wantAppError 断言错误携带指定业务错误码。
func wantAppError(t *testing.T, err error, want error) {
	t.Helper()
	var got *apperror.Error
	if !errors.As(err, &got) {
		t.Fatalf("error = %v, want app error %v", err, want)
	}
	var expected *apperror.Error
	if !errors.As(want, &expected) {
		t.Fatalf("want 参数不是业务错误: %v", want)
	}
	if got.Code != expected.Code {
		t.Fatalf("error code = %s, want %s", got.Code, expected.Code)
	}
}

func inboundSettlement(total, paid, invoiced money.Amount) DocumentSettlement {
	return DocumentSettlement{
		Kind: document.KindInbound, TotalAmount: total, Paid: paid, Invoiced: invoiced,
	}
}

func outboundSettlement(total, received money.Amount, saleAmountType document.SaleAmountType) DocumentSettlement {
	return DocumentSettlement{
		Kind: document.KindOutbound, TotalAmount: total, Received: received, SaleAmountType: &saleAmountType,
	}
}

/* ------------------------------------------------------------------ 看板 */

func TestOverviewAggregatesPeriodTotals(t *testing.T) {
	repo := newFakeRepository()
	repo.suppliers, repo.customers = 3, 4
	repo.settlements = []DocumentSettlement{
		// 入库单：一张全额付清并开满票，一张只付了一部分且完全未开票。
		inboundSettlement(money.AmountFromYuan(100000), money.AmountFromYuan(100000), money.AmountFromYuan(100000)),
		inboundSettlement(money.AmountFromYuan(50000), money.AmountFromYuan(30000), 0),
		// 出库单：合计 173520，已收 80000。
		outboundSettlement(money.AmountFromYuan(113200), money.AmountFromYuan(80000), document.SaleAmountVATSpecial),
		outboundSettlement(money.AmountFromYuan(60320), 0, document.SaleAmountVATGeneral),
	}

	result, err := ownerService(repo).Overview(context.Background(), ownerPrincipal(testGroupID, testUserID), PeriodQuery{Period: "2026-09"})
	if err != nil {
		t.Fatalf("Overview error = %v", err)
	}

	if result.Period != "2026-09" {
		t.Fatalf("period = %q, want 2026-09", result.Period)
	}
	if result.InboundDocumentCount != 2 || result.OutboundDocumentCount != 2 {
		t.Fatalf("document counts = %d/%d, want 2/2", result.InboundDocumentCount, result.OutboundDocumentCount)
	}
	if result.InboundAmount != money.AmountFromYuan(150000) {
		t.Fatalf("inbound amount = %s, want 150000.00", result.InboundAmount)
	}
	if result.OutboundAmount != money.AmountFromYuan(173520) {
		t.Fatalf("outbound amount = %s, want 173520.00", result.OutboundAmount)
	}
	if result.PaidAmount != money.AmountFromYuan(130000) {
		t.Fatalf("paid = %s, want 130000.00", result.PaidAmount)
	}
	if result.UnpaidAmount != money.AmountFromYuan(20000) {
		t.Fatalf("unpaid = %s, want 20000.00", result.UnpaidAmount)
	}
	if result.UnpaidDocumentCount != 1 {
		t.Fatalf("unpaid document count = %d, want 1", result.UnpaidDocumentCount)
	}
	if result.InvoicedAmount != money.AmountFromYuan(100000) || result.UninvoicedAmount != money.AmountFromYuan(50000) {
		t.Fatalf("invoiced/uninvoiced = %s/%s, want 100000.00/50000.00", result.InvoicedAmount, result.UninvoicedAmount)
	}
	if result.UninvoicedDocumentCount != 1 {
		t.Fatalf("uninvoiced document count = %d, want 1", result.UninvoicedDocumentCount)
	}
	if result.ReceivedAmount != money.AmountFromYuan(80000) || result.UnreceivedAmount != money.AmountFromYuan(93520) {
		t.Fatalf("received/unreceived = %s/%s, want 80000.00/93520.00", result.ReceivedAmount, result.UnreceivedAmount)
	}
	if result.UnreceivedDocumentCount != 2 {
		t.Fatalf("unreceived document count = %d, want 2", result.UnreceivedDocumentCount)
	}
	// 毛利润 = 出库 − 入库 = 173520 − 150000 = 23520；毛利率 = 23520 / 173520 = 13.5546...% → 13.55%
	if result.GrossProfit != money.AmountFromYuan(23520) {
		t.Fatalf("gross profit = %s, want 23520.00", result.GrossProfit)
	}
	if result.GrossMarginPercent != "13.55" {
		t.Fatalf("gross margin = %q, want 13.55", result.GrossMarginPercent)
	}
	if result.GrossMarginPPM != 135546 {
		t.Fatalf("gross margin ppm = %d, want 135546", result.GrossMarginPPM)
	}
	if result.SupplierCount != 3 || result.CustomerCount != 4 {
		t.Fatalf("supplier/customer = %d/%d, want 3/4", result.SupplierCount, result.CustomerCount)
	}
	if result.UnpaidAmountUpper == "" || result.GrossProfitUpper == "" {
		t.Fatalf("大写金额不应为空: %+v", result)
	}

	// 三类销售金额顺序固定为 Y-1 / y-N / N，缺的补 0。
	if len(result.SaleAmountTypes) != 3 {
		t.Fatalf("sale amount types = %d, want 3", len(result.SaleAmountTypes))
	}
	wantTypes := []document.SaleAmountType{
		document.SaleAmountVATSpecial, document.SaleAmountVATGeneral, document.SaleAmountNoInvoice,
	}
	for index, want := range wantTypes {
		if result.SaleAmountTypes[index].SaleAmountType != want {
			t.Fatalf("sale amount type[%d] = %s, want %s", index, result.SaleAmountTypes[index].SaleAmountType, want)
		}
	}
	if result.SaleAmountTypes[0].Amount != money.AmountFromYuan(113200) {
		t.Fatalf("Y-1 amount = %s, want 113200.00", result.SaleAmountTypes[0].Amount)
	}
	if result.SaleAmountTypes[1].Amount != money.AmountFromYuan(60320) {
		t.Fatalf("y-N amount = %s, want 60320.00", result.SaleAmountTypes[1].Amount)
	}
	if !result.SaleAmountTypes[2].Amount.IsZero() {
		t.Fatalf("N amount = %s, want 0.00", result.SaleAmountTypes[2].Amount)
	}
	// 113200 / 173520 = 65.239...% → 65.24%
	if result.SaleAmountTypes[0].SharePercent != "65.24" {
		t.Fatalf("Y-1 share = %q, want 65.24", result.SaleAmountTypes[0].SharePercent)
	}
}

// TestUnpaidDocumentCountNotCancelledByOverpayment 锁定一个容易写错的口径：
// 「未付清单据数」必须逐单比较，不能由「总额 − 已付」推导。
// 一张单多付、另一张单少付时，总额相减会正好抵消，把「有 1 张单没付清」悄悄藏起来。
func TestUnpaidDocumentCountNotCancelledByOverpayment(t *testing.T) {
	repo := newFakeRepository()
	repo.settlements = []DocumentSettlement{
		inboundSettlement(money.AmountFromYuan(10000), money.AmountFromYuan(10000), 0),
		inboundSettlement(money.AmountFromYuan(10000), money.AmountFromYuan(10000), 0),
	}

	totals := newPeriodTotals(repo.settlements)
	if totals.UnpaidDocuments != 0 {
		t.Fatalf("全额付清时未付清单据数 = %d, want 0", totals.UnpaidDocuments)
	}

	// 换成一多一少：总额相同、已付合计相同，但确实有一张单没付清。
	repo.settlements = []DocumentSettlement{
		inboundSettlement(money.AmountFromYuan(10000), money.AmountFromYuan(15000), 0),
		inboundSettlement(money.AmountFromYuan(10000), money.AmountFromYuan(5000), 0),
	}
	totals = newPeriodTotals(repo.settlements)
	if totals.UnpaidDocuments != 1 {
		t.Fatalf("一多一少时未付清单据数 = %d, want 1", totals.UnpaidDocuments)
	}
	if !totals.Unpaid().IsZero() {
		t.Fatalf("未付款合计 = %s, want 0.00（合计确实相抵，但这不能掩盖那张没付清的单）", totals.Unpaid())
	}
}

func TestOverviewDefaultsToCurrentMonthAndRejectsBadPeriod(t *testing.T) {
	repo := newFakeRepository()
	service := ownerService(repo)

	result, err := service.Overview(context.Background(), ownerPrincipal(testGroupID, testUserID), PeriodQuery{})
	if err != nil {
		t.Fatalf("Overview error = %v", err)
	}
	if result.Period != "2026-09" {
		t.Fatalf("缺省 period = %q, want 2026-09（固定时钟所在月份）", result.Period)
	}
	wantStart := time.Date(2026, time.September, 1, 0, 0, 0, 0, time.UTC)
	wantEnd := time.Date(2026, time.October, 1, 0, 0, 0, 0, time.UTC)
	if !repo.lastAggregate.PeriodStart.Equal(wantStart) || !repo.lastAggregate.PeriodEnd.Equal(wantEnd) {
		t.Fatalf("聚合区间 = %s~%s, want %s~%s",
			repo.lastAggregate.PeriodStart, repo.lastAggregate.PeriodEnd, wantStart, wantEnd)
	}

	for _, bad := range []string{"2026-13", "2026/9/1", "202609", "abc"} {
		if _, err := service.Overview(context.Background(), ownerPrincipal(testGroupID, testUserID), PeriodQuery{Period: bad}); err == nil {
			t.Fatalf("period = %q 应被拒绝", bad)
		} else {
			wantAppError(t, err, apperror.ErrValidationFailed)
		}
	}
}

func TestOverviewBusinessUserFilterIsForwarded(t *testing.T) {
	repo := newFakeRepository()
	if _, err := ownerService(repo).Overview(context.Background(), ownerPrincipal(testGroupID, testUserID),
		PeriodQuery{Period: "2026-09", BusinessUserID: testOtherID}); err != nil {
		t.Fatalf("Overview error = %v", err)
	}
	if repo.lastAggregate.BusinessUserID != testOtherID {
		t.Fatalf("业务员筛选 = %d, want %d", repo.lastAggregate.BusinessUserID, testOtherID)
	}
}

/* ------------------------------------------------------------------ 权限 */

func TestResolveScopePermissionMatrix(t *testing.T) {
	repo := newFakeRepository()
	repo.settlements = []DocumentSettlement{inboundSettlement(money.AmountFromYuan(100), 0, 0)}
	query := PeriodQuery{Period: "2026-09"}

	// 主账号默认拥有汇总权限，不需要任何显式授权。
	if _, err := ownerService(repo).Overview(context.Background(), ownerPrincipal(testGroupID, testUserID), query); err != nil {
		t.Fatalf("主账号应可查看汇总: %v", err)
	}
	// 子账号被授予 report.view 后可查看。
	if _, err := memberService(repo, authorization.PermissionReportView).
		Overview(context.Background(), memberPrincipal(testGroupID, testOtherID), query); err != nil {
		t.Fatalf("已授权子账号应可查看汇总: %v", err)
	}
	// 子账号未授权时明确拒绝（而不是返回空报表）。
	_, err := memberService(repo).Overview(context.Background(), memberPrincipal(testGroupID, testOtherID), query)
	wantAppError(t, err, apperror.ErrForbidden)

	// 平台管理员没有业务组，不能看任何组的汇总。
	platformAdmin := identity.Principal{UserID: 1, AccountType: identity.AccountTypePlatformAdmin, SessionID: 3}
	_, err = ownerService(repo).Overview(context.Background(), platformAdmin, query)
	wantAppError(t, err, apperror.ErrForbidden)

	// 无组身份（GroupID 为空）。
	noGroup := identity.Principal{UserID: testUserID, AccountType: identity.AccountTypeMember, MemberType: "member", SessionID: 4}
	_, err = ownerService(repo).Overview(context.Background(), noGroup, query)
	wantAppError(t, err, apperror.ErrForbidden)

	// 未修改初始密码。
	mustChange := ownerPrincipal(testGroupID, testUserID)
	mustChange.MustChangePassword = true
	_, err = ownerService(repo).Overview(context.Background(), mustChange, query)
	wantAppError(t, err, apperror.ErrAuthPasswordChangeRequired)
}

/* ------------------------------------------------------------------ 入库 / 出库统计 */

func TestInboundStatsSeparatesDocumentAndItemLevels(t *testing.T) {
	repo := newFakeRepository()
	repo.suppliers = 2
	repo.settlements = []DocumentSettlement{
		inboundSettlement(money.AmountFromYuan(100000), money.AmountFromYuan(80000), money.AmountFromYuan(100000)),
	}
	repo.items[document.KindInbound] = ItemPage{
		Items: []ItemTotals{
			{PartyName: "鑫源钢贸", ProductName: "螺纹钢", Quantity: money.Quantity(17050), Amount: money.AmountFromYuan(72000)},
			{PartyName: "昌盛金属", ProductName: "热轧卷板", Quantity: money.Quantity(3000), Amount: money.AmountFromYuan(28000)},
		},
		Total: 2,
	}

	result, err := ownerService(repo).InboundStats(context.Background(), ownerPrincipal(testGroupID, testUserID), ItemStatsQuery{Period: "2026-09"})
	if err != nil {
		t.Fatalf("InboundStats error = %v", err)
	}
	if result.DocumentCount != 1 || result.AmountTotal != money.AmountFromYuan(100000) {
		t.Fatalf("documentCount/amountTotal = %d/%s, want 1/100000.00", result.DocumentCount, result.AmountTotal)
	}
	if result.PaidAmount != money.AmountFromYuan(80000) || result.UnpaidAmount != money.AmountFromYuan(20000) {
		t.Fatalf("paid/unpaid = %s/%s, want 80000.00/20000.00", result.PaidAmount, result.UnpaidAmount)
	}
	if result.InvoicedAmount != money.AmountFromYuan(100000) || !result.UninvoicedAmount.IsZero() {
		t.Fatalf("invoiced/uninvoiced = %s/%s, want 100000.00/0.00", result.InvoicedAmount, result.UninvoicedAmount)
	}
	if result.UnpaidDocumentCount != 1 || result.UninvoicedDocumentCount != 0 {
		t.Fatalf("未付清/未开满 单据数 = %d/%d, want 1/0", result.UnpaidDocumentCount, result.UninvoicedDocumentCount)
	}
	if result.SupplierCount != 2 {
		t.Fatalf("进项公司数 = %d, want 2", result.SupplierCount)
	}
	if len(result.Items) != 2 || result.Total != 2 {
		t.Fatalf("明细行 = %d / total=%d, want 2/2", len(result.Items), result.Total)
	}
	if result.Items[0].AmountUpper == "" {
		t.Fatalf("明细行应带大写金额")
	}
	if repo.lastKind != document.KindInbound {
		t.Fatalf("仓储 kind = %s, want inbound", repo.lastKind)
	}
}

// TestItemDataDoesNotExposeUnallocatableSettlementFields 用反射把一条设计约束钉在测试里：
// 付款 / 收款记录挂在单据上，明细行无法推导「这一行的已付 / 未付」，
// 因此 ItemData 一旦被加上这类字段，就说明有人准备把单据级金额摊到明细行去做假精确。
func TestItemDataDoesNotExposeUnallocatableSettlementFields(t *testing.T) {
	forbidden := []string{"paid", "unpaid", "invoiced", "uninvoiced", "received", "unreceived"}
	itemType := reflect.TypeOf(ItemData{})
	for index := 0; index < itemType.NumField(); index++ {
		field := itemType.Field(index)
		tag := field.Tag.Get("json")
		for _, word := range forbidden {
			if strings.Contains(tag, word) {
				t.Fatalf("ItemData 不应包含字段 %s（json tag %q）：付款 / 收款无法按明细分摊", field.Name, tag)
			}
		}
	}
}

func TestOutboundStatsIncludesSaleAmountTypeBreakdown(t *testing.T) {
	repo := newFakeRepository()
	repo.settlements = []DocumentSettlement{
		outboundSettlement(money.AmountFromYuan(113200), money.AmountFromYuan(80000), document.SaleAmountVATSpecial),
		outboundSettlement(money.AmountFromYuan(37440), 0, document.SaleAmountVATGeneral),
		outboundSettlement(money.AmountFromYuan(22880), money.AmountFromYuan(22880), document.SaleAmountNoInvoice),
	}
	repo.customers = 4

	result, err := ownerService(repo).OutboundStats(context.Background(), ownerPrincipal(testGroupID, testUserID), ItemStatsQuery{Period: "2026-09"})
	if err != nil {
		t.Fatalf("OutboundStats error = %v", err)
	}
	if result.AmountTotal != money.AmountFromYuan(173520) {
		t.Fatalf("出库合计 = %s, want 173520.00", result.AmountTotal)
	}
	if result.ReceivedAmount != money.AmountFromYuan(102880) || result.UnreceivedAmount != money.AmountFromYuan(70640) {
		t.Fatalf("已收/未收 = %s/%s, want 102880.00/70640.00", result.ReceivedAmount, result.UnreceivedAmount)
	}
	if result.UnreceivedDocumentCount != 2 {
		t.Fatalf("未收清单据数 = %d, want 2", result.UnreceivedDocumentCount)
	}
	if result.CustomerCount != 4 {
		t.Fatalf("客户数 = %d, want 4", result.CustomerCount)
	}
	wantAmounts := []money.Amount{
		money.AmountFromYuan(113200), money.AmountFromYuan(37440), money.AmountFromYuan(22880),
	}
	for index, want := range wantAmounts {
		if result.SaleAmountTypes[index].Amount != want {
			t.Fatalf("销售金额分项[%d] = %s, want %s", index, result.SaleAmountTypes[index].Amount, want)
		}
	}
	if result.SaleAmountTypes[0].SharePercent != "65.24" {
		t.Fatalf("Y-1 占比 = %q, want 65.24", result.SaleAmountTypes[0].SharePercent)
	}
	if repo.lastKind != document.KindOutbound {
		t.Fatalf("仓储 kind = %s, want outbound", repo.lastKind)
	}
}

func TestItemStatsNormalizesFiltersAndPagination(t *testing.T) {
	repo := newFakeRepository()
	service := ownerService(repo)

	if _, err := service.InboundStats(context.Background(), ownerPrincipal(testGroupID, testUserID), ItemStatsQuery{
		Period: "2026-09", PartyName: "  鑫源   钢贸 ", ProductName: "螺纹钢", ProductModel: "HRB400",
		Page: 0, PageSize: 0,
	}); err != nil {
		t.Fatalf("InboundStats error = %v", err)
	}
	if repo.lastItemQuery.PartyKeyword != "鑫源 钢贸" {
		t.Fatalf("进项公司关键词 = %q, want %q", repo.lastItemQuery.PartyKeyword, "鑫源 钢贸")
	}
	if repo.lastItemQuery.Page != 1 || repo.lastItemQuery.PageSize != defaultPageSize {
		t.Fatalf("分页缺省 = %d/%d, want 1/%d", repo.lastItemQuery.Page, repo.lastItemQuery.PageSize, defaultPageSize)
	}
	if repo.lastItemQuery.ProductKeyword != "螺纹钢" || repo.lastItemQuery.ModelKeyword != "HRB400" {
		t.Fatalf("品名/型号关键词 = %q/%q", repo.lastItemQuery.ProductKeyword, repo.lastItemQuery.ModelKeyword)
	}

	// page_size 超限与超长关键词都应被拒绝，而不是被静默截断。
	if _, err := service.InboundStats(context.Background(), ownerPrincipal(testGroupID, testUserID),
		ItemStatsQuery{Period: "2026-09", PageSize: maxPageSize + 1}); err == nil {
		t.Fatalf("page_size 超限应被拒绝")
	} else {
		wantAppError(t, err, apperror.ErrValidationFailed)
	}
	if _, err := service.OutboundStats(context.Background(), ownerPrincipal(testGroupID, testUserID),
		ItemStatsQuery{Period: "2026-09", ProductName: strings.Repeat("螺", maxKeywordLength+1)}); err == nil {
		t.Fatalf("超长关键词应被拒绝")
	} else {
		wantAppError(t, err, apperror.ErrValidationFailed)
	}
}

/* ------------------------------------------------------------------ 业务员利润 */

func TestBusinessUsersReportAggregatesRowsAndSummary(t *testing.T) {
	repo := newFakeRepository()
	repo.seedUser(testUserID, "王业务")
	repo.seedUser(testOtherID, "赵业务")
	repo.businessUsers = []BusinessUserTotals{
		{BusinessUserID: testUserID, InboundAmount: money.AmountFromYuan(146982), OutboundAmount: money.AmountFromYuan(173540), DocumentCount: 14},
		{BusinessUserID: testOtherID, InboundAmount: money.AmountFromYuan(402000), OutboundAmount: money.AmountFromYuan(512000), DocumentCount: 21},
	}

	result, err := ownerService(repo).BusinessUsers(context.Background(), ownerPrincipal(testGroupID, testUserID), BusinessUserQuery{Period: "2026-09"})
	if err != nil {
		t.Fatalf("BusinessUsers error = %v", err)
	}
	if len(result.Items) != 2 {
		t.Fatalf("业务员行数 = %d, want 2", len(result.Items))
	}
	if result.Items[0].BusinessUser.DisplayName != "王业务" {
		t.Fatalf("首个业务员 = %q, want 王业务", result.Items[0].BusinessUser.DisplayName)
	}
	if result.Items[0].GrossProfit != money.AmountFromYuan(26558) {
		t.Fatalf("王业务毛利润 = %s, want 26558.00", result.Items[0].GrossProfit)
	}
	if result.Summary.InboundAmount != money.AmountFromYuan(548982) || result.Summary.OutboundAmount != money.AmountFromYuan(685540) {
		t.Fatalf("合计行 = %s/%s", result.Summary.InboundAmount, result.Summary.OutboundAmount)
	}
	if result.Summary.DocumentCount != 35 {
		t.Fatalf("合计单据数 = %d, want 35", result.Summary.DocumentCount)
	}
	if result.Summary.GrossProfitUpper == "" {
		t.Fatalf("合计行应带大写金额")
	}
}

/* ------------------------------------------------------------------ 总结算快照 */

func TestCreateSnapshotCompanyScope(t *testing.T) {
	repo := newFakeRepository()
	repo.seedUser(testUserID, "主账号")
	repo.settlements = []DocumentSettlement{
		inboundSettlement(money.AmountFromYuan(100000), money.AmountFromYuan(80000), money.AmountFromYuan(100000)),
		outboundSettlement(money.AmountFromYuan(125000), money.AmountFromYuan(100000), document.SaleAmountVATSpecial),
	}
	remark := "  九月   总结算  "

	result, err := ownerService(repo).CreateSnapshots(context.Background(), ownerPrincipal(testGroupID, testUserID),
		CreateSnapshotRequest{Period: "2026-09", Scope: "company", Remark: &remark})
	if err != nil {
		t.Fatalf("CreateSnapshots error = %v", err)
	}
	if len(result.Snapshots) != 1 || result.Snapshots[0].Scope != ScopeCompany {
		t.Fatalf("公司维度应只生成 1 张: %+v", result.Snapshots)
	}
	snapshot := result.Snapshots[0]
	if snapshot.InboundAmount != money.AmountFromYuan(100000) || snapshot.OutboundAmount != money.AmountFromYuan(125000) {
		t.Fatalf("快照金额 = %s/%s", snapshot.InboundAmount, snapshot.OutboundAmount)
	}
	if snapshot.GrossProfit != money.AmountFromYuan(25000) || snapshot.GrossMarginPercent != "20.00" {
		t.Fatalf("毛利润/毛利率 = %s/%s, want 25000.00/20.00", snapshot.GrossProfit, snapshot.GrossMarginPercent)
	}
	if snapshot.DocumentCount != 2 {
		t.Fatalf("单据数 = %d, want 2", snapshot.DocumentCount)
	}
	if snapshot.Remark == nil || *snapshot.Remark != "九月 总结算" {
		t.Fatalf("备注归一化 = %v, want 九月 总结算", snapshot.Remark)
	}
	if snapshot.BusinessUser.ID != 0 {
		t.Fatalf("公司维度不应带业务员: %+v", snapshot.BusinessUser)
	}
	if len(snapshot.SaleAmountTypes) != 3 || snapshot.SaleAmountTypes[0].Amount != money.AmountFromYuan(125000) {
		t.Fatalf("销售金额分项应随快照冻结: %+v", snapshot.SaleAmountTypes)
	}
	if snapshot.BatchNo == "" || snapshot.BatchNo != snapshot.SnapshotNo {
		t.Fatalf("单张快照的批次号应等于自身单号: %q / %q", snapshot.BatchNo, snapshot.SnapshotNo)
	}
	if repo.lastCreateInput.PeriodStart != time.Date(2026, time.September, 1, 0, 0, 0, 0, time.UTC) {
		t.Fatalf("快照周期起点 = %s", repo.lastCreateInput.PeriodStart)
	}
	if len(repo.audits) != 1 || repo.audits[0].summary != fmt.Sprintf("总结算单 %s 公司维度 生成", snapshot.SnapshotNo) {
		t.Fatalf("审计摘要 = %+v", repo.audits)
	}
}

func TestCreateSnapshotBusinessUsersScopeGeneratesOnePerUser(t *testing.T) {
	repo := newFakeRepository()
	repo.seedUser(testUserID, "王业务")
	repo.seedUser(testOtherID, "赵业务")
	repo.businessUsers = []BusinessUserTotals{
		{
			BusinessUserID: testUserID, InboundAmount: money.AmountFromYuan(146982),
			OutboundAmount: money.AmountFromYuan(173540), DocumentCount: 14,
			SaleAmountTotals: SaleAmountTotals{VATSpecial: money.AmountFromYuan(113200), VATGeneral: money.AmountFromYuan(60340)},
		},
		{BusinessUserID: testOtherID, InboundAmount: money.AmountFromYuan(402000), OutboundAmount: money.AmountFromYuan(512000), DocumentCount: 21},
	}

	result, err := ownerService(repo).CreateSnapshots(context.Background(), ownerPrincipal(testGroupID, testUserID),
		CreateSnapshotRequest{Period: "2026-09", Scope: "business_user"})
	if err != nil {
		t.Fatalf("CreateSnapshots error = %v", err)
	}
	if len(result.Snapshots) != 2 {
		t.Fatalf("业务员维度应生成 2 张, got %d", len(result.Snapshots))
	}
	if result.BatchNo == "" || result.Snapshots[0].BatchNo != result.BatchNo || result.Snapshots[1].BatchNo != result.BatchNo {
		t.Fatalf("同一次生成应共享批次号: %q / %q / %q", result.BatchNo, result.Snapshots[0].BatchNo, result.Snapshots[1].BatchNo)
	}
	if result.Snapshots[0].BusinessUser.DisplayName != "王业务" || result.Snapshots[1].BusinessUser.DisplayName != "赵业务" {
		t.Fatalf("业务员姓名 = %q/%q", result.Snapshots[0].BusinessUser.DisplayName, result.Snapshots[1].BusinessUser.DisplayName)
	}
	if result.Snapshots[0].DocumentCount != 14 || result.Snapshots[1].DocumentCount != 21 {
		t.Fatalf("单据数 = %d/%d, want 14/21", result.Snapshots[0].DocumentCount, result.Snapshots[1].DocumentCount)
	}
	// 业务员维度快照同样要冻结三类销售金额。
	if result.Snapshots[0].SaleAmountTypes[0].Amount != money.AmountFromYuan(113200) {
		t.Fatalf("业务员快照应冻结三类销售金额: %+v", result.Snapshots[0].SaleAmountTypes)
	}
	if result.Snapshots[0].SaleAmountTypes[1].Amount != money.AmountFromYuan(60340) {
		t.Fatalf("业务员快照 y-N 金额 = %s, want 60340.00", result.Snapshots[0].SaleAmountTypes[1].Amount)
	}
	if result.Snapshots[0].GrossProfit != money.AmountFromYuan(26558) {
		t.Fatalf("王业务毛利润 = %s, want 26558.00", result.Snapshots[0].GrossProfit)
	}
}

func TestCreateSnapshotSingleBusinessUser(t *testing.T) {
	repo := newFakeRepository()
	repo.seedUser(testOtherID, "赵业务")
	repo.settlements = []DocumentSettlement{
		inboundSettlement(money.AmountFromYuan(100000), 0, 0),
	}

	result, err := ownerService(repo).CreateSnapshots(context.Background(), ownerPrincipal(testGroupID, testUserID),
		CreateSnapshotRequest{Period: "2026-09", Scope: "business_user", BusinessUserID: testOtherID})
	if err != nil {
		t.Fatalf("CreateSnapshots error = %v", err)
	}
	if len(result.Snapshots) != 1 || result.Snapshots[0].BusinessUser.ID != testOtherID {
		t.Fatalf("指定业务员应只生成 1 张: %+v", result.Snapshots)
	}
	if repo.lastAggregate.BusinessUserID != testOtherID {
		t.Fatalf("聚合筛选业务员 = %d, want %d", repo.lastAggregate.BusinessUserID, testOtherID)
	}
}

func TestCreateSnapshotRejectsEmptyPeriodAndBadInput(t *testing.T) {
	repo := newFakeRepository()
	service := ownerService(repo)
	principal := ownerPrincipal(testGroupID, testUserID)

	// 周期内没有任何已提交单据 → 拒绝，而不是写入一堆 0。
	_, err := service.CreateSnapshots(context.Background(), principal, CreateSnapshotRequest{Period: "2026-09", Scope: "company"})
	wantAppError(t, err, apperror.ErrReportPeriodEmpty)

	// 业务员全都没有单据 → 同样拒绝。
	_, err = service.CreateSnapshots(context.Background(), principal, CreateSnapshotRequest{Period: "2026-09", Scope: "business_user"})
	wantAppError(t, err, apperror.ErrReportPeriodEmpty)

	// scope 非法。
	_, err = service.CreateSnapshots(context.Background(), principal, CreateSnapshotRequest{Period: "2026-09", Scope: "team"})
	wantAppError(t, err, apperror.ErrValidationFailed)

	// period 非法。
	_, err = service.CreateSnapshots(context.Background(), principal, CreateSnapshotRequest{Period: "2026-13", Scope: "company"})
	wantAppError(t, err, apperror.ErrValidationFailed)

	// 备注超长。
	repo.settlements = []DocumentSettlement{inboundSettlement(money.AmountFromYuan(100), 0, 0)}
	long := strings.Repeat("备", maxRemarkLength+1)
	_, err = service.CreateSnapshots(context.Background(), principal, CreateSnapshotRequest{Period: "2026-09", Scope: "company", Remark: &long})
	wantAppError(t, err, apperror.ErrValidationFailed)
}

func TestCreateSnapshotRequiresReportPermission(t *testing.T) {
	repo := newFakeRepository()
	repo.settlements = []DocumentSettlement{inboundSettlement(money.AmountFromYuan(100), 0, 0)}
	_, err := memberService(repo).CreateSnapshots(context.Background(), memberPrincipal(testGroupID, testOtherID),
		CreateSnapshotRequest{Period: "2026-09", Scope: "company"})
	wantAppError(t, err, apperror.ErrForbidden)
}

/* ------------------------------------------------------------------ 快照查询 */

func TestListSnapshotsNormalizesFilters(t *testing.T) {
	repo := newFakeRepository()
	repo.seedUser(testUserID, "主账号")
	repo.seedSnapshot(Snapshot{
		GroupID: testGroupID, SnapshotNo: "ZJS202609-0001", BatchNo: "ZJS202609-0001",
		Scope: ScopeCompany, PeriodStart: time.Date(2026, time.September, 1, 0, 0, 0, 0, time.UTC),
		InboundAmount: money.AmountFromYuan(100000), OutboundAmount: money.AmountFromYuan(125000),
		GrossProfit: money.AmountFromYuan(25000), GrossMarginPPM: 200000,
		CreatedBy: testUserID, CreatedAt: fixedNow,
	})
	service := ownerService(repo)
	principal := ownerPrincipal(testGroupID, testUserID)

	result, err := service.ListSnapshots(context.Background(), principal, SnapshotListQuery{Period: "2026-09", Scope: ScopeCompany})
	if err != nil {
		t.Fatalf("ListSnapshots error = %v", err)
	}
	if result.Total != 1 || len(result.Items) != 1 {
		t.Fatalf("快照列表 = %d/%d", len(result.Items), result.Total)
	}
	if result.Items[0].GrossMarginPercent != "20.00" {
		t.Fatalf("毛利率展示 = %q, want 20.00", result.Items[0].GrossMarginPercent)
	}
	if result.Items[0].CreatedBy.DisplayName != "主账号" {
		t.Fatalf("创建人 = %q", result.Items[0].CreatedBy.DisplayName)
	}
	if repo.lastSnapshotQ.Scope == nil || *repo.lastSnapshotQ.Scope != ScopeCompany {
		t.Fatalf("维度筛选未透传: %+v", repo.lastSnapshotQ.Scope)
	}
	if repo.lastSnapshotQ.PeriodStart == nil || repo.lastSnapshotQ.PeriodEnd == nil {
		t.Fatalf("周期筛选未透传")
	}

	// page_size 超限与 scope 非法都要被拒绝。
	if _, err := service.ListSnapshots(context.Background(), principal, SnapshotListQuery{PageSize: maxPageSize + 1}); err == nil {
		t.Fatalf("page_size 超限应被拒绝")
	} else {
		wantAppError(t, err, apperror.ErrValidationFailed)
	}
	if _, err := service.ListSnapshots(context.Background(), principal, SnapshotListQuery{Scope: "team"}); err == nil {
		t.Fatalf("scope 非法应被拒绝")
	} else {
		wantAppError(t, err, apperror.ErrValidationFailed)
	}
}

func TestGetSnapshotValidatesAndMapsNotFound(t *testing.T) {
	repo := newFakeRepository()
	repo.seedUser(testUserID, "主账号")
	snapshot := repo.seedSnapshot(Snapshot{
		GroupID: testGroupID, SnapshotNo: "ZJS202609-0001", Scope: ScopeCompany,
		PeriodStart: time.Date(2026, time.September, 1, 0, 0, 0, 0, time.UTC),
		CreatedBy:   testUserID, CreatedAt: fixedNow,
	})
	service := ownerService(repo)
	principal := ownerPrincipal(testGroupID, testUserID)

	result, err := service.GetSnapshot(context.Background(), principal, snapshot.ID)
	if err != nil {
		t.Fatalf("GetSnapshot error = %v", err)
	}
	if result.SnapshotNo != "ZJS202609-0001" {
		t.Fatalf("单号 = %q", result.SnapshotNo)
	}

	if _, err := service.GetSnapshot(context.Background(), principal, 0); err == nil {
		t.Fatalf("snapshot_id = 0 应被拒绝")
	} else {
		wantAppError(t, err, apperror.ErrValidationFailed)
	}
	if _, err := service.GetSnapshot(context.Background(), principal, 999); err == nil {
		t.Fatalf("不存在的快照应报错")
	} else {
		wantAppError(t, err, apperror.ErrReportSnapshotNotFound)
	}
}

// TestSnapshotKeepsFrozenBusinessUserName 锁定「姓名快照」这条规则：
// 用户事后改名不应该改写历史报表的抬头。
func TestSnapshotKeepsFrozenBusinessUserName(t *testing.T) {
	repo := newFakeRepository()
	repo.seedUser(testOtherID, "赵业务（已改名）")
	name := "赵业务"
	otherUserID := testOtherID
	snapshot := repo.seedSnapshot(Snapshot{
		GroupID: testGroupID, SnapshotNo: "ZJS202609-0002", Scope: ScopeBusinessUser,
		PeriodStart:    time.Date(2026, time.September, 1, 0, 0, 0, 0, time.UTC),
		BusinessUserID: &otherUserID, BusinessUserName: &name,
		CreatedBy: testUserID, CreatedAt: fixedNow,
	})

	result, err := ownerService(repo).GetSnapshot(context.Background(), ownerPrincipal(testGroupID, testUserID), snapshot.ID)
	if err != nil {
		t.Fatalf("GetSnapshot error = %v", err)
	}
	if result.BusinessUser.DisplayName != "赵业务" {
		t.Fatalf("业务员姓名 = %q, want 赵业务（快照里冻结的那份）", result.BusinessUser.DisplayName)
	}
	if result.BusinessUser.ID != testOtherID {
		t.Fatalf("业务员 ID = %d, want %d", result.BusinessUser.ID, testOtherID)
	}
}

/* ------------------------------------------------------------------ 数值工具 */

func TestPercentTextFormatting(t *testing.T) {
	cases := []struct {
		ppm  int64
		want string
	}{
		{0, "0.00"},
		{207500, "20.75"},
		{50, "0.01"},
		{49, "0.00"},
		{-33892, "-3.39"},
		{-1, "0.00"},
		{1000000, "100.00"},
	}
	for _, item := range cases {
		if got := percentText(item.ppm); got != item.want {
			t.Fatalf("percentText(%d) = %q, want %q", item.ppm, got, item.want)
		}
	}
}

func TestPpmRatioHandlesZeroAndNegative(t *testing.T) {
	if got := ppmRatio(money.AmountFromYuan(100), 0); got != 0 {
		t.Fatalf("分母为 0 时 ppmRatio = %d, want 0", got)
	}
	// 负毛利必须如实返回负数，而不是被收敛成 0。
	if got := ppmRatio(money.AmountFromYuan(-25000), money.AmountFromYuan(125000)); got != -200000 {
		t.Fatalf("负毛利 ppmRatio = %d, want -200000", got)
	}
	// 大数不溢出：1000 亿 / 1 元 = 1e11 倍 → 远超 int64 的百万分之一表达范围，
	// 这里只要求不 panic 且返回 0（溢出兜底）。
	if got := ppmRatio(money.Amount(testQuotaMax), money.Amount(1)); got != 0 {
		t.Fatalf("极端比值应返回 0，got %d", got)
	}
}

const testQuotaMax = int64(9223372036854775807)

func TestParseScopeRejectsUnknown(t *testing.T) {
	if _, ok := ParseScope("company"); !ok {
		t.Fatalf("company 应被接受")
	}
	if _, ok := ParseScope("business_user"); !ok {
		t.Fatalf("business_user 应被接受")
	}
	if _, ok := ParseScope("team"); ok {
		t.Fatalf("team 不应被接受")
	}
	if ScopeCompany.Label() != "公司维度" || ScopeBusinessUser.Label() != "业务员维度" {
		t.Fatalf("维度文案不符合预期")
	}
}
