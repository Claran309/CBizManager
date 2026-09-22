package finance

import (
	"context"
	"errors"
	"fmt"
	"sort"
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

// fixedNow 固定「当前时间」，让记录时间与审计时间在断言里可预期。
var fixedNow = time.Date(2026, time.September, 22, 10, 30, 0, 0, time.UTC)

// businessDay 是测试用的业务日期（零点，与写入 DATE 列后的回读值一致）。
var businessDay = time.Date(2026, time.September, 22, 0, 0, 0, 0, time.UTC)

// 测试用的固定标识：组 3，业务员 7（本人）与 8（他人）。
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

type idempotencyEntry struct {
	fingerprint string
	recordID    uint64
}

// fakeRepository 用内存结构模拟财务仓储，便于在无数据库环境下覆盖业务规则。
//
// 注意：内存桩不做组隔离（TargetDocument 没有 group 字段），组间隔离由仓储层
// 的 SQL 条件与 integration 测试负责，这里只验证服务层的规则。
type fakeRepository struct {
	mu           sync.Mutex
	nextRecordID uint64
	records      map[uint64]*Record
	documents    map[uint64]TargetDocument
	users        map[uint64]identity.UserSummary
	idempotency  map[string]idempotencyEntry
	audits       []auditEntry

	createErr    error
	revokeErr    error
	findErr      error
	listErr      error
	documentErr  error
	statementErr error
	usersErr     error

	createCalls int
	lastCreate  CreateInput
	lastRevoke  RevokeInput
	lastQuery   RepositoryQuery
}

func newFakeRepository() *fakeRepository {
	return &fakeRepository{
		nextRecordID: 1,
		records:      make(map[uint64]*Record),
		documents:    make(map[uint64]TargetDocument),
		users:        make(map[uint64]identity.UserSummary),
		idempotency:  make(map[string]idempotencyEntry),
	}
}

func (r *fakeRepository) seedUser(userID uint64, displayName string) {
	r.users[userID] = identity.UserSummary{
		ID: userID, Username: fmt.Sprintf("user%d", userID), DisplayName: displayName,
		AccountType: identity.AccountTypeMember,
	}
}

// seedRecord 直接写入一条记录，用于构造「他人记录」这类不便通过 Create 得到的场景。
func (r *fakeRepository) seedRecord(record Record) Record {
	r.mu.Lock()
	defer r.mu.Unlock()
	record.ID = r.nextRecordID
	r.nextRecordID++
	r.records[record.ID] = &record
	return record
}

func (r *fakeRepository) idempotencyKey(scope, key string) string { return scope + "|" + key }

func (r *fakeRepository) CreateRecord(_ context.Context, input CreateInput) (Record, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.createCalls++
	r.lastCreate = input
	if r.createErr != nil {
		return Record{}, r.createErr
	}

	// 1) 幂等重放：同一个键且内容指纹一致，直接返回首次写入的记录。
	if input.IdempotencyKey != "" {
		if entry, ok := r.idempotency[r.idempotencyKey(input.IdempotencyScope, input.IdempotencyKey)]; ok {
			if entry.fingerprint != input.RequestFingerprint {
				return Record{}, ErrIdempotencyMismatch
			}
			return *r.records[entry.recordID], nil
		}
	}

	// 2) 事务内复检单据类型与状态。
	target, ok := r.documents[input.DocumentID]
	if !ok {
		return Record{}, ErrDocumentNotFound
	}
	if target.Kind != input.DocumentKind {
		return Record{}, ErrDocumentMismatch
	}
	if target.Status != document.StatusSubmitted {
		return Record{}, ErrDocumentStatusInvalid
	}

	// 3) 累计上限：已有的同类记录合计 + 本次金额不得超过单据总额。
	var accumulated money.Amount
	for _, record := range r.records {
		if record.DocumentID == input.DocumentID && record.Kind == input.Kind {
			accumulated = accumulated.Add(record.Amount)
		}
	}
	if accumulated.Add(input.Amount) > target.TotalAmount {
		return Record{}, ErrAmountExceeds
	}

	record := Record{
		GroupID: input.GroupID, DocumentID: input.DocumentID, DocumentKind: input.DocumentKind,
		DocumentNo: input.DocumentNo, PartyName: input.PartyName,
		BusinessUserID: input.BusinessUserID, BusinessDate: input.BusinessDate,
		Kind: input.Kind, Amount: input.Amount, OccurredOn: input.OccurredOn,
		Method: input.Method, MethodNote: input.MethodNote, CardTail: input.CardTail,
		InvoiceNo: input.InvoiceNo, Remark: input.Remark,
		CreatedBy: input.OperatorUserID, CreatedAt: input.Now,
	}
	record.ID = r.nextRecordID
	r.nextRecordID++
	r.records[record.ID] = &record
	if input.IdempotencyKey != "" {
		r.idempotency[r.idempotencyKey(input.IdempotencyScope, input.IdempotencyKey)] = idempotencyEntry{
			fingerprint: input.RequestFingerprint, recordID: record.ID,
		}
	}
	r.audits = append(r.audits, auditEntry{action: input.AuditAction, summary: input.AuditSummary})
	return record, nil
}

func (r *fakeRepository) RevokeRecord(_ context.Context, input RevokeInput) (Record, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.lastRevoke = input
	if r.revokeErr != nil {
		return Record{}, r.revokeErr
	}
	record, ok := r.records[input.RecordID]
	if !ok {
		return Record{}, ErrRecordNotFound
	}
	delete(r.records, input.RecordID)
	r.audits = append(r.audits, auditEntry{action: input.AuditAction, summary: input.AuditSummary})
	return *record, nil
}

func (r *fakeRepository) FindRecord(_ context.Context, _, recordID uint64) (Record, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.findErr != nil {
		return Record{}, r.findErr
	}
	record, ok := r.records[recordID]
	if !ok {
		return Record{}, ErrRecordNotFound
	}
	return *record, nil
}

func (r *fakeRepository) ListRecords(_ context.Context, _ uint64, query RepositoryQuery) (Page, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.lastQuery = query
	if r.listErr != nil {
		return Page{}, r.listErr
	}
	matched := make([]Record, 0, len(r.records))
	for _, record := range r.records {
		if record.Kind != query.Kind {
			continue
		}
		if query.DocumentID != 0 && record.DocumentID != query.DocumentID {
			continue
		}
		if query.Method != nil && (record.Method == nil || *record.Method != *query.Method) {
			continue
		}
		if query.OnlyBusinessUserID != 0 && record.BusinessUserID != query.OnlyBusinessUserID {
			continue
		}
		if query.BusinessUserID != nil && record.BusinessUserID != *query.BusinessUserID {
			continue
		}
		if query.OccurredFrom != nil && record.OccurredOn.Before(*query.OccurredFrom) {
			continue
		}
		if query.OccurredTo != nil && !record.OccurredOn.Before(*query.OccurredTo) {
			continue
		}
		matched = append(matched, *record)
	}
	// 与仓储一致：按发生日期倒序、同日按 ID 倒序。
	sort.Slice(matched, func(i, j int) bool {
		if !matched[i].OccurredOn.Equal(matched[j].OccurredOn) {
			return matched[i].OccurredOn.After(matched[j].OccurredOn)
		}
		return matched[i].ID > matched[j].ID
	})

	page := Page{Items: []Summary{}, Page: query.Page, PageSize: query.PageSize, Total: int64(len(matched))}
	start := (query.Page - 1) * query.PageSize
	for index := start; index >= 0 && index < start+query.PageSize && index < len(matched); index++ {
		page.Items = append(page.Items, Summary{Record: matched[index]})
	}
	return page, nil
}

func (r *fakeRepository) LoadDocument(_ context.Context, _, documentID uint64) (TargetDocument, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.documentErr != nil {
		return TargetDocument{}, r.documentErr
	}
	target, ok := r.documents[documentID]
	if !ok {
		return TargetDocument{}, ErrDocumentNotFound
	}
	return target, nil
}

func (r *fakeRepository) LoadStatement(_ context.Context, _, documentID uint64) (Statement, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.statementErr != nil {
		return Statement{}, r.statementErr
	}
	target, ok := r.documents[documentID]
	if !ok {
		return Statement{}, ErrDocumentNotFound
	}
	records := make([]Record, 0)
	for _, record := range r.records {
		if record.DocumentID == documentID {
			records = append(records, *record)
		}
	}
	sort.Slice(records, func(i, j int) bool { return records[i].ID < records[j].ID })
	return Statement{Document: target, Records: records}, nil
}

func (r *fakeRepository) LoadUsers(_ context.Context, ids []uint64) (map[uint64]identity.UserSummary, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.usersErr != nil {
		return nil, r.usersErr
	}
	result := make(map[uint64]identity.UserSummary, len(ids))
	for _, id := range ids {
		if summary, ok := r.users[id]; ok {
			result[id] = summary
		}
	}
	return result, nil
}

/* ------------------------------------------------------------------ 测试辅助 */

func textPtr(value string) *string { return &value }

func inboundDocument(id uint64, totalYuan int64, businessUser uint64) TargetDocument {
	return TargetDocument{
		ID: id, Kind: document.KindInbound, DocumentNo: fmt.Sprintf("RK20260922-%04d", id),
		Status: document.StatusSubmitted, BusinessUserID: businessUser,
		BusinessDate: businessDay, PartyName: "唐山钢铁", TotalAmount: money.AmountFromYuan(totalYuan),
	}
}

func outboundDocument(id uint64, totalYuan int64, businessUser uint64) TargetDocument {
	target := inboundDocument(id, totalYuan, businessUser)
	target.Kind = document.KindOutbound
	target.DocumentNo = fmt.Sprintf("CK20260922-%04d", id)
	target.PartyName = "沧州管材"
	return target
}

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

func onlyRecordID(t *testing.T, repo *fakeRepository) uint64 {
	t.Helper()
	repo.mu.Lock()
	defer repo.mu.Unlock()
	var found uint64
	for id := range repo.records {
		if found != 0 {
			t.Fatalf("期望恰好一条记录，实际 %d 条", len(repo.records))
		}
		found = id
	}
	if found == 0 {
		t.Fatal("仓储中没有记录")
	}
	return found
}

/* ------------------------------------------------------------------ 登记：快照与结清推导 */

func TestCreatePaymentSnapshotsDocumentAndDerivesStatement(t *testing.T) {
	repo := newFakeRepository()
	repo.documents[11] = inboundDocument(11, 100, testUserID)
	repo.seedUser(testUserID, "王业务")
	service := ownerService(repo)

	data, err := service.Create(context.Background(), ownerPrincipal(testGroupID, testUserID), KindPayment, CreateRequest{
		DocumentID: 11, Amount: "30.00", OccurredOn: "2026年9月22日",
		Method: "transfer", MethodNote: textPtr("微信"), Remark: textPtr("首款"),
	}, "pay-key-1")
	if err != nil {
		t.Fatalf("Create() error = %v", err)
	}

	if data.PaidAmount != money.AmountFromYuan(30) || data.UnpaidAmount != money.AmountFromYuan(70) {
		t.Fatalf("paid=%s unpaid=%s", data.PaidAmount, data.UnpaidAmount)
	}
	if data.PaymentCount != 1 || len(data.Records) != 1 {
		t.Fatalf("paymentCount=%d records=%d", data.PaymentCount, len(data.Records))
	}
	if data.InvoiceStatus != InvoiceStatusNone || data.InvoicedAmount != 0 {
		t.Fatalf("invoiceStatus=%s invoiced=%s", data.InvoiceStatus, data.InvoicedAmount)
	}
	// 出库单方向的三类金额对入库单恒为 0：客户端不需要自己判断单据类型。
	if data.ReceivedAmount != 0 || data.UnreceivedAmount != 0 || data.ReceiptCount != 0 {
		t.Fatalf("入库单结清视图混入了收款口径: %+v", data)
	}
	// 人民币大写三端同口径：单据总额、已付、单条记录都必须给出。
	if data.TotalUpper == "" || data.PaidUpper == "" || data.UnpaidUpper == "" || data.Records[0].AmountUpper == "" {
		t.Fatalf("人民币大写缺失: %+v", data)
	}
	if data.PartyName != "唐山钢铁" || data.DocumentNo != "RK20260922-0011" {
		t.Fatalf("单据快照 = %+v", data)
	}

	created := repo.lastCreate
	if created.DocumentNo != "RK20260922-0011" || created.PartyName != "唐山钢铁" {
		t.Fatalf("记录未落单据快照: %+v", created)
	}
	if created.BusinessUserID != testUserID || !created.BusinessDate.Equal(businessDay) {
		t.Fatalf("业务员 / 业务日期快照 = %+v", created)
	}
	if !created.OccurredOn.Equal(businessDay) || !created.Now.Equal(fixedNow) {
		t.Fatalf("occurred=%s now=%s", created.OccurredOn, created.Now)
	}
	if created.Method == nil || *created.Method != MethodTransfer {
		t.Fatalf("method = %v", created.Method)
	}
	if created.IdempotencyScope != "finance.payment.create" || created.IdempotencyKey != "pay-key-1" {
		t.Fatalf("幂等入参 = %s / %s", created.IdempotencyScope, created.IdempotencyKey)
	}
	if created.RequestFingerprint == "" || created.AuditAction != "finance.payment.recorded" {
		t.Fatalf("指纹 / 审计动作 = %s / %s", created.RequestFingerprint, created.AuditAction)
	}
	// 审计摘要带单号与金额，但不把备注这类自由文本带进审计文本。
	if summary := created.AuditSummary; !strings.Contains(summary, "RK20260922-0011") || strings.Contains(summary, "首款") {
		t.Fatalf("审计摘要 = %q", summary)
	}
}

func TestCreateRejectsDocumentKindMismatch(t *testing.T) {
	repo := newFakeRepository()
	repo.documents[11] = inboundDocument(11, 100, testUserID)
	repo.documents[12] = outboundDocument(12, 80, testUserID)
	service := ownerService(repo)
	principal := ownerPrincipal(testGroupID, testUserID)

	// 给入库单登记收款、给出库单登记付款、给出库单登记开票：三种接口用错都要明确报错。
	cases := []struct {
		name    string
		kind    Kind
		docID   uint64
		request CreateRequest
	}{
		{name: "入库单不允许登记收款", kind: KindReceipt, docID: 11,
			request: CreateRequest{DocumentID: 11, Amount: "10.00", OccurredOn: "2026-09-22", Method: "transfer"}},
		{name: "出库单不允许登记付款", kind: KindPayment, docID: 12,
			request: CreateRequest{DocumentID: 12, Amount: "10.00", OccurredOn: "2026-09-22", Method: "transfer"}},
		{name: "出库单不允许登记开票", kind: KindInvoice, docID: 12,
			request: CreateRequest{DocumentID: 12, Amount: "10.00", OccurredOn: "2026-09-22"}},
	}
	for _, tt := range cases {
		t.Run(tt.name, func(t *testing.T) {
			_, err := service.Create(context.Background(), principal, tt.kind, tt.request, "")
			wantAppError(t, err, apperror.ErrFinanceDocumentMismatch)
		})
	}
}

func TestCreateRejectsNonSubmittedDocument(t *testing.T) {
	repo := newFakeRepository()
	draft := inboundDocument(13, 100, testUserID)
	draft.Status = document.StatusDraft
	repo.documents[13] = draft
	voided := inboundDocument(14, 100, testUserID)
	voided.Status = document.StatusVoided
	repo.documents[14] = voided
	service := ownerService(repo)
	principal := ownerPrincipal(testGroupID, testUserID)

	// 草稿金额未定、作废单已失效，都不允许产生财务记录。
	for _, documentID := range []uint64{13, 14} {
		_, err := service.Create(context.Background(), principal, KindPayment, CreateRequest{
			DocumentID: documentID, Amount: "10.00", OccurredOn: "2026-09-22", Method: "transfer",
		}, "")
		wantAppError(t, err, apperror.ErrDocumentStatusInvalid)
	}

	// 不存在的单据（含其他组的单据）按「找不到」处理，不泄露存在性。
	_, err := service.Create(context.Background(), principal, KindPayment, CreateRequest{
		DocumentID: 999, Amount: "10.00", OccurredOn: "2026-09-22", Method: "transfer",
	}, "")
	wantAppError(t, err, apperror.ErrDocumentNotFound)
}

func TestInvoiceStatusFollowsInvoicedAmount(t *testing.T) {
	repo := newFakeRepository()
	repo.documents[11] = inboundDocument(11, 100, testUserID)
	service := ownerService(repo)
	principal := ownerPrincipal(testGroupID, testUserID)

	book := func(amount string) *StatementData {
		t.Helper()
		data, err := service.Create(context.Background(), principal, KindInvoice, CreateRequest{
			DocumentID: 11, Amount: amount, OccurredOn: "2026-09-22", InvoiceNo: textPtr("INV-0001"),
		}, "")
		if err != nil {
			t.Fatalf("登记开票 %s 失败: %v", amount, err)
		}
		return data
	}

	if status := book("40.00").InvoiceStatus; status != InvoiceStatusPartial {
		t.Fatalf("部分开票状态 = %s", status)
	}
	data := book("60.00")
	if data.InvoiceStatus != InvoiceStatusFull {
		t.Fatalf("开票满额状态 = %s", data.InvoiceStatus)
	}
	if data.InvoicedAmount != money.AmountFromYuan(100) || data.UninvoicedAmount != 0 || data.InvoiceCount != 2 {
		t.Fatalf("开票结清视图 = %+v", data)
	}
}

func TestCreateReceiptDerivesOutboundStatement(t *testing.T) {
	repo := newFakeRepository()
	repo.documents[12] = outboundDocument(12, 80, testUserID)
	service := ownerService(repo)
	principal := ownerPrincipal(testGroupID, testUserID)

	data, err := service.Create(context.Background(), principal, KindReceipt, CreateRequest{
		DocumentID: 12, Amount: "30.00", OccurredOn: "2026-09-22",
		Method: "private_card", CardTail: textPtr("8899"),
	}, "")
	if err != nil {
		t.Fatalf("Create() error = %v", err)
	}

	if data.ReceivedAmount != money.AmountFromYuan(30) || data.UnreceivedAmount != money.AmountFromYuan(50) {
		t.Fatalf("received=%s unreceived=%s", data.ReceivedAmount, data.UnreceivedAmount)
	}
	// 入库单方向的三类金额对出库单恒为 0，避免客户端漏判单据类型时显示假数据。
	if data.PaidAmount != 0 || data.UnpaidAmount != 0 || data.PaymentCount != 0 {
		t.Fatalf("出库单结清视图混入了付款口径: %+v", data)
	}
	if data.InvoicedAmount != 0 || data.UninvoicedAmount != 0 || data.InvoiceStatus != InvoiceStatusNotApplicable {
		t.Fatalf("出库单结清视图混入了开票口径: %+v", data)
	}
	// 对私卡只留后 4 位，完整卡号不进入系统。
	if data.Records[0].CardTail == nil || *data.Records[0].CardTail != "8899" {
		t.Fatalf("卡尾号 = %v", data.Records[0].CardTail)
	}
}

/* ------------------------------------------------------------------ 登记：字段校验 */

func TestCreateValidatesRequestFields(t *testing.T) {
	tests := []struct {
		name    string
		kind    Kind
		request CreateRequest
	}{
		{name: "单据 ID 为空", kind: KindPayment,
			request: CreateRequest{Amount: "10.00", OccurredOn: "2026-09-22", Method: "transfer"}},
		{name: "金额为空", kind: KindPayment,
			request: CreateRequest{DocumentID: 11, OccurredOn: "2026-09-22", Method: "transfer"}},
		{name: "金额格式非法", kind: KindPayment,
			request: CreateRequest{DocumentID: 11, Amount: "10元", OccurredOn: "2026-09-22", Method: "transfer"}},
		{name: "金额为零", kind: KindPayment,
			request: CreateRequest{DocumentID: 11, Amount: "0.00", OccurredOn: "2026-09-22", Method: "transfer"}},
		{name: "金额为负", kind: KindPayment,
			request: CreateRequest{DocumentID: 11, Amount: "-1.00", OccurredOn: "2026-09-22", Method: "transfer"}},
		{name: "发生日期非法", kind: KindPayment,
			request: CreateRequest{DocumentID: 11, Amount: "10.00", OccurredOn: "昨天", Method: "transfer"}},
		{name: "发生日期为空", kind: KindPayment,
			request: CreateRequest{DocumentID: 11, Amount: "10.00", Method: "transfer"}},
		{name: "付款方式非法", kind: KindPayment,
			request: CreateRequest{DocumentID: 11, Amount: "10.00", OccurredOn: "2026-09-22", Method: "cash"}},
		{name: "转账不允许填卡尾号", kind: KindPayment,
			request: CreateRequest{DocumentID: 11, Amount: "10.00", OccurredOn: "2026-09-22", Method: "transfer", CardTail: textPtr("1234")}},
		{name: "对私卡必须填卡尾号", kind: KindPayment,
			request: CreateRequest{DocumentID: 11, Amount: "10.00", OccurredOn: "2026-09-22", Method: "private_card"}},
		{name: "卡尾号必须四位", kind: KindPayment,
			request: CreateRequest{DocumentID: 11, Amount: "10.00", OccurredOn: "2026-09-22", Method: "private_card", CardTail: textPtr("123456")}},
		{name: "卡尾号必须是数字", kind: KindPayment,
			request: CreateRequest{DocumentID: 11, Amount: "10.00", OccurredOn: "2026-09-22", Method: "private_card", CardTail: textPtr("12a4")}},
		{name: "对私卡不允许填转账备注", kind: KindPayment,
			request: CreateRequest{DocumentID: 11, Amount: "10.00", OccurredOn: "2026-09-22", Method: "private_card", CardTail: textPtr("1234"), MethodNote: textPtr("微信")}},
		{name: "对公账户不允许附加字段", kind: KindPayment,
			request: CreateRequest{DocumentID: 11, Amount: "10.00", OccurredOn: "2026-09-22", Method: "public_account", MethodNote: textPtr("微信")}},
		{name: "付款不允许带发票号", kind: KindPayment,
			request: CreateRequest{DocumentID: 11, Amount: "10.00", OccurredOn: "2026-09-22", Method: "transfer", InvoiceNo: textPtr("INV-1")}},
		{name: "开票不允许带付款方式", kind: KindInvoice,
			request: CreateRequest{DocumentID: 11, Amount: "10.00", OccurredOn: "2026-09-22", Method: "transfer"}},
		{name: "开票不允许带卡尾号", kind: KindInvoice,
			request: CreateRequest{DocumentID: 11, Amount: "10.00", OccurredOn: "2026-09-22", CardTail: textPtr("1234")}},
		{name: "备注超长", kind: KindPayment,
			request: CreateRequest{DocumentID: 11, Amount: "10.00", OccurredOn: "2026-09-22", Method: "transfer", Remark: textPtr(strings.Repeat("备", maxRemarkLength+1))}},
		{name: "转账备注超长", kind: KindPayment,
			request: CreateRequest{DocumentID: 11, Amount: "10.00", OccurredOn: "2026-09-22", Method: "transfer", MethodNote: textPtr(strings.Repeat("微", maxMethodNoteLength+1))}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			repo := newFakeRepository()
			repo.documents[11] = inboundDocument(11, 100, testUserID)
			service := ownerService(repo)
			_, err := service.Create(context.Background(), ownerPrincipal(testGroupID, testUserID), tt.kind, tt.request, "")
			wantAppError(t, err, apperror.ErrValidationFailed)
			// 校验必须发生在触达仓储之前：非法请求不应该产生任何写入。
			if repo.createCalls != 0 {
				t.Fatalf("非法请求触达了仓储，createCalls=%d", repo.createCalls)
			}
		})
	}
}

