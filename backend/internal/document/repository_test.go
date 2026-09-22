package document

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"testing"
	"time"

	"CBizDocsManager/backend/internal/identity"
	"CBizDocsManager/backend/pkg/money"
	"github.com/glebarez/sqlite"
	"gorm.io/gorm"
	"gorm.io/gorm/logger"
)

/* ------------------------------------------------------------------ sqlite 测试库 */

type documentAuditLogTest struct {
	ID             uint64 `gorm:"primaryKey;autoIncrement"`
	GroupID        *uint64
	OperatorUserID uint64
	Action         string
	ResourceType   string
	ResourceID     string
	Summary        string
	CreatedAt      time.Time
}

func (documentAuditLogTest) TableName() string { return "audit_logs" }

// 下面两个表只用于让仓储 SQL 在 sqlite 上可执行，字段与真实迁移保持同名字段。
type documentGroupTest struct {
	ID          uint64 `gorm:"primaryKey;autoIncrement"`
	Name        string `gorm:"size:191"`
	Status      string `gorm:"size:16"`
	OwnerUserID uint64
	CreatedBy   uint64
	CreatedAt   time.Time
	UpdatedAt   time.Time
}

func (documentGroupTest) TableName() string { return "groups" }

type documentMembershipTest struct {
	ID         uint64 `gorm:"primaryKey;autoIncrement"`
	GroupID    uint64
	UserID     uint64
	MemberType string `gorm:"size:16"`
	Status     string `gorm:"size:16"`
}

func (documentMembershipTest) TableName() string { return "memberships" }

func openDocumentTestDB(t *testing.T) *gorm.DB {
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
		&identity.User{}, &documentGroupTest{}, &documentMembershipTest{},
		&Document{}, &Party{}, &Item{}, &idempotencyRecord{}, &documentAuditLogTest{},
	}
	if err := db.AutoMigrate(models...); err != nil {
		t.Fatalf("migrate: %v", err)
	}
	return db
}

type documentFixture struct {
	groupID  uint64
	ownerID  uint64
	memberID uint64
}

func seedDocumentFixture(t *testing.T, db *gorm.DB) documentFixture {
	t.Helper()
	now := time.Date(2026, time.September, 1, 0, 0, 0, 0, time.UTC)
	owner := identity.User{Username: "owner-doc", DisplayName: "主账号", AccountType: identity.AccountTypeGroupOwner,
		Status: identity.UserStatusActive, PasswordHash: "x", CreatedAt: now, UpdatedAt: now}
	if err := db.Create(&owner).Error; err != nil {
		t.Fatalf("create owner: %v", err)
	}
	member := identity.User{Username: "member-doc", DisplayName: "王业务", AccountType: identity.AccountTypeMember,
		Status: identity.UserStatusActive, PasswordHash: "x", CreatedAt: now, UpdatedAt: now}
	if err := db.Create(&member).Error; err != nil {
		t.Fatalf("create member: %v", err)
	}
	group := documentGroupTest{Name: "钢铁一组", Status: "active", OwnerUserID: owner.ID, CreatedBy: owner.ID, CreatedAt: now, UpdatedAt: now}
	if err := db.Create(&group).Error; err != nil {
		t.Fatalf("create group: %v", err)
	}
	memberships := []documentMembershipTest{
		{GroupID: group.ID, UserID: owner.ID, MemberType: "owner", Status: "active"},
		{GroupID: group.ID, UserID: member.ID, MemberType: "member", Status: "active"},
	}
	if err := db.Create(&memberships).Error; err != nil {
		t.Fatalf("create memberships: %v", err)
	}
	return documentFixture{groupID: group.ID, ownerID: owner.ID, memberID: member.ID}
}

