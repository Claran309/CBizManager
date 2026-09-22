package settlement

import (
	"context"
	"errors"
	"fmt"
	"sync"
	"testing"
	"time"

	"CBizDocsManager/backend/internal/authorization"
	"CBizDocsManager/backend/internal/document"
	"CBizDocsManager/backend/internal/identity"
	"CBizDocsManager/backend/pkg/apperror"
	"CBizDocsManager/backend/pkg/bizdate"
	"CBizDocsManager/backend/pkg/money"
	"CBizDocsManager/backend/pkg/rmb"
)

// fixedNow 固定「当前时间」，让结算单号（按年月编号）在断言里可预期。
var fixedNow = time.Date(2026, time.September, 22, 10, 30, 0, 0, time.UTC)

/* ------------------------------------------------------------------ 测试桩 */

// fakeAuthorizer 用一张授权表模拟权限引擎；未列出的权限码一律拒绝。
type fakeAuthorizer struct{ granted map[authorization.Code]bool }

func (a fakeAuthorizer) Require(_ context.Context, _ identity.Principal, _ uint64, code authorization.Code) error {
	if a.granted[code] {
		return nil
	}
	return apperror.ErrForbidden
}

type idempotencyEntry struct {
	fingerprint  string
	settlementID uint64
}

// fakeRepository 用内存结构模拟结算仓储，便于在无数据库环境下覆盖业务规则。
type fakeRepository struct {
	mu               sync.Mutex
	nextSettlementID uint64
	details          map[uint64]*Detail
	idempotency      map[string]idempotencyEntry
	documents        map[uint64]SourceDocument
	occupied         map[uint64]bool
	users            map[uint64]identity.UserSummary

	createErr  error
	decideErr  error
	listErr    error
	loadErr    error
	findErr    error
	docsErr    error
	createCall int
	lastCreate CreateInput
	lastDecide DecideInput
	lastQuery  RepositoryQuery
}

func newFakeRepository() *fakeRepository {
	return &fakeRepository{
		nextSettlementID: 1,
		details:          make(map[uint64]*Detail),
		idempotency:      make(map[string]idempotencyEntry),
		documents:        make(map[uint64]SourceDocument),
		occupied:         make(map[uint64]bool),
		users:            make(map[uint64]identity.UserSummary),
	}
}

func (r *fakeRepository) key(scope, apiKey string) string { return scope + "|" + apiKey }

func (r *fakeRepository) nextSequence(month string) int {
	sequence := 0
	for _, detail := range r.details {
		if detail.Settlement.SettlementNo == formatSettlementNo(month, sequence+1) {
			sequence++
		}
	}
	return sequence + 1
}

func (r *fakeRepository) CreateSettlement(_ context.Context, input CreateInput) (Settlement, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.createCall++
	r.lastCreate = input
	if r.createErr != nil {
		return Settlement{}, r.createErr
	}

	if input.IdempotencyKey != "" {
		if entry, ok := r.idempotency[r.key(input.IdempotencyScope, input.IdempotencyKey)]; ok {
			if entry.fingerprint != input.RequestFingerprint {
				return Settlement{}, ErrIdempotencyMismatch
			}
			return r.details[entry.settlementID].Settlement, nil
		}
	}
	for _, snapshot := range input.Sources {
		if r.occupied[snapshot.DocumentID] {
			return Settlement{}, ErrSourceConflict
		}
	}

	settlement := Settlement{
		ID: r.nextSettlementID, GroupID: input.GroupID,
		SettlementNo: formatSettlementNo(monthKey(input.Now), r.nextSequence(monthKey(input.Now))),
		Status:       StatusPending, RequesterUserID: input.RequesterUserID, Remark: input.Remark,
		InboundTotal: input.InboundTotal, OutboundTotal: input.OutboundTotal, GrossProfit: input.GrossProfit,
		SourceCount: len(input.Sources), Version: 1,
		CreatedBy: input.OperatorUserID, UpdatedBy: input.OperatorUserID,
		CreatedAt: input.Now, UpdatedAt: input.Now,
	}
	sources := make([]Source, 0, len(input.Sources))
	for _, snapshot := range input.Sources {
		documentID := snapshot.DocumentID
		sources = append(sources, Source{
			ID: uint64(len(sources) + 1), GroupID: input.GroupID, SettlementID: settlement.ID,
			DocumentID: snapshot.DocumentID, Kind: snapshot.Kind, DocumentNo: snapshot.DocumentNo,
			BusinessUserID: snapshot.BusinessUserID, BusinessDate: snapshot.BusinessDate,
			Amount: snapshot.Amount, ActiveDocumentID: &documentID, CreatedAt: input.Now,
		})
		r.occupied[snapshot.DocumentID] = true
	}
	r.details[settlement.ID] = &Detail{
		Settlement: settlement, Sources: sources,
		Records: []ApprovalRecord{{
			ID: 1, GroupID: input.GroupID, SettlementID: settlement.ID, Action: ActionSubmitted,
			OperatorUserID: input.OperatorUserID, Remark: input.Remark, CreatedAt: input.Now,
		}},
	}
	r.nextSettlementID++
	if input.IdempotencyKey != "" {
		r.idempotency[r.key(input.IdempotencyScope, input.IdempotencyKey)] = idempotencyEntry{
			fingerprint: input.RequestFingerprint, settlementID: settlement.ID,
		}
	}
	return settlement, nil
}

