package settlement

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

// settlementAuditLogTest 只用于让仓储里对 audit_logs 的写入在 sqlite 上可执行。
// 字段名与真实迁移一致，避免测试通过而生产 SQL 报错。
type settlementAuditLogTest struct {
	ID             uint64 `gorm:"primaryKey;autoIncrement"`
	GroupID        *uint64
	OperatorUserID uint64
	Action         string
	ResourceType   string
	ResourceID     string
	Summary        string
	CreatedAt      time.Time
}

func (settlementAuditLogTest) TableName() string { return "audit_logs" }

// openSettlementTestDB 打开一个进程内 sqlite 库并建好结算模块依赖的全部表。
//
// 这里刻意用「内存库 + 单连接」：GORM 的链式查询与事务在同一连接上才可预期，
// 多连接的内存库会各自看到不同的数据库。
func openSettlementTestDB(t *testing.T) *gorm.DB {
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
		&identity.User{}, &document.Document{},
		&Settlement{}, &Source{}, &ApprovalRecord{}, &idempotencyRecord{},
		&settlementAuditLogTest{},
	}
	if err := db.AutoMigrate(models...); err != nil {
		t.Fatalf("migrate: %v", err)
	}

	// 真实迁移里 (group_id, active_document_id) 是唯一索引，用来兜底「同一源单据
	// 不能被两张有效结算单同时引用」。测试里显式补上，才能验证「释放后置 NULL 可复用」。
	if err := db.Exec(`CREATE UNIQUE INDEX uk_settlement_sources_active
		ON settlement_sources (group_id, active_document_id)`).Error; err != nil {
		t.Fatalf("create unique index: %v", err)
	}
	return db
}

type settlementFixture struct {
	db           *gorm.DB
	repo         Repository
	groupID      uint64
	otherGroupID uint64
}

func newSettlementFixture(t *testing.T) settlementFixture {
	t.Helper()
	db := openSettlementTestDB(t)
	return settlementFixture{db: db, repo: NewRepository(db), groupID: 1, otherGroupID: 2}
}

// insertDocument 造一张已提交的源单据，供结算引用。
func (f settlementFixture) insertDocument(t *testing.T, id, groupID uint64, kind document.Kind, no string, amount money.Amount, businessUser uint64) {
	t.Helper()
	record := document.Document{
		ID: id, GroupID: groupID, Kind: kind, DocumentNo: no, Status: document.StatusSubmitted,
		BusinessUserID: businessUser, BusinessDate: time.Date(2026, time.September, 22, 0, 0, 0, 0, time.UTC),
		TotalAmount: amount, Version: 1, CreatedBy: businessUser, UpdatedBy: businessUser,
	}
	if err := f.db.Create(&record).Error; err != nil {
		t.Fatalf("insert document: %v", err)
	}
}

func (f settlementFixture) insertUser(t *testing.T, id uint64, name string) {
	t.Helper()
	record := identity.User{
		ID: id, Username: fmt.Sprintf("user%d", id), PasswordHash: "x", DisplayName: name,
		AccountType: identity.AccountTypeMember, Status: "active",
	}
	if err := f.db.Create(&record).Error; err != nil {
		t.Fatalf("insert user: %v", err)
	}
}

/* ------------------------------------------------------------------ 造数据 */

// sourceSnapshot 生成一条源单据快照，字段顺序与真实汇总逻辑无关，只为构造输入。
func sourceSnapshot(id uint64, kind document.Kind, no string, amount money.Amount, businessUser uint64) SourceSnapshot {
	return SourceSnapshot{
		DocumentID: id, Kind: kind, DocumentNo: no, BusinessUserID: businessUser,
		BusinessDate: time.Date(2026, time.September, 22, 0, 0, 0, 0, time.UTC), Amount: amount,
	}
}

