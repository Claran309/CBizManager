package identity

import (
	"context"
	"errors"
	"fmt"
	"reflect"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/glebarez/sqlite"
	mysqldriver "github.com/go-sql-driver/mysql"
	"gorm.io/gorm"
	"gorm.io/gorm/logger"
)

func TestRepositoryFindsUsersAndAccessState(t *testing.T) {
	db := openIdentityTestDB(t)
	repo := NewRepository(db)
	owner, group, _ := seedIdentityGroupUser(t, db, "owner-find", AccountTypeGroupOwner)

	byUsername, err := repo.FindUserByUsername(context.Background(), owner.Username)
	if err != nil {
		t.Fatalf("FindUserByUsername() error = %v", err)
	}
	if byUsername.ID != owner.ID {
		t.Fatalf("FindUserByUsername() ID = %d, want %d", byUsername.ID, owner.ID)
	}
	byID, err := repo.FindUserByID(context.Background(), owner.ID)
	if err != nil {
		t.Fatalf("FindUserByID() error = %v", err)
	}
	if byID.Username != owner.Username {
		t.Fatalf("FindUserByID() username = %q, want %q", byID.Username, owner.Username)
	}

	state, err := repo.GetAccessState(context.Background(), owner.ID)
	if err != nil {
		t.Fatalf("GetAccessState() error = %v", err)
	}
	if state.GroupID == nil || *state.GroupID != group.ID || state.GroupName != group.Name || state.MemberType != "owner" {
		t.Fatalf("GetAccessState() = %+v, want group %d owner", state, group.ID)
	}

	_, err = repo.FindUserByUsername(context.Background(), "missing")
	if !errors.Is(err, ErrUserNotFound) {
		t.Fatalf("FindUserByUsername(missing) error = %v, want ErrUserNotFound", err)
	}
}

func TestRepositoryRejectsAccessStateWithInconsistentRoleRelationships(t *testing.T) {
	tests := []struct {
		name       string
		account    AccountType
		memberType string
		wrongOwner bool
	}{
		{name: "group owner with member membership", account: AccountTypeGroupOwner, memberType: "member"},
		{name: "member with owner membership", account: AccountTypeMember, memberType: "owner"},
		{name: "owner membership not matching group owner", account: AccountTypeGroupOwner, memberType: "owner", wrongOwner: true},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			db := openIdentityTestDB(t)
			repo := NewRepository(db)
			user, group, membership := seedIdentityGroupUser(t, db, "invalid-access-"+strings.ReplaceAll(tt.name, " ", "-"), tt.account)
			if err := db.Model(&membership).Update("member_type", tt.memberType).Error; err != nil {
				t.Fatalf("change membership type: %v", err)
			}
			if tt.wrongOwner {
				other := User{Username: user.Username + "-other", PasswordHash: "hash", DisplayName: "Other", AccountType: AccountTypeGroupOwner, Status: UserStatusActive}
				if err := db.Create(&other).Error; err != nil {
					t.Fatalf("seed other owner: %v", err)
				}
				if err := db.Model(&group).Update("owner_user_id", other.ID).Error; err != nil {
					t.Fatalf("change group owner: %v", err)
				}
			}

			_, err := repo.GetAccessState(context.Background(), user.ID)
			if !errors.Is(err, ErrAccessInactive) {
				t.Fatalf("GetAccessState() error = %v, want ErrAccessInactive", err)
			}
		})
	}
}

