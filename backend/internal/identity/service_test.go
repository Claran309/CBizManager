package identity

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"sync"
	"testing"
	"time"

	"CBizDocsManager/backend/pkg/apperror"
	jwtmanager "CBizDocsManager/backend/pkg/jwt"
)

func TestServiceLoginCreatesHashedRefreshSessionAndReturnsPrincipal(t *testing.T) {
	repo := newFakeIdentityRepository()
	admin := repo.addUser(User{
		Username: "admin", PasswordHash: "hash:secret", DisplayName: "Admin",
		AccountType: AccountTypePlatformAdmin, Status: UserStatusActive, MustChangePassword: true,
	}, AccessState{AccountType: AccountTypePlatformAdmin, UserStatus: UserStatusActive, MustChangePassword: true})
	service, now := newIdentityTestService(t, repo)

	pair, err := service.Login(context.Background(), LoginRequest{Username: " admin ", Password: "secret"})
	if err != nil {
		t.Fatalf("Login() error = %v", err)
	}
	if pair.AccessToken == "" || pair.RefreshToken == "" {
		t.Fatalf("Login() tokens = %+v, want non-empty values", pair)
	}
	if !pair.AccessExpiresAt.Equal(now.Add(15*time.Minute)) || !pair.RefreshExpiresAt.Equal(now.Add(7*24*time.Hour)) {
		t.Fatalf("Login() expiry = access:%v refresh:%v", pair.AccessExpiresAt, pair.RefreshExpiresAt)
	}

	principal, err := service.Authenticate(context.Background(), pair.AccessToken)
	if err != nil {
		t.Fatalf("Authenticate() error = %v", err)
	}
	if principal.UserID != admin.ID || principal.GroupID != nil || principal.SessionID == 0 || !principal.MustChangePassword {
		t.Fatalf("Authenticate() principal = %+v", principal)
	}

	repo.mu.Lock()
	created := cloneRefreshSession(repo.lastCreatedSession)
	repo.mu.Unlock()
	if created == nil || created.TokenHash == pair.RefreshToken {
		t.Fatalf("persisted refresh session = %+v, raw token must not be stored", created)
	}
	if created.TokenHash != sha256HexForTest(pair.RefreshToken) {
		t.Fatalf("persisted token hash = %q, want SHA-256 of returned refresh token", created.TokenHash)
	}
}

func TestServiceLoginUsesUnifiedCredentialErrorForInvalidOrInactiveAccounts(t *testing.T) {
	tests := []struct {
		name       string
		seed       bool
		password   string
		userStatus UserStatus
		group      bool
		groupState string
		member     string
	}{
		{name: "missing user", password: "secret"},
		{name: "wrong password", seed: true, password: "wrong", userStatus: UserStatusActive},
		{name: "disabled user", seed: true, password: "secret", userStatus: UserStatusDisabled},
		{name: "disabled group", seed: true, password: "secret", userStatus: UserStatusActive, group: true, groupState: "disabled", member: "active"},
		{name: "disabled membership", seed: true, password: "secret", userStatus: UserStatusActive, group: true, groupState: "active", member: "disabled"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			repo := newFakeIdentityRepository()
			if tt.seed {
				accountType := AccountTypePlatformAdmin
				state := AccessState{AccountType: accountType, UserStatus: tt.userStatus}
				if tt.group {
					groupID := uint64(91)
					accountType = AccountTypeMember
					state.AccountType = accountType
					state.GroupID = &groupID
					state.MemberType = "member"
					state.GroupStatus = tt.groupState
					state.MembershipStatus = tt.member
				}
				repo.addUser(User{Username: "person", PasswordHash: "hash:secret", DisplayName: "Person", AccountType: accountType, Status: tt.userStatus}, state)
			}
			service, _ := newIdentityTestService(t, repo)

			_, err := service.Login(context.Background(), LoginRequest{Username: "person", Password: tt.password})
			assertAppErrorCode(t, err, apperror.CodeAuthInvalidCredentials)
		})
	}
}