// createInput 生成一份最小可用的创建入参；需要的字段由调用方覆盖。
func createInput(groupID, requester uint64, now time.Time, key string, sources ...SourceSnapshot) CreateInput {
	var inbound, outbound money.Amount
	for _, source := range sources {
		if source.Kind.IsInbound() {
			inbound = inbound.Add(source.Amount)
		} else {
			outbound = outbound.Add(source.Amount)
		}
	}
	return CreateInput{
		GroupID: groupID, RequesterUserID: requester, Remark: nil,
		InboundTotal: inbound, OutboundTotal: outbound, GrossProfit: outbound.Sub(inbound),
		Sources: sources, OperatorUserID: requester, Now: now,
		IdempotencyScope: idempotencyScope("create"), IdempotencyKey: key,
		RequestFingerprint: fingerprintCreate(requester, nil, sources),
		AuditAction:        "settlement.created", AuditSummary: "已提交申请",
	}
}

/* ------------------------------------------------------------------ 写入 */

func TestRepositoryCreatePersistsSnapshotAndSequence(t *testing.T) {
	fixture := newSettlementFixture(t)
	now := time.Date(2026, time.September, 22, 10, 0, 0, 0, time.UTC)

	first, err := fixture.repo.CreateSettlement(context.Background(), createInput(fixture.groupID, 7, now, "k1",
		sourceSnapshot(11, document.KindInbound, "RK20260922-0001", money.AmountFromYuan(100), 7),
		sourceSnapshot(12, document.KindOutbound, "CK20260922-0002", money.AmountFromYuan(150), 7),
	))
	if err != nil {
		t.Fatalf("CreateSettlement() error = %v", err)
	}
	if first.ID == 0 || first.SettlementNo != "JS202609-0001" {
		t.Fatalf("created = %+v", first)
	}
	if first.Status != StatusPending || first.Version != 1 || first.SourceCount != 2 {
		t.Fatalf("created = %+v", first)
	}
	if first.InboundTotal.String() != "100.00" || first.OutboundTotal.String() != "150.00" || first.GrossProfit.String() != "50.00" {
		t.Fatalf("totals = %s / %s / %s", first.InboundTotal, first.OutboundTotal, first.GrossProfit)
	}

	// 同月再建一张：序号必须递增，而不是复用 0001。
	second, err := fixture.repo.CreateSettlement(context.Background(), createInput(fixture.groupID, 7, now, "k2",
		sourceSnapshot(13, document.KindInbound, "RK20260922-0003", money.AmountFromYuan(80), 7),
	))
	if err != nil {
		t.Fatalf("second CreateSettlement() error = %v", err)
	}
	if second.SettlementNo != "JS202609-0002" {
		t.Fatalf("second SettlementNo = %q, want JS202609-0002", second.SettlementNo)
	}

	// 源单据行、审批记录、审计日志都要落库。
	detail, err := fixture.repo.LoadDetail(context.Background(), fixture.groupID, first.ID)
	if err != nil {
		t.Fatalf("LoadDetail() error = %v", err)
	}
	if len(detail.Sources) != 2 || detail.Sources[0].ActiveDocumentID == nil ||
		*detail.Sources[0].ActiveDocumentID != detail.Sources[0].DocumentID {
		t.Fatalf("sources = %+v", detail.Sources)
	}
	if len(detail.Records) != 1 || detail.Records[0].Action != ActionSubmitted {
		t.Fatalf("records = %+v", detail.Records)
	}

	var audits int64
	if err := fixture.db.Model(&settlementAuditLogTest{}).
		Where("resource_type = ? AND action = ?", "settlement", "settlement.created").Count(&audits).Error; err != nil {
		t.Fatalf("count audits: %v", err)
	}
	if audits != 2 {
		t.Fatalf("audit rows = %d, want 2", audits)
	}

	var records int64
	if err := fixture.db.Model(&idempotencyRecord{}).Count(&records).Error; err != nil {
		t.Fatalf("count idempotency: %v", err)
	}
	if records != 2 {
		t.Fatalf("idempotency rows = %d, want 2", records)
	}
}

