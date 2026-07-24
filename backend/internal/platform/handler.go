package platform

import (
	"context"
	"net/http"

	"CBizDocsManager/backend/internal/identity"
	"CBizDocsManager/backend/pkg/apperror"
	"CBizDocsManager/backend/pkg/response"
	"github.com/gin-gonic/gin"
)

type PlatformService interface {
	CreateGroup(ctx context.Context, principal identity.Principal, req CreateGroupRequest) (*GroupCreatedData, error)
}

type Handler struct {
	service PlatformService
}

func NewHandler(service PlatformService) *Handler { return &Handler{service: service} }

func (h *Handler) CreateGroup(c *gin.Context) {
	principal, ok := identity.PrincipalFromContext(c)
	if !ok {
		response.Failure(c, apperror.ErrAuthTokenExpired, nil)
		return
	}
	var req CreateGroupRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		response.Failure(c, apperror.ErrValidationFailed, response.ValidationErrors(err))
		return
	}
	result, err := h.service.CreateGroup(c.Request.Context(), *principal, req)
	if err != nil {
		response.Failure(c, err, nil)
		return
	}
	response.Success(c, http.StatusCreated, result)
}