func TestOccurredOnAcceptsHandwrittenDateFormats(t *testing.T) {
	// 财务登记与单据填写是同一批人操作，日期输入口径必须与业务日期完全一致。
	formats := []string{"2026-09-22", "2026/9/22", "2026 9 22", "2026年9月22日", "20260922"}
	for _, raw := range formats {
		t.Run(raw, func(t *testing.T) {
			repo := newFakeRepository()
			repo.documents[11] = inboundDocument(11, 100, testUserID)
			service := ownerService(repo)
			_, err := service.Create(context.Background(), ownerPrincipal(testGroupID, testUserID), KindPayment, CreateRequest{
				DocumentID: 11, Amount: "10.00", OccurredOn: raw, Method: "transfer",
			}, "")
			if err != nil {
				t.Fatalf("Create(occurred_on=%q) error = %v", raw, err)
			}
			if !repo.lastCreate.OccurredOn.Equal(businessDay) {
				t.Fatalf("occurred_on %q 解析为 %s", raw, repo.lastCreate.OccurredOn)
			}
		})
	}
}

/* ------------------------------------------------------------------ 登记：累计上限与幂等 */

func TestCreateEnforcesCumulativeCeiling(t *testing.T) {
	repo := newFakeRepository()
	repo.documents[11] = inboundDocument(11, 100, testUserID)
	service := ownerService(repo)
	principal := ownerPrincipal(testGroupID, testUserID)

	book := func(kind Kind, amount string) error {
		t.Helper()
		_, err := service.Create(context.Background(), principal, kind, CreateRequest{
			DocumentID: 11, Amount: amount, OccurredOn: "2026-09-22", Method: "transfer",
		}, "")
		return err
	}

	if err := book(KindPayment, "60.00"); err != nil {
		t.Fatalf("首笔付款失败: %v", err)
	}
	wantAppError(t, book(KindPayment, "50.00"), apperror.ErrFinanceAmountExceeds)
	if err := book(KindPayment, "40.00"); err != nil {
		t.Fatalf("累计恰好等于总额应当允许: %v", err)
	}

	statement, err := service.Statement(context.Background(), principal, 11)
	if err != nil {
		t.Fatalf("Statement() error = %v", err)
	}
	if statement.PaidAmount != money.AmountFromYuan(100) || statement.UnpaidAmount != 0 {
		t.Fatalf("paid=%s unpaid=%s", statement.PaidAmount, statement.UnpaidAmount)
	}

	// 三类记录的额度互相独立：付款额度用满不影响开票额度。
	if _, err := service.Create(context.Background(), principal, KindInvoice, CreateRequest{
		DocumentID: 11, Amount: "100.00", OccurredOn: "2026-09-22",
	}, ""); err != nil {
		t.Fatalf("开票额度应与付款额度独立: %v", err)
	}
}