func TestRepositoryIdempotentReplayAndFingerprintMismatch(t *testing.T) {
	fixture := newSettlementFixture(t)
	now := time.Date(2026, time.September, 22, 10, 0, 0, 0, time.UTC)
	input := createInput(fixture.groupID, 7, now, "same-key",
		sourceSnapshot(11, document.KindInbound, "RK20260922-0001", money.AmountFromYuan(100), 7),
	)

	created, err := fixture.repo.CreateSettlement(context.Background(), input)
	if err != nil {
		t.Fatalf("CreateSettlement() error = %v", err)
	}
	// 同键同载荷重放：直接返回首次创建的那张，绝不新建。
	replayed, err := fixture.repo.CreateSettlement(context.Background(), input)
	if err != nil {
		t.Fatalf("replay error = %v", err)
	}
	if replayed.ID != created.ID || replayed.SettlementNo != created.SettlementNo {
		t.Fatalf("replayed = %+v, want same as %+v", replayed, created)
	}
	if replayNo := replayed.SettlementNo; replayNo != "JS202609-0001" {
		t.Fatalf("replayed SettlementNo = %q", replayNo)
	}

	// 同键异载荷：说明客户端复用了幂等键，必须报错而不是返回旧单。
	mismatch := input
	mismatch.RequestFingerprint = "different-fingerprint"
	if _, err := fixture.repo.CreateSettlement(context.Background(), mismatch); !errors.Is(err, ErrIdempotencyMismatch) {
		t.Fatalf("mismatch error = %v, want ErrIdempotencyMismatch", err)
	}
}

func TestRepositoryRejectsOccupiedSource(t *testing.T) {
	fixture := newSettlementFixture(t)
	now := time.Date(2026, time.September, 22, 10, 0, 0, 0, time.UTC)
	snapshot := sourceSnapshot(11, document.KindInbound, "RK20260922-0001", money.AmountFromYuan(100), 7)

	if _, err := fixture.repo.CreateSettlement(context.Background(), createInput(fixture.groupID, 7, now, "k1", snapshot)); err != nil {
		t.Fatalf("first CreateSettlement() error = %v", err)
	}
	// 换一个幂等键再引用同一张源单据：预检必须拦下来。
	if _, err := fixture.repo.CreateSettlement(context.Background(), createInput(fixture.groupID, 7, now, "k2", snapshot)); !errors.Is(err, ErrSourceConflict) {
		t.Fatalf("occupied error = %v, want ErrSourceConflict", err)
	}
}

func TestRepositoryRejectionReleasesSourcesForReuse(t *testing.T) {
	fixture := newSettlementFixture(t)
	now := time.Date(2026, time.September, 22, 10, 0, 0, 0, time.UTC)
	snapshot := sourceSnapshot(11, document.KindInbound, "RK20260922-0001", money.AmountFromYuan(100), 7)

	created, err := fixture.repo.CreateSettlement(context.Background(), createInput(fixture.groupID, 7, now, "k1", snapshot))
	if err != nil {
		t.Fatalf("CreateSettlement() error = %v", err)
	}
	reason := "单价填错"
	decided, err := fixture.repo.DecideSettlement(context.Background(), DecideInput{
		GroupID: fixture.groupID, SettlementID: created.ID, OperatorUserID: 1,
		ExpectedVersion: created.Version, Status: StatusRejected, DecisionRemark: &reason,
		ReleaseSources: true, Now: now.Add(time.Hour),
		AuditAction: "settlement.rejected", AuditSummary: "已审批驳回",
	})
	if err != nil {
		t.Fatalf("DecideSettlement() error = %v", err)
	}
	if decided.Status != StatusRejected || decided.Version != 2 || decided.DecidedBy == nil || *decided.DecidedBy != 1 {
		t.Fatalf("decided = %+v", decided)
	}

	// 关联行保留（追溯不丢），但活跃引用被置空、记录释放时间。
	detail, err := fixture.repo.LoadDetail(context.Background(), fixture.groupID, created.ID)
	if err != nil {
		t.Fatalf("LoadDetail() error = %v", err)
	}
	if len(detail.Sources) != 1 || detail.Sources[0].ActiveDocumentID != nil || detail.Sources[0].ReleasedAt == nil {
		t.Fatalf("released sources = %+v", detail.Sources)
	}
	if len(detail.Records) != 2 || detail.Records[1].Action != ActionRejected {
		t.Fatalf("records = %+v", detail.Records)
	}

	// 释放后同一张源单据可以被新的结算单重新引用（唯一索引上的多 NULL 语义）。
	reused, err := fixture.repo.CreateSettlement(context.Background(), createInput(fixture.groupID, 7, now, "k2", snapshot))
	if err != nil {
		t.Fatalf("reuse CreateSettlement() error = %v", err)
	}
	if reused.SettlementNo != "JS202609-0002" {
		t.Fatalf("reused SettlementNo = %q, want JS202609-0002", reused.SettlementNo)
	}
}

