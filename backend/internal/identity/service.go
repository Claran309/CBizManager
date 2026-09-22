package identity

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"strings"
	"time"

	"CBizDocsManager/backend/pkg/apperror"
	jwtmanager "CBizDocsManager/backend/pkg/jwt"
	passwordpkg "CBizDocsManager/backend/pkg/password"
)

type PasswordManager interface {
	Hash(plain string) (string, error)
	Verify(hash, plain string) bool
}

type bcryptPasswordManager struct{}

func NewPasswordManager() PasswordManager { return bcryptPasswordManager{} }

func (bcryptPasswordManager) Hash(plain string) (string, error) {
	return passwordpkg.Hash(plain)
}

func (bcryptPasswordManager) Verify(hash, plain string) bool {
	return passwordpkg.Verify(hash, plain)
}

type Service struct {
	repo       Repository
	passwords  PasswordManager
	tokens     *jwtmanager.Manager
	refreshTTL time.Duration
	now        func() time.Time
}

func NewService(repo Repository, passwords PasswordManager, tokens *jwtmanager.Manager, _ time.Duration, refreshTTL time.Duration) *Service {
	return &Service{
		repo: repo, passwords: passwords, tokens: tokens,
		refreshTTL: refreshTTL, now: time.Now,
	}
}

func (s *Service) Login(ctx context.Context, req LoginRequest) (*TokenPair, error) {
	user, err := s.repo.FindUserByUsername(ctx, strings.TrimSpace(req.Username))
	if errors.Is(err, ErrUserNotFound) {
		return nil, apperror.ErrAuthInvalidCredentials
	}
	if err != nil {
		return nil, internalServiceError("find login user", err)
	}
	if !s.passwords.Verify(user.PasswordHash, req.Password) {
		return nil, apperror.ErrAuthInvalidCredentials
	}
	state, err := s.repo.GetAccessState(ctx, user.ID)
	if errors.Is(err, ErrAccessInactive) || errors.Is(err, ErrUserNotFound) {
		return nil, apperror.ErrAuthInvalidCredentials
	}
	if err != nil {
		return nil, internalServiceError("load login access state", err)
	}

	now := s.now().UTC()
	rawRefresh, err := newRefreshToken()
	if err != nil {
		return nil, internalServiceError("generate refresh token", err)
	}
	session := &RefreshSession{
		UserID: user.ID, GroupID: cloneOptionalID(state.GroupID), TokenHash: hashRefreshToken(rawRefresh),
		ExpiresAt: now.Add(s.refreshTTL), CreatedAt: now,
	}
	if err := s.repo.CreateRefreshSession(ctx, session); err != nil {
		return nil, internalServiceError("create refresh session", err)
	}
	return s.signTokenPair(ctx, state, session, rawRefresh, now)
}

func (s *Service) Refresh(ctx context.Context, req RefreshRequest) (*TokenPair, error) {
	now := s.now().UTC()
	rawRefresh, err := newRefreshToken()
	if err != nil {
		return nil, internalServiceError("generate replacement refresh token", err)
	}
	replacement := &RefreshSession{
		TokenHash: hashRefreshToken(rawRefresh), ExpiresAt: now.Add(s.refreshTTL), CreatedAt: now,
	}
	created, state, err := s.repo.RotateRefreshSession(ctx, hashRefreshToken(strings.TrimSpace(req.RefreshToken)), replacement, now)
	if errors.Is(err, ErrRefreshInvalid) || errors.Is(err, ErrAccessInactive) || errors.Is(err, ErrUserNotFound) {
		return nil, apperror.ErrAuthRefreshInvalid
	}
	if err != nil {
		return nil, internalServiceError("rotate refresh session", err)
	}
	return s.signTokenPair(ctx, state, created, rawRefresh, now)
}

func (s *Service) Logout(ctx context.Context, principal Principal) error {
	err := s.repo.RevokeRefreshSession(ctx, principal.UserID, principal.SessionID, s.now().UTC())
	if errors.Is(err, ErrRefreshInvalid) {
		return apperror.ErrAuthTokenExpired
	}
	if err != nil {
		return internalServiceError("revoke refresh session", err)
	}
	return nil
}

func (s *Service) LogoutRefresh(ctx context.Context, rawRefreshToken string) error {
	rawRefreshToken = strings.TrimSpace(rawRefreshToken)
	if rawRefreshToken == "" {
		return apperror.ErrAuthRefreshInvalid
	}
	err := s.repo.RevokeRefreshToken(ctx, hashRefreshToken(rawRefreshToken), s.now().UTC())
	if errors.Is(err, ErrRefreshInvalid) {
		return apperror.ErrAuthRefreshInvalid
	}
	if err != nil {
		return internalServiceError("revoke refresh token", err)
	}
	return nil
}

