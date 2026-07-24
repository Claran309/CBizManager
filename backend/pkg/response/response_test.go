package response

import (
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"testing"

	"CBizDocsManager/backend/pkg/apperror"
	"CBizDocsManager/backend/pkg/requestid"
	"github.com/gin-gonic/gin"
)

func TestSuccessWritesEnvelopeWithRequestID(t *testing.T) {
	recorder := performRequest(t, func(c *gin.Context) {
		Success(c, http.StatusCreated, map[string]any{"id": float64(7)})
	})

	if recorder.Code != http.StatusCreated {
		t.Fatalf("status = %d, want %d", recorder.Code, http.StatusCreated)
	}
	envelope := decodeEnvelope(t, recorder)
	if envelope.Code != CodeOK {
		t.Fatalf("code = %q, want %q", envelope.Code, CodeOK)
	}
	if envelope.RequestID != testRequestID {
		t.Fatalf("request_id = %q, want %q", envelope.RequestID, testRequestID)
	}
	if recorder.Header().Get(requestid.Header) != testRequestID {
		t.Fatalf("response header request ID = %q", recorder.Header().Get(requestid.Header))
	}
	data, ok := envelope.Data.(map[string]any)
	if !ok || data["id"] != float64(7) {
		t.Fatalf("data = %#v, want object containing id=7", envelope.Data)
	}

	var raw map[string]json.RawMessage
	if err := json.Unmarshal(recorder.Body.Bytes(), &raw); err != nil {
		t.Fatalf("decode raw response: %v", err)
	}
	if _, exists := raw["field_errors"]; exists {
		t.Fatal("successful response should omit field_errors")
	}
}

func TestFailureMapsApplicationErrorAndFieldErrors(t *testing.T) {
	fields := []FieldError{{Field: "group_id", Message: "无权访问该组"}}
	recorder := performRequest(t, func(c *gin.Context) {
		Failure(c, apperror.ErrForbidden, fields)
	})

	if recorder.Code != http.StatusForbidden {
		t.Fatalf("status = %d, want %d", recorder.Code, http.StatusForbidden)
	}
	envelope := decodeEnvelope(t, recorder)
	if envelope.Code != apperror.CodeForbidden {
		t.Fatalf("code = %q, want %q", envelope.Code, apperror.CodeForbidden)
	}
	if envelope.Message != apperror.ErrForbidden.Message {
		t.Fatalf("message = %q, want %q", envelope.Message, apperror.ErrForbidden.Message)
	}
	if envelope.Data != nil {
		t.Fatalf("data = %#v, want nil", envelope.Data)
	}
	if envelope.RequestID != testRequestID {
		t.Fatalf("request_id = %q, want %q", envelope.RequestID, testRequestID)
	}
	if len(envelope.FieldErrors) != 1 || envelope.FieldErrors[0] != fields[0] {
		t.Fatalf("field_errors = %#v, want %#v", envelope.FieldErrors, fields)
	}
}

func TestFailureMapsUnknownErrorToInternalError(t *testing.T) {
	recorder := performRequest(t, func(c *gin.Context) {
		Failure(c, errors.New("database password leaked in cause"), nil)
	})

	if recorder.Code != http.StatusInternalServerError {
		t.Fatalf("status = %d, want %d", recorder.Code, http.StatusInternalServerError)
	}
	envelope := decodeEnvelope(t, recorder)
	if envelope.Code != apperror.CodeInternalError {
		t.Fatalf("code = %q, want %q", envelope.Code, apperror.CodeInternalError)
	}
	if envelope.Message != apperror.ErrInternal.Message {
		t.Fatalf("message = %q, want safe message %q", envelope.Message, apperror.ErrInternal.Message)
	}
	if envelope.Data != nil {
		t.Fatalf("data = %#v, want nil", envelope.Data)
	}
	if envelope.RequestID != testRequestID {
		t.Fatalf("request_id = %q, want %q", envelope.RequestID, testRequestID)
	}
}

func TestFailureFallsBackToInternalErrorForInvalidHTTPStatus(t *testing.T) {
	tests := []struct {
		name       string
		httpStatus int
	}{
		{name: "success status", httpStatus: http.StatusOK},
		{name: "redirect status", httpStatus: http.StatusFound},
		{name: "below HTTP range", httpStatus: 99},
		{name: "above HTTP range", httpStatus: 600},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			recorder := performRequest(t, func(c *gin.Context) {
				Failure(c, apperror.New("UNSAFE_ERROR", "unsafe message", tt.httpStatus), nil)
			})

			if recorder.Code != http.StatusInternalServerError {
				t.Fatalf("status = %d, want %d", recorder.Code, http.StatusInternalServerError)
			}
			envelope := decodeEnvelope(t, recorder)
			if envelope.Code != apperror.CodeInternalError {
				t.Fatalf("code = %q, want %q", envelope.Code, apperror.CodeInternalError)
			}
			if envelope.Message != apperror.ErrInternal.Message {
				t.Fatalf("message = %q, want %q", envelope.Message, apperror.ErrInternal.Message)
			}
		})
	}
}

const testRequestID = "test-request-id"

func performRequest(t *testing.T, handler gin.HandlerFunc) *httptest.ResponseRecorder {
	t.Helper()

	gin.SetMode(gin.TestMode)
	router := gin.New()
	router.Use(requestid.Middleware())
	router.GET("/", handler)

	recorder := httptest.NewRecorder()
	request := httptest.NewRequest(http.MethodGet, "/", nil)
	request.Header.Set(requestid.Header, testRequestID)
	router.ServeHTTP(recorder, request)
	return recorder
}

func decodeEnvelope(t *testing.T, recorder *httptest.ResponseRecorder) Envelope {
	t.Helper()

	var envelope Envelope
	if err := json.Unmarshal(recorder.Body.Bytes(), &envelope); err != nil {
		t.Fatalf("decode response envelope: %v; body=%s", err, recorder.Body.String())
	}
	return envelope
}
