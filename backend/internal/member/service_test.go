package member

import (
	"context"
	"errors"
	"testing"
	"time"

	"CBizDocsManager/backend/internal/authorization"
	"CBizDocsManager/backend/internal/identity"
	"CBizDocsManager/backend/internal/organization"
	"CBizDocsManager/backend/pkg/apperror"
)

type memberRepositoryStub struct {
	members       map[uint64]Member
	permissions   map[uint64]PermissionSet
	page          Page
	lastStatus    organization.MembershipStatus
	lastCodes     []authorization.Code
	lastVersion   uint64
	statusErr     error
	permissionErr error
}

func (r *memberRepositoryStub) List(_ context.Context, _ uint64, _ ListQuery) (Page, error) {
	return r.page, nil
}
func (r *memberRepositoryStub) Find(_ context.Context, _ uint64, membershipID uint64) (Member, error) {
	value, ok := r.members[membershipID]
	if !ok {
		return Member{}, ErrNotFound
	}
	return value, nil
}
func (r *memberRepositoryStub) GetPermissions(_ context.Context, _ uint64, membershipID uint64) (PermissionSet, error) {
	value, ok := r.permissions[membershipID]
	if !ok {
		return PermissionSet{}, ErrNotFound
	}
	return value, nil
}
func (r *memberRepositoryStub) ChangeStatus(_ context.Context, _ uint64, membershipID, _ uint64, version uint64, status organization.MembershipStatus, _ time.Time) (Member, error) {
	r.lastStatus, r.lastVersion = status, version
	if r.statusErr != nil {
		return Member{}, r.statusErr
	}
	value := r.members[membershipID]
	value.Status, value.Version = status, version+1
	return value, nil
}
func (r *memberRepositoryStub) ReplacePermissions(_ context.Context, _ uint64, membershipID, _ uint64, version uint64, codes []authorization.Code, _ time.Time) (PermissionSet, error) {
	r.lastCodes, r.lastVersion = append([]authorization.Code(nil), codes...), version
	if r.permissionErr != nil {
		return PermissionSet{}, r.permissionErr
	}
	return PermissionSet{MembershipID: membershipID, PermissionCodes: append([]authorization.Code(nil), codes...), Version: version + 1}, nil
}

type authorizerStub struct {
	err   error
	calls int
	code  authorization.Code
}

func (a *authorizerStub) Require(_ context.Context, _ identity.Principal, _ uint64, code authorization.Code) error {
	a.calls++
	a.code = code
	return a.err
}

func ownerPrincipal(groupID uint64) identity.Principal {
	return identity.Principal{UserID: 10, GroupID: &groupID, AccountType: identity.AccountTypeGroupOwner, MemberType: "owner"}
}
func memberPrincipal(userID, groupID uint64) identity.Principal {
	return identity.Principal{UserID: userID, GroupID: &groupID, AccountType: identity.AccountTypeMember, MemberType: "member"}
}
func appErrorCode(t *testing.T, err error) string {
	t.Helper()
	var appErr *apperror.Error
	if !errors.As(err, &appErr) {
		t.Fatalf("error = %v, want app error", err)
	}
	return appErr.Code
}

func TestServiceListRequiresMemberManageAndKeepsGroupScope(t *testing.T) {
	groupID := uint64(7)
	repo := &memberRepositoryStub{page: Page{Items: []Member{{MembershipID: 21, GroupID: groupID}}, Page: 1, PageSize: 20, Total: 1}}
	auth := &authorizerStub{}
	service := NewService(repo, auth)
	page, err := service.List(context.Background(), memberPrincipal(11, groupID), ListQuery{Page: 1, PageSize: 20})
	if err != nil || page.Total != 1 {
		t.Fatalf("List() page=%+v error=%v", page, err)
	}
	if auth.calls != 1 || auth.code != authorization.PermissionMemberManage {
		t.Fatalf("authorization = calls %d code %q", auth.calls, auth.code)
	}
}

