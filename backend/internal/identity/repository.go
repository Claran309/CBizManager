package identity

import (
	"context"
	"errors"
	"fmt"
	"strconv"
	"time"

	mysqldriver "github.com/go-sql-driver/mysql"
	"gorm.io/gorm"
	"gorm.io/gorm/clause"
)

const bootstrapDeadlockAttempts = 3

var (
	ErrUserNotFound         = errors.New("user not found")
	ErrUsernameConflict     = errors.New("username conflict")
	ErrRefreshInvalid       = errors.New("refresh session invalid")
	ErrAccessInactive       = errors.New("access state inactive")
	ErrPasswordHashMismatch = errors.New("password hash mismatch")
)

type Repository interface {
	FindUserByUsername(ctx context.Context, username string) (*User, error)
	FindUserByID(ctx context.Context, userID uint64) (*User, error)
	GetAccessState(ctx context.Context, userID uint64) (AccessState, error)
	CreateRefreshSession(ctx context.Context, session *RefreshSession) error
	RotateRefreshSession(ctx context.Context, oldTokenHash string, replacement *RefreshSession, now time.Time) (*RefreshSession, AccessState, error)
	RevokeRefreshSession(ctx context.Context, userID, sessionID uint64, now time.Time) error
	RevokeRefreshToken(ctx context.Context, tokenHash string, now time.Time) error
	ChangePassword(ctx context.Context, userID uint64, expectedOldHash, newHash string, now time.Time) error
	BootstrapPlatformAdmin(ctx context.Context, admin *User, now time.Time) (bool, error)
	ListPermissionCodes(ctx context.Context, groupID, userID uint64) ([]string, error)
}

type gormRepository struct {
	db *gorm.DB
}

func NewRepository(db *gorm.DB) Repository {
	return &gormRepository{db: db}
}

func (r *gormRepository) FindUserByUsername(ctx context.Context, username string) (*User, error) {
	var user User
	err := r.db.WithContext(ctx).Where("username = ?", username).First(&user).Error
	if errors.Is(err, gorm.ErrRecordNotFound) {
		return nil, ErrUserNotFound
	}
	if err != nil {
		return nil, fmt.Errorf("find user by username: %w", err)
	}
	return &user, nil
}

func (r *gormRepository) FindUserByID(ctx context.Context, userID uint64) (*User, error) {
	var user User
	err := r.db.WithContext(ctx).First(&user, userID).Error
	if errors.Is(err, gorm.ErrRecordNotFound) {
		return nil, ErrUserNotFound
	}
	if err != nil {
		return nil, fmt.Errorf("find user by id: %w", err)
	}
	return &user, nil
}

func (r *gormRepository) GetAccessState(ctx context.Context, userID uint64) (AccessState, error) {
	return loadAccessState(r.db.WithContext(ctx), userID)
}

func (r *gormRepository) CreateRefreshSession(ctx context.Context, session *RefreshSession) error {
	if err := r.db.WithContext(ctx).Create(session).Error; err != nil {
		if errors.Is(err, gorm.ErrDuplicatedKey) {
			return ErrRefreshInvalid
		}
		return fmt.Errorf("create refresh session: %w", err)
	}
	return nil
}

