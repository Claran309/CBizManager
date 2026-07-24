package dictionary

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"time"

	"CBizDocsManager/backend/internal/authorization"
	"CBizDocsManager/backend/internal/identity"
	"CBizDocsManager/backend/pkg/apperror"
)

var (
	ErrNotFound        = errors.New("dictionary entry not found")
	ErrNameExists      = errors.New("dictionary name exists")
	ErrParentInvalid   = errors.New("dictionary parent invalid")
	ErrVersionConflict = errors.New("dictionary version conflict")
)

type Repository interface {
	List(ctx context.Context, groupID uint64, query ListQuery) (Page, error)
	Find(ctx context.Context, groupID, id uint64) (Entry, error)
	Create(ctx context.Context, groupID, userID uint64, draft Draft, now time.Time) (Entry, error)
	Update(ctx context.Context, groupID, id, userID uint64, version uint64, draft Draft, now time.Time) (Entry, error)
	ChangeStatus(ctx context.Context, groupID, id, userID, version uint64, status Status, now time.Time) (Entry, error)
}

type Service struct {
	repo       Repository
	authorizer authorization.Authorizer
	now        func() time.Time
}

func NewService(repo Repository, authorizer authorization.Authorizer) *Service {
	return &Service{repo: repo, authorizer: authorizer, now: time.Now}
}

func (s *Service) List(ctx context.Context, principal identity.Principal, query ListQuery) (Page, error) {
	groupID, err := dictionaryGroup(principal)
	if err != nil {
		return Page{}, err
	}
	if query.Page == 0 {
		query.Page = 1
	}
	if query.PageSize == 0 {
		query.PageSize = 20
	}
	if query.Page < 1 || query.PageSize < 1 || query.PageSize > 100 || (query.Kind != nil && !knownKind(*query.Kind)) {
		return Page{}, apperror.ErrValidationFailed
	}
	if query.Status == nil {
		active := StatusActive
		query.Status = &active
	} else if *query.Status == StatusDisabled {
		if err := s.authorizer.Require(ctx, principal, groupID, authorization.PermissionDictionaryManage); err != nil {
			return Page{}, err
		}
	} else if *query.Status != StatusActive {
		return Page{}, apperror.ErrValidationFailed
	}
	query.Keyword = NormalizeName(query.Keyword)
	page, err := s.repo.List(ctx, groupID, query)
	if err != nil {
		return Page{}, dictionaryInternalError("list dictionaries", err)
	}
	return page, nil
}

func (s *Service) Create(ctx context.Context, principal identity.Principal, request CreateRequest) (Entry, error) {
	groupID, err := dictionaryGroup(principal)
	if err != nil {
		return Entry{}, err
	}
	if err := s.authorizer.Require(ctx, principal, groupID, authorization.PermissionDictionaryManage); err != nil {
		return Entry{}, err
	}
	draft := Draft{Kind: request.Kind, Name: strings.Join(strings.Fields(request.Name), " "), NormalizedName: NormalizeName(request.Name), ParentID: request.ParentID, ContactPhone: cleanPhone(request.ContactPhone)}
	if err := s.validateDraft(ctx, groupID, draft); err != nil {
		return Entry{}, err
	}
	result, err := s.repo.Create(ctx, groupID, principal.UserID, draft, s.now().UTC())
	if err != nil {
		return Entry{}, mapDictionaryError("create dictionary", err)
	}
	return result, nil
}

