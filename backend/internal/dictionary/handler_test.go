package dictionary

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"CBizDocsManager/backend/internal/identity"
	"CBizDocsManager/backend/pkg/requestid"
	"github.com/gin-gonic/gin"
)

type dictionaryServiceStub struct {
	page  Page
	entry Entry
	err   error
}

func (s *dictionaryServiceStub) List(context.Context, identity.Principal, ListQuery) (Page, error) {
	return s.page, s.err
}
func (s *dictionaryServiceStub) Create(context.Context, identity.Principal, CreateRequest) (Entry, error) {
	return s.entry, s.err
}
func (s *dictionaryServiceStub) Update(context.Context, identity.Principal, uint64, UpdateRequest) (Entry, error) {
	return s.entry, s.err
}
func (s *dictionaryServiceStub) ChangeStatus(context.Context, identity.Principal, uint64, ChangeStatusRequest) (Entry, error) {
	return s.entry, s.err
}

func dictionaryRouter(service DictionaryService, principal bool) *gin.Engine {
	gin.SetMode(gin.TestMode)
	router := gin.New()
	router.Use(requestid.Middleware())
	if principal {
		router.Use(func(c *gin.Context) {
			groupID := uint64(7)
			identity.SetPrincipal(c, &identity.Principal{UserID: 10, GroupID: &groupID, AccountType: identity.AccountTypeGroupOwner, MemberType: "owner"})
			c.Next()
		})
	}
	handler := NewHandler(service)
	router.GET("/dictionaries", handler.List)
	router.POST("/dictionaries", handler.Create)
	router.PUT("/dictionaries/:dictionary_id", handler.Update)
	router.PATCH("/dictionaries/:dictionary_id/status", handler.ChangeStatus)
	return router
}

func TestHandlerReturnsDictionaryPageAndCreatedEntry(t *testing.T) {
	service := &dictionaryServiceStub{page: Page{Items: []Entry{{ID: 1, Kind: KindCustomer, Name: "Acme", Status: StatusActive, Version: 1}}, Page: 1, PageSize: 20, Total: 1}, entry: Entry{ID: 2, Kind: KindUnit, Name: "箱", Status: StatusActive, Version: 1}}
	router := dictionaryRouter(service, true)
	writer := httptest.NewRecorder()
	router.ServeHTTP(writer, httptest.NewRequest(http.MethodGet, "/dictionaries", nil))
	if writer.Code != http.StatusOK {
		t.Fatalf("list status=%d body=%s", writer.Code, writer.Body.String())
	}
	var envelope struct {
		Data PageData `json:"data"`
	}
	if err := json.Unmarshal(writer.Body.Bytes(), &envelope); err != nil {
		t.Fatalf("decode list: %v", err)
	}
	if len(envelope.Data.Items) != 1 || envelope.Data.Pagination.Total != 1 {
		t.Fatalf("page=%+v", envelope.Data)
	}
	request := httptest.NewRequest(http.MethodPost, "/dictionaries", bytes.NewBufferString(`{"kind":"unit","name":"箱"}`))
	request.Header.Set("Content-Type", "application/json")
	writer = httptest.NewRecorder()
	router.ServeHTTP(writer, request)
	if writer.Code != http.StatusCreated {
		t.Fatalf("create status=%d body=%s", writer.Code, writer.Body.String())
	}
}

func TestHandlerValidatesDictionaryRequests(t *testing.T) {
	router := dictionaryRouter(&dictionaryServiceStub{}, true)
	tests := []struct{ method, path, body string }{
		{http.MethodGet, "/dictionaries?kind=unknown", ""},
		{http.MethodPost, "/dictionaries", `{"kind":"unit","name":""}`},
		{http.MethodPut, "/dictionaries/nope", `{"name":"箱","version":1}`},
		{http.MethodPut, "/dictionaries/1", `{"name":"箱","version":0}`},
		{http.MethodPatch, "/dictionaries/1/status", `{"status":"removed","version":1}`},
	}
	for _, test := range tests {
		request := httptest.NewRequest(test.method, test.path, bytes.NewBufferString(test.body))
		request.Header.Set("Content-Type", "application/json")
		writer := httptest.NewRecorder()
		router.ServeHTTP(writer, request)
		if writer.Code != http.StatusBadRequest {
			t.Fatalf("%s %s status=%d body=%s", test.method, test.path, writer.Code, writer.Body.String())
		}
	}
}

func TestHandlerRequiresDictionaryPrincipal(t *testing.T) {
	writer := httptest.NewRecorder()
	dictionaryRouter(&dictionaryServiceStub{}, false).ServeHTTP(writer, httptest.NewRequest(http.MethodGet, "/dictionaries", nil))
	if writer.Code != http.StatusUnauthorized {
		t.Fatalf("status=%d body=%s", writer.Code, writer.Body.String())
	}
}
