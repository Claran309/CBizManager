package reporting

import (
	"math/big"
	"time"

	"CBizDocsManager/backend/internal/document"
	"CBizDocsManager/backend/pkg/money"
)

/* ------------------------------------------------------------------ 枚举 */

// Scope 是总结算快照的统计维度（FR-BACK-05）。
type Scope string

const (
	// ScopeCompany 公司维度：整个业务组在统计周期内的合计。
	ScopeCompany Scope = "company"
	// ScopeBusinessUser 业务员维度：单个业务员在统计周期内的合计。
	ScopeBusinessUser Scope = "business_user"
)

// Label 返回统计维度的中文展示文案（仅用于审计摘要，界面文案仍由客户端决定）。
func (s Scope) Label() string {
	switch s {
	case ScopeCompany:
		return "公司维度"
	case ScopeBusinessUser:
		return "业务员维度"
	default:
		return string(s)
	}
}

// ParseScope 校验并解析客户端传入的统计维度。
func ParseScope(value string) (Scope, bool) {
	switch Scope(value) {
	case ScopeCompany, ScopeBusinessUser:
		return Scope(value), true
	default:
		return "", false
	}
}

/* ------------------------------------------------------------------ 实体 */

// Snapshot 是一张月度总结算快照。
//
// 它是「生成时快照」而不是实时视图：生成之后源单据再被修改或作废，都不会改变已生成的数值。
// 因此实体上没有 version 列，也不提供修改接口——要更正只能重新生成一张。
type Snapshot struct {
	ID      uint64 `gorm:"primaryKey;autoIncrement"`
	GroupID uint64 `gorm:"not null;index"`
	// SnapshotNo 单号：ZJS + YYYYMM + -4 位当月序号（如 ZJS202609-0003）。
	SnapshotNo string `gorm:"column:snapshot_no;size:32;not null"`
	// BatchNo 是一次生成动作的批次号；业务员维度会一次生成多行，共用同一个批次号。
	BatchNo string `gorm:"column:batch_no;size:32;not null"`
	Scope   Scope  `gorm:"size:16;not null"`
	// PeriodStart / PeriodEnd 是统计周期，左闭右开。
	PeriodStart time.Time `gorm:"column:period_start;type:date;not null"`
	PeriodEnd   time.Time `gorm:"column:period_end;type:date;not null"`
	// BusinessUserID 只在业务员维度有值。
	BusinessUserID *uint64 `gorm:"column:business_user_id"`
	// BusinessUserName 是生成时的姓名快照，避免用户改名或注销后历史报表失真。
	BusinessUserName *string `gorm:"column:business_user_name;size:191"`

	InboundAmount  money.Amount `gorm:"column:inbound_amount;not null"`
	OutboundAmount money.Amount `gorm:"column:outbound_amount;not null"`
	GrossProfit    money.Amount `gorm:"column:gross_profit;not null"`
	// GrossMarginPPM 毛利率，单位「百万分之一」（207500 = 20.75%）。用整数避免浮点。
	GrossMarginPPM int64 `gorm:"column:gross_margin_ppm;not null"`

	// 三类销售金额分项（FR-BACK-03）。
	VATSpecialAmount money.Amount `gorm:"column:vat_special_amount;not null"`
	VATGeneralAmount money.Amount `gorm:"column:vat_general_amount;not null"`
	NoInvoiceAmount  money.Amount `gorm:"column:no_invoice_amount;not null"`

	DocumentCount int64   `gorm:"column:document_count;not null"`
	Remark        *string `gorm:"size:500"`
	CreatedBy     uint64  `gorm:"column:created_by;not null"`
	CreatedAt     time.Time
}

func (Snapshot) TableName() string { return "report_snapshots" }

/* ------------------------------------------------------------------ 聚合 */

// SaleAmountTotals 是出库单三类销售金额的合计（FR-BACK-03）。
type SaleAmountTotals struct {
	VATSpecial money.Amount
	VATGeneral money.Amount
	NoInvoice  money.Amount
}

// AmountOf 返回指定销售金额类型的合计。
func (t SaleAmountTotals) AmountOf(saleAmountType document.SaleAmountType) money.Amount {
	switch saleAmountType {
	case document.SaleAmountVATSpecial:
		return t.VATSpecial
	case document.SaleAmountVATGeneral:
		return t.VATGeneral
	case document.SaleAmountNoInvoice:
		return t.NoInvoice
	default:
		return 0
	}
}

// Total 返回三类销售金额之和。
func (t SaleAmountTotals) Total() money.Amount {
	return t.VATSpecial.Add(t.VATGeneral).Add(t.NoInvoice)
}

// DocumentSettlement 是统计周期内一张单据的结清关系。
//
// 它在服务端内部用来推导合计，以及「未付清 / 未收清 / 未开满」的单据数——
// 后者必须逐单比较（付款合计 < 单据总额），只靠总额相减是算不出来的：
// 一张单多付、另一张单少付，总额相减的结果会正好抵消，把「有 1 张单没付清」藏起来。
type DocumentSettlement struct {
	Kind           document.Kind
	SaleAmountType *document.SaleAmountType
	TotalAmount    money.Amount
	Paid           money.Amount
	Invoiced       money.Amount
	Received       money.Amount
}