func (s *Service) Update(ctx context.Context, principal identity.Principal, id uint64, request UpdateRequest) (Entry, error) {
	groupID, err := dictionaryGroup(principal)
	if err != nil {
		return Entry{}, err
	}
	if err := s.authorizer.Require(ctx, principal, groupID, authorization.PermissionDictionaryManage); err != nil {
		return Entry{}, err
	}
	current, err := s.repo.Find(ctx, groupID, id)
	if err != nil {
		return Entry{}, mapDictionaryError("find dictionary", err)
	}
	if request.Version == 0 {
		return Entry{}, apperror.ErrValidationFailed
	}
	draft := Draft{Kind: current.Kind, Name: strings.Join(strings.Fields(request.Name), " "), NormalizedName: NormalizeName(request.Name), ParentID: request.ParentID, ContactPhone: cleanPhone(request.ContactPhone)}
	if err := s.validateDraft(ctx, groupID, draft); err != nil {
		return Entry{}, err
	}
	result, err := s.repo.Update(ctx, groupID, id, principal.UserID, request.Version, draft, s.now().UTC())
	if err != nil {
		return Entry{}, mapDictionaryError("update dictionary", err)
	}
	return result, nil
}

func (s *Service) ChangeStatus(ctx context.Context, principal identity.Principal, id uint64, request ChangeStatusRequest) (Entry, error) {
	groupID, err := dictionaryGroup(principal)
	if err != nil {
		return Entry{}, err
	}
	if err := s.authorizer.Require(ctx, principal, groupID, authorization.PermissionDictionaryManage); err != nil {
		return Entry{}, err
	}
	if request.Version == 0 || (request.Status != StatusActive && request.Status != StatusDisabled) {
		return Entry{}, apperror.ErrValidationFailed
	}
	result, err := s.repo.ChangeStatus(ctx, groupID, id, principal.UserID, request.Version, request.Status, s.now().UTC())
	if err != nil {
		return Entry{}, mapDictionaryError("change dictionary status", err)
	}
	return result, nil
}

func (s *Service) validateDraft(ctx context.Context, groupID uint64, draft Draft) error {
	if !knownKind(draft.Kind) || draft.NormalizedName == "" || len([]rune(draft.Name)) > 191 {
		return apperror.ErrValidationFailed
	}
	if draft.Kind == KindCustomer {
		if draft.ParentID != nil {
			return apperror.ErrDictionaryParentInvalid
		}
		return nil
	}
	if draft.ContactPhone != nil {
		return apperror.ErrValidationFailed
	}
	if draft.Kind != KindProductModel {
		if draft.ParentID != nil {
			return apperror.ErrDictionaryParentInvalid
		}
		return nil
	}
	if draft.ParentID == nil {
		return apperror.ErrDictionaryParentInvalid
	}
	parent, err := s.repo.Find(ctx, groupID, *draft.ParentID)
	if err != nil || parent.Kind != KindProductName || parent.Status != StatusActive {
		return apperror.ErrDictionaryParentInvalid
	}
	return nil
}

func knownKind(kind Kind) bool {
	switch kind {
	case KindSupplierCompany, KindCustomer, KindProductName, KindProductModel, KindUnit, KindShippingUnit:
		return true
	}
	return false
}
func cleanPhone(value *string) *string {
	if value == nil {
		return nil
	}
	cleaned := strings.TrimSpace(*value)
	if cleaned == "" {
		return nil
	}
	return &cleaned
}
func dictionaryGroup(principal identity.Principal) (uint64, error) {
	if principal.GroupID == nil || principal.AccountType == identity.AccountTypePlatformAdmin {
		return 0, apperror.ErrForbidden
	}
	return *principal.GroupID, nil
}
func mapDictionaryError(operation string, err error) error {
	switch {
	case errors.Is(err, ErrNotFound):
		return apperror.ErrDictionaryNotFound
	case errors.Is(err, ErrNameExists):
		return apperror.ErrDictionaryNameExists
	case errors.Is(err, ErrParentInvalid):
		return apperror.ErrDictionaryParentInvalid
	case errors.Is(err, ErrVersionConflict):
		return apperror.ErrResourceVersionConflict
	default:
		return dictionaryInternalError(operation, err)
	}
}
func dictionaryInternalError(operation string, err error) error {
	return apperror.Wrap(apperror.ErrInternal, fmt.Errorf("%s: %w", operation, err))
}
