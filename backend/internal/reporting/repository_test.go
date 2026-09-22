package reporting

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"testing"
	"time"

	"CBizDocsManager/backend/internal/document"
	"CBizDocsManager/backend/internal/identity"
	"CBizDocsManager/backend/pkg/money"
	"github.com/glebarez/sqlite"
	"gorm.io/gorm"
	"gorm.io/gorm/logger"
)

/* ------------------------------------------------------------------ sqlite 测试库 */

// businessDay 是测试用的业务日期（零点，与写入 DATE 列后的回读值一致）。
var businessDay = time.Date(2026, time.September, 15, 0, 0, 0, 0, time.UTC)

// reportingAuditLogTest 只用于让仓储里对 audit_logs 的写入在 sqlite 上可执行。
// 字段名与真实迁移一致，避免测试通过而生产 SQL 报错。
type reportingAuditLogTest struct {
	ID             uint64 `gorm:"primaryKey;autoIncrement"`
	GroupID        *uint64
	OperatorUserID uint64
	Action         string
	ResourceType   string
	ResourceID     string
	Summary        string
	CreatedAt      time.Time
}

func (reportingAuditLogTest) TableName() string { return "audit_logs" }

// financeRecordTest 是 finance_records 的最小列集合。
//
// 汇总统计只读这张表（按 kind 过滤并 SUM），不 import finance 包；
// 这里按真实迁移的列名建一张等价表，既能验证聚合 SQL 的正确性，
// 也不会把两个模块的编译绑在一起。
type financeRecordTest struct {
	ID             uint64 `gorm:"primaryKey;autoIncrement"`
	GroupID        uint64
	DocumentID     uint64
	DocumentKind   string `gorm:"size:16"`
	DocumentNo     string `gorm:"size:32"`
	PartyName      string `gorm:"size:191"`
	BusinessUserID uint64
	BusinessDate   time.Time `gorm:"type:date"`
	Kind           string    `gorm:"size:16"`
	Amount         money.Amount
	OccurredOn     time.Time `gorm:"type:date"`
	Method         *string   `gorm:"size:16"`
	MethodNote     *string   `gorm:"size:100"`
	CardTail       *string   `gorm:"size:4"`
	InvoiceNo      *string   `gorm:"size:64"`
	Remark         *string   `gorm:"size:500"`
	CreatedBy      uint64
	CreatedAt      time.Time
}

func (financeRecordTest) TableName() string { return "finance_records" }

// openReportingTestDB 打开一个进程内 sqlite 库并建好汇总统计依赖的全部表。
//
// 用「内存库 + 单连接」：GORM 的链式查询与事务在同一连接上才可预期，
// 多连接的内存库会各自看到不同的数据库。
func openReportingTestDB(t *testing.T) *gorm.DB {
	t.Helper()
	dsn := fmt.Sprintf("file:%s?mode=memory&cache=shared&_foreign_keys=on", strings.ReplaceAll(t.Name(), "/", "_"))
	db, err := gorm.Open(sqlite.Open(dsn), &gorm.Config{TranslateError: true, Logger: logger.Default.LogMode(logger.Silent)})
	if err != nil {
		t.Fatalf("open sqlite: %v", err)
	}
	sqlDB, err := db.DB()
	if err != nil {
		t.Fatalf("sql db: %v", err)
	}
	sqlDB.SetMaxOpenConns(1)
	t.Cleanup(func() { _ = sqlDB.Close() })

	models := []any{
		&identity.User{}, &document.Document{}, &document.Party{}, &document.Item{},
		&Snapshot{}, &financeRecordTest{}, &reportingAuditLogTest{},
	}
	if err := db.AutoMigrate(models...); err != nil {
		t.Fatalf("migrate: %v", err)
	}
	return db
}

type reportingFixture struct {
	db           *gorm.DB
	repo         Repository
	groupID      uint64
	otherGroupID uint64
}

func newReportingFixture(t *testing.T) reportingFixture {
	t.Helper()
	db := openReportingTestDB(t)
	return reportingFixture{db: db, repo: NewRepository(db), groupID: testGroupID, otherGroupID: 4}
}

func (f reportingFixture) insertUser(t *testing.T, id uint64, name string) {
	t.Helper()
	record := identity.User{
		ID: id, Username: fmt.Sprintf("user%d", id), PasswordHash: "x", DisplayName: name,
		AccountType: identity.AccountTypeMember, Status: "active",
	}
	if err := f.db.Create(&record).Error; err != nil {
		t.Fatalf("insert user: %v", err)
	}
}