func TestCreateIsIdempotentPerKind(t *testing.T) {
	repo := newFakeRepository()
	repo.documents[11] = inboundDocument(11, 100, testUserID)
	service := ownerService(repo)
	principal := ownerPrincipal(testGroupID, testUserID)
	request := CreateRequest{DocumentID: 11, Amount: "30.00", OccurredOn: "2026-09-22", Method: "transfer"}

	first, err := service.Create(context.Background(), principal, KindPayment, request, "key-1")
	if err != nil {
		t.Fatalf("首次登记失败: %v", err)
	}
	second, err := service.Create(context.Background(), principal, KindPayment, request, "key-1")
	if err != nil {
		t.Fatalf("幂等重放应当成功: %v", err)
	}
	if repo.createCalls != 2 {
		t.Fatalf("createCalls=%d", repo.createCalls)
	}
	if len(second.Records) != 1 || second.PaidAmount != first.PaidAmount {
		t.Fatalf("幂等重放产生了重复记录: %+v", second.Records)
	}

	// 同一个幂等键换了内容 = 客户端复用了键，必须报错而不是静默返回旧结果。
	changed := request
	changed.Amount = "31.00"
	_, err = service.Create(context.Background(), principal, KindPayment, changed, "key-1")
	wantAppError(t, err, apperror.ErrIdempotencyKeyReused)

	// 不同记录类型各自独立的作用域：同一个键不会互相干扰。
	if _, err := service.Create(context.Background(), principal, KindInvoice, CreateRequest{
		DocumentID: 11, Amount: "30.00", OccurredOn: "2026-09-22",
	}, "key-1"); err != nil {
		t.Fatalf("不同 kind 复用同一个幂等键应当互不影响: %v", err)
	}
}

