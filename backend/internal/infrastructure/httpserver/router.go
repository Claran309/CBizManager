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
	Login            gin.HandlerFunc
	Register         gin.HandlerFunc
	Refresh          gin.HandlerFunc
	Logout           gin.HandlerFunc
	Me               gin.HandlerFunc
	ChangePassword   gin.HandlerFunc
	CreateGroup      gin.HandlerFunc
	CreateInvitation gin.HandlerFunc
}

type RouterDependencies struct {
	Logger        *zap.Logger
	CORS          config.CORSConfig
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

	authenticated := api.Group("")
	authenticated.Use(Authentication(deps.Authenticator))
	authenticated.GET("/auth/me", deps.Routes.Me)
	authenticated.PUT("/auth/password", deps.Routes.ChangePassword)
	authenticated.POST("/auth/logout", deps.Routes.Logout)

	platform := authenticated.Group("/platform")
	platform.Use(RequirePasswordChanged(), RequirePlatformAdmin())
	platform.POST("/groups", deps.Routes.CreateGroup)

	groups := authenticated.Group("/groups")
	groups.Use(RequirePasswordChanged(), RequireGroupOwner())
	groups.POST("/invitations", deps.Routes.CreateInvitation)
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
