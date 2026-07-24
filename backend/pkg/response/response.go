package response

import (
	"net/http"

	"CBizDocsManager/backend/pkg/apperror"
	"CBizDocsManager/backend/pkg/requestid"
	"github.com/gin-gonic/gin"
)

const (
	CodeOK    = "OK"
	MessageOK = "success"
)

// FieldError 描述单个请求字段的校验失败原因。
type FieldError struct {
	Field   string `json:"field"`
	Message string `json:"message"`
}

// Envelope 是所有 HTTP JSON 响应共用的稳定外层结构。
type Envelope struct {
	Code        string       `json:"code"`
	Message     string       `json:"message"`
	Data        any          `json:"data"`
	RequestID   string       `json:"request_id"`
	FieldErrors []FieldError `json:"field_errors,omitempty"`
}

// Success 写入成功响应；data 由具体 Handler 提供对象。
func Success(c *gin.Context, status int, data any) {
	c.JSON(status, Envelope{
		Code:      CodeOK,
		Message:   MessageOK,
		Data:      data,
		RequestID: requestid.FromContext(c),
	})
}

// Failure 将任意错误稳定映射为客户端可见的状态码与错误 Envelope。
func Failure(c *gin.Context, err error, fields []FieldError) {
	appErr := apperror.As(err)
	if appErr == nil {
		appErr = apperror.ErrInternal
	}
	if appErr.HTTPStatus < http.StatusBadRequest || appErr.HTTPStatus > 599 {
		appErr = apperror.ErrInternal
	}

	c.JSON(appErr.HTTPStatus, Envelope{
		Code:        appErr.Code,
		Message:     appErr.Message,
		Data:        nil,
		RequestID:   requestid.FromContext(c),
		FieldErrors: fields,
	})
}