func TestRepositoryDecideGuardsVersionAndTerminalState(t *testing.T) {
	fixture := newSettlementFixture(t)
	now := time.Date(2026, time.September, 22, 10, 0, 0, 0, time.UTC)
	created, err := fixture.repo.CreateSettlement(context.Background(), createInput(fixture.groupID, 7, now, "k1",
		sourceSnapshot(11, document.KindInbound, "RK20260922-0001", money.AmountFromYuan(100), 7),
	))
	if err != nil {
		t.Fatalf("CreateSettlement() error = %v", err)
	}

	// 版本不匹配：说明客户端读到的是旧快照，要求刷新。
	if _, err := fixture.repo.DecideSettlement(context.Background(), DecideInput{
		GroupID: fixture.groupID, SettlementID: created.ID, OperatorUserID: 1,
		ExpectedVersion: created.Version + 1, Status: StatusApproved, Now: now,
	}); !errors.Is(err, ErrVersionConflict) {
		t.Fatalf("version error = %v, want ErrVersionConflict", err)
	}

	if _, err := fixture.repo.DecideSettlement(context.Background(), DecideInput{
		GroupID: fixture.groupID, SettlementID: created.ID, OperatorUserID: 1,
		ExpectedVersion: created.Version, Status: StatusApproved, Now: now,
	}); err != nil {
		t.Fatalf("approve error = %v", err)
	}

	// 单级审批：终态不允许再被审批一次。
	if _, err := fixture.repo.DecideSettlement(context.Background(), DecideInput{
		GroupID: fixture.groupID, SettlementID: created.ID, OperatorUserID: 1,
		ExpectedVersion: 2, Status: StatusRejected, DecisionRemark: textPointer("重复审批"), Now: now,
	}); !errors.Is(err, ErrStatusInvalid) {
		t.Fatalf("terminal error = %v, want ErrStatusInvalid", err)
	}

	// 审批通过不释放源单据：仍占着唯一索引。
	if _, err := fixture.repo.CreateSettlement(context.Background(), createInput(fixture.groupID, 7, now, "k2",
		sourceSnapshot(11, document.KindInbound, "RK20260922-0001", money.AmountFromYuan(100), 7),
	)); !errors.Is(err, ErrSourceConflict) {
		t.Fatalf("approved source error = %v, want ErrSourceConflict", err)
	}
}

/* ------------------------------------------------------------------ 读取 */

