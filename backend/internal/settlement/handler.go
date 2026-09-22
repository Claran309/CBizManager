package settlement

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

// idempotencyHeader 是离线队列重复提交时携带的幂等键请求头（与单据模块共用同一约定）。
const idempotencyHeader = "Idempotency-Key"

// SettlementService 是 Handler 依赖的服务能力。
type SettlementService interface {
	Create(ctx context.Context, principal identity.Principal, request CreateRequest, idempotencyKey string) (*SettlementData, error)
	Get(ctx context.Context, principal identity.Principal, settlementID uint64) (*SettlementData, error)
	List(ctx context.Context, principal identity.Principal, query ListQuery) (*SettlementPageData, error)
	Approve(ctx context.Context, principal identity.Principal, settlementID uint64, request DecideRequest) (*SettlementData, error)
	Reject(ctx context.Context, principal identity.Principal, settlementID uint64, request DecideRequest) (*SettlementData, error)
}

// Handler 承载结算单的 HTTP 转换。
type Handler struct {
	service SettlementService
}

// NewHandler 创建结算 Handler。
func NewHandler(service SettlementService) *Handler {
	return &Handler{service: service}
}

// Create 提交结算申请。
func (h *Handler) Create(c *gin.Context) {
	principal, ok := settlementPrincipalFromContext(c)
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
	result, err := h.service.Create(c.Request.Context(), *principal, request, idempotencyKey)
	if err != nil {
		response.Failure(c, err, nil)
		return
	}
	response.Success(c, http.StatusCreated, result)
}

// List 分页查询结算单。
func (h *Handler) List(c *gin.Context) {
	principal, ok := settlementPrincipalFromContext(c)
	if !ok {
		return
	}
	var query ListQuery
	if err := c.ShouldBindQuery(&query); err != nil {
		response.Failure(c, apperror.ErrValidationFailed, response.ValidationErrors(err))
		return
	}
	result, err := h.service.List(c.Request.Context(), *principal, query)
	if err != nil {
		response.Failure(c, err, nil)
		return
	}
	response.Success(c, http.StatusOK, result)
}

// Get 读取结算单详情（含源单据快照与审批记录）。
func (h *Handler) Get(c *gin.Context) {
	principal, settlementID, ok := settlementPrincipalAndID(c)
	if !ok {
		return
	}
	result, err := h.service.Get(c.Request.Context(), *principal, settlementID)
	if err != nil {
		response.Failure(c, err, nil)
		return
	}
	response.Success(c, http.StatusOK, result)
}

// Approve 审批通过。
func (h *Handler) Approve(c *gin.Context) {
	h.decide(c, h.service.Approve)
}

// Reject 审批驳回；驳回原因必填。
func (h *Handler) Reject(c *gin.Context) {
	h.decide(c, h.service.Reject)
}

func (h *Handler) decide(c *gin.Context, action func(context.Context, identity.Principal, uint64, DecideRequest) (*SettlementData, error)) {
	principal, settlementID, ok := settlementPrincipalAndID(c)
	if !ok {
		return
	}
	var request DecideRequest
	if err := c.ShouldBindJSON(&request); err != nil {
		response.Failure(c, apperror.ErrValidationFailed, response.ValidationErrors(err))
		return
	}
	result, err := action(c.Request.Context(), *principal, settlementID, request)
	if err != nil {
		response.Failure(c, err, nil)
		return
	}
	response.Success(c, http.StatusOK, result)
}

func settlementPrincipalFromContext(c *gin.Context) (*identity.Principal, bool) {
	principal, ok := identity.PrincipalFromContext(c)
	if !ok {
		response.Failure(c, apperror.ErrAuthTokenExpired, nil)
		return nil, false
	}
	return principal, true
}

func settlementPrincipalAndID(c *gin.Context) (*identity.Principal, uint64, bool) {
	principal, ok := settlementPrincipalFromContext(c)
	if !ok {
		return nil, 0, false
	}
	id, err := strconv.ParseUint(c.Param("settlement_id"), 10, 64)
	if err != nil || id == 0 {
		response.Failure(c, apperror.ErrValidationFailed, nil)
		return nil, 0, false
	}
	return principal, id, true
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
