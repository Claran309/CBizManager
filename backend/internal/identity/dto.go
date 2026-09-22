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
	// PermissionCodes 是当前成员在本组内被显式授予的权限码（成员账号）。
	// 平台管理员与主账号返回空数组：它们的权限来自角色本身，不需要逐条授权。
	// 客户端只用它做菜单/按钮级渲染，真正的鉴权仍在服务端逐请求校验。
	PermissionCodes []string `json:"permission_codes"`
}