func TestRepositoryFindSettlementIsGroupScoped(t *testing.T) {
	fixture := newSettlementFixture(t)
	now := time.Date(2026, time.September, 22, 10, 0, 0, 0, time.UTC)
	created, err := fixture.repo.CreateSettlement(context.Background(), createInput(fixture.groupID, 7, now, "k1",
		sourceSnapshot(11, document.KindInbound, "RK20260922-0001", money.AmountFromYuan(100), 7),
	))
	if err != nil {
		t.Fatalf("CreateSettlement() error = %v", err)
	}

	if _, err := fixture.repo.FindSettlement(context.Background(), fixture.groupID, created.ID); err != nil {
		t.Fatalf("FindSettlement() error = %v", err)
	}
	// 跨组读取必须表现得像「不存在」，不能泄露别组数据的存在性。
	if _, err := fixture.repo.FindSettlement(context.Background(), fixture.otherGroupID, created.ID); !errors.Is(err, ErrNotFound) {
		t.Fatalf("cross-group error = %v, want ErrNotFound", err)
	}
	if _, err := fixture.repo.LoadDetail(context.Background(), fixture.otherGroupID, created.ID); !errors.Is(err, ErrNotFound) {
		t.Fatalf("cross-group detail error = %v, want ErrNotFound", err)
	}
}

func TestRepositoryLoadDetailOrdersSourcesAndRecords(t *testing.T) {
	fixture := newSettlementFixture(t)
	now := time.Date(2026, time.September, 22, 10, 0, 0, 0, time.UTC)
	// 故意先传出库再传入库，验证读回来是按 kind 升序（inbound 在 outbound 前）。
	created, err := fixture.repo.CreateSettlement(context.Background(), createInput(fixture.groupID, 7, now, "k1",
		sourceSnapshot(12, document.KindOutbound, "CK20260922-0002", money.AmountFromYuan(150), 7),
		sourceSnapshot(11, document.KindInbound, "RK20260922-0001", money.AmountFromYuan(100), 7),
	))
	if err != nil {
		t.Fatalf("CreateSettlement() error = %v", err)
	}
	if _, err := fixture.repo.DecideSettlement(context.Background(), DecideInput{
		GroupID: fixture.groupID, SettlementID: created.ID, OperatorUserID: 1,
		ExpectedVersion: created.Version, Status: StatusApproved, Now: now,
	}); err != nil {
		t.Fatalf("DecideSettlement() error = %v", err)
	}

	detail, err := fixture.repo.LoadDetail(context.Background(), fixture.groupID, created.ID)
	if err != nil {
		t.Fatalf("LoadDetail() error = %v", err)
	}
	if len(detail.Sources) != 2 || detail.Sources[0].Kind != document.KindInbound || detail.Sources[1].Kind != document.KindOutbound {
		t.Fatalf("sources order = %+v", detail.Sources)
	}
	// 审批记录按写入顺序追加：先「提交申请」，再「审批通过」。
	if len(detail.Records) != 2 || detail.Records[0].Action != ActionSubmitted || detail.Records[1].Action != ActionApproved {
		t.Fatalf("records order = %+v", detail.Records)
	}
}

