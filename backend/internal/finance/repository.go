package finance

import (
	"context"
	"errors"
	"fmt"
	"strconv"
	"strings"
	"time"

	"CBizDocsManager/backend/internal/document"
	"CBizDocsManager/backend/internal/identity"
	"CBizDocsManager/backend/pkg/money"
	"gorm.io/gorm"
	"gorm.io/gorm/clause"
)

// maxIdempotencyAttempts 限制「同一幂等键并发重放」撞唯一索引后的重试次数。
const maxIdempotencyAttempts = 3

// errIdempotencyConflict 表示幂等记录撞唯一索引：说明同一请求被并发重放，
// 重试一次就能读到首次写入的结果，因此不对外暴露。
var errIdempotencyConflict = errors.New("idempotency record conflict")

type gormRepository struct{ db *gorm.DB }

// NewRepository 创建财务仓储。
func NewRepository(db *gorm.DB) Repository { return &gormRepository{db: db} }

/* ------------------------------------------------------------------ 写操作 */

// CreateRecord 登记一条财务记录。
//
// 「累计不得超过单据总额」必须在事务里、并锁住目标单据行来校验：
// 只在 Service 里做前置校验会在并发下被绕过（两笔同时读到「已付 0」）。
// 单据行锁把同一张单据上的并发登记串行化，事务内的 SUM 才是可信的。
func (r *gormRepository) CreateRecord(ctx context.Context, input CreateInput) (Record, error) {
	for attempt := 0; attempt < maxIdempotencyAttempts; attempt++ {
		record, err := r.tryCreateRecord(ctx, input)
		if err == nil {
			return record, nil
		}
		if !errors.Is(err, errIdempotencyConflict) {
			return Record{}, err
		}
	}
	return Record{}, errIdempotencyConflict
}

func (r *gormRepository) tryCreateRecord(ctx context.Context, input CreateInput) (Record, error) {
	var created Record
	err := r.db.WithContext(ctx).Transaction(func(tx *gorm.DB) error {
		tx = tx.WithContext(ctx)

		// 1) 锁住目标单据。锁的不是财务记录表，而是单据行本身：
		//    同一张单据上的并发登记会在这里排队，SUM 因此不会读到过期数据。
		target, err := findDocumentLocked(tx, input.GroupID, input.DocumentID)
		if err != nil {
			return err
		}
		// 2) 事务内复检单据状态与类型：Service 的校验可能已被并发改动作废。
		if target.Kind != input.DocumentKind {
			return ErrDocumentMismatch
		}
		if target.Status != document.StatusSubmitted {
			return ErrDocumentStatusInvalid
		}
		// 3) 记录类型与单据类型的配对联检（入库单只接受付款 / 开票，出库单只接受收款）。
		//    服务层已经查过一次，这里再查一次是因为「挂错单据」的记录不会出现在任何
		//    一个结清视图里（例如把收款挂到入库单上），等于凭空丢了一笔钱，
		//    代价远高于一次整数比较。
		if input.Kind.DocumentKind() != target.Kind {
			return ErrDocumentMismatch
		}

		// 4) 幂等重放：同一个 key 且内容指纹一致，直接返回首次写入的记录。
		if input.IdempotencyKey != "" {
			existing, hit, err := replayRecord(tx, input.GroupID, input.OperatorUserID, input.IdempotencyScope, input.IdempotencyKey, input.RequestFingerprint)
			if err != nil {
				return err
			}
			if hit {
				created = existing
				return nil
			}
		}

		// 5) 累计上限：已有的同类记录合计 + 本次金额不得超过单据总额。
		accumulated, err := sumRecords(tx, input.GroupID, input.DocumentID, input.Kind)
		if err != nil {
			return err
		}
		if accumulated.Add(input.Amount) > target.TotalAmount {
			return ErrAmountExceeds
		}

		record := Record{
			GroupID: input.GroupID, DocumentID: input.DocumentID, DocumentKind: input.DocumentKind,
			DocumentNo: input.DocumentNo, PartyName: input.PartyName,
			BusinessUserID: input.BusinessUserID, BusinessDate: input.BusinessDate,
			Kind: input.Kind, Amount: input.Amount, OccurredOn: input.OccurredOn,
			Method: input.Method, MethodNote: input.MethodNote, CardTail: input.CardTail,
			InvoiceNo: input.InvoiceNo, Remark: input.Remark,
			CreatedBy: input.OperatorUserID,
			// 显式使用注入时钟，保证审计时间与记录时间一致、且测试可预期。
			CreatedAt: input.Now,
		}
		if err := tx.Create(&record).Error; err != nil {
			return fmt.Errorf("insert finance record: %w", err)
		}

		// 6) 幂等记录与审计。
		if input.IdempotencyKey != "" {
			if err := insertIdempotencyRecord(tx, input.GroupID, input.OperatorUserID,
				input.IdempotencyScope, input.IdempotencyKey, input.RequestFingerprint, record.ID, input.Now); err != nil {
				return err
			}
		}
		if err := appendAudit(tx, input.GroupID, input.OperatorUserID, input.AuditAction, record.ID, input.AuditSummary, input.Now); err != nil {
			return err
		}
		created = record
		return nil
	})
	if err != nil {
		return Record{}, err
	}
	return created, nil
}