func (r *fakeRepository) DecideSettlement(_ context.Context, input DecideInput) (Settlement, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.lastDecide = input
	if r.decideErr != nil {
		return Settlement{}, r.decideErr
	}
	detail, ok := r.details[input.SettlementID]
	if !ok {
		return Settlement{}, ErrNotFound
	}
	if detail.Settlement.Version != input.ExpectedVersion {
		return Settlement{}, ErrVersionConflict
	}
	if detail.Settlement.Status.IsTerminal() {
		return Settlement{}, ErrStatusInvalid
	}
	detail.Settlement.Status = input.Status
	detail.Settlement.DecisionRemark = input.DecisionRemark
	detail.Settlement.Version = input.ExpectedVersion + 1
	detail.Settlement.UpdatedAt = input.Now
	decidedAt, decidedBy := input.Now, input.OperatorUserID
	detail.Settlement.DecidedAt = &decidedAt
	detail.Settlement.DecidedBy = &decidedBy
	if input.ReleaseSources {
		for index := range detail.Sources {
			detail.Sources[index].ActiveDocumentID = nil
			released := input.Now
			detail.Sources[index].ReleasedAt = &released
			delete(r.occupied, detail.Sources[index].DocumentID)
		}
	}
	action := ActionApproved
	if input.Status == StatusRejected {
		action = ActionRejected
	}
	detail.Records = append(detail.Records, ApprovalRecord{
		ID: uint64(len(detail.Records) + 1), GroupID: input.GroupID, SettlementID: input.SettlementID,
		Action: action, OperatorUserID: input.OperatorUserID, Remark: input.DecisionRemark, CreatedAt: input.Now,
	})
	return detail.Settlement, nil
}

func (r *fakeRepository) FindSettlement(_ context.Context, _, settlementID uint64) (Settlement, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.findErr != nil {
		return Settlement{}, r.findErr
	}
	detail, ok := r.details[settlementID]
	if !ok {
		return Settlement{}, ErrNotFound
	}
	return detail.Settlement, nil
}

func (r *fakeRepository) LoadDetail(_ context.Context, _, settlementID uint64) (Detail, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.loadErr != nil {
		return Detail{}, r.loadErr
	}
	detail, ok := r.details[settlementID]
	if !ok {
		return Detail{}, ErrNotFound
	}
	return *detail, nil
}

func (r *fakeRepository) ListSettlements(_ context.Context, _ uint64, query RepositoryQuery) (Page, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.lastQuery = query
	if r.listErr != nil {
		return Page{}, r.listErr
	}
	page := Page{Page: query.Page, PageSize: query.PageSize}
	for _, detail := range r.details {
		if query.Status != nil && detail.Settlement.Status != *query.Status {
			continue
		}
		if query.OnlyRequesterUserID != 0 && detail.Settlement.RequesterUserID != query.OnlyRequesterUserID {
			continue
		}
		if query.RequesterUserID != nil && detail.Settlement.RequesterUserID != *query.RequesterUserID {
			continue
		}
		requester := r.users[detail.Settlement.RequesterUserID]
		requester.ID = detail.Settlement.RequesterUserID
		page.Items = append(page.Items, Summary{
			Settlement: detail.Settlement,
			Requester:  requester,
		})
	}
	page.Total = int64(len(page.Items))
	return page, nil
}

