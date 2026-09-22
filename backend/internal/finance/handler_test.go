package finance

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"CBizDocsManager/backend/internal/document"
	"CBizDocsManager/backend/internal/identity"
	"CBizDocsManager/backend/pkg/apperror"
	"CBizDocsManager/backend/pkg/money"
	"CBizDocsManager/backend/pkg/requestid"
	"github.com/gin-gonic/gin"
)

// financeServiceStub 记录 Handler 传给服务层的入参，用于断言协议转换是否正确。
//
// 特别注意 kind：它由路由构造时注入，客户端无论怎么传都必须无效，
// 所以桩把收到的 kind 记下来，测试再与路由声明的 kind 对比。
type financeServiceStub struct {
	kind           Kind
	createRequest  CreateRequest
	idempotencyKey string
	listQuery      ListQuery
	recordID       uint64
	statementID    uint64

	createCalled    bool
	listCalled      bool
	revokeCalled    bool
	statementCalled bool
	err             error
}

func (s *financeServiceStub) Create(_ context.Context, _ identity.Principal, kind Kind, request CreateRequest, idempotencyKey string) (*StatementData, error) {
	s.createCalled, s.kind, s.createRequest, s.idempotencyKey = true, kind, request, idempotencyKey
	if s.err != nil {
		return nil, s.err
	}
	return stubStatementData(), nil
}

func (s *financeServiceStub) List(_ context.Context, _ identity.Principal, kind Kind, query ListQuery) (*RecordPageData, error) {
	s.listCalled, s.kind, s.listQuery = true, kind, query
	if s.err != nil {
		return nil, s.err
	}
	return &RecordPageData{
		Items: []RecordData{{
			RecordID: 1, Kind: kind, DocumentID: 11, DocumentKind: document.KindInbound,
			DocumentNo: "RK20260922-0011", Amount: money.AmountFromYuan(30000),
			AmountUpper: "RMB叁万元整", OccurredOn: "2026-09-22", Method: methodPtr(MethodTransfer),
		}},
		Page: query.Page, PageSize: query.PageSize, Total: 1,
	}, nil
}

func (s *financeServiceStub) Revoke(_ context.Context, _ identity.Principal, kind Kind, recordID uint64) (*StatementData, error) {
	s.revokeCalled, s.kind, s.recordID = true, kind, recordID
	if s.err != nil {
		return nil, s.err
	}
	return stubStatementData(), nil
}

func (s *financeServiceStub) Statement(_ context.Context, _ identity.Principal, documentID uint64) (*StatementData, error) {
	s.statementCalled, s.statementID = true, documentID
	if s.err != nil {
		return nil, s.err
	}
	return stubStatementData(), nil
}

func methodPtr(method Method) *Method { return &method }

// stubStatementData 造一份覆盖全部对外字段的结清视图。
func stubStatementData() *StatementData {
	return &StatementData{
		DocumentID: 11, DocumentKind: document.KindInbound, DocumentNo: "RK20260922-0011",
		PartyName:    "唐山钢铁",
		BusinessUser: identity.UserSummary{ID: 7, DisplayName: "王业务", AccountType: identity.AccountTypeMember},
		BusinessDate: "2026-09-22",
		TotalAmount:  money.AmountFromYuan(100), TotalUpper: "RMB壹佰元整",
		PaidAmount: money.AmountFromYuan(30), UnpaidAmount: money.AmountFromYuan(70),
		PaidUpper: "RMB叁拾元整", UnpaidUpper: "RMB柒拾元整",
		InvoicedAmount: 0, UninvoicedAmount: money.AmountFromYuan(100),
		InvoicedUpper: "RMB零元整", UninvoicedUpper: "RMB壹佰元整",
		InvoiceStatus: InvoiceStatusNone,
		PaymentCount:  1,
		Records: []RecordData{{
			RecordID: 1, Kind: KindPayment, DocumentID: 11, DocumentKind: document.KindInbound,
			DocumentNo: "RK20260922-0011", PartyName: "唐山钢铁",
			Amount: money.AmountFromYuan(30), AmountUpper: "RMB叁拾元整",
			OccurredOn: "2026-09-22", Method: methodPtr(MethodTransfer),
		}},
	}
}

