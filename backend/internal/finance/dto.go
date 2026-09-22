package finance

import (
	"time"

	"CBizDocsManager/backend/internal/document"
	"CBizDocsManager/backend/internal/identity"
	"CBizDocsManager/backend/pkg/money"
	"CBizDocsManager/backend/pkg/rmb"
)

const businessDateLayout = "2006-01-02"

/* ------------------------------------------------------------------ 请求 */

// ListQuery 是财务记录列表查询条件。
type ListQuery struct {
	DocumentID     uint64 `form:"document_id"`
	Keyword        string `form:"keyword"`
	Method         Method `form:"method"`
	BusinessUserID uint64 `form:"business_user_id"`
	Month          string `form:"month"`
	DateFrom       string `form:"date_from"`
	DateTo         string `form:"date_to"`
	Page           int    `form:"page"`
	PageSize       int    `form:"page_size"`
}

// CreateRequest 是登记付款 / 收款 / 开票的请求体。
//
// 三类记录共用同一个请求结构：kind 由路由决定（客户端传不进来），
// 不适用的字段传了会被明确拒绝，而不是被静默忽略。
type CreateRequest struct {
	DocumentID uint64 `json:"document_id"`
	// Amount 是定点字符串（如 "30000.00"），服务端解析，避免浮点误差。
	Amount string `json:"amount"`
	// OccurredOn 是实际发生日期，兼容用户手写的五种日期写法。
	OccurredOn string  `json:"occurred_on"`
	Method     string  `json:"method"`
	MethodNote *string `json:"method_note"`
	CardTail   *string `json:"card_tail"`
	InvoiceNo  *string `json:"invoice_no"`
	Remark     *string `json:"remark"`
}

/* ------------------------------------------------------------------ 响应 */

// RecordData 是一条付款 / 收款 / 开票记录。
type RecordData struct {
	RecordID     uint64               `json:"record_id"`
	Kind         Kind                 `json:"kind"`
	DocumentID   uint64               `json:"document_id"`
	DocumentKind document.Kind        `json:"document_kind"`
	DocumentNo   string               `json:"document_no"`
	PartyName    string               `json:"party_name"`
	BusinessUser identity.UserSummary `json:"business_user"`
	BusinessDate string               `json:"business_date"`
	Amount       money.Amount         `json:"amount"`
	AmountUpper  string               `json:"amount_upper"`
	OccurredOn   string               `json:"occurred_on"`
	Method       *Method              `json:"method"`
	MethodNote   *string              `json:"method_note"`
	// CardTail 只暴露后 4 位：完整卡号不进入系统，日志与审计摘要也不含卡号。
	CardTail  *string              `json:"card_tail"`
	InvoiceNo *string              `json:"invoice_no"`
	Remark    *string              `json:"remark"`
	CreatedBy identity.UserSummary `json:"created_by"`
	CreatedAt time.Time            `json:"created_at"`
}

// RecordPageData 是财务记录分页响应。
type RecordPageData struct {
	Items    []RecordData `json:"items"`
	Page     int          `json:"page"`
	PageSize int          `json:"page_size"`
	Total    int64        `json:"total"`
}

// StatementData 是单张单据的结清视图。
//
// 三类金额只在适用的单据方向上取值，不适用的方向恒为 0，客户端不需要自己判断单据类型。
type StatementData struct {
	DocumentID   uint64               `json:"document_id"`
	DocumentKind document.Kind        `json:"document_kind"`
	DocumentNo   string               `json:"document_no"`
	PartyName    string               `json:"party_name"`
	BusinessUser identity.UserSummary `json:"business_user"`
	BusinessDate string               `json:"business_date"`
	TotalAmount  money.Amount         `json:"total_amount"`
	TotalUpper   string               `json:"total_amount_upper"`

	// 入库单方向：付款与开票。
	PaidAmount       money.Amount  `json:"paid_amount"`
	UnpaidAmount     money.Amount  `json:"unpaid_amount"`
	PaidUpper        string        `json:"paid_amount_upper"`
	UnpaidUpper      string        `json:"unpaid_amount_upper"`
	InvoicedAmount   money.Amount  `json:"invoiced_amount"`
	UninvoicedAmount money.Amount  `json:"uninvoiced_amount"`
	InvoicedUpper    string        `json:"invoiced_amount_upper"`
	UninvoicedUpper  string        `json:"uninvoiced_amount_upper"`
	InvoiceStatus    InvoiceStatus `json:"invoice_status"`

	// 出库单方向：收款。
	ReceivedAmount   money.Amount `json:"received_amount"`
	UnreceivedAmount money.Amount `json:"unreceived_amount"`
	ReceivedUpper    string       `json:"received_amount_upper"`
	UnreceivedUpper  string       `json:"unreceived_amount_upper"`

	PaymentCount int `json:"payment_count"`
	ReceiptCount int `json:"receipt_count"`
	InvoiceCount int `json:"invoice_count"`

	Records []RecordData `json:"records"`
}