func (r *gormRepository) RotateRefreshSession(ctx context.Context, oldTokenHash string, replacement *RefreshSession, now time.Time) (*RefreshSession, AccessState, error) {
	var created RefreshSession
	var state AccessState
	err := r.db.WithContext(ctx).Transaction(func(tx *gorm.DB) error {
		tx = tx.WithContext(ctx)
		var old RefreshSession
		err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).Where("token_hash = ?", oldTokenHash).First(&old).Error
		if errors.Is(err, gorm.ErrRecordNotFound) {
			return ErrRefreshInvalid
		}
		if err != nil {
			return fmt.Errorf("lock refresh session: %w", err)
		}
		if old.RevokedAt != nil || old.ReplacedBySessionID != nil || !old.ExpiresAt.After(now) {
			return ErrRefreshInvalid
		}

		state, err = loadAccessState(tx, old.UserID)
		if errors.Is(err, ErrUserNotFound) {
			return ErrAccessInactive
		}
		if err != nil {
			return err
		}
		if !sameOptionalID(old.GroupID, state.GroupID) {
			return ErrAccessInactive
		}

		created = *replacement
		created.ID = 0
		created.UserID = old.UserID
		created.GroupID = cloneOptionalID(old.GroupID)
		created.RevokedAt = nil
		created.ReplacedBySessionID = nil
		created.LastUsedAt = nil
		if created.CreatedAt.IsZero() {
			created.CreatedAt = now
		}
		if err := tx.Create(&created).Error; err != nil {
			if errors.Is(err, gorm.ErrDuplicatedKey) {
				return ErrRefreshInvalid
			}
			return fmt.Errorf("create replacement refresh session: %w", err)
		}

		result := tx.Model(&RefreshSession{}).
			Where("id = ? AND revoked_at IS NULL AND replaced_by_session_id IS NULL", old.ID).
			Updates(map[string]any{
				"revoked_at":             now,
				"replaced_by_session_id": created.ID,
				"last_used_at":           now,
			})
		if result.Error != nil {
			return fmt.Errorf("revoke rotated refresh session: %w", result.Error)
		}
		if result.RowsAffected != 1 {
			return ErrRefreshInvalid
		}
		if err := appendAudit(tx, old.GroupID, old.UserID, "identity.session.refreshed", "refresh_session", strconv.FormatUint(created.ID, 10), "用户会话已轮换", now); err != nil {
			return err
		}
		return nil
	})
	if err != nil {
		return nil, AccessState{}, err
	}
	return &created, state, nil
}

func (r *gormRepository) RevokeRefreshSession(ctx context.Context, userID, sessionID uint64, now time.Time) error {
	return r.db.WithContext(ctx).Transaction(func(tx *gorm.DB) error {
		tx = tx.WithContext(ctx)
		result := tx.Model(&RefreshSession{}).
			Where("id = ? AND user_id = ? AND revoked_at IS NULL", sessionID, userID).
			Updates(map[string]any{"revoked_at": now, "last_used_at": now})
		if result.Error != nil {
			return fmt.Errorf("revoke refresh session: %w", result.Error)
		}
		if result.RowsAffected != 1 {
			return ErrRefreshInvalid
		}
		groupID, err := optionalGroupID(tx, userID)
		if err != nil {
			return err
		}
		return appendAudit(tx, groupID, userID, "identity.session.logged_out", "refresh_session", strconv.FormatUint(sessionID, 10), "用户已退出当前会话", now)
	})
}

func (r *gormRepository) RevokeRefreshToken(ctx context.Context, tokenHash string, now time.Time) error {
	return r.db.WithContext(ctx).Transaction(func(tx *gorm.DB) error {
		tx = tx.WithContext(ctx)
		var session RefreshSession
		err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).Where("token_hash = ?", tokenHash).Take(&session).Error
		if errors.Is(err, gorm.ErrRecordNotFound) {
			return ErrRefreshInvalid
		}
		if err != nil {
			return fmt.Errorf("lock refresh session for logout: %w", err)
		}
		if session.RevokedAt != nil {
			return ErrRefreshInvalid
		}
		update := tx.Model(&RefreshSession{}).Where("id = ? AND revoked_at IS NULL", session.ID).
			Updates(map[string]any{"revoked_at": now, "last_used_at": now})
		if update.Error != nil {
			return fmt.Errorf("revoke refresh token session: %w", update.Error)
		}
		if update.RowsAffected != 1 {
			return ErrRefreshInvalid
		}
		return appendAudit(tx, session.GroupID, session.UserID, "identity.session.logged_out", "refresh_session", strconv.FormatUint(session.ID, 10), "用户已退出当前会话", now)
	})
}

