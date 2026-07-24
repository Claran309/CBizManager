package platform

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"time"

	"CBizDocsManager/backend/internal/identity"
	"CBizDocsManager/backend/pkg/apperror"
)

type Service struct {
	repo      Repository
	passwords identity.PasswordManager
	now       func() time.Time
}

func NewService(repo Repository, passwords identity.PasswordManager) *Service {
	return &Service{repo: repo, passwords: passwords, now: time.Now}
}

func (s *Service) CreateGroup(ctx context.Context, principal identity.Principal, req CreateGroupRequest) (*GroupCreatedData, error) {
	if principal.MustChangePassword {
		return nil, apperror.ErrAuthPasswordChangeRequired
	}
	if principal.AccountType != identity.AccountTypePlatformAdmin {
		return nil, apperror.ErrForbidden
	}
	groupName := strings.TrimSpace(req.Name)
	ownerUsername := strings.TrimSpace(req.OwnerUsername)
	ownerDisplayName := strings.TrimSpace(req.OwnerDisplayName)
	if groupName == "" || ownerUsername == "" || ownerDisplayName == "" || len(req.OwnerTemporaryPassword) < 8 {
		return nil, apperror.ErrValidationFailed
	}
	passwordHash, err := s.passwords.Hash(req.OwnerTemporaryPassword)
	if err != nil {
		return nil, platformInternalError("hash owner temporary password", err)
	}
	created, err := s.repo.CreateGroupWithOwner(ctx, CreateGroupInput{
		OperatorUserID: principal.UserID, GroupName: groupName,
		OwnerUsername: ownerUsername, OwnerPasswordHash: passwordHash, OwnerDisplayName: ownerDisplayName,
		Now: s.now().UTC(),
	})
	if errors.Is(err, ErrGroupNameConflict) {
		return nil, apperror.ErrGroupNameExists
	}
	if errors.Is(err, ErrUsernameConflict) {
		return nil, apperror.ErrUserUsernameExists
	}
	if err != nil {
		return nil, platformInternalError("create group with owner", err)
	}
	return &GroupCreatedData{
		Group: identity.GroupSummary{ID: created.Group.ID, Name: created.Group.Name},
		Owner: identity.UserSummary{
			ID: created.Owner.ID, Username: created.Owner.Username,
			DisplayName: created.Owner.DisplayName, AccountType: created.Owner.AccountType,
		},
	}, nil
}

func platformInternalError(operation string, err error) error {
	return apperror.Wrap(apperror.ErrInternal, fmt.Errorf("%s: %w", operation, err))
}