func TestServiceAuthenticateRejectsStaleOrInactiveAccessState(t *testing.T) {
	repo := newFakeIdentityRepository()
	groupID := uint64(42)
	user := repo.addUser(User{
		Username: "member", PasswordHash: "hash:secret", DisplayName: "Member",
		AccountType: AccountTypeMember, Status: UserStatusActive,
	}, AccessState{
		GroupID: &groupID, AccountType: AccountTypeMember, MemberType: "member",
		UserStatus: UserStatusActive, GroupStatus: "active", MembershipStatus: "active",
	})
	service, _ := newIdentityTestService(t, repo)
	pair, err := service.Login(context.Background(), LoginRequest{Username: user.Username, Password: "secret"})
	if err != nil {
		t.Fatalf("Login() error = %v", err)
	}

	repo.mu.Lock()
	state := repo.states[user.ID]
	state.GroupStatus = "disabled"
	repo.states[user.ID] = state
	repo.mu.Unlock()
	_, err = service.Authenticate(context.Background(), pair.AccessToken)
	assertAppErrorCode(t, err, apperror.CodeAuthTokenExpired)
}

func TestServiceChangePasswordVerifiesCurrentPasswordAndClearsForcedChange(t *testing.T) {
	repo := newFakeIdentityRepository()
	user := repo.addUser(User{
		Username: "owner", PasswordHash: "hash:old-password", DisplayName: "Owner",
		AccountType: AccountTypeGroupOwner, Status: UserStatusActive, MustChangePassword: true,
	}, AccessState{AccountType: AccountTypeGroupOwner, UserStatus: UserStatusActive, MustChangePassword: true})
	service, _ := newIdentityTestService(t, repo)
	principal := Principal{UserID: user.ID, AccountType: user.AccountType, MustChangePassword: true, SessionID: 7}

	err := service.ChangePassword(context.Background(), principal, ChangePasswordRequest{CurrentPassword: "wrong", NewPassword: "new-password"})
	assertAppErrorCode(t, err, apperror.CodeAuthInvalidCredentials)
	err = service.ChangePassword(context.Background(), principal, ChangePasswordRequest{CurrentPassword: "old-password", NewPassword: "new-password"})
	if err != nil {
		t.Fatalf("ChangePassword() error = %v", err)
	}

	got, err := repo.FindUserByID(context.Background(), user.ID)
	if err != nil {
		t.Fatalf("FindUserByID() error = %v", err)
	}
	if got.PasswordHash != "hash:new-password" || got.MustChangePassword {
		t.Fatalf("changed user = %+v", got)
	}
}

func TestServiceRefreshRotatesOnceAndLogoutRevokesCurrentSession(t *testing.T) {
	repo := newFakeIdentityRepository()
	repo.addUser(User{
		Username: "refresh-user", PasswordHash: "hash:secret", DisplayName: "Refresh",
		AccountType: AccountTypePlatformAdmin, Status: UserStatusActive,
	}, AccessState{AccountType: AccountTypePlatformAdmin, UserStatus: UserStatusActive})
	service, _ := newIdentityTestService(t, repo)

	loginPair, err := service.Login(context.Background(), LoginRequest{Username: "refresh-user", Password: "secret"})
	if err != nil {
		t.Fatalf("Login() error = %v", err)
	}
	refreshed, err := service.Refresh(context.Background(), RefreshRequest{RefreshToken: loginPair.RefreshToken})
	if err != nil {
		t.Fatalf("Refresh() error = %v", err)
	}
	if refreshed.RefreshToken == loginPair.RefreshToken || refreshed.AccessToken == loginPair.AccessToken {
		t.Fatal("Refresh() did not rotate both token values")
	}
	_, err = service.Refresh(context.Background(), RefreshRequest{RefreshToken: loginPair.RefreshToken})
	assertAppErrorCode(t, err, apperror.CodeAuthRefreshInvalid)

	principal, err := service.Authenticate(context.Background(), refreshed.AccessToken)
	if err != nil {
		t.Fatalf("Authenticate(refreshed) error = %v", err)
	}
	if err := service.Logout(context.Background(), *principal); err != nil {
		t.Fatalf("Logout() error = %v", err)
	}
	_, err = service.Refresh(context.Background(), RefreshRequest{RefreshToken: refreshed.RefreshToken})
	assertAppErrorCode(t, err, apperror.CodeAuthRefreshInvalid)
}

