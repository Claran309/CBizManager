package document

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

// idempotencyHeader 是离线队列重复提交时携带的幂等键请求头。
const idempotencyHeader = "Idempotency-Key"

// DocumentService 是 Handler 依赖的服务能力。
type DocumentService interface {
	Create(ctx context.Context, principal identity.Principal, kind Kind, request CreateRequest, idempotencyKey string) (*DocumentData, error)
	Update(ctx context.Context, principal identity.Principal, kind Kind, documentID uint64, request UpdateRequest, idempotencyKey string) (*DocumentData, error)
	Get(ctx context.Context, principal identity.Principal, kind Kind, documentID uint64) (*DocumentData, error)
	List(ctx context.Context, principal identity.Principal, kind Kind, query ListQuery) (*DocumentPageData, error)
	Submit(ctx context.Context, principal identity.Principal, kind Kind, documentID uint64, request VersionRequest) (*DocumentData, error)
	Void(ctx context.Context, principal identity.Principal, kind Kind, documentID uint64, request VersionRequest) (*DocumentData, error)
	MonthlySummary(ctx context.Context, principal identity.Principal, kind Kind, month string, bucketSize int) (*MonthlySummaryData, error)
}

// MonthlySummaryQuery 是汇总接口的查询参数。
type MonthlySummaryQuery struct {
	Month      string `form:"month"`
	BucketSize int    `form:"bucket_size" binding:"omitempty,min=1,max=100"`
}

// Handler 承载某一类单据（入库或出库）的 HTTP 转换。
// 入库与出库共享同一套服务逻辑，差别只在构造 Handler 时注入的 kind。
type Handler struct {
	service DocumentService
	kind    Kind
}

// NewHandler 创建指定类型单据的 Handler。
func NewHandler(service DocumentService, kind Kind) *Handler {
	return &Handler{service: service, kind: kind}
}

// Create 创建单据；草稿与直接提交都走这个入口。
func (h *Handler) Create(c *gin.Context) {
	principal, ok := documentPrincipalFromContext(c)
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

// Update 整体替换单据内容，必须携带 version。
func (h *Handler) Update(c *gin.Context) {
	principal, documentID, ok := documentPrincipalAndID(c)
	if !ok {
		return
	}
	var request UpdateRequest
	if err := c.ShouldBindJSON(&request); err != nil {
		response.Failure(c, apperror.ErrValidationFailed, response.ValidationErrors(err))
		return
	}
	idempotencyKey, ok := idempotencyKeyFromHeader(c)
	if !ok {
		return
	}
	result, err := h.service.Update(c.Request.Context(), *principal, h.kind, documentID, request, idempotencyKey)
	if err != nil {
		response.Failure(c, err, nil)
		return
	}
	response.Success(c, http.StatusOK, result)
}

// Get 读取单据详情。
func (h *Handler) Get(c *gin.Context) {
	principal, documentID, ok := documentPrincipalAndID(c)
	if !ok {
		return
	}
	result, err := h.service.Get(c.Request.Context(), *principal, h.kind, documentID)
	if err != nil {
		response.Failure(c, err, nil)
		return
	}
	response.Success(c, http.StatusOK, result)
}

// List 分页查询单据。
func (h *Handler) List(c *gin.Context) {
	principal, ok := documentPrincipalFromContext(c)
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

// MonthlySummary 返回月度汇总（手机端「按月份回顾」与后台统计共用）。
func (h *Handler) MonthlySummary(c *gin.Context) {
	principal, ok := documentPrincipalFromContext(c)
	if !ok {
		return
	}
	var query MonthlySummaryQuery
	if err := c.ShouldBindQuery(&query); err != nil {
		response.Failure(c, apperror.ErrValidationFailed, response.ValidationErrors(err))
		return
	}
	result, err := h.service.MonthlySummary(c.Request.Context(), *principal, h.kind, strings.TrimSpace(query.Month), query.BucketSize)
	if err != nil {
		response.Failure(c, err, nil)
		return
	}
	response.Success(c, http.StatusOK, result)
}

// Submit 提交草稿到后台。
func (h *Handler) Submit(c *gin.Context) {
	h.changeStatus(c, h.service.Submit)
}

// Void 作废单据。
func (h *Handler) Void(c *gin.Context) {
	h.changeStatus(c, h.service.Void)
}

func (h *Handler) changeStatus(c *gin.Context, action func(context.Context, identity.Principal, Kind, uint64, VersionRequest) (*DocumentData, error)) {
	principal, documentID, ok := documentPrincipalAndID(c)
	if !ok {
		return
	}
	var request VersionRequest
	if err := c.ShouldBindJSON(&request); err != nil {
		response.Failure(c, apperror.ErrValidationFailed, response.ValidationErrors(err))
		return
	}
	result, err := action(c.Request.Context(), *principal, h.kind, documentID, request)
	if err != nil {
		response.Failure(c, err, nil)
		return
	}
	response.Success(c, http.StatusOK, result)
}

func documentPrincipalFromContext(c *gin.Context) (*identity.Principal, bool) {
	principal, ok := identity.PrincipalFromContext(c)
	if !ok {
		response.Failure(c, apperror.ErrAuthTokenExpired, nil)
		return nil, false
	}
	return principal, true
}

func documentPrincipalAndID(c *gin.Context) (*identity.Principal, uint64, bool) {
	principal, ok := documentPrincipalFromContext(c)
	if !ok {
		return nil, 0, false
	}
	id, err := strconv.ParseUint(c.Param("document_id"), 10, 64)
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
