package document

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"time"

	"CBizDocsManager/backend/internal/authorization"
	"CBizDocsManager/backend/internal/identity"
	"CBizDocsManager/backend/pkg/apperror"
	"CBizDocsManager/backend/pkg/money"
	"CBizDocsManager/backend/pkg/rmb"
)

var (
	// ErrNotFound 表示单据不存在或不属于当前组。
	ErrNotFound = errors.New("document not found")
	// ErrVersionConflict 表示乐观锁版本不匹配。
	ErrVersionConflict = errors.New("document version conflict")
	// ErrStatusInvalid 表示当前业务状态不允许该操作。
	ErrStatusInvalid = errors.New("document status invalid")
	// ErrDocumentNoConflict 表示单号生成撞车，需要重新生成（仓储内部重试）。
	ErrDocumentNoConflict = errors.New("document number conflict")
	// ErrIdempotencyMismatch 表示同一个幂等键被用于了不同的请求体。
	ErrIdempotencyMismatch = errors.New("idempotency key reused with different payload")
)

// 金额与数量的上限，用来挡住明显的脏数据，同时保证单号与金额都在可展示范围内。
var (
	maxUnitPrice = mustPrice(maxUnitPriceValue)
	maxQuantity  = mustQuantity(maxQuantityValue)
)

// Repository 是单据模块的存储接口。所有方法都必须带 group_id 条件，保证组间数据隔离。
type Repository interface {
	// CreateDocument 创建单据；第二个返回值表示这次请求命中了幂等重放。
	CreateDocument(ctx context.Context, input CreateInput) (Document, bool, error)
	// ReplaceDocument 整体替换单据内容并递增版本号。
	ReplaceDocument(ctx context.Context, input UpdateInput) (Document, error)
	// ChangeStatus 变更单据业务状态（提交 / 作废）。
	ChangeStatus(ctx context.Context, input StatusInput) (Document, error)
	FindDocument(ctx context.Context, groupID uint64, kind Kind, id uint64) (Document, error)
	LoadDetail(ctx context.Context, groupID uint64, kind Kind, id uint64) (Detail, error)
	ListDocuments(ctx context.Context, groupID uint64, kind Kind, query RepositoryQuery) (Page, error)
	MonthlyTotals(ctx context.Context, groupID uint64, kind Kind, query SummaryQuery) (MonthlyTotals, error)
	// LoadUsers 返回业务员摘要。放在单据仓储里是为了避免 Service 直接依赖 identity 仓储。
	LoadUsers(ctx context.Context, ids []uint64) (map[uint64]identity.UserSummary, error)
	// ActiveMemberExists 校验业务员是否为该组的有效成员。
	ActiveMemberExists(ctx context.Context, groupID, userID uint64) (bool, error)
}

// Service 承载单据的业务规则：权限、数据范围、金额计算、状态机与幂等。
type Service struct {
	repo       Repository
	authorizer authorization.Authorizer
	now        func() time.Time
}

// NewService 创建单据服务。
func NewService(repo Repository, authorizer authorization.Authorizer) *Service {
	return &Service{repo: repo, authorizer: authorizer, now: time.Now}
}

/* ------------------------------------------------------------------ 对外能力 */

// Create 创建单据。idempotencyKey 为空表示客户端未启用幂等（离线队列会启用）。
func (s *Service) Create(ctx context.Context, principal identity.Principal, kind Kind, request CreateRequest, idempotencyKey string) (*DocumentData, error) {
	scope, err := s.resolveScope(ctx, principal)
	if err != nil {
		return nil, err
	}
	payload, err := buildPayload(kind, principal, payloadRequest{
		Status: request.Status, BusinessDate: request.BusinessDate, BusinessUserID: request.BusinessUserID,
		ShippingUnit: request.ShippingUnit, SaleAmountType: request.SaleAmountType,
		Remark: request.Remark, Parties: request.Parties,
	})
	if err != nil {
		return nil, err
	}
	if err := s.authorizeBusinessUser(ctx, scope, principal, payload.BusinessUserID); err != nil {
		return nil, err
	}

	document, _, err := s.repo.CreateDocument(ctx, CreateInput{
		GroupID: scope.groupID, Kind: kind, Status: payload.Status,
		BusinessUserID: payload.BusinessUserID, BusinessDate: payload.BusinessDate,
		ShippingUnit: payload.ShippingUnit, SaleAmountType: payload.SaleAmountType,
		TotalAmount: payload.TotalAmount, Remark: payload.Remark,
		OperatorUserID: principal.UserID, Parties: payload.Parties,
		IdempotencyScope:   idempotencyScope(kind, "create"),
		IdempotencyKey:     idempotencyKey,
		RequestFingerprint: fingerprintPayload(kind, payload),
		AuditAction:        "document.created",
		AuditSummary:       fmt.Sprintf("%s %s 已创建", kindLabel(kind), "（单号自动生成）"),
	})
	if err != nil {
		return nil, mapRepositoryError("create document", err)
	}
	return s.detailData(ctx, scope, kind, document.ID)
}