/* ------------------------------------------------------------------ 撤销 */

func TestRevokeRebuildsStatementAndKeepsKindBoundary(t *testing.T) {
	repo := newFakeRepository()
	repo.documents[11] = inboundDocument(11, 100, testUserID)
	service := ownerService(repo)
	principal := ownerPrincipal(testGroupID, testUserID)

	if _, err := service.Create(context.Background(), principal, KindPayment, CreateRequest{
		DocumentID: 11, Amount: "30.00", OccurredOn: "2026-09-22", Method: "transfer",
	}, ""); err != nil {
		t.Fatalf("登记付款失败: %v", err)
	}
	recordID := onlyRecordID(t, repo)

	data, err := service.Revoke(context.Background(), principal, KindPayment, recordID)
	if err != nil {
		t.Fatalf("Revoke() error = %v", err)
	}
	if data.PaidAmount != 0 || data.UnpaidAmount != money.AmountFromYuan(100) || len(data.Records) != 0 {
		t.Fatalf("撤销后的结清视图 = %+v", data)
	}
	if repo.lastRevoke.AuditAction != "finance.payment.revoked" || repo.lastRevoke.RecordID != recordID {
		t.Fatalf("撤销审计入参 = %+v", repo.lastRevoke)
	}

	// 用收款接口去撤销付款记录：属于接口用错，按「记录不存在」处理。
	wantAppError(t, func() error {
		_, err := service.Revoke(context.Background(), principal, KindReceipt, recordID)
		return err
	}(), apperror.ErrFinanceRecordNotFound)

	// 记录 ID 不存在同样是「记录不存在」。
	wantAppError(t, func() error {
		_, err := service.Revoke(context.Background(), principal, KindPayment, 9999)
		return err
	}(), apperror.ErrFinanceRecordNotFound)

	// 记录 ID 为 0 属于参数错误。
	wantAppError(t, func() error {
		_, err := service.Revoke(context.Background(), principal, KindPayment, 0)
		return err
	}(), apperror.ErrValidationFailed)
}