func mustCreateInbound(t *testing.T, repo Repository, fixture documentFixture, date string, idempotencyKey string) Document {
	t.Helper()
	businessDate, err := parseBusinessDate(date)
	if err != nil {
		t.Fatalf("parseBusinessDate(%q) error = %v", date, err)
	}
	amount := money.Mul(p("1800.00"), q("40"))
	document, _, err := repo.CreateDocument(context.Background(), CreateInput{
		GroupID: fixture.groupID, Kind: KindInbound, Status: StatusDraft,
		BusinessUserID: fixture.memberID, BusinessDate: businessDate,
		TotalAmount: amount, OperatorUserID: fixture.ownerID, Now: time.Now().UTC(),
		Parties: []PartyDraft{{
			Position: 1, PartyName: "鑫源钢贸有限公司", ContactPhone: nil, Subtotal: amount,
			Items: []ItemDraft{{
				Position: 1, ProductName: "螺纹钢", ProductModel: textPointer("HRB400 Φ20"), Unit: textPointer("吨"),
				Quantity: q("40"), Weight: quantityPointer("40.20"), UnitPrice: p("1800.00"),
				PriceTaxMode: PriceTaxIncluded, Amount: amount,
			}},
		}},
		IdempotencyScope: "document.inbound.create", IdempotencyKey: idempotencyKey,
		RequestFingerprint: "fingerprint-" + idempotencyKey, AuditAction: "document.created", AuditSummary: "已创建",
	})
	if err != nil {
		t.Fatalf("CreateDocument() error = %v", err)
	}
	return document
}

func quantityPointer(raw string) *money.Quantity {
	value := q(raw)
	return &value
}

/* ------------------------------------------------------------------ 用例 */

func TestRepositoryCreateGeneratesDailySequenceAndLoadsDetail(t *testing.T) {
	db := openDocumentTestDB(t)
	fixture := seedDocumentFixture(t, db)
	repo := NewRepository(db)
	ctx := context.Background()

	first := mustCreateInbound(t, repo, fixture, "2026-09-22", "")
	if first.DocumentNo != "RK20260922-0001" {
		t.Fatalf("first document no = %q", first.DocumentNo)
	}
	second := mustCreateInbound(t, repo, fixture, "2026-09-22", "")
	if second.DocumentNo != "RK20260922-0002" {
		t.Fatalf("second document no = %q, want RK20260922-0002", second.DocumentNo)
	}
	// 换一天重新从 0001 开始。
	otherDay := mustCreateInbound(t, repo, fixture, "2026-09-23", "")
	if otherDay.DocumentNo != "RK20260923-0001" {
		t.Fatalf("other day document no = %q", otherDay.DocumentNo)
	}

	detail, err := repo.LoadDetail(ctx, fixture.groupID, KindInbound, first.ID)
	if err != nil {
		t.Fatalf("LoadDetail() error = %v", err)
	}
	if len(detail.Parties) != 1 || len(detail.Parties[0].Items) != 1 {
		t.Fatalf("detail = %+v", detail)
	}
	item := detail.Parties[0].Items[0]
	// DECIMAL 列在 sqlite 上会以 REAL 落库，这里顺带验证定点类型的 Scan 无损。
	if item.Amount != a("72000.00") || item.UnitPrice != p("1800.00") || item.Quantity != q("40") {
		t.Fatalf("item = %+v", item)
	}
	if item.Weight == nil || *item.Weight != q("40.20") {
		t.Fatalf("weight = %v", item.Weight)
	}
	if item.PriceTaxMode != PriceTaxIncluded {
		t.Fatalf("price tax mode = %q", item.PriceTaxMode)
	}
	if detail.Document.TotalAmount != a("72000.00") {
		t.Fatalf("total = %s", detail.Document.TotalAmount)
	}

	// 出库单必须有独立的单号序列，不能和入库单共用。
	outboundDate, _ := parseBusinessDate("2026-09-22")
	outbound, _, err := repo.CreateDocument(ctx, CreateInput{
		GroupID: fixture.groupID, Kind: KindOutbound, Status: StatusDraft,
		BusinessUserID: fixture.memberID, BusinessDate: outboundDate,
		ShippingUnit: textPointer("一号库"), SaleAmountType: saleTypePointer(SaleAmountVATSpecial),
		TotalAmount: a("45200.00"), OperatorUserID: fixture.ownerID, Now: time.Now().UTC(),
		Parties: []PartyDraft{{Position: 1, PartyName: "宏达建筑", ContactPhone: textPointer("13911112222"), Subtotal: a("45200.00"),
			Items: []ItemDraft{{Position: 1, ProductName: "螺纹钢", Quantity: q("20"), UnitPrice: p("2260.00"),
				PriceTaxMode: PriceTaxIncluded, Amount: a("45200.00")}}}},
		AuditAction: "document.created", AuditSummary: "已创建",
	})
	if err != nil {
		t.Fatalf("CreateDocument(outbound) error = %v", err)
	}
	if outbound.DocumentNo != "CK20260922-0001" {
		t.Fatalf("outbound document no = %q", outbound.DocumentNo)
	}
	if _, err := repo.FindDocument(ctx, fixture.groupID, KindInbound, outbound.ID); !errors.Is(err, ErrNotFound) {
		t.Fatalf("cross-kind lookup error = %v, want ErrNotFound", err)
	}

	// 审计日志必须落库，且带上单号。
	var audit documentAuditLogTest
	if err := db.Where("action = ?", "document.created").Order("id ASC").Take(&audit).Error; err != nil {
		t.Fatalf("load audit: %v", err)
	}
	if !strings.Contains(audit.Summary, "入库单 RK20260922-0001") {
		t.Fatalf("audit summary = %q", audit.Summary)
	}
	if audit.ResourceID != fmt.Sprintf("%d", first.ID) {
		t.Fatalf("audit resource id = %q", audit.ResourceID)
	}
}

