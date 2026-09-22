package reporting

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"CBizDocsManager/backend/internal/document"
	"CBizDocsManager/backend/internal/identity"
	"CBizDocsManager/backend/pkg/apperror"
	"CBizDocsManager/backend/pkg/money"
	"CBizDocsManager/backend/pkg/requestid"
	"CBizDocsManager/backend/pkg/response"
	"github.com/gin-gonic/gin"
)

// reportServiceStub 记录 Handler 传给服务层的入参，用于断言协议转换是否正确。
type reportServiceStub struct {
	periodQuery        PeriodQuery
	itemQuery          ItemStatsQuery
	businessUserQuery  BusinessUserQuery
	createRequest      CreateSnapshotRequest
	snapshotListQuery  SnapshotListQuery
	snapshotID         uint64

	overviewCalled      bool
	inboundCalled       bool
	outboundCalled      bool
	businessUsersCalled bool
	createCalled        bool
	listCalled          bool
	getCalled           bool
	err                 error
}

func (s *reportServiceStub) Overview(_ context.Context, _ identity.Principal, query PeriodQuery) (*OverviewData, error) {
	s.overviewCalled, s.periodQuery = true, query
	if s.err != nil {
		return nil, s.err
	}
	return stubOverviewData(), nil
}

func (s *reportServiceStub) InboundStats(_ context.Context, _ identity.Principal, query ItemStatsQuery) (*InboundStatsData, error) {
	s.inboundCalled, s.itemQuery = true, query
	if s.err != nil {
		return nil, s.err
	}
	return stubInboundStatsData(), nil
}

func (s *reportServiceStub) OutboundStats(_ context.Context, _ identity.Principal, query ItemStatsQuery) (*OutboundStatsData, error) {
	s.outboundCalled, s.itemQuery = true, query
	if s.err != nil {
		return nil, s.err
	}
	return stubOutboundStatsData(), nil
}

func (s *reportServiceStub) BusinessUsers(_ context.Context, _ identity.Principal, query BusinessUserQuery) (*BusinessUserReportData, error) {
	s.businessUsersCalled, s.businessUserQuery = true, query
	if s.err != nil {
		return nil, s.err
	}
	return &BusinessUserReportData{
		Period: query.Period,
		Items: []BusinessUserSummaryData{{
			BusinessUser:  identity.UserSummary{ID: testUserID, DisplayName: "王业务", AccountType: identity.AccountTypeMember},
			InboundAmount: money.AmountFromYuan(100), OutboundAmount: money.AmountFromYuan(200),
			GrossProfit: money.AmountFromYuan(100), GrossProfitUpper: "RMB壹佰元整", DocumentCount: 2,
		}},
		Summary: BusinessUserTotalsData{
			InboundAmount: money.AmountFromYuan(100), OutboundAmount: money.AmountFromYuan(200),
			GrossProfit: money.AmountFromYuan(100), GrossProfitUpper: "RMB壹佰元整", DocumentCount: 2,
		},
	}, nil
}

func (s *reportServiceStub) CreateSnapshots(_ context.Context, _ identity.Principal, request CreateSnapshotRequest) (*CreateSnapshotData, error) {
	s.createCalled, s.createRequest = true, request
	if s.err != nil {
		return nil, s.err
	}
	return &CreateSnapshotData{
		BatchNo: "ZJS202609-0001", Period: request.Period,
		Snapshots: []SnapshotData{*stubSnapshotData()},
	}, nil
}

func (s *reportServiceStub) ListSnapshots(_ context.Context, _ identity.Principal, query SnapshotListQuery) (*SnapshotPageData, error) {
	s.listCalled, s.snapshotListQuery = true, query
	if s.err != nil {
		return nil, s.err
	}
	return &SnapshotPageData{
		Items: []SnapshotData{*stubSnapshotData()},
		Page:  query.Page, PageSize: query.PageSize, Total: 1,
	}, nil
}

func (s *reportServiceStub) GetSnapshot(_ context.Context, _ identity.Principal, snapshotID uint64) (*SnapshotData, error) {
	s.getCalled, s.snapshotID = true, snapshotID
	if s.err != nil {
		return nil, s.err
	}
	return stubSnapshotData(), nil
}

