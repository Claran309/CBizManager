package member

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"testing"
	"time"

	"CBizDocsManager/backend/internal/authorization"
	"CBizDocsManager/backend/internal/identity"
	"CBizDocsManager/backend/internal/organization"
	"github.com/glebarez/sqlite"
	"gorm.io/gorm"
	"gorm.io/gorm/logger"
)

type memberAuditLogTest struct {
	ID             uint64 `gorm:"primaryKey;autoIncrement"`
	GroupID        *uint64
	OperatorUserID uint64
	Action         string
	ResourceType   string
	ResourceID     string
	Summary        string
	CreatedAt      time.Time
}

func (memberAuditLogTest) TableName() string { return "audit_logs" }

func openMemberTestDB(t *testing.T, withAudit bool) *gorm.DB {
	t.Helper()
	dsn := fmt.Sprintf("file:%s?mode=memory&cache=shared&_foreign_keys=on", strings.ReplaceAll(t.Name(), "/", "_"))
	db, err := gorm.Open(sqlite.Open(dsn), &gorm.Config{TranslateError: true, Logger: logger.Default.LogMode(logger.Silent)})
	if err != nil {
		t.Fatalf("open sqlite: %v", err)
	}
	sqlDB, err := db.DB()
	if err != nil {
		t.Fatalf("sql db: %v", err)
	}
	sqlDB.SetMaxOpenConns(1)
	t.Cleanup(func() { _ = sqlDB.Close() })
	models := []any{&identity.User{}, &organization.Group{}, &organization.Membership{}, &identity.RefreshSession{}, &permissionRecord{}}
	if withAudit {
		models = append(models, &memberAuditLogTest{})
	}
	if err := db.AutoMigrate(models...); err != nil {
		t.Fatalf("migrate: %v", err)
	}
	return db
}

type memberFixture struct {
	owner            identity.User
	target           identity.User
	group            organization.Group
	ownerMembership  organization.Membership
	targetMembership organization.Membership
}

func seedMemberFixture(t *testing.T, db *gorm.DB) memberFixture {
	t.Helper()
	fixture := memberFixture{
		owner:  identity.User{ID: 10, Username: "owner", PasswordHash: "hash", DisplayName: "Owner", AccountType: identity.AccountTypeGroupOwner, Status: identity.UserStatusActive},
		target: identity.User{ID: 11, Username: "member", PasswordHash: "hash", DisplayName: "Member", AccountType: identity.AccountTypeMember, Status: identity.UserStatusActive},
	}
	for _, user := range []*identity.User{&fixture.owner, &fixture.target} {
		if err := db.Create(user).Error; err != nil {
			t.Fatalf("seed user: %v", err)
		}
	}
	fixture.group = organization.Group{ID: 7, Name: "Finance", Status: organization.GroupStatusActive, OwnerUserID: fixture.owner.ID, CreatedBy: fixture.owner.ID}
	if err := db.Create(&fixture.group).Error; err != nil {
		t.Fatalf("seed group: %v", err)
	}
	fixture.ownerMembership = organization.Membership{ID: 20, GroupID: fixture.group.ID, UserID: fixture.owner.ID, MemberType: organization.MemberTypeOwner, Status: organization.MembershipStatusActive, Version: 1}
	fixture.targetMembership = organization.Membership{ID: 21, GroupID: fixture.group.ID, UserID: fixture.target.ID, MemberType: organization.MemberTypeMember, Status: organization.MembershipStatusActive, Version: 2}
	for _, membership := range []*organization.Membership{&fixture.ownerMembership, &fixture.targetMembership} {
		if err := db.Create(membership).Error; err != nil {
			t.Fatalf("seed membership: %v", err)
		}
	}
	return fixture
}

func TestRepositoryListIsGroupScopedAndIncludesPermissions(t *testing.T) {
	db := openMemberTestDB(t, true)
	fixture := seedMemberFixture(t, db)
	if err := db.Create(&permissionRecord{GroupID: fixture.group.ID, MembershipID: fixture.targetMembership.ID, PermissionCode: authorization.PermissionMemberManage, GrantedBy: fixture.owner.ID}).Error; err != nil {
		t.Fatalf("seed permission: %v", err)
	}
	repo := NewRepository(db)
	page, err := repo.List(context.Background(), fixture.group.ID, ListQuery{Page: 1, PageSize: 20})
	if err != nil {
		t.Fatalf("List() error=%v", err)
	}
	if page.Total != 2 || len(page.Items) != 2 {
		t.Fatalf("page=%+v", page)
	}
	if len(page.Items[0].PermissionCodes) != len(authorization.Catalog()) {
		t.Fatalf("owner implicit permissions=%v", page.Items[0].PermissionCodes)
	}
	if len(page.Items[1].PermissionCodes) != 1 || page.Items[1].PermissionCodes[0] != authorization.PermissionMemberManage {
		t.Fatalf("member permissions=%v", page.Items[1].PermissionCodes)
	}
	other, err := repo.List(context.Background(), 8, ListQuery{Page: 1, PageSize: 20})
	if err != nil || other.Total != 0 {
		t.Fatalf("other group page=%+v error=%v", other, err)
	}
}

func TestRepositoryGetPermissionsReturnsOwnerImplicitCatalog(t *testing.T) {
	db := openMemberTestDB(t, true)
	fixture := seedMemberFixture(t, db)

	result, err := NewRepository(db).GetPermissions(context.Background(), fixture.group.ID, fixture.ownerMembership.ID)
	if err != nil {
		t.Fatalf("GetPermissions() error=%v", err)
	}
	if len(result.PermissionCodes) != len(authorization.Catalog()) || result.Version != fixture.ownerMembership.Version {
		t.Fatalf("owner permissions=%+v", result)
	}
}

