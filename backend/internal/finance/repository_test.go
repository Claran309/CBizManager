package finance

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

// financeAuditLogTest 只用于让仓储里对 audit_logs 的写入在 sqlite 上可执行。
// 字段名与真实迁移一致，避免测试通过而生产 SQL 报错。
type financeAuditLogTest struct {
	ID             uint64 `gorm:"primaryKey;autoIncrement"`
	GroupID        *uint64
	OperatorUserID uint64
	Action         string
	ResourceType   string
	ResourceID     string
	Summary        string
	CreatedAt      time.Time
}

func (financeAuditLogTest) TableName() string { return "audit_logs" }

// openFinanceTestDB 打开一个进程内 sqlite 库并建好财务模块依赖的全部表。
//
// 这里刻意用「内存库 + 单连接」：GORM 的链式查询与事务在同一连接上才可预期，
// 多连接的内存库会各自看到不同的数据库。
func openFinanceTestDB(t *testing.T) *gorm.DB {
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
		&identity.User{}, &document.Document{}, &document.Party{},
		&Record{}, &idempotencyRecord{}, &financeAuditLogTest{},
	}
	if err := db.AutoMigrate(models...); err != nil {
		t.Fatalf("migrate: %v", err)
	}
	return db
}

type financeFixture struct {
	db           *gorm.DB
	repo         Repository
	groupID      uint64
	otherGroupID uint64
}

func newFinanceFixture(t *testing.T) financeFixture {
	t.Helper()
	db := openFinanceTestDB(t)
	return financeFixture{db: db, repo: NewRepository(db), groupID: testGroupID, otherGroupID: 4}
}

func (f financeFixture) insertUser(t *testing.T, id uint64, name string) {
	t.Helper()
	record := identity.User{
		ID: id, Username: fmt.Sprintf("user%d", id), PasswordHash: "x", DisplayName: name,
		AccountType: identity.AccountTypeMember, Status: "active",
	}
	if err := f.db.Create(&record).Error; err != nil {
		t.Fatalf("insert user: %v", err)
	}
}

func (f financeFixture) insertDocument(t *testing.T, id, groupID uint64, kind document.Kind, no string, amount money.Amount, status document.Status) {
	t.Helper()
	record := document.Document{
		ID: id, GroupID: groupID, Kind: kind, DocumentNo: no, Status: status,
		BusinessUserID: testUserID, BusinessDate: businessDay,
		TotalAmount: amount, Version: 1, CreatedBy: testUserID, UpdatedBy: testUserID,
	}
	if err := f.db.Create(&record).Error; err != nil {
		t.Fatalf("insert document: %v", err)
	}
}

// insertParty 插入往来单位；position 用来验证「取第一个往来单位名称」的口径。
func (f financeFixture) insertParty(t *testing.T, groupID, documentID uint64, position int, name string) {
	t.Helper()
	record := document.Party{
		GroupID: groupID, DocumentID: documentID, Position: position,
		PartyName: name, Subtotal: money.AmountFromYuan(10),
	}
	if err := f.db.Create(&record).Error; err != nil {
		t.Fatalf("insert party: %v", err)
	}
}

// recordInput 生成一份最小可用的登记入参；金额、日期等由调用方覆盖。
func (f financeFixture) recordInput(documentID uint64, documentKind document.Kind, kind Kind, amount money.Amount) CreateInput {
	return CreateInput{
		GroupID: f.groupID, DocumentID: documentID, DocumentKind: documentKind,
		DocumentNo: fmt.Sprintf("RK20260922-%04d", documentID), PartyName: "唐山钢铁",
		BusinessUserID: testUserID, BusinessDate: businessDay,
		Kind: kind, Amount: amount, OccurredOn: businessDay,
		OperatorUserID: testUserID, Now: fixedNow,
		AuditAction: auditAction(kind, auditVerbRecorded), AuditSummary: "测试摘要",
	}
}

func (f financeFixture) recordCount(t *testing.T, documentID uint64) int64 {
	t.Helper()
	var total int64
	if err := f.db.Model(&Record{}).Where("document_id = ?", documentID).Count(&total).Error; err != nil {
		t.Fatalf("count records: %v", err)
	}
	return total
}

