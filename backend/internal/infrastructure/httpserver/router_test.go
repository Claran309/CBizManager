package httpserver

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"sort"
	"strings"
	"testing"

	"CBizDocsManager/backend/internal/identity"
	"CBizDocsManager/backend/pkg/config"
	"CBizDocsManager/backend/pkg/response"
	"github.com/gin-gonic/gin"
	"go.uber.org/zap"
)

func TestRoutesRegistersOpenAPIEndpoints(t *testing.T) {
	gin.SetMode(gin.TestMode)
	router := NewRouter(RouterDependencies{
		Logger: zap.NewNop(), Authenticator: routerAuthenticator{}, Health: &stubHealth{redis: "disabled"},
		Routes: noOpRouteHandlers(), CORS: config.CORSConfig{}, WebAuth: config.WebAuthConfig{Enabled: true},
	})
	got := make([]string, 0, len(router.Routes()))
	for _, route := range router.Routes() {
		got = append(got, route.Method+" "+route.Path)
	}
	sort.Strings(got)
	want := []string{
		"GET /api/v1/auth/me", "GET /api/v1/groups/members", "GET /api/v1/groups/members/:membership_id/permissions",
		"GET /api/v1/groups/permission-catalog", "GET /api/v1/dictionaries", "GET /health/live", "GET /health/ready",
		"GET /api/v1/platform/groups", "GET /api/v1/platform/groups/:group_id",
		"GET /api/v1/groups/invitations",
		"GET /api/v1/inbound-documents", "GET /api/v1/inbound-documents/:document_id",
		"GET /api/v1/inbound-documents/monthly-summary",
		"GET /api/v1/outbound-documents", "GET /api/v1/outbound-documents/:document_id",
		"GET /api/v1/outbound-documents/monthly-summary",
		"POST /api/v1/auth/login", "POST /api/v1/auth/logout", "POST /api/v1/auth/refresh",
		"POST /api/v1/auth/register", "POST /api/v1/auth/web/login", "POST /api/v1/auth/web/logout", "POST /api/v1/auth/web/refresh",
		"POST /api/v1/groups/invitations", "POST /api/v1/platform/groups", "POST /api/v1/dictionaries",
		"POST /api/v1/groups/invitations/:invitation_id/secret", "POST /api/v1/groups/invitations/:invitation_id/revoke",
		"POST /api/v1/inbound-documents", "POST /api/v1/inbound-documents/:document_id/submit",
		"POST /api/v1/inbound-documents/:document_id/void",
		"POST /api/v1/outbound-documents", "POST /api/v1/outbound-documents/:document_id/submit",
		"POST /api/v1/outbound-documents/:document_id/void",
		"PATCH /api/v1/groups/members/:membership_id/status", "PATCH /api/v1/dictionaries/:dictionary_id/status",
		"PATCH /api/v1/platform/groups/:group_id/status",
		"PUT /api/v1/auth/password", "PUT /api/v1/groups/members/:membership_id/permissions", "PUT /api/v1/dictionaries/:dictionary_id",
		"PUT /api/v1/platform/groups/:group_id/owner",
		"PUT /api/v1/inbound-documents/:document_id", "PUT /api/v1/outbound-documents/:document_id",
	}
	sort.Strings(want)
	if strings.Join(got, "\n") != strings.Join(want, "\n") {
		t.Fatalf("routes=\n%s\nwant=\n%s", strings.Join(got, "\n"), strings.Join(want, "\n"))
	}
}