// Update 整体替换单据内容，要求携带乐观锁版本号。
func (s *Service) Update(ctx context.Context, principal identity.Principal, kind Kind, documentID uint64, request UpdateRequest, idempotencyKey string) (*DocumentData, error) {
	scope, err := s.resolveScope(ctx, principal)
	if err != nil {
		return nil, err
	}
	if request.Version == 0 {
		return nil, apperror.ErrValidationFailed
	}
	current, err := s.repo.FindDocument(ctx, scope.groupID, kind, documentID)
	if err != nil {
		return nil, mapRepositoryError("find document", err)
	}
	if err := s.ensureEditable(scope, principal, current); err != nil {
		return nil, err
	}
	payload, err := buildPayload(kind, principal, payloadRequest{
		Status: request.Status, BusinessDate: request.BusinessDate, BusinessUserID: request.BusinessUserID,
		ShippingUnit: request.ShippingUnit, SaleAmountType: request.SaleAmountType,
		Remark: request.Remark, Parties: request.Parties,
	})
	if err != nil {
		return nil, err
	}
	if err := s.authorizeBusinessUser(ctx, scope, principal, payload.BusinessUserID); err != nil {
		return nil, err
	}

	document, err := s.repo.ReplaceDocument(ctx, UpdateInput{
		GroupID: scope.groupID, Kind: kind, DocumentID: documentID, ExpectedVersion: request.Version,
		Status:         payload.Status,
		BusinessUserID: payload.BusinessUserID, BusinessDate: payload.BusinessDate,
		ShippingUnit: payload.ShippingUnit, SaleAmountType: payload.SaleAmountType,
		TotalAmount: payload.TotalAmount, Remark: payload.Remark, OperatorUserID: principal.UserID,
		Parties:            payload.Parties,
		IdempotencyScope:   idempotencyScope(kind, "update"),
		IdempotencyKey:     idempotencyKey,
		RequestFingerprint: fingerprintPayload(kind, payload),
		AuditSummary:       fmt.Sprintf("%s 已修改", kindLabel(kind)),
	})
	if err != nil {
		return nil, mapRepositoryError("update document", err)
	}
	return s.detailData(ctx, scope, kind, document.ID)
}

// Get 返回单据详情。
func (s *Service) Get(ctx context.Context, principal identity.Principal, kind Kind, documentID uint64) (*DocumentData, error) {
	scope, err := s.resolveScope(ctx, principal)
	if err != nil {
		return nil, err
	}
	detail, err := s.repo.LoadDetail(ctx, scope.groupID, kind, documentID)
	if err != nil {
		return nil, mapRepositoryError("load document", err)
	}
	if err := s.ensureVisible(scope, principal, detail.Document); err != nil {
		return nil, err
	}
	return s.buildDetailData(ctx, detail)
}

