package document

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"sync"
	"testing"
	"time"

	"CBizDocsManager/backend/internal/authorization"
	"CBizDocsManager/backend/internal/identity"
	"CBizDocsManager/backend/pkg/apperror"
	"CBizDocsManager/backend/pkg/money"
)

/* ------------------------------------------------------------------ 测试桩 */

type idempotencyEntry struct {
	fingerprint string
	documentID  uint64
}

// fakeRepository 用内存结构模拟单据仓储，便于在无数据库环境下覆盖业务规则。
type fakeRepository struct {
	mu             sync.Mutex
	nextDocumentID uint64
	nextPartyID    uint64
	nextItemID     uint64
	details        map[uint64]Detail
	idempotency    map[string]idempotencyEntry
	users          map[uint64]identity.UserSummary
	members        map[uint64]bool
	totals         MonthlyTotals
	listErr        error
	loadErr        error
	forceVersion   *uint64
	createCalls    int
	lastListQuery  RepositoryQuery
	lastCreate     CreateInput
	auditActions   []string
}

func newFakeRepository() *fakeRepository {
	return &fakeRepository{
		nextDocumentID: 1, nextPartyID: 1, nextItemID: 1,
		details: make(map[uint64]Detail), idempotency: make(map[string]idempotencyEntry),
		users: make(map[uint64]identity.UserSummary), members: make(map[uint64]bool),
	}
}

func (r *fakeRepository) key(scope, apiKey string) string {
	return fmt.Sprintf("%s|%s", scope, apiKey)
}

func (r *fakeRepository) CreateDocument(_ context.Context, input CreateInput) (Document, bool, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.createCalls++
	r.lastCreate = input

	if input.IdempotencyKey != "" {
		if entry, ok := r.idempotency[r.key(input.IdempotencyScope, input.IdempotencyKey)]; ok {
			if entry.fingerprint != input.RequestFingerprint {
				return Document{}, false, ErrIdempotencyMismatch
			}
			detail := r.details[entry.documentID]
			return detail.Document, true, nil
		}
	}

	// 单号按「组 + 类型 + 业务日期」自增，与真实仓储行为保持一致。
	sequence := 0
	for _, detail := range r.details {
		if detail.Document.Kind == input.Kind && detail.Document.BusinessDate.Equal(input.BusinessDate) {
			sequence++
		}
	}
	document := Document{
		ID: r.nextDocumentID, GroupID: input.GroupID, Kind: input.Kind,
		DocumentNo: formatDocumentNo(input.Kind, input.BusinessDate, sequence+1),
		Status:     input.Status, BusinessUserID: input.BusinessUserID, BusinessDate: input.BusinessDate,
		ShippingUnit: input.ShippingUnit, SaleAmountType: input.SaleAmountType, TotalAmount: input.TotalAmount,
		Remark: input.Remark, Version: 1, CreatedBy: input.OperatorUserID, UpdatedBy: input.OperatorUserID,
		CreatedAt: input.Now, UpdatedAt: input.Now,
	}
	if input.Status == StatusSubmitted {
		submitted := input.Now
		document.SubmittedAt = &submitted
	}
	detail := Detail{Document: document, Parties: []PartyWithItems{}}
	for _, partyDraft := range input.Parties {
		party := Party{
			ID: r.nextPartyID, GroupID: input.GroupID, DocumentID: document.ID, Position: partyDraft.Position,
			PartyName: partyDraft.PartyName, ContactPhone: partyDraft.ContactPhone,
			DictionaryEntryID: partyDraft.DictionaryEntryID, Subtotal: partyDraft.Subtotal,
		}
		r.nextPartyID++
		items := make([]Item, 0, len(partyDraft.Items))
		for _, itemDraft := range partyDraft.Items {
			items = append(items, Item{
				ID: r.nextItemID, GroupID: input.GroupID, DocumentID: document.ID, PartyID: party.ID,
				Position: itemDraft.Position, ProductName: itemDraft.ProductName, ProductModel: itemDraft.ProductModel,
				Unit: itemDraft.Unit, Quantity: itemDraft.Quantity, Weight: itemDraft.Weight,
				UnitPrice: itemDraft.UnitPrice, PriceTaxMode: itemDraft.PriceTaxMode,
				Amount: itemDraft.Amount, Remark: itemDraft.Remark,
			})
			r.nextItemID++
		}
		detail.Parties = append(detail.Parties, PartyWithItems{Party: party, Items: items})
	}
	r.details[document.ID] = detail
	r.nextDocumentID++
	r.auditActions = append(r.auditActions, input.AuditAction)
	if input.IdempotencyKey != "" {
		r.idempotency[r.key(input.IdempotencyScope, input.IdempotencyKey)] = idempotencyEntry{fingerprint: input.RequestFingerprint, documentID: document.ID}
	}
	return document, false, nil
}

