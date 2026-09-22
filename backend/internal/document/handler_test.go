package document

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"CBizDocsManager/backend/internal/identity"
	"CBizDocsManager/backend/pkg/apperror"
	"CBizDocsManager/backend/pkg/money"
	"CBizDocsManager/backend/pkg/requestid"
	"github.com/gin-gonic/gin"
)

// documentServiceStub 记录 Handler 传给服务层的入参，用于断言协议转换是否正确。
type documentServiceStub struct {
	err            error
	kind           Kind
	idempotencyKey string
	documentID     uint64
	version        uint64
	listQuery      ListQuery
	summaryMonth   string
	bucketSize     int
}

func (s *documentServiceStub) Create(_ context.Context, _ identity.Principal, kind Kind, request CreateRequest, idempotencyKey string) (*DocumentData, error) {
	s.kind, s.idempotencyKey = kind, idempotencyKey
	if s.err != nil {
		return nil, s.err
	}
	return stubDocumentData(kind, firstPartyName(request.Parties)), nil
}

func (s *documentServiceStub) Update(_ context.Context, _ identity.Principal, kind Kind, documentID uint64, request UpdateRequest, idempotencyKey string) (*DocumentData, error) {
	s.kind, s.documentID, s.version, s.idempotencyKey = kind, documentID, request.Version, idempotencyKey
	if s.err != nil {
		return nil, s.err
	}
	return stubDocumentData(kind, firstPartyName(request.Parties)), nil
}

func (s *documentServiceStub) Get(_ context.Context, _ identity.Principal, kind Kind, documentID uint64) (*DocumentData, error) {
	s.kind, s.documentID = kind, documentID
	if s.err != nil {
		return nil, s.err
	}
	return stubDocumentData(kind, "鑫源钢贸有限公司"), nil
}

func (s *documentServiceStub) List(_ context.Context, _ identity.Principal, kind Kind, query ListQuery) (*DocumentPageData, error) {
	s.kind, s.listQuery = kind, query
	if s.err != nil {
		return nil, s.err
	}
	return &DocumentPageData{Items: []DocumentSummaryData{{
		DocumentID: 1, Kind: kind, DocumentNo: "RK20260922-0001", Status: StatusDraft,
		BusinessDate: "2026-09-22", PartyNames: []string{"鑫源钢贸有限公司"}, ItemCount: 2,
		TotalAmount: money.AmountFromYuan(72000), Version: 1,
	}}, Page: query.Page, PageSize: query.PageSize, Total: 1}, nil
}

func (s *documentServiceStub) Submit(_ context.Context, _ identity.Principal, kind Kind, documentID uint64, request VersionRequest) (*DocumentData, error) {
	s.kind, s.documentID, s.version = kind, documentID, request.Version
	if s.err != nil {
		return nil, s.err
	}
	return stubDocumentData(kind, "鑫源钢贸有限公司"), nil
}

func (s *documentServiceStub) Void(_ context.Context, _ identity.Principal, kind Kind, documentID uint64, request VersionRequest) (*DocumentData, error) {
	s.kind, s.documentID, s.version = kind, documentID, request.Version
	if s.err != nil {
		return nil, s.err
	}
	return stubDocumentData(kind, "鑫源钢贸有限公司"), nil
}

func (s *documentServiceStub) MonthlySummary(_ context.Context, _ identity.Principal, kind Kind, month string, bucketSize int) (*MonthlySummaryData, error) {
	s.kind, s.summaryMonth, s.bucketSize = kind, month, bucketSize
	if s.err != nil {
		return nil, s.err
	}
	return &MonthlySummaryData{Month: "2026-09", Kind: kind, DocumentCount: 1, TotalAmount: money.AmountFromYuan(72000)}, nil
}

func firstPartyName(parties []PartyRequest) string {
	if len(parties) == 0 {
		return ""
	}
	return parties[0].PartyName
}

