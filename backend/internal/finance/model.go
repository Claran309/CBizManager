package finance

import (
	"time"

	"CBizDocsManager/backend/internal/document"
	"CBizDocsManager/backend/internal/identity"
	"CBizDocsManager/backend/pkg/money"
)

/* ------------------------------------------------------------------ 枚举 */

// Kind 是财务记录类型。
//
// 三类记录共用 finance_records 一张表与一套仓储实现，差异只在「挂在哪种单据上、
// 需要哪些额外字段、以及最终怎么汇总」，因此在类型层面就固定下来：
//   - payment（付款）只挂入库单，单据维度看「已付 / 未付」；
//   - receipt（收款）只挂出库单，单据维度看「已收 / 未收」；
//   - invoice（开票）只挂入库单，单据维度看「已开票 / 未开票」。
type Kind string

const (
	// KindPayment 付款记录（进项付款）。
	KindPayment Kind = "payment"
	// KindReceipt 收款记录（销项收款）。
	KindReceipt Kind = "receipt"
	// KindInvoice 开票记录（进项取得发票）。
	KindInvoice Kind = "invoice"
)

// Label 返回记录类型的中文展示文案（仅用于审计摘要，界面文案仍由客户端决定）。
func (k Kind) Label() string {
	switch k {
	case KindPayment:
		return "付款"
	case KindReceipt:
		return "收款"
	case KindInvoice:
		return "开票"
	default:
		return string(k)
	}
}

// ParseKind 校验并解析客户端传入的记录类型。
func ParseKind(value string) (Kind, bool) {
	switch Kind(value) {
	case KindPayment, KindReceipt, KindInvoice:
		return Kind(value), true
	default:
		return "", false
	}
}

// DocumentKind 返回该记录类型只能挂载的单据类型。
//
// 这条约束是服务层的第一道校验，同时用于「登记时单据类型不匹配」的友好报错。
func (k Kind) DocumentKind() document.Kind {
	if k == KindReceipt {
		return document.KindOutbound
	}
	return document.KindInbound
}

// CarriesMethod 表示该记录类型是否携带付款 / 收款方式。
// 开票没有「方式」概念，请求里带了就必须报错，而不是被静默忽略。
func (k Kind) CarriesMethod() bool { return k == KindPayment || k == KindReceipt }

// CarriesInvoiceNo 表示该记录类型是否携带发票号。
func (k Kind) CarriesInvoiceNo() bool { return k == KindInvoice }

// Method 是付款 / 收款方式（FR-OUT-06）。
type Method string

const (
	// MethodTransfer 转账，可备注微信 / 支付宝。
	MethodTransfer Method = "transfer"
	// MethodPrivateCard 对私卡，记录卡号后 4 位。
	MethodPrivateCard Method = "private_card"
	// MethodPublicAccount 对公账户。
	MethodPublicAccount Method = "public_account"
)

// Label 返回方式的中文展示文案。
func (m Method) Label() string {
	switch m {
	case MethodTransfer:
		return "转账"
	case MethodPrivateCard:
		return "对私卡"
	case MethodPublicAccount:
		return "对公账户"
	default:
		return string(m)
	}
}

// ParseMethod 校验并解析客户端传入的付款 / 收款方式。
func ParseMethod(value string) (Method, bool) {
	switch Method(value) {
	case MethodTransfer, MethodPrivateCard, MethodPublicAccount:
		return Method(value), true
	default:
		return "", false
	}
}

// InvoiceStatus 是单据维度的开票状态（FR-BACK-02「查询开票状态」）。
//
// 它不落库，而是由「已开票金额合计」与「单据总金额」在服务端推导，
// 避免出现「状态列说已开票、明细金额却没开满」这类自相矛盾的数据。
type InvoiceStatus string

const (
	// InvoiceStatusNone 未开票。
	InvoiceStatusNone InvoiceStatus = "none"
	// InvoiceStatusPartial 部分开票。
	InvoiceStatusPartial InvoiceStatus = "partial"
	// InvoiceStatusFull 已开票。
	InvoiceStatusFull InvoiceStatus = "full"
	// InvoiceStatusNotApplicable 表示该单据方向不存在开票概念。
	//
	// 开票只挂入库单，所以出库单的结清视图会返回这个值而不是 "none"：
	// 出库单永远不可能开票，回 "none" 会让客户端显示「未开票」这种误导性文案。
	InvoiceStatusNotApplicable InvoiceStatus = "not_applicable"
)

// invoiceStatusOf 由已开票金额与单据总额推导开票状态。
func invoiceStatusOf(invoiced, total money.Amount) InvoiceStatus {
	switch {
	case invoiced.IsZero():
		return InvoiceStatusNone
	case invoiced < total:
		return InvoiceStatusPartial
	default:
		return InvoiceStatusFull
	}
}