func (r *fakeRepository) ReplaceDocument(_ context.Context, input UpdateInput) (Document, error) {
	r.mu.Lock()
	defer r.mu.Unlock()

	if input.IdempotencyKey != "" {
		if entry, ok := r.idempotency[r.key(input.IdempotencyScope, input.IdempotencyKey)]; ok {
			if entry.fingerprint != input.RequestFingerprint {
				return Document{}, ErrIdempotencyMismatch
			}
			return r.details[entry.documentID].Document, nil
		}
	}

	detail, ok := r.details[input.DocumentID]
	if !ok {
		return Document{}, ErrNotFound
	}
	if detail.Document.Version != input.ExpectedVersion {
		return Document{}, ErrVersionConflict
	}
	if detail.Document.Status == StatusVoided {
		return Document{}, ErrStatusInvalid
	}
	document := detail.Document
	document.Status = input.Status
	document.BusinessUserID = input.BusinessUserID
	document.BusinessDate = input.BusinessDate
	document.ShippingUnit = input.ShippingUnit
	document.SaleAmountType = input.SaleAmountType
	document.TotalAmount = input.TotalAmount
	document.Remark = input.Remark
	document.Version = input.ExpectedVersion + 1
	document.UpdatedBy = input.OperatorUserID
	document.UpdatedAt = input.Now

	rebuilt := Detail{Document: document, Parties: []PartyWithItems{}}
	for _, partyDraft := range input.Parties {
		party := Party{
			ID: r.nextPartyID, GroupID: input.GroupID, DocumentID: document.ID, Position: partyDraft.Position,
			PartyName: partyDraft.PartyName, ContactPhone: partyDraft.ContactPhone,
			DictionaryEntryID: partyDraft.DictionaryEntryID, Subtotal: partyDraft.Subtotal,
		}
		r.nextPartyID++
		items := make([]Item, 0, len(partyDraft.Items))
		for _, itemDraft := range partyDraft.Items {
			items = append(items, Item{
				ID: r.nextItemID, GroupID: input.GroupID, DocumentID: document.ID, PartyID: party.ID,
				Position: itemDraft.Position, ProductName: itemDraft.ProductName, ProductModel: itemDraft.ProductModel,
				Unit: itemDraft.Unit, Quantity: itemDraft.Quantity, Weight: itemDraft.Weight,
				UnitPrice: itemDraft.UnitPrice, PriceTaxMode: itemDraft.PriceTaxMode,
				Amount: itemDraft.Amount, Remark: itemDraft.Remark,
			})
			r.nextItemID++
		}
		rebuilt.Parties = append(rebuilt.Parties, PartyWithItems{Party: party, Items: items})
	}
	r.details[document.ID] = rebuilt
	if input.IdempotencyKey != "" {
		r.idempotency[r.key(input.IdempotencyScope, input.IdempotencyKey)] = idempotencyEntry{fingerprint: input.RequestFingerprint, documentID: document.ID}
	}
	return document, nil
}

func (r *fakeRepository) ChangeStatus(_ context.Context, input StatusInput) (Document, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	detail, ok := r.details[input.DocumentID]
	if !ok {
		return Document{}, ErrNotFound
	}
	if detail.Document.Version != input.ExpectedVersion {
		return Document{}, ErrVersionConflict
	}
	if detail.Document.Status == input.Status {
		return Document{}, ErrStatusInvalid
	}
	detail.Document.Status = input.Status
	detail.Document.Version = input.ExpectedVersion + 1
	detail.Document.UpdatedAt = input.Now
	if input.Status == StatusSubmitted {
		submitted := input.Now
		detail.Document.SubmittedAt = &submitted
	}
	r.details[input.DocumentID] = detail
	r.auditActions = append(r.auditActions, input.AuditAction)
	return detail.Document, nil
}

func (r *fakeRepository) FindDocument(_ context.Context, groupID uint64, kind Kind, id uint64) (Document, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.loadErr != nil {
		return Document{}, r.loadErr
	}
	detail, ok := r.details[id]
	if !ok || detail.Document.GroupID != groupID || detail.Document.Kind != kind {
		return Document{}, ErrNotFound
	}
	return detail.Document, nil
}

func (r *fakeRepository) LoadDetail(_ context.Context, groupID uint64, kind Kind, id uint64) (Detail, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.loadErr != nil {
		return Detail{}, r.loadErr
	}
	detail, ok := r.details[id]
	if !ok || detail.Document.GroupID != groupID || detail.Document.Kind != kind {
		return Detail{}, ErrNotFound
	}
	return detail, nil
}