func stubDocumentData(kind Kind, partyName string) *DocumentData {
	return &DocumentData{
		DocumentID: 1, Kind: kind, DocumentNo: "RK20260922-0001", Status: StatusDraft,
		BusinessDate: "2026-09-22", TotalAmount: money.AmountFromYuan(72000), Version: 1,
		Parties: []PartyData{{PartyID: 1, Position: 1, PartyName: partyName, Subtotal: money.AmountFromYuan(72000)}},
	}
}

func documentRouter(service DocumentService, kind Kind, withPrincipal bool) *gin.Engine {
	gin.SetMode(gin.TestMode)
	// 与 NewRouter 保持一致：拒绝未知字段，避免客户端字段名写错却被静默忽略。
	gin.EnableJsonDecoderDisallowUnknownFields()
	router := gin.New()
	router.Use(requestid.Middleware())
	if withPrincipal {
		router.Use(func(c *gin.Context) {
			groupID := uint64(7)
			identity.SetPrincipal(c, &identity.Principal{
				UserID: 10, GroupID: &groupID, GroupName: "钢铁一组",
				AccountType: identity.AccountTypeGroupOwner, MemberType: "owner", SessionID: 1,
			})
			c.Next()
		})
	}
	handler := NewHandler(service, kind)
	router.POST("/inbound-documents", handler.Create)
	router.GET("/inbound-documents", handler.List)
	router.GET("/inbound-documents/monthly-summary", handler.MonthlySummary)
	router.GET("/inbound-documents/:document_id", handler.Get)
	router.PUT("/inbound-documents/:document_id", handler.Update)
	router.POST("/inbound-documents/:document_id/submit", handler.Submit)
	router.POST("/inbound-documents/:document_id/void", handler.Void)
	return router
}

func TestHandlerCreateUsesRouteKindAndIdempotencyHeader(t *testing.T) {
	service := &documentServiceStub{}
	router := documentRouter(service, KindOutbound, true)
	body := []byte(`{"status":"draft","business_date":"2026-09-22","parties":[{"party_name":"宏达建筑","items":[{"product_name":"螺纹钢","quantity":"20","unit_price":"2260.00","price_tax_mode":"tax_included"}]}]}`)
	request := httptest.NewRequest(http.MethodPost, "/inbound-documents", bytes.NewReader(body))
	request.Header.Set("Content-Type", "application/json")
	request.Header.Set(idempotencyHeader, "  offline-queue-1  ")
	writer := httptest.NewRecorder()
	router.ServeHTTP(writer, request)

	if writer.Code != http.StatusCreated {
		t.Fatalf("status=%d body=%s", writer.Code, writer.Body.String())
	}
	// 路由由 Handler 构造时的 kind 决定，客户端无法通过请求体篡改单据类型。
	if service.kind != KindOutbound {
		t.Fatalf("kind = %q, want outbound", service.kind)
	}
	if service.idempotencyKey != "offline-queue-1" {
		t.Fatalf("idempotency key = %q", service.idempotencyKey)
	}
	var envelope struct {
		Code string       `json:"code"`
		Data DocumentData `json:"data"`
	}
	if err := json.Unmarshal(writer.Body.Bytes(), &envelope); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if envelope.Data.Parties[0].PartyName != "宏达建筑" || envelope.Data.TotalAmount != money.AmountFromYuan(72000) {
		t.Fatalf("data = %+v", envelope.Data)
	}
}

func TestHandlerRejectsOversizedIdempotencyKey(t *testing.T) {
	service := &documentServiceStub{}
	router := documentRouter(service, KindInbound, true)
	request := httptest.NewRequest(http.MethodPost, "/inbound-documents", bytes.NewReader([]byte(`{}`)))
	request.Header.Set("Content-Type", "application/json")
	request.Header.Set(idempotencyHeader, string(bytes.Repeat([]byte("k"), 192)))
	writer := httptest.NewRecorder()
	router.ServeHTTP(writer, request)
	if writer.Code != http.StatusBadRequest {
		t.Fatalf("status=%d body=%s", writer.Code, writer.Body.String())
	}
	if service.idempotencyKey != "" {
		t.Fatalf("service must not be called with an oversized key")
	}
}

