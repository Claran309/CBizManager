package identity

import "time"

type LoginRequest struct {
	Username string `json:"username" binding:"required"`
	Password string `json:"password" binding:"required"`
}

type RefreshRequest struct {
	RefreshToken string `json:"refresh_token" binding:"required"`
}

type ChangePasswordRequest struct {
	CurrentPassword string `json:"current_password" binding:"required"`
	NewPassword     string `json:"new_password" binding:"required,min=8"`
}

type TokenPair struct {
	AccessToken      string    `json:"access_token"`
	RefreshToken     string    `json:"refresh_token"`
	AccessExpiresAt  time.Time `json:"access_expires_at"`
	RefreshExpiresAt time.Time `json:"refresh_expires_at"`
}

type UserSummary struct {
	ID          uint64      `json:"id"`
	Username    string      `json:"username"`
	DisplayName string      `json:"display_name"`
	AccountType AccountType `json:"account_type"`
}

type GroupSummary struct {
	ID   uint64 `json:"id"`
	Name string `json:"name"`
}

type MeResponse struct {
	User               UserSummary   `json:"user"`
	Group              *GroupSummary `json:"group"`
	MemberType         *string       `json:"member_type"`
	MustChangePassword bool          `json:"must_change_password"`
}
