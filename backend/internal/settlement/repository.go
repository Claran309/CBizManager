package settlement

import (
	"context"
	"errors"
	"fmt"
	"strconv"
	"strings"
	"time"

	"CBizDocsManager/backend/internal/document"
	"CBizDocsManager/backend/internal/identity"
	"CBizDocsManager/backend/pkg/bizdate"
	"gorm.io/gorm"
	"gorm.io/gorm/clause"
)

// maxSettlementNoAttempts 限制结算单号并发撞车后的重试次数。
const maxSettlementNoAttempts = 5

type gormRepository struct{ db *gorm.DB }

// NewRepository 创建结算仓储。
func NewRepository(db *gorm.DB) Repository { return &gormRepository{db: db} }

/* ------------------------------------------------------------------ 写操作 */

// CreateSettlement 创建结算单。
//
// 单号按「组 + 年月」生成，并发撞车时依赖唯一索引报错并重试，而不是用悲观锁把整张表串行化；
// 源单据的占用冲突则优先用预检给出友好错误，唯一索引只作为并发兜底。
func (r *gormRepository) CreateSettlement(ctx context.Context, input CreateInput) (Settlement, error) {
	for attempt := 0; attempt < maxSettlementNoAttempts; attempt++ {
		settlement, err := r.tryCreateSettlement(ctx, input)
		if err == nil {
			return settlement, nil
		}
		if !errors.Is(err, ErrSettlementNoConflict) {
			return Settlement{}, err
		}
	}
	return Settlement{}, ErrSettlementNoConflict
}

func (r *gormRepository) tryCreateSettlement(ctx context.Context, input CreateInput) (Settlement, error) {
	var created Settlement
	err := r.db.WithContext(ctx).Transaction(func(tx *gorm.DB) error {
		tx = tx.WithContext(ctx)

		// 1) 幂等重放：同一个 key 且内容指纹一致，直接返回首次创建的结算单。
		if input.IdempotencyKey != "" {
			existing, hit, err := replaySettlement(tx, input.GroupID, input.OperatorUserID, input.IdempotencyScope, input.IdempotencyKey, input.RequestFingerprint)
			if err != nil {
				return err
			}
			if hit {
				created = existing
				return nil
			}
		}

		// 2) 源单据占用预检：已被其他有效结算单引用的单据不允许再次结算。
		if err := ensureSourcesFree(tx, input.GroupID, input.Sources); err != nil {
			return err
		}

		// 3) 生成当月结算单号（月份用紧凑的 YYYYMM，单号形如 JS202609-0003）。
		month := bizdate.FormatMonthCompact(input.Now)
		sequence, err := nextSettlementSequence(tx, input.GroupID, month)
		if err != nil {
			return err
		}
		settlement := Settlement{
			GroupID: input.GroupID, SettlementNo: formatSettlementNo(month, sequence),
			Status: StatusPending, RequesterUserID: input.RequesterUserID, Remark: input.Remark,
			InboundTotal: input.InboundTotal, OutboundTotal: input.OutboundTotal, GrossProfit: input.GrossProfit,
			SourceCount: len(input.Sources), Version: 1,
			CreatedBy: input.OperatorUserID, UpdatedBy: input.OperatorUserID,
			// 显式使用注入时钟而不是让 GORM 取墙上时间：单号由 input.Now 决定月份，
			// 列表又按 created_at 过滤月份，两者若各取一套时间，跨月瞬间会出现
			// 「单号是 10 月、列表却归到 9 月」的错位。
			CreatedAt: input.Now, UpdatedAt: input.Now,
		}
		if err := tx.Create(&settlement).Error; err != nil {
			if errors.Is(err, gorm.ErrDuplicatedKey) {
				return ErrSettlementNoConflict
			}
			return fmt.Errorf("insert settlement: %w", err)
		}

		// 4) 源单据快照；active_document_id 同时写入，占住唯一索引。
		for _, snapshot := range input.Sources {
			documentID := snapshot.DocumentID
			source := Source{
				GroupID: input.GroupID, SettlementID: settlement.ID, DocumentID: snapshot.DocumentID,
				Kind: snapshot.Kind, DocumentNo: snapshot.DocumentNo, BusinessUserID: snapshot.BusinessUserID,
				BusinessDate: snapshot.BusinessDate, Amount: snapshot.Amount, ActiveDocumentID: &documentID,
				CreatedAt: input.Now,
			}
			if err := tx.Create(&source).Error; err != nil {
				// 唯一索引冲突说明另一笔并发申请抢先占用了同一张源单据。
				if errors.Is(err, gorm.ErrDuplicatedKey) {
					return ErrSourceConflict
				}
				return fmt.Errorf("insert settlement source: %w", err)
			}
		}

		// 5) 审批链路：申请本身也是一条记录。
		if err := appendApprovalRecord(tx, input.GroupID, settlement.ID, ActionSubmitted, input.OperatorUserID, input.Remark, input.Now); err != nil {
			return err
		}

		// 6) 幂等记录与审计。
		if input.IdempotencyKey != "" {
			if err := insertIdempotencyRecord(tx, input.GroupID, input.OperatorUserID, input.IdempotencyScope, input.IdempotencyKey, input.RequestFingerprint, settlement.ID, input.Now); err != nil {
				return err
			}
		}
		if err := appendSettlementAudit(tx, input.GroupID, input.OperatorUserID, input.AuditAction, settlement, input.AuditSummary, input.Now); err != nil {
			return err
		}
		created = settlement
		return nil
	})
	if err != nil {
		return Settlement{}, err
	}
	return created, nil
}

