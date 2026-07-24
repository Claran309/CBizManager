package identity

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"CBizDocsManager/backend/pkg/apperror"
	"CBizDocsManager/backend/pkg/config"
	"CBizDocsManager/backend/pkg/requestid"
	"github.com/gin-gonic/gin"
)

type webIdentityServiceStub struct {
	pair         *TokenPair
	err          error
	logoutToken  string
	refreshToken string
}

func (s *webIdentityServiceStub) Login(context.Context, LoginRequest) (*TokenPair, error) {
	return s.pair, s.err
}
func (s *webIdentityServiceStub) Refresh(_ context.Context, request RefreshRequest) (*TokenPair, error) {
	s.refreshToken = request.RefreshToken
	return s.pair, s.err
}
func (s *webIdentityServiceStub) LogoutRefresh(_ context.Context, token string) error {
	s.logoutToken = token
	return s.err
}

func webHandlerRouter(service WebIdentityService, cfg config.WebAuthConfig) *gin.Engine {
	gin.SetMode(gin.TestMode)
	router := gin.New()
	router.Use(requestid.Middleware())
	handler := NewWebHandler(service, cfg)
	router.POST("/login", handler.Login)
	router.POST("/refresh", handler.Refresh)
	router.POST("/logout", handler.Logout)
	return router
}

func findResponseCookie(t *testing.T, response *http.Response, name string) *http.Cookie {
	t.Helper()
	for _, cookie := range response.Cookies() {
		if cookie.Name == name {
			return cookie
		}
	}
	t.Fatalf("cookie %q missing: %v", name, response.Header.Values("Set-Cookie"))
	return nil
}

func TestWebHandlerLoginSetsProtectedCookiesWithoutLeakingRefreshToken(t *testing.T) {
	now := time.Date(2026, 7, 24, 18, 0, 0, 0, time.UTC)
	service := &webIdentityServiceStub{pair: &TokenPair{AccessToken: "access-secret", RefreshToken: "refresh-secret", AccessExpiresAt: now.Add(time.Minute), RefreshExpiresAt: now.Add(time.Hour)}}
	cfg := config.WebAuthConfig{Enabled: true, Secure: true, CookieDomain: "example.com", RefreshCookieName: "cbiz_refresh", CSRFCookieName: "cbiz_csrf"}
	request := httptest.NewRequest(http.MethodPost, "/login", bytes.NewBufferString(`{"username":"user","password":"secret"}`))
	request.Header.Set("Content-Type", "application/json")
	writer := httptest.NewRecorder()
	webHandlerRouter(service, cfg).ServeHTTP(writer, request)
	if writer.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", writer.Code, writer.Body.String())
	}
	if strings.Contains(writer.Body.String(), "refresh-secret") || strings.Contains(writer.Body.String(), "refresh_token") {
		t.Fatalf("response leaked refresh token: %s", writer.Body.String())
	}
	var envelope struct {
		Data WebAccessTokenData `json:"data"`
	}
	if err := json.Unmarshal(writer.Body.Bytes(), &envelope); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if envelope.Data.AccessToken != "access-secret" {
		t.Fatalf("data=%+v", envelope.Data)
	}
	response := writer.Result()
	refresh := findResponseCookie(t, response, cfg.RefreshCookieName)
	csrf := findResponseCookie(t, response, cfg.CSRFCookieName)
	if refresh.Value != "refresh-secret" || !refresh.HttpOnly || !refresh.Secure || refresh.SameSite != http.SameSiteLaxMode || refresh.Path != "/api/v1/auth/web" || refresh.Domain != "" {
		t.Fatalf("refresh cookie=%+v", refresh)
	}
	if csrf.Value == "" || csrf.HttpOnly || !csrf.Secure || csrf.SameSite != http.SameSiteLaxMode || csrf.Path != "/" || csrf.Domain != "example.com" {
		t.Fatalf("csrf cookie=%+v", csrf)
	}
}

func TestWebHandlerRefreshReadsCookieAndRotatesBothCookies(t *testing.T) {
	now := time.Now().UTC()
	service := &webIdentityServiceStub{pair: &TokenPair{AccessToken: "next-access", RefreshToken: "next-refresh", AccessExpiresAt: now.Add(time.Minute), RefreshExpiresAt: now.Add(time.Hour)}}
	cfg := config.WebAuthConfig{RefreshCookieName: "cbiz_refresh", CSRFCookieName: "cbiz_csrf"}
	request := httptest.NewRequest(http.MethodPost, "/refresh", nil)
	request.AddCookie(&http.Cookie{Name: cfg.RefreshCookieName, Value: "old-refresh"})
	writer := httptest.NewRecorder()
	webHandlerRouter(service, cfg).ServeHTTP(writer, request)
	if writer.Code != http.StatusOK || service.refreshToken != "old-refresh" {
		t.Fatalf("status=%d token=%q body=%s", writer.Code, service.refreshToken, writer.Body.String())
	}
	if findResponseCookie(t, writer.Result(), cfg.RefreshCookieName).Value != "next-refresh" {
		t.Fatal("refresh cookie was not rotated")
	}
}

func TestWebHandlerLogoutClearsCookiesOnSuccessAndFailure(t *testing.T) {
	cfg := config.WebAuthConfig{RefreshCookieName: "cbiz_refresh", CSRFCookieName: "cbiz_csrf"}
	for _, serviceErr := range []error{nil, apperror.ErrAuthRefreshInvalid} {
		service := &webIdentityServiceStub{err: serviceErr}
		request := httptest.NewRequest(http.MethodPost, "/logout", nil)
		request.AddCookie(&http.Cookie{Name: cfg.RefreshCookieName, Value: "refresh"})
		writer := httptest.NewRecorder()
		webHandlerRouter(service, cfg).ServeHTTP(writer, request)
		want := http.StatusOK
		if serviceErr != nil {
			want = http.StatusUnauthorized
		}
		if writer.Code != want {
			t.Fatalf("error=%v status=%d body=%s", serviceErr, writer.Code, writer.Body.String())
		}
		if service.logoutToken != "refresh" {
			t.Fatalf("logout token=%q", service.logoutToken)
		}
		for _, name := range []string{cfg.RefreshCookieName, cfg.CSRFCookieName} {
			cookie := findResponseCookie(t, writer.Result(), name)
			if cookie.MaxAge >= 0 || cookie.Value != "" {
				t.Fatalf("cleared cookie=%+v", cookie)
			}
		}
	}
}