// stubOverviewData 造一份覆盖全部对外字段的看板数据。
func stubOverviewData() *OverviewData {
	return &OverviewData{
		Period:               "2026-09",
		InboundDocumentCount: 2, InboundAmount: money.AmountFromYuan(150000), InboundAmountUpper: "RMB壹拾伍万元整",
		OutboundDocumentCount: 2, OutboundAmount: money.AmountFromYuan(173520), OutboundAmountUpper: "RMB壹拾柒万叁仟伍佰贰拾元整",
		GrossProfit: money.AmountFromYuan(23520), GrossProfitUpper: "RMB贰万叁仟伍佰贰拾元整",
		GrossMarginPPM: 135546, GrossMarginPercent: "13.55",
		PaidAmount: money.AmountFromYuan(130000), UnpaidAmount: money.AmountFromYuan(20000),
		UnpaidAmountUpper: "RMB贰万元整", UnpaidDocumentCount: 2,
		InvoicedAmount: money.AmountFromYuan(100000), UninvoicedAmount: money.AmountFromYuan(50000),
		UninvoicedAmountUpper: "RMB伍万元整", UninvoicedDocumentCount: 1,
		ReceivedAmount: money.AmountFromYuan(80000), UnreceivedAmount: money.AmountFromYuan(93520),
		UnreceivedAmountUpper: "RMB玖万叁仟伍佰贰拾元整", UnreceivedDocumentCount: 2,
		SupplierCount: 3, CustomerCount: 4,
		SaleAmountTypes: []SaleAmountTotalData{{
			SaleAmountType: document.SaleAmountVATSpecial, Amount: money.AmountFromYuan(113200),
			AmountUpper: "RMB壹拾壹万叁仟贰佰元整", SharePPM: 652397, SharePercent: "65.24",
		}},
	}
}

func stubInboundStatsData() *InboundStatsData {
	return &InboundStatsData{
		Period: "2026-09",
		DocumentCount: 2, AmountTotal: money.AmountFromYuan(150000), AmountTotalUpper: "RMB壹拾伍万元整",
		PaidAmount: money.AmountFromYuan(130000), UnpaidAmount: money.AmountFromYuan(20000),
		UnpaidAmountUpper: "RMB贰万元整", UnpaidDocumentCount: 2,
		InvoicedAmount: money.AmountFromYuan(100000), UninvoicedAmount: money.AmountFromYuan(50000),
		UninvoicedAmountUpper: "RMB伍万元整", UninvoicedDocumentCount: 1,
		SupplierCount: 3,
		Items: []ItemData{{
			PartyName: "鑫源钢贸", ProductName: "螺纹钢",
			DocumentCount: 1, Quantity: money.Quantity(17050),
			Amount: money.AmountFromYuan(72000), AmountUpper: "RMB柒万贰仟元整",
		}},
		Page: 1, PageSize: 20, Total: 1,
	}
}

func stubOutboundStatsData() *OutboundStatsData {
	return &OutboundStatsData{
		Period: "2026-09",
		DocumentCount: 2, AmountTotal: money.AmountFromYuan(173520), AmountTotalUpper: "RMB壹拾柒万叁仟伍佰贰拾元整",
		ReceivedAmount: money.AmountFromYuan(80000), UnreceivedAmount: money.AmountFromYuan(93520),
		UnreceivedAmountUpper: "RMB玖万叁仟伍佰贰拾元整", UnreceivedDocumentCount: 2,
		CustomerCount: 4,
		SaleAmountTypes: []SaleAmountTotalData{{
			SaleAmountType: document.SaleAmountVATSpecial, Amount: money.AmountFromYuan(113200),
			AmountUpper: "RMB壹拾壹万叁仟贰佰元整", SharePPM: 652397, SharePercent: "65.24",
		}},
		Items: []ItemData{{
			PartyName: "宏达建筑", ProductName: "螺纹钢",
			DocumentCount: 1, Quantity: money.Quantity(17050),
			Amount: money.AmountFromYuan(90440), AmountUpper: "RMB玖万零肆佰肆拾元整",
		}},
		Page: 1, PageSize: 20, Total: 1,
	}
}

func stubSnapshotData() *SnapshotData {
	return &SnapshotData{
		SnapshotID: 1, SnapshotNo: "ZJS202609-0001", BatchNo: "ZJS202609-0001",
		Scope: ScopeCompany, Period: "2026-09",
		InboundAmount: money.AmountFromYuan(150000), InboundAmountUpper: "RMB壹拾伍万元整",
		OutboundAmount: money.AmountFromYuan(173520), OutboundAmountUpper: "RMB壹拾柒万叁仟伍佰贰拾元整",
		GrossProfit: money.AmountFromYuan(23520), GrossProfitUpper: "RMB贰万叁仟伍佰贰拾元整",
		GrossMarginPPM: 135546, GrossMarginPercent: "13.55",
		SaleAmountTypes: []SaleAmountTotalData{{
			SaleAmountType: document.SaleAmountVATSpecial, Amount: money.AmountFromYuan(113200),
			AmountUpper: "RMB壹拾壹万叁仟贰佰元整", SharePPM: 652397, SharePercent: "65.24",
		}},
		DocumentCount: 4,
		CreatedBy:     identity.UserSummary{ID: testUserID, DisplayName: "主账号", AccountType: identity.AccountTypeGroupOwner},
		CreatedAt:     fixedNow,
	}
}

