package platform

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"CBizDocsManager/backend/internal/identity"
	"CBizDocsManager/backend/pkg/requestid"
	"CBizDocsManager/backend/pkg/response"
	"github.com/gin-gonic/gin"
)

func TestHandlerCreateGroupReturnsCreatedWithoutTemporaryPassword(t *testing.T) {
	gin.SetMode(gin.TestMode)
	repo := &fakePlatformRepository{}
	service := NewService(repo, platformPasswordManager{})
	handler := NewHandler(service)
	router := gin.New()
	router.Use(requestid.Middleware(), func(c *gin.Context) {
		identity.SetPrincipal(c, &identity.Principal{UserID: 1, AccountType: identity.AccountTypePlatformAdmin})
		c.Next()
	})
	router.POST("/groups", handler.CreateGroup)
	body := `{"name":"Finance","owner_username":"owner","owner_display_name":"Owner","owner_temporary_password":"temporary-password"}`
	request := httptest.NewRequest(http.MethodPost, "/groups", bytes.NewBufferString(body))
	request.Header.Set("Content-Type", "application/json")
	writer := httptest.NewRecorder()
	router.ServeHTTP(writer, request)

	if writer.Code != http.StatusCreated {
		t.Fatalf("status=%d want=201 body=%s", writer.Code, writer.Body.String())
	}
	if strings.Contains(writer.Body.String(), "temporary-password") || strings.Contains(writer.Body.String(), "password") {
		t.Fatalf("response leaked password field/value: %s", writer.Body.String())
	}
	var envelope struct {
		Code string           `json:"code"`
		Data GroupCreatedData `json:"data"`
	}
	if err := json.Unmarshal(writer.Body.Bytes(), &envelope); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if envelope.Code != response.CodeOK || envelope.Data.Group.ID == 0 || envelope.Data.Owner.ID == 0 {
		t.Fatalf("response=%+v", envelope)
	}
}

func TestHandlerCreateGroupValidatesTemporaryPassword(t *testing.T) {
	gin.SetMode(gin.TestMode)
	handler := NewHandler(NewService(&fakePlatformRepository{}, platformPasswordManager{}))
	router := gin.New()
	router.Use(requestid.Middleware(), func(c *gin.Context) {
		identity.SetPrincipal(c, &identity.Principal{UserID: 1, AccountType: identity.AccountTypePlatformAdmin})
		c.Next()
	})
	router.POST("/groups", handler.CreateGroup)
	request := httptest.NewRequest(http.MethodPost, "/groups", bytes.NewBufferString(`{"name":"Finance","owner_username":"owner","owner_display_name":"Owner","owner_temporary_password":"short"}`))
	request.Header.Set("Content-Type", "application/json")
	writer := httptest.NewRecorder()
	router.ServeHTTP(writer, request)
	if writer.Code != http.StatusBadRequest || !strings.Contains(writer.Body.String(), "VALIDATION_FAILED") {
		t.Fatalf("status=%d body=%s", writer.Code, writer.Body.String())
	}
}
