package reporting

import (
	"fmt"
	"time"

	"CBizDocsManager/backend/internal/document"
	"CBizDocsManager/backend/internal/identity"
	"CBizDocsManager/backend/pkg/money"
	"CBizDocsManager/backend/pkg/rmb"
)

const dateLayout = "2006-01-02"

/* ------------------------------------------------------------------ 请求 */

// PeriodQuery 是看板与统计类查询的公共参数（FR-BACK-01「按年份、月份和业务员筛选」）。
//
// 一期只开放「年 + 月」的月份粒度（period=2026-09），不单独提供年份粒度：
// 需求里的「按年份筛选」在界面上就是「月份选全部」，聚合粒度仍然是月，
// 多一个 year 参数只会让「既传 year 又传 month」这种组合产生歧义。
type PeriodQuery struct {
	Period         string `form:"period"`
	BusinessUserID uint64 `form:"business_user_id"`
}

// ItemStatsQuery 是入库 / 出库统计的查询参数（FR-BACK-02 / FR-BACK-03 的字段查询）。
type ItemStatsQuery struct {
	Period         string `form:"period"`
	BusinessUserID uint64 `form:"business_user_id"`
	PartyName      string `form:"party_name"`
	ProductName    string `form:"product_name"`
	ProductModel   string `form:"product_model"`
	Page           int    `form:"page"`
	PageSize       int    `form:"page_size"`
}

// BusinessUserQuery 是业务员维度利润统计的查询参数。
type BusinessUserQuery struct {
	Period string `form:"period"`
}

// SnapshotListQuery 是总结算快照列表的查询参数。
type SnapshotListQuery struct {
	Period         string `form:"period"`
	Scope          Scope  `form:"scope"`
	BusinessUserID uint64 `form:"business_user_id"`
	Page           int    `form:"page"`
	PageSize       int    `form:"page_size"`
}

// CreateSnapshotRequest 是生成月度总结算的请求体。
//
// scope = company 生成 1 张公司维度快照；
// scope = business_user 且不带 business_user_id 时，为该周期内所有有单据的业务员各生成 1 张；
// scope = business_user 且带 business_user_id 时，只生成指定业务员那一张。
type CreateSnapshotRequest struct {
	Period         string  `json:"period"`
	Scope          string  `json:"scope"`
	BusinessUserID uint64  `json:"business_user_id"`
	Remark         *string `json:"remark"`
}

/* ------------------------------------------------------------------ 响应 */

// SaleAmountTotalData 是一类销售金额的分项统计（FR-BACK-03）。
type SaleAmountTotalData struct {
	SaleAmountType document.SaleAmountType `json:"sale_amount_type"`
	Amount         money.Amount            `json:"amount"`
	AmountUpper    string                  `json:"amount_upper"`
	// SharePPM 是该类金额占出库合计的百万分之一占比。
	SharePPM int64 `json:"share_ppm"`
	// SharePercent 是占比的展示文本（两位小数，如 "65.20"），三端共用同一口径。
	SharePercent string `json:"share_percent"`
}

// OverviewData 是后台数据汇总看板（FR-BACK-01 数据汇总 + FR-BACK-02/03 的合计指标）。
type OverviewData struct {
	Period string `json:"period"`

	InboundDocumentCount int64        `json:"inbound_document_count"`
	InboundAmount        money.Amount `json:"inbound_amount"`
	InboundAmountUpper   string       `json:"inbound_amount_upper"`

	OutboundDocumentCount int64        `json:"outbound_document_count"`
	OutboundAmount        money.Amount `json:"outbound_amount"`
	OutboundAmountUpper   string       `json:"outbound_amount_upper"`

	GrossProfit        money.Amount `json:"gross_profit"`
	GrossProfitUpper   string       `json:"gross_profit_upper"`
	GrossMarginPPM     int64        `json:"gross_margin_ppm"`
	GrossMarginPercent string       `json:"gross_margin_percent"`

	PaidAmount          money.Amount `json:"paid_amount"`
	UnpaidAmount        money.Amount `json:"unpaid_amount"`
	UnpaidAmountUpper   string       `json:"unpaid_amount_upper"`
	UnpaidDocumentCount int64        `json:"unpaid_document_count"`

	InvoicedAmount          money.Amount `json:"invoiced_amount"`
	UninvoicedAmount        money.Amount `json:"uninvoiced_amount"`
	UninvoicedAmountUpper   string       `json:"uninvoiced_amount_upper"`
	UninvoicedDocumentCount int64        `json:"uninvoiced_document_count"`

	ReceivedAmount          money.Amount `json:"received_amount"`
	UnreceivedAmount        money.Amount `json:"unreceived_amount"`
	UnreceivedAmountUpper   string       `json:"unreceived_amount_upper"`
	UnreceivedDocumentCount int64        `json:"unreceived_document_count"`

	SupplierCount int64 `json:"supplier_count"`
	CustomerCount int64 `json:"customer_count"`

	SaleAmountTypes []SaleAmountTotalData `json:"sale_amount_types"`
}