func TestRepositoryRotatesRefreshSessionOnceAndReturnsAccessState(t *testing.T) {
	db := openIdentityTestDB(t)
	repo := NewRepository(db)
	user, group, _ := seedIdentityGroupUser(t, db, "member-refresh", AccountTypeMember)
	now := time.Date(2026, 7, 24, 8, 0, 0, 0, time.UTC)
	oldSession := &RefreshSession{
		UserID: user.ID, GroupID: &group.ID, TokenHash: "old-token-hash",
		ExpiresAt: now.Add(time.Hour), CreatedAt: now.Add(-time.Minute),
	}
	if err := repo.CreateRefreshSession(context.Background(), oldSession); err != nil {
		t.Fatalf("CreateRefreshSession() error = %v", err)
	}

	replacement := &RefreshSession{TokenHash: "new-token-hash", ExpiresAt: now.Add(2 * time.Hour), CreatedAt: now}
	created, state, err := repo.RotateRefreshSession(context.Background(), oldSession.TokenHash, replacement, now)
	if err != nil {
		t.Fatalf("RotateRefreshSession() error = %v", err)
	}
	if created.ID == 0 || created.UserID != user.ID || created.GroupID == nil || *created.GroupID != group.ID {
		t.Fatalf("created replacement = %+v, want persisted user/group session", created)
	}
	if state.UserID != user.ID || state.GroupID == nil || *state.GroupID != group.ID || state.AccountType != AccountTypeMember {
		t.Fatalf("access state = %+v, want current member state", state)
	}

	_, _, err = repo.RotateRefreshSession(context.Background(), oldSession.TokenHash, &RefreshSession{
		TokenHash: "replay-created-token", ExpiresAt: now.Add(3 * time.Hour), CreatedAt: now,
	}, now.Add(time.Second))
	if !errors.Is(err, ErrRefreshInvalid) {
		t.Fatalf("second RotateRefreshSession() error = %v, want ErrRefreshInvalid", err)
	}
	var sessionCount int64
	if err := db.Model(&RefreshSession{}).Count(&sessionCount).Error; err != nil {
		t.Fatalf("count refresh sessions: %v", err)
	}
	if sessionCount != 2 {
		t.Fatalf("refresh session count = %d, want 2", sessionCount)
	}

	var persistedOld RefreshSession
	if err := db.First(&persistedOld, oldSession.ID).Error; err != nil {
		t.Fatalf("load old refresh session: %v", err)
	}
	if persistedOld.RevokedAt == nil || persistedOld.ReplacedBySessionID == nil || *persistedOld.ReplacedBySessionID != created.ID || persistedOld.LastUsedAt == nil {
		t.Fatalf("old refresh session not fully rotated: %+v", persistedOld)
	}
	var refreshAudit auditLogTest
	if err := db.Where("action = ?", "identity.session.refreshed").First(&refreshAudit).Error; err != nil {
		t.Fatalf("load refresh audit: %v", err)
	}
	if strings.Contains(refreshAudit.Summary, oldSession.TokenHash) || strings.Contains(refreshAudit.Summary, replacement.TokenHash) {
		t.Fatalf("refresh audit leaked token hash: %q", refreshAudit.Summary)
	}
}

func TestRepositoryRejectsRefreshRotationWhenAccessIsInactive(t *testing.T) {
	db := openIdentityTestDB(t)
	repo := NewRepository(db)
	user, group, _ := seedIdentityGroupUser(t, db, "inactive-refresh", AccountTypeMember)
	now := time.Date(2026, 7, 24, 9, 0, 0, 0, time.UTC)
	oldSession := &RefreshSession{UserID: user.ID, GroupID: &group.ID, TokenHash: "inactive-old", ExpiresAt: now.Add(time.Hour), CreatedAt: now}
	if err := repo.CreateRefreshSession(context.Background(), oldSession); err != nil {
		t.Fatalf("CreateRefreshSession() error = %v", err)
	}
	if err := db.Model(&identityGroupTest{}).Where("id = ?", group.ID).Update("status", "disabled").Error; err != nil {
		t.Fatalf("disable group: %v", err)
	}

	_, _, err := repo.RotateRefreshSession(context.Background(), oldSession.TokenHash, &RefreshSession{
		TokenHash: "must-not-exist", ExpiresAt: now.Add(2 * time.Hour), CreatedAt: now,
	}, now)
	if !errors.Is(err, ErrAccessInactive) {
		t.Fatalf("RotateRefreshSession() error = %v, want ErrAccessInactive", err)
	}
	var count int64
	if err := db.Model(&RefreshSession{}).Count(&count).Error; err != nil {
		t.Fatalf("count refresh sessions: %v", err)
	}
	if count != 1 {
		t.Fatalf("refresh session count = %d, want 1 after rejected rotation", count)
	}
}

