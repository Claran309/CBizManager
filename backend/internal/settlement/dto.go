package settlement

import (
	"time"

	"CBizDocsManager/backend/internal/document"
	"CBizDocsManager/backend/internal/identity"
	"CBizDocsManager/backend/pkg/money"
	"CBizDocsManager/backend/pkg/rmb"
)

const businessDateLayout = "2006-01-02"

/* ------------------------------------------------------------------ 请求 */

// ListQuery 是结算单列表查询条件。
type ListQuery struct {
	Keyword         string `form:"keyword"`
	Status          Status `form:"status"`
	RequesterUserID uint64 `form:"requester_user_id"`
	Month           string `form:"month"`
	Page            int    `form:"page"`
	PageSize        int    `form:"page_size"`
}

// SourceRequest 是申请结算时勾选的一张源单据。
type SourceRequest struct {
	DocumentID uint64 `json:"document_id"`
}

// CreateRequest 是提交结算申请请求。
type CreateRequest struct {
	Remark  *string         `json:"remark"`
	Sources []SourceRequest `json:"sources"`
}

// DecideRequest 是审批（通过 / 驳回）请求。
type DecideRequest struct {
	Version uint64  `json:"version"`
	Remark  *string `json:"remark"`
}

/* ------------------------------------------------------------------ 响应 */

// SourceData 是结算单里的一张源单据快照。
type SourceData struct {
	DocumentID   uint64               `json:"document_id"`
	Kind         document.Kind        `json:"kind"`
	DocumentNo   string               `json:"document_no"`
	BusinessUser identity.UserSummary `json:"business_user"`
	BusinessDate string               `json:"business_date"`
	Amount       money.Amount         `json:"amount"`
	// Released 表示该源单据已被释放（结算单被驳回），可以重新申请结算。
	Released bool `json:"released"`
}

// ApprovalRecordData 是审批链路上的一条记录。
type ApprovalRecordData struct {
	Action    Action               `json:"action"`
	Operator  identity.UserSummary `json:"operator"`
	Remark    *string              `json:"remark"`
	CreatedAt time.Time            `json:"created_at"`
}

// SettlementData 是结算单详情响应。
type SettlementData struct {
	SettlementID     uint64                `json:"settlement_id"`
	SettlementNo     string                `json:"settlement_no"`
	Status           Status                `json:"status"`
	Requester        identity.UserSummary  `json:"requester"`
	Remark           *string               `json:"remark"`
	InboundTotal     money.Amount          `json:"inbound_total"`
	OutboundTotal    money.Amount          `json:"outbound_total"`
	GrossProfit      money.Amount          `json:"gross_profit"`
	SourceCount      int                   `json:"source_count"`
	InboundUpper     string                `json:"inbound_total_upper"`
	OutboundUpper    string                `json:"outbound_total_upper"`
	GrossProfitUpper string                `json:"gross_profit_upper"`
	Version          uint64                `json:"version"`
	DecidedAt        *time.Time            `json:"decided_at"`
	DecidedBy        *identity.UserSummary `json:"decided_by"`
	DecisionRemark   *string               `json:"decision_remark"`
	CreatedAt        time.Time             `json:"created_at"`
	UpdatedAt        time.Time             `json:"updated_at"`
	Sources          []SourceData          `json:"sources"`
	ApprovalRecords  []ApprovalRecordData  `json:"approval_records"`
}

// SettlementSummaryData 是结算单列表行响应。
type SettlementSummaryData struct {
	SettlementID   uint64               `json:"settlement_id"`
	SettlementNo   string               `json:"settlement_no"`
	Status         Status               `json:"status"`
	Requester      identity.UserSummary `json:"requester"`
	InboundTotal   money.Amount         `json:"inbound_total"`
	OutboundTotal  money.Amount         `json:"outbound_total"`
	GrossProfit    money.Amount         `json:"gross_profit"`
	SourceCount    int                  `json:"source_count"`
	Version        uint64               `json:"version"`
	DecidedAt      *time.Time           `json:"decided_at"`
	DecisionRemark *string              `json:"decision_remark"`
	CreatedAt      time.Time            `json:"created_at"`
	UpdatedAt      time.Time            `json:"updated_at"`
}

