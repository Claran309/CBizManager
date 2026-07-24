package organization

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
)

func TestRepositoryCreatesInvitationAndAuditInOneTransaction(t *testing.T) {
	db := openOrganizationTestDB(t, true)
	_, owner, group := seedOrganizationGroup(t, db, "invite")
	repo := NewRepository(db)
	now := time.Date(2026, 7, 24, 15, 0, 0, 0, time.UTC)

	created, err := repo.CreateInvitation(context.Background(), CreateInvitationInput{
		GroupID: group.ID, CreatedBy: owner.ID, CodeHash: "invitation-code-hash",
		ExpiresAt: now.Add(7 * 24 * time.Hour), Now: now,
	})
	if err != nil {
		t.Fatalf("CreateInvitation() error = %v", err)
	}
	if created.ID == 0 || created.Status != InvitationStatusActive || created.CreatedAt != now {
		t.Fatalf("CreateInvitation() = %+v, want persisted active invitation", created)
	}
	var audit organizationAuditLogTest
	if err := db.Where("action = ?", "organization.invitation.created").First(&audit).Error; err != nil {
		t.Fatalf("load invitation audit: %v", err)
	}
	if audit.GroupID == nil || *audit.GroupID != group.ID || audit.OperatorUserID != owner.ID {
		t.Fatalf("invitation audit = %+v, want group/operator", audit)
	}
}

func TestRepositoryRollsBackInvitationWhenAuditInsertFails(t *testing.T) {
	db := openOrganizationTestDB(t, false)
	_, owner, group := seedOrganizationGroup(t, db, "invite-audit-fail")
	repo := NewRepository(db)

	_, err := repo.CreateInvitation(context.Background(), CreateInvitationInput{
		GroupID: group.ID, CreatedBy: owner.ID, CodeHash: "must-roll-back",
		ExpiresAt: time.Now().UTC().Add(time.Hour), Now: time.Now().UTC(),
	})
	if err == nil {
		t.Fatal("CreateInvitation() error = nil, want missing audit table failure")
	}
	var count int64
	if err := db.Model(&Invitation{}).Where("code_hash = ?", "must-roll-back").Count(&count).Error; err != nil {
		t.Fatalf("count rolled-back invitation: %v", err)
	}
	if count != 0 {
		t.Fatalf("failed transaction left %d invitations, want 0", count)
	}
}

func TestRepositoryConsumesInvitationOnceAndReturnsRegistration(t *testing.T) {
	db := openOrganizationTestDB(t, true)
	_, owner, group := seedOrganizationGroup(t, db, "register")
	now := time.Date(2026, 7, 24, 16, 0, 0, 0, time.UTC)
	invitation := Invitation{GroupID: group.ID, CreatedBy: owner.ID, CodeHash: "consume-once", ExpiresAt: now.Add(time.Hour), Status: InvitationStatusActive, CreatedAt: now.Add(-time.Minute)}
	if err := db.Create(&invitation).Error; err != nil {
		t.Fatalf("seed invitation: %v", err)
	}
	repo := NewRepository(db)
	input := ConsumeInvitationInput{CodeHash: invitation.CodeHash, Username: "new-member", PasswordHash: "member-hash", DisplayName: "New Member", Now: now}

	registration, err := repo.ConsumeInvitation(context.Background(), input)
	if err != nil {
		t.Fatalf("ConsumeInvitation() error = %v", err)
	}
	if registration.User.ID == 0 || registration.Group.ID != group.ID || registration.Membership.UserID != registration.User.ID || registration.Membership.GroupID != group.ID {
		t.Fatalf("ConsumeInvitation() = %+v, want consistent registration", registration)
	}
	if registration.User.AccountType != identity.AccountTypeMember || registration.Membership.MemberType != MemberTypeMember {
		t.Fatalf("registration roles = %+v, want member", registration)
	}

	_, err = repo.ConsumeInvitation(context.Background(), ConsumeInvitationInput{
		CodeHash: invitation.CodeHash, Username: "second-member", PasswordHash: "hash", DisplayName: "Second", Now: now.Add(time.Second),
	})
	if !errors.Is(err, ErrInvitationUsed) {
		t.Fatalf("second ConsumeInvitation() error = %v, want ErrInvitationUsed", err)
	}
	var memberUsers, memberships int64
	if err := db.Model(&identity.User{}).Where("account_type = ?", identity.AccountTypeMember).Count(&memberUsers).Error; err != nil {
		t.Fatalf("count member users: %v", err)
	}
	if err := db.Model(&Membership{}).Where("group_id = ? AND member_type = ?", group.ID, MemberTypeMember).Count(&memberships).Error; err != nil {
		t.Fatalf("count member memberships: %v", err)
	}
	if memberUsers != 1 || memberships != 1 {
		t.Fatalf("replay created users=%d memberships=%d, want 1 each", memberUsers, memberships)
	}
	var audit organizationAuditLogTest
	if err := db.Where("action = ?", "identity.member.registered").First(&audit).Error; err != nil {
		t.Fatalf("load registration audit: %v", err)
	}
}