// reportingRouter 按生产环境的路由结构挂载汇总统计子路由。
func reportingRouter(service ReportService, withPrincipal bool) *gin.Engine {
	gin.SetMode(gin.TestMode)
	// 与 NewRouter 保持一致：拒绝未知字段，避免客户端字段名写错却被静默忽略。
	gin.EnableJsonDecoderDisallowUnknownFields()
	router := gin.New()
	router.Use(requestid.Middleware())
	if withPrincipal {
		router.Use(func(c *gin.Context) {
			groupID := testGroupID
			identity.SetPrincipal(c, &identity.Principal{
				UserID: testUserID, GroupID: &groupID, GroupName: "钢铁一组",
				AccountType: identity.AccountTypeGroupOwner, MemberType: "owner", SessionID: 1,
			})
			c.Next()
		})
	}
	handler := NewHandler(service)
	router.GET("/reports/overview", handler.Overview)
	router.GET("/reports/inbound-stats", handler.InboundStats)
	router.GET("/reports/outbound-stats", handler.OutboundStats)
	router.GET("/reports/business-users", handler.BusinessUsers)
	router.POST("/reports/summary-settlements", handler.CreateSnapshots)
	router.GET("/reports/summary-settlements", handler.ListSnapshots)
	router.GET("/reports/summary-settlements/:snapshot_id", handler.GetSnapshot)
	return router
}

func doRequest(router *gin.Engine, method, target string, body []byte) *httptest.ResponseRecorder {
	var reader *bytes.Reader
	if body == nil {
		reader = bytes.NewReader(nil)
	} else {
		reader = bytes.NewReader(body)
	}
	request := httptest.NewRequest(method, target, reader)
	if body != nil {
		request.Header.Set("Content-Type", "application/json")
	}
	writer := httptest.NewRecorder()
	router.ServeHTTP(writer, request)
	return writer
}

func decodeData[T any](t *testing.T, writer *httptest.ResponseRecorder) T {
	t.Helper()
	var envelope struct {
		Code string `json:"code"`
		Data T      `json:"data"`
	}
	if err := json.Unmarshal(writer.Body.Bytes(), &envelope); err != nil {
		t.Fatalf("decode response: %v body=%s", err, writer.Body.String())
	}
	if envelope.Code != response.CodeOK {
		t.Fatalf("response code = %q, want OK body=%s", envelope.Code, writer.Body.String())
	}
	return envelope.Data
}

func TestHandlerOverviewBindsQuery(t *testing.T) {
	service := &reportServiceStub{}
	router := reportingRouter(service, true)

	writer := doRequest(router, http.MethodGet, "/reports/overview?period=2026-09&business_user_id=8", nil)
	if writer.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", writer.Code, writer.Body.String())
	}
	if !service.overviewCalled {
		t.Fatalf("服务层未被调用")
	}
	if service.periodQuery.Period != "2026-09" || service.periodQuery.BusinessUserID != 8 {
		t.Fatalf("query = %+v", service.periodQuery)
	}
	data := decodeData[OverviewData](t, writer)
	if data.GrossMarginPercent != "13.55" || data.SaleAmountTypes[0].SaleAmountType != document.SaleAmountVATSpecial {
		t.Fatalf("data = %+v", data)
	}
}

func TestHandlerItemStatsBindFiltersAndPath(t *testing.T) {
	service := &reportServiceStub{}
	router := reportingRouter(service, true)

	writer := doRequest(router, http.MethodGet,
		"/reports/inbound-stats?period=2026-09&party_name=%E9%91%AB%E6%BA%90&product_name=%E8%9E%BA%E7%BA%B9%E9%92%A2&page=2&page_size=5", nil)
	if writer.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", writer.Code, writer.Body.String())
	}
	if !service.inboundCalled {
		t.Fatalf("服务层未被调用")
	}
	query := service.itemQuery
	if query.PartyName != "鑫源" || query.ProductName != "螺纹钢" || query.Page != 2 || query.PageSize != 5 {
		t.Fatalf("query = %+v", query)
	}
	decodeData[InboundStatsData](t, writer)

	// 出库统计走同一套查询参数。
	service = &reportServiceStub{}
	router = reportingRouter(service, true)
	writer = doRequest(router, http.MethodGet, "/reports/outbound-stats?period=2026-08", nil)
	if writer.Code != http.StatusOK || !service.outboundCalled {
		t.Fatalf("status=%d called=%v body=%s", writer.Code, service.outboundCalled, writer.Body.String())
	}
	if service.itemQuery.Period != "2026-08" {
		t.Fatalf("query = %+v", service.itemQuery)
	}
	decodeData[OutboundStatsData](t, writer)
}

