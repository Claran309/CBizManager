package platform

import (
	"context"
	"errors"
	"testing"
	"time"

	"CBizDocsManager/backend/internal/identity"
	"CBizDocsManager/backend/internal/organization"
	"CBizDocsManager/backend/pkg/apperror"
)

// platformAdminPrincipal 是平台治理用例的默认调用者：已改密的平台管理员。
func platformAdminPrincipal() identity.Principal {
	return identity.Principal{UserID: 1, AccountType: identity.AccountTypePlatformAdmin, SessionID: 1}
}

func TestServiceListGroupsNormalizesPagingAndReturnsEmptyItems(t *testing.T) {
	tests := []struct {
		name             string
		query            GroupQuery
		wantPage         int
		wantPageSize     int
		wantKeyword      string
		wantRepoPageSize int
	}{
		{name: "defaults", query: GroupQuery{}, wantPage: 1, wantPageSize: 20, wantRepoPageSize: 20},
		{name: "oversized page size clamps to default", query: GroupQuery{Page: -1, PageSize: 9999}, wantPage: 1, wantPageSize: 20, wantRepoPageSize: 20},
		{name: "keyword trimmed", query: GroupQuery{Page: 2, PageSize: 50, Keyword: "  钢铁  "}, wantPage: 2, wantPageSize: 50, wantKeyword: "钢铁", wantRepoPageSize: 50},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			repo := &fakePlatformRepository{groups: nil, groupTotal: 0}
			service := NewService(repo, platformPasswordManager{})

			result, err := service.ListGroups(context.Background(), platformAdminPrincipal(), tt.query)
			if err != nil {
				t.Fatalf("ListGroups() error = %v", err)
			}
			if result.Page != tt.wantPage || result.PageSize != tt.wantPageSize || result.Total != 0 {
				t.Fatalf("ListGroups() paging = %+v", result)
			}
			// 空列表必须序列化成 []，不能让客户端拿到 null。
			if result.Items == nil {
				t.Fatal("ListGroups() Items = nil, want empty slice")
			}
			if repo.listQuery.PageSize != tt.wantRepoPageSize || repo.listQuery.Keyword != tt.wantKeyword || repo.listQuery.Page != tt.wantPage {
				t.Fatalf("repository query = %+v", repo.listQuery)
			}
		})
	}
}

func TestServiceGovernanceRequiresChangedPlatformAdmin(t *testing.T) {
	cases := []struct {
		name string
		run  func(*Service, identity.Principal) error
	}{
		{
			name: "list groups",
			run: func(s *Service, p identity.Principal) error {
				_, err := s.ListGroups(context.Background(), p, GroupQuery{})
				return err
			},
		},
		{
			name: "get group detail",
			run: func(s *Service, p identity.Principal) error {
				_, err := s.GetGroupDetail(context.Background(), p, 21)
				return err
			},
		},
		{
			name: "change status",
			run: func(s *Service, p identity.Principal) error {
				_, err := s.ChangeGroupStatus(context.Background(), p, 21, ChangeGroupStatusRequest{Status: organization.GroupStatusDisabled, Version: 1})
				return err
			},
		},
		{
			name: "change owner",
			run: func(s *Service, p identity.Principal) error {
				membershipID := uint64(31)
				_, err := s.ChangeGroupOwner(context.Background(), p, 21, ChangeGroupOwnerRequest{Mode: ChangeOwnerExistingMember, MembershipID: &membershipID, Version: 1})
				return err
			},
		},
	}
	principals := []struct {
		name     string
		value    identity.Principal
		wantCode string
	}{
		{name: "member forbidden", value: identity.Principal{AccountType: identity.AccountTypeMember}, wantCode: apperror.CodeForbidden},
		{name: "forced change forbidden", value: identity.Principal{AccountType: identity.AccountTypePlatformAdmin, MustChangePassword: true}, wantCode: apperror.CodeAuthPasswordChangeRequired},
	}
	for _, principal := range principals {
		for _, tt := range cases {
			t.Run(principal.name+"/"+tt.name, func(t *testing.T) {
				service := NewService(&fakePlatformRepository{}, platformPasswordManager{})
				err := tt.run(service, principal.value)
				assertPlatformAppError(t, err, principal.wantCode)
			})
		}
	}
}

