package document

import (
	"time"

	"CBizDocsManager/backend/internal/identity"
	"CBizDocsManager/backend/pkg/money"
	"CBizDocsManager/backend/pkg/rmb"
)

/* ------------------------------------------------------------------ 请求 */

// ListQuery 是单据列表查询条件。
type ListQuery struct {
	Keyword        string `form:"keyword"`
	Status         Status `form:"status"`
	BusinessUserID uint64 `form:"business_user_id"`
	Month          string `form:"month"`
	DateFrom       string `form:"date_from"`
	DateTo         string `form:"date_to"`
	Page           int    `form:"page"`
	PageSize       int    `form:"page_size"`
}

// RepositoryQuery 是归一化后的仓储查询条件，保证 Handler 与 Service 使用同一套默认值。
type RepositoryQuery struct {
	Keyword            string
	Status             *Status
	MonthStart         *time.Time
	MonthEnd           *time.Time
	BusinessUserID     *uint64
	OnlyBusinessUserID uint64
	Page               int
	PageSize           int
}

// ItemRequest 是明细写入请求。
type ItemRequest struct {
	ProductName  string          `json:"product_name"`
	ProductModel *string         `json:"product_model"`
	Unit         *string         `json:"unit"`
	Quantity     money.Quantity  `json:"quantity"`
	Weight       *money.Quantity `json:"weight"`
	UnitPrice    money.Price     `json:"unit_price"`
	PriceTaxMode PriceTaxMode    `json:"price_tax_mode"`
	Remark       *string         `json:"remark"`
}

// PartyRequest 是往来单位写入请求（入库=进项公司，出库=客户）。
type PartyRequest struct {
	PartyName         string        `json:"party_name"`
	ContactPhone      *string       `json:"contact_phone"`
	DictionaryEntryID *uint64       `json:"dictionary_entry_id"`
	Items             []ItemRequest `json:"items"`
}

// CreateRequest 是创建单据请求。
type CreateRequest struct {
	Status         Status          `json:"status"`
	BusinessDate   string          `json:"business_date"`
	BusinessUserID *uint64         `json:"business_user_id"`
	ShippingUnit   *string         `json:"shipping_unit"`
	SaleAmountType *SaleAmountType `json:"sale_amount_type"`
	Remark         *string         `json:"remark"`
	Parties        []PartyRequest  `json:"parties"`
}

// UpdateRequest 是整体替换单据内容的请求，携带乐观锁版本号。
type UpdateRequest struct {
	Version        uint64          `json:"version"`
	Status         Status          `json:"status"`
	BusinessDate   string          `json:"business_date"`
	BusinessUserID *uint64         `json:"business_user_id"`
	ShippingUnit   *string         `json:"shipping_unit"`
	SaleAmountType *SaleAmountType `json:"sale_amount_type"`
	Remark         *string         `json:"remark"`
	Parties        []PartyRequest  `json:"parties"`
}

// VersionRequest 用于提交、作废等只依赖版本号的动作。
type VersionRequest struct {
	Version uint64 `json:"version"`
}

/* ------------------------------------------------------------------ 响应 */

// ItemData 是明细响应。
type ItemData struct {
	ItemID       uint64          `json:"item_id"`
	Position     int             `json:"position"`
	ProductName  string          `json:"product_name"`
	ProductModel *string         `json:"product_model"`
	Unit         *string         `json:"unit"`
	Quantity     money.Quantity  `json:"quantity"`
	Weight       *money.Quantity `json:"weight"`
	UnitPrice    money.Price     `json:"unit_price"`
	PriceTaxMode PriceTaxMode    `json:"price_tax_mode"`
	Amount       money.Amount    `json:"amount"`
	Remark       *string         `json:"remark"`
}

// PartyData 是往来单位响应，附带小计金额。
type PartyData struct {
	PartyID      uint64       `json:"party_id"`
	Position     int          `json:"position"`
	PartyName    string       `json:"party_name"`
	ContactPhone *string      `json:"contact_phone"`
	Subtotal     money.Amount `json:"subtotal"`
	Items        []ItemData   `json:"items"`
}

// DocumentData 是单据详情响应。
type DocumentData struct {
	DocumentID       uint64               `json:"document_id"`
	Kind             Kind                 `json:"kind"`
	DocumentNo       string               `json:"document_no"`
	Status           Status               `json:"status"`
	BusinessUser     identity.UserSummary `json:"business_user"`
	BusinessDate     string               `json:"business_date"`
	ShippingUnit     *string              `json:"shipping_unit"`
	SaleAmountType   *SaleAmountType      `json:"sale_amount_type"`
	TotalAmount      money.Amount         `json:"total_amount"`
	TotalAmountUpper string               `json:"total_amount_upper"`
	Remark           *string              `json:"remark"`
	Version          uint64               `json:"version"`
	SubmittedAt      *time.Time           `json:"submitted_at"`
	CreatedAt        time.Time            `json:"created_at"`
	UpdatedAt        time.Time            `json:"updated_at"`
	Parties          []PartyData          `json:"parties"`
}

