package platform

import (
	"context"
	"net/http"
	"strconv"

	"CBizDocsManager/backend/internal/identity"
	"CBizDocsManager/backend/pkg/apperror"
	"CBizDocsManager/backend/pkg/response"
	"github.com/gin-gonic/gin"
)

type PlatformService interface {
	CreateGroup(ctx context.Context, principal identity.Principal, req CreateGroupRequest) (*GroupCreatedData, error)
	ListGroups(ctx context.Context, principal identity.Principal, query GroupQuery) (*GroupPageData, error)
	GetGroupDetail(ctx context.Context, principal identity.Principal, groupID uint64) (*GroupDetailData, error)
	ChangeGroupStatus(ctx context.Context, principal identity.Principal, groupID uint64, req ChangeGroupStatusRequest) (*GroupSummaryData, error)
	ChangeGroupOwner(ctx context.Context, principal identity.Principal, groupID uint64, req ChangeGroupOwnerRequest) (*OwnerChangedData, error)
}

type Handler struct {
	service PlatformService
}

func NewHandler(service PlatformService) *Handler { return &Handler{service: service} }

func (h *Handler) CreateGroup(c *gin.Context) {
	principal, ok := identity.PrincipalFromContext(c)
	if !ok {
		response.Failure(c, apperror.ErrAuthTokenExpired, nil)
		return
	}
	var req CreateGroupRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		response.Failure(c, apperror.ErrValidationFailed, response.ValidationErrors(err))
		return
	}
	result, err := h.service.CreateGroup(c.Request.Context(), *principal, req)
	if err != nil {
		response.Failure(c, err, nil)
		return
	}
	response.Success(c, http.StatusCreated, result)
}

// ListGroups 处理 GET /api/v1/platform/groups 的组分页查询。
func (h *Handler) ListGroups(c *gin.Context) {
	principal, ok := identity.PrincipalFromContext(c)
	if !ok {
		response.Failure(c, apperror.ErrAuthTokenExpired, nil)
		return
	}
	var query GroupQuery
	if err := c.ShouldBindQuery(&query); err != nil {
		response.Failure(c, apperror.ErrValidationFailed, response.ValidationErrors(err))
		return
	}
	result, err := h.service.ListGroups(c.Request.Context(), *principal, query)
	if err != nil {
		response.Failure(c, err, nil)
		return
	}
	response.Success(c, http.StatusOK, result)
}

// GetGroup 处理 GET /api/v1/platform/groups/:group_id 的组治理详情查询。
func (h *Handler) GetGroup(c *gin.Context) {
	principal, ok := identity.PrincipalFromContext(c)
	if !ok {
		response.Failure(c, apperror.ErrAuthTokenExpired, nil)
		return
	}
	groupID, ok := parseUintParam(c, "group_id")
	if !ok {
		return
	}
	result, err := h.service.GetGroupDetail(c.Request.Context(), *principal, groupID)
	if err != nil {
		response.Failure(c, err, nil)
		return
	}
	response.Success(c, http.StatusOK, result)
}

// ChangeGroupStatus 处理 PATCH /api/v1/platform/groups/:group_id/status 的组启停。
func (h *Handler) ChangeGroupStatus(c *gin.Context) {
	principal, ok := identity.PrincipalFromContext(c)
	if !ok {
		response.Failure(c, apperror.ErrAuthTokenExpired, nil)
		return
	}
	groupID, ok := parseUintParam(c, "group_id")
	if !ok {
		return
	}
	var req ChangeGroupStatusRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		response.Failure(c, apperror.ErrValidationFailed, response.ValidationErrors(err))
		return
	}
	result, err := h.service.ChangeGroupStatus(c.Request.Context(), *principal, groupID, req)
	if err != nil {
		response.Failure(c, err, nil)
		return
	}
	response.Success(c, http.StatusOK, result)
}

// ChangeGroupOwner 处理 PUT /api/v1/platform/groups/:group_id/owner 的主账号交接。
func (h *Handler) ChangeGroupOwner(c *gin.Context) {
	principal, ok := identity.PrincipalFromContext(c)
	if !ok {
		response.Failure(c, apperror.ErrAuthTokenExpired, nil)
		return
	}
	groupID, ok := parseUintParam(c, "group_id")
	if !ok {
		return
	}
	var req ChangeGroupOwnerRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		response.Failure(c, apperror.ErrValidationFailed, response.ValidationErrors(err))
		return
	}
	result, err := h.service.ChangeGroupOwner(c.Request.Context(), *principal, groupID, req)
	if err != nil {
		response.Failure(c, err, nil)
		return
	}
	response.Success(c, http.StatusOK, result)
}

// parseUintParam 解析路径中的无符号整数参数，非法时直接写入统一错误响应并返回 false。
func parseUintParam(c *gin.Context, name string) (uint64, bool) {
	value, err := strconv.ParseUint(c.Param(name), 10, 64)
	if err != nil || value == 0 {
		response.Failure(c, apperror.ErrValidationFailed, nil)
		return 0, false
	}
	return value, true
}
