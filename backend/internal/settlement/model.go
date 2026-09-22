package settlement

import (
	"time"

	"CBizDocsManager/backend/internal/document"
	"CBizDocsManager/backend/pkg/money"
)

/* ------------------------------------------------------------------ 枚举 */

// Status 是结算单的审批状态。
//
// 一期只做单级审批：待审批 → 审批通过 / 审批驳回。通过与驳回都是终态，
// 业务员要重新申请只能修改源单据后新建一张结算单，这样每一次审批结论都不会被覆盖。
type Status string

const (
	// StatusPending 待审批。
	StatusPending Status = "pending"
	// StatusApproved 审批通过。
	StatusApproved Status = "approved"
	// StatusRejected 审批驳回。
	StatusRejected Status = "rejected"
)

// IsTerminal 判断是否为终态（已审批过，不可再次审批）。
func (s Status) IsTerminal() bool { return s == StatusApproved || s == StatusRejected }

// ParseStatus 校验并解析客户端传入的结算单状态。
func ParseStatus(value string) (Status, bool) {
	switch Status(value) {
	case StatusPending, StatusApproved, StatusRejected:
		return Status(value), true
	default:
		return "", false
	}
}

// Label 返回状态的中文展示文案（仅用于审计摘要，界面文案仍由客户端决定）。
func (s Status) Label() string {
	switch s {
	case StatusPending:
		return "待审批"
	case StatusApproved:
		return "审批通过"
	case StatusRejected:
		return "审批驳回"
	default:
		return string(s)
	}
}

// Action 是审批记录中的动作，覆盖「申请」与两次审批结论。
type Action string

const (
	// ActionSubmitted 业务员提交结算申请。
	ActionSubmitted Action = "submitted"
	// ActionApproved 审批通过。
	ActionApproved Action = "approved"
	// ActionRejected 审批驳回。
	ActionRejected Action = "rejected"
)

// Label 返回动作的中文展示文案。
func (a Action) Label() string {
	switch a {
	case ActionSubmitted:
		return "提交申请"
	case ActionApproved:
		return "审批通过"
	case ActionRejected:
		return "审批驳回"
	default:
		return string(a)
	}
}

/* ------------------------------------------------------------------ 实体 */

// Settlement 是结算单主表实体。
//
// inbound_total / outbound_total / gross_profit 是生成结算单时的金额快照：
// 源单据后续被修改或作废都不会回头改动这三个值，保证「已生成结算单数值稳定」。
type Settlement struct {
	ID              uint64       `gorm:"primaryKey;autoIncrement"`
	GroupID         uint64       `gorm:"not null;index"`
	SettlementNo    string       `gorm:"size:32;not null"`
	Status          Status       `gorm:"size:16;not null"`
	RequesterUserID uint64       `gorm:"not null"`
	Remark          *string      `gorm:"size:500"`
	InboundTotal    money.Amount `gorm:"not null"`
	OutboundTotal   money.Amount `gorm:"not null"`
	GrossProfit     money.Amount `gorm:"not null"`
	SourceCount     int          `gorm:"not null"`
	Version         uint64       `gorm:"not null;default:1"`
	DecidedAt       *time.Time
	DecidedBy       *uint64
	DecisionRemark  *string `gorm:"size:500"`
	CreatedBy       uint64  `gorm:"not null"`
	UpdatedBy       uint64  `gorm:"not null"`
	CreatedAt       time.Time
	UpdatedAt       time.Time
}

func (Settlement) TableName() string { return "settlements" }