func wantSentinel(t *testing.T, err error, want error) {
	t.Helper()
	if !errors.Is(err, want) {
		t.Fatalf("error = %v, want %v", err, want)
	}
}

/* ------------------------------------------------------------------ 登记：快照、复检与累计上限 */

func TestCreateRecordSnapshotsAndEnforcesCeiling(t *testing.T) {
	fixture := newFinanceFixture(t)
	fixture.insertUser(t, testUserID, "王业务")
	fixture.insertDocument(t, 11, fixture.groupID, document.KindInbound, "RK20260922-0011", money.AmountFromYuan(100), document.StatusSubmitted)

	created, err := fixture.repo.CreateRecord(context.Background(), fixture.recordInput(11, document.KindInbound, KindPayment, money.AmountFromYuan(60)))
	if err != nil {
		t.Fatalf("CreateRecord() error = %v", err)
	}
	if created.ID == 0 || created.DocumentNo != "RK20260922-0011" || created.PartyName != "唐山钢铁" {
		t.Fatalf("记录未落单据快照: %+v", created)
	}
	// 时间戳必须来自注入时钟，否则跨月/跨日场景下审计时间与业务日期会错位。
	if !created.CreatedAt.Equal(fixedNow) {
		t.Fatalf("created_at = %s, want %s", created.CreatedAt, fixedNow)
	}
	if !created.OccurredOn.Equal(businessDay) || !created.BusinessDate.Equal(businessDay) {
		t.Fatalf("日期快照 = %s / %s", created.OccurredOn, created.BusinessDate)
	}

	// 累计超过单据总额：必须被事务内的 SUM 校验拦下。
	_, err = fixture.repo.CreateRecord(context.Background(), fixture.recordInput(11, document.KindInbound, KindPayment, money.AmountFromYuan(50)))
	wantSentinel(t, err, ErrAmountExceeds)

	// 累计恰好等于总额允许。
	if _, err := fixture.repo.CreateRecord(context.Background(), fixture.recordInput(11, document.KindInbound, KindPayment, money.AmountFromYuan(40))); err != nil {
		t.Fatalf("累计恰好等于总额应当允许: %v", err)
	}
	// 已经付满后再多付 1 分同样要拒绝（说明校验看的是库里的实时合计）。
	_, err = fixture.repo.CreateRecord(context.Background(), fixture.recordInput(11, document.KindInbound, KindPayment, money.Amount(1)))
	wantSentinel(t, err, ErrAmountExceeds)
	if got := fixture.recordCount(t, 11); got != 2 {
		t.Fatalf("成功写入的记录数 = %d, want 2", got)
	}

	// 开票与付款的额度互相独立：付款付满不影响开票。
	if _, err := fixture.repo.CreateRecord(context.Background(), fixture.recordInput(11, document.KindInbound, KindInvoice, money.AmountFromYuan(100))); err != nil {
		t.Fatalf("开票额度应与付款额度独立: %v", err)
	}

	// 审计应该为三笔成功记录各写一条，动作形如 finance.payment.recorded。
	var audits []financeAuditLogTest
	if err := fixture.db.Where("resource_type = ?", "finance_record").Order("id ASC").Find(&audits).Error; err != nil {
		t.Fatalf("load audits: %v", err)
	}
	if len(audits) != 3 {
		t.Fatalf("审计条数 = %d, want 3", len(audits))
	}
	if audits[0].Action != "finance.payment.recorded" || audits[2].Action != "finance.invoice.recorded" {
		t.Fatalf("审计动作 = %s / %s", audits[0].Action, audits[2].Action)
	}
	if audits[0].ResourceID != "1" {
		t.Fatalf("审计资源 ID = %s, want 1", audits[0].ResourceID)
	}
}