// documentSpec 描述一张用于统计的测试单据。
type documentSpec struct {
	id             uint64
	groupID        uint64
	kind           document.Kind
	no             string
	status         document.Status
	businessUserID uint64
	amount         money.Amount
	saleAmountType *document.SaleAmountType
	// businessDate 为零值时用默认的 businessDay，非零时按给定日期落库。
	businessDate time.Time
}

func (f reportingFixture) insertDocument(t *testing.T, spec documentSpec) {
	t.Helper()
	groupID := spec.groupID
	if groupID == 0 {
		groupID = f.groupID
	}
	if spec.status == "" {
		spec.status = document.StatusSubmitted
	}
	businessDate := spec.businessDate
	if businessDate.IsZero() {
		businessDate = businessDay
	}
	record := document.Document{
		ID: spec.id, GroupID: groupID, Kind: spec.kind, DocumentNo: spec.no, Status: spec.status,
		BusinessUserID: spec.businessUserID, BusinessDate: businessDate,
		SaleAmountType: spec.saleAmountType, TotalAmount: spec.amount,
		Version: 1, CreatedBy: spec.businessUserID, UpdatedBy: spec.businessUserID,
	}
	if err := f.db.Create(&record).Error; err != nil {
		t.Fatalf("insert document: %v", err)
	}
}

func (f reportingFixture) insertParty(t *testing.T, documentID uint64, position int, name string) uint64 {
	t.Helper()
	record := document.Party{
		GroupID: f.groupID, DocumentID: documentID, Position: position,
		PartyName: name, Subtotal: money.AmountFromYuan(10),
	}
	if err := f.db.Create(&record).Error; err != nil {
		t.Fatalf("insert party: %v", err)
	}
	return record.ID
}

func (f reportingFixture) insertItem(t *testing.T, documentID, partyID uint64, position int, productName, model, unit string, quantity money.Quantity, amount money.Amount) {
	t.Helper()
	record := document.Item{
		GroupID: f.groupID, DocumentID: documentID, PartyID: partyID, Position: position,
		ProductName: productName, Quantity: quantity, UnitPrice: money.Price(10000),
		PriceTaxMode: document.PriceTaxIncluded, Amount: amount,
	}
	if model != "" {
		record.ProductModel = &model
	}
	if unit != "" {
		record.Unit = &unit
	}
	if err := f.db.Create(&record).Error; err != nil {
		t.Fatalf("insert item: %v", err)
	}
}

// insertFinanceRecord 直接写入一条付款 / 收款 / 开票记录。
func (f reportingFixture) insertFinanceRecord(t *testing.T, groupID, documentID uint64, kind string, amount money.Amount) {
	t.Helper()
	record := financeRecordTest{
		GroupID: groupID, DocumentID: documentID, DocumentKind: string(document.KindInbound),
		DocumentNo: fmt.Sprintf("RK20260915-%04d", documentID), PartyName: "唐山钢铁",
		BusinessUserID: testUserID, BusinessDate: businessDay,
		Kind: kind, Amount: amount, OccurredOn: businessDay, CreatedBy: testUserID, CreatedAt: fixedNow,
	}
	if err := f.db.Create(&record).Error; err != nil {
		t.Fatalf("insert finance record: %v", err)
	}
}

func (f reportingFixture) aggregateQuery() AggregateQuery {
	return AggregateQuery{
		PeriodStart: time.Date(2026, time.September, 1, 0, 0, 0, 0, time.UTC),
		PeriodEnd:   time.Date(2026, time.October, 1, 0, 0, 0, 0, time.UTC),
	}
}