func (r *fakeRepository) ListDocuments(_ context.Context, groupID uint64, kind Kind, query RepositoryQuery) (Page, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.lastListQuery = query
	if r.listErr != nil {
		return Page{}, r.listErr
	}
	items := make([]DocumentSummary, 0, len(r.details))
	for _, detail := range r.details {
		document := detail.Document
		if document.GroupID != groupID || document.Kind != kind {
			continue
		}
		if query.Status != nil && document.Status != *query.Status {
			continue
		}
		if query.BusinessUserID != nil && document.BusinessUserID != *query.BusinessUserID {
			continue
		}
		if query.OnlyBusinessUserID != 0 && document.BusinessUserID != query.OnlyBusinessUserID {
			continue
		}
		if query.MonthStart != nil && document.BusinessDate.Before(*query.MonthStart) {
			continue
		}
		if query.MonthEnd != nil && !document.BusinessDate.Before(*query.MonthEnd) {
			continue
		}
		if keyword := strings.TrimSpace(query.Keyword); keyword != "" {
			matched := strings.Contains(document.DocumentNo, keyword)
			for _, party := range detail.Parties {
				if strings.Contains(party.PartyName, keyword) {
					matched = true
				}
			}
			if !matched {
				continue
			}
		}
		names := make([]string, 0, len(detail.Parties))
		count := 0
		for _, party := range detail.Parties {
			names = append(names, party.PartyName)
			count += len(party.Items)
		}
		items = append(items, DocumentSummary{Document: document, PartyNames: names, ItemCount: count, BusinessUserID: document.BusinessUserID})
	}
	return Page{Items: items, Page: query.Page, PageSize: query.PageSize, Total: int64(len(items))}, nil
}

func (r *fakeRepository) MonthlyTotals(_ context.Context, _ uint64, _ Kind, _ SummaryQuery) (MonthlyTotals, error) {
	return r.totals, nil
}

func (r *fakeRepository) LoadUsers(_ context.Context, ids []uint64) (map[uint64]identity.UserSummary, error) {
	result := make(map[uint64]identity.UserSummary, len(ids))
	for _, id := range ids {
		if user, ok := r.users[id]; ok {
			result[id] = user
		}
	}
	return result, nil
}

func (r *fakeRepository) ActiveMemberExists(_ context.Context, groupID, userID uint64) (bool, error) {
	return r.members[userID], nil
}

// fakeAuthorizer 用固定授权集合模拟权限引擎。
type fakeAuthorizer struct {
	granted map[authorization.Code]bool
	err     error
}

func (a fakeAuthorizer) Require(_ context.Context, principal identity.Principal, groupID uint64, code authorization.Code) error {
	if a.err != nil {
		return a.err
	}
	if principal.GroupID == nil || *principal.GroupID != groupID {
		return apperror.ErrForbidden
	}
	if a.granted[code] {
		return nil
	}
	return apperror.ErrForbidden
}

/* ------------------------------------------------------------------ 测试辅助 */

var fixedNow = time.Date(2026, time.September, 22, 10, 30, 0, 0, time.UTC)

func testPrincipal(groupID uint64) identity.Principal {
	return identity.Principal{UserID: 7, GroupID: &groupID, GroupName: "钢铁一组",
		AccountType: identity.AccountTypeGroupOwner, MemberType: "owner", SessionID: 1}
}

func memberPrincipal(groupID, userID uint64) identity.Principal {
	return identity.Principal{UserID: userID, GroupID: &groupID, GroupName: "钢铁一组",
		AccountType: identity.AccountTypeMember, MemberType: "member", SessionID: 2}
}

func newTestService(repo *fakeRepository, authorizer authorization.Authorizer) *Service {
	service := NewService(repo, authorizer)
	service.now = func() time.Time { return fixedNow }
	return service
}

func ownerService(repo *fakeRepository) *Service {
	return newTestService(repo, fakeAuthorizer{granted: map[authorization.Code]bool{}})
}

func seedGroupMember(repo *fakeRepository, userID uint64) {
	repo.members[userID] = true
	repo.users[userID] = identity.UserSummary{ID: userID, Username: fmt.Sprintf("user%d", userID), DisplayName: fmt.Sprintf("业务员%d", userID), AccountType: identity.AccountTypeMember}
}

// 测试常量助手：常量非法时直接 panic，避免每个用例都写错误处理。
func a(raw string) money.Amount {
	value, err := money.ParseAmount(raw)
	if err != nil {
		panic(err)
	}
	return value
}

