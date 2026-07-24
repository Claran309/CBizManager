package member

import (
	"CBizDocsManager/backend/internal/authorization"
	"CBizDocsManager/backend/internal/organization"
)

type ListQuery struct {
	Page     int                            `form:"page" binding:"omitempty,min=1"`
	PageSize int                            `form:"page_size" binding:"omitempty,min=1,max=100"`
	Status   *organization.MembershipStatus `form:"status" binding:"omitempty,oneof=active disabled removed"`
}

type ChangeStatusRequest struct {
	Status  organization.MembershipStatus `json:"status" binding:"required,oneof=active disabled removed"`
	Version uint64                        `json:"version" binding:"required,min=1"`
}

type ReplacePermissionsRequest struct {
	PermissionCodes []authorization.Code `json:"permission_codes" binding:"required"`
	Version         uint64               `json:"version" binding:"required,min=1"`
}

type PaginationData struct {
	Page     int   `json:"page"`
	PageSize int   `json:"page_size"`
	Total    int64 `json:"total"`
}

type MemberPageData struct {
	Items      []Member       `json:"items"`
	Pagination PaginationData `json:"pagination"`
}

type PermissionCatalogItem struct {
	Code        authorization.Code `json:"code"`
	Name        string             `json:"name"`
	Description string             `json:"description"`
}

type PermissionCatalogData struct {
	Items []PermissionCatalogItem `json:"items"`
}