func (r *fakeRepository) LoadSourceDocuments(_ context.Context, _ uint64, ids []uint64) ([]SourceDocument, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.docsErr != nil {
		return nil, r.docsErr
	}
	result := make([]SourceDocument, 0, len(ids))
	for _, id := range ids {
		if doc, ok := r.documents[id]; ok {
			result = append(result, doc)
		}
	}
	return result, nil
}

func (r *fakeRepository) LoadUsers(_ context.Context, ids []uint64) (map[uint64]identity.UserSummary, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	result := make(map[uint64]identity.UserSummary, len(ids))
	for _, id := range ids {
		if user, ok := r.users[id]; ok {
			result[id] = user
		}
	}
	return result, nil
}

/* ------------------------------------------------------------------ 用例 */

func TestCreateSettlementSnapshotsTotalsAndNumber(t *testing.T) {
	repo := newFakeRepository()
	repo.documents[11] = submittedInbound(11, 14709200, 7)
	repo.documents[12] = submittedOutbound(12, 17352000, 7)
	seedUser(repo, 7, "王业务")
	service := ownerService(repo)

	created, err := service.Create(context.Background(), ownerPrincipal(1, 7), CreateRequest{
		Remark:  textPointer("  九月  第一批  "),
		Sources: []SourceRequest{{DocumentID: 11}, {DocumentID: 12}},
	}, "settle-1")
	if err != nil {
		t.Fatalf("Create() error = %v", err)
	}

	if created.SettlementNo != "JS202609-0001" {
		t.Fatalf("SettlementNo = %q, want JS202609-0001", created.SettlementNo)
	}
	if created.Status != StatusPending || created.SourceCount != 2 {
		t.Fatalf("created = %+v", created)
	}
	// 进项 147092.00、销售 173520.00、毛利 26428.00。
	if created.InboundTotal.String() != "147092.00" || created.OutboundTotal.String() != "173520.00" {
		t.Fatalf("totals = %s / %s", created.InboundTotal, created.OutboundTotal)
	}
	if created.GrossProfit.String() != "26428.00" {
		t.Fatalf("GrossProfit = %s, want 26428.00", created.GrossProfit)
	}
	// 三项金额都由服务端给出人民币大写，客户端不需要自己算。
	if created.GrossProfitUpper != rmb.Upper(created.GrossProfit) {
		t.Fatalf("GrossProfitUpper = %q", created.GrossProfitUpper)
	}
	// 备注要折叠内部空白。
	if created.Remark == nil || *created.Remark != "九月 第一批" {
		t.Fatalf("Remark = %v", created.Remark)
	}
	// 申请本身也是一条审批记录，业务员在历史页能看到「已提交」。
	if len(created.ApprovalRecords) != 1 || created.ApprovalRecords[0].Action != ActionSubmitted {
		t.Fatalf("approval records = %+v", created.ApprovalRecords)
	}
	// 源单据快照要带上单号与金额，保证结算单能独立追溯。
	// 桩数据里的单号由单据 ID 生成（RK20260922-0011），这里顺带锁定「快照原样透传单号」。
	if len(created.Sources) != 2 || created.Sources[0].DocumentNo != "RK20260922-0011" {
		t.Fatalf("sources = %+v", created.Sources)
	}
	if created.Sources[0].Released {
		t.Fatal("newly created settlement source must not be released")
	}
}

func TestCreateSettlementAllowsNegativeGrossProfit(t *testing.T) {
	repo := newFakeRepository()
	repo.documents[11] = submittedInbound(11, 14709200, 7)
	repo.documents[12] = submittedOutbound(12, 11320000, 7)
	service := ownerService(repo)

	created, err := service.Create(context.Background(), ownerPrincipal(1, 7), CreateRequest{
		Sources: []SourceRequest{{DocumentID: 11}, {DocumentID: 12}},
	}, "")
	if err != nil {
		t.Fatalf("Create() error = %v", err)
	}
	// 漏选出库单时毛利润为负，这是允许的（原型会在界面上提示确认）。
	if created.GrossProfit.String() != "-33892.00" {
		t.Fatalf("GrossProfit = %s, want -33892.00", created.GrossProfit)
	}
	if !created.GrossProfit.IsNegative() {
		t.Fatal("GrossProfit should be negative")
	}
	if created.GrossProfitUpper != "RMB负叁万叁仟捌佰玖拾贰元整" {
		t.Fatalf("GrossProfitUpper = %q", created.GrossProfitUpper)
	}
}