func TestRepositoryChangeStatusUpdatesVersionRevokesSessionsAndAudits(t *testing.T) {
	db := openMemberTestDB(t, true)
	fixture := seedMemberFixture(t, db)
	now := time.Date(2026, 7, 24, 16, 0, 0, 0, time.UTC)
	session := identity.RefreshSession{UserID: fixture.target.ID, GroupID: &fixture.group.ID, TokenHash: strings.Repeat("a", 64), ExpiresAt: now.Add(time.Hour), CreatedAt: now.Add(-time.Hour)}
	if err := db.Create(&session).Error; err != nil {
		t.Fatalf("seed session: %v", err)
	}
	result, err := NewRepository(db).ChangeStatus(context.Background(), fixture.group.ID, fixture.targetMembership.ID, fixture.owner.ID, 2, organization.MembershipStatusDisabled, now)
	if err != nil {
		t.Fatalf("ChangeStatus() error=%v", err)
	}
	if result.Status != organization.MembershipStatusDisabled || result.Version != 3 {
		t.Fatalf("result=%+v", result)
	}
	var storedSession identity.RefreshSession
	if err := db.First(&storedSession, session.ID).Error; err != nil {
		t.Fatalf("load session: %v", err)
	}
	if storedSession.RevokedAt == nil || !storedSession.RevokedAt.Equal(now) {
		t.Fatalf("revoked_at=%v", storedSession.RevokedAt)
	}
	var audit memberAuditLogTest
	if err := db.Where("action = ?", "member.status.changed").First(&audit).Error; err != nil {
		t.Fatalf("load audit: %v", err)
	}
	if audit.OperatorUserID != fixture.owner.ID || audit.GroupID == nil || *audit.GroupID != fixture.group.ID {
		t.Fatalf("audit=%+v", audit)
	}
	_, err = NewRepository(db).ChangeStatus(context.Background(), fixture.group.ID, fixture.targetMembership.ID, fixture.owner.ID, 2, organization.MembershipStatusActive, now)
	if !errors.Is(err, ErrVersionConflict) {
		t.Fatalf("stale error=%v", err)
	}
}

func TestRepositoryReplacePermissionsIsIdempotentBeforeVersionCheck(t *testing.T) {
	db := openMemberTestDB(t, true)
	fixture := seedMemberFixture(t, db)
	record := permissionRecord{GroupID: fixture.group.ID, MembershipID: fixture.targetMembership.ID, PermissionCode: authorization.PermissionMemberManage, GrantedBy: fixture.owner.ID}
	if err := db.Create(&record).Error; err != nil {
		t.Fatalf("seed permission: %v", err)
	}
	repo := NewRepository(db)
	now := time.Date(2026, 7, 24, 16, 30, 0, 0, time.UTC)
	idempotent, err := repo.ReplacePermissions(context.Background(), fixture.group.ID, fixture.targetMembership.ID, fixture.owner.ID, 1, []authorization.Code{authorization.PermissionMemberManage}, now)
	if err != nil || idempotent.Version != 2 {
		t.Fatalf("idempotent=%+v error=%v", idempotent, err)
	}
	var auditCount int64
	_ = db.Model(&memberAuditLogTest{}).Count(&auditCount).Error
	if auditCount != 0 {
		t.Fatalf("idempotent audit count=%d", auditCount)
	}
	_, err = repo.ReplacePermissions(context.Background(), fixture.group.ID, fixture.targetMembership.ID, fixture.owner.ID, 1, []authorization.Code{authorization.PermissionDictionaryManage}, now)
	if !errors.Is(err, ErrVersionConflict) {
		t.Fatalf("different stale error=%v", err)
	}
	changed, err := repo.ReplacePermissions(context.Background(), fixture.group.ID, fixture.targetMembership.ID, fixture.owner.ID, 2, []authorization.Code{authorization.PermissionDictionaryManage}, now)
	if err != nil || changed.Version != 3 || len(changed.PermissionCodes) != 1 || changed.PermissionCodes[0] != authorization.PermissionDictionaryManage {
		t.Fatalf("changed=%+v error=%v", changed, err)
	}
	var records []permissionRecord
	if err := db.Find(&records).Error; err != nil {
		t.Fatalf("load permissions: %v", err)
	}
	if len(records) != 1 || records[0].PermissionCode != authorization.PermissionDictionaryManage {
		t.Fatalf("records=%+v", records)
	}
}

func TestRepositoryRollsBackMemberWriteWhenAuditFails(t *testing.T) {
	db := openMemberTestDB(t, false)
	fixture := seedMemberFixture(t, db)
	_, err := NewRepository(db).ChangeStatus(context.Background(), fixture.group.ID, fixture.targetMembership.ID, fixture.owner.ID, 2, organization.MembershipStatusDisabled, time.Now().UTC())
	if err == nil {
		t.Fatal("ChangeStatus() error=nil, want missing audit table")
	}
	var stored organization.Membership
	if err := db.First(&stored, fixture.targetMembership.ID).Error; err != nil {
		t.Fatalf("load membership: %v", err)
	}
	if stored.Status != organization.MembershipStatusActive || stored.Version != 2 {
		t.Fatalf("rolled back membership=%+v", stored)
	}
}
