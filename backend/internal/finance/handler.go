package finance

import (
	"context"
	"net/http"
	"strconv"
	"strings"

	"CBizDocsManager/backend/internal/identity"
	"CBizDocsManager/backend/pkg/apperror"
	"CBizDocsManager/backend/pkg/response"
	"github.com/gin-gonic/gin"
)

// idempotencyHeader 是离线队列重复提交时携带的幂等键请求头（与单据 / 结算模块共用同一约定）。
const idempotencyHeader = "Idempotency-Key"

// FinanceService 是 Handler 依赖的服务能力。
type FinanceService interface {
	Create(ctx context.Context, principal identity.Principal, kind Kind, request CreateRequest, idempotencyKey string) (*StatementData, error)
	List(ctx context.Context, principal identity.Principal, kind Kind, query ListQuery) (*RecordPageData, error)
	Revoke(ctx context.Context, principal identity.Principal, kind Kind, recordID uint64) (*StatementData, error)
	Statement(ctx context.Context, principal identity.Principal, documentID uint64) (*StatementData, error)
}

// Handler 承载财务记录的 HTTP 转换。
//
// 三类记录（付款 / 收款 / 开票）共用同一个 Handler，kind 由构造时的路由决定：
// 客户端无法通过请求体或查询参数篡改记录类型，也就无法用付款接口去写收款数据。
type Handler struct {
	service FinanceService
	kind    Kind
}

// NewHandler 创建指定记录类型的财务 Handler。
func NewHandler(service FinanceService, kind Kind) *Handler {
	return &Handler{service: service, kind: kind}
}

// Create 登记一条付款 / 收款 / 开票记录。
func (h *Handler) Create(c *gin.Context) {
	principal, ok := financePrincipalFromContext(c)
	if !ok {
		return
	}
	var request CreateRequest
	if err := c.ShouldBindJSON(&request); err != nil {
		response.Failure(c, apperror.ErrValidationFailed, response.ValidationErrors(err))
		return
	}
	idempotencyKey, ok := idempotencyKeyFromHeader(c)
	if !ok {
		return
	}
	result, err := h.service.Create(c.Request.Context(), *principal, h.kind, request, idempotencyKey)
	if err != nil {
		response.Failure(c, err, nil)
		return
	}
	response.Success(c, http.StatusCreated, result)
}

// List 分页查询财务记录。
func (h *Handler) List(c *gin.Context) {
	principal, ok := financePrincipalFromContext(c)
	if !ok {
		return
	}
	var query ListQuery
	if err := c.ShouldBindQuery(&query); err != nil {
		response.Failure(c, apperror.ErrValidationFailed, response.ValidationErrors(err))
		return
	}
	result, err := h.service.List(c.Request.Context(), *principal, h.kind, query)
	if err != nil {
		response.Failure(c, err, nil)
		return
	}
	response.Success(c, http.StatusOK, result)
}

// Revoke 撤销一条财务记录。
func (h *Handler) Revoke(c *gin.Context) {
	principal, ok := financePrincipalFromContext(c)
	if !ok {
		return
	}
	recordID, err := strconv.ParseUint(c.Param("record_id"), 10, 64)
	if err != nil || recordID == 0 {
		response.Failure(c, apperror.ErrValidationFailed, nil)
		return
	}
	result, err := h.service.Revoke(c.Request.Context(), *principal, h.kind, recordID)
	if err != nil {
		response.Failure(c, err, nil)
		return
	}
	response.Success(c, http.StatusOK, result)
}

// Statement 读取单张单据的结清视图。
//
// 它不挂在任何一个 kind 前缀下（三份拷贝没有意义），由 router 单独注册一次。
func (h *Handler) Statement(c *gin.Context) {
	principal, ok := financePrincipalFromContext(c)
	if !ok {
		return
	}
	documentID, err := strconv.ParseUint(c.Param("document_id"), 10, 64)
	if err != nil || documentID == 0 {
		response.Failure(c, apperror.ErrValidationFailed, nil)
		return
	}
	result, err := h.service.Statement(c.Request.Context(), *principal, documentID)
	if err != nil {
		response.Failure(c, err, nil)
		return
	}
	response.Success(c, http.StatusOK, result)
}

func financePrincipalFromContext(c *gin.Context) (*identity.Principal, bool) {
	principal, ok := identity.PrincipalFromContext(c)
	if !ok {
		response.Failure(c, apperror.ErrAuthTokenExpired, nil)
		return nil, false
	}
	return principal, true
}

// idempotencyKeyFromHeader 读取幂等键；缺省表示客户端未启用幂等，属于合法情况。
func idempotencyKeyFromHeader(c *gin.Context) (string, bool) {
	key := strings.TrimSpace(c.GetHeader(idempotencyHeader))
	if len([]rune(key)) > 191 {
		response.Failure(c, apperror.ErrValidationFailed, nil)
		return "", false
	}
	return key, true
}