// seedReportingCorpus 建一组覆盖「已提交 / 草稿 / 作废 / 跨组」的最小数据集。
func (f reportingFixture) seedReportingCorpus(t *testing.T) {
	t.Helper()
	vatSpecial := document.SaleAmountVATSpecial
	vatGeneral := document.SaleAmountVATGeneral

	// 入库单 1（业务员 7）：100000 元，已付 80000、已开票 100000。
	f.insertDocument(t, documentSpec{id: 1, kind: document.KindInbound, no: "RK20260915-0001", businessUserID: testUserID, amount: money.AmountFromYuan(100000)})
	f.insertFinanceRecord(t, f.groupID, 1, KindPaymentRecord, money.AmountFromYuan(80000))
	f.insertFinanceRecord(t, f.groupID, 1, KindInvoiceRecord, money.AmountFromYuan(100000))
	// 入库单 2（业务员 8）：50000 元，已付 30000、未开票。
	f.insertDocument(t, documentSpec{id: 2, kind: document.KindInbound, no: "RK20260916-0002", businessUserID: testOtherID, amount: money.AmountFromYuan(50000)})
	f.insertFinanceRecord(t, f.groupID, 2, KindPaymentRecord, money.AmountFromYuan(30000))
	// 草稿与作废单都不参与统计。
	f.insertDocument(t, documentSpec{id: 3, kind: document.KindInbound, no: "RK20260917-0003", status: document.StatusDraft, businessUserID: testUserID, amount: money.AmountFromYuan(999999)})
	f.insertDocument(t, documentSpec{id: 4, kind: document.KindInbound, no: "RK20260918-0004", status: document.StatusVoided, businessUserID: testUserID, amount: money.AmountFromYuan(888888)})
	// 出库单 5（业务员 7）：173520 元，Y-1，已收 80000。
	f.insertDocument(t, documentSpec{id: 5, kind: document.KindOutbound, no: "CK20260918-0005", businessUserID: testUserID, amount: money.AmountFromYuan(173520), saleAmountType: &vatSpecial})
	f.insertFinanceRecord(t, f.groupID, 5, KindReceiptRecord, money.AmountFromYuan(80000))
	// 出库单 6（业务员 8）：60320 元，y-N，未收。
	f.insertDocument(t, documentSpec{id: 6, kind: document.KindOutbound, no: "CK20260919-0006", businessUserID: testOtherID, amount: money.AmountFromYuan(60320), saleAmountType: &vatGeneral})
	// 跨组单据：完全不应出现。
	f.insertDocument(t, documentSpec{id: 7, groupID: f.otherGroupID, kind: document.KindInbound, no: "RK20260920-0007", businessUserID: testUserID, amount: money.AmountFromYuan(777777)})
}

/* ------------------------------------------------------------------ 周期合计 */

func TestLoadSettlementsCountsOnlySubmittedDocuments(t *testing.T) {
	fixture := newReportingFixture(t)
	fixture.seedReportingCorpus(t)

	rows, err := fixture.repo.LoadSettlements(context.Background(), fixture.groupID, fixture.aggregateQuery())
	if err != nil {
		t.Fatalf("LoadSettlements error = %v", err)
	}
	if len(rows) != 4 {
		t.Fatalf("参与统计的单据数 = %d, want 4（草稿、作废与跨组单据必须排除）: %+v", len(rows), rows)
	}

	totals := newPeriodTotals(rows)
	if totals.InboundDocuments != 2 || totals.OutboundDocuments != 2 {
		t.Fatalf("入库/出库单据数 = %d/%d, want 2/2", totals.InboundDocuments, totals.OutboundDocuments)
	}
	if totals.InboundAmount != money.AmountFromYuan(150000) {
		t.Fatalf("入库合计 = %s, want 150000.00", totals.InboundAmount)
	}
	if totals.OutboundAmount != money.AmountFromYuan(233840) {
		t.Fatalf("出库合计 = %s, want 233840.00", totals.OutboundAmount)
	}
	if totals.Paid != money.AmountFromYuan(110000) {
		t.Fatalf("已付合计 = %s, want 110000.00", totals.Paid)
	}
	if totals.Invoiced != money.AmountFromYuan(100000) {
		t.Fatalf("已开票合计 = %s, want 100000.00", totals.Invoiced)
	}
	if totals.Received != money.AmountFromYuan(80000) {
		t.Fatalf("已收合计 = %s, want 80000.00", totals.Received)
	}
	if totals.Unpaid() != money.AmountFromYuan(40000) {
		t.Fatalf("未付款 = %s, want 40000.00", totals.Unpaid())
	}
	if totals.Unreceived() != money.AmountFromYuan(153840) {
		t.Fatalf("未收款 = %s, want 153840.00", totals.Unreceived())
	}
	// 两张入库单都没付清（80000/100000、30000/50000），只有第一张开满了票。
	if totals.UnpaidDocuments != 2 || totals.UninvoicedDocuments != 1 || totals.UnreceivedDocuments != 2 {
		t.Fatalf("未付清/未开满/未收清 = %d/%d/%d, want 2/1/2",
			totals.UnpaidDocuments, totals.UninvoicedDocuments, totals.UnreceivedDocuments)
	}
	if totals.SaleAmountTotals.VATSpecial != money.AmountFromYuan(173520) || totals.SaleAmountTotals.VATGeneral != money.AmountFromYuan(60320) {
		t.Fatalf("三类销售金额 = %s/%s", totals.SaleAmountTotals.VATSpecial, totals.SaleAmountTotals.VATGeneral)
	}
}