func TestRepositoryIdempotentCreateReplaysSameDocument(t *testing.T) {
	db := openDocumentTestDB(t)
	fixture := seedDocumentFixture(t, db)
	repo := NewRepository(db)
	ctx := context.Background()

	first := mustCreateInbound(t, repo, fixture, "2026-09-22", "queue-key-1")
	replayed, hit, err := repo.CreateDocument(ctx, CreateInput{
		GroupID: fixture.groupID, Kind: KindInbound, Status: StatusDraft,
		BusinessUserID: fixture.memberID, BusinessDate: first.BusinessDate,
		TotalAmount: a("72000.00"), OperatorUserID: fixture.ownerID, Now: time.Now().UTC(),
		Parties: []PartyDraft{{Position: 1, PartyName: "鑫源钢贸有限公司", Subtotal: a("72000.00"),
			Items: []ItemDraft{{Position: 1, ProductName: "螺纹钢", Quantity: q("40"), UnitPrice: p("1800.00"),
				PriceTaxMode: PriceTaxIncluded, Amount: a("72000.00")}}}},
		IdempotencyScope: "document.inbound.create", IdempotencyKey: "queue-key-1",
		RequestFingerprint: "fingerprint-queue-key-1", AuditAction: "document.created", AuditSummary: "已创建",
	})
	if err != nil {
		t.Fatalf("replay error = %v", err)
	}
	if !hit || replayed.ID != first.ID {
		t.Fatalf("replay = %d/%v, want document %d", replayed.ID, hit, first.ID)
	}

	var count int64
	if err := db.Model(&Document{}).Count(&count).Error; err != nil {
		t.Fatalf("count: %v", err)
	}
	if count != 1 {
		t.Fatalf("documents = %d, want 1", count)
	}

	// 同一个幂等键配不同内容必须报错。
	_, _, err = repo.CreateDocument(ctx, CreateInput{
		GroupID: fixture.groupID, Kind: KindInbound, Status: StatusDraft,
		BusinessUserID: fixture.memberID, BusinessDate: first.BusinessDate,
		TotalAmount: a("1.00"), OperatorUserID: fixture.ownerID, Now: time.Now().UTC(),
		Parties: []PartyDraft{{Position: 1, PartyName: "另一家公司", Subtotal: a("1.00"),
			Items: []ItemDraft{{Position: 1, ProductName: "圆钢", Quantity: q("1"), UnitPrice: p("1.00"),
				PriceTaxMode: PriceTaxIncluded, Amount: a("1.00")}}}},
		IdempotencyScope: "document.inbound.create", IdempotencyKey: "queue-key-1",
		RequestFingerprint: "different-fingerprint",
	})
	if !errors.Is(err, ErrIdempotencyMismatch) {
		t.Fatalf("mismatched replay error = %v, want ErrIdempotencyMismatch", err)
	}
}