func TestRepositoryRevokesOnlyOwnedRefreshSession(t *testing.T) {
	db := openIdentityTestDB(t)
	repo := NewRepository(db)
	user, group, _ := seedIdentityGroupUser(t, db, "member-revoke", AccountTypeMember)
	now := time.Date(2026, 7, 24, 10, 0, 0, 0, time.UTC)
	session := &RefreshSession{UserID: user.ID, GroupID: &group.ID, TokenHash: "revoke-token", ExpiresAt: now.Add(time.Hour), CreatedAt: now}
	if err := repo.CreateRefreshSession(context.Background(), session); err != nil {
		t.Fatalf("CreateRefreshSession() error = %v", err)
	}

	if err := repo.RevokeRefreshSession(context.Background(), user.ID+1, session.ID, now); !errors.Is(err, ErrRefreshInvalid) {
		t.Fatalf("RevokeRefreshSession(other user) error = %v, want ErrRefreshInvalid", err)
	}
	if err := repo.RevokeRefreshSession(context.Background(), user.ID, session.ID, now); err != nil {
		t.Fatalf("RevokeRefreshSession() error = %v", err)
	}
	var logoutAudit auditLogTest
	if err := db.Where("action = ?", "identity.session.logged_out").First(&logoutAudit).Error; err != nil {
		t.Fatalf("load logout audit: %v", err)
	}
	if strings.Contains(logoutAudit.Summary, session.TokenHash) {
		t.Fatalf("logout audit leaked token hash: %q", logoutAudit.Summary)
	}
}

func TestRepositoryChangesPasswordConditionallyAndAuditsWithoutHashes(t *testing.T) {
	db := openIdentityTestDB(t)
	repo := NewRepository(db)
	user := User{Username: "change-password", PasswordHash: "old-secret-hash", DisplayName: "Change", AccountType: AccountTypePlatformAdmin, Status: UserStatusActive, MustChangePassword: true}
	if err := db.Create(&user).Error; err != nil {
		t.Fatalf("seed user: %v", err)
	}
	now := time.Date(2026, 7, 24, 11, 0, 0, 0, time.UTC)

	if err := repo.ChangePassword(context.Background(), user.ID, "stale-hash", "new-secret-hash", now); !errors.Is(err, ErrPasswordHashMismatch) {
		t.Fatalf("ChangePassword(stale) error = %v, want ErrPasswordHashMismatch", err)
	}
	if err := repo.ChangePassword(context.Background(), user.ID, user.PasswordHash, "new-secret-hash", now); err != nil {
		t.Fatalf("ChangePassword() error = %v", err)
	}

	var got User
	if err := db.First(&got, user.ID).Error; err != nil {
		t.Fatalf("load changed user: %v", err)
	}
	if got.PasswordHash != "new-secret-hash" || got.MustChangePassword {
		t.Fatalf("changed user = %+v, want new hash and must_change_password=false", got)
	}
	var audit auditLogTest
	if err := db.Where("action = ?", "identity.password.changed").First(&audit).Error; err != nil {
		t.Fatalf("load password audit: %v", err)
	}
	if strings.Contains(audit.Summary, "old-secret-hash") || strings.Contains(audit.Summary, "new-secret-hash") {
		t.Fatalf("password audit leaked hash: %q", audit.Summary)
	}
}