func TestLoadSettlementsHonoursBusinessUserFilter(t *testing.T) {
	fixture := newReportingFixture(t)
	fixture.seedReportingCorpus(t)

	query := fixture.aggregateQuery()
	query.BusinessUserID = testOtherID
	rows, err := fixture.repo.LoadSettlements(context.Background(), fixture.groupID, query)
	if err != nil {
		t.Fatalf("LoadSettlements error = %v", err)
	}
	if len(rows) != 2 {
		t.Fatalf("业务员维度单据数 = %d, want 2", len(rows))
	}
	totals := newPeriodTotals(rows)
	if totals.InboundAmount != money.AmountFromYuan(50000) || totals.OutboundAmount != money.AmountFromYuan(60320) {
		t.Fatalf("业务员维度金额 = %s/%s, want 50000.00/60320.00", totals.InboundAmount, totals.OutboundAmount)
	}
}

func TestLoadSettlementsExcludesOtherMonths(t *testing.T) {
	fixture := newReportingFixture(t)
	fixture.insertDocument(t, documentSpec{
		id: 11, kind: document.KindInbound, no: "RK20260815-0011", businessUserID: testUserID,
		amount:       money.AmountFromYuan(1000),
		businessDate: time.Date(2026, time.August, 15, 0, 0, 0, 0, time.UTC),
	})

	// 九月窗口内不应出现八月的单据。
	rows, err := fixture.repo.LoadSettlements(context.Background(), fixture.groupID, fixture.aggregateQuery())
	if err != nil {
		t.Fatalf("LoadSettlements error = %v", err)
	}
	if len(rows) != 0 {
		t.Fatalf("九月窗口内出现 %d 张单据，want 0", len(rows))
	}

	// 把窗口挪到八月就能看到它，证明过滤条件生效而不是整段查询失效。
	august := AggregateQuery{
		PeriodStart: time.Date(2026, time.August, 1, 0, 0, 0, 0, time.UTC),
		PeriodEnd:   time.Date(2026, time.September, 1, 0, 0, 0, 0, time.UTC),
	}
	rows, err = fixture.repo.LoadSettlements(context.Background(), fixture.groupID, august)
	if err != nil {
		t.Fatalf("LoadSettlements error = %v", err)
	}
	if len(rows) != 1 {
		t.Fatalf("八月窗口内单据数 = %d, want 1", len(rows))
	}
}

func TestCountPartiesDeduplicatesByKind(t *testing.T) {
	fixture := newReportingFixture(t)
	fixture.seedReportingCorpus(t)

	// 两张入库单各一个进项公司（含一张草稿、一张作废，都要排除），两张出库单各一个客户。
	fixture.insertParty(t, 1, 1, "鑫源钢贸")
	fixture.insertParty(t, 2, 1, "昌盛金属")
	fixture.insertParty(t, 3, 1, "不应统计的草稿公司")
	fixture.insertParty(t, 4, 1, "不应统计的作废公司")
	fixture.insertParty(t, 5, 1, "宏达建筑")
	fixture.insertParty(t, 6, 1, "恒信机电")
	fixture.insertParty(t, 7, 1, "跨组公司")

	suppliers, customers, err := fixture.repo.CountParties(context.Background(), fixture.groupID, fixture.aggregateQuery())
	if err != nil {
		t.Fatalf("CountParties error = %v", err)
	}
	if suppliers != 2 {
		t.Fatalf("进项公司数 = %d, want 2", suppliers)
	}
	if customers != 2 {
		t.Fatalf("客户数 = %d, want 2", customers)
	}
}

/* ------------------------------------------------------------------ 明细聚合 */