// SettlementPageData 是结算单分页响应。
type SettlementPageData struct {
	Items    []SettlementSummaryData `json:"items"`
	Page     int                     `json:"page"`
	PageSize int                     `json:"page_size"`
	Total    int64                   `json:"total"`
}

/* ------------------------------------------------------------------ 转换 */

func toSourceData(source Source, businessUser identity.UserSummary) SourceData {
	return SourceData{
		DocumentID: source.DocumentID, Kind: source.Kind, DocumentNo: source.DocumentNo,
		BusinessUser: businessUser, BusinessDate: source.BusinessDate.Format(businessDateLayout),
		Amount: source.Amount, Released: source.ReleasedAt != nil,
	}
}

func toApprovalRecordData(record ApprovalRecord, operator identity.UserSummary) ApprovalRecordData {
	return ApprovalRecordData{
		Action: record.Action, Operator: operator, Remark: record.Remark, CreatedAt: record.CreatedAt,
	}
}

func toSettlementSummaryData(summary Summary) SettlementSummaryData {
	return SettlementSummaryData{
		SettlementID: summary.Settlement.ID, SettlementNo: summary.Settlement.SettlementNo,
		Status:       summary.Settlement.Status,
		Requester:    identity.UserSummary{ID: summary.RequesterUserID, DisplayName: summary.RequesterName},
		InboundTotal: summary.Settlement.InboundTotal, OutboundTotal: summary.Settlement.OutboundTotal,
		GrossProfit: summary.Settlement.GrossProfit, SourceCount: summary.Settlement.SourceCount,
		Version: summary.Settlement.Version, DecidedAt: summary.Settlement.DecidedAt,
		DecisionRemark: summary.Settlement.DecisionRemark,
		CreatedAt:      summary.Settlement.CreatedAt, UpdatedAt: summary.Settlement.UpdatedAt,
	}
}

// buildSettlementData 组装结算单详情。
//
// 三项金额都附上服务端生成的人民币大写：毛利润允许为负，rmb.Upper 会返回「RMB负…」，
// 客户端直接展示即可，不需要各端再写一套大写算法。
func buildSettlementData(
	detail Detail,
	requester identity.UserSummary,
	decidedBy *identity.UserSummary,
	sourceUsers map[uint64]identity.UserSummary,
	recordUsers map[uint64]identity.UserSummary,
) *SettlementData {
	sources := make([]SourceData, 0, len(detail.Sources))
	for _, source := range detail.Sources {
		sources = append(sources, toSourceData(source, sourceUsers[source.BusinessUserID]))
	}
	records := make([]ApprovalRecordData, 0, len(detail.Records))
	for _, record := range detail.Records {
		records = append(records, toApprovalRecordData(record, recordUsers[record.OperatorUserID]))
	}
	return &SettlementData{
		SettlementID: detail.Settlement.ID, SettlementNo: detail.Settlement.SettlementNo,
		Status: detail.Settlement.Status, Requester: requester, Remark: detail.Settlement.Remark,
		InboundTotal: detail.Settlement.InboundTotal, OutboundTotal: detail.Settlement.OutboundTotal,
		GrossProfit: detail.Settlement.GrossProfit, SourceCount: detail.Settlement.SourceCount,
		InboundUpper: rmb.Upper(detail.Settlement.InboundTotal), OutboundUpper: rmb.Upper(detail.Settlement.OutboundTotal),
		GrossProfitUpper: rmb.Upper(detail.Settlement.GrossProfit),
		Version:          detail.Settlement.Version, DecidedAt: detail.Settlement.DecidedAt, DecidedBy: decidedBy,
		DecisionRemark: detail.Settlement.DecisionRemark,
		CreatedAt:      detail.Settlement.CreatedAt, UpdatedAt: detail.Settlement.UpdatedAt,
		Sources: sources, ApprovalRecords: records,
	}
}