func TestRevokeEnforcesOwnerScopeForMembers(t *testing.T) {
	repo := newFakeRepository()
	repo.documents[14] = inboundDocument(14, 100, testOtherID)
	othersRecord := repo.seedRecord(Record{
		GroupID: testGroupID, DocumentID: 14, DocumentKind: document.KindInbound,
		DocumentNo: "RK20260922-0014", PartyName: "唐山钢铁",
		BusinessUserID: testOtherID, BusinessDate: businessDay,
		Kind: KindPayment, Amount: money.AmountFromYuan(10), OccurredOn: businessDay,
		CreatedBy: testOtherID, CreatedAt: fixedNow,
	})
	principal := memberPrincipal(testGroupID, testUserID)

	// 只有记账权限、没有查看他人权限：不能撤销他人单据上的记录。
	recorder := memberService(repo, authorization.PermissionFinanceRecord)
	wantAppError(t, func() error {
		_, err := recorder.Revoke(context.Background(), principal, KindPayment, othersRecord.ID)
		return err
	}(), apperror.ErrForbidden)

	// 有查看他人权限后，撤销他人记录属于正常业务路径。
	viewer := memberService(repo, authorization.PermissionFinanceRecord, authorization.PermissionDocumentViewOthers)
	if _, err := viewer.Revoke(context.Background(), principal, KindPayment, othersRecord.ID); err != nil {
		t.Fatalf("有查看他人权限时应当可以撤销: %v", err)
	}
}

