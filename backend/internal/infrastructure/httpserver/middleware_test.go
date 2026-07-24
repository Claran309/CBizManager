package httpserver

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"CBizDocsManager/backend/internal/identity"
	"CBizDocsManager/backend/pkg/apperror"
	"CBizDocsManager/backend/pkg/config"
	"CBizDocsManager/backend/pkg/requestid"
	"CBizDocsManager/backend/pkg/response"
	"github.com/gin-gonic/gin"
	"go.uber.org/zap"
	"go.uber.org/zap/zaptest/observer"
)

func TestMiddlewareAuthenticationRequiresBearerAndStoresPrincipal(t *testing.T) {
	gin.SetMode(gin.TestMode)
	principal := &identity.Principal{UserID: 9, AccountType: identity.AccountTypePlatformAdmin, SessionID: 12}
	authenticator := &stubAuthenticator{principal: principal}
	router := gin.New()
	router.Use(requestid.Middleware(), Authentication(authenticator))
	router.GET("/protected", func(c *gin.Context) {
		got, ok := identity.PrincipalFromContext(c)
		if !ok {
			c.Status(http.StatusInternalServerError)
			return
		}
		c.JSON(http.StatusOK, gin.H{"user_id": got.UserID})
	})

	missing := httptest.NewRecorder()
	router.ServeHTTP(missing, httptest.NewRequest(http.MethodGet, "/protected", nil))
	assertMiddlewareError(t, missing, http.StatusUnauthorized, apperror.CodeAuthTokenExpired)

	validRequest := httptest.NewRequest(http.MethodGet, "/protected", nil)
	validRequest.Header.Set("Authorization", "Bearer access-token")
	valid := httptest.NewRecorder()
	router.ServeHTTP(valid, validRequest)
	if valid.Code != http.StatusOK || authenticator.lastToken != "access-token" {
		t.Fatalf("valid authentication status=%d token=%q body=%s", valid.Code, authenticator.lastToken, valid.Body.String())
	}
}

func TestMiddlewarePasswordAndRoleGuards(t *testing.T) {
	tests := []struct {
		name       string
		principal  identity.Principal
		middleware gin.HandlerFunc
		wantStatus int
		wantCode   string
	}{
		{
			name: "forced password change", principal: identity.Principal{MustChangePassword: true},
			middleware: RequirePasswordChanged(), wantStatus: http.StatusForbidden, wantCode: apperror.CodeAuthPasswordChangeRequired,
		},
		{
			name: "member denied platform", principal: identity.Principal{AccountType: identity.AccountTypeMember},
			middleware: RequirePlatformAdmin(), wantStatus: http.StatusForbidden, wantCode: apperror.CodeForbidden,
		},
		{
			name: "member denied owner", principal: identity.Principal{AccountType: identity.AccountTypeMember, MemberType: "member"},
			middleware: RequireGroupOwner(), wantStatus: http.StatusForbidden, wantCode: apperror.CodeForbidden,
		},
		{
			name: "owner allowed", principal: identity.Principal{AccountType: identity.AccountTypeGroupOwner, MemberType: "owner"},
			middleware: RequireGroupOwner(), wantStatus: http.StatusNoContent,
		},
		{
			name: "platform denied tenant", principal: identity.Principal{AccountType: identity.AccountTypePlatformAdmin},
			middleware: RequireTenantGroup(), wantStatus: http.StatusForbidden, wantCode: apperror.CodeForbidden,
		},
		{
			name: "member with group allowed tenant", principal: func() identity.Principal {
				groupID := uint64(7)
				return identity.Principal{GroupID: &groupID, AccountType: identity.AccountTypeMember, MemberType: "member"}
			}(),
			middleware: RequireTenantGroup(), wantStatus: http.StatusNoContent,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			router := gin.New()
			router.Use(requestid.Middleware(), func(c *gin.Context) {
				identity.SetPrincipal(c, &tt.principal)
				c.Next()
			}, tt.middleware)
			router.GET("/guarded", func(c *gin.Context) { c.Status(http.StatusNoContent) })
			writer := httptest.NewRecorder()
			router.ServeHTTP(writer, httptest.NewRequest(http.MethodGet, "/guarded", nil))
			if tt.wantCode == "" {
				if writer.Code != tt.wantStatus {
					t.Fatalf("status=%d want=%d body=%s", writer.Code, tt.wantStatus, writer.Body.String())
				}
				return
			}
			assertMiddlewareError(t, writer, tt.wantStatus, tt.wantCode)
		})
	}
}