func TestCreateSettlementRejectsInvalidSources(t *testing.T) {
	tests := []struct {
		name    string
		prepare func(repo *fakeRepository)
		request CreateRequest
		want    *apperror.Error
	}{
		{
			name:    "未勾选任何源单据",
			prepare: func(*fakeRepository) {},
			request: CreateRequest{Sources: nil},
			want:    apperror.ErrValidationFailed,
		},
		{
			name:    "同一个源单据重复出现",
			prepare: func(repo *fakeRepository) { repo.documents[11] = submittedInbound(11, 100, 7) },
			request: CreateRequest{Sources: []SourceRequest{{DocumentID: 11}, {DocumentID: 11}}},
			want:    apperror.ErrValidationFailed,
		},
		{
			name:    "源单据 ID 为 0",
			prepare: func(repo *fakeRepository) {},
			request: CreateRequest{Sources: []SourceRequest{{DocumentID: 0}}},
			want:    apperror.ErrValidationFailed,
		},
		{
			name: "源单据仍是草稿",
			prepare: func(repo *fakeRepository) {
				doc := submittedInbound(11, 100, 7)
				doc.Status = document.StatusDraft
				repo.documents[11] = doc
			},
			request: CreateRequest{Sources: []SourceRequest{{DocumentID: 11}}},
			want:    apperror.ErrSettlementSourceInvalid,
		},
		{
			name: "源单据已作废",
			prepare: func(repo *fakeRepository) {
				doc := submittedInbound(11, 100, 7)
				doc.Status = document.StatusVoided
				repo.documents[11] = doc
			},
			request: CreateRequest{Sources: []SourceRequest{{DocumentID: 11}}},
			want:    apperror.ErrSettlementSourceInvalid,
		},
		{
			name:    "源单据不存在或跨组",
			prepare: func(repo *fakeRepository) { repo.documents[11] = submittedInbound(11, 100, 7) },
			request: CreateRequest{Sources: []SourceRequest{{DocumentID: 11}, {DocumentID: 99}}},
			want:    apperror.ErrSettlementSourceInvalid,
		},
		{
			name: "源单据已被其他有效结算单占用",
			prepare: func(repo *fakeRepository) {
				repo.documents[11] = submittedInbound(11, 100, 7)
				repo.occupied[11] = true
			},
			request: CreateRequest{Sources: []SourceRequest{{DocumentID: 11}}},
			want:    apperror.ErrSettlementSourceConflict,
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			repo := newFakeRepository()
			tt.prepare(repo)
			seedUser(repo, 7, "王业务")
			service := ownerService(repo)

			_, err := service.Create(context.Background(), ownerPrincipal(1, 7), tt.request, "")
			wantAppError(t, err, tt.want)
		})
	}
}

func TestCreateSettlementRequiresVisibleSources(t *testing.T) {
	repo := newFakeRepository()
	repo.documents[11] = submittedInbound(11, 100, 7) // 属于业务员 7
	seedUser(repo, 7, "王业务")
	seedUser(repo, 8, "李业务")
	service := newTestService(repo, fakeAuthorizer{granted: map[authorization.Code]bool{}})

	// 子账号默认只能拿自己的单据去结算。
	_, err := service.Create(context.Background(), memberPrincipal(1, 8), CreateRequest{
		Sources: []SourceRequest{{DocumentID: 11}},
	}, "")
	wantAppError(t, err, apperror.ErrForbidden)

	// 授予查看他人单据后即可代他申请结算。
	allowed := newTestService(repo, fakeAuthorizer{granted: map[authorization.Code]bool{
		authorization.PermissionDocumentViewOthers: true,
	}})
	if _, err := allowed.Create(context.Background(), memberPrincipal(1, 8), CreateRequest{
		Sources: []SourceRequest{{DocumentID: 11}},
	}, ""); err != nil {
		t.Fatalf("Create(with view_others) error = %v", err)
	}
}

