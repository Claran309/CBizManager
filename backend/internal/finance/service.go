package finance

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
	// ErrRecordNotFound 表示财务记录不存在或不属于当前组。
	ErrRecordNotFound = errors.New("finance record not found")
	// ErrDocumentNotFound 表示目标单据不存在或不属于当前组。
	ErrDocumentNotFound = errors.New("finance target document not found")
	// ErrDocumentStatusInvalid 表示单据当前状态不允许登记或撤销财务记录。
	ErrDocumentStatusInvalid = errors.New("finance target document status invalid")
	// ErrDocumentMismatch 表示记录类型与单据类型不匹配（例如给入库单登记收款）。
	ErrDocumentMismatch = errors.New("finance record kind does not match document kind")
	// ErrAmountExceeds 表示本次金额加上已有累计后超过了单据总额。
	ErrAmountExceeds = errors.New("finance amount exceeds document total")
	// ErrIdempotencyMismatch 表示同一个幂等键被用于了不同的请求体。
	ErrIdempotencyMismatch = errors.New("idempotency key reused with different payload")
)

// Repository 是财务模块的存储接口。所有方法都必须带 group_id 条件，保证组间数据隔离。
type Repository interface {
	// CreateRecord 在事务内锁定目标单据、校验累计金额、写入记录、幂等记录与审计。
	CreateRecord(ctx context.Context, input CreateInput) (Record, error)
	// RevokeRecord 在事务内删除一条记录并写审计，返回被撤销的记录。
	RevokeRecord(ctx context.Context, input RevokeInput) (Record, error)
	// FindRecord 读取一条记录。
	FindRecord(ctx context.Context, groupID, recordID uint64) (Record, error)
	// ListRecords 分页查询财务记录。
	ListRecords(ctx context.Context, groupID uint64, query RepositoryQuery) (Page, error)
	// LoadDocument 读取目标单据的当前状态（含首往来单位名称）。
	LoadDocument(ctx context.Context, groupID, documentID uint64) (TargetDocument, error)
	// LoadStatement 读取单张单据的全部财务记录，用于推导结清情况。
	LoadStatement(ctx context.Context, groupID, documentID uint64) (Statement, error)
	// LoadUsers 返回用户摘要，避免 Service 直接依赖 identity 仓储。
	LoadUsers(ctx context.Context, ids []uint64) (map[uint64]identity.UserSummary, error)
}

// Service 承载财务记录的业务规则：权限、单据状态与类型、累计金额上限、幂等与结清推导。
type Service struct {
	repo       Repository
	authorizer authorization.Authorizer
	now        func() time.Time
}

// NewService 创建财务服务。
func NewService(repo Repository, authorizer authorization.Authorizer) *Service {
	return &Service{repo: repo, authorizer: authorizer, now: time.Now}
}

/* ------------------------------------------------------------------ 对外能力 */

// Create 登记一条付款 / 收款 / 开票记录，并返回该单据最新的结清视图。
//
// 返回整张单据的结清视图（而不是只回一条记录）是有意为之：客户端登记完立刻就
// 需要刷新「已付 / 未付」这类派生金额，一次往返拿全比再查一次更不容易出现界面不一致。
func (s *Service) Create(ctx context.Context, principal identity.Principal, kind Kind, request CreateRequest, idempotencyKey string) (*StatementData, error) {
	scope, err := s.resolveScope(ctx, principal)
	if err != nil {
		return nil, err
	}
	if !scope.canRecord {
		return nil, apperror.ErrForbidden
	}

	documentID, err := normalizeDocumentID(request.DocumentID)
	if err != nil {
		return nil, apperror.ErrValidationFailed
	}
	amount, err := normalizeAmount(request.Amount)
	if err != nil {
		return nil, apperror.ErrValidationFailed
	}
	occurredOn, err := parseOccurredOn(request.OccurredOn)
	if err != nil {
		return nil, apperror.ErrValidationFailed
	}
	method, methodNote, cardTail, err := normalizeMethod(kind, request.Method, request.MethodNote, request.CardTail)
	if err != nil {
		return nil, apperror.ErrValidationFailed
	}
	invoiceNo, err := normalizeInvoiceNo(kind, request.InvoiceNo)
	if err != nil {
		return nil, apperror.ErrValidationFailed
	}
	remark, err := normalizeOptionalText(request.Remark, maxRemarkLength)
	if err != nil {
		return nil, apperror.ErrValidationFailed
	}

	// 目标单据必须存在、属于本组、处于「已提交」状态，且类型与记录类型匹配。
	target, err := s.loadRecordableDocument(ctx, scope, principal, documentID, kind)
	if err != nil {
		return nil, err
	}

	now := s.now().UTC()
	// 登记结果本身不单独返回：调用方要的是「整张单据最新的结清视图」。
	// 仓储内部仍会写入 record，用于生成审计与幂等记录。
	if _, err = s.repo.CreateRecord(ctx, CreateInput{
		GroupID: scope.groupID, DocumentID: target.ID, DocumentKind: target.Kind,
		DocumentNo: target.DocumentNo, PartyName: target.PartyName,
		BusinessUserID: target.BusinessUserID, BusinessDate: target.BusinessDate,
		Kind: kind, Amount: amount, OccurredOn: occurredOn,
		Method: method, MethodNote: methodNote, CardTail: cardTail, InvoiceNo: invoiceNo,
		Remark: remark, OperatorUserID: principal.UserID, Now: now,
		IdempotencyScope: idempotencyScope(kind),
		IdempotencyKey:   idempotencyKey,
		RequestFingerprint: fingerprintCreate(kind, target.ID, amount, occurredOn,
			method, methodNote, cardTail, invoiceNo, remark),
		AuditAction:  auditAction(kind, auditVerbRecorded),
		AuditSummary: auditSummary(target, kind, amount),
	}); err != nil {
		return nil, mapRepositoryError("create finance record", err)
	}
	// 幂等重放时 record.DocumentID 与 target.ID 相同，直接用目标单据 ID 即可。
	return s.statementData(ctx, scope, principal, target.ID)
}