func TestRepositoryReplaceAndStatusTransitions(t *testing.T) {
	db := openDocumentTestDB(t)
	fixture := seedDocumentFixture(t, db)
	repo := NewRepository(db)
	ctx := context.Background()

	document := mustCreateInbound(t, repo, fixture, "2026-09-22", "")
	now := time.Now().UTC()

	updated, err := repo.ReplaceDocument(ctx, UpdateInput{
		GroupID: fixture.groupID, Kind: KindInbound, DocumentID: document.ID, ExpectedVersion: document.Version,
		Status: StatusDraft, BusinessUserID: fixture.memberID, BusinessDate: document.BusinessDate,
		TotalAmount: a("50731.08"), OperatorUserID: fixture.ownerID, Now: now,
		Parties: []PartyDraft{{
			Position: 1, PartyName: "昌盛金属材料有限公司", Subtotal: a("50731.08"),
			Items: []ItemDraft{{Position: 1, ProductName: "热轧卷板", Quantity: q("17.05"), UnitPrice: p("2975.43"),
				PriceTaxMode: PriceTaxIncluded, Amount: a("50731.08")}},
		}},
		AuditSummary: "已修改",
	})
	if err != nil {
		t.Fatalf("ReplaceDocument() error = %v", err)
	}
	if updated.Version != document.Version+1 {
		t.Fatalf("version = %d, want %d", updated.Version, document.Version+1)
	}

	// 明细必须被整体替换，不能残留旧行。
	detail, err := repo.LoadDetail(ctx, fixture.groupID, KindInbound, document.ID)
	if err != nil {
		t.Fatalf("LoadDetail() error = %v", err)
	}
	if len(detail.Parties) != 1 || detail.Parties[0].PartyName != "昌盛金属材料有限公司" {
		t.Fatalf("parties after replace = %+v", detail.Parties)
	}
	var itemCount int64
	if err := db.Model(&Item{}).Where("document_id = ?", document.ID).Count(&itemCount).Error; err != nil {
		t.Fatalf("count items: %v", err)
	}
	if itemCount != 1 {
		t.Fatalf("items after replace = %d, want 1", itemCount)
	}

	// 版本不匹配必须报冲突。
	_, err = repo.ReplaceDocument(ctx, UpdateInput{
		GroupID: fixture.groupID, Kind: KindInbound, DocumentID: document.ID, ExpectedVersion: document.Version,
		Status: StatusDraft, BusinessUserID: fixture.memberID, BusinessDate: document.BusinessDate,
		OperatorUserID: fixture.ownerID, Now: now,
		Parties: []PartyDraft{{Position: 1, PartyName: "昌盛金属材料有限公司", Subtotal: a("50731.08"),
			Items: []ItemDraft{{Position: 1, ProductName: "热轧卷板", Quantity: q("17.05"), UnitPrice: p("2975.43"),
				PriceTaxMode: PriceTaxIncluded, Amount: a("50731.08")}}}},
	})
	if !errors.Is(err, ErrVersionConflict) {
		t.Fatalf("stale replace error = %v, want ErrVersionConflict", err)
	}

	submitted, err := repo.ChangeStatus(ctx, StatusInput{
		GroupID: fixture.groupID, Kind: KindInbound, DocumentID: document.ID, OperatorUserID: fixture.ownerID,
		ExpectedVersion: updated.Version, Status: StatusSubmitted, Now: now,
		AuditAction: "document.submitted", AuditSummary: "已提交",
	})
	if err != nil {
		t.Fatalf("ChangeStatus() error = %v", err)
	}
	if submitted.Status != StatusSubmitted || submitted.SubmittedAt == nil {
		t.Fatalf("submitted = %+v", submitted)
	}
	// 同状态重复提交返回状态冲突而不是静默成功。
	_, err = repo.ChangeStatus(ctx, StatusInput{
		GroupID: fixture.groupID, Kind: KindInbound, DocumentID: document.ID, OperatorUserID: fixture.ownerID,
		ExpectedVersion: submitted.Version, Status: StatusSubmitted, Now: now,
	})
	if !errors.Is(err, ErrStatusInvalid) {
		t.Fatalf("duplicate submit error = %v, want ErrStatusInvalid", err)
	}
	if _, err := repo.ChangeStatus(ctx, StatusInput{
		GroupID: fixture.groupID, Kind: KindInbound, DocumentID: document.ID, OperatorUserID: fixture.ownerID,
		ExpectedVersion: submitted.Version, Status: StatusVoided, Now: now,
		AuditAction: "document.voided", AuditSummary: "已作废",
	}); err != nil {
		t.Fatalf("void error = %v", err)
	}
	// 作废后不允许再修改。
	_, err = repo.ReplaceDocument(ctx, UpdateInput{
		GroupID: fixture.groupID, Kind: KindInbound, DocumentID: document.ID, ExpectedVersion: submitted.Version + 1,
		Status: StatusDraft, BusinessUserID: fixture.memberID, BusinessDate: document.BusinessDate,
		OperatorUserID: fixture.ownerID, Now: now,
		Parties: []PartyDraft{{Position: 1, PartyName: "昌盛金属材料有限公司", Subtotal: a("1.00"),
			Items: []ItemDraft{{Position: 1, ProductName: "热轧卷板", Quantity: q("1"), UnitPrice: p("1.00"),
				PriceTaxMode: PriceTaxIncluded, Amount: a("1.00")}}}},
	})
	if !errors.Is(err, ErrStatusInvalid) {
		t.Fatalf("voided replace error = %v, want ErrStatusInvalid", err)
	}
}

