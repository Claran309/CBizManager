package organization

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"sync"
	"testing"
	"time"

	"CBizDocsManager/backend/internal/identity"
	"CBizDocsManager/backend/pkg/apperror"
)

func TestServiceCreatesOneTimeInvitationWithDefaultAndCustomExpiry(t *testing.T) {
	tests := []struct {
		name     string
		days     int
		wantDays int
	}{
		{name: "default seven days", wantDays: 7},
		{name: "custom thirty days", days: 30, wantDays: 30},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			repo := newFakeOrganizationRepository()
			service := NewService(repo, organizationPasswordManager{})
			now := time.Date(2026, 7, 24, 14, 30, 0, 0, time.UTC)
			service.now = func() time.Time { return now }
			groupID := uint64(17)
			principal := identity.Principal{
				UserID: 5, GroupID: &groupID, GroupName: "Finance",
				AccountType: identity.AccountTypeGroupOwner, MemberType: "owner",
			}

			result, err := service.CreateInvitation(context.Background(), principal, CreateInvitationRequest{ExpiresInDays: tt.days})
			if err != nil {
				t.Fatalf("CreateInvitation() error = %v", err)
			}
			if result.InvitationCode == "" || repo.createInput.CodeHash == result.InvitationCode {
				t.Fatalf("invitation result=%+v repository input=%+v", result, repo.createInput)
			}
			if repo.createInput.CodeHash != organizationSHA256(result.InvitationCode) {
				t.Fatalf("stored code hash = %q", repo.createInput.CodeHash)
			}
			if !repo.createInput.ExpiresAt.Equal(now.Add(time.Duration(tt.wantDays) * 24 * time.Hour)) {
				t.Fatalf("expires_at=%v want %d days", repo.createInput.ExpiresAt, tt.wantDays)
			}
			if result.Group.ID != groupID || result.Group.Name != "Finance" {
				t.Fatalf("invitation group = %+v", result.Group)
			}
		})
	}
}

func TestServiceCreateInvitationRequiresChangedGroupOwner(t *testing.T) {
	groupID := uint64(1)
	tests := []struct {
		name      string
		principal identity.Principal
		wantCode  string
	}{
		{name: "member", principal: identity.Principal{GroupID: &groupID, AccountType: identity.AccountTypeMember, MemberType: "member"}, wantCode: apperror.CodeForbidden},
		{name: "forced owner", principal: identity.Principal{GroupID: &groupID, AccountType: identity.AccountTypeGroupOwner, MemberType: "owner", MustChangePassword: true}, wantCode: apperror.CodeAuthPasswordChangeRequired},
		{name: "owner without group", principal: identity.Principal{AccountType: identity.AccountTypeGroupOwner, MemberType: "owner"}, wantCode: apperror.CodeForbidden},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			service := NewService(newFakeOrganizationRepository(), organizationPasswordManager{})
			result, err := service.CreateInvitation(context.Background(), tt.principal, CreateInvitationRequest{})
			if result != nil {
				t.Fatalf("CreateInvitation() result=%+v, want nil", result)
			}
			assertOrganizationAppError(t, err, tt.wantCode)
		})
	}
}

func TestServiceRegistersMemberUsingOnlyHashedCredentials(t *testing.T) {
	repo := newFakeOrganizationRepository()
	service := NewService(repo, organizationPasswordManager{})
	result, err := service.Register(context.Background(), RegisterRequest{
		InvitationCode: " invitation-secret ", Username: " member-one ", Password: "member-password", DisplayName: " Member One ",
	})
	if err != nil {
		t.Fatalf("Register() error = %v", err)
	}
	if repo.consumeInput.CodeHash != organizationSHA256("invitation-secret") || repo.consumeInput.PasswordHash != "hash:member-password" {
		t.Fatalf("repository consume input = %+v", repo.consumeInput)
	}
	if repo.consumeInput.Username != "member-one" || repo.consumeInput.DisplayName != "Member One" {
		t.Fatalf("trimmed registration input = %+v", repo.consumeInput)
	}
	if result.User.AccountType != identity.AccountTypeMember || result.Group.ID == 0 {
		t.Fatalf("Register() result = %+v", result)
	}
}

func TestServiceRegisterMapsInvitationAndUsernameErrors(t *testing.T) {
	tests := []struct {
		name     string
		repoErr  error
		wantCode string
	}{
		{name: "invalid", repoErr: ErrInvitationInvalid, wantCode: apperror.CodeInvitationInvalid},
		{name: "expired", repoErr: ErrInvitationExpired, wantCode: apperror.CodeInvitationExpired},
		{name: "used", repoErr: ErrInvitationUsed, wantCode: apperror.CodeInvitationUsed},
		{name: "username", repoErr: ErrUsernameConflict, wantCode: apperror.CodeUserUsernameExists},
		{name: "inactive group", repoErr: ErrGroupInactive, wantCode: apperror.CodeInvitationInvalid},
		{name: "internal", repoErr: errors.New("database unavailable"), wantCode: apperror.CodeInternalError},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			repo := newFakeOrganizationRepository()
			repo.consumeErr = tt.repoErr
			service := NewService(repo, organizationPasswordManager{})
			result, err := service.Register(context.Background(), RegisterRequest{
				InvitationCode: "code", Username: "member", Password: "member-password", DisplayName: "Member",
			})
			if result != nil {
				t.Fatalf("Register() result=%+v, want nil", result)
			}
			assertOrganizationAppError(t, err, tt.wantCode)
		})
	}
}