// RevokeRecord 撤销一条财务记录。
//
// 采用硬删除 + 审计：财务记录是可无限重录的派生数据，纠错时把错的那条删掉、
// 重新录一条正确的，语义比「软删除 + 标记作废」更清晰；操作痕迹由 audit_logs 承担。
func (r *gormRepository) RevokeRecord(ctx context.Context, input RevokeInput) (Record, error) {
	var revoked Record
	err := r.db.WithContext(ctx).Transaction(func(tx *gorm.DB) error {
		tx = tx.WithContext(ctx)

		current, err := findRecord(tx, input.GroupID, input.RecordID)
		if err != nil {
			return err
		}
		// 锁住单据行，避免撤销与登记并发时出现「超额」判断失效。
		if _, err := findDocumentLocked(tx, input.GroupID, current.DocumentID); err != nil {
			return err
		}
		if err := tx.Where("id = ? AND group_id = ?", input.RecordID, input.GroupID).
			Delete(&Record{}).Error; err != nil {
			return fmt.Errorf("delete finance record: %w", err)
		}
		// 同步清掉指向这条记录的幂等记录：硬删除的语义是「这笔记录从未存在过」，
		// 如果留着幂等记录，客户端重放同一个 key 会读到一条已经不存在的记录，
		// 对外表现为难以理解的 404。清掉之后重放会重新登记，语义才自洽。
		if err := tx.Where("group_id = ? AND resource_type = ? AND resource_id = ?",
			input.GroupID, "finance_record", strconv.FormatUint(current.ID, 10)).
			Delete(&idempotencyRecord{}).Error; err != nil {
			return fmt.Errorf("delete finance idempotency record: %w", err)
		}
		if err := appendAudit(tx, input.GroupID, input.OperatorUserID, input.AuditAction, current.ID, input.AuditSummary, input.Now); err != nil {
			return err
		}
		revoked = current
		return nil
	})
	if err != nil {
		return Record{}, err
	}
	return revoked, nil
}

/* ------------------------------------------------------------------ 读操作 */

// FindRecord 按组读取一条财务记录。
func (r *gormRepository) FindRecord(ctx context.Context, groupID, recordID uint64) (Record, error) {
	return findRecord(r.db.WithContext(ctx), groupID, recordID)
}

