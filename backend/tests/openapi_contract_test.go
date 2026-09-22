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
		{method: http.MethodGet, path: "/api/v1/platform/groups"},
		{method: http.MethodGet, path: "/api/v1/platform/groups/{group_id}"},
		{method: http.MethodPatch, path: "/api/v1/platform/groups/{group_id}/status"},
		{method: http.MethodPut, path: "/api/v1/platform/groups/{group_id}/owner"},
		{method: http.MethodPost, path: "/api/v1/groups/invitations"},
		{method: http.MethodGet, path: "/api/v1/groups/invitations"},
		{method: http.MethodPost, path: "/api/v1/groups/invitations/{invitation_id}/secret"},
		{method: http.MethodPost, path: "/api/v1/groups/invitations/{invitation_id}/revoke"},
		{method: http.MethodPost, path: "/api/v1/auth/web/login"},
		{method: http.MethodPost, path: "/api/v1/auth/web/refresh"},
		{method: http.MethodPost, path: "/api/v1/auth/web/logout"},
		{method: http.MethodGet, path: "/api/v1/groups/members"},
		{method: http.MethodPatch, path: "/api/v1/groups/members/{membership_id}/status"},
		{method: http.MethodGet, path: "/api/v1/groups/members/{membership_id}/permissions"},
		{method: http.MethodPut, path: "/api/v1/groups/members/{membership_id}/permissions"},
		{method: http.MethodGet, path: "/api/v1/groups/permission-catalog"},
		{method: http.MethodGet, path: "/api/v1/dictionaries"},
		{method: http.MethodPost, path: "/api/v1/dictionaries"},
		{method: http.MethodPut, path: "/api/v1/dictionaries/{dictionary_id}"},
		{method: http.MethodPatch, path: "/api/v1/dictionaries/{dictionary_id}/status"},
		{method: http.MethodPost, path: "/api/v1/inbound-documents"},
		{method: http.MethodGet, path: "/api/v1/inbound-documents"},
		{method: http.MethodGet, path: "/api/v1/inbound-documents/monthly-summary"},
		{method: http.MethodGet, path: "/api/v1/inbound-documents/{document_id}"},
		{method: http.MethodPut, path: "/api/v1/inbound-documents/{document_id}"},
		{method: http.MethodPost, path: "/api/v1/inbound-documents/{document_id}/submit"},
		{method: http.MethodPost, path: "/api/v1/inbound-documents/{document_id}/void"},
		{method: http.MethodPost, path: "/api/v1/outbound-documents"},
		{method: http.MethodGet, path: "/api/v1/outbound-documents"},
		{method: http.MethodGet, path: "/api/v1/outbound-documents/monthly-summary"},
		{method: http.MethodGet, path: "/api/v1/outbound-documents/{document_id}"},
		{method: http.MethodPut, path: "/api/v1/outbound-documents/{document_id}"},
		{method: http.MethodPost, path: "/api/v1/outbound-documents/{document_id}/submit"},
		{method: http.MethodPost, path: "/api/v1/outbound-documents/{document_id}/void"},
		{method: http.MethodPost, path: "/api/v1/settlements"},
		{method: http.MethodGet, path: "/api/v1/settlements"},
		{method: http.MethodGet, path: "/api/v1/settlements/{settlement_id}"},
		{method: http.MethodPost, path: "/api/v1/settlements/{settlement_id}/approve"},
		{method: http.MethodPost, path: "/api/v1/settlements/{settlement_id}/reject"},
		{method: http.MethodPost, path: "/api/v1/finance/payments"},
		{method: http.MethodGet, path: "/api/v1/finance/payments"},
		{method: http.MethodPost, path: "/api/v1/finance/payments/{record_id}/revoke"},
		{method: http.MethodPost, path: "/api/v1/finance/receipts"},
		{method: http.MethodGet, path: "/api/v1/finance/receipts"},
		{method: http.MethodPost, path: "/api/v1/finance/receipts/{record_id}/revoke"},
		{method: http.MethodPost, path: "/api/v1/finance/invoices"},
		{method: http.MethodGet, path: "/api/v1/finance/invoices"},
		{method: http.MethodPost, path: "/api/v1/finance/invoices/{record_id}/revoke"},
		{method: http.MethodGet, path: "/api/v1/finance/statements/{document_id}"},
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
		"INVITATION_NOT_FOUND",
		"INVITATION_NOT_REVEALABLE",
		"INVITATION_NOT_REVOKABLE",
		"INVITATION_DECRYPT_FAILED",
		"GROUP_NAME_EXISTS",
		"GROUP_NOT_FOUND",
		"OWNER_TARGET_INVALID",
		"MEMBER_NOT_FOUND",
		"MEMBER_OWNER_PROTECTED",
		"MEMBER_SELF_OPERATION_FORBIDDEN",
		"PERMISSION_CODE_INVALID",
		"DICTIONARY_NOT_FOUND",
		"DICTIONARY_NAME_EXISTS",
		"DICTIONARY_PARENT_INVALID",
		"DOCUMENT_NOT_FOUND",
		"DOCUMENT_STATUS_INVALID",
		"DOCUMENT_INCOMPLETE",
		"SETTLEMENT_NOT_FOUND",
		"SETTLEMENT_STATUS_INVALID",
		"SETTLEMENT_SOURCE_INVALID",
		"SETTLEMENT_SOURCE_CONFLICT",
		"SETTLEMENT_REMARK_REQUIRED",
		"IDEMPOTENCY_KEY_REUSED",
		"RESOURCE_VERSION_CONFLICT",
		"CSRF_INVALID",
		"ORIGIN_FORBIDDEN",
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

