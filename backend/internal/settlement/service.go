package settlement

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"strings"
	"time"

	"CBizDocsManager/backend/internal/authorization"
	"CBizDocsManager/backend/internal/document"
	"CBizDocsManager/backend/internal/identity"
	"CBizDocsManager/backend/pkg/apperror"
	"CBizDocsManager/backend/pkg/bizdate"
	"CBizDocsManager/backend/pkg/money"
)

var (
	// ErrNotFound 表示结算单不存在或不属于当前组。
	ErrNotFound = errors.New("settlement not found")
	// ErrVersionConflict 表示乐观锁版本不匹配（含已被审批过的重复审批）。
	ErrVersionConflict = errors.New("settlement version conflict")
	// ErrStatusInvalid 表示当前审批状态不允许该操作。
	ErrStatusInvalid = errors.New("settlement status invalid")
	// ErrSourceConflict 表示源单据已被其他有效结算单引用。
	ErrSourceConflict = errors.New("settlement source already referenced")
	// ErrSettlementNoConflict 表示结算单号生成撞车，需要重新生成（仓储内部重试）。
	ErrSettlementNoConflict = errors.New("settlement number conflict")
	// ErrIdempotencyMismatch 表示同一个幂等键被用于了不同的请求体。
	ErrIdempotencyMismatch = errors.New("idempotency key reused with different payload")
)

// Repository 是结算模块的存储接口。所有方法都必须带 group_id 条件，保证组间数据隔离。
type Repository interface {
	// CreateSettlement 在事务内创建结算单、写入源单据快照与「提交申请」审批记录。
	CreateSettlement(ctx context.Context, input CreateInput) (Settlement, error)
	// DecideSettlement 在事务内写入审批结论并追加审批记录；驳回时释放源单据活跃引用。
	DecideSettlement(ctx context.Context, input DecideInput) (Settlement, error)
	// FindSettlement 读取结算单主表。
	FindSettlement(ctx context.Context, groupID, settlementID uint64) (Settlement, error)
	// LoadDetail 读取结算单详情（主表 + 源单据 + 审批记录）。
	LoadDetail(ctx context.Context, groupID, settlementID uint64) (Detail, error)
	// ListSettlements 分页查询结算单列表。
	ListSettlements(ctx context.Context, groupID uint64, query RepositoryQuery) (Page, error)
	// LoadSourceDocuments 读取候选源单据的当前状态，用于校验与生成金额快照。
	LoadSourceDocuments(ctx context.Context, groupID uint64, ids []uint64) ([]SourceDocument, error)
	// LoadUsers 返回申请人 / 审批人摘要，避免 Service 直接依赖 identity 仓储。
	LoadUsers(ctx context.Context, ids []uint64) (map[uint64]identity.UserSummary, error)
}

// Service 承载结算单的业务规则：数据范围、源单据校验、金额快照、单级审批与幂等。
type Service struct {
	repo       Repository
	authorizer authorization.Authorizer
	now        func() time.Time
}

// NewService 创建结算服务。
func NewService(repo Repository, authorizer authorization.Authorizer) *Service {
	return &Service{repo: repo, authorizer: authorizer, now: time.Now}
}

/* ------------------------------------------------------------------ 对外能力 */

