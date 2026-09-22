package member

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"CBizDocsManager/backend/internal/authorization"
	"CBizDocsManager/backend/internal/identity"
	"CBizDocsManager/backend/internal/organization"
	"CBizDocsManager/backend/pkg/requestid"
	"github.com/gin-gonic/gin"
)

type memberServiceStub struct {
	page        Page
	member      Member
	permissions PermissionSet
	codes       []authorization.Code
	err         error
}

func (s *memberServiceStub) List(context.Context, identity.Principal, ListQuery) (Page, error) {
	return s.page, s.err
}
func (s *memberServiceStub) ChangeStatus(context.Context, identity.Principal, uint64, ChangeStatusRequest) (Member, error) {
	return s.member, s.err
}
func (s *memberServiceStub) GetPermissions(context.Context, identity.Principal, uint64) (PermissionSet, error) {
	return s.permissions, s.err
}
func (s *memberServiceStub) ReplacePermissions(context.Context, identity.Principal, uint64, ReplacePermissionsRequest) (PermissionSet, error) {
	return s.permissions, s.err
}
func (s *memberServiceStub) PermissionCatalog(context.Context, identity.Principal) ([]authorization.Code, error) {
	return s.codes, s.err
}

func memberHandlerRouter(service MemberService, withPrincipal bool) *gin.Engine {
	gin.SetMode(gin.TestMode)
	router := gin.New()
	router.Use(requestid.Middleware())
	if withPrincipal {
		router.Use(func(c *gin.Context) {
			groupID := uint64(7)
			identity.SetPrincipal(c, &identity.Principal{UserID: 10, GroupID: &groupID, AccountType: identity.AccountTypeGroupOwner, MemberType: "owner"})
			c.Next()
		})
	}
	handler := NewHandler(service)
	router.GET("/members", handler.List)
	router.PATCH("/members/:membership_id/status", handler.ChangeStatus)
	router.GET("/members/:membership_id/permissions", handler.GetPermissions)
	router.PUT("/members/:membership_id/permissions", handler.ReplacePermissions)
	router.GET("/permission-catalog", handler.PermissionCatalog)
	return router
}

func TestHandlerListReturnsNestedPaginationEnvelope(t *testing.T) {
	service := &memberServiceStub{page: Page{Items: []Member{{MembershipID: 21, GroupID: 7, Status: organization.MembershipStatusActive, Version: 1}}, Page: 2, PageSize: 10, Total: 11}}
	request := httptest.NewRequest(http.MethodGet, "/members?page=2&page_size=10", nil)
	writer := httptest.NewRecorder()
	memberHandlerRouter(service, true).ServeHTTP(writer, request)
	if writer.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", writer.Code, writer.Body.String())
	}
	var envelope struct {
		Data struct {
			Items      []Member `json:"items"`
			Pagination struct {
				Page     int   `json:"page"`
				PageSize int   `json:"page_size"`
				Total    int64 `json:"total"`
			} `json:"pagination"`
		} `json:"data"`
	}
	if err := json.Unmarshal(writer.Body.Bytes(), &envelope); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if len(envelope.Data.Items) != 1 || envelope.Data.Pagination.Page != 2 || envelope.Data.Pagination.Total != 11 {
		t.Fatalf("envelope=%+v", envelope)
	}
}

func TestHandlerValidatesMemberPathAndBody(t *testing.T) {
	router := memberHandlerRouter(&memberServiceStub{}, true)
	tests := []struct{ method, path, body string }{
		{http.MethodPatch, "/members/not-a-number/status", `{"status":"disabled","version":1}`},
		{http.MethodPatch, "/members/21/status", `{"status":"invalid","version":1}`},
		{http.MethodPut, "/members/21/permissions", `{"permission_codes":["member.manage"],"version":0}`},
	}
	for _, test := range tests {
		request := httptest.NewRequest(test.method, test.path, bytes.NewBufferString(test.body))
		request.Header.Set("Content-Type", "application/json")
		writer := httptest.NewRecorder()
		router.ServeHTTP(writer, request)
		if writer.Code != http.StatusBadRequest {
			t.Fatalf("%s %s status=%d body=%s", test.method, test.path, writer.Code, writer.Body.String())
		}
	}
}

func TestHandlerRequiresPrincipalAndReturnsCatalog(t *testing.T) {
	withoutPrincipal := memberHandlerRouter(&memberServiceStub{}, false)
	writer := httptest.NewRecorder()
	withoutPrincipal.ServeHTTP(writer, httptest.NewRequest(http.MethodGet, "/members", nil))
	if writer.Code != http.StatusUnauthorized {
		t.Fatalf("missing principal status=%d", writer.Code)
	}

	service := &memberServiceStub{codes: authorization.Catalog()}
	writer = httptest.NewRecorder()
	memberHandlerRouter(service, true).ServeHTTP(writer, httptest.NewRequest(http.MethodGet, "/permission-catalog", nil))
	if writer.Code != http.StatusOK {
		t.Fatalf("catalog status=%d body=%s", writer.Code, writer.Body.String())
	}
	var envelope struct {
		Data struct {
			Items []PermissionCatalogItem `json:"items"`
		} `json:"data"`
	}
	if err := json.Unmarshal(writer.Body.Bytes(), &envelope); err != nil {
		t.Fatalf("decode catalog: %v", err)
	}
	if len(envelope.Data.Items) != 7 || envelope.Data.Items[0].Name == "" || envelope.Data.Items[0].Description == "" {
		// 每一项都必须有中文文案：漏配一条会让前端权限勾选框显示空白。
		for _, item := range envelope.Data.Items {
			if item.Name == "" || item.Description == "" {
				t.Fatalf("permission %q missing label: %+v", item.Code, item)
			}
		}
		t.Fatalf("catalog=%+v", envelope.Data.Items)
	}
}