// ItemData 是明细聚合的一行（按往来单位 + 品名 + 型号 + 单位分组）。
type ItemData struct {
	PartyName     string         `json:"party_name"`
	ProductName   string         `json:"product_name"`
	ProductModel  *string        `json:"product_model"`
	Unit          *string        `json:"unit"`
	DocumentCount int64          `json:"document_count"`
	Quantity      money.Quantity `json:"quantity"`
	Amount        money.Amount   `json:"amount"`
	AmountUpper   string         `json:"amount_upper"`
}

// InboundStatsData 是入库统计（FR-BACK-02：金额总计 / 未付款总计 / 付款情况 / 开票状态）。
//
// 这里刻意把「金额」与「付款 / 开票」分成两层口径：
//   - 合计块（DocumentCount / AmountTotal / Paid / Unpaid / Invoiced ...）是**单据粒度**的精确数字；
//   - Items 明细行只给金额与数量，不给已付 / 未付。
//
// 因为付款记录挂在单据上，而不是挂在某一行明细上：一张单里既有螺纹钢又有盘螺时，
// 那笔付款到底算在哪个品名头上根本无从推导。硬把单据级金额摊到明细行，
// 只会得到一组数字自洽、业务上却经不起追问的「假精确」报表。
type InboundStatsData struct {
	Period string `json:"period"`

	DocumentCount    int64        `json:"document_count"`
	AmountTotal      money.Amount `json:"amount_total"`
	AmountTotalUpper string       `json:"amount_total_upper"`

	PaidAmount          money.Amount `json:"paid_amount"`
	UnpaidAmount        money.Amount `json:"unpaid_amount"`
	UnpaidAmountUpper   string       `json:"unpaid_amount_upper"`
	UnpaidDocumentCount int64        `json:"unpaid_document_count"`

	InvoicedAmount          money.Amount `json:"invoiced_amount"`
	UninvoicedAmount        money.Amount `json:"uninvoiced_amount"`
	UninvoicedAmountUpper   string       `json:"uninvoiced_amount_upper"`
	UninvoicedDocumentCount int64        `json:"uninvoiced_document_count"`

	SupplierCount int64 `json:"supplier_count"`

	Items    []ItemData `json:"items"`
	Page     int        `json:"page"`
	PageSize int        `json:"page_size"`
	Total    int64      `json:"total"`
}

// OutboundStatsData 是出库统计（FR-BACK-03：三类销售金额分别统计 / 未收款总计 / 收款情况）。
type OutboundStatsData struct {
	Period string `json:"period"`

	DocumentCount    int64        `json:"document_count"`
	AmountTotal      money.Amount `json:"amount_total"`
	AmountTotalUpper string       `json:"amount_total_upper"`

	ReceivedAmount          money.Amount `json:"received_amount"`
	UnreceivedAmount        money.Amount `json:"unreceived_amount"`
	UnreceivedAmountUpper   string       `json:"unreceived_amount_upper"`
	UnreceivedDocumentCount int64        `json:"unreceived_document_count"`

	CustomerCount int64 `json:"customer_count"`

	SaleAmountTypes []SaleAmountTotalData `json:"sale_amount_types"`

	Items    []ItemData `json:"items"`
	Page     int        `json:"page"`
	PageSize int        `json:"page_size"`
	Total    int64      `json:"total"`
}

// BusinessUserSummaryData 是单个业务员的利润统计行。
type BusinessUserSummaryData struct {
	BusinessUser     identity.UserSummary `json:"business_user"`
	InboundAmount    money.Amount         `json:"inbound_amount"`
	OutboundAmount   money.Amount         `json:"outbound_amount"`
	GrossProfit      money.Amount         `json:"gross_profit"`
	GrossProfitUpper string               `json:"gross_profit_upper"`
	DocumentCount    int64                `json:"document_count"`
}