/* ------------------------------------------------------------------ 权限与数据范围 */

func TestMemberScopeAndPermissionGate(t *testing.T) {
	repo := newFakeRepository()
	repo.documents[11] = inboundDocument(11, 100, testUserID)  // 本人单据
	repo.documents[14] = inboundDocument(14, 100, testOtherID) // 他人单据
	repo.seedUser(testUserID, "王业务")
	principal := memberPrincipal(testGroupID, testUserID)

	// 没有 finance.record 权限：既不能登记，也不能撤销。
	plain := memberService(repo)
	wantAppError(t, func() error {
		_, err := plain.Create(context.Background(), principal, KindPayment, CreateRequest{
			DocumentID: 11, Amount: "10.00", OccurredOn: "2026-09-22", Method: "transfer",
		}, "")
		return err
	}(), apperror.ErrForbidden)

	// 只有 finance.record 权限：可以登记本人单据，不能碰他人单据。
	recorder := memberService(repo, authorization.PermissionFinanceRecord)
	if _, err := recorder.Create(context.Background(), principal, KindPayment, CreateRequest{
		DocumentID: 11, Amount: "10.00", OccurredOn: "2026-09-22", Method: "transfer",
	}, ""); err != nil {
		t.Fatalf("本人单据应当可登记: %v", err)
	}
	wantAppError(t, func() error {
		_, err := recorder.Create(context.Background(), principal, KindPayment, CreateRequest{
			DocumentID: 14, Amount: "10.00", OccurredOn: "2026-09-22", Method: "transfer",
		}, "")
		return err
	}(), apperror.ErrForbidden)

	// 列表：未授权查看他人时强制收敛到本人，且显式指定他人业务员直接拒绝。
	if _, err := recorder.List(context.Background(), principal, KindPayment, ListQuery{}); err != nil {
		t.Fatalf("List() error = %v", err)
	}
	if repo.lastQuery.OnlyBusinessUserID != testUserID || repo.lastQuery.BusinessUserID != nil {
		t.Fatalf("未授权查看他人时必须收敛到本人: %+v", repo.lastQuery)
	}
	wantAppError(t, func() error {
		_, err := recorder.List(context.Background(), principal, KindPayment, ListQuery{BusinessUserID: testOtherID})
		return err
	}(), apperror.ErrForbidden)

	// 结清视图沿用同一套数据范围：没有 document.view_others 时读不到他人单据。
	wantAppError(t, func() error {
		_, err := recorder.Statement(context.Background(), principal, 14)
		return err
	}(), apperror.ErrForbidden)
	if _, err := recorder.Statement(context.Background(), principal, 11); err != nil {
		t.Fatalf("本人单据的结清视图应当可读: %v", err)
	}

	// 有 document.view_others：可以看全组，并可按业务员过滤。
	viewer := memberService(repo, authorization.PermissionFinanceRecord, authorization.PermissionDocumentViewOthers)
	if _, err := viewer.List(context.Background(), principal, KindPayment, ListQuery{BusinessUserID: testOtherID}); err != nil {
		t.Fatalf("全组范围应当可以按业务员过滤: %v", err)
	}
	if repo.lastQuery.OnlyBusinessUserID != 0 || repo.lastQuery.BusinessUserID == nil || *repo.lastQuery.BusinessUserID != testOtherID {
		t.Fatalf("全组范围查询条件 = %+v", repo.lastQuery)
	}
	if _, err := viewer.Statement(context.Background(), principal, 14); err != nil {
		t.Fatalf("有查看他人权限时应当可读他人单据的结清视图: %v", err)
	}
}

