package member

import (
	"time"

	"CBizDocsManager/backend/internal/authorization"
	"CBizDocsManager/backend/internal/identity"
	"CBizDocsManager/backend/internal/organization"
)

type Member struct {
	MembershipID    uint64                        `json:"membership_id"`
	GroupID         uint64                        `json:"group_id"`
	User            identity.UserSummary          `json:"user"`
	MemberType      organization.MemberType       `json:"member_type"`
	Status          organization.MembershipStatus `json:"status"`
	PermissionCodes []authorization.Code          `json:"permission_codes"`
	Version         uint64                        `json:"version"`
	CreatedAt       time.Time                     `json:"created_at"`
	UpdatedAt       time.Time                     `json:"updated_at"`
}

type PermissionSet struct {
	MembershipID    uint64               `json:"membership_id"`
	PermissionCodes []authorization.Code `json:"permission_codes"`
	Version         uint64               `json:"version"`
}

type Page struct {
	Items    []Member `json:"items"`
	Page     int      `json:"page"`
	PageSize int      `json:"page_size"`
	Total    int64    `json:"total"`
}