func TestLoadItemsGroupsAndPaginates(t *testing.T) {
	fixture := newReportingFixture(t)
	fixture.seedReportingCorpus(t)

	// 入库单 1：同一进项公司下两条同品名同型号同单位的明细应合并；空型号 / 空单位单独成行。
	partyID := fixture.insertParty(t, 1, 1, "鑫源钢贸")
	fixture.insertItem(t, 1, partyID, 1, "螺纹钢", "HRB400 Φ20", "吨", money.Quantity(17050), money.AmountFromYuan(72000))
	fixture.insertItem(t, 1, partyID, 2, "螺纹钢", "HRB400 Φ20", "吨", money.Quantity(3000), money.AmountFromYuan(12000))
	fixture.insertItem(t, 1, partyID, 3, "盘螺", "", "", money.Quantity(5000), money.AmountFromYuan(16000))
	// 入库单 2：不同进项公司，独立成行。
	partyID2 := fixture.insertParty(t, 2, 1, "昌盛金属")
	fixture.insertItem(t, 2, partyID2, 1, "热轧卷板", "Q235B", "张", money.Quantity(10000), money.AmountFromYuan(50000))
	// 草稿单的明细不应出现。
	draftParty := fixture.insertParty(t, 3, 1, "草稿公司")
	fixture.insertItem(t, 3, draftParty, 1, "草稿品名", "", "", money.Quantity(1000), money.AmountFromYuan(1))

	query := ItemQuery{AggregateQuery: fixture.aggregateQuery(), Page: 1, PageSize: 20}
	page, err := fixture.repo.LoadItems(context.Background(), fixture.groupID, document.KindInbound, query)
	if err != nil {
		t.Fatalf("LoadItems error = %v", err)
	}
	if page.Total != 3 {
		t.Fatalf("聚合行数 = %d, want 3（草稿明细必须排除）", page.Total)
	}
	if len(page.Items) != 3 {
		t.Fatalf("返回行数 = %d, want 3", len(page.Items))
	}
	byProduct := make(map[string]ItemTotals, len(page.Items))
	for _, item := range page.Items {
		byProduct[item.ProductName] = item
	}
	// 金额倒序：螺纹钢 84000 > 热轧卷板 50000 > 盘螺 16000。
	if page.Items[0].ProductName != "螺纹钢" || page.Items[0].Amount != money.AmountFromYuan(84000) {
		t.Fatalf("首行 = %+v, want 螺纹钢 84000.00（按金额倒序）", page.Items[0])
	}

	// 合并后的螺纹钢：72000 + 12000 = 84000，数量 17.050 + 3.000 = 20.050。
	rebar, ok := byProduct["螺纹钢"]
	if !ok {
		t.Fatalf("缺少螺纹钢聚合行: %+v", page.Items)
	}
	if rebar.Amount != money.AmountFromYuan(84000) {
		t.Fatalf("螺纹钢金额 = %s, want 84000.00", rebar.Amount)
	}
	if rebar.Quantity != money.Quantity(20050) {
		t.Fatalf("螺纹钢数量 = %s, want 20.050", rebar.Quantity)
	}
	if rebar.DocumentCount != 1 {
		t.Fatalf("螺纹钢关联单据数 = %d, want 1", rebar.DocumentCount)
	}
	if rebar.ProductModel == nil || *rebar.ProductModel != "HRB400 Φ20" || rebar.Unit == nil || *rebar.Unit != "吨" {
		t.Fatalf("螺纹钢型号 / 单位 = %v/%v", rebar.ProductModel, rebar.Unit)
	}

	// 不同进项公司的同品名明细必须分开成行。
	hotRolled, ok := byProduct["热轧卷板"]
	if !ok || hotRolled.PartyName != "昌盛金属" || hotRolled.Amount != money.AmountFromYuan(50000) {
		t.Fatalf("热轧卷板行 = %+v", hotRolled)
	}

	// 空型号 / 空单位要落成 nil，而不是空字符串。
	spiral, ok := byProduct["盘螺"]
	if !ok {
		t.Fatalf("缺少盘螺聚合行: %+v", page.Items)
	}
	if spiral.ProductModel != nil || spiral.Unit != nil {
		t.Fatalf("盘螺行的空型号 / 空单位应为 nil: %+v", spiral)
	}

	// 分页：第 2 页只应有 1 行，但 total 仍是 3。
	query.Page, query.PageSize = 2, 2
	paged, err := fixture.repo.LoadItems(context.Background(), fixture.groupID, document.KindInbound, query)
	if err != nil {
		t.Fatalf("LoadItems error = %v", err)
	}
	if paged.Total != 3 || len(paged.Items) != 1 {
		t.Fatalf("分页结果 = %d 行 / total=%d, want 1/3", len(paged.Items), paged.Total)
	}
}

