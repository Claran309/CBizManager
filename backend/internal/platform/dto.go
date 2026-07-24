package platform

import "CBizDocsManager/backend/internal/identity"

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
