package member

import (
	"context"
	"errors"
	"fmt"
	"sort"
	"strconv"
	"time"

	"CBizDocsManager/backend/internal/authorization"
	"CBizDocsManager/backend/internal/identity"
	"CBizDocsManager/backend/internal/organization"
	"gorm.io/gorm"
	"gorm.io/gorm/clause"
)

type permissionRecord struct {
	ID             uint64             `gorm:"primaryKey;autoIncrement"`
	GroupID        uint64             `gorm:"not null"`
	MembershipID   uint64             `gorm:"not null"`
	PermissionCode authorization.Code `gorm:"size:100;not null"`
	GrantedBy      uint64             `gorm:"not null"`
	CreatedAt      time.Time
}

func (permissionRecord) TableName() string { return "membership_permissions" }

type gormRepository struct{ db *gorm.DB }

func NewRepository(db *gorm.DB) Repository { return &gormRepository{db: db} }

type memberRow struct {
	MembershipID uint64
	GroupID      uint64
	UserID       uint64
	Username     string
	DisplayName  string
	AccountType  identity.AccountType
	MemberType   organization.MemberType
	Status       organization.MembershipStatus
	Version      uint64
	CreatedAt    time.Time
	UpdatedAt    time.Time
}

func (r *gormRepository) List(ctx context.Context, groupID uint64, query ListQuery) (Page, error) {
	base := r.db.WithContext(ctx).Table("memberships AS membership").Where("membership.group_id = ?", groupID)
	if query.Status != nil {
		base = base.Where("membership.status = ?", *query.Status)
	}
	var total int64
	if err := base.Count(&total).Error; err != nil {
		return Page{}, fmt.Errorf("count group members: %w", err)
	}
	var rows []memberRow
	offset := (query.Page - 1) * query.PageSize
	err := base.Select(`membership.id AS membership_id, membership.group_id, membership.user_id,
		user_account.username, user_account.display_name, user_account.account_type,
		membership.member_type, membership.status, membership.version, membership.created_at, membership.updated_at`).
		Joins("JOIN users AS user_account ON user_account.id = membership.user_id").
		Order("membership.id ASC").Offset(offset).Limit(query.PageSize).Scan(&rows).Error
	if err != nil {
		return Page{}, fmt.Errorf("list group members: %w", err)
	}

	items := make([]Member, 0, len(rows))
	membershipIDs := make([]uint64, 0, len(rows))
	for _, row := range rows {
		items = append(items, row.member())
		membershipIDs = append(membershipIDs, row.MembershipID)
	}
	permissions, err := loadPermissionMap(r.db.WithContext(ctx), groupID, membershipIDs)
	if err != nil {
		return Page{}, err
	}
	for index := range items {
		if items[index].MemberType == organization.MemberTypeOwner {
			items[index].PermissionCodes = authorization.Catalog()
			continue
		}
		items[index].PermissionCodes = permissions[items[index].MembershipID]
	}
	return Page{Items: items, Page: query.Page, PageSize: query.PageSize, Total: total}, nil
}

func (r *gormRepository) Find(ctx context.Context, groupID, membershipID uint64) (Member, error) {
	return findMember(r.db.WithContext(ctx), groupID, membershipID)
}

func (r *gormRepository) GetPermissions(ctx context.Context, groupID, membershipID uint64) (PermissionSet, error) {
	member, err := findMember(r.db.WithContext(ctx), groupID, membershipID)
	if err != nil {
		return PermissionSet{}, err
	}
	if member.MemberType == organization.MemberTypeOwner {
		return PermissionSet{MembershipID: membershipID, PermissionCodes: authorization.Catalog(), Version: member.Version}, nil
	}
	permissions, err := loadPermissionMap(r.db.WithContext(ctx), groupID, []uint64{membershipID})
	if err != nil {
		return PermissionSet{}, err
	}
	return PermissionSet{MembershipID: membershipID, PermissionCodes: permissions[membershipID], Version: member.Version}, nil
}

func (r *gormRepository) ChangeStatus(ctx context.Context, groupID, membershipID, operatorUserID, version uint64, status organization.MembershipStatus, now time.Time) (Member, error) {
	var result Member
	err := r.db.WithContext(ctx).Transaction(func(tx *gorm.DB) error {
		tx = tx.WithContext(ctx)
		current, err := findMember(tx.Clauses(clause.Locking{Strength: "UPDATE"}), groupID, membershipID)
		if err != nil {
			return err
		}
		if current.Version != version {
			return ErrVersionConflict
		}
		update := tx.Model(&organization.Membership{}).
			Where("id = ? AND group_id = ? AND version = ?", membershipID, groupID, version).
			Updates(map[string]any{"status": status, "version": gorm.Expr("version + 1"), "updated_at": now})
		if update.Error != nil {
			return fmt.Errorf("update membership status: %w", update.Error)
		}
		if update.RowsAffected != 1 {
			return ErrVersionConflict
		}
		if status == organization.MembershipStatusDisabled || status == organization.MembershipStatusRemoved {
			if err := tx.Model(&identity.RefreshSession{}).
				Where("user_id = ? AND revoked_at IS NULL", current.User.ID).
				Updates(map[string]any{"revoked_at": now, "last_used_at": now}).Error; err != nil {
				return fmt.Errorf("revoke member sessions: %w", err)
			}
		}
		if err := appendMemberAudit(tx, groupID, operatorUserID, "member.status.changed", membershipID, "成员状态已变更", now); err != nil {
			return err
		}
		current.Status = status
		current.Version++
		current.UpdatedAt = now
		result = current
		return nil
	})
	if err != nil {
		return Member{}, err
	}
	return result, nil
}

