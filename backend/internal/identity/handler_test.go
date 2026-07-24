package identity

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"CBizDocsManager/backend/pkg/requestid"
	"CBizDocsManager/backend/pkg/response"
	"github.com/gin-gonic/gin"
)

func TestHandlerLoginValidatesRequestAndMapsCredentialFailure(t *testing.T) {
	gin.SetMode(gin.TestMode)
	repo := newFakeIdentityRepository()
	repo.addUser(User{
		Username: "handler-user", PasswordHash: "hash:secret", DisplayName: "Handler",
		AccountType: AccountTypePlatformAdmin, Status: UserStatusActive,
	}, AccessState{AccountType: AccountTypePlatformAdmin, UserStatus: UserStatusActive})
	service, _ := newIdentityTestService(t, repo)
	handler := NewHandler(service)
	router := gin.New()
	router.Use(requestid.Middleware())
	router.POST("/login", handler.Login)

	tests := []struct {
		name       string
		body       string
		wantStatus int
		wantCode   string
	}{
		{name: "missing password", body: `{"username":"handler-user"}`, wantStatus: http.StatusBadRequest, wantCode: "VALIDATION_FAILED"},
		{name: "wrong password", body: `{"username":"handler-user","password":"wrong"}`, wantStatus: http.StatusUnauthorized, wantCode: "AUTH_INVALID_CREDENTIALS"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			request := httptest.NewRequest(http.MethodPost, "/login", bytes.NewBufferString(tt.body))
			request.Header.Set("Content-Type", "application/json")
			request.Header.Set(requestid.Header, "handler-request-id")
			writer := httptest.NewRecorder()
			router.ServeHTTP(writer, request)

			if writer.Code != tt.wantStatus {
				t.Fatalf("status = %d, want %d; body=%s", writer.Code, tt.wantStatus, writer.Body.String())
			}
			var envelope response.Envelope
			if err := json.Unmarshal(writer.Body.Bytes(), &envelope); err != nil {
				t.Fatalf("decode response: %v", err)
			}
			if envelope.Code != tt.wantCode || envelope.RequestID != "handler-request-id" {
				t.Fatalf("response = %+v", envelope)
			}
			if tt.wantCode == "VALIDATION_FAILED" && len(envelope.FieldErrors) == 0 {
				t.Fatal("validation response has no field_errors")
			}
		})
	}
}

func TestHandlerMeReturnsCurrentUserEnvelope(t *testing.T) {
	gin.SetMode(gin.TestMode)
	repo := newFakeIdentityRepository()
	user := repo.addUser(User{
		Username: "me-handler", PasswordHash: "hash:secret", DisplayName: "Me Handler",
		AccountType: AccountTypePlatformAdmin, Status: UserStatusActive,
	}, AccessState{AccountType: AccountTypePlatformAdmin, UserStatus: UserStatusActive})
	service, _ := newIdentityTestService(t, repo)
	handler := NewHandler(service)
	router := gin.New()
	router.Use(requestid.Middleware(), func(c *gin.Context) {
		SetPrincipal(c, &Principal{UserID: user.ID, AccountType: AccountTypePlatformAdmin, SessionID: 1})
		c.Next()
	})
	router.GET("/me", handler.Me)

	request := httptest.NewRequest(http.MethodGet, "/me", nil)
	writer := httptest.NewRecorder()
	router.ServeHTTP(writer, request)
	if writer.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200; body=%s", writer.Code, writer.Body.String())
	}
	var envelope struct {
		Code string     `json:"code"`
		Data MeResponse `json:"data"`
	}
	if err := json.Unmarshal(writer.Body.Bytes(), &envelope); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if envelope.Code != response.CodeOK || envelope.Data.User.ID != user.ID || envelope.Data.User.Username != user.Username {
		t.Fatalf("response = %+v", envelope)
	}
}

func TestHandlerValidationUsesJSONFieldNames(t *testing.T) {
	gin.SetMode(gin.TestMode)
	repo := newFakeIdentityRepository()
	service, _ := newIdentityTestService(t, repo)
	handler := NewHandler(service)
	router := gin.New()
	router.Use(requestid.Middleware(), func(c *gin.Context) {
		SetPrincipal(c, &Principal{UserID: 1, AccountType: AccountTypePlatformAdmin, SessionID: 1})
		c.Next()
	})
	router.PUT("/password", handler.ChangePassword)

	request := httptest.NewRequest(http.MethodPut, "/password", bytes.NewBufferString(`{"new_password":"new-password"}`))
	request.Header.Set("Content-Type", "application/json")
	writer := httptest.NewRecorder()
	router.ServeHTTP(writer, request)
	if writer.Code != http.StatusBadRequest {
		t.Fatalf("status = %d, want 400; body=%s", writer.Code, writer.Body.String())
	}
	var envelope response.Envelope
	if err := json.Unmarshal(writer.Body.Bytes(), &envelope); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if len(envelope.FieldErrors) != 1 || envelope.FieldErrors[0].Field != "current_password" {
		t.Fatalf("field_errors = %+v, want current_password", envelope.FieldErrors)
	}
}

func TestHandlerPasswordAndLogoutReturnContractFlags(t *testing.T) {
	gin.SetMode(gin.TestMode)
	repo := newFakeIdentityRepository()
	user := repo.addUser(User{
		Username: "flags-user", PasswordHash: "hash:old-password", DisplayName: "Flags",
		AccountType: AccountTypePlatformAdmin, Status: UserStatusActive,
	}, AccessState{AccountType: AccountTypePlatformAdmin, UserStatus: UserStatusActive})
	service, _ := newIdentityTestService(t, repo)
	pair, err := service.Login(context.Background(), LoginRequest{Username: user.Username, Password: "old-password"})
	if err != nil {
		t.Fatalf("Login() error = %v", err)
	}
	principal, err := service.Authenticate(context.Background(), pair.AccessToken)
	if err != nil {
		t.Fatalf("Authenticate() error = %v", err)
	}
	handler := NewHandler(service)
	router := gin.New()
	router.Use(requestid.Middleware(), func(c *gin.Context) {
		SetPrincipal(c, principal)
		c.Next()
	})
	router.PUT("/password", handler.ChangePassword)
	router.POST("/logout", handler.Logout)

	passwordRequest := httptest.NewRequest(http.MethodPut, "/password", bytes.NewBufferString(`{"current_password":"old-password","new_password":"new-password"}`))
	passwordRequest.Header.Set("Content-Type", "application/json")
	passwordWriter := httptest.NewRecorder()
	router.ServeHTTP(passwordWriter, passwordRequest)
	assertHandlerBooleanData(t, passwordWriter, "changed")

	logoutWriter := httptest.NewRecorder()
	router.ServeHTTP(logoutWriter, httptest.NewRequest(http.MethodPost, "/logout", nil))
	assertHandlerBooleanData(t, logoutWriter, "logged_out")
}

func assertHandlerBooleanData(t *testing.T, writer *httptest.ResponseRecorder, field string) {
	t.Helper()
	if writer.Code != http.StatusOK {
		t.Fatalf("status=%d want=200 body=%s", writer.Code, writer.Body.String())
	}
	var envelope struct {
		Data map[string]bool `json:"data"`
	}
	if err := json.Unmarshal(writer.Body.Bytes(), &envelope); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if !envelope.Data[field] {
		t.Fatalf("response data=%v, want %s=true", envelope.Data, field)
	}
}