// List 分页查询财务记录，并按权限收敛数据范围。
func (s *Service) List(ctx context.Context, principal identity.Principal, kind Kind, query ListQuery) (*RecordPageData, error) {
	scope, err := s.resolveScope(ctx, principal)
	if err != nil {
		return nil, err
	}
	repositoryQuery, err := buildRepositoryQuery(scope, principal, kind, query)
	if err != nil {
		return nil, err
	}
	page, err := s.repo.ListRecords(ctx, scope.groupID, repositoryQuery)
	if err != nil {
		return nil, mapRepositoryError("list finance records", err)
	}

	userIDs := make([]uint64, 0, len(page.Items)*2)
	for _, item := range page.Items {
		userIDs = append(userIDs, item.Record.CreatedBy, item.Record.BusinessUserID)
	}
	users, err := s.repo.LoadUsers(ctx, userIDs)
	if err != nil {
		return nil, mapRepositoryError("load finance users", err)
	}

	items := make([]RecordData, 0, len(page.Items))
	for _, summary := range page.Items {
		items = append(items, toRecordData(summary.Record,
			withID(users[summary.Record.CreatedBy], summary.Record.CreatedBy),
			withID(users[summary.Record.BusinessUserID], summary.Record.BusinessUserID)))
	}
	return &RecordPageData{Items: items, Page: page.Page, PageSize: page.PageSize, Total: page.Total}, nil
}

// Revoke 撤销一条财务记录（登记错误时的唯一纠错手段），并返回该单据最新的结清视图。
func (s *Service) Revoke(ctx context.Context, principal identity.Principal, kind Kind, recordID uint64) (*StatementData, error) {
	scope, err := s.resolveScope(ctx, principal)
	if err != nil {
		return nil, err
	}
	if !scope.canRecord {
		// 撤销与登记同属「财务记账」能力，避免出现「能登不能撤」的权限空洞。
		return nil, apperror.ErrForbidden
	}
	if recordID == 0 {
		return nil, apperror.ErrValidationFailed
	}

	record, err := s.repo.FindRecord(ctx, scope.groupID, recordID)
	if err != nil {
		return nil, mapRepositoryError("find finance record", err)
	}
	if record.Kind != kind {
		// 用 payments 接口去删一条收款记录属于客户端接口用错，按「不存在」处理。
		return nil, apperror.ErrFinanceRecordNotFound
	}
	if record.BusinessUserID != principal.UserID && !scope.canViewOthers {
		return nil, apperror.ErrForbidden
	}

	revoked, err := s.repo.RevokeRecord(ctx, RevokeInput{
		GroupID: scope.groupID, RecordID: recordID, OperatorUserID: principal.UserID,
		Now:         s.now().UTC(),
		AuditAction: auditAction(kind, auditVerbRevoked),
		AuditSummary: auditSummary(TargetDocument{
			DocumentNo: record.DocumentNo, Kind: record.DocumentKind,
		}, kind, record.Amount),
	})
	if err != nil {
		return nil, mapRepositoryError("revoke finance record", err)
	}
	return s.statementData(ctx, scope, principal, revoked.DocumentID)
}