func (r *gormRepository) ReplacePermissions(ctx context.Context, groupID, membershipID, operatorUserID, version uint64, codes []authorization.Code, now time.Time) (PermissionSet, error) {
	requested := sortedUniqueCodes(codes)
	var result PermissionSet
	err := r.db.WithContext(ctx).Transaction(func(tx *gorm.DB) error {
		tx = tx.WithContext(ctx)
		current, err := findMember(tx.Clauses(clause.Locking{Strength: "UPDATE"}), groupID, membershipID)
		if err != nil {
			return err
		}
		permissions, err := loadPermissionMap(tx, groupID, []uint64{membershipID})
		if err != nil {
			return err
		}
		stored := permissions[membershipID]
		// 相同目标集合是幂等重放，必须在版本检查前返回数据库当前结果。
		if equalCodes(stored, requested) {
			result = PermissionSet{MembershipID: membershipID, PermissionCodes: stored, Version: current.Version}
			return nil
		}
		if current.Version != version {
			return ErrVersionConflict
		}

		storedSet := make(map[authorization.Code]struct{}, len(stored))
		requestedSet := make(map[authorization.Code]struct{}, len(requested))
		for _, code := range stored {
			storedSet[code] = struct{}{}
		}
		for _, code := range requested {
			requestedSet[code] = struct{}{}
		}
		for code := range storedSet {
			if _, keep := requestedSet[code]; keep {
				continue
			}
			if err := tx.Where("membership_id = ? AND group_id = ? AND permission_code = ?", membershipID, groupID, code).Delete(&permissionRecord{}).Error; err != nil {
				return fmt.Errorf("delete member permission: %w", err)
			}
		}
		for code := range requestedSet {
			if _, exists := storedSet[code]; exists {
				continue
			}
			record := permissionRecord{GroupID: groupID, MembershipID: membershipID, PermissionCode: code, GrantedBy: operatorUserID, CreatedAt: now}
			if err := tx.Create(&record).Error; err != nil {
				return fmt.Errorf("create member permission: %w", err)
			}
		}
		update := tx.Model(&organization.Membership{}).Where("id = ? AND group_id = ? AND version = ?", membershipID, groupID, version).
			Updates(map[string]any{"version": gorm.Expr("version + 1"), "updated_at": now})
		if update.Error != nil {
			return fmt.Errorf("increment membership permission version: %w", update.Error)
		}
		if update.RowsAffected != 1 {
			return ErrVersionConflict
		}
		if err := appendMemberAudit(tx, groupID, operatorUserID, "member.permissions.replaced", membershipID, "成员权限已整体替换", now); err != nil {
			return err
		}
		result = PermissionSet{MembershipID: membershipID, PermissionCodes: requested, Version: version + 1}
		return nil
	})
	if err != nil {
		return PermissionSet{}, err
	}
	return result, nil
}

func findMember(db *gorm.DB, groupID, membershipID uint64) (Member, error) {
	var row memberRow
	err := db.Table("memberships AS membership").Select(`membership.id AS membership_id, membership.group_id, membership.user_id,
		user_account.username, user_account.display_name, user_account.account_type,
		membership.member_type, membership.status, membership.version, membership.created_at, membership.updated_at`).
		Joins("JOIN users AS user_account ON user_account.id = membership.user_id").
		Where("membership.id = ? AND membership.group_id = ?", membershipID, groupID).Take(&row).Error
	if errors.Is(err, gorm.ErrRecordNotFound) {
		return Member{}, ErrNotFound
	}
	if err != nil {
		return Member{}, fmt.Errorf("find group member: %w", err)
	}
	return row.member(), nil
}

func (row memberRow) member() Member {
	return Member{MembershipID: row.MembershipID, GroupID: row.GroupID,
		User:       identity.UserSummary{ID: row.UserID, Username: row.Username, DisplayName: row.DisplayName, AccountType: row.AccountType},
		MemberType: row.MemberType, Status: row.Status, Version: row.Version, CreatedAt: row.CreatedAt, UpdatedAt: row.UpdatedAt}
}

func loadPermissionMap(db *gorm.DB, groupID uint64, membershipIDs []uint64) (map[uint64][]authorization.Code, error) {
	result := make(map[uint64][]authorization.Code, len(membershipIDs))
	if len(membershipIDs) == 0 {
		return result, nil
	}
	var records []permissionRecord
	if err := db.Where("group_id = ? AND membership_id IN ?", groupID, membershipIDs).Order("membership_id ASC, permission_code ASC").Find(&records).Error; err != nil {
		return nil, fmt.Errorf("load member permissions: %w", err)
	}
	for _, record := range records {
		result[record.MembershipID] = append(result[record.MembershipID], record.PermissionCode)
	}
	return result, nil
}

func appendMemberAudit(db *gorm.DB, groupID, operatorUserID uint64, action string, membershipID uint64, summary string, now time.Time) error {
	err := db.Table("audit_logs").Create(map[string]any{"group_id": groupID, "operator_user_id": operatorUserID, "action": action,
		"resource_type": "membership", "resource_id": strconv.FormatUint(membershipID, 10), "summary": summary, "created_at": now}).Error
	if err != nil {
		return fmt.Errorf("append member audit: %w", err)
	}
	return nil
}

func sortedUniqueCodes(codes []authorization.Code) []authorization.Code {
	result := append([]authorization.Code(nil), codes...)
	sort.Slice(result, func(i, j int) bool { return result[i] < result[j] })
	unique := result[:0]
	for _, code := range result {
		if len(unique) == 0 || unique[len(unique)-1] != code {
			unique = append(unique, code)
		}
	}
	return unique
}

func equalCodes(left, right []authorization.Code) bool {
	if len(left) != len(right) {
		return false
	}
	for index := range left {
		if left[index] != right[index] {
			return false
		}
	}
	return true
}