func TestHandlerRejectsUnknownFieldsAndBadIDs(t *testing.T) {
	service := &documentServiceStub{}
	router := documentRouter(service, KindInbound, true)

	// gin 开启了 DisallowUnknownFields，多余字段必须被拒绝，避免客户端静默传错。
	request := httptest.NewRequest(http.MethodPost, "/inbound-documents",
		bytes.NewReader([]byte(`{"business_date":"2026-09-22","unknown_field":1}`)))
	request.Header.Set("Content-Type", "application/json")
	writer := httptest.NewRecorder()
	router.ServeHTTP(writer, request)
	if writer.Code != http.StatusBadRequest {
		t.Fatalf("unknown field status=%d body=%s", writer.Code, writer.Body.String())
	}

	writer = httptest.NewRecorder()
	router.ServeHTTP(writer, httptest.NewRequest(http.MethodGet, "/inbound-documents/abc", nil))
	if writer.Code != http.StatusBadRequest {
		t.Fatalf("bad id status=%d body=%s", writer.Code, writer.Body.String())
	}

	// 没有身份时必须返回登录过期，而不是 500。
	anonymous := documentRouter(&documentServiceStub{}, KindInbound, false)
	writer = httptest.NewRecorder()
	anonymous.ServeHTTP(writer, httptest.NewRequest(http.MethodGet, "/inbound-documents/1", nil))
	if writer.Code != http.StatusUnauthorized {
		t.Fatalf("anonymous status=%d body=%s", writer.Code, writer.Body.String())
	}
}

func TestHandlerMapsServiceErrorsAndQueryParams(t *testing.T) {
	service := &documentServiceStub{err: apperror.ErrDocumentIncomplete}
	router := documentRouter(service, KindInbound, true)

	writer := httptest.NewRecorder()
	router.ServeHTTP(writer, httptest.NewRequest(http.MethodPost, "/inbound-documents/5/submit",
		bytes.NewReader([]byte(`{"version":3}`))))
	if writer.Code != http.StatusBadRequest || service.version != 3 || service.documentID != 5 {
		t.Fatalf("submit status=%d service=%+v", writer.Code, service)
	}
	var envelope struct {
		Code string `json:"code"`
	}
	if err := json.Unmarshal(writer.Body.Bytes(), &envelope); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if envelope.Code != apperror.CodeDocumentIncomplete {
		t.Fatalf("code = %q", envelope.Code)
	}

	// 汇总接口把 month / bucket_size 原样交给服务层做校验。
	service.err = nil
	writer = httptest.NewRecorder()
	router.ServeHTTP(writer, httptest.NewRequest(http.MethodGet, "/inbound-documents/monthly-summary?month=2026-08&bucket_size=5", nil))
	if writer.Code != http.StatusOK || service.summaryMonth != "2026-08" || service.bucketSize != 5 {
		t.Fatalf("summary status=%d service=%+v", writer.Code, service)
	}

	// 列表筛选参数必须原样透传。
	writer = httptest.NewRecorder()
	router.ServeHTTP(writer, httptest.NewRequest(http.MethodGet, "/inbound-documents?status=draft&page=2&page_size=5&keyword=%E9%91%AB%E6%BA%90", nil))
	if writer.Code != http.StatusOK {
		t.Fatalf("list status=%d body=%s", writer.Code, writer.Body.String())
	}
	if service.listQuery.Status != StatusDraft || service.listQuery.Page != 2 || service.listQuery.PageSize != 5 || service.listQuery.Keyword != "鑫源" {
		t.Fatalf("list query = %+v", service.listQuery)
	}
}