func q(raw string) money.Quantity {
	value, err := money.ParseQuantity(raw)
	if err != nil {
		panic(err)
	}
	return value
}

func p(raw string) money.Price {
	value, err := money.ParsePrice(raw)
	if err != nil {
		panic(err)
	}
	return value
}

func textPointer(value string) *string { return &value }

func saleTypePointer(value SaleAmountType) *SaleAmountType { return &value }

func wantAppError(t *testing.T, err error, expected *apperror.Error) {
	t.Helper()
	var appErr *apperror.Error
	if !errors.As(err, &appErr) || appErr.Code != expected.Code {
		t.Fatalf("error = %v, want code %s", err, expected.Code)
	}
}

func inboundCreateRequest() CreateRequest {
	return CreateRequest{
		BusinessDate: "2026 9 22",
		Parties: []PartyRequest{
			{
				PartyName: "  鑫源钢贸有限公司 ",
				Items: []ItemRequest{
					{ProductName: "螺纹钢", ProductModel: textPointer("HRB400 Φ20"), Unit: textPointer("吨"),
						Quantity: q("40"), UnitPrice: p("1800.00"), PriceTaxMode: PriceTaxIncluded, Remark: textPointer("9/20 到货")},
					{ProductName: "盘螺", Quantity: q("14"), UnitPrice: p("1742.86"), PriceTaxMode: PriceTaxExcluded},
				},
			},
			{
				PartyName: "昌盛金属材料有限公司",
				Items: []ItemRequest{
					{ProductName: "热轧卷板", Quantity: q("17"), UnitPrice: p("2975.43"), PriceTaxMode: PriceTaxIncluded},
				},
			},
		},
	}
}

/* ------------------------------------------------------------------ 用例 */

func TestCreateInboundComputesAmountsAndNumber(t *testing.T) {
	repo := newFakeRepository()
	seedGroupMember(repo, 7)
	service := ownerService(repo)

	result, err := service.Create(context.Background(), testPrincipal(3), KindInbound, inboundCreateRequest(), "")
	if err != nil {
		t.Fatalf("Create() error = %v", err)
	}
	if result.DocumentNo != "RK20260922-0001" {
		t.Fatalf("DocumentNo = %q, want RK20260922-0001", result.DocumentNo)
	}
	if result.Status != StatusDraft {
		t.Fatalf("Status = %q, want draft", result.Status)
	}
	// 「2026 9 22」必须被规范化成标准日期。
	if result.BusinessDate != "2026-09-22" {
		t.Fatalf("BusinessDate = %q, want 2026-09-22", result.BusinessDate)
	}
	if len(result.Parties) != 2 {
		t.Fatalf("parties = %d, want 2", len(result.Parties))
	}
	// 1800.00 × 40 = 72000.00；1742.86 × 14 = 24400.04
	if result.Parties[0].Items[0].Amount != a("72000.00") {
		t.Fatalf("item amount = %s, want 72000.00", result.Parties[0].Items[0].Amount)
	}
	if result.Parties[0].Items[1].Amount != a("24400.04") {
		t.Fatalf("item amount = %s, want 24400.04", result.Parties[0].Items[1].Amount)
	}
	if result.Parties[0].Subtotal != a("96400.04") {
		t.Fatalf("subtotal = %s, want 96400.04", result.Parties[0].Subtotal)
	}
	wantTotal := a("96400.04").Add(a("50582.31"))
	if result.TotalAmount != wantTotal {
		t.Fatalf("total = %s, want %s", result.TotalAmount, wantTotal)
	}
	// 验收要求桌面端展示人民币大写，服务端统一生成。
	if result.TotalAmountUpper != rmbUpper(wantTotal) {
		t.Fatalf("TotalAmountUpper = %q", result.TotalAmountUpper)
	}
	// 序号必须连续，且往来单位名称两端空白被清理。
	if result.Parties[0].PartyName != "鑫源钢贸有限公司" {
		t.Fatalf("party name = %q", result.Parties[0].PartyName)
	}
	if result.Parties[0].Items[0].Position != 1 || result.Parties[0].Items[1].Position != 2 {
		t.Fatalf("positions = %d,%d", result.Parties[0].Items[0].Position, result.Parties[0].Items[1].Position)
	}
	if len(repo.auditActions) != 1 || repo.auditActions[0] != "document.created" {
		t.Fatalf("audit actions = %v", repo.auditActions)
	}
}