func TestCreateSettlementIsIdempotent(t *testing.T) {
	repo := newFakeRepository()
	repo.documents[11] = submittedInbound(11, 100, 7)
	seedUser(repo, 7, "王业务")
	service := ownerService(repo)

	request := CreateRequest{Sources: []SourceRequest{{DocumentID: 11}}}
	first, err := service.Create(context.Background(), ownerPrincipal(1, 7), request, "same-key")
	if err != nil {
		t.Fatalf("Create(first) error = %v", err)
	}
	second, err := service.Create(context.Background(), ownerPrincipal(1, 7), request, "same-key")
	if err != nil {
		t.Fatalf("Create(replay) error = %v", err)
	}
	if first.SettlementID != second.SettlementID {
		t.Fatalf("idempotent replay created a new settlement: %d -> %d", first.SettlementID, second.SettlementID)
	}
	if repo.createCall != 2 {
		t.Fatalf("createCall = %d, want 2", repo.createCall)
	}

	// 同一个幂等键换一份载荷必须报错，而不是静默返回旧结算单。
	repo.documents[12] = submittedInbound(12, 200, 7)
	_, err = service.Create(context.Background(), ownerPrincipal(1, 7), CreateRequest{
		Sources: []SourceRequest{{DocumentID: 11}, {DocumentID: 12}},
	}, "same-key")
	wantAppError(t, err, apperror.ErrIdempotencyKeyReused)
}

func TestApprovalRequiresPermissionAndPendingStatus(t *testing.T) {
	repo := newFakeRepository()
	repo.documents[11] = submittedInbound(11, 100, 7)
	seedUser(repo, 7, "王业务")
	seedUser(repo, 8, "李业务")
	owner := ownerService(repo)

	created, err := owner.Create(context.Background(), ownerPrincipal(1, 7), CreateRequest{
		Sources: []SourceRequest{{DocumentID: 11}},
	}, "")
	if err != nil {
		t.Fatalf("Create() error = %v", err)
	}

	// 没有 settlement.approve 的子账号不能审批。
	plain := newTestService(repo, fakeAuthorizer{granted: map[authorization.Code]bool{}})
	_, err = plain.Approve(context.Background(), memberPrincipal(1, 8), created.SettlementID, DecideRequest{Version: created.Version})
	wantAppError(t, err, apperror.ErrForbidden)

	// 授权后可以审批通过。
	approver := newTestService(repo, fakeAuthorizer{granted: map[authorization.Code]bool{
		authorization.PermissionSettlementApprove: true,
	}})
	approved, err := approver.Approve(context.Background(), memberPrincipal(1, 8), created.SettlementID, DecideRequest{
		Version: created.Version, Remark: textPointer("金额核对无误"),
	})
	if err != nil {
		t.Fatalf("Approve() error = %v", err)
	}
	if approved.Status != StatusApproved || approved.DecidedAt == nil || approved.DecidedBy == nil {
		t.Fatalf("approved = %+v", approved)
	}
	if len(approved.ApprovalRecords) != 2 || approved.ApprovalRecords[1].Action != ActionApproved {
		t.Fatalf("approval records = %+v", approved.ApprovalRecords)
	}

	// 单级审批：重复审批返回状态非法。
	_, err = approver.Approve(context.Background(), memberPrincipal(1, 8), created.SettlementID, DecideRequest{Version: approved.Version})
	wantAppError(t, err, apperror.ErrSettlementStatusInvalid)
}

func TestRejectRequiresRemarkAndReleasesSources(t *testing.T) {
	repo := newFakeRepository()
	repo.documents[11] = submittedInbound(11, 100, 7)
	seedUser(repo, 7, "王业务")
	service := ownerService(repo)

	created, err := service.Create(context.Background(), ownerPrincipal(1, 7), CreateRequest{
		Sources: []SourceRequest{{DocumentID: 11}},
	}, "")
	if err != nil {
		t.Fatalf("Create() error = %v", err)
	}

	// 驳回原因必填：空值与纯空白都要拒绝。
	_, err = service.Reject(context.Background(), ownerPrincipal(1, 7), created.SettlementID, DecideRequest{Version: created.Version})
	wantAppError(t, err, apperror.ErrSettlementRemarkRequired)
	_, err = service.Reject(context.Background(), ownerPrincipal(1, 7), created.SettlementID, DecideRequest{
		Version: created.Version, Remark: textPointer("   "),
	})
	wantAppError(t, err, apperror.ErrSettlementRemarkRequired)

	rejected, err := service.Reject(context.Background(), ownerPrincipal(1, 7), created.SettlementID, DecideRequest{
		Version: created.Version, Remark: textPointer("来源单据 CK20260922-0009 金额有误，请核对后重提"),
	})
	if err != nil {
		t.Fatalf("Reject() error = %v", err)
	}
	if rejected.Status != StatusRejected || rejected.DecisionRemark == nil {
		t.Fatalf("rejected = %+v", rejected)
	}
	// 驳回必须释放源单据的活跃引用，业务员改完源单才能重新申请。
	if !rejected.Sources[0].Released {
		t.Fatal("rejected settlement must release its sources")
	}
	if _, err := service.Create(context.Background(), ownerPrincipal(1, 7), CreateRequest{
		Sources: []SourceRequest{{DocumentID: 11}},
	}, ""); err != nil {
		t.Fatalf("Create(after reject) error = %v", err)
	}
}