func TestRepositoryBootstrapsPlatformAdminIdempotently(t *testing.T) {
	db := openIdentityTestDB(t)
	repo := NewRepository(db)
	now := time.Date(2026, 7, 24, 12, 0, 0, 0, time.UTC)
	admin := &User{Username: "admin", PasswordHash: "initial-hash", DisplayName: "Admin", AccountType: AccountTypePlatformAdmin, Status: UserStatusActive, MustChangePassword: true}

	created, err := repo.BootstrapPlatformAdmin(context.Background(), admin, now)
	if err != nil || !created {
		t.Fatalf("BootstrapPlatformAdmin(first) = (%v, %v), want (true, nil)", created, err)
	}
	second := &User{Username: "replacement", PasswordHash: "must-not-overwrite", DisplayName: "Replacement", AccountType: AccountTypePlatformAdmin, Status: UserStatusActive}
	created, err = repo.BootstrapPlatformAdmin(context.Background(), second, now.Add(time.Minute))
	if err != nil || created {
		t.Fatalf("BootstrapPlatformAdmin(second) = (%v, %v), want (false, nil)", created, err)
	}

	var got User
	if err := db.Where("account_type = ?", AccountTypePlatformAdmin).First(&got).Error; err != nil {
		t.Fatalf("load platform admin: %v", err)
	}
	if got.PasswordHash != "initial-hash" || got.Username != "admin" {
		t.Fatalf("existing platform admin overwritten: %+v", got)
	}
	var audits int64
	if err := db.Model(&auditLogTest{}).Where("action = ?", "platform.admin.bootstrapped").Count(&audits).Error; err != nil {
		t.Fatalf("count bootstrap audits: %v", err)
	}
	if audits != 1 {
		t.Fatalf("bootstrap audit count = %d, want 1", audits)
	}
}

func TestRepositoryTreatsConcurrentPlatformAdminUniqueConflictAsIdempotent(t *testing.T) {
	db := openIdentityTestDB(t)
	repo := NewRepository(db)
	now := time.Date(2026, 7, 24, 12, 30, 0, 0, time.UTC)
	var insertCompetitor sync.Once
	if err := db.Callback().Create().Before("gorm:create").Register("test:concurrent-platform-admin", func(tx *gorm.DB) {
		candidate, ok := tx.Statement.Dest.(*User)
		if !ok || candidate.Username != "candidate-admin" {
			return
		}
		insertCompetitor.Do(func() {
			tx.Statement.AddError(tx.Session(&gorm.Session{NewDB: true}).Exec(`
				INSERT INTO users(username, password_hash, display_name, account_type, status, must_change_password, created_at, updated_at)
				VALUES (?, ?, ?, ?, ?, ?, ?, ?)
			`, "winner-admin", "winner-hash", "Winner", AccountTypePlatformAdmin, UserStatusActive, false, now, now).Error)
		})
	}); err != nil {
		t.Fatalf("register concurrent insert callback: %v", err)
	}
	t.Cleanup(func() { db.Callback().Create().Remove("test:concurrent-platform-admin") })

	candidate := &User{Username: "candidate-admin", PasswordHash: "candidate-hash", DisplayName: "Candidate", MustChangePassword: true}
	created, err := repo.BootstrapPlatformAdmin(context.Background(), candidate, now)
	if err != nil || created {
		t.Fatalf("BootstrapPlatformAdmin() = (%v, %v), want (false, nil)", created, err)
	}
	var winner User
	if err := db.Where("account_type = ?", AccountTypePlatformAdmin).First(&winner).Error; err != nil {
		t.Fatalf("load winning platform admin: %v", err)
	}
	if winner.Username != "winner-admin" {
		t.Fatalf("winning platform admin = %q, want winner-admin", winner.Username)
	}
}

