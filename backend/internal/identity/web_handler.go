package identity

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"net/http"
	"time"

	"CBizDocsManager/backend/pkg/apperror"
	"CBizDocsManager/backend/pkg/config"
	"CBizDocsManager/backend/pkg/response"
	"github.com/gin-gonic/gin"
)

const webRefreshCookiePath = "/api/v1/auth/web"

type WebIdentityService interface {
	Login(ctx context.Context, request LoginRequest) (*TokenPair, error)
	Refresh(ctx context.Context, request RefreshRequest) (*TokenPair, error)
	LogoutRefresh(ctx context.Context, rawRefreshToken string) error
}

type WebAccessTokenData struct {
	AccessToken     string    `json:"access_token"`
	AccessExpiresAt time.Time `json:"access_expires_at"`
}

type WebHandler struct {
	service WebIdentityService
	config  config.WebAuthConfig
}

func NewWebHandler(service WebIdentityService, cfg config.WebAuthConfig) *WebHandler {
	return &WebHandler{service: service, config: cfg}
}

func (h *WebHandler) Login(c *gin.Context) {
	var request LoginRequest
	if !bindJSON(c, &request) {
		return
	}
	pair, err := h.service.Login(c.Request.Context(), request)
	if err != nil {
		response.Failure(c, err, nil)
		return
	}
	if err := h.writeSessionCookies(c, pair); err != nil {
		response.Failure(c, err, nil)
		return
	}
	response.Success(c, http.StatusOK, webAccessData(pair))
}

func (h *WebHandler) Refresh(c *gin.Context) {
	rawRefresh, err := c.Cookie(h.config.RefreshCookieName)
	if err != nil || rawRefresh == "" {
		h.clearSessionCookies(c)
		response.Failure(c, apperror.ErrAuthRefreshInvalid, nil)
		return
	}
	pair, err := h.service.Refresh(c.Request.Context(), RefreshRequest{RefreshToken: rawRefresh})
	if err != nil {
		h.clearSessionCookies(c)
		response.Failure(c, err, nil)
		return
	}
	if err := h.writeSessionCookies(c, pair); err != nil {
		response.Failure(c, err, nil)
		return
	}
	response.Success(c, http.StatusOK, webAccessData(pair))
}

func (h *WebHandler) Logout(c *gin.Context) {
	rawRefresh, err := c.Cookie(h.config.RefreshCookieName)
	if err != nil || rawRefresh == "" {
		h.clearSessionCookies(c)
		response.Failure(c, apperror.ErrAuthRefreshInvalid, nil)
		return
	}
	err = h.service.LogoutRefresh(c.Request.Context(), rawRefresh)
	h.clearSessionCookies(c)
	if err != nil {
		response.Failure(c, err, nil)
		return
	}
	response.Success(c, http.StatusOK, gin.H{"logged_out": true})
}

func (h *WebHandler) writeSessionCookies(c *gin.Context, pair *TokenPair) error {
	csrfToken, err := newCSRFToken()
	if err != nil {
		return apperror.Wrap(apperror.ErrInternal, err)
	}
	maxAge := int(time.Until(pair.RefreshExpiresAt) / time.Second)
	if maxAge < 1 {
		maxAge = 1
	}
	http.SetCookie(c.Writer, &http.Cookie{Name: h.config.RefreshCookieName, Value: pair.RefreshToken, Path: webRefreshCookiePath,
		Expires: pair.RefreshExpiresAt, MaxAge: maxAge, Secure: h.config.Secure, HttpOnly: true, SameSite: http.SameSiteLaxMode})
	http.SetCookie(c.Writer, &http.Cookie{Name: h.config.CSRFCookieName, Value: csrfToken, Path: "/", Domain: h.config.CookieDomain,
		Expires: pair.RefreshExpiresAt, MaxAge: maxAge, Secure: h.config.Secure, HttpOnly: false, SameSite: http.SameSiteLaxMode})
	return nil
}

func (h *WebHandler) clearSessionCookies(c *gin.Context) {
	expires := time.Unix(1, 0).UTC()
	http.SetCookie(c.Writer, &http.Cookie{Name: h.config.RefreshCookieName, Value: "", Path: webRefreshCookiePath, Expires: expires, MaxAge: -1, Secure: h.config.Secure, HttpOnly: true, SameSite: http.SameSiteLaxMode})
	http.SetCookie(c.Writer, &http.Cookie{Name: h.config.CSRFCookieName, Value: "", Path: "/", Domain: h.config.CookieDomain, Expires: expires, MaxAge: -1, Secure: h.config.Secure, HttpOnly: false, SameSite: http.SameSiteLaxMode})
}

func webAccessData(pair *TokenPair) WebAccessTokenData {
	return WebAccessTokenData{AccessToken: pair.AccessToken, AccessExpiresAt: pair.AccessExpiresAt}
}
func newCSRFToken() (string, error) {
	value := make([]byte, 32)
	if _, err := rand.Read(value); err != nil {
		return "", err
	}
	return base64.RawURLEncoding.EncodeToString(value), nil
}
