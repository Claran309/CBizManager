package member

import (
	"context"
	"net/http"
	"strconv"

	"CBizDocsManager/backend/internal/authorization"
	"CBizDocsManager/backend/internal/identity"
	"CBizDocsManager/backend/pkg/apperror"
	"CBizDocsManager/backend/pkg/response"
	"github.com/gin-gonic/gin"
)

type MemberService interface {
	List(ctx context.Context, principal identity.Principal, query ListQuery) (Page, error)
	ChangeStatus(ctx context.Context, principal identity.Principal, membershipID uint64, req ChangeStatusRequest) (Member, error)
	GetPermissions(ctx context.Context, principal identity.Principal, membershipID uint64) (PermissionSet, error)
	ReplacePermissions(ctx context.Context, principal identity.Principal, membershipID uint64, req ReplacePermissionsRequest) (PermissionSet, error)
	PermissionCatalog(ctx context.Context, principal identity.Principal) ([]authorization.Code, error)
}

type Handler struct{ service MemberService }

func NewHandler(service MemberService) *Handler { return &Handler{service: service} }

func (h *Handler) List(c *gin.Context) {
	principal, ok := requirePrincipal(c)
	if !ok {
		return
	}
	var query ListQuery
	if err := c.ShouldBindQuery(&query); err != nil {
		response.Failure(c, apperror.ErrValidationFailed, response.ValidationErrors(err))
		return
	}
	page, err := h.service.List(c.Request.Context(), *principal, query)
	if err != nil {
		response.Failure(c, err, nil)
		return
	}
	response.Success(c, http.StatusOK, MemberPageData{Items: page.Items, Pagination: PaginationData{Page: page.Page, PageSize: page.PageSize, Total: page.Total}})
}

func (h *Handler) ChangeStatus(c *gin.Context) {
	principal, membershipID, ok := principalAndMembershipID(c)
	if !ok {
		return
	}
	var request ChangeStatusRequest
	if err := c.ShouldBindJSON(&request); err != nil {
		response.Failure(c, apperror.ErrValidationFailed, response.ValidationErrors(err))
		return
	}
	result, err := h.service.ChangeStatus(c.Request.Context(), *principal, membershipID, request)
	if err != nil {
		response.Failure(c, err, nil)
		return
	}
	response.Success(c, http.StatusOK, result)
}

func (h *Handler) GetPermissions(c *gin.Context) {
	principal, membershipID, ok := principalAndMembershipID(c)
	if !ok {
		return
	}
	result, err := h.service.GetPermissions(c.Request.Context(), *principal, membershipID)
	if err != nil {
		response.Failure(c, err, nil)
		return
	}
	response.Success(c, http.StatusOK, result)
}

func (h *Handler) ReplacePermissions(c *gin.Context) {
	principal, membershipID, ok := principalAndMembershipID(c)
	if !ok {
		return
	}
	var request ReplacePermissionsRequest
	if err := c.ShouldBindJSON(&request); err != nil {
		response.Failure(c, apperror.ErrValidationFailed, response.ValidationErrors(err))
		return
	}
	result, err := h.service.ReplacePermissions(c.Request.Context(), *principal, membershipID, request)
	if err != nil {
		response.Failure(c, err, nil)
		return
	}
	response.Success(c, http.StatusOK, result)
}

func (h *Handler) PermissionCatalog(c *gin.Context) {
	principal, ok := requirePrincipal(c)
	if !ok {
		return
	}
	codes, err := h.service.PermissionCatalog(c.Request.Context(), *principal)
	if err != nil {
		response.Failure(c, err, nil)
		return
	}
	items := make([]PermissionCatalogItem, 0, len(codes))
	for _, code := range codes {
		items = append(items, permissionCatalogItem(code))
	}
	response.Success(c, http.StatusOK, PermissionCatalogData{Items: items})
}

func requirePrincipal(c *gin.Context) (*identity.Principal, bool) {
	principal, ok := identity.PrincipalFromContext(c)
	if !ok {
		response.Failure(c, apperror.ErrAuthTokenExpired, nil)
		return nil, false
	}
	return principal, true
}

func principalAndMembershipID(c *gin.Context) (*identity.Principal, uint64, bool) {
	principal, ok := requirePrincipal(c)
	if !ok {
		return nil, 0, false
	}
	membershipID, err := strconv.ParseUint(c.Param("membership_id"), 10, 64)
	if err != nil || membershipID == 0 {
		response.Failure(c, apperror.ErrValidationFailed, nil)
		return nil, 0, false
	}
	return principal, membershipID, true
}

func permissionCatalogItem(code authorization.Code) PermissionCatalogItem {
	items := map[authorization.Code]PermissionCatalogItem{
		authorization.PermissionDocumentViewOthers: {Code: code, Name: "查看他人单据", Description: "查看同组其他成员创建的单据"},
		authorization.PermissionDocumentEditOthers: {Code: code, Name: "编辑他人单据", Description: "编辑同组其他成员创建的单据"},
		authorization.PermissionReportView:         {Code: code, Name: "查看报表", Description: "查看组内汇总和报表"},
		authorization.PermissionMemberManage:       {Code: code, Name: "成员管理", Description: "查看成员并管理普通成员状态"},
		authorization.PermissionDictionaryManage:   {Code: code, Name: "字典管理", Description: "新增、修改和停用辅助字典"},
		authorization.PermissionSettlementApprove:  {Code: code, Name: "结算审批", Description: "审批结算申请"},
		authorization.PermissionFinanceRecord:      {Code: code, Name: "财务记账", Description: "登记和撤销付款、收款与开票记录"},
	}
	return items[code]
}
