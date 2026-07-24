package authorization

import (
	"context"
	"testing"

	"CBizDocsManager/backend/internal/identity"
	"CBizDocsManager/backend/internal/organization"
	"github.com/glebarez/sqlite"
	"gorm.io/gorm"
)

type permissionRow struct {
	ID             uint64 `gorm:"primaryKey"`
	GroupID        uint64
	MembershipID   uint64
	PermissionCode string
}

func (permissionRow) TableName() string { return "membership_permissions" }

func openAuthorizationTestDB(t *testing.T) *gorm.DB {
	t.Helper()
	db, err := gorm.Open(sqlite.Open("file:"+t.Name()+"?mode=memory&cache=shared"), &gorm.Config{})
	if err != nil {
		t.Fatalf("open sqlite: %v", err)
	}
	if err := db.AutoMigrate(&identity.User{}, &organization.Group{}, &organization.Membership{}, &permissionRow{}); err != nil {
		t.Fatalf("migrate sqlite: %v", err)
	}
	return db
}

func TestRepositoryHasPermissionRequiresActiveTenantState(t *testing.T) {
	tests := []struct {
		name             string
		userStatus       identity.UserStatus
		groupStatus      organization.GroupStatus
		membershipStatus organization.MembershipStatus
		permissionCode   Code
		want             bool
	}{
		{"active grant", identity.UserStatusActive, organization.GroupStatusActive, organization.MembershipStatusActive, PermissionMemberManage, true},
		{"disabled user", identity.UserStatusDisabled, organization.GroupStatusActive, organization.MembershipStatusActive, PermissionMemberManage, false},
		{"disabled group", identity.UserStatusActive, organization.GroupStatusDisabled, organization.MembershipStatusActive, PermissionMemberManage, false},
		{"disabled membership", identity.UserStatusActive, organization.GroupStatusActive, organization.MembershipStatusDisabled, PermissionMemberManage, false},
		{"removed membership", identity.UserStatusActive, organization.GroupStatusActive, organization.MembershipStatusRemoved, PermissionMemberManage, false},
		{"different permission", identity.UserStatusActive, organization.GroupStatusActive, organization.MembershipStatusActive, PermissionDictionaryManage, false},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			db := openAuthorizationTestDB(t)
			user := identity.User{ID: 11, Username: "member", PasswordHash: "hash", DisplayName: "Member", AccountType: identity.AccountTypeMember, Status: test.userStatus}
			group := organization.Group{ID: 7, Name: "group", Status: test.groupStatus, OwnerUserID: 99, CreatedBy: 1}
			membership := organization.Membership{ID: 21, GroupID: group.ID, UserID: user.ID, MemberType: organization.MemberTypeMember, Status: test.membershipStatus, Version: 1}
			for _, value := range []any{&user, &group, &membership, &permissionRow{ID: 31, GroupID: group.ID, MembershipID: membership.ID, PermissionCode: string(PermissionMemberManage)}} {
				if err := db.Create(value).Error; err != nil {
					t.Fatalf("seed %T: %v", value, err)
				}
			}

			got, err := NewRepository(db).HasPermission(context.Background(), user.ID, group.ID, test.permissionCode)
			if err != nil {
				t.Fatalf("HasPermission() error = %v", err)
			}
			if got != test.want {
				t.Fatalf("HasPermission() = %v, want %v", got, test.want)
			}
		})
	}
}

func TestRepositoryHasPermissionDoesNotCrossGroups(t *testing.T) {
	db := openAuthorizationTestDB(t)
	user := identity.User{ID: 11, Username: "member", PasswordHash: "hash", DisplayName: "Member", AccountType: identity.AccountTypeMember, Status: identity.UserStatusActive}
	group := organization.Group{ID: 7, Name: "group", Status: organization.GroupStatusActive, OwnerUserID: 99, CreatedBy: 1}
	membership := organization.Membership{ID: 21, GroupID: group.ID, UserID: user.ID, MemberType: organization.MemberTypeMember, Status: organization.MembershipStatusActive, Version: 1}
	for _, value := range []any{&user, &group, &membership, &permissionRow{ID: 31, GroupID: group.ID, MembershipID: membership.ID, PermissionCode: string(PermissionMemberManage)}} {
		if err := db.Create(value).Error; err != nil {
			t.Fatalf("seed %T: %v", value, err)
		}
	}

	got, err := NewRepository(db).HasPermission(context.Background(), user.ID, 8, PermissionMemberManage)
	if err != nil {
		t.Fatalf("HasPermission() error = %v", err)
	}
	if got {
		t.Fatal("permission from another group was accepted")
	}
}