func TestCreateRecordRechecksDocumentInsideTransaction(t *testing.T) {
	fixture := newFinanceFixture(t)
	fixture.insertUser(t, testUserID, "王业务")
	fixture.insertDocument(t, 11, fixture.groupID, document.KindInbound, "RK20260922-0011", money.AmountFromYuan(100), document.StatusDraft)
	fixture.insertDocument(t, 12, fixture.groupID, document.KindInbound, "RK20260922-0012", money.AmountFromYuan(100), document.StatusVoided)
	fixture.insertDocument(t, 13, fixture.groupID, document.KindOutbound, "CK20260922-0013", money.AmountFromYuan(100), document.StatusSubmitted)
	fixture.insertDocument(t, 21, fixture.otherGroupID, document.KindInbound, "RK20260922-0021", money.AmountFromYuan(100), document.StatusSubmitted)

	// 草稿与作废单据都不允许登记：即使服务层校验被并发改动作废，事务内复检也会兜住。
	for _, documentID := range []uint64{11, 12} {
		_, err := fixture.repo.CreateRecord(context.Background(), fixture.recordInput(documentID, document.KindInbound, KindPayment, money.AmountFromYuan(10)))
		wantSentinel(t, err, ErrDocumentStatusInvalid)
	}

	// 记录类型与单据类型必须配对：付款只挂入库单，所以给出库单登记付款要拒绝。
	// 这条校验必须由仓储兜住——挂错单据的记录不会出现在任何一个结清视图里
	// （出库单的结清视图只汇总收款），等于凭空丢了一笔钱。
	_, err := fixture.repo.CreateRecord(context.Background(), fixture.recordInput(13, document.KindOutbound, KindPayment, money.AmountFromYuan(10)))
	wantSentinel(t, err, ErrDocumentMismatch)

	// 出库单 + 开票同样不成立（开票只挂入库单）。
	_, err = fixture.repo.CreateRecord(context.Background(), fixture.recordInput(13, document.KindOutbound, KindInvoice, money.AmountFromYuan(10)))
	wantSentinel(t, err, ErrDocumentMismatch)

	// 合法配对（出库单 + 收款）必须能写入，避免把校验写成「一律拒绝」。
	if _, err := fixture.repo.CreateRecord(context.Background(), fixture.recordInput(13, document.KindOutbound, KindReceipt, money.AmountFromYuan(10))); err != nil {
		t.Fatalf("出库单登记收款应当成功: %v", err)
	}

	// 交易声明与库中类型不一致时同样拒绝（防止客户端伪造 document_kind 绕过校验）。
	_, err = fixture.repo.CreateRecord(context.Background(), fixture.recordInput(13, document.KindInbound, KindPayment, money.AmountFromYuan(10)))
	wantSentinel(t, err, ErrDocumentMismatch)

	// 其他组的单据对本组不可见，按「找不到」处理。
	_, err = fixture.repo.CreateRecord(context.Background(), fixture.recordInput(21, document.KindInbound, KindPayment, money.AmountFromYuan(10)))
	wantSentinel(t, err, ErrDocumentNotFound)
}