// TestOpenAPIContractDocuments 锁定入库/出库单据契约的关键约定：
// 枚举取值、必填字段、幂等键请求头与单据 ID 路径参数。
func TestOpenAPIContractDocuments(t *testing.T) {
	contractPath := filepath.Join("..", "..", "api", "openapi", "cbizdocsmanager-v1.yaml")
	doc, err := openapi3.NewLoader().LoadFromFile(contractPath)
	if err != nil {
		t.Fatalf("load OpenAPI contract %q: %v", contractPath, err)
	}
	if err := doc.Validate(context.Background()); err != nil {
		t.Fatalf("validate OpenAPI contract: %v", err)
	}

	assertTopLevelEnum(t, requireSchema(t, doc, "DocumentKind"), []string{"inbound", "outbound"})
	assertTopLevelEnum(t, requireSchema(t, doc, "DocumentStatus"), []string{"draft", "submitted", "voided"})
	assertTopLevelEnum(t, requireSchema(t, doc, "PriceTaxMode"), []string{"tax_included", "tax_excluded"})
	assertTopLevelEnum(t, requireSchema(t, doc, "SaleAmountType"), []string{"Y-1", "y-N", "N"})

	documentData := requireSchema(t, doc, "DocumentData")
	for _, property := range []string{
		"document_id", "kind", "document_no", "status", "business_user", "business_date",
		"total_amount", "total_amount_upper", "version", "parties",
	} {
		if !containsString(documentData.Required, property) {
			t.Errorf("DocumentData must require property %q", property)
		}
	}

	summaryData := requireSchema(t, doc, "DocumentSummaryData")
	for _, property := range []string{"document_id", "document_no", "status", "party_names", "item_count", "total_amount"} {
		if !containsString(summaryData.Required, property) {
			t.Errorf("DocumentSummaryData must require property %q", property)
		}
	}

	monthlySummary := requireSchema(t, doc, "MonthlySummaryData")
	for _, property := range []string{"month", "kind", "document_count", "draft_count", "submitted_count", "voided_count", "total_amount", "total_amount_upper", "parties"} {
		if !containsString(monthlySummary.Required, property) {
			t.Errorf("MonthlySummaryData must require property %q", property)
		}
	}

	createRequest := requireSchema(t, doc, "CreateDocumentRequest")
	for _, property := range []string{"status", "business_date", "parties"} {
		if !containsString(createRequest.Required, property) {
			t.Errorf("CreateDocumentRequest must require property %q", property)
		}
	}
	updateRequest := requireSchema(t, doc, "UpdateDocumentRequest")
	for _, property := range []string{"version", "status", "business_date", "parties"} {
		if !containsString(updateRequest.Required, property) {
			t.Errorf("UpdateDocumentRequest must require property %q", property)
		}
	}

	create := doc.Paths.Find("/api/v1/inbound-documents")
	if create == nil || create.Post == nil {
		t.Fatal("missing operation POST /api/v1/inbound-documents")
	}
	if create.Post.Parameters.GetByInAndName("header", "Idempotency-Key") == nil {
		t.Error("POST /api/v1/inbound-documents must declare Idempotency-Key header")
	}

	detail := doc.Paths.Find("/api/v1/outbound-documents/{document_id}")
	if detail == nil || detail.Put == nil {
		t.Fatal("missing operation PUT /api/v1/outbound-documents/{document_id}")
	}
	if detail.Put.Parameters.GetByInAndName("path", "document_id") == nil {
		t.Error("PUT /api/v1/outbound-documents/{document_id} must declare document_id path parameter")
	}
	if detail.Put.Parameters.GetByInAndName("header", "Idempotency-Key") == nil {
		t.Error("PUT /api/v1/outbound-documents/{document_id} must declare Idempotency-Key header")
	}
}

