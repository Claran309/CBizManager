package settlement

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

// settlementServiceStub 记录 Handler 传给服务层的入参，用于断言协议转换是否正确。
type settlementServiceStub struct {
	err            error
	idempotencyKey string
	settlementID   uint64
	version        uint64
	remark         string
	hasRemark      bool
	sourceIDs      []uint64
	listQuery      ListQuery
	approveCalled  bool
	rejectCalled   bool
}

func (s *settlementServiceStub) Create(_ context.Context, _ identity.Principal, request CreateRequest, idempotencyKey string) (*SettlementData, error) {
	s.idempotencyKey = idempotencyKey
	for _, source := range request.Sources {
		s.sourceIDs = append(s.sourceIDs, source.DocumentID)
	}
	if request.Remark != nil {
		s.remark, s.hasRemark = *request.Remark, true
	}
	if s.err != nil {
		return nil, s.err
	}
	return stubSettlementData(), nil
}

func (s *settlementServiceStub) Get(_ context.Context, _ identity.Principal, settlementID uint64) (*SettlementData, error) {
	s.settlementID = settlementID
	if s.err != nil {
		return nil, s.err
	}
	return stubSettlementData(), nil
}

func (s *settlementServiceStub) List(_ context.Context, _ identity.Principal, query ListQuery) (*SettlementPageData, error) {
	s.listQuery = query
	if s.err != nil {
		return nil, s.err
	}
	return &SettlementPageData{
		Items: []SettlementSummaryData{{
			SettlementID: 1, SettlementNo: "JS202609-0001", Status: StatusPending,
			InboundTotal: money.AmountFromYuan(147092), OutboundTotal: money.AmountFromYuan(173520),
			GrossProfit: money.AmountFromYuan(26428), SourceCount: 2, Version: 1,
		}},
		Page: query.Page, PageSize: query.PageSize, Total: 1,
	}, nil
}

func (s *settlementServiceStub) Approve(_ context.Context, _ identity.Principal, settlementID uint64, request DecideRequest) (*SettlementData, error) {
	s.approveCalled, s.settlementID, s.version = true, settlementID, request.Version
	if request.Remark != nil {
		s.remark, s.hasRemark = *request.Remark, true
	}
	if s.err != nil {
		return nil, s.err
	}
	return stubSettlementData(), nil
}

func (s *settlementServiceStub) Reject(_ context.Context, _ identity.Principal, settlementID uint64, request DecideRequest) (*SettlementData, error) {
	s.rejectCalled, s.settlementID, s.version = true, settlementID, request.Version
	if request.Remark != nil {
		s.remark, s.hasRemark = *request.Remark, true
	}
	if s.err != nil {
		return nil, s.err
	}
	return stubSettlementData(), nil
}

// stubSettlementData 造一份带源单据与审批记录的详情响应，覆盖全部对外字段。
func stubSettlementData() *SettlementData {
	return &SettlementData{
		SettlementID: 1, SettlementNo: "JS202609-0001", Status: StatusPending,
		Requester:    identity.UserSummary{ID: 7, DisplayName: "王业务"},
		InboundTotal: money.AmountFromYuan(147092), OutboundTotal: money.AmountFromYuan(173520),
		GrossProfit: money.AmountFromYuan(26428), SourceCount: 2,
		InboundUpper: "RMB壹拾肆万柒仟零玖拾贰元整", OutboundUpper: "RMB壹拾柒万叁仟伍佰贰拾元整",
		GrossProfitUpper: "RMB贰万陆仟肆佰贰拾捌元整", Version: 1,
		Sources: []SourceData{{
			DocumentID: 11, Kind: document.KindInbound, DocumentNo: "RK20260922-0001",
			BusinessUser: identity.UserSummary{ID: 7, DisplayName: "王业务"},
			BusinessDate: "2026-09-22", Amount: money.AmountFromYuan(147092),
		}},
		ApprovalRecords: []ApprovalRecordData{{
			Action: ActionSubmitted, Operator: identity.UserSummary{ID: 7, DisplayName: "王业务"},
		}},
	}
}

func settlementRouter(service SettlementService, withPrincipal bool) *gin.Engine {
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
	handler := NewHandler(service)
	router.POST("/settlements", handler.Create)
	router.GET("/settlements", handler.List)
	router.GET("/settlements/:settlement_id", handler.Get)
	router.POST("/settlements/:settlement_id/approve", handler.Approve)
	router.POST("/settlements/:settlement_id/reject", handler.Reject)
	return router
}

