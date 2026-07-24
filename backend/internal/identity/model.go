package identity

import "time"

type AccountType string

const (
	AccountTypePlatformAdmin AccountType = "platform_admin"
	AccountTypeGroupOwner    AccountType = "group_owner"
	AccountTypeMember        AccountType = "member"
)

type UserStatus string

const (
	UserStatusActive   UserStatus = "active"
	UserStatusDisabled UserStatus = "disabled"
)

type User struct {
	ID                 uint64      `gorm:"primaryKey;autoIncrement"`
	Username           string      `gorm:"size:191;not null;uniqueIndex:uk_users_username"`
	PasswordHash       string      `gorm:"size:255;not null"`
	DisplayName        string      `gorm:"size:191;not null"`
	AccountType        AccountType `gorm:"size:32;not null;index:idx_users_account_type_status,priority:1"`
	Status             UserStatus  `gorm:"size:16;not null;index:idx_users_account_type_status,priority:2"`
	MustChangePassword bool        `gorm:"not null;default:false"`
	CreatedAt          time.Time
	UpdatedAt          time.Time
}

func (User) TableName() string { return "users" }

type RefreshSession struct {
	ID                  uint64 `gorm:"primaryKey;autoIncrement"`
	UserID              uint64 `gorm:"not null;index:idx_refresh_sessions_user_state,priority:1"`
	GroupID             *uint64
	TokenHash           string `gorm:"size:64;not null;uniqueIndex:uk_refresh_sessions_token_hash"`
	ExpiresAt           time.Time
	RevokedAt           *time.Time `gorm:"index:idx_refresh_sessions_user_state,priority:2"`
	ReplacedBySessionID *uint64
	CreatedAt           time.Time
	LastUsedAt          *time.Time
}

func (RefreshSession) TableName() string { return "refresh_sessions" }

// AccessState 是认证与刷新签发 Access Token 所需的最小实时访问状态。
type AccessState struct {
	UserID             uint64
	GroupID            *uint64
	GroupName          string
	AccountType        AccountType
	MemberType         string
	MustChangePassword bool
	UserStatus         UserStatus
	GroupStatus        string
	MembershipStatus   string
}

// Principal 是通过 Access Token 和数据库实时状态共同确认的当前身份。
type Principal struct {
	UserID             uint64
	GroupID            *uint64
	GroupName          string
	AccountType        AccountType
	MemberType         string
	MustChangePassword bool
	SessionID          uint64
}
