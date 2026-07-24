package member

import (
	"context"
	"errors"
	"fmt"
	"sort"
	"time"

	"CBizDocsManager/backend/internal/authorization"
	"CBizDocsManager/backend/internal/identity"
	"CBizDocsManager/backend/internal/organization"
	"CBizDocsManager/backend/pkg/apperror"
)

var (
	ErrNotFound        = errors.New("membership not found")
	ErrVersionConflict = errors.New("membership version conflict")
)

type Repository interface {
	List(ctx context.Context, groupID uint64, query ListQuery) (Page, error)
	Find(ctx context.Context, groupID, membershipID uint64) (Member, error)
	GetPermissions(ctx context.Context, groupID, membershipID uint64) (PermissionSet, error)
	ChangeStatus(ctx context.Context, groupID, membershipID, operatorUserID, version uint64, status organization.MembershipStatus, now time.Time) (Member, error)
	ReplacePermissions(ctx context.Context, groupID, membershipID, operatorUserID, version uint64, codes []authorization.Code, now time.Time) (PermissionSet, error)
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
	groupID, err := requirePrincipalGroup(principal)
	if err != nil {
		return Page{}, err
	}
	if err := s.authorizer.Require(ctx, principal, groupID, authorization.PermissionMemberManage); err != nil {
		return Page{}, err
	}
	if query.Page == 0 {
		query.Page = 1
	}
	if query.PageSize == 0 {
		query.PageSize = 20
	}
	if query.Page < 1 || query.PageSize < 1 || query.PageSize > 100 {
		return Page{}, apperror.ErrValidationFailed
	}
	page, err := s.repo.List(ctx, groupID, query)
	if err != nil {
		return Page{}, memberInternalError("list members", err)
	}
	return page, nil
}

func (s *Service) ChangeStatus(ctx context.Context, principal identity.Principal, membershipID uint64, req ChangeStatusRequest) (Member, error) {
	groupID, err := requirePrincipalGroup(principal)
	if err != nil {
		return Member{}, err
	}
	if err := s.authorizer.Require(ctx, principal, groupID, authorization.PermissionMemberManage); err != nil {
		return Member{}, err
	}
	target, err := s.repo.Find(ctx, groupID, membershipID)
	if err != nil {
		return Member{}, mapRepositoryError("find status target", err)
	}
	if target.MemberType == organization.MemberTypeOwner {
		return Member{}, apperror.ErrMemberOwnerProtected
	}
	if target.User.ID == principal.UserID {
		return Member{}, apperror.ErrMemberSelfForbidden
	}
	if req.Version == 0 || !validStatusTransition(target.Status, req.Status) {
		return Member{}, apperror.ErrValidationFailed
	}
	if req.Version != target.Version {
		return Member{}, apperror.ErrResourceVersionConflict
	}
	if target.Status == req.Status {
		return target, nil
	}
	result, err := s.repo.ChangeStatus(ctx, groupID, membershipID, principal.UserID, req.Version, req.Status, s.now().UTC())
	if err != nil {
		return Member{}, mapRepositoryError("change member status", err)
	}
	return result, nil
}

func (s *Service) GetPermissions(ctx context.Context, principal identity.Principal, membershipID uint64) (PermissionSet, error) {
	groupID, err := requirePrincipalGroup(principal)
	if err != nil {
		return PermissionSet{}, err
	}
	if err := s.authorizer.Require(ctx, principal, groupID, authorization.PermissionMemberManage); err != nil {
		return PermissionSet{}, err
	}
	result, err := s.repo.GetPermissions(ctx, groupID, membershipID)
	if err != nil {
		return PermissionSet{}, mapRepositoryError("get member permissions", err)
	}
	return result, nil
}

func (s *Service) ReplacePermissions(ctx context.Context, principal identity.Principal, membershipID uint64, req ReplacePermissionsRequest) (PermissionSet, error) {
	groupID, err := requirePrincipalGroup(principal)
	if err != nil {
		return PermissionSet{}, err
	}
	// 授权是 owner 的固有职责，member.manage 不能升级为授权能力。
	if principal.AccountType != identity.AccountTypeGroupOwner || principal.MemberType != string(organization.MemberTypeOwner) {
		return PermissionSet{}, apperror.ErrForbidden
	}
	target, err := s.repo.Find(ctx, groupID, membershipID)
	if err != nil {
		return PermissionSet{}, mapRepositoryError("find permission target", err)
	}
	if target.MemberType == organization.MemberTypeOwner {
		return PermissionSet{}, apperror.ErrMemberOwnerProtected
	}
	if target.User.ID == principal.UserID {
		return PermissionSet{}, apperror.ErrMemberSelfForbidden
	}
	if target.Status == organization.MembershipStatusRemoved {
		return PermissionSet{}, apperror.ErrMemberNotFound
	}
	if req.Version == 0 {
		return PermissionSet{}, apperror.ErrValidationFailed
	}
	codes, err := normalizePermissionCodes(req.PermissionCodes)
	if err != nil {
		return PermissionSet{}, err
	}
	result, err := s.repo.ReplacePermissions(ctx, groupID, membershipID, principal.UserID, req.Version, codes, s.now().UTC())
	if err != nil {
		return PermissionSet{}, mapRepositoryError("replace member permissions", err)
	}
	return result, nil
}

func (s *Service) PermissionCatalog(_ context.Context, principal identity.Principal) ([]authorization.Code, error) {
	if _, err := requirePrincipalGroup(principal); err != nil {
		return nil, err
	}
	return authorization.Catalog(), nil
}

func validStatusTransition(current, next organization.MembershipStatus) bool {
	if current == next {
		return current != organization.MembershipStatusRemoved
	}
	if current == organization.MembershipStatusRemoved {
		return false
	}
	if next == organization.MembershipStatusRemoved {
		return true
	}
	return (current == organization.MembershipStatusActive && next == organization.MembershipStatusDisabled) ||
		(current == organization.MembershipStatusDisabled && next == organization.MembershipStatusActive)
}

func normalizePermissionCodes(codes []authorization.Code) ([]authorization.Code, error) {
	result := append([]authorization.Code(nil), codes...)
	for _, code := range result {
		if !authorization.IsKnown(code) {
			return nil, apperror.ErrPermissionCodeInvalid
		}
	}
	sort.Slice(result, func(i, j int) bool { return result[i] < result[j] })
	unique := result[:0]
	for _, code := range result {
		if len(unique) == 0 || unique[len(unique)-1] != code {
			unique = append(unique, code)
		}
	}
	return unique, nil
}

func requirePrincipalGroup(principal identity.Principal) (uint64, error) {
	if principal.GroupID == nil || principal.AccountType == identity.AccountTypePlatformAdmin {
		return 0, apperror.ErrForbidden
	}
	return *principal.GroupID, nil
}

func mapRepositoryError(operation string, err error) error {
	switch {
	case errors.Is(err, ErrNotFound):
		return apperror.ErrMemberNotFound
	case errors.Is(err, ErrVersionConflict):
		return apperror.ErrResourceVersionConflict
	default:
		return memberInternalError(operation, err)
	}
}

func memberInternalError(operation string, err error) error {
	return apperror.Wrap(apperror.ErrInternal, fmt.Errorf("%s: %w", operation, err))
}