// List 返回单据分页列表，并按权限收敛数据范围。
func (s *Service) List(ctx context.Context, principal identity.Principal, kind Kind, query ListQuery) (*DocumentPageData, error) {
	scope, err := s.resolveScope(ctx, principal)
	if err != nil {
		return nil, err
	}
	repositoryQuery, err := buildRepositoryQuery(scope, principal, query)
	if err != nil {
		return nil, err
	}
	page, err := s.repo.ListDocuments(ctx, scope.groupID, kind, repositoryQuery)
	if err != nil {
		return nil, mapRepositoryError("list documents", err)
	}
	items := make([]DocumentSummaryData, 0, len(page.Items))
	for _, summary := range page.Items {
		items = append(items, toSummaryData(summary))
	}
	return &DocumentPageData{Items: items, Page: page.Page, PageSize: page.PageSize, Total: page.Total}, nil
}

// Submit 把草稿提交到后台，提交前执行完整性校验。
func (s *Service) Submit(ctx context.Context, principal identity.Principal, kind Kind, documentID uint64, request VersionRequest) (*DocumentData, error) {
	return s.changeStatus(ctx, principal, kind, documentID, request.Version, StatusSubmitted, "document.submitted", "已提交")
}

// Void 作废单据。一期用状态标记而不是物理删除，保证审计可追溯。
func (s *Service) Void(ctx context.Context, principal identity.Principal, kind Kind, documentID uint64, request VersionRequest) (*DocumentData, error) {
	return s.changeStatus(ctx, principal, kind, documentID, request.Version, StatusVoided, "document.voided", "已作废")
}

// MonthlySummary 返回指定月份的单据汇总，用于手机端「按月份回顾」和后台快速统计。
func (s *Service) MonthlySummary(ctx context.Context, principal identity.Principal, kind Kind, month string, bucketSize int) (*MonthlySummaryData, error) {
	scope, err := s.resolveScope(ctx, principal)
	if err != nil {
		return nil, err
	}
	now := s.now().UTC()
	start := time.Date(now.Year(), now.Month(), 1, 0, 0, 0, 0, time.UTC)
	if month != "" {
		parsedStart, _, err := parseMonthRange(month)
		if err != nil {
			return nil, apperror.ErrValidationFailed
		}
		start = parsedStart
	}
	query := SummaryQuery{Month: start, BucketSize: bucketSize}
	if !scope.canViewOthers {
		// 没有「查看他人单据」权限的子账号只能看到自己的月度汇总。
		query.OnlyBusinessUserID = principal.UserID
	}
	totals, err := s.repo.MonthlyTotals(ctx, scope.groupID, kind, query)
	if err != nil {
		return nil, mapRepositoryError("monthly totals", err)
	}
	parties := make([]PartyTotalsData, 0, len(totals.Parties))
	for _, party := range totals.Parties {
		parties = append(parties, PartyTotalsData{PartyName: party.PartyName, DocumentCount: party.DocumentCount, TotalAmount: party.TotalAmount})
	}
	return &MonthlySummaryData{
		Month: start.Format("2006-01"), Kind: kind, DocumentCount: totals.DocumentCount,
		DraftCount: totals.DraftCount, SubmittedCount: totals.SubmittedCnt, VoidedCount: totals.VoidedCount,
		TotalAmount: totals.TotalAmount, TotalAmountUpper: rmbUpper(totals.TotalAmount), Parties: parties,
	}, nil
}

/* ------------------------------------------------------------------ 权限与数据范围 */

// scope 描述当前身份在单据模块中的可见与可编辑范围。
type scope struct {
	groupID       uint64
	isOwner       bool
	canViewOthers bool
	canEditOthers bool
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
		// 主账号默认拥有组内全部业务权限，与权限表的隐式规则保持一致。
		result.isOwner = true
		result.canViewOthers = true
		result.canEditOthers = true
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
	return result, nil
}

// hasPermission 把「未授予权限」翻译成 false，而不是向客户端抛 403：
// 子账号默认只能看本人单据，这是正常业务路径而不是越权。
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

func (s *Service) ensureVisible(scope scope, principal identity.Principal, current Document) error {
	if current.BusinessUserID == principal.UserID || scope.canViewOthers {
		return nil
	}
	return apperror.ErrForbidden
}

func (s *Service) ensureEditable(scope scope, principal identity.Principal, current Document) error {
	if current.Status == StatusVoided {
		return apperror.ErrDocumentStatusInvalid
	}
	if current.BusinessUserID == principal.UserID || scope.canEditOthers {
		return nil
	}
	return apperror.ErrForbidden
}