// BusinessUserTotalsData 是业务员利润统计的合计行。
type BusinessUserTotalsData struct {
	InboundAmount    money.Amount `json:"inbound_amount"`
	OutboundAmount   money.Amount `json:"outbound_amount"`
	GrossProfit      money.Amount `json:"gross_profit"`
	GrossProfitUpper string       `json:"gross_profit_upper"`
	DocumentCount    int64        `json:"document_count"`
}

// BusinessUserReportData 是业务员维度利润统计（FR-BACK-05 第三项）。
type BusinessUserReportData struct {
	Period  string                    `json:"period"`
	Items   []BusinessUserSummaryData `json:"items"`
	Summary BusinessUserTotalsData    `json:"summary"`
}

// SnapshotData 是一张月度总结算快照。
type SnapshotData struct {
	SnapshotID uint64 `json:"snapshot_id"`
	SnapshotNo string `json:"snapshot_no"`
	BatchNo    string `json:"batch_no"`
	Scope      Scope  `json:"scope"`
	Period     string `json:"period"`

	// BusinessUser 在公司维度快照里是全零值（没有具体业务员）。
	BusinessUser identity.UserSummary `json:"business_user"`

	InboundAmount      money.Amount `json:"inbound_amount"`
	InboundAmountUpper string       `json:"inbound_amount_upper"`
	OutboundAmount     money.Amount `json:"outbound_amount"`
	OutboundAmountUpper string      `json:"outbound_amount_upper"`
	GrossProfit        money.Amount `json:"gross_profit"`
	GrossProfitUpper   string       `json:"gross_profit_upper"`
	GrossMarginPPM     int64        `json:"gross_margin_ppm"`
	GrossMarginPercent string       `json:"gross_margin_percent"`

	SaleAmountTypes []SaleAmountTotalData `json:"sale_amount_types"`

	DocumentCount int64                `json:"document_count"`
	Remark        *string              `json:"remark"`
	CreatedBy     identity.UserSummary `json:"created_by"`
	CreatedAt     time.Time            `json:"created_at"`
}

// SnapshotPageData 是总结算快照分页响应。
type SnapshotPageData struct {
	Items    []SnapshotData `json:"items"`
	Page     int            `json:"page"`
	PageSize int            `json:"page_size"`
	Total    int64          `json:"total"`
}

// CreateSnapshotData 是生成月度总结算的响应。
//
// 返回本次生成的**全部**快照（业务员维度可能一次多张），并带上批次号：
// 客户端可以直接把这一批作为一个整体展示，不需要再按 id 逐张回查。
type CreateSnapshotData struct {
	BatchNo   string         `json:"batch_no"`
	Period    string         `json:"period"`
	Snapshots []SnapshotData `json:"snapshots"`
}

/* ------------------------------------------------------------------ 转换 */

// upperOf 统一生成人民币大写，避免各构造点各写一遍 rmb.Upper。
func upperOf(amount money.Amount) string { return rmb.Upper(amount) }

// buildOverviewData 由周期合计组装看板响应。
func buildOverviewData(period string, totals PeriodTotals) *OverviewData {
	grossProfit := totals.GrossProfit()
	return &OverviewData{
		Period: period,

		InboundDocumentCount: totals.InboundDocuments,
		InboundAmount:        totals.InboundAmount,
		InboundAmountUpper:   upperOf(totals.InboundAmount),

		OutboundDocumentCount: totals.OutboundDocuments,
		OutboundAmount:        totals.OutboundAmount,
		OutboundAmountUpper:   upperOf(totals.OutboundAmount),

		GrossProfit:        grossProfit,
		GrossProfitUpper:   upperOf(grossProfit),
		GrossMarginPPM:     totals.GrossMarginPPM(),
		GrossMarginPercent: percentText(totals.GrossMarginPPM()),

		PaidAmount:          totals.Paid,
		UnpaidAmount:        totals.Unpaid(),
		UnpaidAmountUpper:   upperOf(totals.Unpaid()),
		UnpaidDocumentCount: totals.UnpaidDocuments,

		InvoicedAmount:          totals.Invoiced,
		UninvoicedAmount:        totals.Uninvoiced(),
		UninvoicedAmountUpper:   upperOf(totals.Uninvoiced()),
		UninvoicedDocumentCount: totals.UninvoicedDocuments,

		ReceivedAmount:          totals.Received,
		UnreceivedAmount:        totals.Unreceived(),
		UnreceivedAmountUpper:   upperOf(totals.Unreceived()),
		UnreceivedDocumentCount: totals.UnreceivedDocuments,

		SupplierCount: totals.SupplierCount,
		CustomerCount: totals.CustomerCount,

		SaleAmountTypes: saleAmountTypeData(totals.SaleAmountTotals),
	}
}

