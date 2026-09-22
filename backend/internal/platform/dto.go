package platform

import (
	"CBizDocsManager/backend/internal/identity"
	"CBizDocsManager/backend/internal/organization"
	"time"
)

type CreateGroupRequest struct {
	Name                   string `json:"name" binding:"required"`
	OwnerUsername          string `json:"owner_username" binding:"required"`
	OwnerDisplayName       string `json:"owner_display_name" binding:"required"`
	OwnerTemporaryPassword string `json:"owner_temporary_password" binding:"required,min=8"`
}

type GroupCreatedData struct {
	Group identity.GroupSummary `json:"group"`
	Owner identity.UserSummary  `json:"owner"`
}

type GroupQuery struct {
	Page     int                      `form:"page"`
	PageSize int                      `form:"page_size"`
	Status   organization.GroupStatus `form:"status"`
	Keyword  string                   `form:"keyword"`
}
type GroupSummaryData struct {
	ID          uint64                   `json:"id"`
	Name        string                   `json:"name"`
	Status      organization.GroupStatus `json:"status"`
	Owner       identity.UserSummary     `json:"owner"`
	MemberCount int64                    `json:"member_count"`
	Version     uint64                   `json:"version"`
	CreatedAt   time.Time                `json:"created_at"`
	UpdatedAt   time.Time                `json:"updated_at"`
}
type OwnerCandidateData struct {
	MembershipID uint64               `json:"membership_id"`
	User         identity.UserSummary `json:"user"`
}
type GroupDetailData struct {
	Group           GroupSummaryData                        `json:"group"`
	MemberCounts    map[organization.MembershipStatus]int64 `json:"member_counts"`
	OwnerCandidates []OwnerCandidateData                    `json:"owner_candidates"`
}
type GroupPageData struct {
	Items    []GroupSummaryData `json:"items"`
	Page     int                `json:"page"`
	PageSize int                `json:"page_size"`
	Total    int64              `json:"total"`
}
type ChangeGroupStatusRequest struct {
	Status  organization.GroupStatus `json:"status" binding:"required,oneof=active disabled"`
	Version uint64                   `json:"version" binding:"required,min=1"`
}
type ChangeOwnerMode string

const (
	ChangeOwnerExistingMember ChangeOwnerMode = "existing_member"
	ChangeOwnerNewAccount     ChangeOwnerMode = "new_account"
)

type ChangeGroupOwnerRequest struct {
	Mode              ChangeOwnerMode `json:"mode" binding:"required,oneof=existing_member new_account"`
	MembershipID      *uint64         `json:"membership_id"`
	Username          *string         `json:"username"`
	DisplayName       *string         `json:"display_name"`
	TemporaryPassword *string         `json:"temporary_password"`
	Version           uint64          `json:"version" binding:"required,min=1"`
}
type OwnerChangedData struct {
	Group GroupSummaryData     `json:"group"`
	Owner identity.UserSummary `json:"owner"`
}