func TestMiddlewareRecoveryReturnsInternalErrorWithRequestID(t *testing.T) {
	gin.SetMode(gin.TestMode)
	var ginErrors bytes.Buffer
	previousErrorWriter := gin.DefaultErrorWriter
	gin.DefaultErrorWriter = &ginErrors
	t.Cleanup(func() { gin.DefaultErrorWriter = previousErrorWriter })
	accessCore, accessLogs := observer.New(zap.InfoLevel)
	router := gin.New()
	router.Use(requestid.Middleware(), Recovery(zap.NewNop()), AccessLog(zap.New(accessCore)))
	router.GET("/panic", func(*gin.Context) { panic("sensitive panic") })
	request := httptest.NewRequest(http.MethodGet, "/panic", nil)
	request.Header.Set(requestid.Header, "panic-request-id")
	writer := httptest.NewRecorder()
	router.ServeHTTP(writer, request)

	assertMiddlewareError(t, writer, http.StatusInternalServerError, apperror.CodeInternalError)
	var envelope response.Envelope
	if err := json.Unmarshal(writer.Body.Bytes(), &envelope); err != nil {
		t.Fatalf("decode recovery response: %v", err)
	}
	if envelope.RequestID != "panic-request-id" {
		t.Fatalf("recovery request_id=%q", envelope.RequestID)
	}
	if strings.Contains(ginErrors.String(), "sensitive panic") {
		t.Fatalf("recovery leaked panic value to Gin error output: %q", ginErrors.String())
	}
	if accessLogs.Len() != 1 {
		t.Fatalf("panic access log count = %d, want 1", accessLogs.Len())
	}
	if status := fmt.Sprint(accessLogs.All()[0].ContextMap()["status"]); status != "500" {
		t.Fatalf("panic access log status = %s, want 500", status)
	}
}

func TestMiddlewareAccessLogOmitsAuthorizationAndQueryValues(t *testing.T) {
	gin.SetMode(gin.TestMode)
	core, observed := observer.New(zap.InfoLevel)
	router := gin.New()
	router.Use(requestid.Middleware(), AccessLog(zap.New(core)))
	router.GET("/logged", func(c *gin.Context) { c.Status(http.StatusNoContent) })
	request := httptest.NewRequest(http.MethodGet, "/logged?refresh_token=query-secret", nil)
	request.Header.Set("Authorization", "Bearer access-secret")
	writer := httptest.NewRecorder()
	router.ServeHTTP(writer, request)

	if observed.Len() != 1 {
		t.Fatalf("access log count = %d, want 1", observed.Len())
	}
	entry := observed.All()[0]
	encoded := entry.Message
	for key, value := range entry.ContextMap() {
		encoded += key + "=" + fmt.Sprint(value)
	}
	if strings.Contains(encoded, "access-secret") || strings.Contains(encoded, "query-secret") || strings.Contains(encoded, "Authorization") {
		t.Fatalf("access log leaked credential: %q", encoded)
	}
}

func TestMiddlewareCORSUsesConfiguredOriginsWithoutCredentialWildcard(t *testing.T) {
	gin.SetMode(gin.TestMode)
	cfg := config.CORSConfig{
		AllowedOrigins:   []string{"https://allowed.example", "*"},
		AllowedMethods:   []string{http.MethodGet, http.MethodPost},
		AllowedHeaders:   []string{"Authorization", "Content-Type"},
		AllowCredentials: true,
		MaxAge:           time.Hour,
	}
	router := gin.New()
	router.Use(CORS(cfg))
	router.GET("/cors", func(c *gin.Context) { c.Status(http.StatusNoContent) })

	allowedRequest := httptest.NewRequest(http.MethodGet, "/cors", nil)
	allowedRequest.Header.Set("Origin", "https://allowed.example")
	allowed := httptest.NewRecorder()
	router.ServeHTTP(allowed, allowedRequest)
	if allowed.Header().Get("Access-Control-Allow-Origin") != "https://allowed.example" || allowed.Header().Get("Access-Control-Allow-Credentials") != "true" {
		t.Fatalf("allowed CORS headers = %v", allowed.Header())
	}

	disallowedRequest := httptest.NewRequest(http.MethodGet, "/cors", nil)
	disallowedRequest.Header.Set("Origin", "https://other.example")
	disallowed := httptest.NewRecorder()
	router.ServeHTTP(disallowed, disallowedRequest)
	if origin := disallowed.Header().Get("Access-Control-Allow-Origin"); origin != "" {
		t.Fatalf("disallowed origin received Access-Control-Allow-Origin %q", origin)
	}
}

