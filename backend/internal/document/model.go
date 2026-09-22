package document

import (
	"fmt"
	"time"

	"CBizDocsManager/backend/pkg/money"
)

// Kind 区分入库单与出库单。两种单据共享同一套表结构，由 kind 判别列承载。
type Kind string

const (
	KindInbound  Kind = "inbound"
	KindOutbound Kind = "outbound"
)

// ParseKind 校验并解析客户端传入的单据类型。
func ParseKind(value string) (Kind, error) {
	switch Kind(value) {
	case KindInbound:
		return KindInbound, nil
	case KindOutbound:
		return KindOutbound, nil
	default:
		return "", fmt.Errorf("未知单据类型 %q", value)
	}
}

// NumberPrefix 返回单号前缀（入库 RK、出库 CK）。
func (k Kind) NumberPrefix() string {
	if k == KindOutbound {
		return "CK"
	}
	return "RK"
}

// IsInbound 判断是否为入库单。
func (k Kind) IsInbound() bool { return k == KindInbound }

// Status 是单据业务状态。一期只保留草稿、已提交、已作废三态，
// 结算审批状态由结算单自身承载，避免单据状态机被审批流程污染。
type Status string

const (
	StatusDraft     Status = "draft"
	StatusSubmitted Status = "submitted"
	StatusVoided    Status = "voided"
)

// PriceTaxMode 是明细的单价类型（含税价 / 不含税价）。
// 一期仅用于业务记录与展示，不改变「金额 = 单价 × 数量」的计算公式。
type PriceTaxMode string

const (
	PriceTaxIncluded PriceTaxMode = "tax_included"
	PriceTaxExcluded PriceTaxMode = "tax_excluded"
)

// SaleAmountType 是出库单的销售金额类型，稳定代码值保持不变，界面再翻译成中文。
type SaleAmountType string

const (
	// SaleAmountVATSpecial 增值税专用发票销售金额。
	SaleAmountVATSpecial SaleAmountType = "Y-1"
	// SaleAmountVATGeneral 增值税普通发票销售金额。
	SaleAmountVATGeneral SaleAmountType = "y-N"
	// SaleAmountNoInvoice 不开票销售金额。
	SaleAmountNoInvoice SaleAmountType = "N"
)

// Document 是单据主表实体。
type Document struct {
	ID             uint64          `gorm:"primaryKey;autoIncrement"`
	GroupID        uint64          `gorm:"not null;index"`
	Kind           Kind            `gorm:"size:16;not null"`
	DocumentNo     string          `gorm:"size:32;not null"`
	Status         Status          `gorm:"size:16;not null"`
	BusinessUserID uint64          `gorm:"not null"`
	BusinessDate   time.Time       `gorm:"type:date;not null"`
	ShippingUnit   *string         `gorm:"size:191"`
	SaleAmountType *SaleAmountType `gorm:"size:8"`
	TotalAmount    money.Amount    `gorm:"not null"`
	Remark         *string         `gorm:"size:500"`
	Version        uint64          `gorm:"not null;default:1"`
	SubmittedAt    *time.Time
	CreatedBy      uint64 `gorm:"not null"`
	UpdatedBy      uint64 `gorm:"not null"`
	CreatedAt      time.Time
	UpdatedAt      time.Time
}

func (Document) TableName() string { return "documents" }

// Party 是往来单位分组：入库场景是进项公司，出库场景是客户（含联系电话）。
type Party struct {
	ID                uint64       `gorm:"primaryKey;autoIncrement"`
	GroupID           uint64       `gorm:"not null;index"`
	DocumentID        uint64       `gorm:"not null"`
	Position          int          `gorm:"not null"`
	PartyName         string       `gorm:"size:191;not null"`
	ContactPhone      *string      `gorm:"size:50"`
	DictionaryEntryID *uint64      `gorm:"column:dictionary_entry_id"`
	Subtotal          money.Amount `gorm:"not null"`
	CreatedAt         time.Time
	UpdatedAt         time.Time
}

func (Party) TableName() string { return "document_parties" }