func TestServiceGetGroupDetailMapsMissingAndFillsCandidates(t *testing.T) {
	t.Run("missing group", func(t *testing.T) {
		service := NewService(&fakePlatformRepository{detailErr: ErrGroupMissing}, platformPasswordManager{})
		_, err := service.GetGroupDetail(context.Background(), platformAdminPrincipal(), 21)
		assertPlatformAppError(t, err, apperror.CodeGroupNotFound)
	})
	t.Run("candidates default to empty slice", func(t *testing.T) {
		service := NewService(&fakePlatformRepository{detail: &GroupDetailData{
			Group: GroupSummaryData{ID: 21, Name: "钢铁组", Version: 1},
		}}, platformPasswordManager{})

		result, err := service.GetGroupDetail(context.Background(), platformAdminPrincipal(), 21)
		if err != nil {
			t.Fatalf("GetGroupDetail() error = %v", err)
		}
		if result.OwnerCandidates == nil || len(result.OwnerCandidates) != 0 {
			t.Fatalf("OwnerCandidates = %+v, want empty slice", result.OwnerCandidates)
		}
	})
	t.Run("zero id rejected", func(t *testing.T) {
		service := NewService(&fakePlatformRepository{}, platformPasswordManager{})
		_, err := service.GetGroupDetail(context.Background(), platformAdminPrincipal(), 0)
		assertPlatformAppError(t, err, apperror.CodeValidationFailed)
	})
}

func TestServiceChangeGroupStatusPassesVersionAndMapsConflicts(t *testing.T) {
	now := time.Date(2026, 9, 22, 10, 0, 0, 0, time.UTC)
	t.Run("success forwards expected version", func(t *testing.T) {
		repo := &fakePlatformRepository{statusResult: &GroupSummaryData{ID: 21, Name: "钢铁组", Status: organization.GroupStatusDisabled, Version: 2}}
		service := NewService(repo, platformPasswordManager{})
		service.now = func() time.Time { return now }

		result, err := service.ChangeGroupStatus(context.Background(), platformAdminPrincipal(), 21, ChangeGroupStatusRequest{
			Status: organization.GroupStatusDisabled, Version: 1,
		})
		if err != nil {
			t.Fatalf("ChangeGroupStatus() error = %v", err)
		}
		if result.Status != organization.GroupStatusDisabled || result.Version != 2 {
			t.Fatalf("ChangeGroupStatus() = %+v", result)
		}
		if repo.statusInput.ExpectedVersion != 1 || repo.statusInput.GroupID != 21 || repo.statusInput.OperatorUserID != 1 || repo.statusInput.Now != now {
			t.Fatalf("repository input = %+v", repo.statusInput)
		}
	})
	t.Run("repository errors map to stable codes", func(t *testing.T) {
		cases := []struct {
			repoErr  error
			wantCode string
		}{
			{ErrGroupMissing, apperror.CodeGroupNotFound},
			{ErrVersionConflict, apperror.CodeResourceVersionConflict},
			{ErrGroupStatusInvalid, apperror.CodeValidationFailed},
			{errors.New("database unavailable"), apperror.CodeInternalError},
		}
		for _, tt := range cases {
			service := NewService(&fakePlatformRepository{statusErr: tt.repoErr}, platformPasswordManager{})
			_, err := service.ChangeGroupStatus(context.Background(), platformAdminPrincipal(), 21, ChangeGroupStatusRequest{
				Status: organization.GroupStatusDisabled, Version: 1,
			})
			assertPlatformAppError(t, err, tt.wantCode)
		}
	})
	t.Run("zero version rejected before touching repository", func(t *testing.T) {
		repo := &fakePlatformRepository{}
		service := NewService(repo, platformPasswordManager{})
		_, err := service.ChangeGroupStatus(context.Background(), platformAdminPrincipal(), 21, ChangeGroupStatusRequest{Status: organization.GroupStatusDisabled})
		assertPlatformAppError(t, err, apperror.CodeValidationFailed)
		if repo.statusInput.GroupID != 0 {
			t.Fatal("repository must not be called on validation failure")
		}
	})
}

