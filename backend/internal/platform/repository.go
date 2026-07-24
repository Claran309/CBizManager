package platform

import (
	"context"
	"errors"
	"fmt"
	"strconv"
	"time"

	"gorm.io/gorm"

	"CBizDocsManager/backend/internal/identity"
	"CBizDocsManager/backend/internal/organization"
)

var (
	ErrUsernameConflict  = errors.New("username conflict")
	ErrGroupNameConflict = errors.New("group name conflict")
)

type CreateGroupInput struct {
	OperatorUserID    uint64
	GroupName         string
	OwnerUsername     string
	OwnerPasswordHash string
	OwnerDisplayName  string
	Now               time.Time
}

type GroupCreation struct {
	Owner      identity.User
	Group      organization.Group
	Membership organization.Membership
}

type Repository interface {
	CreateGroupWithOwner(ctx context.Context, input CreateGroupInput) (*GroupCreation, error)
}

type gormRepository struct {
	db *gorm.DB
}

func NewRepository(db *gorm.DB) Repository {
	return &gormRepository{db: db}
}

func (r *gormRepository) CreateGroupWithOwner(ctx context.Context, input CreateGroupInput) (*GroupCreation, error) {
	created := &GroupCreation{}
	err := r.db.WithContext(ctx).Transaction(func(tx *gorm.DB) error {
		tx = tx.WithContext(ctx)
		created.Owner = identity.User{
			Username: input.OwnerUsername, PasswordHash: input.OwnerPasswordHash, DisplayName: input.OwnerDisplayName,
			AccountType: identity.AccountTypeGroupOwner, Status: identity.UserStatusActive,
			MustChangePassword: true, CreatedAt: input.Now, UpdatedAt: input.Now,
		}
		if err := tx.Create(&created.Owner).Error; err != nil {
			if errors.Is(err, gorm.ErrDuplicatedKey) {
				return ErrUsernameConflict
			}
			return fmt.Errorf("create group owner: %w", err)
		}

		created.Group = organization.Group{
			Name: input.GroupName, Status: organization.GroupStatusActive, OwnerUserID: created.Owner.ID,
			CreatedBy: input.OperatorUserID, CreatedAt: input.Now, UpdatedAt: input.Now,
		}
		if err := tx.Create(&created.Group).Error; err != nil {
			if errors.Is(err, gorm.ErrDuplicatedKey) {
				return ErrGroupNameConflict
			}
			return fmt.Errorf("create group: %w", err)
		}

		created.Membership = organization.Membership{
			GroupID: created.Group.ID, UserID: created.Owner.ID, MemberType: organization.MemberTypeOwner,
			Status: organization.MembershipStatusActive, CreatedAt: input.Now, UpdatedAt: input.Now,
		}
		if err := tx.Create(&created.Membership).Error; err != nil {
			return fmt.Errorf("create owner membership: %w", err)
		}
		if err := tx.Table("audit_logs").Create(map[string]any{
			"group_id": &created.Group.ID, "operator_user_id": input.OperatorUserID,
			"action": "platform.group.created", "resource_type": "group",
			"resource_id": strconv.FormatUint(created.Group.ID, 10), "summary": "平台已创建业务组和主账号",
			"created_at": input.Now,
		}).Error; err != nil {
			return fmt.Errorf("append platform group audit: %w", err)
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	return created, nil
}