// Item 是商品明细，序号在所属往来单位内从 1 连续递增。
type Item struct {
	ID           uint64          `gorm:"primaryKey;autoIncrement"`
	GroupID      uint64          `gorm:"not null;index"`
	DocumentID   uint64          `gorm:"not null"`
	PartyID      uint64          `gorm:"not null"`
	Position     int             `gorm:"not null"`
	ProductName  string          `gorm:"size:191;not null"`
	ProductModel *string         `gorm:"size:191"`
	Unit         *string         `gorm:"size:32"`
	Quantity     money.Quantity  `gorm:"not null"`
	Weight       *money.Quantity `gorm:"column:weight"`
	UnitPrice    money.Price     `gorm:"not null"`
	PriceTaxMode PriceTaxMode    `gorm:"size:16;not null"`
	Amount       money.Amount    `gorm:"not null"`
	Remark       *string         `gorm:"size:500"`
	CreatedAt    time.Time
	UpdatedAt    time.Time
}

func (Item) TableName() string { return "document_items" }

// Page 是单据列表分页结果。
type Page struct {
	Items    []DocumentSummary
	Page     int
	PageSize int
	Total    int64
}

// DocumentSummary 是列表行所需的单据摘要（含往来单位与明细条数，避免客户端二次请求）。
type DocumentSummary struct {
	Document       Document
	PartyNames     []string
	ItemCount      int
	BusinessName   string
	BusinessUserID uint64
}

// Detail 是单据详情聚合：主表 + 往来单位 + 明细。
type Detail struct {
	Document Document
	Parties  []PartyWithItems
}

// PartyWithItems 是往来单位与其明细的组合。
type PartyWithItems struct {
	Party
	Items []Item
}

// PartyTotals 是月度汇总中按往来单位聚合的结果。
type PartyTotals struct {
	PartyName     string
	DocumentCount int64
	TotalAmount   money.Amount
}

// MonthlyTotals 是月度汇总结果。
type MonthlyTotals struct {
	DocumentCount int64
	DraftCount    int64
	SubmittedCnt  int64
	VoidedCount   int64
	TotalAmount   money.Amount
	Parties       []PartyTotals
}

// PartyDraft 是写入用的往来单位草稿。
type PartyDraft struct {
	Position          int
	PartyName         string
	ContactPhone      *string
	DictionaryEntryID *uint64
	Subtotal          money.Amount
	Items             []ItemDraft
}

// ItemDraft 是写入用的明细草稿，Amount 已由服务层算好。
type ItemDraft struct {
	Position     int
	ProductName  string
	ProductModel *string
	Unit         *string
	Quantity     money.Quantity
	Weight       *money.Quantity
	UnitPrice    money.Price
	PriceTaxMode PriceTaxMode
	Amount       money.Amount
	Remark       *string
}

// CreateInput 是创建单据的仓储入参。
type CreateInput struct {
	GroupID            uint64
	Kind               Kind
	Status             Status
	BusinessUserID     uint64
	BusinessDate       time.Time
	ShippingUnit       *string
	SaleAmountType     *SaleAmountType
	TotalAmount        money.Amount
	Remark             *string
	OperatorUserID     uint64
	Parties            []PartyDraft
	IdempotencyScope   string
	IdempotencyKey     string
	RequestFingerprint string
	Now                time.Time
	AuditAction        string
	AuditSummary       string
}

// UpdateInput 是整体替换单据内容的仓储入参。
type UpdateInput struct {
	GroupID            uint64
	Kind               Kind
	DocumentID         uint64
	ExpectedVersion    uint64
	Status             Status
	BusinessUserID     uint64
	BusinessDate       time.Time
	ShippingUnit       *string
	SaleAmountType     *SaleAmountType
	TotalAmount        money.Amount
	Remark             *string
	OperatorUserID     uint64
	Parties            []PartyDraft
	IdempotencyScope   string
	IdempotencyKey     string
	RequestFingerprint string
	Now                time.Time
	AuditSummary       string
}

// StatusInput 是状态变更（提交 / 作废）的仓储入参。
type StatusInput struct {
	GroupID         uint64
	Kind            Kind
	DocumentID      uint64
	OperatorUserID  uint64
	ExpectedVersion uint64
	Status          Status
	Now             time.Time
	AuditAction     string
	AuditSummary    string
}

// SummaryQuery 是月度汇总的查询条件。
type SummaryQuery struct {
	Month      time.Time
	BucketSize int
	// OnlyBusinessUserID 非零时只统计该业务员的单据（普通子账号的默认数据范围）。
	OnlyBusinessUserID uint64
}