// PeriodTotals 是一个统计周期的全部汇总指标。
type PeriodTotals struct {
	InboundDocuments  int64
	InboundAmount     money.Amount
	OutboundDocuments int64
	OutboundAmount    money.Amount

	// 截至当前，本周期入库单的已付 / 已开票合计，以及出库单的已收合计。
	//
	// 这里刻意不按付款 / 收款的发生日期过滤：需求要的是「本周期单据的应付 / 应收余额」，
	// 而不是「本周期发生了多少笔付款」。若按发生日期过滤，上月已付、本月付清的单一分钱
	// 都不会计入本月已付，未付款就会被长期高估。
	Paid     money.Amount
	Invoiced money.Amount
	Received money.Amount

	// 「未结清」的单据数：逐单比较得出的结果，不是总额相减。
	UnpaidDocuments     int64
	UnreceivedDocuments int64
	UninvoicedDocuments int64

	SaleAmountTotals SaleAmountTotals

	// 涉及的不同进项公司 / 客户数量。
	SupplierCount int64
	CustomerCount int64
}

// newPeriodTotals 由逐单结清关系聚合出周期合计。
//
// 聚合放在 Go 里而不是 SQL 的 SUM(CASE WHEN ...) 里，是因为「未结清单据数」需要逐单比较，
// 写进 SQL 会变成多层子查询 + HAVING，既难读又容易在 MySQL / SQLite 之间出现方言差异；
// 一个月的单据量在百级别，逐单取回来在内存里聚合完全够用。
func newPeriodTotals(rows []DocumentSettlement) PeriodTotals {
	var result PeriodTotals
	for _, row := range rows {
		switch row.Kind {
		case document.KindInbound:
			result.InboundDocuments++
			result.InboundAmount = result.InboundAmount.Add(row.TotalAmount)
			result.Paid = result.Paid.Add(row.Paid)
			result.Invoiced = result.Invoiced.Add(row.Invoiced)
			if row.Paid < row.TotalAmount {
				result.UnpaidDocuments++
			}
			if row.Invoiced < row.TotalAmount {
				result.UninvoicedDocuments++
			}
		case document.KindOutbound:
			result.OutboundDocuments++
			result.OutboundAmount = result.OutboundAmount.Add(row.TotalAmount)
			result.Received = result.Received.Add(row.Received)
			if row.Received < row.TotalAmount {
				result.UnreceivedDocuments++
			}
			if row.SaleAmountType != nil {
				switch *row.SaleAmountType {
				case document.SaleAmountVATSpecial:
					result.SaleAmountTotals.VATSpecial = result.SaleAmountTotals.VATSpecial.Add(row.TotalAmount)
				case document.SaleAmountVATGeneral:
					result.SaleAmountTotals.VATGeneral = result.SaleAmountTotals.VATGeneral.Add(row.TotalAmount)
				case document.SaleAmountNoInvoice:
					result.SaleAmountTotals.NoInvoice = result.SaleAmountTotals.NoInvoice.Add(row.TotalAmount)
				}
			}
		}
	}
	return result
}

// GrossProfit 返回毛利润（出库销售合计 − 入库进项合计），允许为负。
func (t PeriodTotals) GrossProfit() money.Amount { return t.OutboundAmount.Sub(t.InboundAmount) }

// GrossMarginPPM 返回毛利率（毛利润 / 出库销售合计），单位百万分之一。
func (t PeriodTotals) GrossMarginPPM() int64 {
	return ppmRatio(t.GrossProfit(), t.OutboundAmount)
}

// Unpaid 返回未付款合计（入库合计 − 已付合计），不会为负。
func (t PeriodTotals) Unpaid() money.Amount { return nonNegative(t.InboundAmount.Sub(t.Paid)) }

// Uninvoiced 返回未开票合计（入库合计 − 已开票合计），不会为负。
func (t PeriodTotals) Uninvoiced() money.Amount { return nonNegative(t.InboundAmount.Sub(t.Invoiced)) }

// Unreceived 返回未收款合计（出库合计 − 已收合计），不会为负。
func (t PeriodTotals) Unreceived() money.Amount { return nonNegative(t.OutboundAmount.Sub(t.Received)) }

// BusinessUserTotals 是单个业务员在一个周期内的利润统计（FR-BACK-05）。
type BusinessUserTotals struct {
	BusinessUserID uint64
	InboundAmount  money.Amount
	OutboundAmount money.Amount
	DocumentCount  int64
	// SaleAmountTotals 是该业务员出库单的三类销售金额合计；
	// 业务员维度总结算快照需要它，因此与利润统计一次查出来，避免生成快照时再回查一遍。
	SaleAmountTotals SaleAmountTotals
}