func TestCreateRejectsKindSpecificFields(t *testing.T) {
	repo := newFakeRepository()
	seedGroupMember(repo, 7)
	service := ownerService(repo)
	principal := testPrincipal(3)

	inboundWithSaleType := inboundCreateRequest()
	inboundWithSaleType.SaleAmountType = saleTypePointer(SaleAmountVATSpecial)
	_, err := service.Create(context.Background(), principal, KindInbound, inboundWithSaleType, "")
	wantAppError(t, err, apperror.ErrValidationFailed)

	inboundWithPhone := inboundCreateRequest()
	inboundWithPhone.Parties[0].ContactPhone = textPointer("13900000000")
	_, err = service.Create(context.Background(), principal, KindInbound, inboundWithPhone, "")
	wantAppError(t, err, apperror.ErrValidationFailed)

	// 出库单允许先存草稿而不填销售金额类型，但提交时必须填。
	outbound := CreateRequest{
		Status: StatusDraft, BusinessDate: "2026-09-22", ShippingUnit: textPointer("一号库"),
		Parties: []PartyRequest{{PartyName: "宏达建筑", ContactPhone: textPointer("13911112222"),
			Items: []ItemRequest{{ProductName: "螺纹钢", Quantity: q("20"), UnitPrice: p("2260.00"), PriceTaxMode: PriceTaxIncluded}}}},
	}
	if _, err := service.Create(context.Background(), principal, KindOutbound, outbound, ""); err != nil {
		t.Fatalf("create outbound draft error = %v", err)
	}
	outbound.Status = StatusSubmitted
	_, err = service.Create(context.Background(), principal, KindOutbound, outbound, "")
	wantAppError(t, err, apperror.ErrDocumentIncomplete)

	outbound.SaleAmountType = saleTypePointer(SaleAmountVATSpecial)
	submitted, err := service.Create(context.Background(), principal, KindOutbound, outbound, "")
	if err != nil {
		t.Fatalf("create outbound submitted error = %v", err)
	}
	if submitted.DocumentNo != "CK20260922-0002" {
		// 草稿已经占用了 0001，序号必须继续递增。
		t.Fatalf("outbound DocumentNo = %q, want CK20260922-0002", submitted.DocumentNo)
	}
}

func TestSubmitRequiresCompleteItems(t *testing.T) {
	repo := newFakeRepository()
	seedGroupMember(repo, 7)
	service := ownerService(repo)
	principal := testPrincipal(3)

	request := inboundCreateRequest()
	request.Parties[1].Items[0].UnitPrice = 0 // 待补单价的草稿行
	draft, err := service.Create(context.Background(), principal, KindInbound, request, "")
	if err != nil {
		t.Fatalf("Create() error = %v", err)
	}
	_, err = service.Submit(context.Background(), principal, KindInbound, draft.DocumentID, VersionRequest{Version: draft.Version})
	wantAppError(t, err, apperror.ErrDocumentIncomplete)

	update := UpdateRequest{
		Version: draft.Version, Status: StatusDraft, BusinessDate: "2026-09-22",
		Parties: []PartyRequest{{
			PartyName: "昌盛金属材料有限公司",
			Items: []ItemRequest{{ProductName: "热轧卷板", Quantity: q("17.05"),
				UnitPrice: p("2975.43"), PriceTaxMode: PriceTaxIncluded}},
		}},
	}
	updated, err := service.Update(context.Background(), principal, KindInbound, draft.DocumentID, update, "")
	if err != nil {
		t.Fatalf("Update() error = %v", err)
	}
	if updated.Version != draft.Version+1 {
		t.Fatalf("version = %d, want %d", updated.Version, draft.Version+1)
	}
	submitted, err := service.Submit(context.Background(), principal, KindInbound, draft.DocumentID, VersionRequest{Version: updated.Version})
	if err != nil {
		t.Fatalf("Submit() error = %v", err)
	}
	if submitted.Status != StatusSubmitted || submitted.SubmittedAt == nil {
		t.Fatalf("submit result = %+v", submitted)
	}
	// 重复提交必须被状态机挡住，避免客户端重放造成状态倒退。
	_, err = service.Submit(context.Background(), principal, KindInbound, draft.DocumentID, VersionRequest{Version: submitted.Version})
	wantAppError(t, err, apperror.ErrDocumentStatusInvalid)

	if _, err := service.Void(context.Background(), principal, KindInbound, draft.DocumentID, VersionRequest{Version: submitted.Version}); err != nil {
		t.Fatalf("Void() error = %v", err)
	}
	// 作废是终态：不能再修改。
	_, err = service.Update(context.Background(), principal, KindInbound, draft.DocumentID, update, "")
	wantAppError(t, err, apperror.ErrDocumentStatusInvalid)
}