func TestCreateRecordIsIdempotentAndKeyIsReleasedOnRevoke(t *testing.T) {
	fixture := newFinanceFixture(t)
	fixture.insertUser(t, testUserID, "王业务")
	fixture.insertDocument(t, 11, fixture.groupID, document.KindInbound, "RK20260922-0011", money.AmountFromYuan(100), document.StatusSubmitted)

	input := fixture.recordInput(11, document.KindInbound, KindPayment, money.AmountFromYuan(30))
	input.IdempotencyScope = idempotencyScope(KindPayment)
	input.IdempotencyKey = "key-1"
	input.RequestFingerprint = "fp-1"

	first, err := fixture.repo.CreateRecord(context.Background(), input)
	if err != nil {
		t.Fatalf("首次登记失败: %v", err)
	}
	second, err := fixture.repo.CreateRecord(context.Background(), input)
	if err != nil {
		t.Fatalf("幂等重放应当成功: %v", err)
	}
	if first.ID != second.ID {
		t.Fatalf("幂等重放返回了不同的记录: %d / %d", first.ID, second.ID)
	}
	if got := fixture.recordCount(t, 11); got != 1 {
		t.Fatalf("幂等重放产生了重复记录，条数 = %d", got)
	}

	// 同一个键换了内容 = 客户端复用了幂等键，必须报错。
	reused := input
	reused.RequestFingerprint = "fp-2"
	_, err = fixture.repo.CreateRecord(context.Background(), reused)
	wantSentinel(t, err, ErrIdempotencyMismatch)

	// 撤销：硬删除记录并写审计。
	revoked, err := fixture.repo.RevokeRecord(context.Background(), RevokeInput{
		GroupID: fixture.groupID, RecordID: first.ID, OperatorUserID: testUserID, Now: fixedNow,
		AuditAction: auditAction(KindPayment, auditVerbRevoked), AuditSummary: "测试撤销",
	})
	if err != nil {
		t.Fatalf("RevokeRecord() error = %v", err)
	}
	if revoked.ID != first.ID || revoked.Amount != first.Amount {
		t.Fatalf("撤销返回的记录 = %+v", revoked)
	}
	if _, err := fixture.repo.FindRecord(context.Background(), fixture.groupID, first.ID); !errors.Is(err, ErrRecordNotFound) {
		t.Fatalf("撤销后记录应被物理删除，err = %v", err)
	}
	var audits []financeAuditLogTest
	if err := fixture.db.Where("action = ?", "finance.payment.revoked").Find(&audits).Error; err != nil {
		t.Fatalf("load audits: %v", err)
	}
	if len(audits) != 1 {
		t.Fatalf("撤销审计条数 = %d, want 1", len(audits))
	}

	// 幂等记录随记录一起释放：重放同一个键会重新登记，而不是读到已删除的记录。
	replayed, err := fixture.repo.CreateRecord(context.Background(), input)
	if err != nil {
		t.Fatalf("撤销后重放同一个幂等键应当重新登记: %v", err)
	}
	if replayed.ID == first.ID {
		t.Fatalf("撤销后重放应当是新的记录，id 仍为 %d", replayed.ID)
	}
	if got := fixture.recordCount(t, 11); got != 1 {
		t.Fatalf("撤销后重放后记录数 = %d, want 1", got)
	}

	// 撤销不存在的记录返回 ErrRecordNotFound。
	_, err = fixture.repo.RevokeRecord(context.Background(), RevokeInput{
		GroupID: fixture.groupID, RecordID: 9999, OperatorUserID: testUserID, Now: fixedNow,
		AuditAction: auditAction(KindPayment, auditVerbRevoked), AuditSummary: "测试撤销",
	})
	wantSentinel(t, err, ErrRecordNotFound)

	// 跨组撤销不可见：用其他组身份撤销本组记录同样按「找不到」处理。
	_, err = fixture.repo.RevokeRecord(context.Background(), RevokeInput{
		GroupID: fixture.otherGroupID, RecordID: replayed.ID, OperatorUserID: testUserID, Now: fixedNow,
		AuditAction: auditAction(KindPayment, auditVerbRevoked), AuditSummary: "测试撤销",
	})
	wantSentinel(t, err, ErrRecordNotFound)
}

/* ------------------------------------------------------------------ 读操作：单据、结清视图与用户 */

func TestLoadDocumentReturnsFirstPartyName(t *testing.T) {
	fixture := newFinanceFixture(t)
	fixture.insertUser(t, testUserID, "王业务")
	fixture.insertDocument(t, 11, fixture.groupID, document.KindInbound, "RK20260922-0011", money.AmountFromYuan(100), document.StatusSubmitted)
	// 一张单据可能有多个公司，财务侧只展示主往来单位（position 最小的那个）。
	fixture.insertParty(t, fixture.groupID, 11, 2, "天津物资")
	fixture.insertParty(t, fixture.groupID, 11, 1, "唐山钢铁")

	target, err := fixture.repo.LoadDocument(context.Background(), fixture.groupID, 11)
	if err != nil {
		t.Fatalf("LoadDocument() error = %v", err)
	}
	if target.PartyName != "唐山钢铁" {
		t.Fatalf("主往来单位 = %q", target.PartyName)
	}
	if target.TotalAmount != money.AmountFromYuan(100) || target.Status != document.StatusSubmitted {
		t.Fatalf("单据状态 = %+v", target)
	}

	// 跨组不可见。
	if _, err := fixture.repo.LoadDocument(context.Background(), fixture.otherGroupID, 11); !errors.Is(err, ErrDocumentNotFound) {
		t.Fatalf("跨组读取应返回 ErrDocumentNotFound，实际 %v", err)
	}
}