func TestHealthReadinessDependsOnlyOnMySQL(t *testing.T) {
	gin.SetMode(gin.TestMode)
	tests := []struct {
		name       string
		mysqlErr   error
		redis      string
		wantStatus int
		wantMySQL  string
	}{
		{name: "all up", redis: "up", wantStatus: http.StatusOK, wantMySQL: "up"},
		{name: "redis degraded", redis: "down", wantStatus: http.StatusOK, wantMySQL: "up"},
		{name: "mysql down", mysqlErr: errors.New("mysql unavailable"), redis: "up", wantStatus: http.StatusServiceUnavailable, wantMySQL: "down"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			health := &stubHealth{mysqlErr: tt.mysqlErr, redis: tt.redis}
			router := NewRouter(RouterDependencies{
				Logger: zap.NewNop(), Authenticator: routerAuthenticator{}, Health: health,
				Routes: noOpRouteHandlers(), CORS: config.CORSConfig{},
			})

			live := httptest.NewRecorder()
			router.ServeHTTP(live, httptest.NewRequest(http.MethodGet, "/health/live", nil))
			if live.Code != http.StatusOK {
				t.Fatalf("live status=%d body=%s", live.Code, live.Body.String())
			}
			ready := httptest.NewRecorder()
			router.ServeHTTP(ready, httptest.NewRequest(http.MethodGet, "/health/ready", nil))
			if ready.Code != tt.wantStatus {
				t.Fatalf("ready status=%d want=%d body=%s", ready.Code, tt.wantStatus, ready.Body.String())
			}
			var envelope struct {
				Code string `json:"code"`
				Data struct {
					Status string `json:"status"`
					MySQL  string `json:"mysql"`
					Redis  string `json:"redis"`
				} `json:"data"`
			}
			if err := json.Unmarshal(ready.Body.Bytes(), &envelope); err != nil {
				t.Fatalf("decode ready response: %v", err)
			}
			if envelope.Data.MySQL != tt.wantMySQL || envelope.Data.Redis != tt.redis {
				t.Fatalf("ready data=%+v", envelope.Data)
			}
			wantHealthStatus := "ok"
			if tt.mysqlErr != nil {
				wantHealthStatus = "unavailable"
			}
			if envelope.Data.Status != wantHealthStatus {
				t.Fatalf("ready health status=%q want=%q", envelope.Data.Status, wantHealthStatus)
			}
			if tt.mysqlErr == nil && envelope.Code != response.CodeOK {
				t.Fatalf("ready code=%q want OK", envelope.Code)
			}
		})
	}
}

type stubHealth struct {
	mysqlErr error
	redis    string
}

func (h *stubHealth) PingMySQL(context.Context) error   { return h.mysqlErr }
func (h *stubHealth) RedisState(context.Context) string { return h.redis }

type routerAuthenticator struct{}

func (routerAuthenticator) Authenticate(context.Context, string) (*identity.Principal, error) {
	return &identity.Principal{UserID: 1, AccountType: identity.AccountTypePlatformAdmin, SessionID: 1}, nil
}

func noOpRouteHandlers() RouteHandlers {
	noContent := func(c *gin.Context) { c.Status(http.StatusNoContent) }
	documentRoutes := DocumentRouteSet{
		Create: noContent, List: noContent, Get: noContent, Update: noContent,
		Submit: noContent, Void: noContent, MonthlySummary: noContent,
	}
	return RouteHandlers{
		Login: noContent, Register: noContent, Refresh: noContent, Logout: noContent,
		Me: noContent, ChangePassword: noContent, CreateGroup: noContent, CreateInvitation: noContent,
		ListGroups: noContent, GetGroup: noContent, ChangeGroupStatus: noContent, ChangeGroupOwner: noContent,
		ListInvitations: noContent, RevealInvitation: noContent, RevokeInvitation: noContent,
		WebLogin: noContent, WebRefresh: noContent, WebLogout: noContent,
		ListMembers: noContent, ChangeMemberStatus: noContent, GetMemberPermissions: noContent,
		ReplaceMemberPermissions: noContent, PermissionCatalog: noContent,
		ListDictionaries: noContent, CreateDictionary: noContent, UpdateDictionary: noContent, ChangeDictionaryStatus: noContent,
		InboundDocuments: documentRoutes, OutboundDocuments: documentRoutes,
	}
}
