package dictionary

import (
	"context"
	"net/http"
	"strconv"

	"CBizDocsManager/backend/internal/identity"
	"CBizDocsManager/backend/pkg/apperror"
	"CBizDocsManager/backend/pkg/response"
	"github.com/gin-gonic/gin"
)

type DictionaryService interface {
	List(ctx context.Context, principal identity.Principal, query ListQuery) (Page, error)
	Create(ctx context.Context, principal identity.Principal, request CreateRequest) (Entry, error)
	Update(ctx context.Context, principal identity.Principal, id uint64, request UpdateRequest) (Entry, error)
	ChangeStatus(ctx context.Context, principal identity.Principal, id uint64, request ChangeStatusRequest) (Entry, error)
}

type Handler struct{ service DictionaryService }

func NewHandler(service DictionaryService) *Handler { return &Handler{service: service} }

func (h *Handler) List(c *gin.Context) {
	principal, ok := dictionaryPrincipalFromContext(c)
	if !ok {
		return
	}
	var query ListQuery
	if err := c.ShouldBindQuery(&query); err != nil {
		response.Failure(c, apperror.ErrValidationFailed, response.ValidationErrors(err))
		return
	}
	page, err := h.service.List(c.Request.Context(), *principal, query)
	if err != nil {
		response.Failure(c, err, nil)
		return
	}
	response.Success(c, http.StatusOK, PageData{Items: page.Items, Pagination: PaginationData{Page: page.Page, PageSize: page.PageSize, Total: page.Total}})
}

func (h *Handler) Create(c *gin.Context) {
	principal, ok := dictionaryPrincipalFromContext(c)
	if !ok {
		return
	}
	var request CreateRequest
	if err := c.ShouldBindJSON(&request); err != nil {
		response.Failure(c, apperror.ErrValidationFailed, response.ValidationErrors(err))
		return
	}
	result, err := h.service.Create(c.Request.Context(), *principal, request)
	if err != nil {
		response.Failure(c, err, nil)
		return
	}
	response.Success(c, http.StatusCreated, result)
}

func (h *Handler) Update(c *gin.Context) {
	principal, id, ok := dictionaryPrincipalAndID(c)
	if !ok {
		return
	}
	var request UpdateRequest
	if err := c.ShouldBindJSON(&request); err != nil {
		response.Failure(c, apperror.ErrValidationFailed, response.ValidationErrors(err))
		return
	}
	result, err := h.service.Update(c.Request.Context(), *principal, id, request)
	if err != nil {
		response.Failure(c, err, nil)
		return
	}
	response.Success(c, http.StatusOK, result)
}

func (h *Handler) ChangeStatus(c *gin.Context) {
	principal, id, ok := dictionaryPrincipalAndID(c)
	if !ok {
		return
	}
	var request ChangeStatusRequest
	if err := c.ShouldBindJSON(&request); err != nil {
		response.Failure(c, apperror.ErrValidationFailed, response.ValidationErrors(err))
		return
	}
	result, err := h.service.ChangeStatus(c.Request.Context(), *principal, id, request)
	if err != nil {
		response.Failure(c, err, nil)
		return
	}
	response.Success(c, http.StatusOK, result)
}

func dictionaryPrincipalFromContext(c *gin.Context) (*identity.Principal, bool) {
	principal, ok := identity.PrincipalFromContext(c)
	if !ok {
		response.Failure(c, apperror.ErrAuthTokenExpired, nil)
		return nil, false
	}
	return principal, true
}
func dictionaryPrincipalAndID(c *gin.Context) (*identity.Principal, uint64, bool) {
	principal, ok := dictionaryPrincipalFromContext(c)
	if !ok {
		return nil, 0, false
	}
	id, err := strconv.ParseUint(c.Param("dictionary_id"), 10, 64)
	if err != nil || id == 0 {
		response.Failure(c, apperror.ErrValidationFailed, nil)
		return nil, 0, false
	}
	return principal, id, true
}