// DecideSettlement 写入审批结论并追加审批记录；驳回时释放源单据的活跃引用。
func (r *gormRepository) DecideSettlement(ctx context.Context, input DecideInput) (Settlement, error) {
	var result Settlement
	err := r.db.WithContext(ctx).Transaction(func(tx *gorm.DB) error {
		tx = tx.WithContext(ctx)

		current, err := findSettlementLocked(tx, input.GroupID, input.SettlementID)
		if err != nil {
			return err
		}
		if current.Version != input.ExpectedVersion {
			return ErrVersionConflict
		}
		if current.Status.IsTerminal() {
			// 单级审批：同一张结算单只能被审批一次。
			return ErrStatusInvalid
		}

		update := tx.Model(&Settlement{}).
			Where("id = ? AND group_id = ? AND version = ?", input.SettlementID, input.GroupID, input.ExpectedVersion).
			Updates(map[string]any{
				"status": input.Status, "decided_at": input.Now, "decided_by": input.OperatorUserID,
				"decision_remark": input.DecisionRemark, "updated_by": input.OperatorUserID,
				"updated_at": input.Now, "version": gorm.Expr("version + 1"),
			})
		if update.Error != nil {
			return fmt.Errorf("update settlement status: %w", update.Error)
		}
		if update.RowsAffected != 1 {
			return ErrVersionConflict
		}

		if input.ReleaseSources {
			// 把活跃引用置回 NULL，源单据即可被新的结算单重新引用；
			// 关联行本身保留，结算单与源单据的追溯关系不丢。
			release := tx.Model(&Source{}).
				Where("settlement_id = ? AND group_id = ?", input.SettlementID, input.GroupID).
				Updates(map[string]any{"active_document_id": nil, "released_at": input.Now})
			if release.Error != nil {
				return fmt.Errorf("release settlement sources: %w", release.Error)
			}
		}

		action := ActionApproved
		if input.Status == StatusRejected {
			action = ActionRejected
		}
		if err := appendApprovalRecord(tx, input.GroupID, input.SettlementID, action, input.OperatorUserID, input.DecisionRemark, input.Now); err != nil {
			return err
		}
		if err := appendSettlementAudit(tx, input.GroupID, input.OperatorUserID, input.AuditAction, current, input.AuditSummary, input.Now); err != nil {
			return err
		}

		current.Status = input.Status
		current.DecisionRemark = input.DecisionRemark
		current.UpdatedBy = input.OperatorUserID
		current.UpdatedAt = input.Now
		current.Version = input.ExpectedVersion + 1
		decidedAt := input.Now
		decidedBy := input.OperatorUserID
		current.DecidedAt = &decidedAt
		current.DecidedBy = &decidedBy
		result = current
		return nil
	})
	if err != nil {
		return Settlement{}, err
	}
	return result, nil
}

