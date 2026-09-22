package organization

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

	"CBizDocsManager/backend/internal/identity"
	"CBizDocsManager/backend/internal/infrastructure/cryptography"
	"CBizDocsManager/backend/pkg/apperror"
)

const defaultInvitationDays = 7

type Service struct {
	repo      Repository
	passwords identity.PasswordManager
	cipher    cryptography.InvitationCipher
	now       func() time.Time
}

func NewService(repo Repository, passwords identity.PasswordManager, ciphers ...cryptography.InvitationCipher) *Service {
	var cipher cryptography.InvitationCipher
	if len(ciphers) > 0 {
		cipher = ciphers[0]
	}
	return &Service{repo: repo, passwords: passwords, cipher: cipher, now: time.Now}
}

func (s *Service) CreateInvitation(ctx context.Context, principal identity.Principal, req CreateInvitationRequest) (*InvitationCreatedData, error) {
	if principal.MustChangePassword {
		return nil, apperror.ErrAuthPasswordChangeRequired
	}
	if principal.AccountType != identity.AccountTypeGroupOwner || principal.MemberType != "owner" || principal.GroupID == nil {
		return nil, apperror.ErrForbidden
	}
	days := req.ExpiresInDays
	if days == 0 {
		days = defaultInvitationDays
	}
	if days < 1 || days > 30 {
		return nil, apperror.ErrValidationFailed
	}
	rawCode, err := newInvitationCode()
	if err != nil {
		return nil, organizationInternalError("generate invitation code", err)
	}
	now := s.now().UTC()
	expiresAt := now.Add(time.Duration(days) * 24 * time.Hour)
	codeHash := hashInvitationCode(rawCode)
	var ciphertext, nonce []byte
	if s.cipher != nil {
		ciphertext, nonce, err = s.cipher.Encrypt(rawCode, *principal.GroupID, codeHash)
		if err != nil {
			return nil, organizationInternalError("encrypt invitation code", err)
		}
	}
	invitation, err := s.repo.CreateInvitation(ctx, CreateInvitationInput{
		GroupID: *principal.GroupID, CreatedBy: principal.UserID,
		CodeHash: codeHash, CodeCiphertext: ciphertext, CodeNonce: nonce, ExpiresAt: expiresAt, Now: now,
	})
	if err != nil {
		return nil, organizationInternalError("create invitation", err)
	}
	return &InvitationCreatedData{
		InvitationID: invitation.ID, InvitationCode: rawCode,
		Group:     identity.GroupSummary{ID: *principal.GroupID, Name: principal.GroupName},
		ExpiresAt: invitation.ExpiresAt,
	}, nil
}

func (s *Service) Register(ctx context.Context, req RegisterRequest) (*RegisterData, error) {
	invitationCode := strings.TrimSpace(req.InvitationCode)
	username := strings.TrimSpace(req.Username)
	displayName := strings.TrimSpace(req.DisplayName)
	if invitationCode == "" || username == "" || displayName == "" || len(req.Password) < 8 {
		return nil, apperror.ErrValidationFailed
	}
	passwordHash, err := s.passwords.Hash(req.Password)
	if err != nil {
		return nil, organizationInternalError("hash invited member password", err)
	}
	registration, err := s.repo.ConsumeInvitation(ctx, ConsumeInvitationInput{
		CodeHash: hashInvitationCode(invitationCode), Username: username,
		PasswordHash: passwordHash, DisplayName: displayName, Now: s.now().UTC(),
	})
	switch {
	case errors.Is(err, ErrInvitationInvalid), errors.Is(err, ErrGroupInactive):
		return nil, apperror.ErrInvitationInvalid
	case errors.Is(err, ErrInvitationExpired):
		return nil, apperror.ErrInvitationExpired
	case errors.Is(err, ErrInvitationUsed):
		return nil, apperror.ErrInvitationUsed
	case errors.Is(err, ErrUsernameConflict):
		return nil, apperror.ErrUserUsernameExists
	case err != nil:
		return nil, organizationInternalError("consume invitation", err)
	}
	return &RegisterData{
		User: identity.UserSummary{
			ID: registration.User.ID, Username: registration.User.Username,
			DisplayName: registration.User.DisplayName, AccountType: registration.User.AccountType,
		},
		Group: identity.GroupSummary{ID: registration.Group.ID, Name: registration.Group.Name},
	}, nil
}