// toSaleAmountTotalData 把一类销售金额转成响应体，占比以出库合计为分母。
func toSaleAmountTotalData(saleAmountType document.SaleAmountType, amount, total money.Amount) SaleAmountTotalData {
	share := ppmRatio(amount, total)
	return SaleAmountTotalData{
		SaleAmountType: saleAmountType,
		Amount:         amount,
		AmountUpper:    rmb.Upper(amount),
		SharePPM:       share,
		SharePercent:   percentText(share),
	}
}

// saleAmountTypeData 按固定顺序（Y-1 / y-N / N）返回三类销售金额，缺哪类补 0。
//
// 顺序固定而不是按金额排序：三类销售金额是固定的财务口径，
// 顺序随金额浮动会让使用者在不同月份看到的报表结构发生变化。
func saleAmountTypeData(totals SaleAmountTotals) []SaleAmountTotalData {
	total := totals.Total()
	return []SaleAmountTotalData{
		toSaleAmountTotalData(document.SaleAmountVATSpecial, totals.VATSpecial, total),
		toSaleAmountTotalData(document.SaleAmountVATGeneral, totals.VATGeneral, total),
		toSaleAmountTotalData(document.SaleAmountNoInvoice, totals.NoInvoice, total),
	}
}

func toItemData(row ItemTotals) ItemData {
	return ItemData{
		PartyName: row.PartyName, ProductName: row.ProductName,
		ProductModel: row.ProductModel, Unit: row.Unit,
		DocumentCount: row.DocumentCount, Quantity: row.Quantity,
		Amount: row.Amount, AmountUpper: rmb.Upper(row.Amount),
	}
}

func toItemPageData(page ItemPage) ([]ItemData, int, int, int64) {
	items := make([]ItemData, 0, len(page.Items))
	for _, row := range page.Items {
		items = append(items, toItemData(row))
	}
	return items, page.Page, page.PageSize, page.Total
}

// toSnapshotData 组装快照响应。
//
// 快照里的三类销售金额是从三列金额还原出来的，因此这里按「三类之和」计算占比分母，
// 与快照落库时使用的分母保持一致（快照一旦生成，占比不能随源单据变化而改变）。
func toSnapshotData(snapshot Snapshot, createdBy, businessUser identity.UserSummary) SnapshotData {
	totals := SaleAmountTotals{
		VATSpecial: snapshot.VATSpecialAmount,
		VATGeneral: snapshot.VATGeneralAmount,
		NoInvoice:  snapshot.NoInvoiceAmount,
	}
	return SnapshotData{
		SnapshotID: snapshot.ID, SnapshotNo: snapshot.SnapshotNo, BatchNo: snapshot.BatchNo,
		Scope: snapshot.Scope, Period: snapshot.PeriodStart.Format("2006-01"),
		BusinessUser: businessUser,

		InboundAmount: snapshot.InboundAmount, InboundAmountUpper: rmb.Upper(snapshot.InboundAmount),
		OutboundAmount: snapshot.OutboundAmount, OutboundAmountUpper: rmb.Upper(snapshot.OutboundAmount),
		GrossProfit: snapshot.GrossProfit, GrossProfitUpper: rmb.Upper(snapshot.GrossProfit),
		GrossMarginPPM: snapshot.GrossMarginPPM, GrossMarginPercent: percentText(snapshot.GrossMarginPPM),

		SaleAmountTypes: saleAmountTypeData(totals),

		DocumentCount: snapshot.DocumentCount, Remark: snapshot.Remark,
		CreatedBy: createdBy, CreatedAt: snapshot.CreatedAt,
	}
}

// percentText 把百万分之一的整数比值格式化成两位小数的百分比文本。
//
// 207500 → "20.75"，50 → "0.01"。客户端拿到就能直接显示，
// 三端不会各写一套除法而出现「一端显示 20.75%、另一端显示 20.8%」的差异。
func percentText(ppm int64) string {
	negative := ppm < 0
	if negative {
		ppm = -ppm
	}
	// 两位小数的百分比以「万分之一百分比」为最小单位，先四舍五入到该单位再拆分。
	hundredths := (ppm + 50) / 100
	if negative && hundredths != 0 {
		return fmt.Sprintf("-%d.%02d", hundredths/100, hundredths%100)
	}
	return fmt.Sprintf("%d.%02d", hundredths/100, hundredths%100)
}