// ListRecords 分页查询财务记录。
func (r *gormRepository) ListRecords(ctx context.Context, groupID uint64, query RepositoryQuery) (Page, error) {
	db := r.db.WithContext(ctx)
	// 每次重建查询条件：GORM 的链式查询被 Count 复用后继续 Find 容易串到旧条件。
	buildQuery := func() *gorm.DB {
		statement := db.Model(&Record{}).Where("finance_records.group_id = ?", groupID).
			Where("finance_records.kind = ?", query.Kind)
		if query.DocumentID != 0 {
			statement = statement.Where("finance_records.document_id = ?", query.DocumentID)
		}
		if query.Method != nil {
			statement = statement.Where("finance_records.method = ?", *query.Method)
		}
		if query.OccurredFrom != nil {
			statement = statement.Where("finance_records.occurred_on >= ?", *query.OccurredFrom)
		}
		if query.OccurredTo != nil {
			statement = statement.Where("finance_records.occurred_on < ?", *query.OccurredTo)
		}
		if query.BusinessUserID != nil {
			statement = statement.Where("finance_records.business_user_id = ?", *query.BusinessUserID)
		}
		if query.OnlyBusinessUserID != 0 {
			statement = statement.Where("finance_records.business_user_id = ?", query.OnlyBusinessUserID)
		}
		if keyword := strings.TrimSpace(query.Keyword); keyword != "" {
			like := "%" + keyword + "%"
			statement = statement.Where("finance_records.document_no LIKE ? OR finance_records.party_name LIKE ?", like, like)
		}
		return statement
	}

	var total int64
	if err := buildQuery().Count(&total).Error; err != nil {
		return Page{}, fmt.Errorf("count finance records: %w", err)
	}

	var records []Record
	offset := (query.Page - 1) * query.PageSize
	if err := buildQuery().
		Order("finance_records.occurred_on DESC").Order("finance_records.id DESC").
		Offset(offset).Limit(query.PageSize).Find(&records).Error; err != nil {
		return Page{}, fmt.Errorf("list finance records: %w", err)
	}

	page := Page{Items: []Summary{}, Page: query.Page, PageSize: query.PageSize, Total: total}
	for _, record := range records {
		page.Items = append(page.Items, Summary{Record: record})
	}
	return page, nil
}

// LoadDocument 读取目标单据的当前状态，并带出首个往来单位名称。
func (r *gormRepository) LoadDocument(ctx context.Context, groupID, documentID uint64) (TargetDocument, error) {
	db := r.db.WithContext(ctx)
	target, err := findDocument(db, groupID, documentID)
	if err != nil {
		return TargetDocument{}, err
	}
	var partyName string
	// 财务列表与审计摘要只展示「主往来单位」；一张单据有多个公司时按 position 取第一个。
	if err := db.Table("document_parties").
		Select("party_name").
		Where("group_id = ? AND document_id = ?", groupID, documentID).
		Order("position ASC").Limit(1).Scan(&partyName).Error; err != nil {
		return TargetDocument{}, fmt.Errorf("load document party name: %w", err)
	}
	target.PartyName = partyName
	return target, nil
}

// LoadStatement 读取单张单据的结清情况：单据本体 + 全部财务记录。
func (r *gormRepository) LoadStatement(ctx context.Context, groupID, documentID uint64) (Statement, error) {
	db := r.db.WithContext(ctx)
	target, err := r.LoadDocument(ctx, groupID, documentID)
	if err != nil {
		return Statement{}, err
	}
	var records []Record
	if err := db.Where("group_id = ? AND document_id = ?", groupID, documentID).
		Order("occurred_on ASC").Order("id ASC").Find(&records).Error; err != nil {
		return Statement{}, fmt.Errorf("load finance records: %w", err)
	}
	return Statement{Document: target, Records: records}, nil
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

func findRecord(db *gorm.DB, groupID, recordID uint64) (Record, error) {
	var record Record
	err := db.Where("id = ? AND group_id = ?", recordID, groupID).Take(&record).Error
	if errors.Is(err, gorm.ErrRecordNotFound) {
		return Record{}, ErrRecordNotFound
	}
	if err != nil {
		return Record{}, fmt.Errorf("find finance record: %w", err)
	}
	return record, nil
}

// findDocument 读取单据本体（不含往来单位名称）。
func findDocument(db *gorm.DB, groupID, documentID uint64) (TargetDocument, error) {
	var record document.Document
	err := db.Where("id = ? AND group_id = ?", documentID, groupID).Take(&record).Error
	if errors.Is(err, gorm.ErrRecordNotFound) {
		return TargetDocument{}, ErrDocumentNotFound
	}
	if err != nil {
		return TargetDocument{}, fmt.Errorf("find target document: %w", err)
	}
	return TargetDocument{
		ID: record.ID, Kind: record.Kind, DocumentNo: record.DocumentNo, Status: record.Status,
		BusinessUserID: record.BusinessUserID, BusinessDate: record.BusinessDate, TotalAmount: record.TotalAmount,
	}, nil
}

// findDocumentLocked 加行锁读取单据，用于串行化同一张单据上的并发登记。
func findDocumentLocked(tx *gorm.DB, groupID, documentID uint64) (TargetDocument, error) {
	var record document.Document
	err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).
		Where("id = ? AND group_id = ?", documentID, groupID).Take(&record).Error
	if errors.Is(err, gorm.ErrRecordNotFound) {
		return TargetDocument{}, ErrDocumentNotFound
	}
	if err != nil {
		return TargetDocument{}, fmt.Errorf("find target document for update: %w", err)
	}
	return TargetDocument{
		ID: record.ID, Kind: record.Kind, DocumentNo: record.DocumentNo, Status: record.Status,
		BusinessUserID: record.BusinessUserID, BusinessDate: record.BusinessDate, TotalAmount: record.TotalAmount,
	}, nil
}