/* ------------------------------------------------------------------ 读操作 */

// FindSettlement 按组读取结算单主表。
func (r *gormRepository) FindSettlement(ctx context.Context, groupID, settlementID uint64) (Settlement, error) {
	return findSettlement(r.db.WithContext(ctx), groupID, settlementID)
}

// LoadDetail 读取结算单详情：主表 + 源单据 + 审批记录，固定 3 条查询。
func (r *gormRepository) LoadDetail(ctx context.Context, groupID, settlementID uint64) (Detail, error) {
	db := r.db.WithContext(ctx)
	settlement, err := findSettlement(db, groupID, settlementID)
	if err != nil {
		return Detail{}, err
	}
	var sources []Source
	if err := db.Where("settlement_id = ? AND group_id = ?", settlementID, groupID).
		Order("kind ASC").Order("id ASC").Find(&sources).Error; err != nil {
		return Detail{}, fmt.Errorf("load settlement sources: %w", err)
	}
	var records []ApprovalRecord
	if err := db.Where("settlement_id = ? AND group_id = ?", settlementID, groupID).
		Order("id ASC").Find(&records).Error; err != nil {
		return Detail{}, fmt.Errorf("load approval records: %w", err)
	}
	return Detail{Settlement: settlement, Sources: sources, Records: records}, nil
}

// ListSettlements 分页查询结算单列表，附带申请人名称。
func (r *gormRepository) ListSettlements(ctx context.Context, groupID uint64, query RepositoryQuery) (Page, error) {
	db := r.db.WithContext(ctx)
	// 每次重建查询条件：GORM 的链式查询被 Count 复用后继续 Find 容易串到旧条件。
	buildQuery := func() *gorm.DB {
		statement := db.Model(&Settlement{}).Where("settlements.group_id = ?", groupID)
		if query.Status != nil {
			statement = statement.Where("settlements.status = ?", *query.Status)
		}
		if query.MonthStart != nil {
			statement = statement.Where("settlements.created_at >= ?", *query.MonthStart)
		}
		if query.MonthEnd != nil {
			statement = statement.Where("settlements.created_at < ?", *query.MonthEnd)
		}
		if query.RequesterUserID != nil {
			statement = statement.Where("settlements.requester_user_id = ?", *query.RequesterUserID)
		}
		if query.OnlyRequesterUserID != 0 {
			statement = statement.Where("settlements.requester_user_id = ?", query.OnlyRequesterUserID)
		}
		if keyword := strings.TrimSpace(query.Keyword); keyword != "" {
			like := "%" + keyword + "%"
			statement = statement.Where("settlements.settlement_no LIKE ?", like)
		}
		return statement
	}

	var total int64
	if err := buildQuery().Count(&total).Error; err != nil {
		return Page{}, fmt.Errorf("count settlements: %w", err)
	}

	var settlements []Settlement
	offset := (query.Page - 1) * query.PageSize
	if err := buildQuery().Order("settlements.created_at DESC").Order("settlements.id DESC").
		Offset(offset).Limit(query.PageSize).Find(&settlements).Error; err != nil {
		return Page{}, fmt.Errorf("list settlements: %w", err)
	}

	page := Page{Items: []Summary{}, Page: query.Page, PageSize: query.PageSize, Total: total}
	if len(settlements) == 0 {
		return page, nil
	}

	requesterIDs := make([]uint64, 0, len(settlements))
	for _, settlement := range settlements {
		requesterIDs = append(requesterIDs, settlement.RequesterUserID)
	}
	users, err := r.LoadUsers(ctx, requesterIDs)
	if err != nil {
		return Page{}, err
	}
	for _, settlement := range settlements {
		// users 里缺人时也要保留 ID，界面至少能显示「已注销用户」而不是空行。
		requester := users[settlement.RequesterUserID]
		requester.ID = settlement.RequesterUserID
		page.Items = append(page.Items, Summary{Settlement: settlement, Requester: requester})
	}
	return page, nil
}

