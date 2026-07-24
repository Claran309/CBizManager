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
	"CBizDocsManager/backend/pkg/apperror"
)

const defaultInvitationDays = 7

type Service struct {
	repo      Repository
	passwords identity.PasswordManager
	now       func() time.Time
}

func NewService(repo Repository, passwords identity.PasswordManager) *Service {
	return &Service{repo: repo, passwords: passwords, now: time.Now}
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
	invitation, err := s.repo.CreateInvitation(ctx, CreateInvitationInput{
		GroupID: *principal.GroupID, CreatedBy: principal.UserID,
		CodeHash: hashInvitationCode(rawCode), ExpiresAt: expiresAt, Now: now,
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