// authorizeBusinessUser 校验「代录他人单据」的资格，避免业务员把单据挂到别人名下。
func (s *Service) authorizeBusinessUser(ctx context.Context, scope scope, principal identity.Principal, businessUserID uint64) error {
	if businessUserID == 0 {
		return apperror.ErrValidationFailed
	}
	if businessUserID != principal.UserID && !scope.canEditOthers {
		return apperror.ErrForbidden
	}
	exists, err := s.repo.ActiveMemberExists(ctx, scope.groupID, businessUserID)
	if err != nil {
		return mapRepositoryError("check business user", err)
	}
	if !exists {
		return apperror.ErrValidationFailed
	}
	return nil
}

/* ------------------------------------------------------------------ 内部工具 */

func (s *Service) changeStatus(ctx context.Context, principal identity.Principal, kind Kind, documentID, version uint64, target Status, action, summary string) (*DocumentData, error) {
	scope, err := s.resolveScope(ctx, principal)
	if err != nil {
		return nil, err
	}
	if version == 0 {
		return nil, apperror.ErrValidationFailed
	}
	current, err := s.repo.FindDocument(ctx, scope.groupID, kind, documentID)
	if err != nil {
		return nil, mapRepositoryError("find document", err)
	}
	if current.BusinessUserID != principal.UserID && !scope.canEditOthers {
		return nil, apperror.ErrForbidden
	}
	if err := validateTransition(current.Status, target); err != nil {
		return nil, err
	}
	if target == StatusSubmitted {
		// 提交前必须保证内容是完整的，草稿阶段允许留空。
		detail, err := s.repo.LoadDetail(ctx, scope.groupID, kind, documentID)
		if err != nil {
			return nil, mapRepositoryError("load document", err)
		}
		if err := validateCompleteness(kind, detail); err != nil {
			return nil, err
		}
	}
	updated, err := s.repo.ChangeStatus(ctx, StatusInput{
		GroupID: scope.groupID, Kind: kind, DocumentID: documentID, OperatorUserID: principal.UserID,
		ExpectedVersion: version, Status: target, Now: s.now().UTC(), AuditAction: action,
		AuditSummary: summary,
	})
	if err != nil {
		return nil, mapRepositoryError("change document status", err)
	}
	return s.detailData(ctx, scope, kind, updated.ID)
}

func (s *Service) detailData(ctx context.Context, scope scope, kind Kind, documentID uint64) (*DocumentData, error) {
	detail, err := s.repo.LoadDetail(ctx, scope.groupID, kind, documentID)
	if err != nil {
		return nil, mapRepositoryError("load document", err)
	}
	return s.buildDetailData(ctx, detail)
}

func (s *Service) buildDetailData(ctx context.Context, detail Detail) (*DocumentData, error) {
	businessUser, err := s.businessUserSummary(ctx, detail.Document.BusinessUserID)
	if err != nil {
		return nil, err
	}
	return toDocumentData(detail, businessUser), nil
}

func (s *Service) businessUserSummary(ctx context.Context, userID uint64) (identity.UserSummary, error) {
	users, err := s.repo.LoadUsers(ctx, []uint64{userID})
	if err != nil {
		return identity.UserSummary{}, mapRepositoryError("load business user", err)
	}
	if summary, ok := users[userID]; ok {
		return summary, nil
	}
	// 用户已被删除时保留 ID，避免详情接口整体失败。
	return identity.UserSummary{ID: userID}, nil
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
	result := RepositoryQuery{Page: page, PageSize: pageSize, Keyword: query.Keyword}
	if query.Status != "" {
		switch query.Status {
		case StatusDraft, StatusSubmitted, StatusVoided:
			status := query.Status
			result.Status = &status
		default:
			return RepositoryQuery{}, apperror.ErrValidationFailed
		}
	}
	if query.Month != "" {
		start, end, err := parseMonthRange(query.Month)
		if err != nil {
			return RepositoryQuery{}, apperror.ErrValidationFailed
		}
		result.MonthStart, result.MonthEnd = &start, &end
	}
	if query.DateFrom != "" {
		start, err := parseBusinessDate(query.DateFrom)
		if err != nil {
			return RepositoryQuery{}, apperror.ErrValidationFailed
		}
		result.MonthStart = &start
	}
	if query.DateTo != "" {
		end, err := parseBusinessDate(query.DateTo)
		if err != nil {
			return RepositoryQuery{}, apperror.ErrValidationFailed
		}
		exclusive := end.AddDate(0, 0, 1)
		result.MonthEnd = &exclusive
	}

	if !scope.canViewOthers {
		// 没有查看他人权限时，只允许查询本人单据；显式指定他人业务员直接拒绝。
		if query.BusinessUserID != 0 && query.BusinessUserID != principal.UserID {
			return RepositoryQuery{}, apperror.ErrForbidden
		}
		result.OnlyBusinessUserID = principal.UserID
		return result, nil
	}
	if query.BusinessUserID != 0 {
		businessUserID := query.BusinessUserID
		result.BusinessUserID = &businessUserID
	}
	return result, nil
}