// Statement 读取单张单据的结清视图（已付 / 未付、已收 / 未收、已开票 / 开票状态）。
func (s *Service) Statement(ctx context.Context, principal identity.Principal, documentID uint64) (*StatementData, error) {
	scope, err := s.resolveScope(ctx, principal)
	if err != nil {
		return nil, err
	}
	if _, err := normalizeDocumentID(documentID); err != nil {
		return nil, apperror.ErrValidationFailed
	}
	return s.statementData(ctx, scope, principal, documentID)
}

/* ------------------------------------------------------------------ 权限与数据范围 */

// scope 描述当前身份在财务模块中的可见范围与记账资格。
type scope struct {
	groupID       uint64
	canViewOthers bool
	canRecord     bool
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
		// 主账号默认拥有组内全部业务与管理权限，其中包含财务记账。
		result.canViewOthers, result.canRecord = true, true
		return result, nil
	}
	if principal.AccountType != identity.AccountTypeMember || principal.MemberType != "member" {
		return scope{}, apperror.ErrForbidden
	}
	var err error
	if result.canViewOthers, err = s.hasPermission(ctx, principal, result.groupID, authorization.PermissionDocumentViewOthers); err != nil {
		return scope{}, err
	}
	if result.canRecord, err = s.hasPermission(ctx, principal, result.groupID, authorization.PermissionFinanceRecord); err != nil {
		return scope{}, err
	}
	return result, nil
}

// hasPermission 把「未授予权限」翻译成 false，而不是向客户端抛 403：
// 子账号默认看不到他人单据的财务记录，这是正常业务路径而不是越权。
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

// loadRecordableDocument 读取目标单据并校验「可记账」的全部前置条件。
func (s *Service) loadRecordableDocument(
	ctx context.Context,
	scope scope,
	principal identity.Principal,
	documentID uint64,
	kind Kind,
) (TargetDocument, error) {
	target, err := s.repo.LoadDocument(ctx, scope.groupID, documentID)
	if err != nil {
		return TargetDocument{}, mapRepositoryError("load target document", err)
	}
	if target.Kind != kind.DocumentKind() {
		// 先判类型再判状态：客户端接口用错（给入库单登记收款）比状态不对更常见，
		// 也更需要一句明确的错误提示。
		return TargetDocument{}, apperror.ErrFinanceDocumentMismatch
	}
	if target.Status != document.StatusSubmitted {
		// 草稿金额还没定、作废单已经失效，两者都不允许产生财务记录。
		return TargetDocument{}, apperror.ErrDocumentStatusInvalid
	}
	if target.BusinessUserID != principal.UserID && !scope.canViewOthers {
		return TargetDocument{}, apperror.ErrForbidden
	}
	return target, nil
}

func buildRepositoryQuery(scope scope, principal identity.Principal, kind Kind, query ListQuery) (RepositoryQuery, error) {
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
	result := RepositoryQuery{
		Kind: kind, DocumentID: query.DocumentID,
		Keyword: strings.TrimSpace(query.Keyword), Page: page, PageSize: pageSize,
	}
	if strings.TrimSpace(string(query.Method)) != "" {
		method, ok := ParseMethod(strings.TrimSpace(string(query.Method)))
		if !ok {
			return RepositoryQuery{}, apperror.ErrValidationFailed
		}
		result.Method = &method
	}
	if strings.TrimSpace(query.Month) != "" {
		start, end, err := bizdate.ParseMonth(query.Month)
		if err != nil {
			return RepositoryQuery{}, apperror.ErrValidationFailed
		}
		result.OccurredFrom, result.OccurredTo = &start, &end
	} else {
		if strings.TrimSpace(query.DateFrom) != "" {
			from, err := bizdate.ParseDate(query.DateFrom)
			if err != nil {
				return RepositoryQuery{}, apperror.ErrValidationFailed
			}
			result.OccurredFrom = &from
		}
		if strings.TrimSpace(query.DateTo) != "" {
			to, err := bizdate.ParseDate(query.DateTo)
			if err != nil {
				return RepositoryQuery{}, apperror.ErrValidationFailed
			}
			// date_to 是闭区间语义，仓储按左闭右开比较，这里补一天。
			exclusive := to.AddDate(0, 0, 1)
			result.OccurredTo = &exclusive
		}
	}

	if !scope.canViewOthers {
		// 没有查看他人权限时，只允许查询本人单据的财务记录；显式指定他人直接拒绝。
		if query.BusinessUserID != 0 && query.BusinessUserID != principal.UserID {
			return RepositoryQuery{}, apperror.ErrForbidden
		}
		result.OnlyBusinessUserID = principal.UserID
		return result, nil
	}
	if query.BusinessUserID != 0 {
		businessUser := query.BusinessUserID
		result.BusinessUserID = &businessUser
	}
	return result, nil
}