// financeRouter 按生产环境的路由结构挂载财务子路由（kind 在构造 Handler 时注入）。
func financeRouter(service FinanceService, kind Kind, withPrincipal bool) *gin.Engine {
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
	router.POST("/finance/records", handler.Create)
	router.GET("/finance/records", handler.List)
	router.POST("/finance/records/:record_id/revoke", handler.Revoke)
	router.GET("/finance/statements/:document_id", handler.Statement)
	return router
}

func TestHandlerCreateUsesRouteKindAndTrimsIdempotencyKey(t *testing.T) {
	service := &financeServiceStub{}
	router := financeRouter(service, KindReceipt, true)
	body := []byte(`{"document_id":12,"amount":"30000.00","occurred_on":"2026-09-22","method":"private_card","card_tail":"8899","remark":"九月回款"}`)
	request := httptest.NewRequest(http.MethodPost, "/finance/records", bytes.NewReader(body))
	request.Header.Set("Content-Type", "application/json")
	// 幂等键首尾空白必须被裁掉，否则离线队列重放会因为空格而命中不了同一条记录。
	request.Header.Set(idempotencyHeader, "  offline-queue-9  ")
	writer := httptest.NewRecorder()
	router.ServeHTTP(writer, request)

	if writer.Code != http.StatusCreated {
		t.Fatalf("status=%d body=%s", writer.Code, writer.Body.String())
	}
	if service.kind != KindReceipt {
		t.Fatalf("service kind = %q, want receipt", service.kind)
	}
	if service.idempotencyKey != "offline-queue-9" {
		t.Fatalf("idempotency key = %q", service.idempotencyKey)
	}
	if service.createRequest.DocumentID != 12 || service.createRequest.Amount != "30000.00" {
		t.Fatalf("create request = %+v", service.createRequest)
	}
	if service.createRequest.CardTail == nil || *service.createRequest.CardTail != "8899" {
		t.Fatalf("card tail = %v", service.createRequest.CardTail)
	}
	if service.createRequest.Remark == nil || *service.createRequest.Remark != "九月回款" {
		t.Fatalf("remark = %v", service.createRequest.Remark)
	}

	var envelope struct {
		Code string        `json:"code"`
		Data StatementData `json:"data"`
	}
	if err := json.Unmarshal(writer.Body.Bytes(), &envelope); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if envelope.Data.PaidAmount != money.AmountFromYuan(30) || envelope.Data.UnpaidAmount != money.AmountFromYuan(70) {
		t.Fatalf("data = %+v", envelope.Data)
	}
	// 大写金额由服务端给出，客户端不需要自己算。
	if envelope.Data.PaidUpper != "RMB叁拾元整" {
		t.Fatalf("paid upper = %q", envelope.Data.PaidUpper)
	}
}

func TestHandlerRejectsClientSuppliedKind(t *testing.T) {
	// 记录类型由路由决定：客户端在请求体里塞 kind 必须被当作未知字段拒绝，
	// 否则就能用付款接口写收款数据。
	service := &financeServiceStub{}
	router := financeRouter(service, KindPayment, true)
	body := []byte(`{"document_id":11,"amount":"10.00","occurred_on":"2026-09-22","method":"transfer","kind":"receipt"}`)
	request := httptest.NewRequest(http.MethodPost, "/finance/records", bytes.NewReader(body))
	request.Header.Set("Content-Type", "application/json")
	writer := httptest.NewRecorder()
	router.ServeHTTP(writer, request)

	if writer.Code != http.StatusBadRequest {
		t.Fatalf("status=%d body=%s", writer.Code, writer.Body.String())
	}
	if service.createCalled {
		t.Fatal("带非法字段的请求不应触达服务层")
	}
}

