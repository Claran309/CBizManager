package organization

import "time"

type GroupStatus string

const (
	GroupStatusActive   GroupStatus = "active"
	GroupStatusDisabled GroupStatus = "disabled"
)

type MemberType string

const (
	MemberTypeOwner  MemberType = "owner"
	MemberTypeMember MemberType = "member"
)

type MembershipStatus string

const (
	MembershipStatusActive   MembershipStatus = "active"
	MembershipStatusDisabled MembershipStatus = "disabled"
	MembershipStatusRemoved  MembershipStatus = "removed"
)

type InvitationStatus string

const (
	InvitationStatusActive  InvitationStatus = "active"
	InvitationStatusUsed    InvitationStatus = "used"
	InvitationStatusRevoked InvitationStatus = "revoked"
)

type Group struct {
	ID          uint64      `gorm:"primaryKey;autoIncrement"`
	Name        string      `gorm:"size:191;not null;uniqueIndex:uk_groups_name"`
	Status      GroupStatus `gorm:"size:16;not null;index:idx_groups_status"`
	OwnerUserID uint64      `gorm:"not null;uniqueIndex:uk_groups_owner_user_id"`
	// Version 是组治理状态与主账号信息的乐观锁版本，迁移 000003 已建列；
	// 平台启停组和交接主账号都必须带期望版本，避免并发治理请求互相覆盖。
	Version   uint64 `gorm:"not null;default:1"`
	CreatedBy uint64 `gorm:"not null"`
	CreatedAt time.Time
	UpdatedAt time.Time
}

func (Group) TableName() string { return "groups" }

type Membership struct {
	ID         uint64           `gorm:"primaryKey;autoIncrement"`
	GroupID    uint64           `gorm:"not null;uniqueIndex:uk_memberships_group_user,priority:1;index:idx_memberships_group_status,priority:1"`
	UserID     uint64           `gorm:"not null;uniqueIndex:uk_memberships_group_user,priority:2;uniqueIndex:uk_memberships_user"`
	MemberType MemberType       `gorm:"size:16;not null"`
	Status     MembershipStatus `gorm:"size:16;not null;index:idx_memberships_group_status,priority:2"`
	// Version 是成员状态和权限整体替换共用的乐观锁版本，避免并发管理请求相互覆盖。
	Version            uint64  `gorm:"not null;default:1"`
	ActiveOwnerGroupID *uint64 `gorm:"column:active_owner_group_id;->;-:migration"`
	CreatedAt          time.Time
	UpdatedAt          time.Time
}

func (Membership) TableName() string { return "memberships" }

type Invitation struct {
	ID             uint64    `gorm:"primaryKey;autoIncrement"`
	GroupID        uint64    `gorm:"not null;index:idx_invitations_group_status,priority:1"`
	CreatedBy      uint64    `gorm:"not null"`
	CodeHash       string    `gorm:"size:64;not null;uniqueIndex:uk_invitations_code_hash"`
	CodeCiphertext []byte    `gorm:"column:code_ciphertext"`
	CodeNonce      []byte    `gorm:"column:code_nonce"`
	ExpiresAt      time.Time `gorm:"not null;index:idx_invitations_expiry"`
	UsedAt         *time.Time
	UsedBy         *uint64
	Status         InvitationStatus `gorm:"size:16;not null;index:idx_invitations_group_status,priority:2"`
	Version        uint64           `gorm:"not null;default:1"`
	RevokedAt      *time.Time
	RevokedBy      *uint64
	CreatedAt      time.Time
}

func (Invitation) TableName() string { return "invitations" }