// StatementApiResponse 等包装由 pkg/response 统一处理，这里只需要业务数据体。

/* ------------------------------------------------------------------ 转换 */

func toRecordData(record Record, createdBy, businessUser identity.UserSummary) RecordData {
	return RecordData{
		RecordID: record.ID, Kind: record.Kind,
		DocumentID: record.DocumentID, DocumentKind: record.DocumentKind, DocumentNo: record.DocumentNo,
		PartyName: record.PartyName, BusinessUser: businessUser,
		BusinessDate: record.BusinessDate.Format(businessDateLayout),
		Amount:       record.Amount, AmountUpper: rmb.Upper(record.Amount),
		OccurredOn: record.OccurredOn.Format(businessDateLayout),
		Method:     record.Method, MethodNote: record.MethodNote, CardTail: record.CardTail,
		InvoiceNo: record.InvoiceNo, Remark: record.Remark,
		CreatedBy: createdBy, CreatedAt: record.CreatedAt,
	}
}

// buildStatementData 组装单据结清视图。金额一律由服务端按记录合计推导。
//
// 只有适用于该单据方向的金额才给值，不适用的一律为 0：
// 客户端的详情页对入库单只看「已付 / 未付 / 开票」、对出库单只看「已收 / 未收」，
// 如果给不适用的方向也填上「单据总额」，界面一旦漏判单据类型就会显示成
// 「未收 100 元」这种凭空捏造的假数据，比留空危险得多。
func buildStatementData(statement Statement, businessUser identity.UserSummary, operators map[uint64]identity.UserSummary) *StatementData {
	var paid, unpaid, received, unreceived, invoiced, uninvoiced money.Amount
	// 开票只存在于入库单方向，出库单（以及异常类型）一律返回「不适用」，
	// 保证这个字段永远是四个合法枚举值之一，契约校验不会因为空串而失败。
	invoiceStatus := InvoiceStatusNotApplicable
	switch statement.Document.Kind {
	case document.KindInbound:
		paid, unpaid = statement.SumByKind(KindPayment), statement.Outstanding(KindPayment)
		invoiced = statement.SumByKind(KindInvoice)
		uninvoiced = statement.Outstanding(KindInvoice)
		invoiceStatus = invoiceStatusOf(invoiced, statement.Document.TotalAmount)
	case document.KindOutbound:
		received, unreceived = statement.SumByKind(KindReceipt), statement.Outstanding(KindReceipt)
	}

	records := make([]RecordData, 0, len(statement.Records))
	for _, record := range statement.Records {
		records = append(records, toRecordData(record, operators[record.CreatedBy], businessUser))
	}

	return &StatementData{
		DocumentID: statement.Document.ID, DocumentKind: statement.Document.Kind,
		DocumentNo: statement.Document.DocumentNo, PartyName: statement.Document.PartyName,
		BusinessUser: businessUser, BusinessDate: statement.Document.BusinessDate.Format(businessDateLayout),
		TotalAmount: statement.Document.TotalAmount, TotalUpper: rmb.Upper(statement.Document.TotalAmount),

		PaidAmount: paid, UnpaidAmount: unpaid,
		PaidUpper: rmb.Upper(paid), UnpaidUpper: rmb.Upper(unpaid),
		InvoicedAmount: invoiced, UninvoicedAmount: uninvoiced,
		InvoicedUpper: rmb.Upper(invoiced), UninvoicedUpper: rmb.Upper(uninvoiced),
		InvoiceStatus: invoiceStatus,

		ReceivedAmount: received, UnreceivedAmount: unreceived,
		ReceivedUpper: rmb.Upper(received), UnreceivedUpper: rmb.Upper(unreceived),

		PaymentCount: statement.CountByKind(KindPayment),
		ReceiptCount: statement.CountByKind(KindReceipt),
		InvoiceCount: statement.CountByKind(KindInvoice),
		Records:      records,
	}
}
