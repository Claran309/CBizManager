package platform

import (
	"context"
	"errors"
	"fmt"
	"strconv"
	"strings"
	"time"

	"gorm.io/gorm"
	"gorm.io/gorm/clause"

	"CBizDocsManager/backend/internal/identity"
	"CBizDocsManager/backend/internal/organization"
)

// 以下是 Repository 层内部使用的哨兵错误，Service 负责把它们映射成稳定的业务错误码。
// 这样 Repository 不需要依赖 apperror，也能让上层用 errors.Is 精确判断失败原因。
var (
	ErrUsernameConflict     = errors.New("username conflict")
	ErrGroupNameConflict    = errors.New("group name conflict")
	ErrGroupMissing         = errors.New("group missing")
	ErrGroupStatusInvalid   = errors.New("group status invalid")
	ErrVersionConflict      = errors.New("resource version conflict")
	ErrOwnerTargetInvalid   = errors.New("owner target invalid")
	ErrOwnerTargetForbidden = errors.New("owner target forbidden")
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
	ListGroups(ctx context.Context, query GroupQuery) ([]GroupSummaryData, int64, error)
	GetGroupDetail(ctx context.Context, groupID uint64) (*GroupDetailData, error)
	ChangeGroupStatus(ctx context.Context, input ChangeGroupStatusInput) (*GroupSummaryData, error)
	ChangeOwner(ctx context.Context, input ChangeOwnerInput) (*OwnerChange, error)
}

