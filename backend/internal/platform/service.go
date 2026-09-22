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

// requirePlatformAdmin 是所有平台治理能力的统一前置校验：
// 必须已改密（临时密码账号不允许做治理动作），且账号类型为平台管理员。
func requirePlatformAdmin(principal identity.Principal) error {
	if principal.MustChangePassword {
		return apperror.ErrAuthPasswordChangeRequired
	}
	if principal.AccountType != identity.AccountTypePlatformAdmin {
		return apperror.ErrForbidden
	}
	return nil
}

// ListGroups 返回平台侧的组分页列表，支持按状态与组名关键字过滤。
func (s *Service) ListGroups(ctx context.Context, principal identity.Principal, query GroupQuery) (*GroupPageData, error) {
	if err := requirePlatformAdmin(principal); err != nil {
		return nil, err
	}
	page, pageSize := query.Page, query.PageSize
	if page < 1 {
		page = 1
	}
	if pageSize < 1 || pageSize > 100 {
		pageSize = 20
	}
	items, total, err := s.repo.ListGroups(ctx, GroupQuery{
		Page: page, PageSize: pageSize, Status: query.Status, Keyword: strings.TrimSpace(query.Keyword),
	})
	if err != nil {
		return nil, platformInternalError("list groups", err)
	}
	if items == nil {
		items = make([]GroupSummaryData, 0)
	}
	return &GroupPageData{Items: items, Page: page, PageSize: pageSize, Total: total}, nil
}

// GetGroupDetail 返回单个组的治理详情：成员状态分布 + 可作为新主账号的候选成员。
func (s *Service) GetGroupDetail(ctx context.Context, principal identity.Principal, groupID uint64) (*GroupDetailData, error) {
	if err := requirePlatformAdmin(principal); err != nil {
		return nil, err
	}
	if groupID == 0 {
		return nil, apperror.ErrValidationFailed
	}
	detail, err := s.repo.GetGroupDetail(ctx, groupID)
	if errors.Is(err, ErrGroupMissing) {
		return nil, apperror.ErrGroupNotFound
	}
	if err != nil {
		return nil, platformInternalError("get group detail", err)
	}
	if detail.OwnerCandidates == nil {
		detail.OwnerCandidates = make([]OwnerCandidateData, 0)
	}
	return detail, nil
}

// ChangeGroupStatus 停用 / 启用业务组。
//
// 采用「显式版本号 + 幂等」语义：
//   - 目标状态与当前一致 → 直接返回当前摘要，不报冲突（重复点击不会出错）；
//   - 版本号不匹配 → 返回资源版本冲突，提示前端刷新后重试；
//   - 停用组会连带撤销该组所有刷新会话，已在线的成员下次续期即失效。
func (s *Service) ChangeGroupStatus(ctx context.Context, principal identity.Principal, groupID uint64, req ChangeGroupStatusRequest) (*GroupSummaryData, error) {
	if err := requirePlatformAdmin(principal); err != nil {
		return nil, err
	}
	if groupID == 0 || req.Version == 0 {
		return nil, apperror.ErrValidationFailed
	}
	result, err := s.repo.ChangeGroupStatus(ctx, ChangeGroupStatusInput{
		GroupID: groupID, Status: req.Status, ExpectedVersion: req.Version,
		OperatorUserID: principal.UserID, Now: s.now().UTC(),
	})
	if errors.Is(err, ErrGroupMissing) {
		return nil, apperror.ErrGroupNotFound
	}
	if errors.Is(err, ErrVersionConflict) {
		return nil, apperror.ErrResourceVersionConflict
	}
	if errors.Is(err, ErrGroupStatusInvalid) {
		return nil, apperror.ErrValidationFailed
	}
	if err != nil {
		return nil, platformInternalError("change group status", err)
	}
	return result, nil
}

// ChangeGroupOwner 完成主账号交接，支持「把现有成员提升为主账号」与「新建账号并设为主账号」两种模式。
func (s *Service) ChangeGroupOwner(ctx context.Context, principal identity.Principal, groupID uint64, req ChangeGroupOwnerRequest) (*OwnerChangedData, error) {
	if err := requirePlatformAdmin(principal); err != nil {
		return nil, err
	}
	if groupID == 0 || req.Version == 0 {
		return nil, apperror.ErrValidationFailed
	}

	input := ChangeOwnerInput{
		GroupID: groupID, Mode: req.Mode, ExpectedVersion: req.Version,
		OperatorUserID: principal.UserID, Now: s.now().UTC(),
	}
	switch req.Mode {
	case ChangeOwnerExistingMember:
		// 从现有成员交接：必须给出成员关系 ID，其余账号字段一律忽略，防止张冠李戴。
		if req.MembershipID == nil || *req.MembershipID == 0 {
			return nil, apperror.ErrValidationFailed
		}
		input.MembershipID = req.MembershipID
	case ChangeOwnerNewAccount:
		// 新建账号交接：用户名 / 展示名 / 初始密码三者必填，密码沿用组主账号的最低长度要求。
		username := strings.TrimSpace(derefString(req.Username))
		displayName := strings.TrimSpace(derefString(req.DisplayName))
		password := derefString(req.TemporaryPassword)
		if username == "" || displayName == "" || len(password) < 8 {
			return nil, apperror.ErrValidationFailed
		}
		passwordHash, err := s.passwords.Hash(password)
		if err != nil {
			return nil, platformInternalError("hash new owner password", err)
		}
		input.Username, input.DisplayName, input.PasswordHash = username, displayName, passwordHash
	default:
		return nil, apperror.ErrValidationFailed
	}

	change, err := s.repo.ChangeOwner(ctx, input)
	switch {
	case errors.Is(err, ErrGroupMissing):
		return nil, apperror.ErrGroupNotFound
	case errors.Is(err, ErrVersionConflict):
		return nil, apperror.ErrResourceVersionConflict
	case errors.Is(err, ErrUsernameConflict):
		return nil, apperror.ErrUserUsernameExists
	case errors.Is(err, ErrOwnerTargetInvalid), errors.Is(err, ErrOwnerTargetForbidden):
		return nil, apperror.ErrOwnerTargetInvalid
	case err != nil:
		return nil, platformInternalError("change group owner", err)
	}
	summary, err := s.repo.GetGroupDetail(ctx, groupID)
	if err != nil {
		return nil, platformInternalError("reload group after owner change", err)
	}
	return &OwnerChangedData{
		Group: summary.Group,
		Owner: identity.UserSummary{
			ID: change.NewOwner.ID, Username: change.NewOwner.Username,
			DisplayName: change.NewOwner.DisplayName, AccountType: change.NewOwner.AccountType,
		},
	}, nil
}

// derefString 安全解引用可空字符串字段，nil 视为空字符串，避免上层到处写判空。
func derefString(value *string) string {
	if value == nil {
		return ""
	}
	return *value
}