func TestLoadItemsAppliesKeywordFilters(t *testing.T) {
	fixture := newReportingFixture(t)
	fixture.seedReportingCorpus(t)
	partyID := fixture.insertParty(t, 1, 1, "鑫源钢贸")
	fixture.insertItem(t, 1, partyID, 1, "螺纹钢", "HRB400 Φ20", "吨", money.Quantity(17050), money.AmountFromYuan(72000))
	fixture.insertItem(t, 1, partyID, 2, "盘螺", "HRB400 Φ8", "吨", money.Quantity(5000), money.AmountFromYuan(16000))

	base := fixture.aggregateQuery()

	// 按型号过滤。
	page, err := fixture.repo.LoadItems(context.Background(), fixture.groupID, document.KindInbound,
		ItemQuery{AggregateQuery: base, ModelKeyword: "Φ8", Page: 1, PageSize: 20})
	if err != nil {
		t.Fatalf("LoadItems error = %v", err)
	}
	if page.Total != 1 || page.Items[0].ProductName != "盘螺" {
		t.Fatalf("按型号过滤结果 = %+v", page.Items)
	}

	// 按进项公司过滤：命中不到时应为空。
	page, err = fixture.repo.LoadItems(context.Background(), fixture.groupID, document.KindInbound,
		ItemQuery{AggregateQuery: base, PartyKeyword: "不存在的公司", Page: 1, PageSize: 20})
	if err != nil {
		t.Fatalf("LoadItems error = %v", err)
	}
	if page.Total != 0 || len(page.Items) != 0 {
		t.Fatalf("按不存在的公司过滤应返回空: %+v", page.Items)
	}

	// 出库方向不应混入入库明细。
	page, err = fixture.repo.LoadItems(context.Background(), fixture.groupID, document.KindOutbound,
		ItemQuery{AggregateQuery: base, Page: 1, PageSize: 20})
	if err != nil {
		t.Fatalf("LoadItems error = %v", err)
	}
	if page.Total != 0 {
		t.Fatalf("出库方向混入了 %d 条入库明细", page.Total)
	}
}

/* ------------------------------------------------------------------ 业务员维度 */

func TestLoadBusinessUserTotalsMergesKindsAndSaleTypes(t *testing.T) {
	fixture := newReportingFixture(t)
	fixture.seedReportingCorpus(t)

	rows, err := fixture.repo.LoadBusinessUserTotals(context.Background(), fixture.groupID, fixture.aggregateQuery())
	if err != nil {
		t.Fatalf("LoadBusinessUserTotals error = %v", err)
	}
	if len(rows) != 2 {
		t.Fatalf("业务员行数 = %d, want 2", len(rows))
	}
	byUser := make(map[uint64]BusinessUserTotals, len(rows))
	for _, row := range rows {
		byUser[row.BusinessUserID] = row
	}
	first, ok := byUser[testUserID]
	if !ok {
		t.Fatalf("缺少业务员 %d 的行: %+v", testUserID, rows)
	}
	if first.InboundAmount != money.AmountFromYuan(100000) {
		t.Fatalf("业务员 %d 入库 = %s, want 100000.00", testUserID, first.InboundAmount)
	}
	if first.OutboundAmount != money.AmountFromYuan(173520) {
		t.Fatalf("业务员 %d 出库 = %s, want 173520.00", testUserID, first.OutboundAmount)
	}
	if first.DocumentCount != 2 {
		t.Fatalf("业务员 %d 单据数 = %d, want 2", testUserID, first.DocumentCount)
	}
	if first.SaleAmountTotals.VATSpecial != money.AmountFromYuan(173520) || first.SaleAmountTotals.VATGeneral != 0 {
		t.Fatalf("业务员 %d 三类销售金额 = %+v", testUserID, first.SaleAmountTotals)
	}
	if first.GrossProfit() != money.AmountFromYuan(73520) {
		t.Fatalf("业务员 %d 毛利润 = %s, want 73520.00", testUserID, first.GrossProfit())
	}
}

/* ------------------------------------------------------------------ 总结算快照 */