func mapRepositoryError(operation string, err error) error {
	switch {
	case errors.Is(err, ErrNotFound):
		return apperror.ErrDocumentNotFound
	case errors.Is(err, ErrVersionConflict):
		return apperror.ErrResourceVersionConflict
	case errors.Is(err, ErrStatusInvalid):
		return apperror.ErrDocumentStatusInvalid
	case errors.Is(err, ErrIdempotencyMismatch):
		return apperror.ErrIdempotencyKeyReused
	case errors.Is(err, ErrDocumentNoConflict):
		return apperror.ErrInternal
	default:
		return apperror.Wrap(apperror.ErrInternal, fmt.Errorf("%s: %w", operation, err))
	}
}

func idempotencyScope(kind Kind, action string) string {
	return fmt.Sprintf("document.%s.%s", kind, action)
}

func kindLabel(kind Kind) string {
	if kind.IsInbound() {
		return "入库单"
	}
	return "出库单"
}

func mustPrice(raw string) money.Price {
	value, err := money.ParsePrice(raw)
	if err != nil {
		panic(fmt.Sprintf("非法的单价上限常量 %q: %v", raw, err))
	}
	return value
}

func mustQuantity(raw string) money.Quantity {
	value, err := money.ParseQuantity(raw)
	if err != nil {
		panic(fmt.Sprintf("非法的数量上限常量 %q: %v", raw, err))
	}
	return value
}

// rmbUpper 供汇总响应复用人民币大写。
func rmbUpper(amount money.Amount) string {
	return rmb.Upper(amount)
}

// fingerprintPayload 生成请求体指纹：同一个幂等键必须对应同一份内容，
// 否则说明客户端复用了幂等键，必须报错而不是静默返回旧单据。
func fingerprintPayload(kind Kind, payload normalizedPayload) string {
	hasher := sha256.New()
	fmt.Fprintf(hasher, "kind=%s|date=%s|user=%d|status=%s|shipping=%s|sale=%s|total=%s\n",
		kind, payload.BusinessDate.Format(businessDateLayout), payload.BusinessUserID, payload.Status,
		derefOrDash(payload.ShippingUnit), derefSale(payload.SaleAmountType), payload.TotalAmount)
	for _, party := range payload.Parties {
		fmt.Fprintf(hasher, "party=%s|phone=%s|subtotal=%s\n", party.PartyName, derefOrDash(party.ContactPhone), party.Subtotal)
		for _, item := range party.Items {
			fmt.Fprintf(hasher, "item=%d|%s|%s|%s|%s|%s|%s|%s|%s\n", item.Position, item.ProductName,
				derefOrDash(item.ProductModel), derefOrDash(item.Unit), item.Quantity, item.UnitPrice,
				item.PriceTaxMode, item.Amount, derefOrDash(item.Remark))
		}
	}
	return hex.EncodeToString(hasher.Sum(nil))
}

func derefOrDash(value *string) string {
	if value == nil {
		return "-"
	}
	return *value
}

func derefSale(value *SaleAmountType) string {
	if value == nil {
		return "-"
	}
	return string(*value)
}