// Create 提交结算申请：按勾选的源单据汇总进项 / 销售 / 毛利润并生成待审批结算单。
// idempotencyKey 为空表示客户端未启用幂等（安卓离线队列会启用）。
func (s *Service) Create(ctx context.Context, principal identity.Principal, request CreateRequest, idempotencyKey string) (*SettlementData, error) {
	scope, err := s.resolveScope(ctx, principal)
	if err != nil {
		return nil, err
	}

	rawIDs := make([]uint64, 0, len(request.Sources))
	for _, source := range request.Sources {
		rawIDs = append(rawIDs, source.DocumentID)
	}
	sourceIDs, err := normalizeSourceIDs(rawIDs)
	if err != nil {
		return nil, apperror.ErrValidationFailed
	}
	remark, err := normalizeOptionalText(request.Remark, 500)
	if err != nil {
		return nil, apperror.ErrValidationFailed
	}

	// 一次性读出全部源单据，逐张校验「同组 + 已提交 + 在本人可见范围内」。
	documents, err := s.repo.LoadSourceDocuments(ctx, scope.groupID, sourceIDs)
	if err != nil {
		return nil, mapRepositoryError("load source documents", err)
	}
	if len(documents) != len(sourceIDs) {
		// 少读到的要么不存在，要么属于别的组；两种都不该暴露给客户端。
		return nil, apperror.ErrSettlementSourceInvalid
	}
	byID := make(map[uint64]SourceDocument, len(documents))
	for _, doc := range documents {
		byID[doc.ID] = doc
	}

	snapshots := make([]SourceSnapshot, 0, len(sourceIDs))
	var inboundTotal, outboundTotal money.Amount
	for _, id := range sourceIDs {
		doc := byID[id]
		if doc.Status != document.StatusSubmitted {
			// 草稿与已作废单据都不允许参与结算：前者金额还没定，后者已失效。
			return nil, apperror.ErrSettlementSourceInvalid
		}
		if doc.BusinessUserID != principal.UserID && !scope.canViewOthers {
			return nil, apperror.ErrForbidden
		}
		snapshots = append(snapshots, SourceSnapshot{
			DocumentID: doc.ID, Kind: doc.Kind, DocumentNo: doc.DocumentNo,
			BusinessUserID: doc.BusinessUserID, BusinessDate: doc.BusinessDate, Amount: doc.TotalAmount,
		})
		if doc.Kind.IsInbound() {
			inboundTotal = inboundTotal.Add(doc.TotalAmount)
		} else {
			outboundTotal = outboundTotal.Add(doc.TotalAmount)
		}
	}
	// 毛利润 = 销售合计 − 进项合计，允许为负（选了出库却漏选入库时界面会提示）。
	grossProfit := outboundTotal.Sub(inboundTotal)

	now := s.now().UTC()
	settlement, err := s.repo.CreateSettlement(ctx, CreateInput{
		GroupID: scope.groupID, RequesterUserID: principal.UserID, Remark: remark,
		InboundTotal: inboundTotal, OutboundTotal: outboundTotal, GrossProfit: grossProfit,
		Sources: snapshots, OperatorUserID: principal.UserID, Now: now,
		IdempotencyScope:   idempotencyScope("create"),
		IdempotencyKey:     idempotencyKey,
		RequestFingerprint: fingerprintCreate(principal.UserID, remark, snapshots),
		AuditAction:        "settlement.created",
		AuditSummary:       "已提交申请",
	})
	if err != nil {
		return nil, mapRepositoryError("create settlement", err)
	}
	return s.detailData(ctx, scope, settlement.ID)
}

// Get 读取结算单详情。
func (s *Service) Get(ctx context.Context, principal identity.Principal, settlementID uint64) (*SettlementData, error) {
	scope, err := s.resolveScope(ctx, principal)
	if err != nil {
		return nil, err
	}
	if settlementID == 0 {
		return nil, apperror.ErrValidationFailed
	}
	detail, err := s.repo.LoadDetail(ctx, scope.groupID, settlementID)
	if err != nil {
		return nil, mapRepositoryError("load settlement", err)
	}
	if err := s.ensureVisible(scope, principal, detail.Settlement); err != nil {
		return nil, err
	}
	return s.buildDetailData(ctx, detail)
}

// List 分页查询结算单，并按权限收敛数据范围。
func (s *Service) List(ctx context.Context, principal identity.Principal, query ListQuery) (*SettlementPageData, error) {
	scope, err := s.resolveScope(ctx, principal)
	if err != nil {
		return nil, err
	}
	repositoryQuery, err := buildRepositoryQuery(scope, principal, query)
	if err != nil {
		return nil, err
	}
	page, err := s.repo.ListSettlements(ctx, scope.groupID, repositoryQuery)
	if err != nil {
		return nil, mapRepositoryError("list settlements", err)
	}
	items := make([]SettlementSummaryData, 0, len(page.Items))
	for _, summary := range page.Items {
		items = append(items, toSettlementSummaryData(summary))
	}
	return &SettlementPageData{Items: items, Page: page.Page, PageSize: page.PageSize, Total: page.Total}, nil
}

// Approve 审批通过。
func (s *Service) Approve(ctx context.Context, principal identity.Principal, settlementID uint64, request DecideRequest) (*SettlementData, error) {
	return s.decide(ctx, principal, settlementID, request, StatusApproved)
}

// Reject 审批驳回；驳回必须填写原因，并释放源单据以便业务员改单后重新申请。
func (s *Service) Reject(ctx context.Context, principal identity.Principal, settlementID uint64, request DecideRequest) (*SettlementData, error) {
	return s.decide(ctx, principal, settlementID, request, StatusRejected)
}

/* ------------------------------------------------------------------ 审批 */