type ChangeGroupStatusInput struct {
	GroupID         uint64
	Status          organization.GroupStatus
	ExpectedVersion uint64
	OperatorUserID  uint64
	Now             time.Time
}
type ChangeOwnerInput struct {
	GroupID                             uint64
	Mode                                ChangeOwnerMode
	MembershipID                        *uint64
	Username, DisplayName, PasswordHash string
	ExpectedVersion, OperatorUserID     uint64
	Now                                 time.Time
}
type OwnerChange struct {
	Group              organization.Group
	OldOwner           identity.User
	NewOwner           identity.User
	NewOwnerMembership organization.Membership
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

func (r *gormRepository) ListGroups(ctx context.Context, query GroupQuery) ([]GroupSummaryData, int64, error) {
	page, size := query.Page, query.PageSize
	if page < 1 {
		page = 1
	}
	if size < 1 || size > 100 {
		size = 20
	}
	base := r.db.WithContext(ctx).Table("groups AS g").Joins("JOIN users AS owner ON owner.id = g.owner_user_id").Where("1=1")
	if query.Status != "" {
		base = base.Where("g.status = ?", query.Status)
	}
	if keyword := strings.TrimSpace(query.Keyword); keyword != "" {
		base = base.Where("g.name LIKE ?", "%"+keyword+"%")
	}
	var total int64
	if err := base.Count(&total).Error; err != nil {
		return nil, 0, err
	}
	type row struct {
		ID                              uint64
		Name                            string
		Status                          string
		OwnerID                         uint64
		OwnerUsername, OwnerDisplayName string
		OwnerAccountType                string
		MemberCount                     int64
		Version                         uint64
		CreatedAt, UpdatedAt            time.Time
	}
	var rows []row
	q := base.Select("g.id, g.name, g.status, g.owner_user_id AS owner_id, owner.username AS owner_username, owner.display_name AS owner_display_name, owner.account_type AS owner_account_type, (SELECT COUNT(*) FROM memberships m WHERE m.group_id = g.id AND m.status <> 'removed') AS member_count, g.version, g.created_at, g.updated_at").Order("g.created_at DESC, g.id DESC").Offset((page - 1) * size).Limit(size)
	if err := q.Scan(&rows).Error; err != nil {
		return nil, 0, err
	}
	result := make([]GroupSummaryData, 0, len(rows))
	for _, item := range rows {
		result = append(result, GroupSummaryData{ID: item.ID, Name: item.Name, Status: organization.GroupStatus(item.Status), Owner: identity.UserSummary{ID: item.OwnerID, Username: item.OwnerUsername, DisplayName: item.OwnerDisplayName, AccountType: identity.AccountType(item.OwnerAccountType)}, MemberCount: item.MemberCount, Version: item.Version, CreatedAt: item.CreatedAt, UpdatedAt: item.UpdatedAt})
	}
	return result, total, nil
}

func (r *gormRepository) GetGroupDetail(ctx context.Context, groupID uint64) (*GroupDetailData, error) {
	var group organization.Group
	if err := r.db.WithContext(ctx).First(&group, groupID).Error; errors.Is(err, gorm.ErrRecordNotFound) {
		return nil, ErrGroupMissing
	} else if err != nil {
		return nil, err
	}
	var owner identity.User
	if err := r.db.WithContext(ctx).First(&owner, group.OwnerUserID).Error; err != nil {
		return nil, err
	}
	var counts []struct {
		Status string
		Count  int64
	}
	if err := r.db.WithContext(ctx).Table("memberships").Select("status, COUNT(*) AS count").Where("group_id = ?", groupID).Group("status").Scan(&counts).Error; err != nil {
		return nil, err
	}
	memberCounts := map[organization.MembershipStatus]int64{}
	for _, c := range counts {
		memberCounts[organization.MembershipStatus(c.Status)] = c.Count
	}
	var candidates []OwnerCandidateData
	err := r.db.WithContext(ctx).Table("memberships AS m").Joins("JOIN users u ON u.id=m.user_id").Where("m.group_id=? AND m.member_type=? AND m.status=?", groupID, organization.MemberTypeMember, organization.MembershipStatusActive).Order("u.display_name ASC,m.id ASC").Select("m.id AS membership_id,u.id,u.username,u.display_name,u.account_type").Scan(&candidates).Error
	if err != nil {
		return nil, err
	}
	return &GroupDetailData{Group: GroupSummaryData{ID: group.ID, Name: group.Name, Status: group.Status, Owner: identity.UserSummary{ID: owner.ID, Username: owner.Username, DisplayName: owner.DisplayName, AccountType: owner.AccountType}, MemberCount: memberCounts[organization.MembershipStatusActive] + memberCounts[organization.MembershipStatusDisabled], Version: group.Version, CreatedAt: group.CreatedAt, UpdatedAt: group.UpdatedAt}, MemberCounts: memberCounts, OwnerCandidates: candidates}, nil
}

// ChangeGroupStatus 在单个事务内变更组状态。
//
// 语义要点：
//  1. 只允许 active / disabled 两个状态，非法枚举直接拒绝；
//  2. 目标状态与当前一致时视为幂等成功，不校验版本、不重复撤销会话；
//  3. 停用组必须在同一事务里撤销组内所有未撤销的 refresh session，启用则不恢复旧会话；
//  4. 任一步失败整笔回滚，最后追加审计日志。
func (r *gormRepository) ChangeGroupStatus(ctx context.Context, input ChangeGroupStatusInput) (*GroupSummaryData, error) {
	if input.Status != organization.GroupStatusActive && input.Status != organization.GroupStatusDisabled {
		return nil, ErrGroupStatusInvalid
	}

	err := r.db.WithContext(ctx).Transaction(func(tx *gorm.DB) error {
		// 先锁住组行，避免两个平台管理员并发改同一个组的状态。
		var group organization.Group
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).First(&group, input.GroupID).Error; err != nil {
			if errors.Is(err, gorm.ErrRecordNotFound) {
				return ErrGroupMissing
			}
			return fmt.Errorf("lock group: %w", err)
		}

		if group.Status == input.Status {
			return nil
		}
		if group.Version != input.ExpectedVersion {
			return ErrVersionConflict
		}

		if err := tx.Model(&organization.Group{}).
			Where("id = ? AND version = ?", input.GroupID, input.ExpectedVersion).
			Updates(map[string]any{
				"status":     input.Status,
				"version":    gorm.Expr("version + 1"),
				"updated_at": input.Now,
			}).Error; err != nil {
			return fmt.Errorf("update group status: %w", err)
		}

		if input.Status == organization.GroupStatusDisabled {
			if err := tx.Model(&identity.RefreshSession{}).
				Where("group_id = ? AND revoked_at IS NULL", input.GroupID).
				Updates(map[string]any{"revoked_at": input.Now, "last_used_at": input.Now}).Error; err != nil {
				return fmt.Errorf("revoke group sessions: %w", err)
			}
		}

		return appendAudit(tx, input.GroupID, input.OperatorUserID, "platform.group.status_changed", "group", input.GroupID, "平台已变更组状态", input.Now)
	})
	if err != nil {
		return nil, err
	}
	// 事务提交、行锁释放后再读取最新摘要，避免在持锁事务内用另一条连接重复查询同一行。
	return r.GetGroupSummary(ctx, input.GroupID)
}

func (r *gormRepository) GetGroupSummary(ctx context.Context, groupID uint64) (*GroupSummaryData, error) {
	detail, err := r.GetGroupDetail(ctx, groupID)
	if err != nil {
		return nil, err
	}
	return &detail.Group, nil
}