func TestHandlerCreateParsesSourcesAndIdempotencyHeader(t *testing.T) {
	service := &settlementServiceStub{}
	router := settlementRouter(service, true)
	body := []byte(`{"remark":"九月第一批","sources":[{"document_id":11},{"document_id":12}]}`)
	request := httptest.NewRequest(http.MethodPost, "/settlements", bytes.NewReader(body))
	request.Header.Set("Content-Type", "application/json")
	// 幂等键首尾空白必须被裁掉，否则离线队列重放会因为空格而命中不了同一条记录。
	request.Header.Set(idempotencyHeader, "  offline-queue-1  ")
	writer := httptest.NewRecorder()
	router.ServeHTTP(writer, request)

	if writer.Code != http.StatusCreated {
		t.Fatalf("status=%d body=%s", writer.Code, writer.Body.String())
	}
	if service.idempotencyKey != "offline-queue-1" {
		t.Fatalf("idempotency key = %q", service.idempotencyKey)
	}
	if len(service.sourceIDs) != 2 || service.sourceIDs[0] != 11 || service.sourceIDs[1] != 12 {
		t.Fatalf("source ids = %+v", service.sourceIDs)
	}
	if !service.hasRemark || service.remark != "九月第一批" {
		t.Fatalf("remark = %q (set=%v)", service.remark, service.hasRemark)
	}

	var envelope struct {
		Code string         `json:"code"`
		Data SettlementData `json:"data"`
	}
	if err := json.Unmarshal(writer.Body.Bytes(), &envelope); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if envelope.Data.SettlementNo != "JS202609-0001" || envelope.Data.GrossProfit != money.AmountFromYuan(26428) {
		t.Fatalf("data = %+v", envelope.Data)
	}
	// 大写金额由服务端给出，客户端不需要自己算。
	if envelope.Data.GrossProfitUpper != "RMB贰万陆仟肆佰贰拾捌元整" {
		t.Fatalf("gross profit upper = %q", envelope.Data.GrossProfitUpper)
	}
}

