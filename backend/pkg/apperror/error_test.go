package apperror

import (
	"errors"
	"fmt"
	"net/http"
	"testing"
)

func TestNewCreatesApplicationError(t *testing.T) {
	err := New(CodeValidationFailed, "参数不合法", http.StatusBadRequest)

	if err.Code != CodeValidationFailed {
		t.Fatalf("Code = %q, want %q", err.Code, CodeValidationFailed)
	}
	if err.Message != "参数不合法" {
		t.Fatalf("Message = %q, want %q", err.Message, "参数不合法")
	}
	if err.HTTPStatus != http.StatusBadRequest {
		t.Fatalf("HTTPStatus = %d, want %d", err.HTTPStatus, http.StatusBadRequest)
	}
	if err.Cause != nil {
		t.Fatalf("Cause = %v, want nil", err.Cause)
	}
	if got := err.Error(); got != "参数不合法" {
		t.Fatalf("Error() = %q, want %q", got, "参数不合法")
	}
}

func TestErrorUsesSafeFallbackWithoutExposingCause(t *testing.T) {
	cause := errors.New("database password leaked from driver")
	err := &Error{Cause: cause}

	if got := err.Error(); got != CodeInternalError {
		t.Fatalf("Error() = %q, want safe fallback %q", got, CodeInternalError)
	}
	if !errors.Is(err, cause) {
		t.Fatal("Error must retain its cause through Unwrap")
	}
}

func TestWrapInheritsBaseMetadataAndPreservesCause(t *testing.T) {
	baseCause := errors.New("base cause")
	base := &Error{
		Code:       CodeForbidden,
		Message:    "无权访问",
		HTTPStatus: http.StatusForbidden,
		Cause:      baseCause,
	}
	cause := errors.New("database unavailable")
	err := Wrap(base, cause)

	if err == base {
		t.Fatal("Wrap() must return a new Error")
	}
	if err.Code != base.Code || err.Message != base.Message || err.HTTPStatus != base.HTTPStatus {
		t.Fatalf("Wrap() metadata = %#v, want inherited metadata from %#v", err, base)
	}

	if !errors.Is(err, cause) {
		t.Fatal("wrapped error must preserve its cause")
	}
	if err.Cause != cause {
		t.Fatalf("Cause = %v, want original cause", err.Cause)
	}
	if base.Code != CodeForbidden || base.Message != "无权访问" || base.HTTPStatus != http.StatusForbidden || base.Cause != baseCause {
		t.Fatalf("Wrap() modified base error: %#v", base)
	}
}

func TestWrapNilBaseFallsBackToInternalErrorMetadata(t *testing.T) {
	cause := errors.New("unexpected failure")

	got := Wrap(nil, cause)

	if got == ErrInternal {
		t.Fatal("Wrap(nil, cause) must return a new Error")
	}
	if got.Code != ErrInternal.Code || got.Message != ErrInternal.Message || got.HTTPStatus != ErrInternal.HTTPStatus {
		t.Fatalf("Wrap(nil, cause) = %#v, want ErrInternal metadata", got)
	}
	if !errors.Is(got, cause) {
		t.Fatal("Wrap(nil, cause) must preserve its cause")
	}
	if ErrInternal.Cause != nil {
		t.Fatalf("Wrap(nil, cause) modified ErrInternal.Cause to %v", ErrInternal.Cause)
	}
}

func TestAsFindsApplicationErrorInChain(t *testing.T) {
	want := New(CodeForbidden, "无权访问", http.StatusForbidden)
	wrapped := fmt.Errorf("handler failed: %w", want)

	got := As(wrapped)
	if got != want {
		t.Fatalf("As() = %#v, want original application error %#v", got, want)
	}
}

func TestAsMapsUnknownErrorToInternalError(t *testing.T) {
	cause := errors.New("unexpected failure")

	got := As(cause)
	if got == ErrInternal {
		t.Fatal("As() must wrap unknown errors in a new Error")
	}
	if got.Code != CodeInternalError {
		t.Fatalf("Code = %q, want %q", got.Code, CodeInternalError)
	}
	if got.HTTPStatus != http.StatusInternalServerError {
		t.Fatalf("HTTPStatus = %d, want %d", got.HTTPStatus, http.StatusInternalServerError)
	}
	if !errors.Is(got, cause) {
		t.Fatal("mapped internal error must preserve the unknown cause")
	}
}