func TestRepositoryBootstrapFailureDoesNotMutateCaller(t *testing.T) {
	db := openIdentityTestDB(t)
	repo := NewRepository(db)
	existing := User{Username: "occupied", PasswordHash: "member-hash", DisplayName: "Member", AccountType: AccountTypeMember, Status: UserStatusActive}
	if err := db.Create(&existing).Error; err != nil {
		t.Fatalf("seed occupied username: %v", err)
	}

	candidate := &User{Username: "occupied", PasswordHash: "admin-hash", DisplayName: "Admin"}
	want := *candidate
	created, err := repo.BootstrapPlatformAdmin(context.Background(), candidate, time.Date(2026, 7, 24, 12, 45, 0, 0, time.UTC))
	if created || !errors.Is(err, ErrUsernameConflict) {
		t.Fatalf("BootstrapPlatformAdmin() = (%v, %v), want (false, ErrUsernameConflict)", created, err)
	}
	if !reflect.DeepEqual(*candidate, want) {
		t.Fatalf("caller candidate mutated after failure: got %+v, want %+v", *candidate, want)
	}
}

func TestRepositoryBootstrapReturnsLastErrorAfterDeadlockRetriesExhausted(t *testing.T) {
	db := openIdentityTestDB(t)
	repo := NewRepository(db)
	var attempts atomic.Int32
	if err := db.Callback().Create().Before("gorm:create").Register("test:bootstrap-deadlock", func(tx *gorm.DB) {
		candidate, ok := tx.Statement.Dest.(*User)
		if !ok || candidate.Username != "deadlock-admin" {
			return
		}
		attempts.Add(1)
		tx.AddError(&mysqldriver.MySQLError{Number: 1213, Message: "test deadlock"})
	}); err != nil {
		t.Fatalf("register bootstrap deadlock callback: %v", err)
	}
	t.Cleanup(func() { db.Callback().Create().Remove("test:bootstrap-deadlock") })

	candidate := &User{Username: "deadlock-admin", PasswordHash: "hash", DisplayName: "Admin"}
	want := *candidate
	created, err := repo.BootstrapPlatformAdmin(context.Background(), candidate, time.Date(2026, 7, 24, 12, 47, 0, 0, time.UTC))
	var mysqlErr *mysqldriver.MySQLError
	if created || !errors.As(err, &mysqlErr) || mysqlErr.Number != 1213 {
		t.Fatalf("BootstrapPlatformAdmin() = (%v, %v), want (false, MySQL 1213)", created, err)
	}
	if attempts.Load() != bootstrapDeadlockAttempts {
		t.Fatalf("bootstrap deadlock attempts = %d, want %d", attempts.Load(), bootstrapDeadlockAttempts)
	}
	if !reflect.DeepEqual(*candidate, want) {
		t.Fatalf("caller candidate mutated after exhausted retries: got %+v, want %+v", *candidate, want)
	}
}

func TestRepositoryBootstrapCommitFailureReturnsNotCreated(t *testing.T) {
	db := openIdentityTestDB(t)
	repo := NewRepository(db)
	if err := db.Exec(`PRAGMA foreign_keys = ON`).Error; err != nil {
		t.Fatalf("enable foreign keys: %v", err)
	}
	if err := db.Exec(`
		CREATE TABLE bootstrap_commit_guards (
			user_id INTEGER NOT NULL,
			FOREIGN KEY(user_id) REFERENCES users(id) DEFERRABLE INITIALLY DEFERRED
		)
	`).Error; err != nil {
		t.Fatalf("create deferred commit guard: %v", err)
	}
	if err := db.Exec(`
		CREATE TRIGGER fail_bootstrap_commit
		AFTER INSERT ON audit_logs
		WHEN NEW.action = 'platform.admin.bootstrapped'
		BEGIN
			INSERT INTO bootstrap_commit_guards(user_id) VALUES (-1);
		END
	`).Error; err != nil {
		t.Fatalf("create commit failure trigger: %v", err)
	}

	admin := &User{Username: "commit-failure-admin", PasswordHash: "hash", DisplayName: "Admin"}
	created, err := repo.BootstrapPlatformAdmin(context.Background(), admin, time.Date(2026, 7, 24, 12, 50, 0, 0, time.UTC))
	if err == nil || created {
		t.Fatalf("BootstrapPlatformAdmin() = (%v, %v), want (false, commit error)", created, err)
	}
}

