package organization

import (
	"context"
	"net/http"

	"CBizDocsManager/backend/internal/identity"
	"CBizDocsManager/backend/pkg/apperror"
	"CBizDocsManager/backend/pkg/response"
	"github.com/gin-gonic/gin"
)

type OrganizationService interface {
	CreateInvitation(ctx context.Context, principal identity.Principal, req CreateInvitationRequest) (*InvitationCreatedData, error)
	Register(ctx context.Context, req RegisterRequest) (*RegisterData, error)
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