func TestAsNilReturnsNil(t *testing.T) {
	if got := As(nil); got != nil {
		t.Fatalf("As(nil) = %#v, want nil", got)
	}
}

func TestPredefinedErrorsHaveStableCodesAndStatuses(t *testing.T) {
	tests := []struct {
		name       string
		err        *Error
		code       string
		httpStatus int
	}{
		{name: "validation failed", err: ErrValidationFailed, code: CodeValidationFailed, httpStatus: http.StatusBadRequest},
		{name: "invalid credentials", err: ErrAuthInvalidCredentials, code: CodeAuthInvalidCredentials, httpStatus: http.StatusUnauthorized},
		{name: "token expired", err: ErrAuthTokenExpired, code: CodeAuthTokenExpired, httpStatus: http.StatusUnauthorized},
		{name: "refresh invalid", err: ErrAuthRefreshInvalid, code: CodeAuthRefreshInvalid, httpStatus: http.StatusUnauthorized},
		{name: "password change required", err: ErrAuthPasswordChangeRequired, code: CodeAuthPasswordChangeRequired, httpStatus: http.StatusForbidden},
		{name: "username exists", err: ErrUserUsernameExists, code: CodeUserUsernameExists, httpStatus: http.StatusConflict},
		{name: "invitation invalid", err: ErrInvitationInvalid, code: CodeInvitationInvalid, httpStatus: http.StatusBadRequest},
		{name: "invitation expired", err: ErrInvitationExpired, code: CodeInvitationExpired, httpStatus: http.StatusBadRequest},
		{name: "invitation used", err: ErrInvitationUsed, code: CodeInvitationUsed, httpStatus: http.StatusBadRequest},
		{name: "group name exists", err: ErrGroupNameExists, code: CodeGroupNameExists, httpStatus: http.StatusConflict},
		{name: "member not found", err: ErrMemberNotFound, code: CodeMemberNotFound, httpStatus: http.StatusNotFound},
		{name: "member owner protected", err: ErrMemberOwnerProtected, code: CodeMemberOwnerProtected, httpStatus: http.StatusForbidden},
		{name: "member self operation forbidden", err: ErrMemberSelfForbidden, code: CodeMemberSelfOperationForbidden, httpStatus: http.StatusForbidden},
		{name: "permission code invalid", err: ErrPermissionCodeInvalid, code: CodePermissionCodeInvalid, httpStatus: http.StatusBadRequest},
		{name: "dictionary not found", err: ErrDictionaryNotFound, code: CodeDictionaryNotFound, httpStatus: http.StatusNotFound},
		{name: "dictionary name exists", err: ErrDictionaryNameExists, code: CodeDictionaryNameExists, httpStatus: http.StatusConflict},
		{name: "dictionary parent invalid", err: ErrDictionaryParentInvalid, code: CodeDictionaryParentInvalid, httpStatus: http.StatusBadRequest},
		{name: "resource version conflict", err: ErrResourceVersionConflict, code: CodeResourceVersionConflict, httpStatus: http.StatusConflict},
		{name: "csrf invalid", err: ErrCSRFInvalid, code: CodeCSRFInvalid, httpStatus: http.StatusForbidden},
		{name: "origin forbidden", err: ErrOriginForbidden, code: CodeOriginForbidden, httpStatus: http.StatusForbidden},
		{name: "forbidden", err: ErrForbidden, code: CodeForbidden, httpStatus: http.StatusForbidden},
		{name: "internal", err: ErrInternal, code: CodeInternalError, httpStatus: http.StatusInternalServerError},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if tt.err == nil {
				t.Fatal("predefined error must not be nil")
			}
			if tt.err.Code != tt.code {
				t.Fatalf("Code = %q, want %q", tt.err.Code, tt.code)
			}
			if tt.err.HTTPStatus != tt.httpStatus {
				t.Fatalf("HTTPStatus = %d, want %d", tt.err.HTTPStatus, tt.httpStatus)
			}
			if tt.err.Message == "" {
				t.Fatal("predefined error message must not be empty")
			}
		})
	}
}
