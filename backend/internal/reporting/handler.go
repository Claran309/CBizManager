package reporting

import (
	"context"
	"net/http"
	"strconv"

	"CBizDocsManager/backend/internal/identity"
	"CBizDocsManager/backend/pkg/apperror"
	"CBizDocsManager/backend/pkg/response"
	"github.com/gin-gonic/gin"
)

// ReportService 是 Handler 依赖的服务能力。
type ReportService interface {
	Overview(ctx context.Context, principal identity.Principal, query PeriodQuery) (*OverviewData, error)
	InboundStats(ctx context.Context, principal identity.Principal, query ItemStatsQuery) (*InboundStatsData, error)
	OutboundStats(ctx context.Context, principal identity.Principal, query ItemStatsQuery) (*OutboundStatsData, error)
	BusinessUsers(ctx context.Context, principal identity.Principal, query BusinessUserQuery) (*BusinessUserReportData, error)
	CreateSnapshots(ctx context.Context, principal identity.Principal, request CreateSnapshotRequest) (*CreateSnapshotData, error)
	ListSnapshots(ctx context.Context, principal identity.Principal, query SnapshotListQuery) (*SnapshotPageData, error)
	GetSnapshot(ctx context.Context, principal identity.Principal, snapshotID uint64) (*SnapshotData, error)
}

// Handler 承载汇总统计的 HTTP 转换。
type Handler struct {
	service ReportService
}

// NewHandler 创建汇总统计 Handler。
func NewHandler(service ReportService) *Handler { return &Handler{service: service} }

// Overview 返回后台数据汇总看板。
func (h *Handler) Overview(c *gin.Context) {
	principal, ok := reportPrincipalFromContext(c)
	if !ok {
		return
	}
	var query PeriodQuery
	if err := c.ShouldBindQuery(&query); err != nil {
		response.Failure(c, apperror.ErrValidationFailed, response.ValidationErrors(err))
		return
	}
	result, err := h.service.Overview(c.Request.Context(), *principal, query)
	if err != nil {
		response.Failure(c, err, nil)
		return
	}
	response.Success(c, http.StatusOK, result)
}

// InboundStats 返回入库统计。
func (h *Handler) InboundStats(c *gin.Context) {
	principal, ok := reportPrincipalFromContext(c)
	if !ok {
		return
	}
	var query ItemStatsQuery
	if err := c.ShouldBindQuery(&query); err != nil {
		response.Failure(c, apperror.ErrValidationFailed, response.ValidationErrors(err))
		return
	}
	result, err := h.service.InboundStats(c.Request.Context(), *principal, query)
	if err != nil {
		response.Failure(c, err, nil)
		return
	}
	response.Success(c, http.StatusOK, result)
}

// OutboundStats 返回出库统计。
func (h *Handler) OutboundStats(c *gin.Context) {
	principal, ok := reportPrincipalFromContext(c)
	if !ok {
		return
	}
	var query ItemStatsQuery
	if err := c.ShouldBindQuery(&query); err != nil {
		response.Failure(c, apperror.ErrValidationFailed, response.ValidationErrors(err))
		return
	}
	result, err := h.service.OutboundStats(c.Request.Context(), *principal, query)
	if err != nil {
		response.Failure(c, err, nil)
		return
	}
	response.Success(c, http.StatusOK, result)
}

// BusinessUsers 返回业务员维度利润统计。
func (h *Handler) BusinessUsers(c *gin.Context) {
	principal, ok := reportPrincipalFromContext(c)
	if !ok {
		return
	}
	var query BusinessUserQuery
	if err := c.ShouldBindQuery(&query); err != nil {
		response.Failure(c, apperror.ErrValidationFailed, response.ValidationErrors(err))
		return
	}
	result, err := h.service.BusinessUsers(c.Request.Context(), *principal, query)
	if err != nil {
		response.Failure(c, err, nil)
		return
	}
	response.Success(c, http.StatusOK, result)
}

// CreateSnapshots 生成月度总结算快照。
func (h *Handler) CreateSnapshots(c *gin.Context) {
	principal, ok := reportPrincipalFromContext(c)
	if !ok {
		return
	}
	var request CreateSnapshotRequest
	if err := c.ShouldBindJSON(&request); err != nil {
		response.Failure(c, apperror.ErrValidationFailed, response.ValidationErrors(err))
		return
	}
	result, err := h.service.CreateSnapshots(c.Request.Context(), *principal, request)
	if err != nil {
		response.Failure(c, err, nil)
		return
	}
	response.Success(c, http.StatusCreated, result)
}

// ListSnapshots 分页查询总结算快照。
func (h *Handler) ListSnapshots(c *gin.Context) {
	principal, ok := reportPrincipalFromContext(c)
	if !ok {
		return
	}
	var query SnapshotListQuery
	if err := c.ShouldBindQuery(&query); err != nil {
		response.Failure(c, apperror.ErrValidationFailed, response.ValidationErrors(err))
		return
	}
	result, err := h.service.ListSnapshots(c.Request.Context(), *principal, query)
	if err != nil {
		response.Failure(c, err, nil)
		return
	}
	response.Success(c, http.StatusOK, result)
}

// GetSnapshot 读取一张总结算快照。
func (h *Handler) GetSnapshot(c *gin.Context) {
	principal, ok := reportPrincipalFromContext(c)
	if !ok {
		return
	}
	snapshotID, err := strconv.ParseUint(c.Param("snapshot_id"), 10, 64)
	if err != nil || snapshotID == 0 {
		response.Failure(c, apperror.ErrValidationFailed, nil)
		return
	}
	result, err := h.service.GetSnapshot(c.Request.Context(), *principal, snapshotID)
	if err != nil {
		response.Failure(c, err, nil)
		return
	}
	response.Success(c, http.StatusOK, result)
}

func reportPrincipalFromContext(c *gin.Context) (*identity.Principal, bool) {
	principal, ok := identity.PrincipalFromContext(c)
	if !ok {
		response.Failure(c, apperror.ErrAuthTokenExpired, nil)
		return nil, false
	}
	return principal, true
}