// GrossProfit 返回该业务员的毛利润（出库 − 入库）。
func (t BusinessUserTotals) GrossProfit() money.Amount { return t.OutboundAmount.Sub(t.InboundAmount) }

// ItemTotals 是按「往来单位 + 品名 + 型号 + 单位」聚合出的明细行。
//
// 分组里必须带 unit：SUM(quantity) 只有在单位一致时才有意义，
// 把「吨」和「支」加在一起会得出一个看起来有值、实际上无意义的数字。
type ItemTotals struct {
	PartyName     string
	ProductName   string
	ProductModel  *string
	Unit          *string
	DocumentCount int64
	Quantity      money.Quantity
	Amount        money.Amount
}

// ItemPage 是明细聚合的分页结果。
type ItemPage struct {
	Items    []ItemTotals
	Page     int
	PageSize int
	Total    int64
}

// SnapshotPage 是总结算快照的分页结果。
type SnapshotPage struct {
	Items    []Snapshot
	Page     int
	PageSize int
	Total    int64
}

/* ------------------------------------------------------------------ 输入 */

// AggregateQuery 是汇总类查询的仓储条件。
type AggregateQuery struct {
	PeriodStart time.Time
	PeriodEnd   time.Time
	// BusinessUserID 非零时只统计该业务员的单据（FR-BACK-01「按业务员视图」）。
	BusinessUserID uint64
}

// ItemQuery 是明细聚合查询的仓储条件。
type ItemQuery struct {
	AggregateQuery
	PartyKeyword   string
	ProductKeyword string
	ModelKeyword   string
	Page           int
	PageSize       int
}

// SnapshotQuery 是总结算快照列表的仓储条件。
type SnapshotQuery struct {
	PeriodStart    *time.Time
	PeriodEnd      *time.Time
	Scope          *Scope
	BusinessUserID *uint64
	Page           int
	PageSize       int
}

// SnapshotCandidate 是待写入的一张总结算快照内容（单号由仓储在事务内生成）。
type SnapshotCandidate struct {
	Scope            Scope
	BusinessUserID   *uint64
	BusinessUserName *string

	InboundAmount  money.Amount
	OutboundAmount money.Amount
	GrossProfit    money.Amount
	GrossMarginPPM int64

	VATSpecialAmount money.Amount
	VATGeneralAmount money.Amount
	NoInvoiceAmount  money.Amount

	DocumentCount int64
	Remark        *string
}

// CreateSnapshotInput 是生成总结算快照的仓储入参。
//
// 这里既没有 BatchNo 也没有 AuditSummary：单号由仓储在事务内生成，批次号与审计摘要
// 都依赖「最终拿到的那串单号」，交给仓储统一拼装才能保证各入口文案一致
// （与单据 / 结算模块「摘要由仓储在拿到单号后统一拼装」的口径相同）。
type CreateSnapshotInput struct {
	GroupID     uint64
	PeriodStart time.Time
	PeriodEnd   time.Time
	// Candidates 是本次要写入的全部快照；同一次生成共享同一个批次号。
	Candidates     []SnapshotCandidate
	OperatorUserID uint64
	Now            time.Time
}

/* ------------------------------------------------------------------ 数值工具 */

// ppmRatio 计算 numerator / denominator 的百万分之一比值（四舍五入到整数）。
//
// 用 big.Int 而不是浮点：钢材单价与数量的乘积很容易接近 int64 上限，
// 先乘 1_000_000 再除必须用大整数兜底才不会静默溢出。
func ppmRatio(numerator, denominator money.Amount) int64 {
	if denominator == 0 {
		return 0
	}
	scaled := new(big.Int).Mul(big.NewInt(int64(numerator)), big.NewInt(1_000_000))
	divisor := big.NewInt(int64(denominator))
	quotient, remainder := new(big.Int), new(big.Int)
	quotient.QuoRem(scaled, divisor, remainder)

	// 四舍五入：|余数| * 2 >= |除数| 时向绝对值更大的方向进位（负数也按远离零处理）。
	doubled := new(big.Int).Abs(remainder)
	doubled.Lsh(doubled, 1)
	if doubled.Cmp(new(big.Int).Abs(divisor)) >= 0 {
		if quotient.Sign() < 0 {
			quotient.Sub(quotient, big.NewInt(1))
		} else {
			quotient.Add(quotient, big.NewInt(1))
		}
	}
	if !quotient.IsInt64() {
		return 0
	}
	return quotient.Int64()
}

// nonNegative 把负值收敛为 0。
//
// 累计金额不会超过单据总额（财务模块在事务内锁单据行校验），所以理论上不会出现负数；
// 但历史数据、并发修复或人工改库都可能留下超额记录，汇总层宁可显示 0 也不要显示
// 「未付款 −1000 元」这种会让财务误判的负数。
func nonNegative(amount money.Amount) money.Amount {
	if amount < 0 {
		return 0
	}
	return amount
}