func (s *Service) Me(ctx context.Context, principal Principal) (*MeResponse, error) {
	user, err := s.repo.FindUserByID(ctx, principal.UserID)
	if errors.Is(err, ErrUserNotFound) {
		return nil, apperror.ErrAuthTokenExpired
	}
	if err != nil {
		return nil, internalServiceError("load current user", err)
	}
	state, err := s.repo.GetAccessState(ctx, principal.UserID)
	if errors.Is(err, ErrAccessInactive) || errors.Is(err, ErrUserNotFound) {
		return nil, apperror.ErrAuthTokenExpired
	}
	if err != nil {
		return nil, internalServiceError("load current access state", err)
	}

	result := &MeResponse{
		User: UserSummary{
			ID: user.ID, Username: user.Username, DisplayName: user.DisplayName, AccountType: state.AccountType,
		},
		MustChangePassword: state.MustChangePassword,
		PermissionCodes:    []string{},
	}
	if state.GroupID != nil {
		result.Group = &GroupSummary{ID: *state.GroupID, Name: state.GroupName}
	}
	if state.MemberType != "" {
		memberType := state.MemberType
		result.MemberType = &memberType
	}
	// 只有普通成员需要逐条下发权限码；平台管理员与主账号的权限来自角色本身，
	// 保持空数组可以让客户端用「数组是否为空」这一条规则统一判断，而不是靠角色分叉。
	if state.AccountType == AccountTypeMember && state.GroupID != nil {
		codes, err := s.repo.ListPermissionCodes(ctx, *state.GroupID, user.ID)
		if err != nil {
			return nil, internalServiceError("list current permission codes", err)
		}
		if codes != nil {
			result.PermissionCodes = codes
		}
	}
	return result, nil
}

func (s *Service) ChangePassword(ctx context.Context, principal Principal, req ChangePasswordRequest) error {
	user, err := s.repo.FindUserByID(ctx, principal.UserID)
	if errors.Is(err, ErrUserNotFound) {
		return apperror.ErrAuthTokenExpired
	}
	if err != nil {
		return internalServiceError("load password user", err)
	}
	if !s.passwords.Verify(user.PasswordHash, req.CurrentPassword) {
		return apperror.ErrAuthInvalidCredentials
	}
	newHash, err := s.passwords.Hash(req.NewPassword)
	if err != nil {
		return internalServiceError("hash new password", err)
	}
	err = s.repo.ChangePassword(ctx, user.ID, user.PasswordHash, newHash, s.now().UTC())
	if errors.Is(err, ErrPasswordHashMismatch) {
		return apperror.ErrAuthInvalidCredentials
	}
	if err != nil {
		return internalServiceError("change password", err)
	}
	return nil
}

func (s *Service) Authenticate(ctx context.Context, rawAccessToken string) (*Principal, error) {
	claims, err := s.tokens.Parse(strings.TrimSpace(rawAccessToken))
	if err != nil || claims.UserID == 0 || claims.SessionID == 0 {
		return nil, apperror.ErrAuthTokenExpired
	}
	state, err := s.repo.GetAccessState(ctx, claims.UserID)
	if errors.Is(err, ErrAccessInactive) || errors.Is(err, ErrUserNotFound) {
		return nil, apperror.ErrAuthTokenExpired
	}
	if err != nil {
		return nil, internalServiceError("authenticate access state", err)
	}
	if string(state.AccountType) != claims.AccountType || !sameOptionalID(state.GroupID, claims.GroupID) {
		return nil, apperror.ErrAuthTokenExpired
	}
	return &Principal{
		UserID: state.UserID, GroupID: cloneOptionalID(state.GroupID), GroupName: state.GroupName, AccountType: state.AccountType,
		MemberType: state.MemberType, MustChangePassword: state.MustChangePassword, SessionID: claims.SessionID,
	}, nil
}

func (s *Service) BootstrapPlatformAdmin(ctx context.Context, username, plainPassword string) (bool, error) {
	hash, err := s.passwords.Hash(plainPassword)
	if err != nil {
		return false, internalServiceError("hash bootstrap password", err)
	}
	username = strings.TrimSpace(username)
	admin := &User{
		Username: username, PasswordHash: hash, DisplayName: username,
		AccountType: AccountTypePlatformAdmin, Status: UserStatusActive, MustChangePassword: true,
	}
	created, err := s.repo.BootstrapPlatformAdmin(ctx, admin, s.now().UTC())
	if errors.Is(err, ErrUsernameConflict) {
		return false, apperror.ErrUserUsernameExists
	}
	if err != nil {
		return false, internalServiceError("bootstrap platform admin", err)
	}
	return created, nil
}

func (s *Service) signTokenPair(ctx context.Context, state AccessState, session *RefreshSession, rawRefresh string, now time.Time) (*TokenPair, error) {
	accessToken, accessExpiresAt, err := s.tokens.Sign(jwtmanager.Claims{
		UserID: state.UserID, GroupID: cloneOptionalID(state.GroupID), AccountType: string(state.AccountType), SessionID: session.ID,
	}, now)
	if err != nil {
		_ = s.repo.RevokeRefreshSession(ctx, state.UserID, session.ID, now)
		return nil, internalServiceError("sign access token", err)
	}
	return &TokenPair{
		AccessToken: accessToken, RefreshToken: rawRefresh,
		AccessExpiresAt: accessExpiresAt, RefreshExpiresAt: session.ExpiresAt,
	}, nil
}

func newRefreshToken() (string, error) {
	bytes := make([]byte, 32)
	if _, err := rand.Read(bytes); err != nil {
		return "", err
	}
	return base64.RawURLEncoding.EncodeToString(bytes), nil
}

func hashRefreshToken(raw string) string {
	sum := sha256.Sum256([]byte(raw))
	return hex.EncodeToString(sum[:])
}

func internalServiceError(operation string, err error) error {
	return apperror.Wrap(apperror.ErrInternal, fmt.Errorf("%s: %w", operation, err))
}
