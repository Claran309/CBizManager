package organization

import (
	"context"
	"errors"
	"fmt"
	"strconv"
	"time"

	"gorm.io/gorm"
	"gorm.io/gorm/clause"

	"CBizDocsManager/backend/internal/identity"
)

var (
	ErrInvitationInvalid  = errors.New("invitation invalid")
	ErrInvitationExpired  = errors.New("invitation expired")
	ErrInvitationUsed     = errors.New("invitation used")
	ErrInvitationConflict = errors.New("invitation conflict")
	ErrUsernameConflict   = errors.New("username conflict")
	ErrGroupInactive      = errors.New("group inactive")
)

type CreateInvitationInput struct {
	GroupID        uint64
	CreatedBy      uint64
	CodeHash       string
	CodeCiphertext []byte
	CodeNonce      []byte
	ExpiresAt      time.Time
	Now            time.Time
}

type ConsumeInvitationInput struct {
	CodeHash     string
	Username     string
	PasswordHash string
	DisplayName  string
	Now          time.Time
}

type Registration struct {
	User       identity.User
	Group      Group
	Membership Membership
}

type Repository interface {
	CreateInvitation(ctx context.Context, input CreateInvitationInput) (*Invitation, error)
	ConsumeInvitation(ctx context.Context, input ConsumeInvitationInput) (*Registration, error)
	ListInvitations(ctx context.Context, groupID uint64, query InvitationQuery, now time.Time) ([]InvitationSummaryData, int64, error)
	GetRevealableInvitation(ctx context.Context, groupID, invitationID uint64, now time.Time) (*Invitation, error)
	RevokeInvitation(ctx context.Context, input RevokeInvitationInput) (*Invitation, error)
}

type gormRepository struct {
	db *gorm.DB
}

func NewRepository(db *gorm.DB) Repository {
	return &gormRepository{db: db}
}

