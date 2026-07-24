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
	GroupID   uint64
	CreatedBy uint64
	CodeHash  string
	ExpiresAt time.Time
	Now       time.Time
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