func TestHandlerAllowsMissingIdempotencyKey(t *testing.T) {
	service := &financeServiceStub{}
	router := financeRouter(service, KindPayment, true)
	request := httptest.NewRequest(http.MethodPost, "/finance/records",
		bytes.NewReader([]byte(`{"document_id":11,"amount":"10.00","occurred_on":"2026-09-22","method":"transfer"}`)))
	request.Header.Set("Content-Type", "application/json")
	writer := httptest.NewRecorder()
	router.ServeHTTP(writer, request)

	// 不带幂等键是合法请求（只是失去重放保护），不能被拒绝。
	if writer.Code != http.StatusCreated {
		t.Fatalf("status=%d body=%s", writer.Code, writer.Body.String())
	}
	if service.idempotencyKey != "" {
		t.Fatalf("idempotency key = %q, want empty", service.idempotencyKey)
	}
}

func TestHandlerRejectsOversizedIdempotencyKeyAndBadIDs(t *testing.T) {
	service := &financeServiceStub{}
	router := financeRouter(service, KindPayment, true)

	// 幂等键长度必须与数据库列宽一致（191），超长直接 400 而不是落到库层报错。
	request := httptest.NewRequest(http.MethodPost, "/finance/records",
		bytes.NewReader([]byte(`{"document_id":11,"amount":"10.00","occurred_on":"2026-09-22","method":"transfer"}`)))
	request.Header.Set("Content-Type", "application/json")
	request.Header.Set(idempotencyHeader, string(bytes.Repeat([]byte("k"), 192)))
	writer := httptest.NewRecorder()
	router.ServeHTTP(writer, request)
	if writer.Code != http.StatusBadRequest {
		t.Fatalf("oversized key status=%d body=%s", writer.Code, writer.Body.String())
	}
	if service.createCalled {
		t.Fatal("超长幂等键不应触达服务层")
	}

	// 路径参数不是正整数时必须 400，而不是落到服务层再报 500。
	for _, path := range []string{"/finance/records/abc/revoke", "/finance/records/0/revoke"} {
		writer = httptest.NewRecorder()
		router.ServeHTTP(writer, httptest.NewRequest(http.MethodPost, path, nil))
		if writer.Code != http.StatusBadRequest {
			t.Fatalf("%s status=%d body=%s", path, writer.Code, writer.Body.String())
		}
	}

	// 结清视图的单据 ID 同样要校验。
	for _, path := range []string{"/finance/statements/abc", "/finance/statements/0"} {
		writer = httptest.NewRecorder()
		router.ServeHTTP(writer, httptest.NewRequest(http.MethodGet, path, nil))
		if writer.Code != http.StatusBadRequest {
			t.Fatalf("%s status=%d body=%s", path, writer.Code, writer.Body.String())
		}
	}
}

func TestHandlerRequiresPrincipal(t *testing.T) {
	// 没有身份时必须返回登录过期，而不是 500。
	router := financeRouter(&financeServiceStub{}, KindPayment, false)
	writer := httptest.NewRecorder()
	router.ServeHTTP(writer, httptest.NewRequest(http.MethodGet, "/finance/records", nil))
	if writer.Code != http.StatusUnauthorized {
		t.Fatalf("anonymous list status=%d body=%s", writer.Code, writer.Body.String())
	}

	writer = httptest.NewRecorder()
	router.ServeHTTP(writer, httptest.NewRequest(http.MethodGet, "/finance/statements/11", nil))
	if writer.Code != http.StatusUnauthorized {
		t.Fatalf("anonymous statement status=%d body=%s", writer.Code, writer.Body.String())
	}

	writer = httptest.NewRecorder()
	router.ServeHTTP(writer, httptest.NewRequest(http.MethodPost, "/finance/records/1/revoke", nil))
	if writer.Code != http.StatusUnauthorized {
		t.Fatalf("anonymous revoke status=%d body=%s", writer.Code, writer.Body.String())
	}
}

