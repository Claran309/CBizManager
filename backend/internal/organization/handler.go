package organization

import (
	"context"
	"net/http"
	"strconv"

	"CBizDocsManager/backend/internal/identity"
	"CBizDocsManager/backend/pkg/apperror"
	"CBizDocsManager/backend/pkg/response"
	"github.com/gin-gonic/gin"
)

type OrganizationService interface {
	CreateInvitation(ctx context.Context, principal identity.Principal, req CreateInvitationRequest) (*InvitationCreatedData, error)
	Register(ctx context.Context, req RegisterRequest) (*RegisterData, error)
	ListInvitations(ctx context.Context, principal identity.Principal, query InvitationQuery) (*InvitationPageData, error)
	RevealInvitation(ctx context.Context, principal identity.Principal, invitationID uint64) (*InvitationSecretData, error)
	RevokeInvitation(ctx context.Context, principal identity.Principal, invitationID uint64, req RevokeInvitationRequest) (*InvitationSummaryData, error)
}

func (h *Handler) ListInvitations(c *gin.Context) {
	principal, ok := identity.PrincipalFromContext(c)
	if !ok {
		response.Failure(c, apperror.ErrAuthTokenExpired, nil)
		return
	}
	var query InvitationQuery
	if err := c.ShouldBindQuery(&query); err != nil {
		response.Failure(c, apperror.ErrValidationFailed, response.ValidationErrors(err))
		return
	}
	result, err := h.service.ListInvitations(c.Request.Context(), *principal, query)
	if err != nil {
		response.Failure(c, err, nil)
		return
	}
	response.Success(c, http.StatusOK, result)
}

func (h *Handler) RevealInvitation(c *gin.Context) {
	principal, ok := identity.PrincipalFromContext(c)
	if !ok {
		response.Failure(c, apperror.ErrAuthTokenExpired, nil)
		return
	}
	id, err := strconv.ParseUint(c.Param("invitation_id"), 10, 64)
	if err != nil || id == 0 {
		response.Failure(c, apperror.ErrValidationFailed, nil)
		return
	}
	result, err := h.service.RevealInvitation(c.Request.Context(), *principal, id)
	if err != nil {
		response.Failure(c, err, nil)
		return
	}
	c.Header("Cache-Control", "no-store")
	c.Header("Pragma", "no-cache")
	response.Success(c, http.StatusOK, result)
}

func (h *Handler) RevokeInvitation(c *gin.Context) {
	principal, ok := identity.PrincipalFromContext(c)
	if !ok {
		response.Failure(c, apperror.ErrAuthTokenExpired, nil)
		return
	}
	id, err := strconv.ParseUint(c.Param("invitation_id"), 10, 64)
	if err != nil || id == 0 {
		response.Failure(c, apperror.ErrValidationFailed, nil)
		return
	}
	var req RevokeInvitationRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		response.Failure(c, apperror.ErrValidationFailed, response.ValidationErrors(err))
		return
	}
	result, err := h.service.RevokeInvitation(c.Request.Context(), *principal, id, req)
	if err != nil {
		response.Failure(c, err, nil)
		return
	}
	response.Success(c, http.StatusOK, result)
}

type Handler struct {
	service OrganizationService
}

func NewHandler(service OrganizationService) *Handler { return &Handler{service: service} }

func (h *Handler) CreateInvitation(c *gin.Context) {
	principal, ok := identity.PrincipalFromContext(c)
	if !ok {
		response.Failure(c, apperror.ErrAuthTokenExpired, nil)
		return
	}
	var req CreateInvitationRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		response.Failure(c, apperror.ErrValidationFailed, response.ValidationErrors(err))
		return
	}
	result, err := h.service.CreateInvitation(c.Request.Context(), *principal, req)
	if err != nil {
		response.Failure(c, err, nil)
		return
	}
	response.Success(c, http.StatusCreated, result)
}

func (h *Handler) Register(c *gin.Context) {
	var req RegisterRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		response.Failure(c, apperror.ErrValidationFailed, response.ValidationErrors(err))
		return
	}
	result, err := h.service.Register(c.Request.Context(), req)
	if err != nil {
		response.Failure(c, err, nil)
		return
	}
	response.Success(c, http.StatusCreated, result)
}