// TestOpenAPIContractSettlements 锁定结算与审批契约的关键约定：
// 枚举取值、必填字段、幂等键请求头与结算单 ID 路径参数。
func TestOpenAPIContractSettlements(t *testing.T) {
	contractPath := filepath.Join("..", "..", "api", "openapi", "cbizdocsmanager-v1.yaml")
	doc, err := openapi3.NewLoader().LoadFromFile(contractPath)
	if err != nil {
		t.Fatalf("load OpenAPI contract %q: %v", contractPath, err)
	}
	if err := doc.Validate(context.Background()); err != nil {
		t.Fatalf("validate OpenAPI contract: %v", err)
	}

	assertTopLevelEnum(t, requireSchema(t, doc, "SettlementStatus"), []string{"pending", "approved", "rejected"})
	assertTopLevelEnum(t, requireSchema(t, doc, "SettlementAction"), []string{"submitted", "approved", "rejected"})

	settlementData := requireSchema(t, doc, "SettlementData")
	for _, property := range []string{
		"settlement_id", "settlement_no", "status", "requester", "inbound_total", "outbound_total",
		"gross_profit", "source_count", "inbound_total_upper", "outbound_total_upper",
		"gross_profit_upper", "version", "sources", "approval_records",
	} {
		if !containsString(settlementData.Required, property) {
			t.Errorf("SettlementData must require property %q", property)
		}
	}

	summaryData := requireSchema(t, doc, "SettlementSummaryData")
	for _, property := range []string{
		"settlement_id", "settlement_no", "status", "requester", "inbound_total",
		"outbound_total", "gross_profit", "source_count", "version",
	} {
		if !containsString(summaryData.Required, property) {
			t.Errorf("SettlementSummaryData must require property %q", property)
		}
	}

	sourceData := requireSchema(t, doc, "SettlementSourceData")
	for _, property := range []string{"document_id", "kind", "document_no", "business_user", "business_date", "amount", "released"} {
		if !containsString(sourceData.Required, property) {
			t.Errorf("SettlementSourceData must require property %q", property)
		}
	}

	// 列表行与详情行的人员摘要都必须是完整的用户对象，不能只回填姓名，
	// 否则客户端按 UserSummary.account_type 枚举校验时会被空串卡住。
	for _, schemaName := range []string{"SettlementData", "SettlementSummaryData"} {
		schema := requireSchema(t, doc, schemaName)
		requesterRef, ok := schema.Properties["requester"]
		if !ok || requesterRef == nil || requesterRef.Ref == "" {
			t.Errorf("%s.requester must reference UserSummary", schemaName)
		}
	}
	if summaryData.Properties["requester"].Ref != "#/components/schemas/UserSummary" {
		t.Errorf("SettlementSummaryData.requester ref = %q", summaryData.Properties["requester"].Ref)
	}

	createRequest := requireSchema(t, doc, "CreateSettlementRequest")
	if !containsString(createRequest.Required, "sources") {
		t.Error("CreateSettlementRequest must require property \"sources\"")
	}
	decideRequest := requireSchema(t, doc, "DecideSettlementRequest")
	if !containsString(decideRequest.Required, "version") {
		t.Error("DecideSettlementRequest must require property \"version\"")
	}

	create := doc.Paths.Find("/api/v1/settlements")
	if create == nil || create.Post == nil {
		t.Fatal("missing operation POST /api/v1/settlements")
	}
	if create.Post.Parameters.GetByInAndName("header", "Idempotency-Key") == nil {
		t.Error("POST /api/v1/settlements must declare Idempotency-Key header")
	}

	approve := doc.Paths.Find("/api/v1/settlements/{settlement_id}/approve")
	if approve == nil || approve.Post == nil {
		t.Fatal("missing operation POST /api/v1/settlements/{settlement_id}/approve")
	}
	if approve.Post.Parameters.GetByInAndName("path", "settlement_id") == nil {
		t.Error("POST /api/v1/settlements/{settlement_id}/approve must declare settlement_id path parameter")
	}
	// 重复审批是单级审批的核心冲突分支，契约必须显式声明，客户端才能据此提示状态已变更。
	if !operationDeclaresErrorCode(approve.Post, "SETTLEMENT_STATUS_INVALID") {
		t.Error("POST /api/v1/settlements/{settlement_id}/approve must declare SETTLEMENT_STATUS_INVALID")
	}

	reject := doc.Paths.Find("/api/v1/settlements/{settlement_id}/reject")
	if reject == nil || reject.Post == nil {
		t.Fatal("missing operation POST /api/v1/settlements/{settlement_id}/reject")
	}
	// 驳回必须能表达「未填原因」这一分支，客户端才能区分该引导用户补填。
	if !operationDeclaresErrorCode(reject.Post, "SETTLEMENT_REMARK_REQUIRED") {
		t.Error("POST /api/v1/settlements/{settlement_id}/reject must declare SETTLEMENT_REMARK_REQUIRED")
	}
}