// LoadSourceDocuments 读取候选源单据的当前状态。
//
// 只返回本组单据；调用方通过「返回条数是否与请求条数一致」识别不存在或跨组的 ID。
func (r *gormRepository) LoadSourceDocuments(ctx context.Context, groupID uint64, ids []uint64) ([]SourceDocument, error) {
	if len(ids) == 0 {
		return nil, nil
	}
	var documents []document.Document
	if err := r.db.WithContext(ctx).
		Where("group_id = ? AND id IN ?", groupID, ids).Find(&documents).Error; err != nil {
		return nil, fmt.Errorf("load source documents: %w", err)
	}
	result := make([]SourceDocument, 0, len(documents))
	for _, doc := range documents {
		result = append(result, SourceDocument{
			ID: doc.ID, Kind: doc.Kind, DocumentNo: doc.DocumentNo, Status: doc.Status,
			BusinessUserID: doc.BusinessUserID, BusinessDate: doc.BusinessDate, TotalAmount: doc.TotalAmount,
		})
	}
	return result, nil
}

// LoadUsers 读取用户摘要（用户表属于身份模块，这里只做只读聚合）。
func (r *gormRepository) LoadUsers(ctx context.Context, ids []uint64) (map[uint64]identity.UserSummary, error) {
	result := make(map[uint64]identity.UserSummary, len(ids))
	if len(ids) == 0 {
		return result, nil
	}
	var users []identity.User
	if err := r.db.WithContext(ctx).Where("id IN ?", ids).Find(&users).Error; err != nil {
		return nil, fmt.Errorf("load users: %w", err)
	}
	for _, user := range users {
		result[user.ID] = identity.UserSummary{
			ID: user.ID, Username: user.Username, DisplayName: user.DisplayName, AccountType: user.AccountType,
		}
	}
	return result, nil
}

/* ------------------------------------------------------------------ 内部工具 */

func findSettlement(db *gorm.DB, groupID, settlementID uint64) (Settlement, error) {
	var settlement Settlement
	err := db.Where("id = ? AND group_id = ?", settlementID, groupID).Take(&settlement).Error
	if errors.Is(err, gorm.ErrRecordNotFound) {
		return Settlement{}, ErrNotFound
	}
	if err != nil {
		return Settlement{}, fmt.Errorf("find settlement: %w", err)
	}
	return settlement, nil
}

func findSettlementLocked(tx *gorm.DB, groupID, settlementID uint64) (Settlement, error) {
	var settlement Settlement
	err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).
		Where("id = ? AND group_id = ?", settlementID, groupID).Take(&settlement).Error
	if errors.Is(err, gorm.ErrRecordNotFound) {
		return Settlement{}, ErrNotFound
	}
	if err != nil {
		return Settlement{}, fmt.Errorf("find settlement for update: %w", err)
	}
	return settlement, nil
}

// ensureSourcesFree 预检源单据是否已被其他有效结算单占用。
//
// 加行锁是为了让并发的两笔申请在同一批源单据上串行；对于「两边都还没插入」的幻读场景，
// 仍然由 (group_id, active_document_id) 唯一索引兜底。
func ensureSourcesFree(tx *gorm.DB, groupID uint64, sources []SourceSnapshot) error {
	if len(sources) == 0 {
		return nil
	}
	ids := make([]uint64, 0, len(sources))
	for _, source := range sources {
		ids = append(ids, source.DocumentID)
	}
	var occupied []uint64
	if err := tx.Table("settlement_sources").
		Clauses(clause.Locking{Strength: "UPDATE"}).
		Where("group_id = ? AND active_document_id IN ?", groupID, ids).
		Pluck("document_id", &occupied).Error; err != nil {
		return fmt.Errorf("check settlement source occupancy: %w", err)
	}
	if len(occupied) > 0 {
		return ErrSourceConflict
	}
	return nil
}

// nextSettlementSequence 取当月「组」最大序号 + 1。
// 单号是定宽的（前缀 + 年月 + 4 位序号），因此字符串倒序等同于数值倒序。
func nextSettlementSequence(tx *gorm.DB, groupID uint64, month string) (int, error) {
	var latest string
	err := tx.Model(&Settlement{}).
		Select("settlement_no").
		Where("group_id = ? AND settlement_no LIKE ?", groupID, settlementNoLikePattern(month)).
		Order("settlement_no DESC").Limit(1).
		Scan(&latest).Error
	if err != nil {
		return 0, fmt.Errorf("load latest settlement no: %w", err)
	}
	sequence := sequenceFromSettlementNo(latest) + 1
	if sequence > 9999 {
		return 0, fmt.Errorf("当月结算单号已用尽")
	}
	return sequence, nil
}