func TestHandlerCreateAllowsMissingIdempotencyKey(t *testing.T) {
	service := &settlementServiceStub{}
	router := settlementRouter(service, true)
	request := httptest.NewRequest(http.MethodPost, "/settlements",
		bytes.NewReader([]byte(`{"sources":[{"document_id":11}]}`)))
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

func TestHandlerRejectsOversizedIdempotencyKey(t *testing.T) {
	service := &settlementServiceStub{}
	router := settlementRouter(service, true)
	request := httptest.NewRequest(http.MethodPost, "/settlements", bytes.NewReader([]byte(`{"sources":[{"document_id":11}]}`)))
	request.Header.Set("Content-Type", "application/json")
	request.Header.Set(idempotencyHeader, string(bytes.Repeat([]byte("k"), 192)))
	writer := httptest.NewRecorder()
	router.ServeHTTP(writer, request)

	if writer.Code != http.StatusBadRequest {
		t.Fatalf("status=%d body=%s", writer.Code, writer.Body.String())
	}
	if service.idempotencyKey != "" || len(service.sourceIDs) != 0 {
		t.Fatal("service must not be called with an oversized key")
	}
}

func TestHandlerRejectsUnknownFieldsAndBadIDs(t *testing.T) {
	service := &settlementServiceStub{}
	router := settlementRouter(service, true)

	request := httptest.NewRequest(http.MethodPost, "/settlements",
		bytes.NewReader([]byte(`{"sources":[{"document_id":11}],"unknown_field":1}`)))
	request.Header.Set("Content-Type", "application/json")
	writer := httptest.NewRecorder()
	router.ServeHTTP(writer, request)
	if writer.Code != http.StatusBadRequest {
		t.Fatalf("unknown field status=%d body=%s", writer.Code, writer.Body.String())
	}

	// 路径参数不是正整数时必须 400，而不是落到服务层再报 500。
	writer = httptest.NewRecorder()
	router.ServeHTTP(writer, httptest.NewRequest(http.MethodGet, "/settlements/abc", nil))
	if writer.Code != http.StatusBadRequest {
		t.Fatalf("bad id status=%d body=%s", writer.Code, writer.Body.String())
	}

	// 结算单 ID 为 0 同样非法。
	writer = httptest.NewRecorder()
	router.ServeHTTP(writer, httptest.NewRequest(http.MethodGet, "/settlements/0", nil))
	if writer.Code != http.StatusBadRequest {
		t.Fatalf("zero id status=%d body=%s", writer.Code, writer.Body.String())
	}

	// 没有身份时必须返回登录过期，而不是 500。
	anonymous := settlementRouter(&settlementServiceStub{}, false)
	writer = httptest.NewRecorder()
	anonymous.ServeHTTP(writer, httptest.NewRequest(http.MethodGet, "/settlements/1", nil))
	if writer.Code != http.StatusUnauthorized {
		t.Fatalf("anonymous status=%d body=%s", writer.Code, writer.Body.String())
	}
}

func TestHandlerMapsServiceErrorsAndQueryParams(t *testing.T) {
	service := &settlementServiceStub{err: apperror.ErrSettlementStatusInvalid}
	router := settlementRouter(service, true)

	// 审批：路径 ID 与请求体版本号都要原样交给服务层。
	writer := httptest.NewRecorder()
	router.ServeHTTP(writer, httptest.NewRequest(http.MethodPost, "/settlements/5/approve",
		bytes.NewReader([]byte(`{"version":3}`))))
	if writer.Code != http.StatusConflict || service.settlementID != 5 || service.version != 3 {
		t.Fatalf("approve status=%d service=%+v", writer.Code, service)
	}
	if !service.approveCalled || service.rejectCalled {
		t.Fatalf("approve called=%v reject called=%v", service.approveCalled, service.rejectCalled)
	}
	var envelope struct {
		Code string `json:"code"`
	}
	if err := json.Unmarshal(writer.Body.Bytes(), &envelope); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if envelope.Code != apperror.CodeSettlementStatusInvalid {
		t.Fatalf("code = %q", envelope.Code)
	}

	// 驳回：原因原样透传给服务层（必填校验在服务层做，保证脚本调用与界面同口径）。
	rejectService := &settlementServiceStub{}
	rejectRouter := settlementRouter(rejectService, true)
	writer = httptest.NewRecorder()
	rejectRouter.ServeHTTP(writer, httptest.NewRequest(http.MethodPost, "/settlements/9/reject",
		bytes.NewReader([]byte(`{"version":2,"remark":"金额填错"}`))))
	if writer.Code != http.StatusOK || !rejectService.rejectCalled || rejectService.version != 2 {
		t.Fatalf("reject status=%d service=%+v", writer.Code, rejectService)
	}
	if !rejectService.hasRemark || rejectService.remark != "金额填错" {
		t.Fatalf("reject remark = %q (set=%v)", rejectService.remark, rejectService.hasRemark)
	}

	// 驳回未填原因时服务层报错，Handler 要把错误码原样带回。
	missingRemark := &settlementServiceStub{err: apperror.ErrSettlementRemarkRequired}
	writer = httptest.NewRecorder()
	settlementRouter(missingRemark, true).ServeHTTP(writer, httptest.NewRequest(http.MethodPost, "/settlements/9/reject",
		bytes.NewReader([]byte(`{"version":2}`))))
	if writer.Code != http.StatusBadRequest {
		t.Fatalf("missing remark status=%d body=%s", writer.Code, writer.Body.String())
	}
	if err := json.Unmarshal(writer.Body.Bytes(), &envelope); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if envelope.Code != apperror.CodeSettlementRemarkRequired {
		t.Fatalf("code = %q", envelope.Code)
	}

	// 列表：查询参数全部绑定到 ListQuery，服务层据此做范围收敛与校验。
	listService := &settlementServiceStub{}
	writer = httptest.NewRecorder()
	settlementRouter(listService, true).ServeHTTP(writer,
		httptest.NewRequest(http.MethodGet, "/settlements?keyword=JS2026&status=pending&requester_user_id=8&month=2026-09&page=2&page_size=50", nil))
	if writer.Code != http.StatusOK {
		t.Fatalf("list status=%d body=%s", writer.Code, writer.Body.String())
	}
	query := listService.listQuery
	if query.Keyword != "JS2026" || query.Status != StatusPending || query.RequesterUserID != 8 ||
		query.Month != "2026-09" || query.Page != 2 || query.PageSize != 50 {
		t.Fatalf("list query = %+v", query)
	}

	// 列表响应要带上分页元信息与金额快照。
	var pageEnvelope struct {
		Data SettlementPageData `json:"data"`
	}
	if err := json.Unmarshal(writer.Body.Bytes(), &pageEnvelope); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if pageEnvelope.Data.Total != 1 || len(pageEnvelope.Data.Items) != 1 ||
		pageEnvelope.Data.Items[0].SettlementNo != "JS202609-0001" {
		t.Fatalf("page = %+v", pageEnvelope.Data)
	}
}