func TestServiceConcurrentRegisterAllowsOneSuccess(t *testing.T) {
	repo := newFakeOrganizationRepository()
	repo.singleUse = true
	service := NewService(repo, organizationPasswordManager{})
	results := make(chan error, 2)
	for index := range 2 {
		go func(index int) {
			_, err := service.Register(context.Background(), RegisterRequest{
				InvitationCode: "same-code", Username: "member-" + string(rune('a'+index)), Password: "member-password", DisplayName: "Member",
			})
			results <- err
		}(index)
	}
	successes, used := 0, 0
	for range 2 {
		err := <-results
		if err == nil {
			successes++
			continue
		}
		var appErr *apperror.Error
		if errors.As(err, &appErr) && appErr.Code == apperror.CodeInvitationUsed {
			used++
		}
	}
	if successes != 1 || used != 1 {
		t.Fatalf("concurrent register results: success=%d used=%d", successes, used)
	}
}

type organizationPasswordManager struct{}

func (organizationPasswordManager) Hash(plain string) (string, error) { return "hash:" + plain, nil }
func (organizationPasswordManager) Verify(hash, plain string) bool    { return hash == "hash:"+plain }

type fakeOrganizationRepository struct {
	mu           sync.Mutex
	createInput  CreateInvitationInput
	consumeInput ConsumeInvitationInput
	consumeErr   error
	singleUse    bool
	used         bool

	// 邀请码生命周期（列表 / 查看 / 撤销）的桩数据与调用记录。
	listGroupID  uint64
	listQuery    InvitationQuery
	listItems    []InvitationSummaryData
	listTotal    int64
	listErr      error
	revealable   *Invitation
	revealErr    error
	revokeInput  RevokeInvitationInput
	revokeResult *Invitation
	revokeErr    error
}

func newFakeOrganizationRepository() *fakeOrganizationRepository {
	return &fakeOrganizationRepository{}
}

func (r *fakeOrganizationRepository) CreateInvitation(_ context.Context, input CreateInvitationInput) (*Invitation, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.createInput = input
	return &Invitation{ID: 9, GroupID: input.GroupID, CreatedBy: input.CreatedBy, CodeHash: input.CodeHash, ExpiresAt: input.ExpiresAt, Status: InvitationStatusActive, CreatedAt: input.Now}, nil
}

func (r *fakeOrganizationRepository) ConsumeInvitation(_ context.Context, input ConsumeInvitationInput) (*Registration, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.consumeInput = input
	if r.consumeErr != nil {
		return nil, r.consumeErr
	}
	if r.singleUse && r.used {
		return nil, ErrInvitationUsed
	}
	r.used = true
	return &Registration{
		User:       identity.User{ID: 12, Username: input.Username, DisplayName: input.DisplayName, AccountType: identity.AccountTypeMember, Status: identity.UserStatusActive},
		Group:      Group{ID: 22, Name: "Finance", Status: GroupStatusActive},
		Membership: Membership{ID: 32, GroupID: 22, UserID: 12, MemberType: MemberTypeMember, Status: MembershipStatusActive},
	}, nil
}

// ListInvitations 返回预先配置的列表桩数据，同时记录查询参数供断言使用。
func (r *fakeOrganizationRepository) ListInvitations(_ context.Context, groupID uint64, query InvitationQuery, _ time.Time) ([]InvitationSummaryData, int64, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.listGroupID = groupID
	r.listQuery = query
	if r.listErr != nil {
		return nil, 0, r.listErr
	}
	return r.listItems, r.listTotal, nil
}

// GetRevealableInvitation 模拟「仅同组 active 且未过期的邀请码可查看」的仓储行为。
func (r *fakeOrganizationRepository) GetRevealableInvitation(_ context.Context, groupID, invitationID uint64, _ time.Time) (*Invitation, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.revealErr != nil {
		return nil, r.revealErr
	}
	if r.revealable == nil {
		return nil, ErrInvitationInvalid
	}
	return r.revealable, nil
}

// RevokeInvitation 模拟撤销事务，返回撤销后的邀请码快照。
func (r *fakeOrganizationRepository) RevokeInvitation(_ context.Context, input RevokeInvitationInput) (*Invitation, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.revokeInput = input
	if r.revokeErr != nil {
		return nil, r.revokeErr
	}
	if r.revokeResult == nil {
		return nil, ErrInvitationInvalid
	}
	return r.revokeResult, nil
}

func organizationSHA256(value string) string {
	sum := sha256.Sum256([]byte(value))
	return hex.EncodeToString(sum[:])
}

func assertOrganizationAppError(t *testing.T, err error, code string) {
	t.Helper()
	var appErr *apperror.Error
	if !errors.As(err, &appErr) || appErr.Code != code {
		t.Fatalf("error=%v, want %s", err, code)
	}
}
