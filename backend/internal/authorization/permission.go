package authorization

import (
	"context"
	"fmt"

	"CBizDocsManager/backend/internal/identity"
	"CBizDocsManager/backend/pkg/apperror"
)

// Code 是后端唯一认可的权限标识。客户端只能从 Catalog 返回的固定集合中选择。
type Code string

const (
	PermissionDocumentViewOthers Code = "document.view_others"
	PermissionDocumentEditOthers Code = "document.edit_others"
	PermissionReportView         Code = "report.view"
	PermissionMemberManage       Code = "member.manage"
	PermissionDictionaryManage   Code = "dictionary.manage"
	PermissionSettlementApprove  Code = "settlement.approve"
)

var catalog = [...]Code{
	PermissionDocumentViewOthers,
	PermissionDocumentEditOthers,
	PermissionReportView,
	PermissionMemberManage,
	PermissionDictionaryManage,
	PermissionSettlementApprove,
}

// Catalog 返回独立切片，防止调用方修改后端保存的权限注册表。
func Catalog() []Code {
	result := make([]Code, len(catalog))
	copy(result, catalog[:])
	return result
}

func IsKnown(code Code) bool {
	for _, registered := range catalog {
		if registered == code {
			return true
		}
	}
	return false
}

type Authorizer interface {
	Require(ctx context.Context, principal identity.Principal, groupID uint64, code Code) error
}

type authorizer struct {
	repo Repository
}

func NewAuthorizer(repo Repository) Authorizer {
	return &authorizer{repo: repo}
}

func (a *authorizer) Require(ctx context.Context, principal identity.Principal, groupID uint64, code Code) error {
	if !IsKnown(code) {
		return apperror.ErrPermissionCodeInvalid
	}
	if principal.GroupID == nil || *principal.GroupID != groupID {
		return apperror.ErrForbidden
	}

	// owner 的全权限来自成员类型而不是权限表，避免把隐式规则复制成多条持久化记录。
	if principal.AccountType == identity.AccountTypeGroupOwner && principal.MemberType == "owner" {
		return nil
	}
	if principal.AccountType != identity.AccountTypeMember || principal.MemberType != "member" {
		return apperror.ErrForbidden
	}

	allowed, err := a.repo.HasPermission(ctx, principal.UserID, groupID, code)
	if err != nil {
		return apperror.Wrap(apperror.ErrInternal, fmt.Errorf("check permission %q: %w", code, err))
	}
	if !allowed {
		return apperror.ErrForbidden
	}
	return nil
}