// Source 是结算单引用的源单据快照。
//
// ActiveDocumentID 是 document_id 的活跃副本：被有效结算单占用时等于 DocumentID，
// 结算单被驳回释放后置为 NULL。表上 (group_id, active_document_id) 有唯一索引，
// 用来兜底「同一源单据不允许被两张有效结算单同时引用」。
type Source struct {
	ID               uint64        `gorm:"primaryKey;autoIncrement"`
	GroupID          uint64        `gorm:"not null;index"`
	SettlementID     uint64        `gorm:"not null;index"`
	DocumentID       uint64        `gorm:"not null"`
	Kind             document.Kind `gorm:"size:16;not null"`
	DocumentNo       string        `gorm:"size:32;not null"`
	BusinessUserID   uint64        `gorm:"not null"`
	BusinessDate     time.Time     `gorm:"type:date;not null"`
	Amount           money.Amount  `gorm:"not null"`
	ActiveDocumentID *uint64
	ReleasedAt       *time.Time
	CreatedAt        time.Time
}

func (Source) TableName() string { return "settlement_sources" }

// ApprovalRecord 是审批链路记录，只增不改。
type ApprovalRecord struct {
	ID             uint64  `gorm:"primaryKey;autoIncrement"`
	GroupID        uint64  `gorm:"not null;index"`
	SettlementID   uint64  `gorm:"not null;index"`
	Action         Action  `gorm:"size:16;not null"`
	OperatorUserID uint64  `gorm:"not null"`
	Remark         *string `gorm:"size:500"`
	CreatedAt      time.Time
}

func (ApprovalRecord) TableName() string { return "approval_records" }

/* ------------------------------------------------------------------ 聚合 */

// SourceDocument 是申请结算时读到的源单据当前状态，用于校验与生成快照。
//
// 它刻意只带结算用得到的字段（而不是整套 document.Detail），
// 既能避开跨模块的明细依赖，也让「结算只关心总额」这件事在类型上就看得见。
type SourceDocument struct {
	ID             uint64
	Kind           document.Kind
	DocumentNo     string
	Status         document.Status
	BusinessUserID uint64
	BusinessDate   time.Time
	TotalAmount    money.Amount
}

// Page 是结算单列表分页结果。
type Page struct {
	Items    []Summary
	Page     int
	PageSize int
	Total    int64
}

// Summary 是列表行所需的结算单摘要。
type Summary struct {
	Settlement      Settlement
	RequesterName   string
	RequesterUserID uint64
}

// Detail 是结算单详情聚合：主表 + 源单据快照 + 审批记录。
type Detail struct {
	Settlement Settlement
	Sources    []Source
	Records    []ApprovalRecord
}

/* ------------------------------------------------------------------ 输入 */

// SourceSnapshot 是落库的源单据快照。
type SourceSnapshot struct {
	DocumentID     uint64
	Kind           document.Kind
	DocumentNo     string
	BusinessUserID uint64
	BusinessDate   time.Time
	Amount         money.Amount
}

// CreateInput 是创建结算单的仓储入参。
type CreateInput struct {
	GroupID            uint64
	RequesterUserID    uint64
	Remark             *string
	InboundTotal       money.Amount
	OutboundTotal      money.Amount
	GrossProfit        money.Amount
	Sources            []SourceSnapshot
	OperatorUserID     uint64
	Now                time.Time
	IdempotencyScope   string
	IdempotencyKey     string
	RequestFingerprint string
	AuditAction        string
	AuditSummary       string
}

// DecideInput 是审批（通过 / 驳回）的仓储入参。
type DecideInput struct {
	GroupID         uint64
	SettlementID    uint64
	OperatorUserID  uint64
	ExpectedVersion uint64
	Status          Status
	DecisionRemark  *string
	// ReleaseSources 为真时释放源单据的活跃引用（驳回场景）。
	ReleaseSources bool
	Now            time.Time
	AuditAction    string
	AuditSummary   string
}

// RepositoryQuery 是归一化后的仓储查询条件。
type RepositoryQuery struct {
	Keyword             string
	Status              *Status
	MonthStart          *time.Time
	MonthEnd            *time.Time
	RequesterUserID     *uint64
	OnlyRequesterUserID uint64
	Page                int
	PageSize            int
}