func TestMemberDataScopeFollowsPermissions(t *testing.T) {
	repo := newFakeRepository()
	seedGroupMember(repo, 7)
	seedGroupMember(repo, 11)
	seedGroupMember(repo, 12)
	ownerServiceInstance := ownerService(repo)

	owner := testPrincipal(3)
	owned, err := ownerServiceInstance.Create(context.Background(), owner, KindInbound, inboundCreateRequest(), "")
	if err != nil {
		t.Fatalf("Create() by owner error = %v", err)
	}
	// 主账号把单据挂在业务员 11 名下（代录）。
	delegated := inboundCreateRequest()
	delegated.BusinessUserID = pointerUint64(11)
	other, err := ownerServiceInstance.Create(context.Background(), owner, KindInbound, delegated, "")
	if err != nil {
		t.Fatalf("Create() delegated error = %v", err)
	}

	member := memberPrincipal(3, 12)
	// 无任何权限的子账号：只能看本人单据。
	plainService := newTestService(repo, fakeAuthorizer{granted: map[authorization.Code]bool{}})
	page, err := plainService.List(context.Background(), member, KindInbound, ListQuery{})
	if err != nil {
		t.Fatalf("List() error = %v", err)
	}
	if page.Total != 0 {
		t.Fatalf("plain member sees %d documents, want 0", page.Total)
	}
	if repo.lastListQuery.OnlyBusinessUserID != 12 {
		t.Fatalf("OnlyBusinessUserID = %d, want 12", repo.lastListQuery.OnlyBusinessUserID)
	}
	_, err = plainService.Get(context.Background(), member, KindInbound, owned.DocumentID)
	wantAppError(t, err, apperror.ErrForbidden)
	_, err = plainService.List(context.Background(), member, KindInbound, ListQuery{BusinessUserID: 11})
	wantAppError(t, err, apperror.ErrForbidden)

	// 授予「查看他人单据」后可以读取全组数据。
	viewerService := newTestService(repo, fakeAuthorizer{granted: map[authorization.Code]bool{
		authorization.PermissionDocumentViewOthers: true,
	}})
	page, err = viewerService.List(context.Background(), member, KindInbound, ListQuery{})
	if err != nil {
		t.Fatalf("List() with permission error = %v", err)
	}
	if page.Total != 2 {
		t.Fatalf("viewer sees %d documents, want 2", page.Total)
	}
	if repo.lastListQuery.OnlyBusinessUserID != 0 {
		t.Fatalf("OnlyBusinessUserID = %d, want 0 for viewer", repo.lastListQuery.OnlyBusinessUserID)
	}
	if _, err := viewerService.Get(context.Background(), member, KindInbound, other.DocumentID); err != nil {
		t.Fatalf("viewer Get() error = %v", err)
	}
	// 只授查看不授编辑：写入他人单据仍必须被拒绝。
	_, err = viewerService.Update(context.Background(), member, KindInbound, other.DocumentID,
		UpdateRequest{Version: other.Version, BusinessDate: "2026-09-22", Parties: inboundCreateRequest().Parties}, "")
	wantAppError(t, err, apperror.ErrForbidden)

	editorService := newTestService(repo, fakeAuthorizer{granted: map[authorization.Code]bool{
		authorization.PermissionDocumentEditOthers: true,
	}})
	if _, err := editorService.Update(context.Background(), member, KindInbound, other.DocumentID,
		UpdateRequest{Version: other.Version, BusinessDate: "2026-09-22", Parties: inboundCreateRequest().Parties}, ""); err != nil {
		t.Fatalf("editor Update() error = %v", err)
	}
}

func TestBusinessUserMustBeActiveGroupMember(t *testing.T) {
	repo := newFakeRepository()
	seedGroupMember(repo, 7)
	service := ownerService(repo)
	principal := testPrincipal(3)

	request := inboundCreateRequest()
	request.BusinessUserID = pointerUint64(99) // 不存在或非本组成员
	_, err := service.Create(context.Background(), principal, KindInbound, request, "")
	wantAppError(t, err, apperror.ErrValidationFailed)

	// 子账号即使有编辑他人权限，也不能把单据挂到自己以外的人名下。
	memberRepo := newFakeRepository()
	seedGroupMember(memberRepo, 11)
	seedGroupMember(memberRepo, 12)
	memberService := newTestService(memberRepo, fakeAuthorizer{granted: map[authorization.Code]bool{
		authorization.PermissionDocumentEditOthers: true,
	}})
	delegated := inboundCreateRequest()
	delegated.BusinessUserID = pointerUint64(11)
	_, err = memberService.Create(context.Background(), memberPrincipal(3, 12), KindInbound, delegated, "")
	if err != nil {
		t.Fatalf("member delegating to another user error = %v, want nil", err)
	}
}