// TestOpenAPIContractFinance 锁定付款 / 收款 / 开票契约的关键约定：
// 枚举取值、必填字段、幂等键与记录 ID 路径参数，以及「记录类型不可由客户端提交」这一硬约束。
func TestOpenAPIContractFinance(t *testing.T) {
	contractPath := filepath.Join("..", "..", "api", "openapi", "cbizdocsmanager-v1.yaml")
	doc, err := openapi3.NewLoader().LoadFromFile(contractPath)
	if err != nil {
		t.Fatalf("load OpenAPI contract %q: %v", contractPath, err)
	}
	if err := doc.Validate(context.Background()); err != nil {
		t.Fatalf("validate OpenAPI contract: %v", err)
	}

	assertTopLevelEnum(t, requireSchema(t, doc, "FinanceRecordKind"), []string{"payment", "receipt", "invoice"})
	assertTopLevelEnum(t, requireSchema(t, doc, "FinanceMethod"), []string{"transfer", "private_card", "public_account"})
	// not_applicable 是出库单的合法取值：出库单不存在开票概念，不能返回 none 误导客户端。
	assertTopLevelEnum(t, requireSchema(t, doc, "InvoiceStatus"), []string{"none", "partial", "full", "not_applicable"})

	recordData := requireSchema(t, doc, "FinanceRecordData")
	for _, property := range []string{
		"record_id", "kind", "document_id", "document_kind", "document_no", "party_name",
		"business_user", "business_date", "amount", "amount_upper", "occurred_on", "created_by", "created_at",
	} {
		if !containsString(recordData.Required, property) {
			t.Errorf("FinanceRecordData must require property %q", property)
		}
	}

	statementData := requireSchema(t, doc, "FinanceStatementData")
	for _, property := range []string{
		"document_id", "document_kind", "document_no", "party_name", "business_user", "business_date",
		"total_amount", "total_amount_upper",
		"paid_amount", "unpaid_amount", "paid_amount_upper", "unpaid_amount_upper",
		"invoiced_amount", "uninvoiced_amount", "invoiced_amount_upper", "uninvoiced_amount_upper", "invoice_status",
		"received_amount", "unreceived_amount", "received_amount_upper", "unreceived_amount_upper",
		"payment_count", "receipt_count", "invoice_count", "records",
	} {
		if !containsString(statementData.Required, property) {
			t.Errorf("FinanceStatementData must require property %q", property)
		}
	}

	// 记录里的人员字段必须是完整的用户对象，不能只回填姓名，
	// 否则客户端按 UserSummary.account_type 枚举校验时会被空串卡住。
	for _, property := range []string{"business_user", "created_by"} {
		ref, ok := recordData.Properties[property]
		if !ok || ref == nil || ref.Ref != "#/components/schemas/UserSummary" {
			t.Errorf("FinanceRecordData.%s must reference UserSummary", property)
		}
	}
	// 单据结清视图的业务员字段同理。
	if ref := statementData.Properties["business_user"]; ref == nil || ref.Ref != "#/components/schemas/UserSummary" {
		t.Error("FinanceStatementData.business_user must reference UserSummary")
	}

	// 记录类型必须由路由决定：请求体里一旦出现 kind 字段，契约就挡不住「用付款接口写收款」。
	createRequest := requireSchema(t, doc, "CreateFinanceRecordRequest")
	for _, property := range []string{"document_id", "amount", "occurred_on"} {
		if !containsString(createRequest.Required, property) {
			t.Errorf("CreateFinanceRecordRequest must require property %q", property)
		}
	}
	if _, ok := createRequest.Properties["kind"]; ok {
		t.Error("CreateFinanceRecordRequest must not declare a kind property")
	}

	// 三类记录各自都有幂等键、记录 ID 路径参数与撤销分支。
	for _, path := range []string{
		"/api/v1/finance/payments",
		"/api/v1/finance/receipts",
		"/api/v1/finance/invoices",
	} {
		create := doc.Paths.Find(path)
		if create == nil || create.Post == nil {
			t.Fatalf("missing operation POST %s", path)
		}
		if create.Post.Parameters.GetByInAndName("header", "Idempotency-Key") == nil {
			t.Errorf("POST %s must declare Idempotency-Key header", path)
		}
		// 累计超额与类型不匹配是记账最常见的两个失败分支，必须在契约里显式声明。
		if !operationDeclaresErrorCode(create.Post, "FINANCE_AMOUNT_EXCEEDS") {
			t.Errorf("POST %s must declare FINANCE_AMOUNT_EXCEEDS", path)
		}
		if !operationDeclaresErrorCode(create.Post, "FINANCE_DOCUMENT_MISMATCH") {
			t.Errorf("POST %s must declare FINANCE_DOCUMENT_MISMATCH", path)
		}
		if create.Get == nil {
			t.Errorf("missing operation GET %s", path)
		}

		revoke := doc.Paths.Find(path + "/{record_id}/revoke")
		if revoke == nil || revoke.Post == nil {
			t.Fatalf("missing operation POST %s/{record_id}/revoke", path)
		}
		if revoke.Post.Parameters.GetByInAndName("path", "record_id") == nil {
			t.Errorf("POST %s/{record_id}/revoke must declare record_id path parameter", path)
		}
		// 用错记录类型的接口（例如用收款接口撤销付款）按「记录不存在」处理，客户端据此提示已撤销。
		if !operationDeclaresErrorCode(revoke.Post, "FINANCE_RECORD_NOT_FOUND") {
			t.Errorf("POST %s/{record_id}/revoke must declare FINANCE_RECORD_NOT_FOUND", path)
		}
	}

	statement := doc.Paths.Find("/api/v1/finance/statements/{document_id}")
	if statement == nil || statement.Get == nil {
		t.Fatal("missing operation GET /api/v1/finance/statements/{document_id}")
	}
	if statement.Get.Parameters.GetByInAndName("path", "document_id") == nil {
		t.Error("GET /api/v1/finance/statements/{document_id} must declare document_id path parameter")
	}

	// 新增的权限码必须进入目录枚举，否则主账号在权限勾选页面上根本选不到它。
	assertTopLevelEnum(t, requireSchema(t, doc, "PermissionCode"), []string{
		"document.view_others", "document.edit_others", "report.view",
		"member.manage", "dictionary.manage", "settlement.approve", "finance.record",
	})
}

// operationDeclaresErrorCode 检查某个操作是否在 4xx 响应的 x-error-codes 里声明了指定错误码。
func operationDeclaresErrorCode(operation *openapi3.Operation, code string) bool {
	if operation == nil || operation.Responses == nil {
		return false
	}
	for _, responseRef := range operation.Responses.Map() {
		if responseRef == nil || responseRef.Value == nil {
			continue
		}
		raw, ok := responseRef.Value.Extensions["x-error-codes"]
		if !ok {
			continue
		}
		codes, ok := raw.([]any)
		if !ok {
			continue
		}
		for _, item := range codes {
			if value, ok := item.(string); ok && value == code {
				return true
			}
		}
	}
	return false
}

func assertTopLevelEnum(t *testing.T, schema *openapi3.Schema, values []string) {
	t.Helper()
	if len(schema.Enum) != len(values) {
		t.Errorf("enum = %#v, want exactly %#v", schema.Enum, values)
	}
	for _, value := range values {
		if !containsEnumString(schema.Enum, value) {
			t.Errorf("enum is missing %q", value)
		}
	}
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
