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
	// PermissionFinanceRecord 允许登记与撤销付款 / 收款 / 开票记录。
	// 「登记」与「撤销」共用同一个权限码：只给登记权限会导致录错后无法纠正，
	// 反而逼着人去找有全权限的账号代劳，审计上更糟。
	PermissionFinanceRecord Code = "finance.record"
)

var catalog = [...]Code{
	PermissionDocumentViewOthers,
	PermissionDocumentEditOthers,
	PermissionReportView,
	PermissionMemberManage,
	PermissionDictionaryManage,
	PermissionSettlementApprove,
	PermissionFinanceRecord,
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
