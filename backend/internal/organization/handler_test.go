package organization

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"CBizDocsManager/backend/internal/identity"
	"CBizDocsManager/backend/pkg/requestid"
	"CBizDocsManager/backend/pkg/response"
	"github.com/gin-gonic/gin"
)

func TestHandlerCreatesInvitationAndRegistersMember(t *testing.T) {
	gin.SetMode(gin.TestMode)
	repo := newFakeOrganizationRepository()
	service := NewService(repo, organizationPasswordManager{})
	handler := NewHandler(service)
	groupID := uint64(17)
	router := gin.New()
	router.Use(requestid.Middleware())
	router.POST("/register", handler.Register)
	router.POST("/invitations", func(c *gin.Context) {
		identity.SetPrincipal(c, &identity.Principal{
			UserID: 5, GroupID: &groupID, GroupName: "Finance",
			AccountType: identity.AccountTypeGroupOwner, MemberType: "owner",
		})
		handler.CreateInvitation(c)
	})

	invitationRequest := httptest.NewRequest(http.MethodPost, "/invitations", bytes.NewBufferString(`{}`))
	invitationRequest.Header.Set("Content-Type", "application/json")
	invitationWriter := httptest.NewRecorder()
	router.ServeHTTP(invitationWriter, invitationRequest)
	if invitationWriter.Code != http.StatusCreated {
		t.Fatalf("invitation status=%d body=%s", invitationWriter.Code, invitationWriter.Body.String())
	}
	var invitationEnvelope struct {
		Data InvitationCreatedData `json:"data"`
	}
	if err := json.Unmarshal(invitationWriter.Body.Bytes(), &invitationEnvelope); err != nil {
		t.Fatalf("decode invitation response: %v", err)
	}
	if invitationEnvelope.Data.InvitationCode == "" || invitationEnvelope.Data.Group.ID != groupID {
		t.Fatalf("invitation response=%+v", invitationEnvelope)
	}

	registerBody := `{"invitation_code":"code","username":"member","password":"member-password","display_name":"Member"}`
	registerRequest := httptest.NewRequest(http.MethodPost, "/register", bytes.NewBufferString(registerBody))
	registerRequest.Header.Set("Content-Type", "application/json")
	registerWriter := httptest.NewRecorder()
	router.ServeHTTP(registerWriter, registerRequest)
	if registerWriter.Code != http.StatusCreated {
		t.Fatalf("register status=%d body=%s", registerWriter.Code, registerWriter.Body.String())
	}
	var registerEnvelope struct {
		Code string       `json:"code"`
		Data RegisterData `json:"data"`
	}
	if err := json.Unmarshal(registerWriter.Body.Bytes(), &registerEnvelope); err != nil {
		t.Fatalf("decode register response: %v", err)
	}
	if registerEnvelope.Code != response.CodeOK || registerEnvelope.Data.User.AccountType != identity.AccountTypeMember {
		t.Fatalf("register response=%+v", registerEnvelope)
	}
}

func TestHandlerRejectsInvitationExpiryOutsideContract(t *testing.T) {
	gin.SetMode(gin.TestMode)
	service := NewService(newFakeOrganizationRepository(), organizationPasswordManager{})
	handler := NewHandler(service)
	groupID := uint64(1)
	router := gin.New()
	router.Use(requestid.Middleware(), func(c *gin.Context) {
		identity.SetPrincipal(c, &identity.Principal{UserID: 1, GroupID: &groupID, AccountType: identity.AccountTypeGroupOwner, MemberType: "owner"})
		c.Next()
	})
	router.POST("/invitations", handler.CreateInvitation)
	request := httptest.NewRequest(http.MethodPost, "/invitations", bytes.NewBufferString(`{"expires_in_days":31}`))
	request.Header.Set("Content-Type", "application/json")
	writer := httptest.NewRecorder()
	router.ServeHTTP(writer, request)
	if writer.Code != http.StatusBadRequest {
		t.Fatalf("status=%d want=400 body=%s", writer.Code, writer.Body.String())
	}
}
