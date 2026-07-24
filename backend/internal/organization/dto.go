package organization

import (
	"time"

	"CBizDocsManager/backend/internal/identity"
)

type CreateInvitationRequest struct {
	ExpiresInDays int `json:"expires_in_days" binding:"omitempty,min=1,max=30"`
}

type InvitationCreatedData struct {
	InvitationID   uint64                `json:"invitation_id"`
	InvitationCode string                `json:"invitation_code"`
	Group          identity.GroupSummary `json:"group"`
	ExpiresAt      time.Time             `json:"expires_at"`
}

type RegisterRequest struct {
	InvitationCode string `json:"invitation_code" binding:"required"`
	Username       string `json:"username" binding:"required"`
	Password       string `json:"password" binding:"required,min=8"`
	DisplayName    string `json:"display_name" binding:"required"`
}

type RegisterData struct {
	User  identity.UserSummary  `json:"user"`
	Group identity.GroupSummary `json:"group"`
}