func (s *Service) decide(ctx context.Context, principal identity.Principal, settlementID uint64, request DecideRequest, target Status) (*SettlementData, error) {
	scope, err := s.resolveScope(ctx, principal)
	if err != nil {
		return nil, err
	}
	if !scope.canApprove {
		// 无审批权限直接拒绝，不允许「先读到数据再被拒」。
		return nil, apperror.ErrForbidden
	}
	if settlementID == 0 || request.Version == 0 {
		return nil, apperror.ErrValidationFailed
	}

	remark, err := normalizeOptionalText(request.Remark, 500)
	if err != nil {
		return nil, apperror.ErrValidationFailed
	}
	if target == StatusRejected && remark == nil {
		// 驳回原因必填：业务员要靠它知道该改哪张源单据。
		return nil, apperror.ErrSettlementRemarkRequired
	}

	current, err := s.repo.FindSettlement(ctx, scope.groupID, settlementID)
	if err != nil {
		return nil, mapRepositoryError("find settlement", err)
	}
	if current.Status.IsTerminal() {
		// 单级审批：通过与驳回都是终态，重复审批返回冲突让客户端重新拉取。
		return nil, apperror.ErrSettlementStatusInvalid
	}

	now := s.now().UTC()
	settlement, err := s.repo.DecideSettlement(ctx, DecideInput{
		GroupID: scope.groupID, SettlementID: settlementID, OperatorUserID: principal.UserID,
		ExpectedVersion: request.Version, Status: target, DecisionRemark: remark,
		ReleaseSources: target == StatusRejected, Now: now,
		AuditAction:  auditAction(target),
		AuditSummary: fmt.Sprintf("已%s", target.Label()),
	})
	if err != nil {
		return nil, mapRepositoryError("decide settlement", err)
	}
	return s.detailData(ctx, scope, settlement.ID)
}

/* ------------------------------------------------------------------ 权限与数据范围 */

// scope 描述当前身份在结算模块中的可见范围与审批资格。
type scope struct {
	groupID       uint64
	isOwner       bool
	canViewOthers bool
	canEditOthers bool
	canApprove    bool
}

func (s *Service) resolveScope(ctx context.Context, principal identity.Principal) (scope, error) {
	if principal.GroupID == nil || principal.AccountType == identity.AccountTypePlatformAdmin {
		return scope{}, apperror.ErrForbidden
	}
	if principal.MustChangePassword {
		return scope{}, apperror.ErrAuthPasswordChangeRequired
	}
	result := scope{groupID: *principal.GroupID}
	if principal.AccountType == identity.AccountTypeGroupOwner && principal.MemberType == "owner" {
		// 主账号默认拥有组内全部业务与管理权限，其中包含审批。
		result.isOwner, result.canViewOthers, result.canEditOthers, result.canApprove = true, true, true, true
		return result, nil
	}
	if principal.AccountType != identity.AccountTypeMember || principal.MemberType != "member" {
		return scope{}, apperror.ErrForbidden
	}
	var err error
	if result.canViewOthers, err = s.hasPermission(ctx, principal, result.groupID, authorization.PermissionDocumentViewOthers); err != nil {
		return scope{}, err
	}
	if result.canEditOthers, err = s.hasPermission(ctx, principal, result.groupID, authorization.PermissionDocumentEditOthers); err != nil {
		return scope{}, err
	}
	if result.canApprove, err = s.hasPermission(ctx, principal, result.groupID, authorization.PermissionSettlementApprove); err != nil {
		return scope{}, err
	}
	return result, nil
}

// hasPermission 把「未授予权限」翻译成 false，而不是向客户端抛 403：
// 子账号默认只能看本人结算单，这是正常业务路径而不是越权。
func (s *Service) hasPermission(ctx context.Context, principal identity.Principal, groupID uint64, code authorization.Code) (bool, error) {
	err := s.authorizer.Require(ctx, principal, groupID, code)
	switch {
	case err == nil:
		return true, nil
	case errors.Is(err, apperror.ErrForbidden):
		return false, nil
	default:
		return false, err
	}
}

func (s *Service) ensureVisible(scope scope, principal identity.Principal, current Settlement) error {
	if current.RequesterUserID == principal.UserID || scope.canViewOthers {
		return nil
	}
	return apperror.ErrForbidden
}