func (r *gormRepository) ChangeOwner(ctx context.Context, input ChangeOwnerInput) (*OwnerChange, error) {
	change := &OwnerChange{}
	err := r.db.WithContext(ctx).Transaction(func(tx *gorm.DB) error {
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).First(&change.Group, input.GroupID).Error; errors.Is(err, gorm.ErrRecordNotFound) {
			return ErrGroupMissing
		} else if err != nil {
			return err
		}
		if change.Group.Version != input.ExpectedVersion {
			return ErrVersionConflict
		}
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).First(&change.OldOwner, change.Group.OwnerUserID).Error; err != nil {
			return err
		}
		var oldMembership organization.Membership
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).Where("group_id=? AND user_id=?", input.GroupID, change.OldOwner.ID).First(&oldMembership).Error; err != nil {
			return err
		}
		var targetMembership organization.Membership
		if input.Mode == ChangeOwnerExistingMember {
			if input.MembershipID == nil {
				return ErrOwnerTargetInvalid
			}
			if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).Where("id=? AND group_id=?", *input.MembershipID, input.GroupID).First(&targetMembership).Error; errors.Is(err, gorm.ErrRecordNotFound) {
				return ErrOwnerTargetForbidden
			} else if err != nil {
				return err
			}
			if targetMembership.MemberType != organization.MemberTypeMember || targetMembership.Status != organization.MembershipStatusActive {
				return ErrOwnerTargetForbidden
			}
			if err := tx.First(&change.NewOwner, targetMembership.UserID).Error; err != nil {
				return err
			}
		} else if input.Mode == ChangeOwnerNewAccount {
			change.NewOwner = identity.User{Username: input.Username, PasswordHash: input.PasswordHash, DisplayName: input.DisplayName, AccountType: identity.AccountTypeGroupOwner, Status: identity.UserStatusActive, MustChangePassword: true, CreatedAt: input.Now, UpdatedAt: input.Now}
			if err := tx.Create(&change.NewOwner).Error; err != nil {
				if errors.Is(err, gorm.ErrDuplicatedKey) {
					return ErrUsernameConflict
				}
				return err
			}
			targetMembership = organization.Membership{GroupID: input.GroupID, UserID: change.NewOwner.ID, MemberType: organization.MemberTypeMember, Status: organization.MembershipStatusActive, CreatedAt: input.Now, UpdatedAt: input.Now}
			if err := tx.Create(&targetMembership).Error; err != nil {
				return err
			}
		} else {
			return ErrOwnerTargetInvalid
		}
		if targetMembership.ID == oldMembership.ID {
			return ErrOwnerTargetForbidden
		}
		if err := tx.Table("membership_permissions").Where("membership_id IN ?", []uint64{oldMembership.ID, targetMembership.ID}).Delete(nil).Error; err != nil {
			return err
		}
		if err := tx.Model(&oldMembership).Updates(map[string]any{"member_type": organization.MemberTypeMember, "status": organization.MembershipStatusDisabled, "version": gorm.Expr("version+1"), "updated_at": input.Now}).Error; err != nil {
			return err
		}
		if err := tx.Model(&change.OldOwner).Updates(map[string]any{"account_type": identity.AccountTypeMember, "updated_at": input.Now}).Error; err != nil {
			return err
		}
		if err := tx.Model(&targetMembership).Updates(map[string]any{"member_type": organization.MemberTypeOwner, "status": organization.MembershipStatusActive, "version": gorm.Expr("version+1"), "updated_at": input.Now}).Error; err != nil {
			return err
		}
		if err := tx.Model(&change.NewOwner).Updates(map[string]any{"account_type": identity.AccountTypeGroupOwner, "updated_at": input.Now}).Error; err != nil {
			return err
		}
		if err := tx.Model(&organization.Group{}).Where("id=? AND version=?", input.GroupID, input.ExpectedVersion).Updates(map[string]any{"owner_user_id": change.NewOwner.ID, "version": gorm.Expr("version+1"), "updated_at": input.Now}).Error; err != nil {
			return err
		}
		if err := tx.Model(&identity.RefreshSession{}).Where("user_id IN ? AND revoked_at IS NULL", []uint64{change.OldOwner.ID, change.NewOwner.ID}).Updates(map[string]any{"revoked_at": input.Now, "last_used_at": input.Now}).Error; err != nil {
			return err
		}
		return appendAudit(tx, input.GroupID, input.OperatorUserID, "platform.group.owner_changed", "group", input.GroupID, "平台已完成主账号交接", input.Now)
	})
	if err != nil {
		return nil, err
	}
	return change, nil
}

func appendAudit(db *gorm.DB, groupID, operator uint64, action, resource string, resourceID uint64, summary string, now time.Time) error {
	return db.Table("audit_logs").Create(map[string]any{"group_id": groupID, "operator_user_id": operator, "action": action, "resource_type": resource, "resource_id": strconv.FormatUint(resourceID, 10), "summary": summary, "created_at": now}).Error
}