func (r *gormRepository) ChangePassword(ctx context.Context, userID uint64, expectedOldHash, newHash string, now time.Time) error {
	return r.db.WithContext(ctx).Transaction(func(tx *gorm.DB) error {
		tx = tx.WithContext(ctx)
		result := tx.Model(&User{}).
			Where("id = ? AND password_hash = ?", userID, expectedOldHash).
			Updates(map[string]any{
				"password_hash":        newHash,
				"must_change_password": false,
				"updated_at":           now,
			})
		if result.Error != nil {
			return fmt.Errorf("update password: %w", result.Error)
		}
		if result.RowsAffected != 1 {
			return ErrPasswordHashMismatch
		}

		groupID, err := optionalGroupID(tx, userID)
		if err != nil {
			return err
		}
		if err := appendAudit(tx, groupID, userID, "identity.password.changed", "user", strconv.FormatUint(userID, 10), "用户已修改密码", now); err != nil {
			return err
		}
		return nil
	})
}

func (r *gormRepository) BootstrapPlatformAdmin(ctx context.Context, admin *User, now time.Time) (bool, error) {
	input := *admin
	var (
		candidate User
		created   bool
		err       error
	)
	for attempt := 0; attempt < bootstrapDeadlockAttempts; attempt++ {
		candidate = input
		created = false
		err = r.bootstrapPlatformAdminTransaction(ctx, &candidate, now, &created)
		if !isMySQLDeadlock(err) {
			break
		}
	}
	if err != nil {
		return false, err
	}
	if created {
		*admin = candidate
	}
	return created, nil
}

func (r *gormRepository) bootstrapPlatformAdminTransaction(ctx context.Context, candidate *User, now time.Time, created *bool) error {
	return r.db.WithContext(ctx).Transaction(func(tx *gorm.DB) error {
		tx = tx.WithContext(ctx)
		var existing User
		err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).Where("account_type = ?", AccountTypePlatformAdmin).First(&existing).Error
		if err == nil {
			return nil
		}
		if !errors.Is(err, gorm.ErrRecordNotFound) {
			return fmt.Errorf("find platform admin: %w", err)
		}

		candidate.AccountType = AccountTypePlatformAdmin
		if candidate.Status == "" {
			candidate.Status = UserStatusActive
		}
		if candidate.CreatedAt.IsZero() {
			candidate.CreatedAt = now
		}
		candidate.UpdatedAt = now
		if err := tx.Create(candidate).Error; err != nil {
			if errors.Is(err, gorm.ErrDuplicatedKey) {
				var winner User
				lookupErr := tx.Where("account_type = ?", AccountTypePlatformAdmin).First(&winner).Error
				if lookupErr == nil {
					return nil
				}
				if errors.Is(lookupErr, gorm.ErrRecordNotFound) {
					return ErrUsernameConflict
				}
				return fmt.Errorf("verify platform admin after unique conflict: %w", lookupErr)
			}
			return fmt.Errorf("create platform admin: %w", err)
		}
		if err := appendAudit(tx, nil, candidate.ID, "platform.admin.bootstrapped", "user", strconv.FormatUint(candidate.ID, 10), "平台管理员已初始化", now); err != nil {
			return err
		}
		*created = true
		return nil
	})
}

// ListPermissionCodes 查询成员在指定组内被显式授予的权限码，按字典序返回，保证同一份数据每次下发顺序稳定。
// 只在「成员账号 + 有效成员关系 + 有效组」的前提下返回；平台管理员与主账号不依赖该表，
// 因此上层对这两类角色直接返回空数组，不会调用本方法。
func (r *gormRepository) ListPermissionCodes(ctx context.Context, groupID, userID uint64) ([]string, error) {
	codes := make([]string, 0)
	err := r.db.WithContext(ctx).
		Table("membership_permissions AS permission").
		Joins("JOIN memberships AS membership ON membership.id = permission.membership_id AND membership.group_id = permission.group_id").
		Where("membership.user_id = ? AND membership.group_id = ? AND membership.status = ?", userID, groupID, "active").
		Order("permission.permission_code ASC").
		Pluck("permission.permission_code", &codes).Error
	if err != nil {
		return nil, fmt.Errorf("list membership permission codes: %w", err)
	}
	return codes, nil
}

func isMySQLDeadlock(err error) bool {
	var mysqlErr *mysqldriver.MySQLError
	return errors.As(err, &mysqlErr) && mysqlErr.Number == 1213
}