func TestServiceMeReturnsUserAndGroupSummary(t *testing.T) {
	repo := newFakeIdentityRepository()
	groupID := uint64(77)
	user := repo.addUser(User{
		Username: "me-user", PasswordHash: "hash:secret", DisplayName: "Me",
		AccountType: AccountTypeMember, Status: UserStatusActive,
	}, AccessState{
		GroupID: &groupID, GroupName: "Finance", AccountType: AccountTypeMember, MemberType: "member",
		UserStatus: UserStatusActive, GroupStatus: "active", MembershipStatus: "active",
	})
	service, _ := newIdentityTestService(t, repo)

	got, err := service.Me(context.Background(), Principal{UserID: user.ID, GroupID: &groupID, AccountType: AccountTypeMember})
	if err != nil {
		t.Fatalf("Me() error = %v", err)
	}
	if got.User.ID != user.ID || got.User.Username != user.Username || got.Group == nil || got.Group.ID != groupID || got.Group.Name != "Finance" {
		t.Fatalf("Me() = %+v", got)
	}
	if got.MemberType == nil || *got.MemberType != "member" {
		t.Fatalf("Me() member_type = %v", got.MemberType)
	}
}

func TestServiceBootstrapsPlatformAdminWithHashedForcedChangePassword(t *testing.T) {
	repo := newFakeIdentityRepository()
	service, _ := newIdentityTestService(t, repo)

	created, err := service.BootstrapPlatformAdmin(context.Background(), " bootstrap-admin ", "temporary-password")
	if err != nil || !created {
		t.Fatalf("BootstrapPlatformAdmin(first) = (%v, %v)", created, err)
	}
	admin, err := repo.FindUserByUsername(context.Background(), "bootstrap-admin")
	if err != nil {
		t.Fatalf("FindUserByUsername() error = %v", err)
	}
	if admin.PasswordHash != "hash:temporary-password" || !admin.MustChangePassword || admin.AccountType != AccountTypePlatformAdmin {
		t.Fatalf("bootstrapped admin = %+v", admin)
	}
	created, err = service.BootstrapPlatformAdmin(context.Background(), "ignored", "must-not-overwrite")
	if err != nil || created {
		t.Fatalf("BootstrapPlatformAdmin(second) = (%v, %v), want (false, nil)", created, err)
	}
	admin, _ = repo.FindUserByUsername(context.Background(), "bootstrap-admin")
	if admin.PasswordHash != "hash:temporary-password" {
		t.Fatalf("existing bootstrap password overwritten: %+v", admin)
	}
}

func newIdentityTestService(t *testing.T, repo Repository) (*Service, time.Time) {
	t.Helper()
	tokens, err := jwtmanager.NewManager("test-secret-at-least-32-bytes-long", "identity-test", 15*time.Minute)
	if err != nil {
		t.Fatalf("NewManager() error = %v", err)
	}
	now := time.Now().UTC().Truncate(time.Second)
	service := NewService(repo, fakePasswordManager{}, tokens, 15*time.Minute, 7*24*time.Hour)
	service.now = func() time.Time { return now }
	return service, now
}

type fakePasswordManager struct{}

func (fakePasswordManager) Hash(plain string) (string, error) { return "hash:" + plain, nil }
func (fakePasswordManager) Verify(hash, plain string) bool    { return hash == "hash:"+plain }

type fakeIdentityRepository struct {
	mu                 sync.Mutex
	nextUserID         uint64
	nextSessionID      uint64
	users              map[uint64]User
	usernames          map[string]uint64
	states             map[uint64]AccessState
	sessions           map[string]RefreshSession
	lastCreatedSession *RefreshSession
}

func newFakeIdentityRepository() *fakeIdentityRepository {
	return &fakeIdentityRepository{
		nextUserID: 1, nextSessionID: 1,
		users: make(map[uint64]User), usernames: make(map[string]uint64),
		states: make(map[uint64]AccessState), sessions: make(map[string]RefreshSession),
	}
}

func (r *fakeIdentityRepository) addUser(user User, state AccessState) User {
	r.mu.Lock()
	defer r.mu.Unlock()
	if user.ID == 0 {
		user.ID = r.nextUserID
		r.nextUserID++
	}
	state.UserID = user.ID
	state.AccountType = user.AccountType
	state.UserStatus = user.Status
	state.MustChangePassword = user.MustChangePassword
	r.users[user.ID] = user
	r.usernames[user.Username] = user.ID
	r.states[user.ID] = state
	return user
}

func (r *fakeIdentityRepository) FindUserByUsername(_ context.Context, username string) (*User, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	id, ok := r.usernames[username]
	if !ok {
		return nil, ErrUserNotFound
	}
	user := r.users[id]
	return &user, nil
}

func (r *fakeIdentityRepository) FindUserByID(_ context.Context, userID uint64) (*User, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	user, ok := r.users[userID]
	if !ok {
		return nil, ErrUserNotFound
	}
	return &user, nil
}