func TestCreateSnapshotsGeneratesNumberBatchAndAudit(t *testing.T) {
	fixture := newReportingFixture(t)
	fixture.insertUser(t, testUserID, "主账号")

	start := time.Date(2026, time.September, 1, 0, 0, 0, 0, time.UTC)
	end := time.Date(2026, time.October, 1, 0, 0, 0, 0, time.UTC)
	name := "王业务"
	userID := testUserID
	input := CreateSnapshotInput{
		GroupID: fixture.groupID, PeriodStart: start, PeriodEnd: end,
		OperatorUserID: testUserID, Now: fixedNow,
		Candidates: []SnapshotCandidate{
			{
				Scope: ScopeCompany,
				InboundAmount: money.AmountFromYuan(100000), OutboundAmount: money.AmountFromYuan(125000),
				GrossProfit: money.AmountFromYuan(25000), GrossMarginPPM: 200000,
				VATSpecialAmount: money.AmountFromYuan(125000), DocumentCount: 2,
			},
			{
				Scope: ScopeBusinessUser, BusinessUserID: &userID, BusinessUserName: &name,
				InboundAmount: money.AmountFromYuan(100000), OutboundAmount: money.AmountFromYuan(125000),
				GrossProfit: money.AmountFromYuan(25000), GrossMarginPPM: 200000, DocumentCount: 2,
			},
		},
	}
	created, err := fixture.repo.CreateSnapshots(context.Background(), input)
	if err != nil {
		t.Fatalf("CreateSnapshots error = %v", err)
	}
	if len(created) != 2 {
		t.Fatalf("生成快照数 = %d, want 2", len(created))
	}
	if created[0].SnapshotNo != "ZJS202609-0001" || created[1].SnapshotNo != "ZJS202609-0002" {
		t.Fatalf("单号 = %q/%q, want ZJS202609-0001/ZJS202609-0002", created[0].SnapshotNo, created[1].SnapshotNo)
	}
	if created[0].BatchNo != "ZJS202609-0001" || created[1].BatchNo != created[0].BatchNo {
		t.Fatalf("批次号 = %q/%q, want 均为 ZJS202609-0001", created[0].BatchNo, created[1].BatchNo)
	}
	if created[0].CreatedAt != fixedNow {
		t.Fatalf("创建时间 = %s, want 注入时钟 %s（不能用墙上时间）", created[0].CreatedAt, fixedNow)
	}
	if created[1].BusinessUserName == nil || *created[1].BusinessUserName != "王业务" {
		t.Fatalf("业务员姓名快照 = %v", created[1].BusinessUserName)
	}

	// 第二次生成应从 0003 继续，而不是重复 0001。
	next, err := fixture.repo.CreateSnapshots(context.Background(), CreateSnapshotInput{
		GroupID: fixture.groupID, PeriodStart: start, PeriodEnd: end,
		OperatorUserID: testUserID, Now: fixedNow,
		Candidates: []SnapshotCandidate{{Scope: ScopeCompany}},
	})
	if err != nil {
		t.Fatalf("CreateSnapshots error = %v", err)
	}
	if next[0].SnapshotNo != "ZJS202609-0003" {
		t.Fatalf("第二次生成单号 = %q, want ZJS202609-0003", next[0].SnapshotNo)
	}

	// 审计逐张写入，摘要由仓储拼装。
	var audits []reportingAuditLogTest
	if err := fixture.db.Where("action = ?", "report.summary_settlement.generated").Find(&audits).Error; err != nil {
		t.Fatalf("load audits: %v", err)
	}
	if len(audits) != 3 {
		t.Fatalf("审计条数 = %d, want 3", len(audits))
	}
	if audits[0].Summary != "总结算单 ZJS202609-0001 公司维度 生成" {
		t.Fatalf("审计摘要 = %q", audits[0].Summary)
	}
	if audits[1].Summary != "总结算单 ZJS202609-0002 业务员维度 王业务 生成" {
		t.Fatalf("审计摘要 = %q", audits[1].Summary)
	}
	if audits[0].ResourceType != "report_snapshot" {
		t.Fatalf("审计资源类型 = %q", audits[0].ResourceType)
	}
}

func TestCreateSnapshotsRejectsEmptyCandidates(t *testing.T) {
	fixture := newReportingFixture(t)
	_, err := fixture.repo.CreateSnapshots(context.Background(), CreateSnapshotInput{
		GroupID: fixture.groupID,
	})
	if !errors.Is(err, ErrPeriodEmpty) {
		t.Fatalf("空候选应返回 ErrPeriodEmpty, got %v", err)
	}
}