func TestRepositoryListFiltersAndPaginates(t *testing.T) {
	fixture := newSettlementFixture(t)
	september := time.Date(2026, time.September, 10, 10, 0, 0, 0, time.UTC)
	october := time.Date(2026, time.October, 3, 10, 0, 0, 0, time.UTC)

	// 九月三张（申请人为 7/7/8），十月一张（申请人 8）。
	first, err := fixture.repo.CreateSettlement(context.Background(), createInput(fixture.groupID, 7, september, "s1",
		sourceSnapshot(11, document.KindInbound, "RK20260922-0001", money.AmountFromYuan(100), 7),
	))
	if err != nil {
		t.Fatalf("create s1: %v", err)
	}
	if _, err := fixture.repo.CreateSettlement(context.Background(), createInput(fixture.groupID, 7, september.Add(time.Hour), "s2",
		sourceSnapshot(12, document.KindInbound, "RK20260922-0002", money.AmountFromYuan(200), 7),
	)); err != nil {
		t.Fatalf("create s2: %v", err)
	}
	if _, err := fixture.repo.CreateSettlement(context.Background(), createInput(fixture.groupID, 8, september.Add(2*time.Hour), "s3",
		sourceSnapshot(13, document.KindOutbound, "CK20260922-0003", money.AmountFromYuan(300), 8),
	)); err != nil {
		t.Fatalf("create s3: %v", err)
	}
	if _, err := fixture.repo.CreateSettlement(context.Background(), createInput(fixture.groupID, 8, october, "s4",
		sourceSnapshot(14, document.KindOutbound, "CK20261003-0004", money.AmountFromYuan(400), 8),
	)); err != nil {
		t.Fatalf("create s4: %v", err)
	}
	// 把第一张审批掉，用来验证状态过滤。
	if _, err := fixture.repo.DecideSettlement(context.Background(), DecideInput{
		GroupID: fixture.groupID, SettlementID: first.ID, OperatorUserID: 1,
		ExpectedVersion: first.Version, Status: StatusApproved, Now: september.Add(3 * time.Hour),
	}); err != nil {
		t.Fatalf("approve: %v", err)
	}

	base := RepositoryQuery{Page: 1, PageSize: 20}
	page, err := fixture.repo.ListSettlements(context.Background(), fixture.groupID, base)
	if err != nil {
		t.Fatalf("ListSettlements() error = %v", err)
	}
	if page.Total != 4 || len(page.Items) != 4 {
		t.Fatalf("total = %d, items = %d, want 4/4", page.Total, len(page.Items))
	}
	// 按创建时间倒序：最新的十月单排最前。
	if page.Items[0].Settlement.SettlementNo != "JS202610-0001" {
		t.Fatalf("first item = %q, want JS202610-0001", page.Items[0].Settlement.SettlementNo)
	}

	// 月份区间过滤（左闭右开，九月 1 日 00:00 ~ 十月 1 日 00:00）。
	septemberStart := time.Date(2026, time.September, 1, 0, 0, 0, 0, time.UTC)
	octoberStart := time.Date(2026, time.October, 1, 0, 0, 0, 0, time.UTC)
	monthPage, err := fixture.repo.ListSettlements(context.Background(), fixture.groupID,
		RepositoryQuery{MonthStart: &septemberStart, MonthEnd: &octoberStart, Page: 1, PageSize: 20})
	if err != nil {
		t.Fatalf("month filter error = %v", err)
	}
	if monthPage.Total != 3 {
		t.Fatalf("september total = %d, want 3", monthPage.Total)
	}

	// 状态过滤。
	approved := StatusApproved
	statusPage, err := fixture.repo.ListSettlements(context.Background(), fixture.groupID,
		RepositoryQuery{Status: &approved, Page: 1, PageSize: 20})
	if err != nil {
		t.Fatalf("status filter error = %v", err)
	}
	if statusPage.Total != 1 || statusPage.Items[0].Settlement.ID != first.ID {
		t.Fatalf("approved page = %+v", statusPage.Items)
	}

	// 申请人过滤（主账号看某位业务员）。
	requester := uint64(8)
	requesterPage, err := fixture.repo.ListSettlements(context.Background(), fixture.groupID,
		RepositoryQuery{RequesterUserID: &requester, Page: 1, PageSize: 20})
	if err != nil {
		t.Fatalf("requester filter error = %v", err)
	}
	if requesterPage.Total != 2 {
		t.Fatalf("requester total = %d, want 2", requesterPage.Total)
	}

	// 子账号数据范围：只能看本人。
	onlyPage, err := fixture.repo.ListSettlements(context.Background(), fixture.groupID,
		RepositoryQuery{OnlyRequesterUserID: 7, Page: 1, PageSize: 20})
	if err != nil {
		t.Fatalf("only requester filter error = %v", err)
	}
	if onlyPage.Total != 2 {
		t.Fatalf("only requester total = %d, want 2", onlyPage.Total)
	}

	// 关键词过滤：单号前缀命中。
	keywordPage, err := fixture.repo.ListSettlements(context.Background(), fixture.groupID,
		RepositoryQuery{Keyword: "JS202609", Page: 1, PageSize: 20})
	if err != nil {
		t.Fatalf("keyword filter error = %v", err)
	}
	if keywordPage.Total != 3 {
		t.Fatalf("keyword total = %d, want 3", keywordPage.Total)
	}

	// 分页：每页 2 条，第 2 页剩 2 条，但 Total 仍是全量。
	paged, err := fixture.repo.ListSettlements(context.Background(), fixture.groupID,
		RepositoryQuery{Page: 2, PageSize: 2})
	if err != nil {
		t.Fatalf("paged error = %v", err)
	}
	if paged.Total != 4 || len(paged.Items) != 2 {
		t.Fatalf("paged = total %d, items %d", paged.Total, len(paged.Items))
	}

	// 跨组查询看不到别组数据。
	if _, err := fixture.repo.CreateSettlement(context.Background(), createInput(fixture.otherGroupID, 9, september, "o1",
		sourceSnapshot(21, document.KindInbound, "RK20260922-0021", money.AmountFromYuan(50), 9),
	)); err != nil {
		t.Fatalf("other group create: %v", err)
	}
	otherPage, err := fixture.repo.ListSettlements(context.Background(), fixture.otherGroupID, base)
	if err != nil {
		t.Fatalf("other group list error = %v", err)
	}
	if otherPage.Total != 1 {
		t.Fatalf("other group total = %d, want 1", otherPage.Total)
	}
}

