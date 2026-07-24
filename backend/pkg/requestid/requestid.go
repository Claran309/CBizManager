package requestid

import (
	"github.com/gin-gonic/gin"
	"github.com/google/uuid"
)

const (
	Header     = "X-Request-ID"
	contextKey = "request_id"
	maxLength  = 128
)

// Middleware 复用合法的上游请求 ID，否则生成 UUID，并同步写入响应头和 Gin 上下文。
func Middleware() gin.HandlerFunc {
	return func(c *gin.Context) {
		requestID := c.GetHeader(Header)
		if !isValid(requestID) {
			requestID = uuid.NewString()
		}

		c.Set(contextKey, requestID)
		c.Header(Header, requestID)
		c.Next()
	}
}

// FromContext 从 Gin 上下文读取当前请求 ID。
func FromContext(c *gin.Context) string {
	if c == nil {
		return ""
	}
	requestID, ok := c.Get(contextKey)
	if !ok {
		return ""
	}
	value, _ := requestID.(string)
	return value
}

func isValid(value string) bool {
	if len(value) == 0 || len(value) > maxLength {
		return false
	}
	for i := 0; i < len(value); i++ {
		char := value[i]
		if (char >= 'a' && char <= 'z') ||
			(char >= 'A' && char <= 'Z') ||
			(char >= '0' && char <= '9') ||
			char == '-' || char == '_' || char == '.' || char == ':' {
			continue
		}
		return false
	}
	return true
}