func TestListAndFindSnapshotsAreFilteredAndGroupIsolated(t *testing.T) {
	fixture := newReportingFixture(t)
	fixture.insertUser(t, testUserID, "主账号")

	name := "王业务"
	userID := testUserID
	seed := func(groupID uint64, no string, scope Scope, start time.Time) Snapshot {
		snapshot := Snapshot{
			GroupID: groupID, SnapshotNo: no, BatchNo: no, Scope: scope,
			PeriodStart: start, PeriodEnd: start.AddDate(0, 1, 0),
			BusinessUserID: &userID, BusinessUserName: &name,
			InboundAmount: money.AmountFromYuan(100), OutboundAmount: money.AmountFromYuan(200),
			GrossProfit: money.AmountFromYuan(100), CreatedBy: testUserID, CreatedAt: fixedNow,
		}
		if scope == ScopeCompany {
			snapshot.BusinessUserID, snapshot.BusinessUserName = nil, nil
		}
		if err := fixture.db.Create(&snapshot).Error; err != nil {
			t.Fatalf("seed snapshot: %v", err)
		}
		return snapshot
	}
	sept := time.Date(2026, time.September, 1, 0, 0, 0, 0, time.UTC)
	august := time.Date(2026, time.August, 1, 0, 0, 0, 0, time.UTC)
	seeded := seed(fixture.groupID, "ZJS202609-0001", ScopeCompany, sept)
	seed(fixture.groupID, "ZJS202609-0002", ScopeBusinessUser, sept)
	seed(fixture.groupID, "ZJS202608-0003", ScopeCompany, august)
	seed(fixture.otherGroupID, "ZJS202609-0004", ScopeCompany, sept)

	query := SnapshotQuery{Page: 1, PageSize: 20}
	page, err := fixture.repo.ListSnapshots(context.Background(), fixture.groupID, query)
	if err != nil {
		t.Fatalf("ListSnapshots error = %v", err)
	}
	if page.Total != 3 {
		t.Fatalf("本组快照数 = %d, want 3（跨组快照必须不可见）", page.Total)
	}

	// 按维度过滤。
	companyScope := ScopeCompany
	query.Scope = &companyScope
	page, err = fixture.repo.ListSnapshots(context.Background(), fixture.groupID, query)
	if err != nil {
		t.Fatalf("ListSnapshots error = %v", err)
	}
	if page.Total != 2 {
		t.Fatalf("公司维度快照数 = %d, want 2", page.Total)
	}

	// 按周期过滤。
	septEnd := time.Date(2026, time.October, 1, 0, 0, 0, 0, time.UTC)
	query = SnapshotQuery{Page: 1, PageSize: 20, PeriodStart: &sept, PeriodEnd: &septEnd}
	page, err = fixture.repo.ListSnapshots(context.Background(), fixture.groupID, query)
	if err != nil {
		t.Fatalf("ListSnapshots error = %v", err)
	}
	if page.Total != 2 {
		t.Fatalf("九月快照数 = %d, want 2", page.Total)
	}

	// 分页时 total 与当前页行数要分开。
	page, err = fixture.repo.ListSnapshots(context.Background(), fixture.groupID, SnapshotQuery{Page: 1, PageSize: 2})
	if err != nil {
		t.Fatalf("ListSnapshots error = %v", err)
	}
	if page.Total != 3 || len(page.Items) != 2 {
		t.Fatalf("分页结果 = %d 行 / total=%d, want 2/3", len(page.Items), page.Total)
	}

	// FindSnapshot：本组可见。
	found, err := fixture.repo.FindSnapshot(context.Background(), fixture.groupID, seeded.ID)
	if err != nil {
		t.Fatalf("FindSnapshot error = %v", err)
	}
	if found.SnapshotNo != "ZJS202609-0001" {
		t.Fatalf("单号 = %q", found.SnapshotNo)
	}
	// 跨组不可见。
	if _, err := fixture.repo.FindSnapshot(context.Background(), fixture.otherGroupID, seeded.ID); !errors.Is(err, ErrSnapshotNotFound) {
		t.Fatalf("跨组读取应返回 ErrSnapshotNotFound, got %v", err)
	}
}

/* ------------------------------------------------------------------ 用户摘要 */

func TestLoadUsersReturnsSummaries(t *testing.T) {
	fixture := newReportingFixture(t)
	fixture.insertUser(t, testUserID, "王业务")
	fixture.insertUser(t, testOtherID, "赵业务")

	users, err := fixture.repo.LoadUsers(context.Background(), []uint64{testUserID, testOtherID, 999})
	if err != nil {
		t.Fatalf("LoadUsers error = %v", err)
	}
	if len(users) != 2 {
		t.Fatalf("用户数 = %d, want 2", len(users))
	}
	if users[testUserID].DisplayName != "王业务" || users[testOtherID].DisplayName != "赵业务" {
		t.Fatalf("用户摘要 = %+v", users)
	}
	empty, err := fixture.repo.LoadUsers(context.Background(), nil)
	if err != nil {
		t.Fatalf("LoadUsers(nil) error = %v", err)
	}
	if len(empty) != 0 {
		t.Fatalf("空入参应返回空映射")
	}
}