func TestApprovalVersionGuards(t *testing.T) {
	repo := newFakeRepository()
	repo.documents[11] = submittedInbound(11, 100, 7)
	seedUser(repo, 7, "王业务")
	service := ownerService(repo)

	created, err := service.Create(context.Background(), ownerPrincipal(1, 7), CreateRequest{
		Sources: []SourceRequest{{DocumentID: 11}},
	}, "")
	if err != nil {
		t.Fatalf("Create() error = %v", err)
	}

	// version 必须携带。
	_, err = service.Approve(context.Background(), ownerPrincipal(1, 7), created.SettlementID, DecideRequest{})
	wantAppError(t, err, apperror.ErrValidationFailed)

	// 过期版本号必须冲突。
	_, err = service.Approve(context.Background(), ownerPrincipal(1, 7), created.SettlementID, DecideRequest{
		Version: created.Version + 5,
	})
	wantAppError(t, err, apperror.ErrResourceVersionConflict)

	// 结算单 ID 非法。
	_, err = service.Approve(context.Background(), ownerPrincipal(1, 7), 0, DecideRequest{Version: 1})
	wantAppError(t, err, apperror.ErrValidationFailed)
}

func TestListNormalizesQueryAndEnforcesScope(t *testing.T) {
	repo := newFakeRepository()
	repo.documents[11] = submittedInbound(11, 100, 7)
	seedUser(repo, 7, "王业务")
	seedUser(repo, 8, "李业务")
	owner := ownerService(repo)
	if _, err := owner.Create(context.Background(), ownerPrincipal(1, 7), CreateRequest{
		Sources: []SourceRequest{{DocumentID: 11}},
	}, ""); err != nil {
		t.Fatalf("Create() error = %v", err)
	}

	// 主账号看全组。
	page, err := owner.List(context.Background(), ownerPrincipal(1, 7), ListQuery{})
	if err != nil {
		t.Fatalf("owner List() error = %v", err)
	}
	if page.Total != 1 || page.Page != 1 || page.PageSize != 20 {
		t.Fatalf("owner List() = %+v", page)
	}
	if repo.lastQuery.OnlyRequesterUserID != 0 {
		t.Fatalf("owner query must not restrict requester, got %d", repo.lastQuery.OnlyRequesterUserID)
	}

	// 子账号默认只看本人，且不能显式查他人。
	member := newTestService(repo, fakeAuthorizer{granted: map[authorization.Code]bool{}})
	page, err = member.List(context.Background(), memberPrincipal(1, 8), ListQuery{})
	if err != nil {
		t.Fatalf("member List() error = %v", err)
	}
	if page.Total != 0 || repo.lastQuery.OnlyRequesterUserID != 8 {
		t.Fatalf("member List() = %+v, onlyRequester = %d", page, repo.lastQuery.OnlyRequesterUserID)
	}
	_, err = member.List(context.Background(), memberPrincipal(1, 8), ListQuery{RequesterUserID: 7})
	wantAppError(t, err, apperror.ErrForbidden)

	// 参数校验：非法状态、非法月份、超限分页都要拒绝。
	for _, query := range []ListQuery{
		{Status: Status("done")},
		{Month: "2026-13"},
		{Month: "2026"},
		{PageSize: 500},
	} {
		if _, err := owner.List(context.Background(), ownerPrincipal(1, 7), query); err == nil {
			t.Fatalf("List(%+v) = nil error, want VALIDATION_FAILED", query)
		} else {
			wantAppError(t, err, apperror.ErrValidationFailed)
		}
	}

	// 合法月份要转成左闭右开区间。
	if _, err := owner.List(context.Background(), ownerPrincipal(1, 7), ListQuery{Month: "2026-09"}); err != nil {
		t.Fatalf("List(month) error = %v", err)
	}
	if repo.lastQuery.MonthStart == nil || repo.lastQuery.MonthEnd == nil {
		t.Fatalf("month range not normalized: %+v", repo.lastQuery)
	}
	if !repo.lastQuery.MonthStart.Equal(time.Date(2026, time.September, 1, 0, 0, 0, 0, time.UTC)) {
		t.Fatalf("MonthStart = %s", repo.lastQuery.MonthStart)
	}
}