func TestRepositoryMapsInvitationAndUsernameFailuresWithoutConsuming(t *testing.T) {
	tests := []struct {
		name    string
		prepare func(t *testing.T, db *gorm.DB, owner identity.User, group Group, now time.Time) string
		wantErr error
	}{
		{
			name:    "invalid",
			prepare: func(_ *testing.T, _ *gorm.DB, _ identity.User, _ Group, _ time.Time) string { return "missing-code" },
			wantErr: ErrInvitationInvalid,
		},
		{
			name: "expired",
			prepare: func(t *testing.T, db *gorm.DB, owner identity.User, group Group, now time.Time) string {
				inv := Invitation{GroupID: group.ID, CreatedBy: owner.ID, CodeHash: "expired-code", ExpiresAt: now, Status: InvitationStatusActive, CreatedAt: now.Add(-time.Hour)}
				if err := db.Create(&inv).Error; err != nil {
					t.Fatalf("seed expired invitation: %v", err)
				}
				return inv.CodeHash
			},
			wantErr: ErrInvitationExpired,
		},
		{
			name: "used",
			prepare: func(t *testing.T, db *gorm.DB, owner identity.User, group Group, now time.Time) string {
				usedAt := now.Add(-time.Minute)
				inv := Invitation{GroupID: group.ID, CreatedBy: owner.ID, CodeHash: "used-code", ExpiresAt: now.Add(time.Hour), UsedAt: &usedAt, UsedBy: &owner.ID, Status: InvitationStatusUsed, CreatedAt: now.Add(-time.Hour)}
				if err := db.Create(&inv).Error; err != nil {
					t.Fatalf("seed used invitation: %v", err)
				}
				return inv.CodeHash
			},
			wantErr: ErrInvitationUsed,
		},
		{
			name: "inactive group",
			prepare: func(t *testing.T, db *gorm.DB, owner identity.User, group Group, now time.Time) string {
				if err := db.Model(&Group{}).Where("id = ?", group.ID).Update("status", GroupStatusDisabled).Error; err != nil {
					t.Fatalf("disable group: %v", err)
				}
				inv := Invitation{GroupID: group.ID, CreatedBy: owner.ID, CodeHash: "inactive-group-code", ExpiresAt: now.Add(time.Hour), Status: InvitationStatusActive, CreatedAt: now}
				if err := db.Create(&inv).Error; err != nil {
					t.Fatalf("seed inactive-group invitation: %v", err)
				}
				return inv.CodeHash
			},
			wantErr: ErrGroupInactive,
		},
		{
			name: "username conflict",
			prepare: func(t *testing.T, db *gorm.DB, owner identity.User, group Group, now time.Time) string {
				inv := Invitation{GroupID: group.ID, CreatedBy: owner.ID, CodeHash: "username-conflict-code", ExpiresAt: now.Add(time.Hour), Status: InvitationStatusActive, CreatedAt: now}
				if err := db.Create(&inv).Error; err != nil {
					t.Fatalf("seed conflict invitation: %v", err)
				}
				return inv.CodeHash
			},
			wantErr: ErrUsernameConflict,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			db := openOrganizationTestDB(t, true)
			_, owner, group := seedOrganizationGroup(t, db, tt.name)
			now := time.Date(2026, 7, 24, 17, 0, 0, 0, time.UTC)
			codeHash := tt.prepare(t, db, owner, group, now)
			username := "candidate-" + strings.ReplaceAll(tt.name, " ", "-")
			if tt.name == "username conflict" {
				existing := identity.User{Username: username, PasswordHash: "hash", DisplayName: "Existing", AccountType: identity.AccountTypeMember, Status: identity.UserStatusActive}
				if err := db.Create(&existing).Error; err != nil {
					t.Fatalf("seed duplicate username: %v", err)
				}
			}
			_, err := NewRepository(db).ConsumeInvitation(context.Background(), ConsumeInvitationInput{
				CodeHash: codeHash, Username: username, PasswordHash: "hash", DisplayName: "Candidate", Now: now,
			})
			if !errors.Is(err, tt.wantErr) {
				t.Fatalf("ConsumeInvitation() error = %v, want %v", err, tt.wantErr)
			}
			if codeHash != "missing-code" {
				var invitation Invitation
				if err := db.Where("code_hash = ?", codeHash).First(&invitation).Error; err != nil {
					t.Fatalf("reload invitation: %v", err)
				}
				if tt.name != "used" && invitation.Status != InvitationStatusActive {
					t.Fatalf("failed registration consumed invitation: %+v", invitation)
				}
			}
		})
	}
}

