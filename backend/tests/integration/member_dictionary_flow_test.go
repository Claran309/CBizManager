//go:build integration

package integration

import (
	"context"
	"errors"
	"testing"
	"time"

	"CBizDocsManager/backend/internal/authorization"
	"CBizDocsManager/backend/internal/dictionary"
	"CBizDocsManager/backend/internal/identity"
	"CBizDocsManager/backend/internal/member"
	"CBizDocsManager/backend/internal/organization"
	"CBizDocsManager/backend/pkg/apperror"
	jwtmanager "CBizDocsManager/backend/pkg/jwt"
)

func TestMemberPermissionAndDictionaryFlow(t *testing.T) {
	db := openAuthFlowMySQL(t)
	ctx := context.Background()
	passwords := identity.NewPasswordManager()
	ownerHash, err := passwords.Hash("owner-password")
	if err != nil {
		t.Fatalf("hash owner password: %v", err)
	}
	memberHash, err := passwords.Hash("member-password")
	if err != nil {
		t.Fatalf("hash member password: %v", err)
	}
	ownerUser := identity.User{Username: "owner-flow", PasswordHash: ownerHash, DisplayName: "Owner", AccountType: identity.AccountTypeGroupOwner, Status: identity.UserStatusActive}
	memberUser := identity.User{Username: "member-flow", PasswordHash: memberHash, DisplayName: "Member", AccountType: identity.AccountTypeMember, Status: identity.UserStatusActive}
	for _, user := range []*identity.User{&ownerUser, &memberUser} {
		if err := db.Create(user).Error; err != nil {
			t.Fatalf("seed user: %v", err)
		}
	}
	group := organization.Group{Name: "Flow Group", Status: organization.GroupStatusActive, OwnerUserID: ownerUser.ID, CreatedBy: ownerUser.ID}
	if err := db.Create(&group).Error; err != nil {
		t.Fatalf("seed group: %v", err)
	}
	ownerMembership := organization.Membership{GroupID: group.ID, UserID: ownerUser.ID, MemberType: organization.MemberTypeOwner, Status: organization.MembershipStatusActive, Version: 1}
	memberMembership := organization.Membership{GroupID: group.ID, UserID: memberUser.ID, MemberType: organization.MemberTypeMember, Status: organization.MembershipStatusActive, Version: 1}
	for _, membership := range []*organization.Membership{&ownerMembership, &memberMembership} {
		if err := db.Create(membership).Error; err != nil {
			t.Fatalf("seed membership: %v", err)
		}
	}

	tokens, err := jwtmanager.NewManager("integration-secret-at-least-32-bytes", "integration", 15*time.Minute)
	if err != nil {
		t.Fatalf("NewManager: %v", err)
	}
	identityService := identity.NewService(identity.NewRepository(db), passwords, tokens, 15*time.Minute, 24*time.Hour)
	authorizer := authorization.NewAuthorizer(authorization.NewRepository(db))
	memberService := member.NewService(member.NewRepository(db), authorizer)
	dictionaryService := dictionary.NewService(dictionary.NewRepository(db), authorizer)
	ownerPrincipal := identity.Principal{UserID: ownerUser.ID, GroupID: &group.ID, AccountType: identity.AccountTypeGroupOwner, MemberType: "owner"}

	permissionSet, err := memberService.ReplacePermissions(ctx, ownerPrincipal, memberMembership.ID, member.ReplacePermissionsRequest{PermissionCodes: []authorization.Code{authorization.PermissionDictionaryManage}, Version: 1})
	if err != nil || permissionSet.Version != 2 {
		t.Fatalf("ReplacePermissions()=%+v error=%v", permissionSet, err)
	}
	login, err := identityService.Login(ctx, identity.LoginRequest{Username: memberUser.Username, Password: "member-password"})
	if err != nil {
		t.Fatalf("member login: %v", err)
	}
	memberPrincipal, err := identityService.Authenticate(ctx, login.AccessToken)
	if err != nil {
		t.Fatalf("authenticate member: %v", err)
	}

	created, err := dictionaryService.Create(ctx, *memberPrincipal, dictionary.CreateRequest{Kind: dictionary.KindCustomer, Name: " ＡＣＭＥ  公司 "})
	if err != nil || created.ID == 0 {
		t.Fatalf("Create(customer)=%+v error=%v", created, err)
	}
	_, err = dictionaryService.Create(ctx, *memberPrincipal, dictionary.CreateRequest{Kind: dictionary.KindCustomer, Name: "acme 公司"})
	assertIntegrationCode(t, err, apperror.CodeDictionaryNameExists)
	product, err := dictionaryService.Create(ctx, *memberPrincipal, dictionary.CreateRequest{Kind: dictionary.KindProductName, Name: "Widget"})
	if err != nil {
		t.Fatalf("Create(product): %v", err)
	}
	if _, err := dictionaryService.Create(ctx, *memberPrincipal, dictionary.CreateRequest{Kind: dictionary.KindProductModel, Name: "X1", ParentID: &product.ID}); err != nil {
		t.Fatalf("Create(model): %v", err)
	}
	missingParent := uint64(999999)
	_, err = dictionaryService.Create(ctx, *memberPrincipal, dictionary.CreateRequest{Kind: dictionary.KindProductModel, Name: "X2", ParentID: &missingParent})
	assertIntegrationCode(t, err, apperror.CodeDictionaryParentInvalid)

	changed, err := memberService.ChangeStatus(ctx, ownerPrincipal, memberMembership.ID, member.ChangeStatusRequest{Status: organization.MembershipStatusDisabled, Version: 2})
	if err != nil || changed.Version != 3 {
		t.Fatalf("ChangeStatus()=%+v error=%v", changed, err)
	}
	_, err = identityService.Authenticate(ctx, login.AccessToken)
	assertIntegrationCode(t, err, apperror.CodeAuthTokenExpired)
	_, err = identityService.Refresh(ctx, identity.RefreshRequest{RefreshToken: login.RefreshToken})
	assertIntegrationCode(t, err, apperror.CodeAuthRefreshInvalid)

	var permissionCount int64
	if err := db.Table("membership_permissions").Where("membership_id = ? AND group_id = ?", memberMembership.ID, group.ID).Count(&permissionCount).Error; err != nil {
		t.Fatalf("count permissions: %v", err)
	}
	if permissionCount != 1 {
		t.Fatalf("permission count=%d", permissionCount)
	}
	if !errors.Is(authorizer.Require(ctx, *memberPrincipal, group.ID, authorization.PermissionDictionaryManage), apperror.ErrForbidden) {
		t.Fatal("disabled member retained effective permission")
	}
}