func TestGetEnforcesDataScope(t *testing.T) {
	repo := newFakeRepository()
	repo.documents[11] = submittedInbound(11, 100, 7)
	seedUser(repo, 7, "王业务")
	seedUser(repo, 8, "李业务")
	owner := ownerService(repo)

	created, err := owner.Create(context.Background(), ownerPrincipal(1, 7), CreateRequest{
		Sources: []SourceRequest{{DocumentID: 11}},
	}, "")
	if err != nil {
		t.Fatalf("Create() error = %v", err)
	}

	member := newTestService(repo, fakeAuthorizer{granted: map[authorization.Code]bool{}})
	_, err = member.Get(context.Background(), memberPrincipal(1, 8), created.SettlementID)
	wantAppError(t, err, apperror.ErrForbidden)

	// 申请人自己能读。
	if _, err := owner.Get(context.Background(), ownerPrincipal(1, 7), created.SettlementID); err != nil {
		t.Fatalf("owner Get() error = %v", err)
	}
	// 不存在的结算单按「找不到」处理。
	_, err = owner.Get(context.Background(), ownerPrincipal(1, 7), 9999)
	wantAppError(t, err, apperror.ErrSettlementNotFound)
}

func TestForbiddenPrincipalsCannotUseSettlements(t *testing.T) {
	repo := newFakeRepository()
	seedUser(repo, 7, "王业务")
	service := ownerService(repo)
	request := CreateRequest{Sources: []SourceRequest{{DocumentID: 11}}}

	// 平台管理员没有组，不能操作组内业务数据。
	_, err := service.Create(context.Background(), identity.Principal{UserID: 1, AccountType: identity.AccountTypePlatformAdmin}, request, "")
	wantAppError(t, err, apperror.ErrForbidden)
	// 没有组身份的成员也不行。
	_, err = service.Create(context.Background(), identity.Principal{UserID: 2, AccountType: identity.AccountTypeMember, MemberType: "member"}, request, "")
	wantAppError(t, err, apperror.ErrForbidden)
	// 未改初始密码时先要求改密。
	forced := ownerPrincipal(1, 7)
	forced.MustChangePassword = true
	_, err = service.Create(context.Background(), forced, request, "")
	wantAppError(t, err, apperror.ErrAuthPasswordChangeRequired)
	// 成员类型与账号类型不匹配（脏身份）也拒绝。
	dirty := ownerPrincipal(1, 7)
	dirty.MemberType = "member"
	_, err = service.Create(context.Background(), dirty, request, "")
	wantAppError(t, err, apperror.ErrForbidden)
}