func TestHandlerBusinessUsersBindsPeriod(t *testing.T) {
	service := &reportServiceStub{}
	router := reportingRouter(service, true)

	writer := doRequest(router, http.MethodGet, "/reports/business-users?period=2026-09", nil)
	if writer.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", writer.Code, writer.Body.String())
	}
	if !service.businessUsersCalled || service.businessUserQuery.Period != "2026-09" {
		t.Fatalf("query = %+v called=%v", service.businessUserQuery, service.businessUsersCalled)
	}
	data := decodeData[BusinessUserReportData](t, writer)
	if len(data.Items) != 1 || data.Summary.DocumentCount != 2 {
		t.Fatalf("data = %+v", data)
	}
}

func TestHandlerCreateSnapshotBindsBodyAndRejectsUnknownFields(t *testing.T) {
	service := &reportServiceStub{}
	router := reportingRouter(service, true)

	body := []byte(`{"period":"2026-09","scope":"business_user","business_user_id":8,"remark":"九月总结算"}`)
	writer := doRequest(router, http.MethodPost, "/reports/summary-settlements", body)
	if writer.Code != http.StatusCreated {
		t.Fatalf("status=%d body=%s", writer.Code, writer.Body.String())
	}
	if !service.createCalled {
		t.Fatalf("服务层未被调用")
	}
	if service.createRequest.Scope != "business_user" || service.createRequest.BusinessUserID != 8 {
		t.Fatalf("request = %+v", service.createRequest)
	}
	if service.createRequest.Remark == nil || *service.createRequest.Remark != "九月总结算" {
		t.Fatalf("remark = %v", service.createRequest.Remark)
	}
	data := decodeData[CreateSnapshotData](t, writer)
	if data.BatchNo != "ZJS202609-0001" || len(data.Snapshots) != 1 {
		t.Fatalf("data = %+v", data)
	}

	// 未知字段必须被拒绝：客户端多传一个 kind 之类的字段时不能静默忽略。
	service = &reportServiceStub{}
	router = reportingRouter(service, true)
	writer = doRequest(router, http.MethodPost, "/reports/summary-settlements",
		[]byte(`{"period":"2026-09","scope":"company","kind":"payment"}`))
	if writer.Code != http.StatusBadRequest {
		t.Fatalf("未知字段应返回 400, got %d body=%s", writer.Code, writer.Body.String())
	}
	if service.createCalled {
		t.Fatalf("非法请求不应触达服务层")
	}
}

func TestHandlerListSnapshotsBindsQuery(t *testing.T) {
	service := &reportServiceStub{}
	router := reportingRouter(service, true)

	writer := doRequest(router, http.MethodGet, "/reports/summary-settlements?period=2026-09&scope=company&page=1&page_size=10", nil)
	if writer.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", writer.Code, writer.Body.String())
	}
	if !service.listCalled {
		t.Fatalf("服务层未被调用")
	}
	if service.snapshotListQuery.Period != "2026-09" || service.snapshotListQuery.Scope != ScopeCompany || service.snapshotListQuery.PageSize != 10 {
		t.Fatalf("query = %+v", service.snapshotListQuery)
	}
	decodeData[SnapshotPageData](t, writer)
}

func TestHandlerGetSnapshotParsesPathAndRejectsInvalidID(t *testing.T) {
	service := &reportServiceStub{}
	router := reportingRouter(service, true)

	writer := doRequest(router, http.MethodGet, "/reports/summary-settlements/42", nil)
	if writer.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", writer.Code, writer.Body.String())
	}
	if !service.getCalled || service.snapshotID != 42 {
		t.Fatalf("snapshotID = %d called=%v", service.snapshotID, service.getCalled)
	}
	decodeData[SnapshotData](t, writer)

	for _, bad := range []string{"abc", "0"} {
		service = &reportServiceStub{}
		router = reportingRouter(service, true)
		writer = doRequest(router, http.MethodGet, "/reports/summary-settlements/"+bad, nil)
		if writer.Code != http.StatusBadRequest {
			t.Fatalf("snapshot_id=%q 应返回 400, got %d", bad, writer.Code)
		}
		if service.getCalled {
			t.Fatalf("snapshot_id=%q 不应触达服务层", bad)
		}
	}
}