func buildRepositoryQuery(scope scope, principal identity.Principal, query ListQuery) (RepositoryQuery, error) {
	page, pageSize := query.Page, query.PageSize
	if page < 1 {
		page = 1
	}
	if pageSize < 1 {
		pageSize = 20
	}
	if pageSize > 100 {
		return RepositoryQuery{}, apperror.ErrValidationFailed
	}
	result := RepositoryQuery{Page: page, PageSize: pageSize, Keyword: strings.TrimSpace(query.Keyword)}
	if query.Status != "" {
		status, ok := ParseStatus(string(query.Status))
		if !ok {
			return RepositoryQuery{}, apperror.ErrValidationFailed
		}
		result.Status = &status
	}
	if strings.TrimSpace(query.Month) != "" {
		start, end, err := bizdate.ParseMonth(query.Month)
		if err != nil {
			return RepositoryQuery{}, apperror.ErrValidationFailed
		}
		result.MonthStart, result.MonthEnd = &start, &end
	}

	if !scope.canViewOthers {
		// 没有查看他人权限时，只允许查询本人结算单；显式指定他人直接拒绝。
		if query.RequesterUserID != 0 && query.RequesterUserID != principal.UserID {
			return RepositoryQuery{}, apperror.ErrForbidden
		}
		result.OnlyRequesterUserID = principal.UserID
		return result, nil
	}
	if query.RequesterUserID != 0 {
		requester := query.RequesterUserID
		result.RequesterUserID = &requester
	}
	return result, nil
}

/* ------------------------------------------------------------------ 内部工具 */

func (s *Service) detailData(ctx context.Context, scope scope, settlementID uint64) (*SettlementData, error) {
	detail, err := s.repo.LoadDetail(ctx, scope.groupID, settlementID)
	if err != nil {
		return nil, mapRepositoryError("load settlement", err)
	}
	return s.buildDetailData(ctx, detail)
}

// buildDetailData 一次性收集申请人、审批人与源单据业务员，避免逐行查用户表。
func (s *Service) buildDetailData(ctx context.Context, detail Detail) (*SettlementData, error) {
	ids := []uint64{detail.Settlement.RequesterUserID}
	if detail.Settlement.DecidedBy != nil {
		ids = append(ids, *detail.Settlement.DecidedBy)
	}
	for _, source := range detail.Sources {
		ids = append(ids, source.BusinessUserID)
	}
	for _, record := range detail.Records {
		ids = append(ids, record.OperatorUserID)
	}
	users, err := s.repo.LoadUsers(ctx, ids)
	if err != nil {
		return nil, mapRepositoryError("load settlement users", err)
	}

	requester := users[detail.Settlement.RequesterUserID]
	requester.ID = detail.Settlement.RequesterUserID
	var decidedBy *identity.UserSummary
	if detail.Settlement.DecidedBy != nil {
		summary := users[*detail.Settlement.DecidedBy]
		summary.ID = *detail.Settlement.DecidedBy
		decidedBy = &summary
	}
	return buildSettlementData(detail, requester, decidedBy, users, users), nil
}

func mapRepositoryError(operation string, err error) error {
	switch {
	case errors.Is(err, ErrNotFound):
		return apperror.ErrSettlementNotFound
	case errors.Is(err, ErrVersionConflict):
		return apperror.ErrResourceVersionConflict
	case errors.Is(err, ErrStatusInvalid):
		return apperror.ErrSettlementStatusInvalid
	case errors.Is(err, ErrSourceConflict):
		return apperror.ErrSettlementSourceConflict
	case errors.Is(err, ErrIdempotencyMismatch):
		return apperror.ErrIdempotencyKeyReused
	case errors.Is(err, ErrSettlementNoConflict):
		return apperror.ErrInternal
	default:
		return apperror.Wrap(apperror.ErrInternal, fmt.Errorf("%s: %w", operation, err))
	}
}

func auditAction(target Status) string {
	if target == StatusRejected {
		return "settlement.rejected"
	}
	return "settlement.approved"
}

func idempotencyScope(action string) string { return fmt.Sprintf("settlement.%s", action) }

// fingerprintCreate 生成申请结算的请求指纹：同一个幂等键必须对应同一份内容，
// 否则说明客户端复用了幂等键，必须报错而不是静默返回旧结算单。
func fingerprintCreate(requester uint64, remark *string, sources []SourceSnapshot) string {
	hasher := sha256.New()
	fmt.Fprintf(hasher, "requester=%d|remark=%s|count=%d\n", requester, derefOrDash(remark), len(sources))
	for _, source := range sources {
		fmt.Fprintf(hasher, "source=%d|%s|%s|%s|%d|%s\n", source.DocumentID, source.Kind,
			source.DocumentNo, source.BusinessDate.Format(businessDateLayout), source.BusinessUserID, source.Amount)
	}
	return hex.EncodeToString(hasher.Sum(nil))
}

func derefOrDash(value *string) string {
	if value == nil {
		return "-"
	}
	return *value
}