func TestRepositoryListFiltersAndSummaries(t *testing.T) {
	db := openDocumentTestDB(t)
	fixture := seedDocumentFixture(t, db)
	repo := NewRepository(db)
	ctx := context.Background()

	sep := mustCreateInbound(t, repo, fixture, "2026-09-22", "")
	august := mustCreateInbound(t, repo, fixture, "2026-08-10", "")
	if august.DocumentNo != "RK20260810-0001" {
		t.Fatalf("august document no = %q", august.DocumentNo)
	}
	// 把 8 月单据作废，验证金额统计会排除作废单据。
	now := time.Now().UTC()
	if _, err := repo.ChangeStatus(ctx, StatusInput{
		GroupID: fixture.groupID, Kind: KindInbound, DocumentID: august.ID, OperatorUserID: fixture.ownerID,
		ExpectedVersion: august.Version, Status: StatusVoided, Now: now,
		AuditAction: "document.voided", AuditSummary: "已作废",
	}); err != nil {
		t.Fatalf("void august: %v", err)
	}

	page, err := repo.ListDocuments(ctx, fixture.groupID, KindInbound, RepositoryQuery{Page: 1, PageSize: 20})
	if err != nil {
		t.Fatalf("ListDocuments() error = %v", err)
	}
	if page.Total != 2 || len(page.Items) != 2 {
		t.Fatalf("page = %+v", page)
	}
	// 默认按业务日期倒序。
	if page.Items[0].Document.ID != sep.ID {
		t.Fatalf("first item = %d, want %d", page.Items[0].Document.ID, sep.ID)
	}
	if len(page.Items[0].PartyNames) != 1 || page.Items[0].PartyNames[0] != "鑫源钢贸有限公司" {
		t.Fatalf("party names = %v", page.Items[0].PartyNames)
	}
	if page.Items[0].ItemCount != 1 {
		t.Fatalf("item count = %d", page.Items[0].ItemCount)
	}
	if page.Items[0].BusinessName != "王业务" {
		t.Fatalf("business name = %q", page.Items[0].BusinessName)
	}

	status := StatusVoided
	page, err = repo.ListDocuments(ctx, fixture.groupID, KindInbound, RepositoryQuery{Page: 1, PageSize: 20, Status: &status})
	if err != nil {
		t.Fatalf("ListDocuments(voided) error = %v", err)
	}
	if page.Total != 1 || page.Items[0].Document.ID != august.ID {
		t.Fatalf("voided page = %+v", page)
	}

	// 关键词同时匹配单号与往来单位名称。
	page, err = repo.ListDocuments(ctx, fixture.groupID, KindInbound, RepositoryQuery{Page: 1, PageSize: 20, Keyword: "鑫源"})
	if err != nil {
		t.Fatalf("ListDocuments(keyword) error = %v", err)
	}
	if page.Total != 2 {
		t.Fatalf("keyword page total = %d, want 2", page.Total)
	}
	page, err = repo.ListDocuments(ctx, fixture.groupID, KindInbound, RepositoryQuery{Page: 1, PageSize: 20, Keyword: "RK20260922"})
	if err != nil {
		t.Fatalf("ListDocuments(number) error = %v", err)
	}
	if page.Total != 1 || page.Items[0].Document.ID != sep.ID {
		t.Fatalf("number keyword page = %+v", page)
	}

	// 只统计 9 月：作废的 8 月单据既不计金额也不出现在往来单位聚合里。
	monthStart, _, err := parseMonthRange("2026-09")
	if err != nil {
		t.Fatalf("parseMonthRange error = %v", err)
	}
	totals, err := repo.MonthlyTotals(ctx, fixture.groupID, KindInbound, SummaryQuery{Month: monthStart, BucketSize: 10})
	if err != nil {
		t.Fatalf("MonthlyTotals() error = %v", err)
	}
	if totals.DocumentCount != 1 || totals.TotalAmount != a("72000.00") {
		t.Fatalf("totals = %+v", totals)
	}
	if totals.DraftCount != 1 || totals.SubmittedCnt != 0 || totals.VoidedCount != 0 {
		t.Fatalf("status counts = %+v", totals)
	}
	if len(totals.Parties) != 1 || totals.Parties[0].PartyName != "鑫源钢贸有限公司" || totals.Parties[0].TotalAmount != a("72000.00") {
		t.Fatalf("party totals = %+v", totals.Parties)
	}

	// 只统计本人单据时，业务员维度过滤生效。
	otherUserTotals, err := repo.MonthlyTotals(ctx, fixture.groupID, KindInbound, SummaryQuery{Month: monthStart, BucketSize: 10, OnlyBusinessUserID: fixture.ownerID})
	if err != nil {
		t.Fatalf("MonthlyTotals(only user) error = %v", err)
	}
	if otherUserTotals.DocumentCount != 0 {
		t.Fatalf("owner-focused totals = %+v", otherUserTotals)
	}
}