func (s *Service) ListInvitations(ctx context.Context, principal identity.Principal, query InvitationQuery) (*InvitationPageData, error) {
	// 邀请码列表属于主账号的账号管理能力：必须已改密、且是租户 owner。
	if principal.MustChangePassword || principal.AccountType != identity.AccountTypeGroupOwner || principal.MemberType != "owner" || principal.GroupID == nil {
		return nil, apperror.ErrForbidden
	}
	page, pageSize := query.Page, query.PageSize
	if page < 1 {
		page = 1
	}
	if pageSize < 1 || pageSize > 100 {
		pageSize = 20
	}
	// Repository 直接返回带展示状态（含 expired 投影）的 DTO，Service 不再二次拼装字段，
	// 避免再次出现「实现返回实体、上层按 DTO 取字段」的错位。
	items, total, err := s.repo.ListInvitations(ctx, *principal.GroupID, InvitationQuery{Page: page, PageSize: pageSize, Status: query.Status}, s.now().UTC())
	if err != nil {
		return nil, organizationInternalError("list invitations", err)
	}
	return &InvitationPageData{Items: items, Page: page, PageSize: pageSize, Total: total}, nil
}

func (s *Service) RevealInvitation(ctx context.Context, principal identity.Principal, invitationID uint64) (*InvitationSecretData, error) {
	if principal.MustChangePassword || principal.AccountType != identity.AccountTypeGroupOwner || principal.MemberType != "owner" || principal.GroupID == nil {
		return nil, apperror.ErrForbidden
	}
	invitation, err := s.repo.GetRevealableInvitation(ctx, *principal.GroupID, invitationID, s.now().UTC())
	if errors.Is(err, ErrInvitationInvalid) {
		return nil, apperror.ErrInvitationNotRevealable
	}
	if err != nil {
		return nil, organizationInternalError("load invitation secret", err)
	}
	if s.cipher == nil {
		return nil, apperror.ErrInvitationDecryptFailed
	}
	plain, err := s.cipher.Decrypt(invitation.CodeCiphertext, invitation.CodeNonce, invitation.GroupID, invitation.CodeHash)
	if err != nil {
		return nil, apperror.ErrInvitationDecryptFailed
	}
	return &InvitationSecretData{InvitationID: invitation.ID, InvitationCode: plain, ExpiresAt: invitation.ExpiresAt}, nil
}

func (s *Service) RevokeInvitation(ctx context.Context, principal identity.Principal, invitationID uint64, req RevokeInvitationRequest) (*InvitationSummaryData, error) {
	if principal.MustChangePassword || principal.AccountType != identity.AccountTypeGroupOwner || principal.MemberType != "owner" || principal.GroupID == nil {
		return nil, apperror.ErrForbidden
	}
	invitation, err := s.repo.RevokeInvitation(ctx, RevokeInvitationInput{GroupID: *principal.GroupID, InvitationID: invitationID, ExpectedVersion: req.Version, OperatorUserID: principal.UserID, Now: s.now().UTC()})
	if errors.Is(err, ErrInvitationInvalid) {
		return nil, apperror.ErrInvitationNotFound
	}
	if errors.Is(err, ErrInvitationVersionConflict) {
		return nil, apperror.ErrResourceVersionConflict
	}
	if errors.Is(err, ErrInvitationConflict) {
		return nil, apperror.ErrInvitationNotRevokable
	}
	if err != nil {
		return nil, organizationInternalError("revoke invitation", err)
	}
	return &InvitationSummaryData{InvitationID: invitation.ID, Status: InvitationDisplayRevoked, ExpiresAt: invitation.ExpiresAt, UsedAt: invitation.UsedAt, RevokedAt: invitation.RevokedAt, CreatedAt: invitation.CreatedAt, Version: invitation.Version}, nil
}

func newInvitationCode() (string, error) {
	bytes := make([]byte, 32)
	if _, err := rand.Read(bytes); err != nil {
		return "", err
	}
	return base64.RawURLEncoding.EncodeToString(bytes), nil
}

func hashInvitationCode(raw string) string {
	sum := sha256.Sum256([]byte(raw))
	return hex.EncodeToString(sum[:])
}

func organizationInternalError(operation string, err error) error {
	return apperror.Wrap(apperror.ErrInternal, fmt.Errorf("%s: %w", operation, err))
}