func TestServiceChangeStatusEnforcesTargetAndTransitionRules(t *testing.T) {
	groupID := uint64(7)
	tests := []struct {
		name     string
		actor    identity.Principal
		target   Member
		next     organization.MembershipStatus
		wantCode string
	}{
		{"owner is protected", ownerPrincipal(groupID), Member{MembershipID: 20, GroupID: groupID, User: identity.UserSummary{ID: 10}, MemberType: organization.MemberTypeOwner, Status: organization.MembershipStatusActive, Version: 1}, organization.MembershipStatusDisabled, apperror.CodeMemberOwnerProtected},
		{"self operation is forbidden", memberPrincipal(11, groupID), Member{MembershipID: 21, GroupID: groupID, User: identity.UserSummary{ID: 11}, MemberType: organization.MemberTypeMember, Status: organization.MembershipStatusActive, Version: 1}, organization.MembershipStatusDisabled, apperror.CodeMemberSelfOperationForbidden},
		{"removed is terminal", ownerPrincipal(groupID), Member{MembershipID: 21, GroupID: groupID, User: identity.UserSummary{ID: 11}, MemberType: organization.MemberTypeMember, Status: organization.MembershipStatusRemoved, Version: 2}, organization.MembershipStatusActive, apperror.CodeValidationFailed},
		{"active can disable", ownerPrincipal(groupID), Member{MembershipID: 21, GroupID: groupID, User: identity.UserSummary{ID: 11}, MemberType: organization.MemberTypeMember, Status: organization.MembershipStatusActive, Version: 2}, organization.MembershipStatusDisabled, ""},
		{"disabled can restore", ownerPrincipal(groupID), Member{MembershipID: 21, GroupID: groupID, User: identity.UserSummary{ID: 11}, MemberType: organization.MemberTypeMember, Status: organization.MembershipStatusDisabled, Version: 2}, organization.MembershipStatusActive, ""},
		{"active can be removed", ownerPrincipal(groupID), Member{MembershipID: 21, GroupID: groupID, User: identity.UserSummary{ID: 11}, MemberType: organization.MemberTypeMember, Status: organization.MembershipStatusActive, Version: 2}, organization.MembershipStatusRemoved, ""},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			repo := &memberRepositoryStub{members: map[uint64]Member{test.target.MembershipID: test.target}}
			service := NewService(repo, &authorizerStub{})
			_, err := service.ChangeStatus(context.Background(), test.actor, test.target.MembershipID, ChangeStatusRequest{Status: test.next, Version: test.target.Version})
			if test.wantCode == "" {
				if err != nil {
					t.Fatalf("ChangeStatus() error=%v", err)
				}
				return
			}
			if got := appErrorCode(t, err); got != test.wantCode {
				t.Fatalf("error code=%s want=%s", got, test.wantCode)
			}
		})
	}
}

func TestServiceChangeStatusRejectsStaleVersionWhenStatusAlreadyMatches(t *testing.T) {
	groupID := uint64(7)
	target := Member{MembershipID: 21, GroupID: groupID, User: identity.UserSummary{ID: 11}, MemberType: organization.MemberTypeMember, Status: organization.MembershipStatusActive, Version: 3}
	repo := &memberRepositoryStub{members: map[uint64]Member{target.MembershipID: target}}

	_, err := NewService(repo, &authorizerStub{}).ChangeStatus(context.Background(), ownerPrincipal(groupID), target.MembershipID, ChangeStatusRequest{Status: organization.MembershipStatusActive, Version: 2})
	if got := appErrorCode(t, err); got != apperror.CodeResourceVersionConflict {
		t.Fatalf("error code=%s want=%s", got, apperror.CodeResourceVersionConflict)
	}
}

func TestServiceReplacePermissionsAllowsOnlyOwnerAndValidCodes(t *testing.T) {
	groupID := uint64(7)
	target := Member{MembershipID: 21, GroupID: groupID, User: identity.UserSummary{ID: 11}, MemberType: organization.MemberTypeMember, Status: organization.MembershipStatusActive, Version: 3}
	tests := []struct {
		name     string
		actor    identity.Principal
		codes    []authorization.Code
		wantCode string
	}{
		{"owner replaces complete set", ownerPrincipal(groupID), []authorization.Code{authorization.PermissionDictionaryManage, authorization.PermissionMemberManage}, ""},
		{"ordinary manager cannot grant", memberPrincipal(12, groupID), []authorization.Code{authorization.PermissionMemberManage}, apperror.CodeForbidden},
		{"unknown code is invalid", ownerPrincipal(groupID), []authorization.Code{authorization.Code("unknown")}, apperror.CodePermissionCodeInvalid},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			repo := &memberRepositoryStub{members: map[uint64]Member{target.MembershipID: target}}
			result, err := NewService(repo, &authorizerStub{}).ReplacePermissions(context.Background(), test.actor, target.MembershipID, ReplacePermissionsRequest{PermissionCodes: test.codes, Version: target.Version})
			if test.wantCode == "" {
				if err != nil || result.MembershipID != target.MembershipID {
					t.Fatalf("result=%+v error=%v", result, err)
				}
				return
			}
			if got := appErrorCode(t, err); got != test.wantCode {
				t.Fatalf("error code=%s want=%s", got, test.wantCode)
			}
		})
	}
}

func TestServiceMapsRepositoryErrors(t *testing.T) {
	groupID := uint64(7)
	repo := &memberRepositoryStub{members: map[uint64]Member{}, statusErr: ErrVersionConflict}
	service := NewService(repo, &authorizerStub{})
	_, err := service.ChangeStatus(context.Background(), ownerPrincipal(groupID), 99, ChangeStatusRequest{Status: organization.MembershipStatusDisabled, Version: 1})
	if got := appErrorCode(t, err); got != apperror.CodeMemberNotFound {
		t.Fatalf("not found code=%s", got)
	}

	target := Member{MembershipID: 21, GroupID: groupID, User: identity.UserSummary{ID: 11}, MemberType: organization.MemberTypeMember, Status: organization.MembershipStatusActive, Version: 1}
	repo.members[target.MembershipID] = target
	_, err = service.ChangeStatus(context.Background(), ownerPrincipal(groupID), target.MembershipID, ChangeStatusRequest{Status: organization.MembershipStatusDisabled, Version: 1})
	if got := appErrorCode(t, err); got != apperror.CodeResourceVersionConflict {
		t.Fatalf("version code=%s", got)
	}
}