func loadAccessState(db *gorm.DB, userID uint64) (AccessState, error) {
	var user User
	err := db.First(&user, userID).Error
	if errors.Is(err, gorm.ErrRecordNotFound) {
		return AccessState{}, ErrUserNotFound
	}
	if err != nil {
		return AccessState{}, fmt.Errorf("load access user: %w", err)
	}
	state := AccessState{
		UserID: user.ID, AccountType: user.AccountType, MustChangePassword: user.MustChangePassword,
		UserStatus: user.Status,
	}
	if user.Status != UserStatusActive {
		return AccessState{}, ErrAccessInactive
	}
	if user.AccountType == AccountTypePlatformAdmin {
		return state, nil
	}

	var membership struct {
		GroupID    uint64
		MemberType string
		Status     string
	}
	err = db.Table("memberships").Select("group_id, member_type, status").Where("user_id = ?", user.ID).First(&membership).Error
	if errors.Is(err, gorm.ErrRecordNotFound) {
		return AccessState{}, ErrAccessInactive
	}
	if err != nil {
		return AccessState{}, fmt.Errorf("load access membership: %w", err)
	}
	if membership.Status != "active" {
		return AccessState{}, ErrAccessInactive
	}
	if user.AccountType == AccountTypeGroupOwner && membership.MemberType != "owner" {
		return AccessState{}, ErrAccessInactive
	}
	if user.AccountType == AccountTypeMember && membership.MemberType != "member" {
		return AccessState{}, ErrAccessInactive
	}
	var group struct {
		ID          uint64
		Name        string
		Status      string
		OwnerUserID uint64
	}
	// 注意：groups 虽然是 MySQL 8.0 的保留字，但这里 Table() 传的是不含空格的纯表名，
	// GORM 会走标识符引用路径自动加反引号，并正确设置 Statement.Table（First 的 ORDER BY 才拼得对）。
	// 千万不要在这里手写反引号：那会让 GORM 走原样 SQL 分支、Statement.Table 落空，
	// 最终生成 `ORDER BY `.`id`` 这种语法错误。保持原样即可。
	err = db.Table("groups").Select("id, name, status, owner_user_id").Where("id = ?", membership.GroupID).First(&group).Error
	if errors.Is(err, gorm.ErrRecordNotFound) {
		return AccessState{}, ErrAccessInactive
	}
	if err != nil {
		return AccessState{}, fmt.Errorf("load access group: %w", err)
	}
	if group.Status != "active" {
		return AccessState{}, ErrAccessInactive
	}
	if membership.MemberType == "owner" && group.OwnerUserID != user.ID {
		return AccessState{}, ErrAccessInactive
	}
	state.GroupID = &group.ID
	state.GroupName = group.Name
	state.MemberType = membership.MemberType
	state.MembershipStatus = membership.Status
	state.GroupStatus = group.Status
	return state, nil
}

func optionalGroupID(db *gorm.DB, userID uint64) (*uint64, error) {
	var membership struct{ GroupID uint64 }
	err := db.Table("memberships").Select("group_id").Where("user_id = ? AND status = ?", userID, "active").First(&membership).Error
	if errors.Is(err, gorm.ErrRecordNotFound) {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("load audit group: %w", err)
	}
	return &membership.GroupID, nil
}

func appendAudit(db *gorm.DB, groupID *uint64, operatorUserID uint64, action, resourceType, resourceID, summary string, now time.Time) error {
	err := db.Table("audit_logs").Create(map[string]any{
		"group_id": groupID, "operator_user_id": operatorUserID, "action": action,
		"resource_type": resourceType, "resource_id": resourceID, "summary": summary, "created_at": now,
	}).Error
	if err != nil {
		return fmt.Errorf("append identity audit: %w", err)
	}
	return nil
}

func sameOptionalID(left, right *uint64) bool {
	if left == nil || right == nil {
		return left == nil && right == nil
	}
	return *left == *right
}

func cloneOptionalID(value *uint64) *uint64 {
	if value == nil {
		return nil
	}
	copyValue := *value
	return &copyValue
}
