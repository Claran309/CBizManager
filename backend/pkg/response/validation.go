package response

import (
	"errors"
	"strings"

	"github.com/go-playground/validator/v10"
)

func ValidationErrors(err error) []FieldError {
	var validationErrors validator.ValidationErrors
	if !errors.As(err, &validationErrors) {
		return []FieldError{{Field: "body", Message: "请求体格式不正确"}}
	}
	fields := make([]FieldError, 0, len(validationErrors))
	for _, fieldError := range validationErrors {
		message := "字段不合法"
		switch fieldError.Tag() {
		case "required":
			message = "字段不能为空"
		case "min":
			message = "字段长度不足"
		case "max":
			message = "字段超过允许范围"
		}
		fields = append(fields, FieldError{Field: snakeCase(fieldError.Field()), Message: message})
	}
	return fields
}

func snakeCase(value string) string {
	var result strings.Builder
	result.Grow(len(value) + 4)
	for index, char := range value {
		if char >= 'A' && char <= 'Z' {
			if index > 0 {
				result.WriteByte('_')
			}
			result.WriteByte(byte(char - 'A' + 'a'))
			continue
		}
		result.WriteRune(char)
	}
	return result.String()
}