func TestForbiddenPrincipalsCannotUseFinance(t *testing.T) {
	repo := newFakeRepository()
	repo.documents[11] = inboundDocument(11, 100, testUserID)
	service := ownerService(repo)
	request := CreateRequest{DocumentID: 11, Amount: "10.00", OccurredOn: "2026-09-22", Method: "transfer"}

	// 平台管理员不参与租户业务。
	wantAppError(t, func() error {
		_, err := service.Create(context.Background(), identity.Principal{
			UserID: 1, AccountType: identity.AccountTypePlatformAdmin,
		}, KindPayment, request, "")
		return err
	}(), apperror.ErrForbidden)

	// 未改初始密码前不允许记账。
	groupID := testGroupID
	wantAppError(t, func() error {
		_, err := service.Create(context.Background(), identity.Principal{
			UserID: 2, GroupID: &groupID, AccountType: identity.AccountTypeMember,
			MemberType: "member", MustChangePassword: true,
		}, KindPayment, request, "")
		return err
	}(), apperror.ErrAuthPasswordChangeRequired)

	// 非组内身份（无 GroupID）在三个入口上都应当被拒绝。
	outsider := identity.Principal{UserID: 5, AccountType: identity.AccountTypeMember, MemberType: "member"}
	wantAppError(t, func() error {
		_, err := service.List(context.Background(), outsider, KindPayment, ListQuery{})
		return err
	}(), apperror.ErrForbidden)
	wantAppError(t, func() error {
		_, err := service.Statement(context.Background(), outsider, 11)
		return err
	}(), apperror.ErrForbidden)
	wantAppError(t, func() error {
		_, err := service.Revoke(context.Background(), outsider, KindPayment, 1)
		return err
	}(), apperror.ErrForbidden)
}

/* ------------------------------------------------------------------ 列表 */

