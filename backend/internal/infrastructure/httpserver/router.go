package httpserver

import (
	"context"
	"net/http"

	"CBizDocsManager/backend/pkg/apperror"
	"CBizDocsManager/backend/pkg/config"
	"CBizDocsManager/backend/pkg/requestid"
	"CBizDocsManager/backend/pkg/response"
	"github.com/gin-gonic/gin"
	"go.uber.org/zap"
)

type HealthChecker interface {
	PingMySQL(ctx context.Context) error
	RedisState(ctx context.Context) string
}

type RouteHandlers struct {
	Login                    gin.HandlerFunc
	Register                 gin.HandlerFunc
	Refresh                  gin.HandlerFunc
	Logout                   gin.HandlerFunc
	Me                       gin.HandlerFunc
	ChangePassword           gin.HandlerFunc
	CreateGroup              gin.HandlerFunc
	ListGroups               gin.HandlerFunc
	GetGroup                 gin.HandlerFunc
	ChangeGroupStatus        gin.HandlerFunc
	ChangeGroupOwner         gin.HandlerFunc
	CreateInvitation         gin.HandlerFunc
	ListInvitations          gin.HandlerFunc
	RevealInvitation         gin.HandlerFunc
	RevokeInvitation         gin.HandlerFunc
	WebLogin                 gin.HandlerFunc
	WebRefresh               gin.HandlerFunc
	WebLogout                gin.HandlerFunc
	ListMembers              gin.HandlerFunc
	ChangeMemberStatus       gin.HandlerFunc
	GetMemberPermissions     gin.HandlerFunc
	ReplaceMemberPermissions gin.HandlerFunc
	PermissionCatalog        gin.HandlerFunc
	ListDictionaries         gin.HandlerFunc
	CreateDictionary         gin.HandlerFunc
	UpdateDictionary         gin.HandlerFunc
	ChangeDictionaryStatus   gin.HandlerFunc
}

type RouterDependencies struct {
	Logger        *zap.Logger
	CORS          config.CORSConfig
	WebAuth       config.WebAuthConfig
	Authenticator Authenticator
	Health        HealthChecker
	Routes        RouteHandlers
}

func NewRouter(deps RouterDependencies) *gin.Engine {
	gin.EnableJsonDecoderDisallowUnknownFields()
	router := gin.New()
	router.Use(requestid.Middleware(), Recovery(deps.Logger), AccessLog(deps.Logger), CORS(deps.CORS))

	router.GET("/health/live", liveness)
	router.GET("/health/ready", readiness(deps.Health))

	api := router.Group("/api/v1")
	auth := api.Group("/auth")
	auth.POST("/login", deps.Routes.Login)
	auth.POST("/register", deps.Routes.Register)
	auth.POST("/refresh", deps.Routes.Refresh)
	if deps.WebAuth.Enabled {
		web := auth.Group("/web")
		web.Use(RequireWebOrigin(deps.WebAuth))
		web.POST("/login", deps.Routes.WebLogin)
		web.POST("/refresh", RequireCSRF(deps.WebAuth), deps.Routes.WebRefresh)
		web.POST("/logout", RequireCSRF(deps.WebAuth), deps.Routes.WebLogout)
	}

	authenticated := api.Group("")
	authenticated.Use(Authentication(deps.Authenticator))
	authenticated.GET("/auth/me", deps.Routes.Me)
	authenticated.PUT("/auth/password", deps.Routes.ChangePassword)
	authenticated.POST("/auth/logout", deps.Routes.Logout)

	// 平台治理：仅平台管理员可创建业务组、查看组列表与详情、启停组、交接主账号。
	platform := authenticated.Group("/platform")
	platform.Use(RequirePasswordChanged(), RequirePlatformAdmin())
	platform.POST("/groups", deps.Routes.CreateGroup)
	platform.GET("/groups", deps.Routes.ListGroups)
	platform.GET("/groups/:group_id", deps.Routes.GetGroup)
	platform.PATCH("/groups/:group_id/status", deps.Routes.ChangeGroupStatus)
	platform.PUT("/groups/:group_id/owner", deps.Routes.ChangeGroupOwner)

	// 租户域：组内成员管理、邀请码、字典。RequireTenantGroup 保证只有组内身份能进入。
	tenant := authenticated.Group("")
	tenant.Use(RequirePasswordChanged(), RequireTenantGroup())
	// 邀请码的「签发 / 查看明文 / 撤销」属于主账号专属能力，单独再收一层 RequireGroupOwner。
	invitations := tenant.Group("/groups/invitations")
	invitations.Use(RequireGroupOwner())
	invitations.POST("", deps.Routes.CreateInvitation)
	invitations.GET("", deps.Routes.ListInvitations)
	invitations.POST("/:invitation_id/secret", deps.Routes.RevealInvitation)
	invitations.POST("/:invitation_id/revoke", deps.Routes.RevokeInvitation)

	groups := tenant.Group("/groups")
	groups.GET("/members", deps.Routes.ListMembers)
	groups.PATCH("/members/:membership_id/status", deps.Routes.ChangeMemberStatus)
	groups.GET("/members/:membership_id/permissions", deps.Routes.GetMemberPermissions)
	groups.PUT("/members/:membership_id/permissions", deps.Routes.ReplaceMemberPermissions)
	groups.GET("/permission-catalog", deps.Routes.PermissionCatalog)

	tenant.GET("/dictionaries", deps.Routes.ListDictionaries)
	tenant.POST("/dictionaries", deps.Routes.CreateDictionary)
	tenant.PUT("/dictionaries/:dictionary_id", deps.Routes.UpdateDictionary)
	tenant.PATCH("/dictionaries/:dictionary_id/status", deps.Routes.ChangeDictionaryStatus)
	return router
}

func liveness(c *gin.Context) {
	response.Success(c, http.StatusOK, gin.H{"status": "ok"})
}

func readiness(health HealthChecker) gin.HandlerFunc {
	return func(c *gin.Context) {
		mysqlState := "down"
		redisState := "disabled"
		var mysqlErr error
		if health != nil {
			mysqlErr = health.PingMySQL(c.Request.Context())
			redisState = health.RedisState(c.Request.Context())
		}
		if mysqlErr == nil && health != nil {
			mysqlState = "up"
		}
		status := "ok"
		if mysqlErr != nil || health == nil {
			status = "unavailable"
		}
		data := gin.H{"status": status, "mysql": mysqlState, "redis": redisState}
		if mysqlErr != nil || health == nil {
			c.JSON(http.StatusServiceUnavailable, response.Envelope{
				Code: apperror.CodeInternalError, Message: apperror.ErrInternal.Message,
				Data: data, RequestID: requestid.FromContext(c),
			})
			return
		}
		response.Success(c, http.StatusOK, data)
	}
}