func TestServiceChangeGroupOwnerValidatesModeSpecificFields(t *testing.T) {
	membershipID := uint64(31)
	username, displayName, password := " new-owner ", " 新主账号 ", "new-owner-password"
	shortPassword := "short"

	t.Run("existing member mode ignores account fields", func(t *testing.T) {
		repo := &fakePlatformRepository{ownerChange: &OwnerChange{
			OldOwner: identity.User{ID: 11, Username: "old-owner"},
			NewOwner: identity.User{ID: 12, Username: "member-one", DisplayName: "成员一", AccountType: identity.AccountTypeGroupOwner},
		}, detail: &GroupDetailData{Group: GroupSummaryData{ID: 21, Name: "钢铁组", Version: 2}}}
		service := NewService(repo, platformPasswordManager{})

		result, err := service.ChangeGroupOwner(context.Background(), platformAdminPrincipal(), 21, ChangeGroupOwnerRequest{
			Mode: ChangeOwnerExistingMember, MembershipID: &membershipID, Version: 1,
			Username: &username, DisplayName: &displayName, TemporaryPassword: &password,
		})
		if err != nil {
			t.Fatalf("ChangeGroupOwner() error = %v", err)
		}
		if result.Owner.ID != 12 || result.Group.Version != 2 {
			t.Fatalf("ChangeGroupOwner() = %+v", result)
		}
		// 成员交接模式下不应把新账号信息传给仓储，避免误建账号。
		if repo.ownerInput.Username != "" || repo.ownerInput.DisplayName != "" || repo.ownerInput.PasswordHash != "" {
			t.Fatalf("repository input leaked account fields: %+v", repo.ownerInput)
		}
		if repo.ownerInput.MembershipID == nil || *repo.ownerInput.MembershipID != membershipID {
			t.Fatalf("repository membership id = %v", repo.ownerInput.MembershipID)
		}
	})

	t.Run("new account mode trims and hashes password", func(t *testing.T) {
		repo := &fakePlatformRepository{ownerChange: &OwnerChange{
			NewOwner: identity.User{ID: 13, Username: "new-owner", DisplayName: "新主账号", AccountType: identity.AccountTypeGroupOwner},
		}, detail: &GroupDetailData{Group: GroupSummaryData{ID: 21, Name: "钢铁组", Version: 2}}}
		service := NewService(repo, platformPasswordManager{})

		if _, err := service.ChangeGroupOwner(context.Background(), platformAdminPrincipal(), 21, ChangeGroupOwnerRequest{
			Mode: ChangeOwnerNewAccount, Username: &username, DisplayName: &displayName, TemporaryPassword: &password, Version: 1,
		}); err != nil {
			t.Fatalf("ChangeGroupOwner() error = %v", err)
		}
		if repo.ownerInput.Username != "new-owner" || repo.ownerInput.DisplayName != "新主账号" {
			t.Fatalf("repository input not trimmed: %+v", repo.ownerInput)
		}
		if repo.ownerInput.PasswordHash != "hash:new-owner-password" {
			t.Fatalf("repository password hash = %q", repo.ownerInput.PasswordHash)
		}
		if repo.ownerInput.MembershipID != nil {
			t.Fatalf("membership id should be nil in new_account mode, got %v", *repo.ownerInput.MembershipID)
		}
	})

	t.Run("invalid payloads rejected before repository", func(t *testing.T) {
		empty := ""
		cases := []struct {
			name string
			req  ChangeGroupOwnerRequest
		}{
			{name: "existing member without membership id", req: ChangeGroupOwnerRequest{Mode: ChangeOwnerExistingMember, Version: 1}},
			{name: "new account without username", req: ChangeGroupOwnerRequest{Mode: ChangeOwnerNewAccount, DisplayName: &displayName, TemporaryPassword: &password, Version: 1}},
			{name: "new account with blank username", req: ChangeGroupOwnerRequest{Mode: ChangeOwnerNewAccount, Username: &empty, DisplayName: &displayName, TemporaryPassword: &password, Version: 1}},
			{name: "new account with short password", req: ChangeGroupOwnerRequest{Mode: ChangeOwnerNewAccount, Username: &username, DisplayName: &displayName, TemporaryPassword: &shortPassword, Version: 1}},
			{name: "zero version", req: ChangeGroupOwnerRequest{Mode: ChangeOwnerExistingMember, MembershipID: &membershipID}},
		}
		for _, tt := range cases {
			t.Run(tt.name, func(t *testing.T) {
				repo := &fakePlatformRepository{}
				service := NewService(repo, platformPasswordManager{})
				_, err := service.ChangeGroupOwner(context.Background(), platformAdminPrincipal(), 21, tt.req)
				assertPlatformAppError(t, err, apperror.CodeValidationFailed)
				if repo.ownerInput.GroupID != 0 {
					t.Fatal("repository must not be called on validation failure")
				}
			})
		}
	})

	t.Run("repository errors map to stable codes", func(t *testing.T) {
		cases := []struct {
			repoErr  error
			wantCode string
		}{
			{ErrGroupMissing, apperror.CodeGroupNotFound},
			{ErrVersionConflict, apperror.CodeResourceVersionConflict},
			{ErrUsernameConflict, apperror.CodeUserUsernameExists},
			{ErrOwnerTargetInvalid, apperror.CodeOwnerTargetInvalid},
			{ErrOwnerTargetForbidden, apperror.CodeOwnerTargetInvalid},
			{errors.New("database unavailable"), apperror.CodeInternalError},
		}
		for _, tt := range cases {
			service := NewService(&fakePlatformRepository{ownerErr: tt.repoErr}, platformPasswordManager{})
			_, err := service.ChangeGroupOwner(context.Background(), platformAdminPrincipal(), 21, ChangeGroupOwnerRequest{
				Mode: ChangeOwnerExistingMember, MembershipID: &membershipID, Version: 1,
			})
			assertPlatformAppError(t, err, tt.wantCode)
		}
	})
}
