package authorization

import (
	"context"
	"errors"
	"testing"

	"CBizDocsManager/backend/internal/identity"
	"CBizDocsManager/backend/pkg/apperror"
)

type permissionRepositoryStub struct {
	allowed bool
	err     error
	calls   int
	userID  uint64
	groupID uint64
	code    Code
}

func (r *permissionRepositoryStub) HasPermission(_ context.Context, userID, groupID uint64, code Code) (bool, error) {
	r.calls++
	r.userID = userID
	r.groupID = groupID
	r.code = code
	return r.allowed, r.err
}

func TestCatalogContainsStablePermissionCodes(t *testing.T) {
	want := []Code{
		PermissionDocumentViewOthers,
		PermissionDocumentEditOthers,
		PermissionReportView,
		PermissionMemberManage,
		PermissionDictionaryManage,
		PermissionSettlementApprove,
	}
	got := Catalog()
	if len(got) != len(want) {
		t.Fatalf("catalog length = %d, want %d", len(got), len(want))
	}
	for index := range want {
		if got[index] != want[index] {
			t.Fatalf("catalog[%d] = %q, want %q", index, got[index], want[index])
		}
		if !IsKnown(want[index]) {
			t.Fatalf("known code %q was rejected", want[index])
		}
	}
	if IsKnown(Code("member.unknown")) {
		t.Fatal("unknown permission code was accepted")
	}
}

func TestAuthorizerRequireUsesOwnerAndExplicitMemberRules(t *testing.T) {
	group7 := uint64(7)
	group8 := uint64(8)
	tests := []struct {
		name          string
		principal     identity.Principal
		groupID       uint64
		code          Code
		repoAllowed   bool
		wantCode      string
		wantRepoCalls int
	}{
		{
			name:      "group owner implicitly has every known permission",
			principal: identity.Principal{UserID: 10, GroupID: &group7, AccountType: identity.AccountTypeGroupOwner, MemberType: "owner"},
			groupID:   group7, code: PermissionSettlementApprove, wantRepoCalls: 0,
		},
		{
			name:      "ordinary member receives explicitly granted permission",
			principal: identity.Principal{UserID: 11, GroupID: &group7, AccountType: identity.AccountTypeMember, MemberType: "member"},
			groupID:   group7, code: PermissionDictionaryManage, repoAllowed: true, wantRepoCalls: 1,
		},
		{
			name:      "ordinary member without permission is forbidden",
			principal: identity.Principal{UserID: 11, GroupID: &group7, AccountType: identity.AccountTypeMember, MemberType: "member"},
			groupID:   group7, code: PermissionMemberManage, wantCode: apperror.CodeForbidden, wantRepoCalls: 1,
		},
		{
			name:      "cross group access is forbidden before repository lookup",
			principal: identity.Principal{UserID: 11, GroupID: &group7, AccountType: identity.AccountTypeMember, MemberType: "member"},
			groupID:   group8, code: PermissionDictionaryManage, repoAllowed: true, wantCode: apperror.CodeForbidden,
		},
		{
			name:      "platform administrator cannot access tenant permissions",
			principal: identity.Principal{UserID: 1, AccountType: identity.AccountTypePlatformAdmin},
			groupID:   group7, code: PermissionMemberManage, repoAllowed: true, wantCode: apperror.CodeForbidden,
		},
		{
			name:      "unknown code is rejected before repository lookup",
			principal: identity.Principal{UserID: 11, GroupID: &group7, AccountType: identity.AccountTypeMember, MemberType: "member"},
			groupID:   group7, code: Code("member.unknown"), repoAllowed: true, wantCode: apperror.CodePermissionCodeInvalid,
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			repo := &permissionRepositoryStub{allowed: test.repoAllowed}
			authorizer := NewAuthorizer(repo)
			err := authorizer.Require(context.Background(), test.principal, test.groupID, test.code)
			if test.wantCode == "" {
				if err != nil {
					t.Fatalf("Require() error = %v", err)
				}
			} else {
				var appErr *apperror.Error
				if !errors.As(err, &appErr) || appErr.Code != test.wantCode {
					t.Fatalf("Require() error = %v, want code %s", err, test.wantCode)
				}
			}
			if repo.calls != test.wantRepoCalls {
				t.Fatalf("repository calls = %d, want %d", repo.calls, test.wantRepoCalls)
			}
			if repo.calls == 1 && (repo.userID != test.principal.UserID || repo.groupID != test.groupID || repo.code != test.code) {
				t.Fatalf("repository arguments = (%d, %d, %q)", repo.userID, repo.groupID, repo.code)
			}
		})
	}
}

func TestAuthorizerRequireWrapsRepositoryFailure(t *testing.T) {
	groupID := uint64(7)
	repo := &permissionRepositoryStub{err: errors.New("database unavailable")}
	err := NewAuthorizer(repo).Require(context.Background(), identity.Principal{
		UserID: 11, GroupID: &groupID, AccountType: identity.AccountTypeMember, MemberType: "member",
	}, groupID, PermissionMemberManage)

	var appErr *apperror.Error
	if !errors.As(err, &appErr) || appErr.Code != apperror.CodeInternalError {
		t.Fatalf("Require() error = %v, want INTERNAL_ERROR", err)
	}
}