func TestHandlerMapsServiceErrors(t *testing.T) {
	tests := []struct {
		name       string
		err        error
		wantStatus int
		wantCode   string
	}{
		{name: "累计超额", err: apperror.ErrFinanceAmountExceeds, wantStatus: http.StatusConflict, wantCode: apperror.CodeFinanceAmountExceeds},
		{name: "单据类型不匹配", err: apperror.ErrFinanceDocumentMismatch, wantStatus: http.StatusBadRequest, wantCode: apperror.CodeFinanceDocumentMismatch},
		{name: "记录不存在", err: apperror.ErrFinanceRecordNotFound, wantStatus: http.StatusNotFound, wantCode: apperror.CodeFinanceRecordNotFound},
		{name: "参数非法", err: apperror.ErrValidationFailed, wantStatus: http.StatusBadRequest, wantCode: apperror.CodeValidationFailed},
		{name: "越权", err: apperror.ErrForbidden, wantStatus: http.StatusForbidden, wantCode: apperror.CodeForbidden},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			service := &financeServiceStub{err: tt.err}
			router := financeRouter(service, KindPayment, true)

			writer := httptest.NewRecorder()
			router.ServeHTTP(writer, httptest.NewRequest(http.MethodPost, "/finance/records/5/revoke", nil))
			if writer.Code != tt.wantStatus || !service.revokeCalled || service.recordID != 5 {
				t.Fatalf("revoke status=%d service=%+v", writer.Code, service)
			}
			var envelope struct {
				Code string `json:"code"`
			}
			if err := json.Unmarshal(writer.Body.Bytes(), &envelope); err != nil {
				t.Fatalf("decode: %v", err)
			}
			if envelope.Code != tt.wantCode {
				t.Fatalf("code = %q, want %q", envelope.Code, tt.wantCode)
			}

			writer = httptest.NewRecorder()
			router.ServeHTTP(writer, httptest.NewRequest(http.MethodGet, "/finance/statements/11", nil))
			if writer.Code != tt.wantStatus || service.statementID != 11 {
				t.Fatalf("statement status=%d service=%+v", writer.Code, service)
			}

			writer = httptest.NewRecorder()
			router.ServeHTTP(writer, httptest.NewRequest(http.MethodPost, "/finance/records",
				bytes.NewReader([]byte(`{"document_id":11,"amount":"10.00","occurred_on":"2026-09-22","method":"transfer"}`))))
			if writer.Code != tt.wantStatus {
				t.Fatalf("create status=%d body=%s", writer.Code, writer.Body.String())
			}
		})
	}
}

func TestHandlerListBindsQueryAndReturnsPage(t *testing.T) {
	service := &financeServiceStub{}
	router := financeRouter(service, KindPayment, true)
	writer := httptest.NewRecorder()
	router.ServeHTTP(writer, httptest.NewRequest(http.MethodGet,
		"/finance/records?document_id=11&keyword=RK2026&method=transfer&business_user_id=8&month=2026-09&date_from=2026-09-01&date_to=2026-09-30&page=2&page_size=50", nil))

	if writer.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", writer.Code, writer.Body.String())
	}
	query := service.listQuery
	if query.DocumentID != 11 || query.Keyword != "RK2026" || query.Method != MethodTransfer ||
		query.BusinessUserID != 8 || query.Month != "2026-09" ||
		query.DateFrom != "2026-09-01" || query.DateTo != "2026-09-30" ||
		query.Page != 2 || query.PageSize != 50 {
		t.Fatalf("list query = %+v", query)
	}
	if service.kind != KindPayment {
		t.Fatalf("service kind = %q", service.kind)
	}

	// 列表响应要带上分页元信息与金额快照。
	var envelope struct {
		Data RecordPageData `json:"data"`
	}
	if err := json.Unmarshal(writer.Body.Bytes(), &envelope); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if envelope.Data.Total != 1 || len(envelope.Data.Items) != 1 ||
		envelope.Data.Items[0].DocumentNo != "RK20260922-0011" ||
		envelope.Data.Items[0].AmountUpper != "RMB叁万元整" {
		t.Fatalf("page = %+v", envelope.Data)
	}
}