func openIdentityTestDB(t *testing.T) *gorm.DB {
	t.Helper()
	dsn := fmt.Sprintf("file:%s?mode=memory&cache=shared&_foreign_keys=on", strings.ReplaceAll(t.Name(), "/", "_"))
	db, err := gorm.Open(sqlite.Open(dsn), &gorm.Config{TranslateError: true, Logger: logger.Default.LogMode(logger.Silent)})
	if err != nil {
		t.Fatalf("open SQLite: %v", err)
	}
	sqlDB, err := db.DB()
	if err != nil {
		t.Fatalf("access sql.DB: %v", err)
	}
	sqlDB.SetMaxOpenConns(1)
	t.Cleanup(func() { _ = sqlDB.Close() })
	if err := db.AutoMigrate(&User{}, &identityGroupTest{}, &identityMembershipTest{}, &RefreshSession{}, &auditLogTest{}); err != nil {
		t.Fatalf("AutoMigrate test schema: %v", err)
	}
	if err := db.Exec(`CREATE UNIQUE INDEX uk_users_platform_admin_guard ON users(account_type) WHERE account_type = 'platform_admin'`).Error; err != nil {
		t.Fatalf("create platform admin guard index: %v", err)
	}
	return db
}

func seedIdentityGroupUser(t *testing.T, db *gorm.DB, username string, accountType AccountType) (User, identityGroupTest, identityMembershipTest) {
	t.Helper()
	operator := User{Username: username + "-operator", PasswordHash: "hash", DisplayName: "Operator", AccountType: AccountTypePlatformAdmin, Status: UserStatusActive}
	if err := db.Create(&operator).Error; err != nil {
		t.Fatalf("seed operator: %v", err)
	}
	user := User{Username: username, PasswordHash: "hash", DisplayName: username, AccountType: accountType, Status: UserStatusActive}
	if err := db.Create(&user).Error; err != nil {
		t.Fatalf("seed user: %v", err)
	}
	group := identityGroupTest{Name: username + "-group", Status: "active", OwnerUserID: user.ID, CreatedBy: operator.ID}
	if err := db.Create(&group).Error; err != nil {
		t.Fatalf("seed group: %v", err)
	}
	memberType := "member"
	if accountType == AccountTypeGroupOwner {
		memberType = "owner"
	}
	membership := identityMembershipTest{GroupID: group.ID, UserID: user.ID, MemberType: memberType, Status: "active"}
	if err := db.Create(&membership).Error; err != nil {
		t.Fatalf("seed membership: %v", err)
	}
	return user, group, membership
}

type auditLogTest struct {
	ID             uint64 `gorm:"primaryKey;autoIncrement"`
	GroupID        *uint64
	OperatorUserID uint64
	Action         string
	ResourceType   string
	ResourceID     string
	Summary        string
	CreatedAt      time.Time
}

func (auditLogTest) TableName() string { return "audit_logs" }

type identityGroupTest struct {
	ID          uint64 `gorm:"primaryKey;autoIncrement"`
	Name        string
	Status      string
	OwnerUserID uint64
	CreatedBy   uint64
	CreatedAt   time.Time
	UpdatedAt   time.Time
}

func (identityGroupTest) TableName() string { return "groups" }

type identityMembershipTest struct {
	ID         uint64 `gorm:"primaryKey;autoIncrement"`
	GroupID    uint64
	UserID     uint64
	MemberType string
	Status     string
	CreatedAt  time.Time
	UpdatedAt  time.Time
}

func (identityMembershipTest) TableName() string { return "memberships" }
