package httpserver

import (
	"context"
	"net/http"
	"runtime/debug"
	"strconv"
	"strings"
	"time"

	"CBizDocsManager/backend/internal/identity"
	"CBizDocsManager/backend/pkg/apperror"
	"CBizDocsManager/backend/pkg/config"
	"CBizDocsManager/backend/pkg/requestid"
	"CBizDocsManager/backend/pkg/response"
	"github.com/gin-gonic/gin"
	"go.uber.org/zap"
)

type Authenticator interface {
	Authenticate(ctx context.Context, rawAccessToken string) (*identity.Principal, error)
}

func Authentication(authenticator Authenticator) gin.HandlerFunc {
	return func(c *gin.Context) {
		parts := strings.Fields(c.GetHeader("Authorization"))
		if len(parts) != 2 || !strings.EqualFold(parts[0], "Bearer") || parts[1] == "" {
			response.Failure(c, apperror.ErrAuthTokenExpired, nil)
			c.Abort()
			return
		}
		principal, err := authenticator.Authenticate(c.Request.Context(), parts[1])
		if err != nil {
			response.Failure(c, err, nil)
			c.Abort()
			return
		}
		identity.SetPrincipal(c, principal)
		c.Next()
	}
}

func RequirePasswordChanged() gin.HandlerFunc {
	return func(c *gin.Context) {
		principal, ok := identity.PrincipalFromContext(c)
		if !ok {
			response.Failure(c, apperror.ErrAuthTokenExpired, nil)
			c.Abort()
			return
		}
		if principal.MustChangePassword {
			response.Failure(c, apperror.ErrAuthPasswordChangeRequired, nil)
			c.Abort()
			return
		}
		c.Next()
	}
}

func RequirePlatformAdmin() gin.HandlerFunc {
	return requireRole(func(principal *identity.Principal) bool {
		return principal.AccountType == identity.AccountTypePlatformAdmin
	})
}

func RequireGroupOwner() gin.HandlerFunc {
	return requireRole(func(principal *identity.Principal) bool {
		return principal.AccountType == identity.AccountTypeGroupOwner && principal.MemberType == "owner"
	})
}

func requireRole(allowed func(*identity.Principal) bool) gin.HandlerFunc {
	return func(c *gin.Context) {
		principal, ok := identity.PrincipalFromContext(c)
		if !ok {
			response.Failure(c, apperror.ErrAuthTokenExpired, nil)
			c.Abort()
			return
		}
		if !allowed(principal) {
			response.Failure(c, apperror.ErrForbidden, nil)
			c.Abort()
			return
		}
		c.Next()
	}
}

func Recovery(log *zap.Logger) gin.HandlerFunc {
	if log == nil {
		log = zap.NewNop()
	}
	return func(c *gin.Context) {
		defer func() {
			if recover() == nil {
				return
			}
			log.Error("请求处理发生 panic",
				zap.String("request_id", requestid.FromContext(c)),
				zap.ByteString("stack", debug.Stack()),
			)
			if !c.Writer.Written() {
				response.Failure(c, apperror.ErrInternal, nil)
			}
			c.Abort()
		}()
		c.Next()
	}
}

func AccessLog(log *zap.Logger) gin.HandlerFunc {
	if log == nil {
		log = zap.NewNop()
	}
	return func(c *gin.Context) {
		startedAt := time.Now()
		defer func() {
			if panicValue := recover(); panicValue != nil {
				writeAccessLog(log, c, http.StatusInternalServerError, startedAt)
				panic(panicValue)
			}
			writeAccessLog(log, c, c.Writer.Status(), startedAt)
		}()
		c.Next()
	}
}

func writeAccessLog(log *zap.Logger, c *gin.Context, status int, startedAt time.Time) {
	log.Info("HTTP 请求",
		zap.String("request_id", requestid.FromContext(c)),
		zap.String("method", c.Request.Method),
		zap.String("path", c.Request.URL.Path),
		zap.Int("status", status),
		zap.Duration("duration", time.Since(startedAt)),
	)
}

func CORS(cfg config.CORSConfig) gin.HandlerFunc {
	allowedOrigins := make(map[string]struct{}, len(cfg.AllowedOrigins))
	allowAny := false
	for _, origin := range cfg.AllowedOrigins {
		origin = strings.TrimSpace(origin)
		if origin == "*" && !cfg.AllowCredentials {
			allowAny = true
			continue
		}
		if origin != "" {
			allowedOrigins[origin] = struct{}{}
		}
	}
	return func(c *gin.Context) {
		origin := c.GetHeader("Origin")
		if origin != "" {
			_, explicitlyAllowed := allowedOrigins[origin]
			if allowAny || explicitlyAllowed {
				if allowAny {
					c.Header("Access-Control-Allow-Origin", "*")
				} else {
					c.Header("Access-Control-Allow-Origin", origin)
					c.Header("Vary", "Origin")
				}
				c.Header("Access-Control-Allow-Methods", strings.Join(cfg.AllowedMethods, ", "))
				c.Header("Access-Control-Allow-Headers", strings.Join(cfg.AllowedHeaders, ", "))
				if cfg.AllowCredentials {
					c.Header("Access-Control-Allow-Credentials", "true")
				}
				if cfg.MaxAge > 0 {
					c.Header("Access-Control-Max-Age", formatMaxAge(cfg.MaxAge))
				}
			}
		}
		if c.Request.Method == http.MethodOptions {
			c.AbortWithStatus(http.StatusNoContent)
			return
		}
		c.Next()
	}
}

func formatMaxAge(duration time.Duration) string {
	seconds := int64(duration / time.Second)
	if seconds < 0 {
		seconds = 0
	}
	return strconv.FormatInt(seconds, 10)
}