// DocumentSummaryData 是单据列表行响应。
type DocumentSummaryData struct {
	DocumentID     uint64               `json:"document_id"`
	Kind           Kind                 `json:"kind"`
	DocumentNo     string               `json:"document_no"`
	Status         Status               `json:"status"`
	BusinessDate   string               `json:"business_date"`
	BusinessUser   identity.UserSummary `json:"business_user"`
	ShippingUnit   *string              `json:"shipping_unit"`
	SaleAmountType *SaleAmountType      `json:"sale_amount_type"`
	PartyNames     []string             `json:"party_names"`
	ItemCount      int                  `json:"item_count"`
	TotalAmount    money.Amount         `json:"total_amount"`
	Version        uint64               `json:"version"`
	SubmittedAt    *time.Time           `json:"submitted_at"`
	CreatedAt      time.Time            `json:"created_at"`
	UpdatedAt      time.Time            `json:"updated_at"`
}

// DocumentPageData 是单据分页响应。
type DocumentPageData struct {
	Items    []DocumentSummaryData `json:"items"`
	Page     int                   `json:"page"`
	PageSize int                   `json:"page_size"`
	Total    int64                 `json:"total"`
}

// PartyTotalsData 是月度汇总中按往来单位的聚合行。
type PartyTotalsData struct {
	PartyName     string       `json:"party_name"`
	DocumentCount int64        `json:"document_count"`
	TotalAmount   money.Amount `json:"total_amount"`
}

// MonthlySummaryData 是月度汇总响应。
type MonthlySummaryData struct {
	Month            string            `json:"month"`
	Kind             Kind              `json:"kind"`
	DocumentCount    int64             `json:"document_count"`
	DraftCount       int64             `json:"draft_count"`
	SubmittedCount   int64             `json:"submitted_count"`
	VoidedCount      int64             `json:"voided_count"`
	TotalAmount      money.Amount      `json:"total_amount"`
	TotalAmountUpper string            `json:"total_amount_upper"`
	Parties          []PartyTotalsData `json:"parties"`
}

/* ------------------------------------------------------------------ 转换 */

const businessDateLayout = "2006-01-02"

func toDocumentData(detail Detail, businessUser identity.UserSummary) *DocumentData {
	parties := make([]PartyData, 0, len(detail.Parties))
	for _, party := range detail.Parties {
		items := make([]ItemData, 0, len(party.Items))
		for _, item := range party.Items {
			items = append(items, ItemData{
				ItemID: item.ID, Position: item.Position, ProductName: item.ProductName,
				ProductModel: item.ProductModel, Unit: item.Unit, Quantity: item.Quantity,
				Weight: item.Weight, UnitPrice: item.UnitPrice, PriceTaxMode: item.PriceTaxMode,
				Amount: item.Amount, Remark: item.Remark,
			})
		}
		parties = append(parties, PartyData{
			PartyID: party.ID, Position: party.Position, PartyName: party.PartyName,
			ContactPhone: party.ContactPhone, Subtotal: party.Subtotal, Items: items,
		})
	}
	return &DocumentData{
		DocumentID: detail.Document.ID, Kind: detail.Document.Kind, DocumentNo: detail.Document.DocumentNo,
		Status: detail.Document.Status, BusinessUser: businessUser,
		BusinessDate: detail.Document.BusinessDate.Format(businessDateLayout),
		ShippingUnit: detail.Document.ShippingUnit, SaleAmountType: detail.Document.SaleAmountType,
		TotalAmount: detail.Document.TotalAmount, TotalAmountUpper: rmb.Upper(detail.Document.TotalAmount),
		Remark: detail.Document.Remark, Version: detail.Document.Version, SubmittedAt: detail.Document.SubmittedAt,
		CreatedAt: detail.Document.CreatedAt, UpdatedAt: detail.Document.UpdatedAt, Parties: parties,
	}
}

func toSummaryData(summary DocumentSummary) DocumentSummaryData {
	names := summary.PartyNames
	if names == nil {
		names = []string{}
	}
	return DocumentSummaryData{
		DocumentID: summary.Document.ID, Kind: summary.Document.Kind, DocumentNo: summary.Document.DocumentNo,
		Status: summary.Document.Status, BusinessDate: summary.Document.BusinessDate.Format(businessDateLayout),
		BusinessUser: identity.UserSummary{ID: summary.BusinessUserID, DisplayName: summary.BusinessName},
		ShippingUnit: summary.Document.ShippingUnit, SaleAmountType: summary.Document.SaleAmountType,
		PartyNames: names, ItemCount: summary.ItemCount, TotalAmount: summary.Document.TotalAmount,
		Version: summary.Document.Version, SubmittedAt: summary.Document.SubmittedAt,
		CreatedAt: summary.Document.CreatedAt, UpdatedAt: summary.Document.UpdatedAt,
	}
}