func TestLoadStatementOrdersRecordsAndListFilters(t *testing.T) {
	fixture := newFinanceFixture(t)
	fixture.insertUser(t, testUserID, "王业务")
	fixture.insertUser(t, testOtherID, "李业务")
	fixture.insertDocument(t, 11, fixture.groupID, document.KindInbound, "RK20260922-0011", money.AmountFromYuan(1000), document.StatusSubmitted)
	fixture.insertDocument(t, 12, fixture.groupID, document.KindOutbound, "CK20260922-0012", money.AmountFromYuan(1000), document.StatusSubmitted)
	fixture.insertDocument(t, 21, fixture.otherGroupID, document.KindInbound, "RK20260922-0021", money.AmountFromYuan(1000), document.StatusSubmitted)

	seed := func(documentID uint64, kind Kind, amount int64, occurredOn string, method Method, businessUser uint64) {
		t.Helper()
		input := fixture.recordInput(documentID, document.KindInbound, kind, money.AmountFromYuan(amount))
		if documentID == 12 {
			input.DocumentKind = document.KindOutbound
		}
		input.BusinessUserID = businessUser
		input.OccurredOn = parseTestDate(t, occurredOn)
		input.Method = &method
		if _, err := fixture.repo.CreateRecord(context.Background(), input); err != nil {
			t.Fatalf("预置记录失败: %v", err)
		}
	}
	seed(11, KindPayment, 100, "2026-09-10", MethodTransfer, testUserID)
	seed(11, KindPayment, 200, "2026-09-12", MethodPublicAccount, testUserID)
	seed(11, KindInvoice, 300, "2026-09-12", MethodTransfer, testUserID)
	seed(12, KindReceipt, 400, "2026-09-15", MethodPrivateCard, testOtherID)

	// 结清视图按发生日期、ID 升序返回明细，客户端可以直接顺序渲染流水。
	statement, err := fixture.repo.LoadStatement(context.Background(), fixture.groupID, 11)
	if err != nil {
		t.Fatalf("LoadStatement() error = %v", err)
	}
	if len(statement.Records) != 3 {
		t.Fatalf("明细条数 = %d, want 3", len(statement.Records))
	}
	if statement.Records[0].Amount != money.AmountFromYuan(100) || statement.Records[2].Kind != KindInvoice {
		t.Fatalf("明细顺序 = %+v", statement.Records)
	}

	// 列表：本组 + 本类型，其他组与其他类型都不能混进来。
	// assertList 同时校验「当前页条数」与「匹配总数」：分页时两者不相等，
	// 只校验其中一个会把「分页失效」这类问题放过去。
	assertList := func(t *testing.T, query RepositoryQuery, wantItems, wantTotal int) Page {
		t.Helper()
		page, err := fixture.repo.ListRecords(context.Background(), fixture.groupID, query)
		if err != nil {
			t.Fatalf("ListRecords() error = %v", err)
		}
		if len(page.Items) != wantItems || page.Total != int64(wantTotal) {
			t.Fatalf("列表结果 = %d 条（total=%d），want %d 条（total=%d）",
				len(page.Items), page.Total, wantItems, wantTotal)
		}
		return page
	}

	assertList(t, RepositoryQuery{Kind: KindPayment, Page: 1, PageSize: 20}, 2, 2)
	assertList(t, RepositoryQuery{Kind: KindReceipt, Page: 1, PageSize: 20}, 1, 1)
	assertList(t, RepositoryQuery{Kind: KindInvoice, Page: 1, PageSize: 20}, 1, 1)

	// 按单据过滤。
	assertList(t, RepositoryQuery{Kind: KindPayment, DocumentID: 11, Page: 1, PageSize: 20}, 2, 2)

	// 按方式过滤。
	transfer := MethodTransfer
	assertList(t, RepositoryQuery{Kind: KindPayment, Method: &transfer, Page: 1, PageSize: 20}, 1, 1)

	// 按业务员过滤（显式指定）。
	otherBusinessUser := testOtherID
	assertList(t, RepositoryQuery{Kind: KindReceipt, BusinessUserID: &otherBusinessUser, Page: 1, PageSize: 20}, 1, 1)

	// 按业务员收敛（子账号只看本人）。
	assertList(t, RepositoryQuery{Kind: KindReceipt, OnlyBusinessUserID: testUserID, Page: 1, PageSize: 20}, 0, 0)
	assertList(t, RepositoryQuery{Kind: KindPayment, OnlyBusinessUserID: testUserID, Page: 1, PageSize: 20}, 2, 2)

	// 日期区间是左闭右开：9-12 到 9-13 只包含 9-12 的两条付款与一条开票中的付款。
	from := parseTestDate(t, "2026-09-12")
	to := parseTestDate(t, "2026-09-13")
	assertList(t, RepositoryQuery{Kind: KindPayment, OccurredFrom: &from, OccurredTo: &to, Page: 1, PageSize: 20}, 1, 1)

	// 关键词同时匹配单号与往来单位。
	assertList(t, RepositoryQuery{Kind: KindPayment, Keyword: "RK20260922", Page: 1, PageSize: 20}, 2, 2)
	assertList(t, RepositoryQuery{Kind: KindPayment, Keyword: "唐山", Page: 1, PageSize: 20}, 2, 2)
	assertList(t, RepositoryQuery{Kind: KindPayment, Keyword: "不存在的单号", Page: 1, PageSize: 20}, 0, 0)

	// 分页：第 1 页 1 条、第 2 页 1 条，按发生日期倒序（9-12 在前）；总数始终是 2。
	firstPage := assertList(t, RepositoryQuery{Kind: KindPayment, Page: 1, PageSize: 1}, 1, 2)
	if firstPage.Items[0].Record.Amount != money.AmountFromYuan(200) {
		t.Fatalf("分页首行金额 = %s, want 200.00", firstPage.Items[0].Record.Amount)
	}
	secondPage := assertList(t, RepositoryQuery{Kind: KindPayment, Page: 2, PageSize: 1}, 1, 2)
	if secondPage.Items[0].Record.Amount != money.AmountFromYuan(100) {
		t.Fatalf("分页次行金额 = %s, want 100.00", secondPage.Items[0].Record.Amount)
	}

	// 结清视图跨组不可见。
	if _, err := fixture.repo.LoadStatement(context.Background(), fixture.otherGroupID, 11); !errors.Is(err, ErrDocumentNotFound) {
		t.Fatalf("跨组读取结清视图应返回 ErrDocumentNotFound，实际 %v", err)
	}
}