func (r *fakeIdentityRepository) GetAccessState(_ context.Context, userID uint64) (AccessState, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	state, ok := r.states[userID]
	if !ok {
		return AccessState{}, ErrUserNotFound
	}
	if state.UserStatus != UserStatusActive {
		return AccessState{}, ErrAccessInactive
	}
	if state.AccountType != AccountTypePlatformAdmin && (state.GroupID == nil || state.GroupStatus != "active" || state.MembershipStatus != "active") {
		return AccessState{}, ErrAccessInactive
	}
	return state, nil
}

func (r *fakeIdentityRepository) CreateRefreshSession(_ context.Context, session *RefreshSession) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	if _, exists := r.sessions[session.TokenHash]; exists {
		return ErrRefreshInvalid
	}
	created := *session
	created.ID = r.nextSessionID
	r.nextSessionID++
	r.sessions[created.TokenHash] = created
	*session = created
	r.lastCreatedSession = cloneRefreshSession(&created)
	return nil
}

func (r *fakeIdentityRepository) RotateRefreshSession(_ context.Context, oldTokenHash string, replacement *RefreshSession, now time.Time) (*RefreshSession, AccessState, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	old, ok := r.sessions[oldTokenHash]
	if !ok || old.RevokedAt != nil || old.ReplacedBySessionID != nil || !old.ExpiresAt.After(now) {
		return nil, AccessState{}, ErrRefreshInvalid
	}
	state, ok := r.states[old.UserID]
	if !ok || state.UserStatus != UserStatusActive || (state.AccountType != AccountTypePlatformAdmin && (state.GroupStatus != "active" || state.MembershipStatus != "active")) {
		return nil, AccessState{}, ErrAccessInactive
	}
	created := *replacement
	created.ID = r.nextSessionID
	r.nextSessionID++
	created.UserID = old.UserID
	created.GroupID = cloneOptionalID(old.GroupID)
	r.sessions[created.TokenHash] = created
	old.RevokedAt = &now
	old.LastUsedAt = &now
	old.ReplacedBySessionID = &created.ID
	r.sessions[oldTokenHash] = old
	return cloneRefreshSession(&created), state, nil
}

func (r *fakeIdentityRepository) RevokeRefreshSession(_ context.Context, userID, sessionID uint64, now time.Time) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	for hash, session := range r.sessions {
		if session.ID == sessionID && session.UserID == userID && session.RevokedAt == nil {
			session.RevokedAt = &now
			session.LastUsedAt = &now
			r.sessions[hash] = session
			return nil
		}
	}
	return ErrRefreshInvalid
}

func (r *fakeIdentityRepository) ChangePassword(_ context.Context, userID uint64, expectedOldHash, newHash string, _ time.Time) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	user, ok := r.users[userID]
	if !ok {
		return ErrUserNotFound
	}
	if user.PasswordHash != expectedOldHash {
		return ErrPasswordHashMismatch
	}
	user.PasswordHash = newHash
	user.MustChangePassword = false
	r.users[userID] = user
	state := r.states[userID]
	state.MustChangePassword = false
	r.states[userID] = state
	return nil
}

func (r *fakeIdentityRepository) BootstrapPlatformAdmin(_ context.Context, admin *User, _ time.Time) (bool, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	for _, user := range r.users {
		if user.AccountType == AccountTypePlatformAdmin {
			return false, nil
		}
	}
	if _, exists := r.usernames[admin.Username]; exists {
		return false, ErrUsernameConflict
	}
	created := *admin
	created.ID = r.nextUserID
	r.nextUserID++
	r.users[created.ID] = created
	r.usernames[created.Username] = created.ID
	r.states[created.ID] = AccessState{UserID: created.ID, AccountType: created.AccountType, UserStatus: created.Status, MustChangePassword: created.MustChangePassword}
	*admin = created
	return true, nil
}

func cloneRefreshSession(session *RefreshSession) *RefreshSession {
	if session == nil {
		return nil
	}
	copySession := *session
	copySession.GroupID = cloneOptionalID(session.GroupID)
	return &copySession
}

func sha256HexForTest(value string) string {
	sum := sha256.Sum256([]byte(value))
	return hex.EncodeToString(sum[:])
}

func assertAppErrorCode(t *testing.T, err error, code string) {
	t.Helper()
	if err == nil {
		t.Fatalf("error = nil, want application error %s", code)
	}
	var appErr *apperror.Error
	if !errors.As(err, &appErr) || appErr.Code != code {
		t.Fatalf("error = %v, want application error %s", err, code)
	}
}