func TestRepositoryLookupsSupportService(t *testing.T) {
	db := openDocumentTestDB(t)
	fixture := seedDocumentFixture(t, db)
	repo := NewRepository(db)
	ctx := context.Background()

	users, err := repo.LoadUsers(ctx, []uint64{fixture.memberID, 9999})
	if err != nil {
		t.Fatalf("LoadUsers() error = %v", err)
	}
	if len(users) != 1 || users[fixture.memberID].DisplayName != "王业务" {
		t.Fatalf("users = %+v", users)
	}
	if users[fixture.memberID].AccountType != identity.AccountTypeMember {
		t.Fatalf("account type = %q", users[fixture.memberID].AccountType)
	}

	exists, err := repo.ActiveMemberExists(ctx, fixture.groupID, fixture.memberID)
	if err != nil || !exists {
		t.Fatalf("ActiveMemberExists(member) = %v, %v", exists, err)
	}
	if exists, err := repo.ActiveMemberExists(ctx, fixture.groupID, fixture.ownerID+100); err != nil || exists {
		t.Fatalf("ActiveMemberExists(unknown) = %v, %v", exists, err)
	}
	// 组隔离：其他组查不到本组成员。
	if exists, err := repo.ActiveMemberExists(ctx, fixture.groupID+1, fixture.memberID); err != nil || exists {
		t.Fatalf("ActiveMemberExists(other group) = %v, %v", exists, err)
	}
}