func TestRepositoryLoadSourceDocumentsScopesToGroup(t *testing.T) {
	fixture := newSettlementFixture(t)
	fixture.insertDocument(t, 11, fixture.groupID, document.KindInbound, "RK20260922-0001", money.AmountFromYuan(100), 7)
	fixture.insertDocument(t, 21, fixture.otherGroupID, document.KindInbound, "RK20260922-0021", money.AmountFromYuan(200), 9)

	documents, err := fixture.repo.LoadSourceDocuments(context.Background(), fixture.groupID, []uint64{11, 21})
	if err != nil {
		t.Fatalf("LoadSourceDocuments() error = %v", err)
	}
	// 只返回本组那一张，调用方据此识别「不存在或跨组」。
	if len(documents) != 1 || documents[0].ID != 11 {
		t.Fatalf("documents = %+v", documents)
	}
	if documents[0].Status != document.StatusSubmitted || documents[0].TotalAmount.String() != "100.00" {
		t.Fatalf("document = %+v", documents[0])
	}

	// 空 ID 列表不必查库。
	empty, err := fixture.repo.LoadSourceDocuments(context.Background(), fixture.groupID, nil)
	if err != nil || empty != nil {
		t.Fatalf("empty = %+v, err = %v", empty, err)
	}
}

func TestRepositoryLoadUsers(t *testing.T) {
	fixture := newSettlementFixture(t)
	fixture.insertUser(t, 7, "王业务")
	fixture.insertUser(t, 8, "李业务")

	users, err := fixture.repo.LoadUsers(context.Background(), []uint64{7, 8, 99})
	if err != nil {
		t.Fatalf("LoadUsers() error = %v", err)
	}
	if len(users) != 2 || users[7].DisplayName != "王业务" || users[8].DisplayName != "李业务" {
		t.Fatalf("users = %+v", users)
	}
	// 不存在的用户不返回，由调用方按「零值」处理。
	if _, ok := users[99]; ok {
		t.Fatal("missing user should not be present")
	}

	empty, err := fixture.repo.LoadUsers(context.Background(), nil)
	if err != nil || len(empty) != 0 {
		t.Fatalf("empty users = %+v, err = %v", empty, err)
	}
}
