package authorization

import (
	"context"
	"fmt"

	"gorm.io/gorm"
)

type Repository interface {
	HasPermission(ctx context.Context, userID, groupID uint64, code Code) (bool, error)
}

type gormRepository struct {
	db *gorm.DB
}

func NewRepository(db *gorm.DB) Repository {
	return &gormRepository{db: db}
}

func (r *gormRepository) HasPermission(ctx context.Context, userID, groupID uint64, code Code) (bool, error) {
	var count int64
	// 每次授权都重新确认用户、组和成员关系仍有效，使停用操作对后续请求即时生效。
	err := r.db.WithContext(ctx).
		Table("membership_permissions AS permission").
		Joins("JOIN memberships AS membership ON membership.id = permission.membership_id AND membership.group_id = permission.group_id").
		Joins("JOIN users AS user_account ON user_account.id = membership.user_id").
		Joins("JOIN `groups` AS tenant_group ON tenant_group.id = membership.group_id").
		Where("membership.user_id = ?", userID).
		Where("membership.group_id = ?", groupID).
		Where("membership.status = ?", "active").
		Where("user_account.status = ?", "active").
		Where("tenant_group.status = ?", "active").
		Where("permission.permission_code = ?", code).
		Count(&count).Error
	if err != nil {
		return false, fmt.Errorf("query membership permission: %w", err)
	}
	return count > 0, nil
}