func TestHandlerRejectsAnonymousRequests(t *testing.T) {
	service := &reportServiceStub{}
	router := reportingRouter(service, false)

	cases := []struct {
		method string
		target string
	}{
		{http.MethodGet, "/reports/overview"},
		{http.MethodGet, "/reports/inbound-stats"},
		{http.MethodGet, "/reports/outbound-stats"},
		{http.MethodGet, "/reports/business-users"},
		{http.MethodPost, "/reports/summary-settlements"},
		{http.MethodGet, "/reports/summary-settlements"},
		{http.MethodGet, "/reports/summary-settlements/1"},
	}
	for _, item := range cases {
		writer := doRequest(router, item.method, item.target, nil)
		if writer.Code != http.StatusUnauthorized {
			t.Fatalf("%s %s 匿名请求应返回 401, got %d body=%s", item.method, item.target, writer.Code, writer.Body.String())
		}
	}
}

func TestHandlerMapsServiceErrors(t *testing.T) {
	cases := []struct {
		name     string
		err      error
		method   string
		target   string
		body     []byte
		wantCode int
		wantBody string
	}{
		{"forbidden", apperror.ErrForbidden, http.MethodGet, "/reports/overview", nil, http.StatusForbidden, apperror.CodeForbidden},
		{"snapshot not found", apperror.ErrReportSnapshotNotFound, http.MethodGet, "/reports/summary-settlements/9", nil, http.StatusNotFound, apperror.CodeReportSnapshotNotFound},
		{"period empty", apperror.ErrReportPeriodEmpty, http.MethodPost, "/reports/summary-settlements", []byte(`{"period":"2026-09","scope":"company"}`), http.StatusBadRequest, apperror.CodeReportPeriodEmpty},
		{"validation", apperror.ErrValidationFailed, http.MethodGet, "/reports/business-users", nil, http.StatusBadRequest, apperror.CodeValidationFailed},
	}
	for _, item := range cases {
		t.Run(item.name, func(t *testing.T) {
			service := &reportServiceStub{err: item.err}
			router := reportingRouter(service, true)
			writer := doRequest(router, item.method, item.target, item.body)
			if writer.Code != item.wantCode {
				t.Fatalf("status = %d, want %d body=%s", writer.Code, item.wantCode, writer.Body.String())
			}
			var envelope struct {
				Code string `json:"code"`
			}
			if err := json.Unmarshal(writer.Body.Bytes(), &envelope); err != nil {
				t.Fatalf("decode: %v", err)
			}
			if envelope.Code != item.wantBody {
				t.Fatalf("code = %q, want %q", envelope.Code, item.wantBody)
			}
		})
	}
}

// TestSnapshotDataSerializesFrozenAmounts 确认金额以定点字符串传输，
// 避免客户端用双精度浮点解析出现分位误差。
func TestSnapshotDataSerializesFrozenAmounts(t *testing.T) {
	service := &reportServiceStub{}
	router := reportingRouter(service, true)
	writer := doRequest(router, http.MethodGet, "/reports/summary-settlements/1", nil)

	var raw struct {
		Data map[string]json.RawMessage `json:"data"`
	}
	if err := json.Unmarshal(writer.Body.Bytes(), &raw); err != nil {
		t.Fatalf("decode: %v", err)
	}
	for _, field := range []string{"inbound_amount", "outbound_amount", "gross_profit"} {
		value, ok := raw.Data[field]
		if !ok {
			t.Fatalf("缺少字段 %s", field)
		}
		if len(value) == 0 || value[0] != '"' {
			t.Fatalf("字段 %s 必须以字符串传输, got %s", field, value)
		}
	}
	if _, err := time.Parse("2006-01-02", mustUnquote(t, raw.Data["period"])); err != nil {
		// period 是 YYYY-MM，用月份格式再校验一次。
		if _, monthErr := time.Parse("2006-01", mustUnquote(t, raw.Data["period"])); monthErr != nil {
			t.Fatalf("period 格式非法: %s", raw.Data["period"])
		}
	}
}

func mustUnquote(t *testing.T, raw json.RawMessage) string {
	t.Helper()
	var value string
	if err := json.Unmarshal(raw, &value); err != nil {
		t.Fatalf("unquote %s: %v", raw, err)
	}
	return value
}
