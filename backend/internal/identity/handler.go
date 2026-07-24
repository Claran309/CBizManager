package identity

import (
	"context"
	"net/http"

	"CBizDocsManager/backend/pkg/apperror"
	"CBizDocsManager/backend/pkg/response"
	"github.com/gin-gonic/gin"
)

const principalContextKey = "identity_principal"

type IdentityService interface {
	Login(ctx context.Context, req LoginRequest) (*TokenPair, error)
	Refresh(ctx context.Context, req RefreshRequest) (*TokenPair, error)
	Logout(ctx context.Context, principal Principal) error
	Me(ctx context.Context, principal Principal) (*MeResponse, error)
	ChangePassword(ctx context.Context, principal Principal, req ChangePasswordRequest) error
}

type Handler struct {
	service IdentityService
}

func NewHandler(service IdentityService) *Handler {
	return &Handler{service: service}
}

func (h *Handler) Login(c *gin.Context) {
	var req LoginRequest
	if !bindJSON(c, &req) {
		return
	}
	result, err := h.service.Login(c.Request.Context(), req)
	if err != nil {
		response.Failure(c, err, nil)
		return
	}
	response.Success(c, http.StatusOK, result)
}

func (h *Handler) Refresh(c *gin.Context) {
	var req RefreshRequest
	if !bindJSON(c, &req) {
		return
	}
	result, err := h.service.Refresh(c.Request.Context(), req)
	if err != nil {
		response.Failure(c, err, nil)
		return
	}
	response.Success(c, http.StatusOK, result)
}

func (h *Handler) Logout(c *gin.Context) {
	principal, ok := PrincipalFromContext(c)
	if !ok {
		response.Failure(c, apperror.ErrAuthTokenExpired, nil)
		return
	}
	if err := h.service.Logout(c.Request.Context(), *principal); err != nil {
		response.Failure(c, err, nil)
		return
	}
	response.Success(c, http.StatusOK, gin.H{"logged_out": true})
}

func (h *Handler) Me(c *gin.Context) {
	principal, ok := PrincipalFromContext(c)
	if !ok {
		response.Failure(c, apperror.ErrAuthTokenExpired, nil)
		return
	}
	result, err := h.service.Me(c.Request.Context(), *principal)
	if err != nil {
		response.Failure(c, err, nil)
		return
	}
	response.Success(c, http.StatusOK, result)
}

func (h *Handler) ChangePassword(c *gin.Context) {
	principal, ok := PrincipalFromContext(c)
	if !ok {
		response.Failure(c, apperror.ErrAuthTokenExpired, nil)
		return
	}
	var req ChangePasswordRequest
	if !bindJSON(c, &req) {
		return
	}
	if err := h.service.ChangePassword(c.Request.Context(), *principal, req); err != nil {
		response.Failure(c, err, nil)
		return
	}
	response.Success(c, http.StatusOK, gin.H{"changed": true})
}

func SetPrincipal(c *gin.Context, principal *Principal) {
	if c != nil && principal != nil {
		c.Set(principalContextKey, principal)
	}
}

func PrincipalFromContext(c *gin.Context) (*Principal, bool) {
	if c == nil {
		return nil, false
	}
	value, exists := c.Get(principalContextKey)
	if !exists {
		return nil, false
	}
	principal, ok := value.(*Principal)
	return principal, ok && principal != nil
}

func bindJSON(c *gin.Context, target any) bool {
	if err := c.ShouldBindJSON(target); err != nil {
		response.Failure(c, apperror.ErrValidationFailed, response.ValidationErrors(err))
		return false
	}
	return true
}