func TestFindAndLoadUsers(t *testing.T) {
	fixture := newFinanceFixture(t)
	fixture.insertUser(t, testUserID, "王业务")
	fixture.insertDocument(t, 11, fixture.groupID, document.KindInbound, "RK20260922-0011", money.AmountFromYuan(100), document.StatusSubmitted)

	created, err := fixture.repo.CreateRecord(context.Background(), fixture.recordInput(11, document.KindInbound, KindPayment, money.AmountFromYuan(30)))
	if err != nil {
		t.Fatalf("CreateRecord() error = %v", err)
	}

	found, err := fixture.repo.FindRecord(context.Background(), fixture.groupID, created.ID)
	if err != nil {
		t.Fatalf("FindRecord() error = %v", err)
	}
	if found.ID != created.ID {
		t.Fatalf("FindRecord 返回 %d, want %d", found.ID, created.ID)
	}
	if _, err := fixture.repo.FindRecord(context.Background(), fixture.otherGroupID, created.ID); !errors.Is(err, ErrRecordNotFound) {
		t.Fatalf("跨组读取记录应返回 ErrRecordNotFound，实际 %v", err)
	}

	users, err := fixture.repo.LoadUsers(context.Background(), []uint64{testUserID, 9999})
	if err != nil {
		t.Fatalf("LoadUsers() error = %v", err)
	}
	if users[testUserID].DisplayName != "王业务" || users[testUserID].AccountType != identity.AccountTypeMember {
		t.Fatalf("用户摘要 = %+v", users[testUserID])
	}
	// 已注销用户查不到时不能报错，交给服务层回填 ID 保证界面仍能显示「谁」。
	if _, ok := users[9999]; ok {
		t.Fatalf("不存在的用户不应出现在结果里: %+v", users)
	}
	if _, err := fixture.repo.LoadUsers(context.Background(), nil); err != nil {
		t.Fatalf("LoadUsers(nil) error = %v", err)
	}
}

// parseTestDate 把 "2026-09-10" 解析成 UTC 零点，避免测试里散落手写的时间构造。
func parseTestDate(t *testing.T, raw string) time.Time {
	t.Helper()
	parsed, err := time.Parse("2006-01-02", raw)
	if err != nil {
		t.Fatalf("解析测试日期 %q: %v", raw, err)
	}
	return parsed
}