func (r *gormRepository) CreateInvitation(ctx context.Context, input CreateInvitationInput) (*Invitation, error) {
	invitation := &Invitation{
		GroupID: input.GroupID, CreatedBy: input.CreatedBy, CodeHash: input.CodeHash,
		CodeCiphertext: input.CodeCiphertext, CodeNonce: input.CodeNonce,
		ExpiresAt: input.ExpiresAt, Status: InvitationStatusActive, CreatedAt: input.Now,
	}
	err := r.db.WithContext(ctx).Transaction(func(tx *gorm.DB) error {
		tx = tx.WithContext(ctx)
		if err := tx.Create(invitation).Error; err != nil {
			if errors.Is(err, gorm.ErrDuplicatedKey) {
				return ErrInvitationConflict
			}
			return fmt.Errorf("create invitation: %w", err)
		}
		if err := appendOrganizationAudit(tx, &invitation.GroupID, input.CreatedBy, "organization.invitation.created", "invitation", invitation.ID, "主账号已创建邀请码", input.Now); err != nil {
			return err
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	return invitation, nil
}

func (r *gormRepository) ConsumeInvitation(ctx context.Context, input ConsumeInvitationInput) (*Registration, error) {
	registration := &Registration{}
	err := r.db.WithContext(ctx).Transaction(func(tx *gorm.DB) error {
		tx = tx.WithContext(ctx)
		var invitation Invitation
		err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).Where("code_hash = ?", input.CodeHash).First(&invitation).Error
		if errors.Is(err, gorm.ErrRecordNotFound) {
			return ErrInvitationInvalid
		}
		if err != nil {
			return fmt.Errorf("lock invitation: %w", err)
		}
		if invitation.Status == InvitationStatusUsed || invitation.UsedAt != nil {
			return ErrInvitationUsed
		}
		if invitation.Status != InvitationStatusActive {
			return ErrInvitationInvalid
		}
		if !invitation.ExpiresAt.After(input.Now) {
			return ErrInvitationExpired
		}

		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).First(&registration.Group, invitation.GroupID).Error; err != nil {
			if errors.Is(err, gorm.ErrRecordNotFound) {
				return ErrInvitationInvalid
			}
			return fmt.Errorf("load invitation group: %w", err)
		}
		if registration.Group.Status != GroupStatusActive {
			return ErrGroupInactive
		}

		registration.User = identity.User{
			Username: input.Username, PasswordHash: input.PasswordHash, DisplayName: input.DisplayName,
			AccountType: identity.AccountTypeMember, Status: identity.UserStatusActive,
			CreatedAt: input.Now, UpdatedAt: input.Now,
		}
		if err := tx.Create(&registration.User).Error; err != nil {
			if errors.Is(err, gorm.ErrDuplicatedKey) {
				return ErrUsernameConflict
			}
			return fmt.Errorf("create invited member: %w", err)
		}

		registration.Membership = Membership{
			GroupID: registration.Group.ID, UserID: registration.User.ID, MemberType: MemberTypeMember,
			Status: MembershipStatusActive, CreatedAt: input.Now, UpdatedAt: input.Now,
		}
		if err := tx.Create(&registration.Membership).Error; err != nil {
			return fmt.Errorf("create member membership: %w", err)
		}

		result := tx.Model(&Invitation{}).
			Where("id = ? AND status = ? AND used_at IS NULL", invitation.ID, InvitationStatusActive).
			Updates(map[string]any{
				"status": InvitationStatusUsed, "used_at": input.Now, "used_by": registration.User.ID,
				"code_ciphertext": nil, "code_nonce": nil, "version": gorm.Expr("version + 1"),
			})
		if result.Error != nil {
			return fmt.Errorf("consume invitation: %w", result.Error)
		}
		if result.RowsAffected != 1 {
			return ErrInvitationUsed
		}
		if err := appendOrganizationAudit(tx, &registration.Group.ID, registration.User.ID, "identity.member.registered", "user", registration.User.ID, "子账号已通过邀请码注册", input.Now); err != nil {
			return err
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	return registration, nil
}

type InvitationDisplayStatus string

const (
	InvitationDisplayActive  InvitationDisplayStatus = "active"
	InvitationDisplayExpired InvitationDisplayStatus = "expired"
	InvitationDisplayUsed    InvitationDisplayStatus = "used"
	InvitationDisplayRevoked InvitationDisplayStatus = "revoked"
)

type InvitationQuery struct {
	Page     int
	PageSize int
	Status   InvitationDisplayStatus
}

type RevokeInvitationInput struct {
	GroupID         uint64
	InvitationID    uint64
	ExpectedVersion uint64
	OperatorUserID  uint64
	Now             time.Time
}

// ListInvitations 按组返回邀请码分页列表。
//
// 数据库只保存 active / used / revoked 三个终态，"已过期"是「active 但 expires_at 已过」的
// 展示投影。这里必须把状态筛选下推到 SQL：如果先分页再在内存里过滤，会出现 total 与实际
// 返回条数不一致、以及某些页整页为空的问题。返回 DTO 而不是实体，避免密文/nonce 泄漏到上层。
func (r *gormRepository) ListInvitations(ctx context.Context, groupID uint64, query InvitationQuery, now time.Time) ([]InvitationSummaryData, int64, error) {
	page, pageSize := query.Page, query.PageSize
	if page < 1 {
		page = 1
	}
	if pageSize < 1 || pageSize > 100 {
		pageSize = 20
	}

	// 每次重新构造条件链，避免 Count 与 Find 复用同一个 *gorm.DB 造成 SELECT 子句污染。
	buildQuery := func() *gorm.DB {
		q := r.db.WithContext(ctx).Model(&Invitation{}).Where("group_id = ?", groupID)
		switch query.Status {
		case InvitationDisplayActive:
			q = q.Where("status = ? AND expires_at > ?", InvitationStatusActive, now)
		case InvitationDisplayExpired:
			q = q.Where("status = ? AND expires_at <= ?", InvitationStatusActive, now)
		case InvitationDisplayUsed:
			q = q.Where("status = ?", InvitationStatusUsed)
		case InvitationDisplayRevoked:
			q = q.Where("status = ?", InvitationStatusRevoked)
		}
		return q
	}

	var total int64
	if err := buildQuery().Count(&total).Error; err != nil {
		return nil, 0, fmt.Errorf("count invitations: %w", err)
	}

	var rows []Invitation
	if err := buildQuery().Order("created_at DESC, id DESC").
		Offset((page - 1) * pageSize).Limit(pageSize).Find(&rows).Error; err != nil {
		return nil, 0, fmt.Errorf("list invitations: %w", err)
	}

	result := make([]InvitationSummaryData, 0, len(rows))
	for _, row := range rows {
		status := InvitationDisplayStatus(row.Status)
		if row.Status == InvitationStatusActive && !row.ExpiresAt.After(now) {
			status = InvitationDisplayExpired
		}
		result = append(result, InvitationSummaryData{
			InvitationID: row.ID,
			Status:       status,
			ExpiresAt:    row.ExpiresAt,
			UsedAt:       row.UsedAt,
			RevokedAt:    row.RevokedAt,
			CreatedAt:    row.CreatedAt,
			Version:      row.Version,
		})
	}
	return result, total, nil
}

func (r *gormRepository) GetRevealableInvitation(ctx context.Context, groupID, invitationID uint64, now time.Time) (*Invitation, error) {
	var invitation Invitation
	err := r.db.WithContext(ctx).Where("id = ? AND group_id = ? AND status = ? AND expires_at > ? AND code_ciphertext IS NOT NULL AND code_nonce IS NOT NULL", invitationID, groupID, InvitationStatusActive, now).First(&invitation).Error
	if errors.Is(err, gorm.ErrRecordNotFound) {
		return nil, ErrInvitationInvalid
	}
	if err != nil {
		return nil, fmt.Errorf("load revealable invitation: %w", err)
	}
	return &invitation, nil
}

func (r *gormRepository) RevokeInvitation(ctx context.Context, input RevokeInvitationInput) (*Invitation, error) {
	var invitation Invitation
	err := r.db.WithContext(ctx).Transaction(func(tx *gorm.DB) error {
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).Where("id = ? AND group_id = ?", input.InvitationID, input.GroupID).First(&invitation).Error; err != nil {
			if errors.Is(err, gorm.ErrRecordNotFound) {
				return ErrInvitationInvalid
			}
			return err
		}
		if invitation.Status == InvitationStatusRevoked {
			return nil
		}
		if invitation.Status != InvitationStatusActive || !invitation.ExpiresAt.After(input.Now) {
			return ErrInvitationConflict
		}
		if invitation.Version != input.ExpectedVersion {
			return ErrInvitationVersionConflict
		}
		result := tx.Model(&Invitation{}).Where("id = ? AND version = ?", invitation.ID, input.ExpectedVersion).Updates(map[string]any{
			"status": InvitationStatusRevoked, "revoked_at": input.Now, "revoked_by": input.OperatorUserID,
			"code_ciphertext": nil, "code_nonce": nil, "version": gorm.Expr("version + 1"),
		})
		if result.Error != nil {
			return result.Error
		}
		if result.RowsAffected != 1 {
			return ErrInvitationVersionConflict
		}
		invitation.Status = InvitationStatusRevoked
		invitation.RevokedAt = &input.Now
		invitation.RevokedBy = &input.OperatorUserID
		invitation.Version++
		invitation.CodeCiphertext, invitation.CodeNonce = nil, nil
		return appendOrganizationAudit(tx, &input.GroupID, input.OperatorUserID, "organization.invitation.revoked", "invitation", invitation.ID, "主账号已撤销邀请码", input.Now)
	})
	if err != nil {
		return nil, err
	}
	return &invitation, nil
}

var ErrInvitationVersionConflict = errors.New("invitation version conflict")

func appendOrganizationAudit(db *gorm.DB, groupID *uint64, operatorUserID uint64, action, resourceType string, resourceID uint64, summary string, now time.Time) error {
	err := db.Table("audit_logs").Create(map[string]any{
		"group_id": groupID, "operator_user_id": operatorUserID, "action": action,
		"resource_type": resourceType, "resource_id": strconv.FormatUint(resourceID, 10),
		"summary": summary, "created_at": now,
	}).Error
	if err != nil {
		return fmt.Errorf("append organization audit: %w", err)
	}
	return nil
}