/* ------------------------------------------------------------------ 内部工具 */

func (s *Service) statementData(ctx context.Context, scope scope, principal identity.Principal, documentID uint64) (*StatementData, error) {
	statement, err := s.repo.LoadStatement(ctx, scope.groupID, documentID)
	if err != nil {
		return nil, mapRepositoryError("load finance statement", err)
	}
	// 结清视图会暴露单据的往来单位与全部金额明细，必须与单据本身采用同一套数据范围：
	// 没有 document.view_others 的成员只能看到自己经手单据的结清情况。
	// 这条校验放在这里而不是放在 Statement 里，是为了让「登记 / 撤销 / 查询」三条路径
	// 共用同一个口径，避免以后新增入口时漏掉。
	if statement.Document.BusinessUserID != principal.UserID && !scope.canViewOthers {
		return nil, apperror.ErrForbidden
	}
	ids := []uint64{statement.Document.BusinessUserID}
	for _, record := range statement.Records {
		ids = append(ids, record.CreatedBy)
	}
	users, err := s.repo.LoadUsers(ctx, ids)
	if err != nil {
		return nil, mapRepositoryError("load finance users", err)
	}
	businessUser := withID(users[statement.Document.BusinessUserID], statement.Document.BusinessUserID)
	return buildStatementData(statement, businessUser, users), nil
}

// withID 保证用户摘要里始终带 ID：LoadUsers 查不到人（已注销）时也要能显示「谁」。
func withID(summary identity.UserSummary, id uint64) identity.UserSummary {
	if summary.ID == 0 {
		summary.ID = id
	}
	return summary
}

func mapRepositoryError(operation string, err error) error {
	switch {
	case errors.Is(err, ErrRecordNotFound):
		return apperror.ErrFinanceRecordNotFound
	case errors.Is(err, ErrDocumentNotFound):
		return apperror.ErrDocumentNotFound
	case errors.Is(err, ErrDocumentStatusInvalid):
		return apperror.ErrDocumentStatusInvalid
	case errors.Is(err, ErrDocumentMismatch):
		return apperror.ErrFinanceDocumentMismatch
	case errors.Is(err, ErrAmountExceeds):
		return apperror.ErrFinanceAmountExceeds
	case errors.Is(err, ErrIdempotencyMismatch):
		return apperror.ErrIdempotencyKeyReused
	default:
		return apperror.Wrap(apperror.ErrInternal, fmt.Errorf("%s: %w", operation, err))
	}
}

// 审计动作的两个动词。
const (
	auditVerbRecorded = "recorded"
	auditVerbRevoked  = "revoked"
)

// auditAction 生成形如 finance.payment.recorded 的审计动作。
func auditAction(kind Kind, verb string) string { return fmt.Sprintf("finance.%s.%s", kind, verb) }

// auditSummary 生成审计摘要，例如「入库单 RK20260922-0001 登记付款 30000.00」。
//
// 摘要里只带单号、动作与金额：卡尾号、转账备注这类信息不进入审计文本，
// 避免敏感字段被带到运维日志与审计查询页。
func auditSummary(target TargetDocument, kind Kind, amount money.Amount) string {
	noun := "单据"
	if target.Kind != "" {
		if target.Kind.IsInbound() {
			noun = "入库单"
		} else {
			noun = "出库单"
		}
	}
	verb := "登记"
	if kind == KindInvoice {
		verb = "登记开票"
	}
	return fmt.Sprintf("%s %s %s%s %s", noun, target.DocumentNo, verb, kind.Label(), amount.String())
}

func idempotencyScope(kind Kind) string { return fmt.Sprintf("finance.%s.create", kind) }

// fingerprintCreate 生成登记财务记录的请求指纹：同一个幂等键必须对应同一份内容，
// 否则说明客户端复用了幂等键，必须报错而不是静默返回旧记录。
func fingerprintCreate(
	kind Kind,
	documentID uint64,
	amount money.Amount,
	occurredOn time.Time,
	method *Method,
	methodNote, cardTail, invoiceNo, remark *string,
) string {
	hasher := sha256.New()
	fmt.Fprintf(hasher, "kind=%s|document=%d|amount=%s|occurred=%s|method=%s|note=%s|card=%s|invoice=%s|remark=%s\n",
		kind, documentID, amount.String(), occurredOn.Format(businessDateLayout),
		derefOrDash((*string)(method)), derefOrDash(methodNote), derefOrDash(cardTail),
		derefOrDash(invoiceNo), derefOrDash(remark))
	return hex.EncodeToString(hasher.Sum(nil))
}

func derefOrDash(value *string) string {
	if value == nil {
		return "-"
	}
	return *value
}