// sumRecords 统计某张单据上某一类记录的金额合计。
func sumRecords(tx *gorm.DB, groupID, documentID uint64, kind Kind) (money.Amount, error) {
	var total money.Amount
	err := tx.Model(&Record{}).
		Select("COALESCE(SUM(amount), 0)").
		Where("group_id = ? AND document_id = ? AND kind = ?", groupID, documentID, kind).
		Scan(&total).Error
	if err != nil {
		return 0, fmt.Errorf("sum finance records: %w", err)
	}
	return total, nil
}

// appendAudit 追加审计日志，动作形如 finance.payment.recorded。
func appendAudit(tx *gorm.DB, groupID, userID uint64, action string, recordID uint64, summary string, now time.Time) error {
	err := tx.Table("audit_logs").Create(map[string]any{
		"group_id": groupID, "operator_user_id": userID, "action": action,
		"resource_type": "finance_record", "resource_id": strconv.FormatUint(recordID, 10),
		"summary": summary, "created_at": now,
	}).Error
	if err != nil {
		return fmt.Errorf("append finance audit: %w", err)
	}
	return nil
}

/* ------------------------------------------------------------------ 幂等记录 */

// idempotencyRecord 对应 idempotency_records 表（与单据 / 结算模块共用同一张表，用 scope 区分场景）。
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

// replayRecord 查幂等记录并返回既有财务记录；指纹不一致时返回 ErrIdempotencyMismatch。
func replayRecord(tx *gorm.DB, groupID, userID uint64, scope, key, fingerprint string) (Record, bool, error) {
	var record idempotencyRecord
	err := tx.Where("group_id = ? AND user_id = ? AND scope = ? AND idempotency_key = ?", groupID, userID, scope, key).
		Take(&record).Error
	if errors.Is(err, gorm.ErrRecordNotFound) {
		return Record{}, false, nil
	}
	if err != nil {
		return Record{}, false, fmt.Errorf("find idempotency record: %w", err)
	}
	if record.RequestFingerprint != fingerprint {
		return Record{}, false, ErrIdempotencyMismatch
	}
	recordID, err := strconv.ParseUint(record.ResourceID, 10, 64)
	if err != nil {
		return Record{}, false, fmt.Errorf("parse idempotency resource id: %w", err)
	}
	existing, err := findRecord(tx, groupID, recordID)
	if err != nil {
		return Record{}, false, err
	}
	return existing, true, nil
}

func insertIdempotencyRecord(tx *gorm.DB, groupID, userID uint64, scope, key, fingerprint string, recordID uint64, now time.Time) error {
	record := idempotencyRecord{
		GroupID: groupID, UserID: userID, Scope: scope, IdempotencyKey: key,
		RequestFingerprint: fingerprint, ResourceType: "finance_record",
		ResourceID: strconv.FormatUint(recordID, 10), CreatedAt: now,
	}
	if err := tx.Create(&record).Error; err != nil {
		// 唯一键冲突说明同一请求被并发重放，交给上层重试后走幂等命中分支。
		if errors.Is(err, gorm.ErrDuplicatedKey) {
			return errIdempotencyConflict
		}
		return fmt.Errorf("insert idempotency record: %w", err)
	}
	return nil
}