/* ------------------------------------------------------------------ 实体 */

// Record 是一条付款 / 收款 / 开票记录。
//
// Part/业务员/业务日期等列是记录生成时的单据快照：财务记录脱离单据也能独立说明
// 「当时依据了什么」，列表页也不需要 join 单据表。
type Record struct {
	ID             uint64        `gorm:"primaryKey;autoIncrement"`
	GroupID        uint64        `gorm:"not null;index"`
	DocumentID     uint64        `gorm:"not null"`
	DocumentKind   document.Kind `gorm:"size:16;not null"`
	DocumentNo     string        `gorm:"size:32;not null"`
	PartyName      string        `gorm:"size:191;not null"`
	BusinessUserID uint64        `gorm:"not null"`
	BusinessDate   time.Time     `gorm:"type:date;not null"`
	Kind           Kind          `gorm:"size:16;not null"`
	Amount         money.Amount  `gorm:"not null"`
	OccurredOn     time.Time     `gorm:"type:date;not null"`
	Method         *Method       `gorm:"size:16"`
	MethodNote     *string       `gorm:"size:100"`
	CardTail       *string       `gorm:"size:4"`
	InvoiceNo      *string       `gorm:"size:64"`
	Remark         *string       `gorm:"size:500"`
	CreatedBy      uint64        `gorm:"not null"`
	CreatedAt      time.Time
}

func (Record) TableName() string { return "finance_records" }

/* ------------------------------------------------------------------ 聚合 */

// TargetDocument 是登记财务记录时读到的目标单据状态。
//
// 只带财务用得上的字段（而不是整套 document.Detail），让「财务只关心金额与状态」
// 这件事在类型上就看得见。
type TargetDocument struct {
	ID             uint64
	Kind           document.Kind
	DocumentNo     string
	Status         document.Status
	BusinessUserID uint64
	BusinessDate   time.Time
	PartyName      string
	TotalAmount    money.Amount
}

// Statement 是单张单据的结清情况：单据本体 + 全部财务记录。
//
// 「已付 / 未付 / 已收 / 未收 / 已开票 / 开票状态」全部由这里按金额推导，
// 不落冗余状态列。
type Statement struct {
	Document TargetDocument
	Records  []Record
}

// SumByKind 返回某一类记录的金额合计。
func (s Statement) SumByKind(kind Kind) money.Amount {
	var total money.Amount
	for _, record := range s.Records {
		if record.Kind == kind {
			total = total.Add(record.Amount)
		}
	}
	return total
}

// CountByKind 返回某一类记录的条数。
func (s Statement) CountByKind(kind Kind) int {
	count := 0
	for _, record := range s.Records {
		if record.Kind == kind {
			count++
		}
	}
	return count
}

// Outstanding 返回「总额 − 已登记合计」，即未付 / 未收 / 未开票金额。
// 累计不会超过总额（服务层与仓储双重校验），因此结果不会为负。
func (s Statement) Outstanding(kind Kind) money.Amount {
	remaining := s.Document.TotalAmount.Sub(s.SumByKind(kind))
	if remaining < 0 {
		return 0
	}
	return remaining
}

// Page 是财务记录列表分页结果。
type Page struct {
	Items    []Summary
	Page     int
	PageSize int
	Total    int64
}

// Summary 是列表行所需的记录摘要，附带登记人姓名。
type Summary struct {
	Record       Record
	CreatedBy    identity.UserSummary
	BusinessUser identity.UserSummary
}

/* ------------------------------------------------------------------ 输入 */

// CreateInput 是登记财务记录的仓储入参。
type CreateInput struct {
	GroupID        uint64
	DocumentID     uint64
	DocumentKind   document.Kind
	DocumentNo     string
	PartyName      string
	BusinessUserID uint64
	BusinessDate   time.Time
	Kind           Kind
	Amount         money.Amount
	OccurredOn     time.Time
	Method         *Method
	MethodNote     *string
	CardTail       *string
	InvoiceNo      *string
	Remark         *string
	OperatorUserID uint64
	Now            time.Time

	IdempotencyScope   string
	IdempotencyKey     string
	RequestFingerprint string
	AuditAction        string
	AuditSummary       string
}

// RevokeInput 是撤销财务记录的仓储入参。
type RevokeInput struct {
	GroupID        uint64
	RecordID       uint64
	OperatorUserID uint64
	Now            time.Time
	AuditAction    string
	AuditSummary   string
}

// RepositoryQuery 是归一化后的仓储查询条件。
type RepositoryQuery struct {
	Kind               Kind
	DocumentID         uint64
	Keyword            string
	Method             *Method
	OccurredFrom       *time.Time
	OccurredTo         *time.Time
	BusinessUserID     *uint64
	OnlyBusinessUserID uint64
	Page               int
	PageSize           int
}