func TestRepositoryErrorsAreMappedToStableCodes(t *testing.T) {
	repo := newFakeRepository()
	repo.documents[11] = submittedInbound(11, 100, 7)
	seedUser(repo, 7, "王业务")

	tests := []struct {
		name   string
		inject func(repo *fakeRepository)
		call   func(service *Service) error
		want   *apperror.Error
	}{
		{
			name:   "创建时源单据冲突",
			inject: func(repo *fakeRepository) { repo.createErr = ErrSourceConflict },
			call: func(service *Service) error {
				_, err := service.Create(context.Background(), ownerPrincipal(1, 7), CreateRequest{Sources: []SourceRequest{{DocumentID: 11}}}, "")
				return err
			},
			want: apperror.ErrSettlementSourceConflict,
		},
		{
			name:   "创建时幂等键复用",
			inject: func(repo *fakeRepository) { repo.createErr = ErrIdempotencyMismatch },
			call: func(service *Service) error {
				_, err := service.Create(context.Background(), ownerPrincipal(1, 7), CreateRequest{Sources: []SourceRequest{{DocumentID: 11}}}, "k")
				return err
			},
			want: apperror.ErrIdempotencyKeyReused,
		},
		{
			name:   "读取时不存在",
			inject: func(repo *fakeRepository) { repo.loadErr = ErrNotFound },
			call: func(service *Service) error {
				_, err := service.Get(context.Background(), ownerPrincipal(1, 7), 1)
				return err
			},
			want: apperror.ErrSettlementNotFound,
		},
		{
			name: "审批时状态非法",
			inject: func(repo *fakeRepository) {
				// 先放一张「待审批」的结算单：Service 的前置读取能通过，
				// 但在真正写结论时仓储才报告状态非法（模拟并发下被他人抢先审批）。
				repo.details[1] = &Detail{Settlement: Settlement{
					ID: 1, GroupID: 1, Status: StatusPending, RequesterUserID: 7, Version: 1,
				}}
				repo.decideErr = ErrStatusInvalid
			},
			call: func(service *Service) error {
				_, err := service.Approve(context.Background(), ownerPrincipal(1, 7), 1, DecideRequest{Version: 1})
				return err
			},
			want: apperror.ErrSettlementStatusInvalid,
		},
		{
			name: "读取源单据失败",
			// 这里要模拟的是「读库失败」而不是「单据不存在」：真实仓储在查询报错时
			// 返回的是包装后的内部错误，客户端不应该看到任何库层细节。
			inject: func(repo *fakeRepository) { repo.docsErr = errors.New("mysql: connection refused") },
			call: func(service *Service) error {
				_, err := service.Create(context.Background(), ownerPrincipal(1, 7), CreateRequest{Sources: []SourceRequest{{DocumentID: 11}}}, "")
				return err
			},
			want: apperror.ErrInternal,
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			target := newFakeRepository()
			target.documents[11] = submittedInbound(11, 100, 7)
			seedUser(target, 7, "王业务")
			tt.inject(target)
			wantAppError(t, tt.call(ownerService(target)), tt.want)
		})
	}
	// 单号撞车对客户端表现为内部错误（仓储内部会重试）。
	if got := mapRepositoryError("create", ErrSettlementNoConflict); got != apperror.ErrInternal {
		t.Fatalf("mapRepositoryError(ErrSettlementNoConflict) = %v", got)
	}
}

/* ------------------------------------------------------------------ 辅助 */

// monthKey 返回结算单号使用的紧凑年月（YYYYMM），直接复用生产格式化函数，
// 避免测试桩与仓储各写一套导致单号口径漂移。
func monthKey(at time.Time) string { return bizdate.FormatMonthCompact(at) }

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

func ownerService(repo *fakeRepository) *Service {
	return newTestService(repo, fakeAuthorizer{granted: map[authorization.Code]bool{}})
}

func seedUser(repo *fakeRepository, userID uint64, displayName string) {
	repo.users[userID] = identity.UserSummary{
		ID: userID, Username: fmt.Sprintf("user%d", userID), DisplayName: displayName,
		AccountType: identity.AccountTypeMember,
	}
}

func submittedInbound(id uint64, amount cents, businessUser uint64) SourceDocument {
	return SourceDocument{
		ID: id, Kind: document.KindInbound, DocumentNo: fmt.Sprintf("RK20260922-%04d", id),
		Status: document.StatusSubmitted, BusinessUserID: businessUser,
		BusinessDate: time.Date(2026, time.September, 22, 0, 0, 0, 0, time.UTC), TotalAmount: amount,
	}
}

func submittedOutbound(id uint64, amount cents, businessUser uint64) SourceDocument {
	doc := submittedInbound(id, amount, businessUser)
	doc.Kind = document.KindOutbound
	doc.DocumentNo = fmt.Sprintf("CK20260922-%04d", id)
	return doc
}

// cents 让测试数据一眼看出是「分」，避免把金额和元搞混。
type cents = money.Amount

func textPointer(value string) *string { return &value }

func wantAppError(t *testing.T, err error, expected *apperror.Error) {
	t.Helper()
	if err == nil {
		t.Fatalf("error = nil, want %s", expected.Code)
	}
	var appErr *apperror.Error
	if !errors.As(err, &appErr) {
		t.Fatalf("error = %v (%T), want %s", err, err, expected.Code)
	}
	if appErr.Code != expected.Code {
		t.Fatalf("error code = %s, want %s", appErr.Code, expected.Code)
	}
}
