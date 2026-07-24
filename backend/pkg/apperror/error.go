package apperror

import (
	stderrors "errors"
	"net/http"
)

const (
	CodeValidationFailed           = "VALIDATION_FAILED"
	CodeAuthInvalidCredentials     = "AUTH_INVALID_CREDENTIALS"
	CodeAuthTokenExpired           = "AUTH_TOKEN_EXPIRED"
	CodeAuthRefreshInvalid         = "AUTH_REFRESH_INVALID"
	CodeAuthPasswordChangeRequired = "AUTH_PASSWORD_CHANGE_REQUIRED"
	CodeUserUsernameExists         = "USER_USERNAME_EXISTS"
	CodeInvitationInvalid          = "INVITATION_INVALID"
	CodeInvitationExpired          = "INVITATION_EXPIRED"
	CodeInvitationUsed             = "INVITATION_USED"
	CodeGroupNameExists            = "GROUP_NAME_EXISTS"
	CodeForbidden                  = "FORBIDDEN"
	CodeInternalError              = "INTERNAL_ERROR"
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

	ErrGroupNameExists = New(CodeGroupNameExists, "组名已存在", http.StatusConflict)
	ErrForbidden       = New(CodeForbidden, "无权执行此操作", http.StatusForbidden)
	ErrInternal        = New(CodeInternalError, "服务内部错误", http.StatusInternalServerError)
)
