package apperror

import (
	stderrors "errors"
	"net/http"
)

const (
	CodeValidationFailed             = "VALIDATION_FAILED"
	CodeAuthInvalidCredentials       = "AUTH_INVALID_CREDENTIALS"
	CodeAuthTokenExpired             = "AUTH_TOKEN_EXPIRED"
	CodeAuthRefreshInvalid           = "AUTH_REFRESH_INVALID"
	CodeAuthPasswordChangeRequired   = "AUTH_PASSWORD_CHANGE_REQUIRED"
	CodeUserUsernameExists           = "USER_USERNAME_EXISTS"
	CodeInvitationInvalid            = "INVITATION_INVALID"
	CodeInvitationExpired            = "INVITATION_EXPIRED"
	CodeInvitationUsed               = "INVITATION_USED"
	CodeGroupNameExists              = "GROUP_NAME_EXISTS"
	CodeGroupNotFound                = "GROUP_NOT_FOUND"
	CodeGroupStatusInvalid           = "GROUP_STATUS_INVALID"
	CodeOwnerTargetInvalid           = "OWNER_TARGET_INVALID"
	CodeOwnerTargetForbidden         = "OWNER_TARGET_FORBIDDEN"
	CodeInvitationNotFound           = "INVITATION_NOT_FOUND"
	CodeInvitationNotRevealable      = "INVITATION_NOT_REVEALABLE"
	CodeInvitationNotRevokable       = "INVITATION_NOT_REVOKABLE"
	CodeInvitationDecryptFailed      = "INVITATION_DECRYPT_FAILED"
	CodeMemberNotFound               = "MEMBER_NOT_FOUND"
	CodeMemberOwnerProtected         = "MEMBER_OWNER_PROTECTED"
	CodeMemberSelfOperationForbidden = "MEMBER_SELF_OPERATION_FORBIDDEN"
	CodePermissionCodeInvalid        = "PERMISSION_CODE_INVALID"
	CodeDictionaryNotFound           = "DICTIONARY_NOT_FOUND"
	CodeDictionaryNameExists         = "DICTIONARY_NAME_EXISTS"
	CodeDictionaryParentInvalid      = "DICTIONARY_PARENT_INVALID"
	CodeDocumentNotFound             = "DOCUMENT_NOT_FOUND"
	CodeDocumentStatusInvalid        = "DOCUMENT_STATUS_INVALID"
	CodeDocumentIncomplete           = "DOCUMENT_INCOMPLETE"
	CodeIdempotencyKeyReused         = "IDEMPOTENCY_KEY_REUSED"
	CodeSettlementNotFound           = "SETTLEMENT_NOT_FOUND"
	CodeSettlementStatusInvalid      = "SETTLEMENT_STATUS_INVALID"
	CodeSettlementSourceInvalid      = "SETTLEMENT_SOURCE_INVALID"
	CodeSettlementSourceConflict     = "SETTLEMENT_SOURCE_CONFLICT"
	CodeSettlementRemarkRequired     = "SETTLEMENT_REMARK_REQUIRED"
	CodeFinanceRecordNotFound        = "FINANCE_RECORD_NOT_FOUND"
	CodeFinanceDocumentMismatch      = "FINANCE_DOCUMENT_MISMATCH"
	CodeFinanceAmountExceeds         = "FINANCE_AMOUNT_EXCEEDS"
	CodeReportSnapshotNotFound       = "REPORT_SNAPSHOT_NOT_FOUND"
	CodeReportPeriodEmpty            = "REPORT_PERIOD_EMPTY"
	CodeResourceVersionConflict      = "RESOURCE_VERSION_CONFLICT"
	CodeCSRFInvalid                  = "CSRF_INVALID"
	CodeOriginForbidden              = "ORIGIN_FORBIDDEN"
	CodeForbidden                    = "FORBIDDEN"
	CodeInternalError                = "INTERNAL_ERROR"
)

// Error 是跨 Handler、Service 与 Repository 传递的稳定业务错误。
type Error struct {
	Code       string
	Message    string
	HTTPStatus int
	Cause      error
}

// Error 返回可安全展示给客户端的错误消息。
func (e *Error) Error() string {
	if e == nil {
		return ""
	}
	if e.Message != "" {
		return e.Message
	}
	if e.Code != "" {
		return e.Code
	}
	return CodeInternalError
}

// Unwrap 让标准库 errors.Is/errors.As 能继续检查底层原因。
func (e *Error) Unwrap() error {
	if e == nil {
		return nil
	}
	return e.Cause
}

// New 创建一个不携带底层原因的业务错误。
func New(code, message string, httpStatus int) *Error {
	return &Error{Code: code, Message: message, HTTPStatus: httpStatus}
}

// Wrap 基于稳定业务错误创建新错误，并保留原始错误链。
func Wrap(base *Error, cause error) *Error {
	if base == nil {
		base = ErrInternal
	}
	return &Error{
		Code:       base.Code,
		Message:    base.Message,
		HTTPStatus: base.HTTPStatus,
		Cause:      cause,
	}
}

// As 提取错误链中的业务错误；未知错误统一降级为 INTERNAL_ERROR。
func As(err error) *Error {
	if err == nil {
		return nil
	}

	var appErr *Error
	if stderrors.As(err, &appErr) {
		return appErr
	}
	return Wrap(ErrInternal, err)
}