func TestMiddlewareWebOriginUsesExactSchemeHostAndPort(t *testing.T) {
	cfg := config.WebAuthConfig{Enabled: true, AllowedOrigins: []string{"https://app.example.com", "http://localhost:3000"}}
	router := gin.New()
	router.Use(requestid.Middleware(), RequireWebOrigin(cfg))
	router.POST("/web", func(c *gin.Context) { c.Status(http.StatusNoContent) })

	allowedRequest := httptest.NewRequest(http.MethodPost, "/web", nil)
	allowedRequest.Header.Set("Origin", "https://app.example.com")
	allowed := httptest.NewRecorder()
	router.ServeHTTP(allowed, allowedRequest)
	if allowed.Code != http.StatusNoContent {
		t.Fatalf("allowed status=%d body=%s", allowed.Code, allowed.Body.String())
	}

	for _, origin := range []string{"", "http://app.example.com", "https://app.example.com:444", "https://evil.example"} {
		request := httptest.NewRequest(http.MethodPost, "/web", nil)
		request.Header.Set("Origin", origin)
		writer := httptest.NewRecorder()
		router.ServeHTTP(writer, request)
		assertMiddlewareError(t, writer, http.StatusForbidden, apperror.CodeOriginForbidden)
	}
}

func TestMiddlewareCSRFRequiresMatchingCookieAndHeader(t *testing.T) {
	cfg := config.WebAuthConfig{CSRFCookieName: "cbiz_csrf"}
	router := gin.New()
	router.Use(requestid.Middleware(), RequireCSRF(cfg))
	router.POST("/web", func(c *gin.Context) { c.Status(http.StatusNoContent) })

	validRequest := httptest.NewRequest(http.MethodPost, "/web", nil)
	validRequest.AddCookie(&http.Cookie{Name: cfg.CSRFCookieName, Value: "csrf-token"})
	validRequest.Header.Set("X-CSRF-Token", "csrf-token")
	valid := httptest.NewRecorder()
	router.ServeHTTP(valid, validRequest)
	if valid.Code != http.StatusNoContent {
		t.Fatalf("valid status=%d body=%s", valid.Code, valid.Body.String())
	}

	for _, header := range []string{"", "different"} {
		request := httptest.NewRequest(http.MethodPost, "/web", nil)
		request.AddCookie(&http.Cookie{Name: cfg.CSRFCookieName, Value: "csrf-token"})
		request.Header.Set("X-CSRF-Token", header)
		writer := httptest.NewRecorder()
		router.ServeHTTP(writer, request)
		assertMiddlewareError(t, writer, http.StatusForbidden, apperror.CodeCSRFInvalid)
	}
}

type stubAuthenticator struct {
	principal *identity.Principal
	err       error
	lastToken string
}

func (s *stubAuthenticator) Authenticate(_ context.Context, token string) (*identity.Principal, error) {
	s.lastToken = token
	if s.err != nil {
		return nil, s.err
	}
	if s.principal == nil {
		return nil, errors.New("no principal")
	}
	return s.principal, nil
}

func assertMiddlewareError(t *testing.T, writer *httptest.ResponseRecorder, status int, code string) {
	t.Helper()
	if writer.Code != status {
		t.Fatalf("status=%d want=%d body=%s", writer.Code, status, writer.Body.String())
	}
	var envelope response.Envelope
	if err := json.Unmarshal(writer.Body.Bytes(), &envelope); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if envelope.Code != code {
		t.Fatalf("code=%q want=%q body=%s", envelope.Code, code, writer.Body.String())
	}
}