func TestIdempotentCreateReplaysDocument(t *testing.T) {
	repo := newFakeRepository()
	seedGroupMember(repo, 7)
	service := ownerService(repo)
	principal := testPrincipal(3)

	first, err := service.Create(context.Background(), principal, KindInbound, inboundCreateRequest(), "offline-queue-1")
	if err != nil {
		t.Fatalf("Create() error = %v", err)
	}
	replayed, err := service.Create(context.Background(), principal, KindInbound, inboundCreateRequest(), "offline-queue-1")
	if err != nil {
		t.Fatalf("Create() replay error = %v", err)
	}
	if replayed.DocumentID != first.DocumentID || replayed.DocumentNo != first.DocumentNo {
		t.Fatalf("replay = %d/%s, want %d/%s", replayed.DocumentID, replayed.DocumentNo, first.DocumentID, first.DocumentNo)
	}
	if repo.createCalls != 2 {
		t.Fatalf("createCalls = %d, want 2", repo.createCalls)
	}
	// 清单里只应存在一张单据。
	if len(repo.details) != 1 {
		t.Fatalf("stored documents = %d, want 1", len(repo.details))
	}

	// 同一个 key 换成不同内容必须报错，避免静默写坏数据。
	different := inboundCreateRequest()
	different.Parties[0].PartyName = "另一家公司"
	_, err = service.Create(context.Background(), principal, KindInbound, different, "offline-queue-1")
	wantAppError(t, err, apperror.ErrIdempotencyKeyReused)
}

func TestForbiddenPrincipalsCannotUseDocuments(t *testing.T) {
	repo := newFakeRepository()
	service := ownerService(repo)

	platformAdmin := identity.Principal{UserID: 1, AccountType: identity.AccountTypePlatformAdmin}
	_, err := service.Create(context.Background(), platformAdmin, KindInbound, inboundCreateRequest(), "")
	wantAppError(t, err, apperror.ErrForbidden)

	groupID := uint64(3)
	forced := testPrincipal(groupID)
	forced.MustChangePassword = true
	_, err = service.Create(context.Background(), forced, KindInbound, inboundCreateRequest(), "")
	wantAppError(t, err, apperror.ErrAuthPasswordChangeRequired)

	noGroup := identity.Principal{UserID: 9, AccountType: identity.AccountTypeMember, MemberType: "member"}
	_, err = service.List(context.Background(), noGroup, KindInbound, ListQuery{})
	wantAppError(t, err, apperror.ErrForbidden)
}

func TestListNormalizesQueryAndRejectsInvalidFilters(t *testing.T) {
	repo := newFakeRepository()
	seedGroupMember(repo, 7)
	service := ownerService(repo)
	principal := testPrincipal(3)

	// 默认分页为 1 / 20。
	if _, err := service.List(context.Background(), principal, KindInbound, ListQuery{}); err != nil {
		t.Fatalf("List() error = %v", err)
	}
	if repo.lastListQuery.Page != 1 || repo.lastListQuery.PageSize != 20 {
		t.Fatalf("paging = %d/%d, want 1/20", repo.lastListQuery.Page, repo.lastListQuery.PageSize)
	}

	_, err := service.List(context.Background(), principal, KindInbound, ListQuery{PageSize: 500})
	wantAppError(t, err, apperror.ErrValidationFailed)

	_, err = service.List(context.Background(), principal, KindInbound, ListQuery{Status: Status("unknown")})
	wantAppError(t, err, apperror.ErrValidationFailed)

	_, err = service.List(context.Background(), principal, KindInbound, ListQuery{Month: "2026-13"})
	wantAppError(t, err, apperror.ErrValidationFailed)

	if _, err := service.List(context.Background(), principal, KindInbound, ListQuery{Month: "2026-09"}); err != nil {
		t.Fatalf("List() by month error = %v", err)
	}
	if repo.lastListQuery.MonthStart == nil || repo.lastListQuery.MonthEnd == nil {
		t.Fatal("month range was not applied")
	}
	if repo.lastListQuery.MonthStart.Format("2006-01-02") != "2026-09-01" {
		t.Fatalf("month start = %v", repo.lastListQuery.MonthStart)
	}
	// date_to 是闭区间，必须转成次日零点作为开区间上界。
	if _, err := service.List(context.Background(), principal, KindInbound, ListQuery{DateFrom: "2026-09-01", DateTo: "2026-09-30"}); err != nil {
		t.Fatalf("List() by date error = %v", err)
	}
	if repo.lastListQuery.MonthEnd.Format("2006-01-02") != "2026-10-01" {
		t.Fatalf("date_to upper bound = %v, want 2026-10-01", repo.lastListQuery.MonthEnd)
	}
}