func TestListNormalizesQueryAndPaginates(t *testing.T) {
	repo := newFakeRepository()
	repo.documents[11] = inboundDocument(11, 100, testUserID)
	repo.seedUser(testUserID, "王业务")
	service := ownerService(repo)
	principal := ownerPrincipal(testGroupID, testUserID)

	for index := 0; index < 3; index++ {
		if _, err := service.Create(context.Background(), principal, KindPayment, CreateRequest{
			DocumentID: 11, Amount: "10.00", OccurredOn: fmt.Sprintf("2026-09-%02d", 10+index), Method: "transfer",
		}, ""); err != nil {
			t.Fatalf("预置第 %d 条记录失败: %v", index, err)
		}
	}

	page, err := service.List(context.Background(), principal, KindPayment, ListQuery{})
	if err != nil {
		t.Fatalf("List() error = %v", err)
	}
	if page.Page != 1 || page.PageSize != 20 || page.Total != 3 || len(page.Items) != 3 {
		t.Fatalf("默认分页 = %+v", page)
	}
	// 列表行必须带完整的用户摘要，否则客户端会渲染出空白的「业务员」列。
	if page.Items[0].CreatedBy.DisplayName == "" || page.Items[0].BusinessUser.DisplayName == "" {
		t.Fatalf("列表行缺少用户摘要: %+v", page.Items[0])
	}
	// 日期倒序：最后登记的那条排最前。
	if page.Items[0].OccurredOn != "2026-09-12" {
		t.Fatalf("排序错误，首行 occurred_on = %s", page.Items[0].OccurredOn)
	}

	// 页大小超过上限直接拒绝，避免一次拉出整张表。
	wantAppError(t, func() error {
		_, err := service.List(context.Background(), principal, KindPayment, ListQuery{PageSize: 101})
		return err
	}(), apperror.ErrValidationFailed)

	// 非法月份、非法方式同样拒绝。
	wantAppError(t, func() error {
		_, err := service.List(context.Background(), principal, KindPayment, ListQuery{Month: "2026-13"})
		return err
	}(), apperror.ErrValidationFailed)
	wantAppError(t, func() error {
		_, err := service.List(context.Background(), principal, KindPayment, ListQuery{Method: Method("cash")})
		return err
	}(), apperror.ErrValidationFailed)

	// 合法月份被翻译成左闭右开的日期区间。
	if _, err := service.List(context.Background(), principal, KindPayment, ListQuery{Month: "2026-09"}); err != nil {
		t.Fatalf("List(month) error = %v", err)
	}
	if repo.lastQuery.OccurredFrom == nil || repo.lastQuery.OccurredTo == nil {
		t.Fatalf("月份未翻译为日期区间: %+v", repo.lastQuery)
	}
	if got := repo.lastQuery.OccurredFrom.Format("2006-01-02"); got != "2026-09-01" {
		t.Fatalf("月份起点 = %s", got)
	}
	if got := repo.lastQuery.OccurredTo.Format("2006-01-02"); got != "2026-10-01" {
		t.Fatalf("月份终点 = %s（应为下月首日）", got)
	}

	// date_to 是闭区间语义，仓储按左闭右开比较，服务层要补一天。
	if _, err := service.List(context.Background(), principal, KindPayment, ListQuery{DateFrom: "2026-09-10", DateTo: "2026-09-11"}); err != nil {
		t.Fatalf("List(date range) error = %v", err)
	}
	if got := repo.lastQuery.OccurredTo.Format("2006-01-02"); got != "2026-09-12" {
		t.Fatalf("date_to 未补一天: %s", got)
	}

	// 关键词首尾空白被裁掉，避免出现「查不到但看起来填了」的怪现象。
	if _, err := service.List(context.Background(), principal, KindPayment, ListQuery{Keyword: "  RK20260922  "}); err != nil {
		t.Fatalf("List(keyword) error = %v", err)
	}
	if repo.lastQuery.Keyword != "RK20260922" {
		t.Fatalf("关键词未裁剪: %q", repo.lastQuery.Keyword)
	}
}

/* ------------------------------------------------------------------ 错误码映射 */

func TestRepositoryErrorsMapToStableCodes(t *testing.T) {
	tests := []struct {
		name string
		err  error
		want error
	}{
		{name: "记录不存在", err: ErrRecordNotFound, want: apperror.ErrFinanceRecordNotFound},
		{name: "单据不存在", err: ErrDocumentNotFound, want: apperror.ErrDocumentNotFound},
		{name: "单据状态非法", err: ErrDocumentStatusInvalid, want: apperror.ErrDocumentStatusInvalid},
		{name: "单据类型不匹配", err: ErrDocumentMismatch, want: apperror.ErrFinanceDocumentMismatch},
		{name: "累计超额", err: ErrAmountExceeds, want: apperror.ErrFinanceAmountExceeds},
		{name: "幂等键复用", err: ErrIdempotencyMismatch, want: apperror.ErrIdempotencyKeyReused},
		{name: "库层故障", err: errors.New("mysql: connection refused"), want: apperror.ErrInternal},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			repo := newFakeRepository()
			repo.documents[11] = inboundDocument(11, 100, testUserID)
			repo.createErr = tt.err
			service := ownerService(repo)
			_, err := service.Create(context.Background(), ownerPrincipal(testGroupID, testUserID), KindPayment, CreateRequest{
				DocumentID: 11, Amount: "10.00", OccurredOn: "2026-09-22", Method: "transfer",
			}, "")
			wantAppError(t, err, tt.want)
		})
	}

	// 读取路径上的库层故障同样收敛为内部错误，不能泄露底层实现。
	repo := newFakeRepository()
	repo.documents[11] = inboundDocument(11, 100, testUserID)
	repo.listErr = errors.New("mysql: connection refused")
	service := ownerService(repo)
	wantAppError(t, func() error {
		_, err := service.List(context.Background(), ownerPrincipal(testGroupID, testUserID), KindPayment, ListQuery{})
		return err
	}(), apperror.ErrInternal)

	repo.listErr = nil
	repo.usersErr = errors.New("mysql: connection refused")
	wantAppError(t, func() error {
		_, err := service.List(context.Background(), ownerPrincipal(testGroupID, testUserID), KindPayment, ListQuery{})
		return err
	}(), apperror.ErrInternal)
}