var (
	ErrValidationFailed = New(CodeValidationFailed, "请求参数校验失败", http.StatusBadRequest)

	ErrAuthInvalidCredentials     = New(CodeAuthInvalidCredentials, "用户名或密码错误", http.StatusUnauthorized)
	ErrAuthTokenExpired           = New(CodeAuthTokenExpired, "登录状态已过期", http.StatusUnauthorized)
	ErrAuthRefreshInvalid         = New(CodeAuthRefreshInvalid, "刷新令牌无效", http.StatusUnauthorized)
	ErrAuthPasswordChangeRequired = New(CodeAuthPasswordChangeRequired, "必须先修改初始密码", http.StatusForbidden)

	ErrUserUsernameExists = New(CodeUserUsernameExists, "用户名已存在", http.StatusConflict)

	ErrInvitationInvalid = New(CodeInvitationInvalid, "邀请码无效", http.StatusBadRequest)
	ErrInvitationExpired = New(CodeInvitationExpired, "邀请码已过期", http.StatusBadRequest)
	ErrInvitationUsed    = New(CodeInvitationUsed, "邀请码已使用", http.StatusBadRequest)

	ErrGroupNameExists         = New(CodeGroupNameExists, "组名已存在", http.StatusConflict)
	ErrGroupNotFound           = New(CodeGroupNotFound, "组不存在", http.StatusNotFound)
	ErrGroupStatusInvalid      = New(CodeGroupStatusInvalid, "组状态不允许执行此操作", http.StatusConflict)
	ErrOwnerTargetInvalid      = New(CodeOwnerTargetInvalid, "新主账号目标无效", http.StatusBadRequest)
	ErrOwnerTargetForbidden    = New(CodeOwnerTargetForbidden, "新主账号目标不允许交接", http.StatusConflict)
	ErrInvitationNotFound      = New(CodeInvitationNotFound, "邀请码不存在", http.StatusNotFound)
	ErrInvitationNotRevealable = New(CodeInvitationNotRevealable, "邀请码当前不可查看", http.StatusConflict)
	ErrInvitationNotRevokable  = New(CodeInvitationNotRevokable, "邀请码当前不可撤销", http.StatusConflict)
	ErrInvitationDecryptFailed = New(CodeInvitationDecryptFailed, "邀请码暂时无法查看", http.StatusInternalServerError)

	ErrMemberNotFound        = New(CodeMemberNotFound, "成员不存在", http.StatusNotFound)
	ErrMemberOwnerProtected  = New(CodeMemberOwnerProtected, "不能通过成员接口操作主账号", http.StatusForbidden)
	ErrMemberSelfForbidden   = New(CodeMemberSelfOperationForbidden, "不能对自己的成员关系执行此操作", http.StatusForbidden)
	ErrPermissionCodeInvalid = New(CodePermissionCodeInvalid, "权限码无效", http.StatusBadRequest)

	ErrDictionaryNotFound      = New(CodeDictionaryNotFound, "字典条目不存在", http.StatusNotFound)
	ErrDictionaryNameExists    = New(CodeDictionaryNameExists, "同一范围内的字典名称已存在", http.StatusConflict)
	ErrDictionaryParentInvalid = New(CodeDictionaryParentInvalid, "字典父级无效", http.StatusBadRequest)

	ErrDocumentNotFound      = New(CodeDocumentNotFound, "单据不存在", http.StatusNotFound)
	ErrDocumentStatusInvalid = New(CodeDocumentStatusInvalid, "当前单据状态不允许此操作", http.StatusConflict)
	ErrDocumentIncomplete    = New(CodeDocumentIncomplete, "单据内容不完整，无法提交", http.StatusBadRequest)
	ErrIdempotencyKeyReused  = New(CodeIdempotencyKeyReused, "幂等键已被用于其他请求", http.StatusConflict)

	ErrSettlementNotFound       = New(CodeSettlementNotFound, "结算单不存在", http.StatusNotFound)
	ErrSettlementStatusInvalid  = New(CodeSettlementStatusInvalid, "当前结算单状态不允许此操作", http.StatusConflict)
	ErrSettlementSourceInvalid  = New(CodeSettlementSourceInvalid, "源单据不允许参与结算", http.StatusBadRequest)
	ErrSettlementSourceConflict = New(CodeSettlementSourceConflict, "源单据已被其他有效结算单引用", http.StatusConflict)
	ErrSettlementRemarkRequired = New(CodeSettlementRemarkRequired, "驳回结算单必须填写原因", http.StatusBadRequest)

	ErrFinanceRecordNotFound   = New(CodeFinanceRecordNotFound, "付款 / 收款 / 开票记录不存在", http.StatusNotFound)
	ErrFinanceDocumentMismatch = New(CodeFinanceDocumentMismatch, "记录类型与单据类型不匹配", http.StatusBadRequest)
	ErrFinanceAmountExceeds    = New(CodeFinanceAmountExceeds, "累计金额超过单据总额", http.StatusConflict)

	ErrReportSnapshotNotFound = New(CodeReportSnapshotNotFound, "总结算单不存在", http.StatusNotFound)
	ErrReportPeriodEmpty      = New(CodeReportPeriodEmpty, "统计周期内没有可汇总的单据", http.StatusBadRequest)

	ErrResourceVersionConflict = New(CodeResourceVersionConflict, "资源已被其他请求修改", http.StatusConflict)

	ErrCSRFInvalid     = New(CodeCSRFInvalid, "CSRF 校验失败", http.StatusForbidden)
	ErrOriginForbidden = New(CodeOriginForbidden, "请求来源不允许", http.StatusForbidden)

	ErrForbidden = New(CodeForbidden, "无权执行此操作", http.StatusForbidden)
	ErrInternal  = New(CodeInternalError, "服务内部错误", http.StatusInternalServerError)
)
