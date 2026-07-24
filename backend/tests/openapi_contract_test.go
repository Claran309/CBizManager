package tests

import (
	"context"
	"net/http"
	"path/filepath"
	"testing"

	"github.com/getkin/kin-openapi/openapi3"
)

func TestOpenAPIContract(t *testing.T) {
	contractPath := filepath.Join("..", "..", "api", "openapi", "cbizdocsmanager-v1.yaml")
	loader := openapi3.NewLoader()

	doc, err := loader.LoadFromFile(contractPath)
	if err != nil {
		t.Fatalf("load OpenAPI contract %q: %v", contractPath, err)
	}
	if err := doc.Validate(context.Background()); err != nil {
		t.Fatalf("validate OpenAPI contract: %v", err)
	}

	requiredOperations := []struct {
		method string
		path   string
	}{
		{method: http.MethodPost, path: "/api/v1/auth/login"},
		{method: http.MethodPost, path: "/api/v1/auth/register"},
		{method: http.MethodPost, path: "/api/v1/auth/refresh"},
		{method: http.MethodPost, path: "/api/v1/auth/logout"},
		{method: http.MethodGet, path: "/api/v1/auth/me"},
		{method: http.MethodPut, path: "/api/v1/auth/password"},
		{method: http.MethodPost, path: "/api/v1/platform/groups"},
		{method: http.MethodPost, path: "/api/v1/groups/invitations"},
		{method: http.MethodGet, path: "/health/live"},
		{method: http.MethodGet, path: "/health/ready"},
	}

	for _, required := range requiredOperations {
		t.Run(required.method+" "+required.path, func(t *testing.T) {
			pathItem := doc.Paths.Find(required.path)
			if pathItem == nil {
				t.Fatalf("missing path %s", required.path)
			}
			operation := pathItem.GetOperation(required.method)
			if operation == nil {
				t.Fatalf("missing operation %s %s", required.method, required.path)
			}
			if operation.OperationID == "" {
				t.Fatalf("operation %s %s must define operationId", required.method, required.path)
			}
		})
	}

	livenessPath := doc.Paths.Find("/health/live")
	if livenessPath == nil {
		t.Fatal("missing path /health/live")
	}
	livenessOperation := livenessPath.GetOperation(http.MethodGet)
	if livenessOperation == nil || livenessOperation.Responses == nil {
		t.Fatal("GET /health/live must define responses")
	}
	if livenessOperation.Responses.Len() != 1 {
		t.Errorf("GET /health/live response count = %d, want exactly 1", livenessOperation.Responses.Len())
	}
	if livenessOperation.Responses.Value("200") == nil {
		t.Error("GET /health/live responses must contain 200")
	}
	if livenessOperation.Responses.Value("500") != nil {
		t.Error("GET /health/live responses must not contain 500")
	}

	apiResponse := requireSchema(t, doc, "ApiResponse")
	for _, property := range []string{"code", "message", "data", "request_id"} {
		if _, ok := apiResponse.Properties[property]; !ok {
			t.Errorf("ApiResponse is missing property %q", property)
		}
		if !containsString(apiResponse.Required, property) {
			t.Errorf("ApiResponse must require property %q", property)
		}
	}

	userSummary := requireSchema(t, doc, "UserSummary")
	accountTypeRef, ok := userSummary.Properties["account_type"]
	if !ok || accountTypeRef == nil || accountTypeRef.Value == nil {
		t.Fatal("UserSummary is missing account_type schema")
	}
	accountType := accountTypeRef.Value
	wantAccountTypes := []string{"platform_admin", "group_owner", "member"}
	if len(accountType.Enum) != len(wantAccountTypes) {
		t.Errorf("UserSummary.account_type enum = %#v, want exactly %#v", accountType.Enum, wantAccountTypes)
	}
	for _, accountTypeValue := range wantAccountTypes {
		if !containsEnumString(accountType.Enum, accountTypeValue) {
			t.Errorf("UserSummary.account_type enum is missing %q", accountTypeValue)
		}
	}
	if containsEnumString(accountType.Enum, "group_member") {
		t.Error("UserSummary.account_type enum must not contain \"group_member\"")
	}

	errorCode := requireSchema(t, doc, "ErrorCode")
	requiredErrorCodes := []string{
		"VALIDATION_FAILED",
		"AUTH_INVALID_CREDENTIALS",
		"AUTH_TOKEN_EXPIRED",
		"AUTH_REFRESH_INVALID",
		"AUTH_PASSWORD_CHANGE_REQUIRED",
		"USER_USERNAME_EXISTS",
		"INVITATION_INVALID",
		"INVITATION_EXPIRED",
		"INVITATION_USED",
		"GROUP_NAME_EXISTS",
		"FORBIDDEN",
		"INTERNAL_ERROR",
	}
	for _, code := range requiredErrorCodes {
		if !containsEnumString(errorCode.Enum, code) {
			t.Errorf("ErrorCode enum is missing %q", code)
		}
	}

	healthData := requireSchema(t, doc, "HealthData")
	for _, property := range []string{"status", "mysql", "redis"} {
		if _, ok := healthData.Properties[property]; !ok {
			t.Errorf("HealthData is missing property %q", property)
		}
	}
	if !containsString(healthData.Required, "status") {
		t.Error("HealthData must require property \"status\"")
	}
	for _, optionalProperty := range []string{"mysql", "redis"} {
		if containsString(healthData.Required, optionalProperty) {
			t.Errorf("HealthData property %q must remain optional for /health/live", optionalProperty)
		}
	}
	assertSchemaEnum(t, healthData, "status", []string{"ok", "unavailable"})
	assertSchemaEnum(t, healthData, "mysql", []string{"up", "down"})
	assertSchemaEnum(t, healthData, "redis", []string{"up", "down", "disabled"})
}

func assertSchemaEnum(t *testing.T, schema *openapi3.Schema, property string, values []string) {
	t.Helper()
	propertyRef, ok := schema.Properties[property]
	if !ok || propertyRef == nil || propertyRef.Value == nil {
		t.Fatalf("schema is missing property %q", property)
	}
	for _, value := range values {
		if !containsEnumString(propertyRef.Value.Enum, value) {
			t.Errorf("%s enum is missing %q", property, value)
		}
	}
}

func requireSchema(t *testing.T, doc *openapi3.T, name string) *openapi3.Schema {
	t.Helper()

	if doc.Components == nil {
		t.Fatal("OpenAPI contract is missing components")
	}
	schemaRef, ok := doc.Components.Schemas[name]
	if !ok || schemaRef == nil || schemaRef.Value == nil {
		t.Fatalf("OpenAPI contract is missing schema %q", name)
	}
	return schemaRef.Value
}

func containsString(values []string, wanted string) bool {
	for _, value := range values {
		if value == wanted {
			return true
		}
	}
	return false
}

func containsEnumString(values []any, wanted string) bool {
	for _, value := range values {
		if value == wanted {
			return true
		}
	}
	return false
}
