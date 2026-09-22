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

func TestServiceCreatesGroupWithHashedTemporaryOwnerPassword(t *testing.T) {
	repo := &fakePlatformRepository{}
	service := NewService(repo, platformPasswordManager{})
	service.now = func() time.Time { return time.Date(2026, 7, 24, 14, 0, 0, 0, time.UTC) }
	principal := identity.Principal{UserID: 7, AccountType: identity.AccountTypePlatformAdmin}

	result, err := service.CreateGroup(context.Background(), principal, CreateGroupRequest{
		Name: " Finance ", OwnerUsername: " owner-one ", OwnerDisplayName: " Finance Owner ", OwnerTemporaryPassword: "temporary-password",
	})
	if err != nil {
		t.Fatalf("CreateGroup() error = %v", err)
	}
	if repo.input.GroupName != "Finance" || repo.input.OwnerUsername != "owner-one" || repo.input.OwnerPasswordHash != "hash:temporary-password" {
		t.Fatalf("repository input = %+v", repo.input)
	}
	if !repo.creation.Owner.MustChangePassword || repo.creation.Owner.AccountType != identity.AccountTypeGroupOwner {
		t.Fatalf("created owner = %+v", repo.creation.Owner)
	}
	if result.Group.ID == 0 || result.Owner.ID == 0 || result.Owner.Username != "owner-one" {
		t.Fatalf("CreateGroup() result = %+v", result)
	}
}

func TestServiceCreateGroupRequiresChangedPlatformAdmin(t *testing.T) {
	tests := []struct {
		name      string
		principal identity.Principal
		wantCode  string
	}{
		{name: "member", principal: identity.Principal{AccountType: identity.AccountTypeMember}, wantCode: apperror.CodeForbidden},
		{name: "forced change admin", principal: identity.Principal{AccountType: identity.AccountTypePlatformAdmin, MustChangePassword: true}, wantCode: apperror.CodeAuthPasswordChangeRequired},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			service := NewService(&fakePlatformRepository{}, platformPasswordManager{})
			result, err := service.CreateGroup(context.Background(), tt.principal, CreateGroupRequest{
				Name: "Group", OwnerUsername: "owner", OwnerDisplayName: "Owner", OwnerTemporaryPassword: "temporary-password",
			})
			if result != nil {
				t.Fatalf("CreateGroup() result = %+v, want nil", result)
			}
			assertPlatformAppError(t, err, tt.wantCode)
		})
	}
}

func TestServiceCreateGroupMapsRepositoryConflictsAndReturnsNoPartialResult(t *testing.T) {
	tests := []struct {
		name     string
		repoErr  error
		wantCode string
	}{
		{name: "group conflict", repoErr: ErrGroupNameConflict, wantCode: apperror.CodeGroupNameExists},
		{name: "username conflict", repoErr: ErrUsernameConflict, wantCode: apperror.CodeUserUsernameExists},
		{name: "internal", repoErr: errors.New("database unavailable"), wantCode: apperror.CodeInternalError},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			service := NewService(&fakePlatformRepository{err: tt.repoErr}, platformPasswordManager{})
			result, err := service.CreateGroup(context.Background(), identity.Principal{UserID: 1, AccountType: identity.AccountTypePlatformAdmin}, CreateGroupRequest{
				Name: "Group", OwnerUsername: "owner", OwnerDisplayName: "Owner", OwnerTemporaryPassword: "temporary-password",
			})
			if result != nil {
				t.Fatalf("CreateGroup() result = %+v, want nil", result)
			}
			assertPlatformAppError(t, err, tt.wantCode)
		})
	}
}

type platformPasswordManager struct{}

func (platformPasswordManager) Hash(plain string) (string, error) { return "hash:" + plain, nil }
func (platformPasswordManager) Verify(hash, plain string) bool    { return hash == "hash:"+plain }

type fakePlatformRepository struct {
	input    CreateGroupInput
	creation GroupCreation
	err      error

	// 平台治理（组列表 / 详情 / 启停 / 主账号交接）的桩数据与调用记录。
	groups       []GroupSummaryData
	groupTotal   int64
	listQuery    GroupQuery
	detail       *GroupDetailData
	detailErr    error
	statusInput  ChangeGroupStatusInput
	statusResult *GroupSummaryData
	statusErr    error
	ownerInput   ChangeOwnerInput
	ownerChange  *OwnerChange
	ownerErr     error
}

func (r *fakePlatformRepository) CreateGroupWithOwner(_ context.Context, input CreateGroupInput) (*GroupCreation, error) {
	r.input = input
	if r.err != nil {
		return nil, r.err
	}
	r.creation = GroupCreation{
		Owner: identity.User{
			ID: 11, Username: input.OwnerUsername, PasswordHash: input.OwnerPasswordHash, DisplayName: input.OwnerDisplayName,
			AccountType: identity.AccountTypeGroupOwner, Status: identity.UserStatusActive, MustChangePassword: true,
		},
		Group:      organization.Group{ID: 21, Name: input.GroupName, Status: organization.GroupStatusActive, OwnerUserID: 11, CreatedBy: input.OperatorUserID, Version: 1},
		Membership: organization.Membership{ID: 31, GroupID: 21, UserID: 11, MemberType: organization.MemberTypeOwner, Status: organization.MembershipStatusActive},
	}
	return &r.creation, nil
}

// ListGroups 返回预先配置的组分页桩数据，同时记录查询参数供断言使用。
func (r *fakePlatformRepository) ListGroups(_ context.Context, query GroupQuery) ([]GroupSummaryData, int64, error) {
	r.listQuery = query
	if r.err != nil {
		return nil, 0, r.err
	}
	return r.groups, r.groupTotal, nil
}

// GetGroupDetail 返回预先配置的组详情；未配置时按「组不存在」处理。
func (r *fakePlatformRepository) GetGroupDetail(_ context.Context, _ uint64) (*GroupDetailData, error) {
	if r.detailErr != nil {
		return nil, r.detailErr
	}
	if r.err != nil {
		return nil, r.err
	}
	if r.detail == nil {
		return nil, ErrGroupMissing
	}
	return r.detail, nil
}

// ChangeGroupStatus 记录输入并返回配置的启停结果。
func (r *fakePlatformRepository) ChangeGroupStatus(_ context.Context, input ChangeGroupStatusInput) (*GroupSummaryData, error) {
	r.statusInput = input
	if r.statusErr != nil {
		return nil, r.statusErr
	}
	if r.statusResult == nil {
		return nil, ErrGroupMissing
	}
	return r.statusResult, nil
}

// ChangeOwner 记录输入并返回配置的交接结果。
func (r *fakePlatformRepository) ChangeOwner(_ context.Context, input ChangeOwnerInput) (*OwnerChange, error) {
	r.ownerInput = input
	if r.ownerErr != nil {
		return nil, r.ownerErr
	}
	if r.ownerChange == nil {
		return nil, ErrOwnerTargetInvalid
	}
	return r.ownerChange, nil
}

func assertPlatformAppError(t *testing.T, err error, code string) {
	t.Helper()
	var appErr *apperror.Error
	if !errors.As(err, &appErr) || appErr.Code != code {
		t.Fatalf("error = %v, want %s", err, code)
	}
}