func TestMonthlySummaryUsesCurrentMonthAndScope(t *testing.T) {
	repo := newFakeRepository()
	repo.totals = MonthlyTotals{DocumentCount: 3, DraftCount: 1, SubmittedCnt: 1, VoidedCount: 1,
		TotalAmount: a("146982.33"),
		Parties:     []PartyTotals{{PartyName: "鑫源钢贸", DocumentCount: 1, TotalAmount: a("96400.00")}}}

	service := ownerService(repo)
	result, err := service.MonthlySummary(context.Background(), testPrincipal(3), KindInbound, "", 10)
	if err != nil {
		t.Fatalf("MonthlySummary() error = %v", err)
	}
	// fixedNow 是 2026-09-22，缺省月份必须是当月。
	if result.Month != "2026-09" {
		t.Fatalf("month = %q, want 2026-09", result.Month)
	}
	if result.TotalAmount.String() != "146982.33" {
		t.Fatalf("total = %s", result.TotalAmount)
	}
	if result.TotalAmountUpper != "RMB壹拾肆万陆仟玖佰捌拾贰元叁角叁分" {
		t.Fatalf("upper = %q", result.TotalAmountUpper)
	}
	if len(result.Parties) != 1 || result.Parties[0].PartyName != "鑫源钢贸" {
		t.Fatalf("parties = %+v", result.Parties)
	}
	if _, err := service.MonthlySummary(context.Background(), testPrincipal(3), KindInbound, "2026-13", 10); err == nil {
		t.Fatal("invalid month must be rejected")
	}
}

func TestErrorMappingFromRepository(t *testing.T) {
	repo := newFakeRepository()
	seedGroupMember(repo, 7)
	service := ownerService(repo)
	principal := testPrincipal(3)
	created, err := service.Create(context.Background(), principal, KindInbound, inboundCreateRequest(), "")
	if err != nil {
		t.Fatalf("Create() error = %v", err)
	}

	// 版本不一致必须映射成 409 的资源冲突。
	_, err = service.Update(context.Background(), principal, KindInbound, created.DocumentID,
		UpdateRequest{Version: created.Version + 5, BusinessDate: "2026-09-22", Parties: inboundCreateRequest().Parties}, "")
	wantAppError(t, err, apperror.ErrResourceVersionConflict)

	// 不存在的单据映射成 404。
	_, err = service.Get(context.Background(), principal, KindInbound, 9999)
	wantAppError(t, err, apperror.ErrDocumentNotFound)

	// 出库单接口访问入库单必须视为不存在，避免跨类型越权读取。
	_, err = service.Get(context.Background(), principal, KindOutbound, created.DocumentID)
	wantAppError(t, err, apperror.ErrDocumentNotFound)

	// 仓储内部错误统一降级为 INTERNAL_ERROR 且保留原因。
	repo.loadErr = errors.New("connection reset")
	_, err = service.Get(context.Background(), principal, KindInbound, created.DocumentID)
	wantAppError(t, err, apperror.ErrInternal)
}

func TestPayloadValidationRejectsBadShape(t *testing.T) {
	repo := newFakeRepository()
	seedGroupMember(repo, 7)
	service := ownerService(repo)
	principal := testPrincipal(3)

	cases := map[string]func(request *CreateRequest){
		"缺少往来单位":  func(request *CreateRequest) { request.Parties = nil },
		"往来单位无明细": func(request *CreateRequest) { request.Parties[0].Items = nil },
		"品名为空": func(request *CreateRequest) {
			request.Parties[0].Items[0].ProductName = "  "
		},
		"单价类型非法": func(request *CreateRequest) { request.Parties[0].Items[0].PriceTaxMode = PriceTaxMode("unknown") },
		"数量为负":   func(request *CreateRequest) { request.Parties[0].Items[0].Quantity = -1 },
		"单价超上限": func(request *CreateRequest) {
			request.Parties[0].Items[0].UnitPrice = mustPrice("100000000.0000") + 1
		},
		"日期非法": func(request *CreateRequest) { request.BusinessDate = "2026-02-31" },
	}
	for name, mutate := range cases {
		t.Run(name, func(t *testing.T) {
			request := inboundCreateRequest()
			mutate(&request)
			_, err := service.Create(context.Background(), principal, KindInbound, request, "")
			wantAppError(t, err, apperror.ErrValidationFailed)
		})
	}
}

func pointerUint64(value uint64) *uint64 { return &value }
