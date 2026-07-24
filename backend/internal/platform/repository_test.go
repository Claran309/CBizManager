package platform

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/glebarez/sqlite"
	"gorm.io/gorm"
	"gorm.io/gorm/logger"

	"CBizDocsManager/backend/internal/identity"
	"CBizDocsManager/backend/internal/organization"
)

func TestRepositoryCreatesGroupOwnerMembershipAndAuditAtomically(t *testing.T) {
	db := openPlatformTestDB(t, true)
	admin := seedPlatformAdmin(t, db, "platform-admin")
	repo := NewRepository(db)
	now := time.Date(2026, 7, 24, 13, 0, 0, 0, time.UTC)

	created, err := repo.CreateGroupWithOwner(context.Background(), CreateGroupInput{
		OperatorUserID: admin.ID, GroupName: "Finance", OwnerUsername: "finance-owner",
		OwnerPasswordHash: "temporary-hash", OwnerDisplayName: "Finance Owner", Now: now,
	})
	if err != nil {
		t.Fatalf("CreateGroupWithOwner() error = %v", err)
	}
	if created.Owner.ID == 0 || created.Group.ID == 0 || created.Membership.ID == 0 {
		t.Fatalf("CreateGroupWithOwner() returned unpersisted records: %+v", created)
	}
	if created.Group.OwnerUserID != created.Owner.ID || created.Membership.UserID != created.Owner.ID || created.Membership.GroupID != created.Group.ID {
		t.Fatalf("owner/group/membership are inconsistent: %+v", created)
	}
	if !created.Owner.MustChangePassword || created.Owner.AccountType != identity.AccountTypeGroupOwner || created.Membership.MemberType != organization.MemberTypeOwner {
		t.Fatalf("created owner defaults are invalid: %+v", created)
	}
	var audit platformAuditLogTest
	if err := db.Where("action = ?", "platform.group.created").First(&audit).Error; err != nil {
		t.Fatalf("load group audit: %v", err)
	}
	if audit.GroupID == nil || *audit.GroupID != created.Group.ID || audit.OperatorUserID != admin.ID {
		t.Fatalf("group audit = %+v, want group/operator", audit)
	}
}

func TestRepositoryMapsUsernameAndGroupConflictsWithoutHalfProducts(t *testing.T) {
	db := openPlatformTestDB(t, true)
	admin := seedPlatformAdmin(t, db, "conflict-admin")
	existingOwner := identity.User{Username: "existing-owner", PasswordHash: "hash", DisplayName: "Existing", AccountType: identity.AccountTypeGroupOwner, Status: identity.UserStatusActive}
	if err := db.Create(&existingOwner).Error; err != nil {
		t.Fatalf("seed existing owner: %v", err)
	}
	existingGroup := organization.Group{Name: "Existing Group", Status: organization.GroupStatusActive, OwnerUserID: existingOwner.ID, CreatedBy: admin.ID}
	if err := db.Create(&existingGroup).Error; err != nil {
		t.Fatalf("seed existing group: %v", err)
	}
	repo := NewRepository(db)
	now := time.Date(2026, 7, 24, 14, 0, 0, 0, time.UTC)

	_, err := repo.CreateGroupWithOwner(context.Background(), CreateGroupInput{
		OperatorUserID: admin.ID, GroupName: "No Group", OwnerUsername: existingOwner.Username,
		OwnerPasswordHash: "hash", OwnerDisplayName: "Duplicate", Now: now,
	})
	if !errors.Is(err, ErrUsernameConflict) {
		t.Fatalf("username conflict error = %v, want ErrUsernameConflict", err)
	}
	var noGroupCount int64
	if err := db.Model(&organization.Group{}).Where("name = ?", "No Group").Count(&noGroupCount).Error; err != nil {
		t.Fatalf("count rejected group: %v", err)
	}
	if noGroupCount != 0 {
		t.Fatalf("username conflict created %d groups, want 0", noGroupCount)
	}

	_, err = repo.CreateGroupWithOwner(context.Background(), CreateGroupInput{
		OperatorUserID: admin.ID, GroupName: existingGroup.Name, OwnerUsername: "rolled-back-owner",
		OwnerPasswordHash: "hash", OwnerDisplayName: "Rollback", Now: now,
	})
	if !errors.Is(err, ErrGroupNameConflict) {
		t.Fatalf("group conflict error = %v, want ErrGroupNameConflict", err)
	}
	var rolledBackUsers int64
	if err := db.Model(&identity.User{}).Where("username = ?", "rolled-back-owner").Count(&rolledBackUsers).Error; err != nil {
		t.Fatalf("count rolled-back user: %v", err)
	}
	if rolledBackUsers != 0 {
		t.Fatalf("group conflict left %d owner users, want 0", rolledBackUsers)
	}
}

func TestRepositoryRollsBackWhenAuditInsertFails(t *testing.T) {
	db := openPlatformTestDB(t, false)
	admin := seedPlatformAdmin(t, db, "audit-failure-admin")
	repo := NewRepository(db)

	_, err := repo.CreateGroupWithOwner(context.Background(), CreateGroupInput{
		OperatorUserID: admin.ID, GroupName: "Audit Failure", OwnerUsername: "audit-failure-owner",
		OwnerPasswordHash: "hash", OwnerDisplayName: "Failure", Now: time.Now().UTC(),
	})
	if err == nil {
		t.Fatal("CreateGroupWithOwner() error = nil, want missing audit table failure")
	}
	var users, groups, memberships int64
	_ = db.Model(&identity.User{}).Where("username = ?", "audit-failure-owner").Count(&users).Error
	_ = db.Model(&organization.Group{}).Where("name = ?", "Audit Failure").Count(&groups).Error
	_ = db.Model(&organization.Membership{}).Count(&memberships).Error
	if users != 0 || groups != 0 || memberships != 0 {
		t.Fatalf("failed transaction left users=%d groups=%d memberships=%d", users, groups, memberships)
	}
}

func openPlatformTestDB(t *testing.T, withAudit bool) *gorm.DB {
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
	models := []any{&identity.User{}, &organization.Group{}, &organization.Membership{}}
	if withAudit {
		models = append(models, &platformAuditLogTest{})
	}
	if err := db.AutoMigrate(models...); err != nil {
		t.Fatalf("AutoMigrate test schema: %v", err)
	}
	return db
}

func seedPlatformAdmin(t *testing.T, db *gorm.DB, username string) identity.User {
	t.Helper()
	admin := identity.User{Username: username, PasswordHash: "hash", DisplayName: "Admin", AccountType: identity.AccountTypePlatformAdmin, Status: identity.UserStatusActive}
	if err := db.Create(&admin).Error; err != nil {
		t.Fatalf("seed platform admin: %v", err)
	}
	return admin
}

type platformAuditLogTest struct {
	ID             uint64 `gorm:"primaryKey;autoIncrement"`
	GroupID        *uint64
	OperatorUserID uint64
	Action         string
	ResourceType   string
	ResourceID     string
	Summary        string
	CreatedAt      time.Time
}

func (platformAuditLogTest) TableName() string { return "audit_logs" }