func appendApprovalRecord(tx *gorm.DB, groupID, settlementID uint64, action Action, operatorID uint64, remark *string, now time.Time) error {
	record := ApprovalRecord{
		GroupID: groupID, SettlementID: settlementID, Action: action,
		OperatorUserID: operatorID, Remark: remark, CreatedAt: now,
	}
	if err := tx.Create(&record).Error; err != nil {
		return fmt.Errorf("insert approval record: %w", err)
	}
	return nil
}

// appendSettlementAudit 追加审计日志，单号由仓储统一拼装，保证各入口文案一致。
func appendSettlementAudit(tx *gorm.DB, groupID, userID uint64, action string, settlement Settlement, summary string, now time.Time) error {
	text := fmt.Sprintf("结算单 %s %s", settlement.SettlementNo, summary)
	err := tx.Table("audit_logs").Create(map[string]any{
		"group_id": groupID, "operator_user_id": userID, "action": action,
		"resource_type": "settlement", "resource_id": strconv.FormatUint(settlement.ID, 10),
		"summary": text, "created_at": now,
	}).Error
	if err != nil {
		return fmt.Errorf("append settlement audit: %w", err)
	}
	return nil
}

/* ------------------------------------------------------------------ 幂等记录 */

// idempotencyRecord 对应 idempotency_records 表（与单据模块共用同一张表，用 scope 区分场景）。
type idempotencyRecord struct {
	ID                 uint64    `gorm:"primaryKey;autoIncrement"`
	GroupID            uint64    `gorm:"not null"`
	UserID             uint64    `gorm:"not null"`
	Scope              string    `gorm:"size:100;not null"`
	IdempotencyKey     string    `gorm:"size:191;not null"`
	RequestFingerprint string    `gorm:"size:64;not null"`
	ResourceType       string    `gorm:"size:100;not null"`
	ResourceID         string    `gorm:"size:191;not null"`
	CreatedAt          time.Time `gorm:"not null"`
}

func (idempotencyRecord) TableName() string { return "idempotency_records" }

// replaySettlement 查幂等记录并返回既有结算单；指纹不一致时返回 ErrIdempotencyMismatch。
func replaySettlement(tx *gorm.DB, groupID, userID uint64, scope, key, fingerprint string) (Settlement, bool, error) {
	var record idempotencyRecord
	err := tx.Where("group_id = ? AND user_id = ? AND scope = ? AND idempotency_key = ?", groupID, userID, scope, key).
		Take(&record).Error
	if errors.Is(err, gorm.ErrRecordNotFound) {
		return Settlement{}, false, nil
	}
	if err != nil {
		return Settlement{}, false, fmt.Errorf("find idempotency record: %w", err)
	}
	if record.RequestFingerprint != fingerprint {
		return Settlement{}, false, ErrIdempotencyMismatch
	}
	settlementID, err := strconv.ParseUint(record.ResourceID, 10, 64)
	if err != nil {
		return Settlement{}, false, fmt.Errorf("parse idempotency resource id: %w", err)
	}
	settlement, err := findSettlement(tx, groupID, settlementID)
	if err != nil {
		return Settlement{}, false, err
	}
	return settlement, true, nil
}

func insertIdempotencyRecord(tx *gorm.DB, groupID, userID uint64, scope, key, fingerprint string, settlementID uint64, now time.Time) error {
	record := idempotencyRecord{
		GroupID: groupID, UserID: userID, Scope: scope, IdempotencyKey: key,
		RequestFingerprint: fingerprint, ResourceType: "settlement",
		ResourceID: strconv.FormatUint(settlementID, 10), CreatedAt: now,
	}
	if err := tx.Create(&record).Error; err != nil {
		// 唯一键冲突说明同一请求被并发重放，交给上层按单号冲突重试。
		if errors.Is(err, gorm.ErrDuplicatedKey) {
			return ErrSettlementNoConflict
		}
		return fmt.Errorf("insert idempotency record: %w", err)
	}
	return nil
}