func openOrganizationTestDB(t *testing.T, withAudit bool) *gorm.DB {
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
	models := []any{&identity.User{}, &Group{}, &Membership{}, &Invitation{}}
	if withAudit {
		models = append(models, &organizationAuditLogTest{})
	}
	if err := db.AutoMigrate(models...); err != nil {
		t.Fatalf("AutoMigrate test schema: %v", err)
	}
	return db
}

func seedOrganizationGroup(t *testing.T, db *gorm.DB, suffix string) (identity.User, identity.User, Group) {
	t.Helper()
	admin := identity.User{Username: "admin-" + suffix, PasswordHash: "hash", DisplayName: "Admin", AccountType: identity.AccountTypePlatformAdmin, Status: identity.UserStatusActive}
	if err := db.Create(&admin).Error; err != nil {
		t.Fatalf("seed admin: %v", err)
	}
	owner := identity.User{Username: "owner-" + suffix, PasswordHash: "hash", DisplayName: "Owner", AccountType: identity.AccountTypeGroupOwner, Status: identity.UserStatusActive}
	if err := db.Create(&owner).Error; err != nil {
		t.Fatalf("seed owner: %v", err)
	}
	group := Group{Name: "group-" + suffix, Status: GroupStatusActive, OwnerUserID: owner.ID, CreatedBy: admin.ID}
	if err := db.Create(&group).Error; err != nil {
		t.Fatalf("seed group: %v", err)
	}
	membership := Membership{GroupID: group.ID, UserID: owner.ID, MemberType: MemberTypeOwner, Status: MembershipStatusActive}
	if err := db.Create(&membership).Error; err != nil {
		t.Fatalf("seed owner membership: %v", err)
	}
	return admin, owner, group
}

type organizationAuditLogTest struct {
	ID             uint64 `gorm:"primaryKey;autoIncrement"`
	GroupID        *uint64
	OperatorUserID uint64
	Action         string
	ResourceType   string
	ResourceID     string
	Summary        string
	CreatedAt      time.Time
}

func (organizationAuditLogTest) TableName() string { return "audit_logs" }
