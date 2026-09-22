package document

import (
	"context"
	"errors"
	"fmt"
	"strconv"
	"strings"
	"time"

	"CBizDocsManager/backend/internal/identity"
	"CBizDocsManager/backend/pkg/money"
	"gorm.io/gorm"
	"gorm.io/gorm/clause"
)

// maxDocumentNoAttempts 限制单号并发撞车后的重试次数。
const maxDocumentNoAttempts = 5

type gormRepository struct{ db *gorm.DB }

// NewRepository 创建单据仓储。
func NewRepository(db *gorm.DB) Repository { return &gormRepository{db: db} }

/* ------------------------------------------------------------------ 写操作 */

// CreateDocument 创建单据。单号由服务端按「组 + 类型 + 业务日期」生成，
// 并发撞车时依赖唯一索引报错并重试，而不是用悲观锁把整张表串行化。
func (r *gormRepository) CreateDocument(ctx context.Context, input CreateInput) (Document, bool, error) {
	for attempt := 0; attempt < maxDocumentNoAttempts; attempt++ {
		document, replayed, err := r.tryCreateDocument(ctx, input)
		if err == nil {
			return document, replayed, nil
		}
		if !errors.Is(err, ErrDocumentNoConflict) {
			return Document{}, false, err
		}
	}
	return Document{}, false, ErrDocumentNoConflict
}

func (r *gormRepository) tryCreateDocument(ctx context.Context, input CreateInput) (Document, bool, error) {
	var created Document
	var replayed bool
	err := r.db.WithContext(ctx).Transaction(func(tx *gorm.DB) error {
		tx = tx.WithContext(ctx)

		// 1) 幂等重放：同一个 key 且内容指纹一致，直接返回首次创建的单据。
		if input.IdempotencyKey != "" {
			existing, hit, err := replayDocument(tx, input.GroupID, input.OperatorUserID, input.IdempotencyScope, input.IdempotencyKey, input.RequestFingerprint, input.Kind)
			if err != nil {
				return err
			}
			if hit {
				created, replayed = existing, true
				return nil
			}
		}

		// 2) 生成当日单号。
		sequence, err := nextDocumentSequence(tx, input.GroupID, input.Kind, input.BusinessDate)
		if err != nil {
			return err
		}
		document := Document{
			GroupID: input.GroupID, Kind: input.Kind, DocumentNo: formatDocumentNo(input.Kind, input.BusinessDate, sequence),
			Status: input.Status, BusinessUserID: input.BusinessUserID, BusinessDate: input.BusinessDate,
			ShippingUnit: input.ShippingUnit, SaleAmountType: input.SaleAmountType, TotalAmount: input.TotalAmount,
			Remark: input.Remark, Version: 1, CreatedBy: input.OperatorUserID, UpdatedBy: input.OperatorUserID,
		}
		if input.Status == StatusSubmitted {
			now := time.Now().UTC()
			document.SubmittedAt = &now
		}
		if err := tx.Create(&document).Error; err != nil {
			if errors.Is(err, gorm.ErrDuplicatedKey) {
				return ErrDocumentNoConflict
			}
			return fmt.Errorf("insert document: %w", err)
		}

		// 3) 往来单位与明细。
		if err := insertParties(tx, document, input.Parties); err != nil {
			return err
		}

		// 4) 幂等记录与审计。
		if input.IdempotencyKey != "" {
			if err := insertIdempotencyRecord(tx, input.GroupID, input.OperatorUserID, input.IdempotencyScope, input.IdempotencyKey, input.RequestFingerprint, "document", document.ID, input.Now); err != nil {
				return err
			}
		}
		if err := appendDocumentAudit(tx, input.GroupID, input.OperatorUserID, input.AuditAction, document, input.AuditSummary, input.Now); err != nil {
			return err
		}
		created = document
		return nil
	})
	if err != nil {
		return Document{}, false, err
	}
	return created, replayed, nil
}

// ReplaceDocument 整体替换单据内容。
//
// 明细采用「删除后重建」而不是逐行 diff：单据明细条数少（一期默认 5 行、上限 200 行），
// 重建能让序号连续、SQL 简单，也避免客户端提交的行 ID 与服务端错位。
func (r *gormRepository) ReplaceDocument(ctx context.Context, input UpdateInput) (Document, error) {
	var result Document
	err := r.db.WithContext(ctx).Transaction(func(tx *gorm.DB) error {
		tx = tx.WithContext(ctx)

		if input.IdempotencyKey != "" {
			existing, hit, err := replayDocument(tx, input.GroupID, input.OperatorUserID, input.IdempotencyScope, input.IdempotencyKey, input.RequestFingerprint, input.Kind)
			if err != nil {
				return err
			}
			if hit {
				result = existing
				return nil
			}
		}

		current, err := findDocumentLocked(tx, input.GroupID, input.Kind, input.DocumentID)
		if err != nil {
			return err
		}
		if current.Version != input.ExpectedVersion {
			return ErrVersionConflict
		}
		if current.Status == StatusVoided {
			return ErrStatusInvalid
		}

		now := input.Now
		update := tx.Model(&Document{}).
			Where("id = ? AND group_id = ? AND version = ?", input.DocumentID, input.GroupID, input.ExpectedVersion).
			Updates(map[string]any{
				"status": input.Status, "business_user_id": input.BusinessUserID, "business_date": input.BusinessDate,
				"shipping_unit": input.ShippingUnit, "sale_amount_type": input.SaleAmountType,
				"total_amount": input.TotalAmount, "remark": input.Remark,
				"updated_by": input.OperatorUserID, "updated_at": now, "version": gorm.Expr("version + 1"),
			})
		if update.Error != nil {
			if errors.Is(update.Error, gorm.ErrDuplicatedKey) {
				return ErrVersionConflict
			}
			return fmt.Errorf("update document: %w", update.Error)
		}
		if update.RowsAffected != 1 {
			return ErrVersionConflict
		}

		if err := tx.Where("document_id = ?", input.DocumentID).Delete(&Item{}).Error; err != nil {
			return fmt.Errorf("delete document items: %w", err)
		}
		if err := tx.Where("document_id = ?", input.DocumentID).Delete(&Party{}).Error; err != nil {
			return fmt.Errorf("delete document parties: %w", err)
		}
		repository := Document{
			ID: input.DocumentID, GroupID: input.GroupID, Kind: input.Kind, DocumentNo: current.DocumentNo,
		}
		if err := insertParties(tx, repository, input.Parties); err != nil {
			return err
		}
		if input.IdempotencyKey != "" {
			if err := insertIdempotencyRecord(tx, input.GroupID, input.OperatorUserID, input.IdempotencyScope, input.IdempotencyKey, input.RequestFingerprint, "document", input.DocumentID, input.Now); err != nil {
				return err
			}
		}
		auditTarget := repository
		auditTarget.DocumentNo = current.DocumentNo
		if err := appendDocumentAudit(tx, input.GroupID, input.OperatorUserID, "document.updated", auditTarget, input.AuditSummary, input.Now); err != nil {
			return err
		}

		current.Status = input.Status
		current.BusinessUserID = input.BusinessUserID
		current.BusinessDate = input.BusinessDate
		current.ShippingUnit = input.ShippingUnit
		current.SaleAmountType = input.SaleAmountType
		current.TotalAmount = input.TotalAmount
		current.Remark = input.Remark
		current.UpdatedBy = input.OperatorUserID
		current.UpdatedAt = now
		current.Version = input.ExpectedVersion + 1
		result = current
		return nil
	})
	if err != nil {
		return Document{}, err
	}
	return result, nil
}

// ChangeStatus 变更单据状态（提交 / 作废），并写入审计。
func (r *gormRepository) ChangeStatus(ctx context.Context, input StatusInput) (Document, error) {
	var result Document
	err := r.db.WithContext(ctx).Transaction(func(tx *gorm.DB) error {
		tx = tx.WithContext(ctx)

		current, err := findDocumentLocked(tx, input.GroupID, input.Kind, input.DocumentID)
		if err != nil {
			return err
		}
		if current.Version != input.ExpectedVersion {
			return ErrVersionConflict
		}
		if current.Status == input.Status {
			// 同状态重复操作属于客户端乱序重放，返回冲突让上层重新拉取最新状态。
			return ErrStatusInvalid
		}

		updates := map[string]any{
			"status": input.Status, "updated_by": input.OperatorUserID,
			"updated_at": input.Now, "version": gorm.Expr("version + 1"),
		}
		if input.Status == StatusSubmitted {
			updates["submitted_at"] = input.Now
		}
		update := tx.Model(&Document{}).
			Where("id = ? AND group_id = ? AND version = ?", input.DocumentID, input.GroupID, input.ExpectedVersion).
			Updates(updates)
		if update.Error != nil {
			return fmt.Errorf("update document status: %w", update.Error)
		}
		if update.RowsAffected != 1 {
			return ErrVersionConflict
		}
		if err := appendDocumentAudit(tx, input.GroupID, input.OperatorUserID, input.AuditAction, current, input.AuditSummary, input.Now); err != nil {
			return err
		}

		current.Status = input.Status
		current.UpdatedBy = input.OperatorUserID
		current.UpdatedAt = input.Now
		current.Version = input.ExpectedVersion + 1
		if input.Status == StatusSubmitted {
			submitted := input.Now
			current.SubmittedAt = &submitted
		}
		result = current
		return nil
	})
	if err != nil {
		return Document{}, err
	}
	return result, nil
}

/* ------------------------------------------------------------------ 读操作 */

// FindDocument 按组 + 类型读取单据主表。
func (r *gormRepository) FindDocument(ctx context.Context, groupID uint64, kind Kind, id uint64) (Document, error) {
	return findDocument(r.db.WithContext(ctx), groupID, kind, id)
}

// LoadDetail 读取单据详情（主表 + 往来单位 + 明细），固定 3 条查询，避免 N+1。
func (r *gormRepository) LoadDetail(ctx context.Context, groupID uint64, kind Kind, id uint64) (Detail, error) {
	db := r.db.WithContext(ctx)
	document, err := findDocument(db, groupID, kind, id)
	if err != nil {
		return Detail{}, err
	}
	parties, err := loadParties(db, document.ID)
	if err != nil {
		return Detail{}, err
	}
	items, err := loadItems(db, document.ID)
	if err != nil {
		return Detail{}, err
	}
	itemsByParty := make(map[uint64][]Item, len(parties))
	for _, item := range items {
		itemsByParty[item.PartyID] = append(itemsByParty[item.PartyID], item)
	}
	detail := Detail{Document: document, Parties: make([]PartyWithItems, 0, len(parties))}
	for _, party := range parties {
		groupItems := itemsByParty[party.ID]
		if groupItems == nil {
			groupItems = []Item{}
		}
		detail.Parties = append(detail.Parties, PartyWithItems{Party: party, Items: groupItems})
	}
	return detail, nil
}

// ListDocuments 分页查询单据列表，附带往来单位名称与明细条数，避免客户端逐行再查。
func (r *gormRepository) ListDocuments(ctx context.Context, groupID uint64, kind Kind, query RepositoryQuery) (Page, error) {
	db := r.db.WithContext(ctx)
	// 每次重建查询条件：GORM 的链式查询被 Count 复用后继续 Find 容易串到旧条件。
	buildQuery := func() *gorm.DB {
		statement := db.Model(&Document{}).Where("documents.group_id = ? AND documents.kind = ?", groupID, kind)
		if query.Status != nil {
			statement = statement.Where("documents.status = ?", *query.Status)
		}
		if query.MonthStart != nil {
			statement = statement.Where("documents.business_date >= ?", *query.MonthStart)
		}
		if query.MonthEnd != nil {
			statement = statement.Where("documents.business_date < ?", *query.MonthEnd)
		}
		if query.BusinessUserID != nil {
			statement = statement.Where("documents.business_user_id = ?", *query.BusinessUserID)
		}
		if query.OnlyBusinessUserID != 0 {
			statement = statement.Where("documents.business_user_id = ?", query.OnlyBusinessUserID)
		}
		if keyword := strings.TrimSpace(query.Keyword); keyword != "" {
			like := "%" + keyword + "%"
			statement = statement.Where(
				"documents.document_no LIKE ? OR EXISTS (SELECT 1 FROM document_parties dp WHERE dp.document_id = documents.id AND dp.party_name LIKE ?)",
				like, like)
		}
		return statement
	}

	var total int64
	if err := buildQuery().Count(&total).Error; err != nil {
		return Page{}, fmt.Errorf("count documents: %w", err)
	}

	var documents []Document
	offset := (query.Page - 1) * query.PageSize
	if err := buildQuery().Order("documents.business_date DESC").Order("documents.id DESC").
		Offset(offset).Limit(query.PageSize).Find(&documents).Error; err != nil {
		return Page{}, fmt.Errorf("list documents: %w", err)
	}

	page := Page{Items: []DocumentSummary{}, Page: query.Page, PageSize: query.PageSize, Total: total}
	if len(documents) == 0 {
		return page, nil
	}

	ids := make([]uint64, 0, len(documents))
	userIDs := make([]uint64, 0, len(documents))
	for _, document := range documents {
		ids = append(ids, document.ID)
		userIDs = append(userIDs, document.BusinessUserID)
	}
	partyNames, err := loadPartyNames(db, ids)
	if err != nil {
		return Page{}, err
	}
	itemCounts, err := loadItemCounts(db, ids)
	if err != nil {
		return Page{}, err
	}
	users, err := r.LoadUsers(ctx, userIDs)
	if err != nil {
		return Page{}, err
	}

	for _, document := range documents {
		businessName := ""
		if user, ok := users[document.BusinessUserID]; ok {
			businessName = user.DisplayName
		}
		names := partyNames[document.ID]
		if names == nil {
			names = []string{}
		}
		page.Items = append(page.Items, DocumentSummary{
			Document: document, PartyNames: names, ItemCount: itemCounts[document.ID],
			BusinessName: businessName, BusinessUserID: document.BusinessUserID,
		})
	}
	return page, nil
}

// MonthlyTotals 统计月度汇总：单据数、状态分布、有效金额合计，以及按往来单位的前 N 名。
func (r *gormRepository) MonthlyTotals(ctx context.Context, groupID uint64, kind Kind, query SummaryQuery) (MonthlyTotals, error) {
	db := r.db.WithContext(ctx)
	start := query.Month
	end := start.AddDate(0, 1, 0)
	buildBase := func() *gorm.DB {
		statement := db.Model(&Document{}).
			Where("documents.group_id = ? AND documents.kind = ? AND documents.business_date >= ? AND documents.business_date < ?", groupID, kind, start, end)
		if query.OnlyBusinessUserID != 0 {
			statement = statement.Where("documents.business_user_id = ?", query.OnlyBusinessUserID)
		}
		return statement
	}

	var counts struct {
		DocumentCount int64
		VoidedCount   int64
	}
	if err := buildBase().
		Select("COUNT(*) AS document_count, SUM(CASE WHEN documents.status = ? THEN 1 ELSE 0 END) AS voided_count", string(StatusVoided)).
		Scan(&counts).Error; err != nil {
		return MonthlyTotals{}, fmt.Errorf("count monthly documents: %w", err)
	}

	// 作废单据不计入业务金额，但计入单据数与状态分布。
	var effective struct{ TotalAmount money.Amount }
	if err := buildBase().Where("documents.status <> ?", StatusVoided).
		Select("COALESCE(SUM(documents.total_amount), 0) AS total_amount").
		Scan(&effective).Error; err != nil {
		return MonthlyTotals{}, fmt.Errorf("sum monthly amount: %w", err)
	}

	result := MonthlyTotals{
		DocumentCount: counts.DocumentCount,
		VoidedCount:   counts.VoidedCount,
		TotalAmount:   effective.TotalAmount,
	}
	result.DraftCount, result.SubmittedCnt = 0, 0
	var statusRows []struct {
		Status Status
		Total  int64
	}
	if err := buildBase().Select("documents.status AS status, COUNT(*) AS total").Group("documents.status").Scan(&statusRows).Error; err != nil {
		return MonthlyTotals{}, fmt.Errorf("count monthly status: %w", err)
	}
	for _, row := range statusRows {
		switch row.Status {
		case StatusDraft:
			result.DraftCount = row.Total
		case StatusSubmitted:
			result.SubmittedCnt = row.Total
		case StatusVoided:
			result.VoidedCount = row.Total
		}
	}

	bucketSize := query.BucketSize
	if bucketSize < 1 {
		bucketSize = 20
	}
	var partyRows []struct {
		PartyName     string
		DocumentCount int64
		TotalAmount   money.Amount
	}
	partyQuery := db.Table("document_parties AS dp").
		Joins("JOIN documents AS d ON d.id = dp.document_id").
		Where("dp.group_id = ? AND d.kind = ? AND d.status <> ? AND d.business_date >= ? AND d.business_date < ?",
			groupID, kind, StatusVoided, start, end)
	if query.OnlyBusinessUserID != 0 {
		partyQuery = partyQuery.Where("d.business_user_id = ?", query.OnlyBusinessUserID)
	}
	if err := partyQuery.
		Select("dp.party_name AS party_name, COUNT(DISTINCT dp.document_id) AS document_count, COALESCE(SUM(dp.subtotal), 0) AS total_amount").
		Group("dp.party_name").Order("total_amount DESC").Limit(bucketSize).
		Scan(&partyRows).Error; err != nil {
		return MonthlyTotals{}, fmt.Errorf("sum monthly parties: %w", err)
	}
	result.Parties = make([]PartyTotals, 0, len(partyRows))
	for _, row := range partyRows {
		result.Parties = append(result.Parties, PartyTotals{PartyName: row.PartyName, DocumentCount: row.DocumentCount, TotalAmount: row.TotalAmount})
	}
	return result, nil
}

// LoadUsers 读取业务员摘要（用户表属于身份模块，这里只做只读聚合）。
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

// ActiveMemberExists 判断用户是否为该组的有效成员。
func (r *gormRepository) ActiveMemberExists(ctx context.Context, groupID, userID uint64) (bool, error) {
	var count int64
	if err := r.db.WithContext(ctx).Table("memberships").
		Where("group_id = ? AND user_id = ? AND status = ?", groupID, userID, "active").
		Count(&count).Error; err != nil {
		return false, fmt.Errorf("count memberships: %w", err)
	}
	return count > 0, nil
}

/* ------------------------------------------------------------------ 内部工具 */

func findDocument(db *gorm.DB, groupID uint64, kind Kind, id uint64) (Document, error) {
	var document Document
	err := db.Where("id = ? AND group_id = ? AND kind = ?", id, groupID, kind).Take(&document).Error
	if errors.Is(err, gorm.ErrRecordNotFound) {
		return Document{}, ErrNotFound
	}
	if err != nil {
		return Document{}, fmt.Errorf("find document: %w", err)
	}
	return document, nil
}

func findDocumentLocked(tx *gorm.DB, groupID uint64, kind Kind, id uint64) (Document, error) {
	var document Document
	err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).
		Where("id = ? AND group_id = ? AND kind = ?", id, groupID, kind).Take(&document).Error
	if errors.Is(err, gorm.ErrRecordNotFound) {
		return Document{}, ErrNotFound
	}
	if err != nil {
		return Document{}, fmt.Errorf("find document for update: %w", err)
	}
	return document, nil
}

func loadParties(db *gorm.DB, documentID uint64) ([]Party, error) {
	var parties []Party
	if err := db.Where("document_id = ?", documentID).Order("position ASC").Order("id ASC").Find(&parties).Error; err != nil {
		return nil, fmt.Errorf("load document parties: %w", err)
	}
	return parties, nil
}

func loadItems(db *gorm.DB, documentID uint64) ([]Item, error) {
	var items []Item
	if err := db.Where("document_id = ?", documentID).Order("party_id ASC").Order("position ASC").Order("id ASC").Find(&items).Error; err != nil {
		return nil, fmt.Errorf("load document items: %w", err)
	}
	return items, nil
}

func loadPartyNames(db *gorm.DB, documentIDs []uint64) (map[uint64][]string, error) {
	var rows []struct {
		DocumentID uint64
		PartyName  string
	}
	if err := db.Table("document_parties").
		Select("document_id, party_name").
		Where("document_id IN ?", documentIDs).
		Order("document_id ASC").Order("position ASC").
		Scan(&rows).Error; err != nil {
		return nil, fmt.Errorf("load party names: %w", err)
	}
	result := make(map[uint64][]string, len(documentIDs))
	for _, row := range rows {
		result[row.DocumentID] = append(result[row.DocumentID], row.PartyName)
	}
	return result, nil
}

func loadItemCounts(db *gorm.DB, documentIDs []uint64) (map[uint64]int, error) {
	var rows []struct {
		DocumentID uint64
		Total      int64
	}
	if err := db.Table("document_items").
		Select("document_id, COUNT(*) AS total").
		Where("document_id IN ?", documentIDs).
		Group("document_id").
		Scan(&rows).Error; err != nil {
		return nil, fmt.Errorf("load item counts: %w", err)
	}
	result := make(map[uint64]int, len(rows))
	for _, row := range rows {
		result[row.DocumentID] = int(row.Total)
	}
	return result, nil
}

// nextDocumentSequence 取当日「组 + 类型」最大序号 + 1。
// 只用 MAX 而不是 COUNT，避免作废单据被删除后序号被复用。
func nextDocumentSequence(tx *gorm.DB, groupID uint64, kind Kind, businessDate time.Time) (int, error) {
	var latest string
	err := tx.Model(&Document{}).
		Select("document_no").
		Where("group_id = ? AND kind = ? AND document_no LIKE ?", groupID, kind, documentNoLikePattern(kind, businessDate)).
		Order("document_no DESC").Limit(1).
		Scan(&latest).Error
	if err != nil {
		return 0, fmt.Errorf("load latest document no: %w", err)
	}
	sequence := sequenceFromDocumentNo(latest) + 1
	if sequence > 9999 {
		return 0, fmt.Errorf("当日单号已用尽")
	}
	return sequence, nil
}

func insertParties(tx *gorm.DB, document Document, parties []PartyDraft) error {
	for _, partyDraft := range parties {
		party := Party{
			GroupID: document.GroupID, DocumentID: document.ID, Position: partyDraft.Position,
			PartyName: partyDraft.PartyName, ContactPhone: partyDraft.ContactPhone,
			DictionaryEntryID: partyDraft.DictionaryEntryID, Subtotal: partyDraft.Subtotal,
		}
		if err := tx.Create(&party).Error; err != nil {
			return fmt.Errorf("insert document party: %w", err)
		}
		for _, itemDraft := range partyDraft.Items {
			item := Item{
				GroupID: document.GroupID, DocumentID: document.ID, PartyID: party.ID, Position: itemDraft.Position,
				ProductName: itemDraft.ProductName, ProductModel: itemDraft.ProductModel, Unit: itemDraft.Unit,
				Quantity: itemDraft.Quantity, Weight: itemDraft.Weight, UnitPrice: itemDraft.UnitPrice,
				PriceTaxMode: itemDraft.PriceTaxMode, Amount: itemDraft.Amount, Remark: itemDraft.Remark,
			}
			if err := tx.Create(&item).Error; err != nil {
				return fmt.Errorf("insert document item: %w", err)
			}
		}
	}
	return nil
}

// appendDocumentAudit 追加审计日志；kindLabel 与单号由仓储统一拼装，保证各入口文案一致。
func appendDocumentAudit(tx *gorm.DB, groupID, userID uint64, action string, document Document, summary string, now time.Time) error {
	text := fmt.Sprintf("%s %s %s", kindLabel(document.Kind), document.DocumentNo, summary)
	err := tx.Table("audit_logs").Create(map[string]any{
		"group_id": groupID, "operator_user_id": userID, "action": action,
		"resource_type": "document", "resource_id": strconv.FormatUint(document.ID, 10),
		"summary": text, "created_at": now,
	}).Error
	if err != nil {
		return fmt.Errorf("append document audit: %w", err)
	}
	return nil
}

/* ------------------------------------------------------------------ 幂等记录 */

// idempotencyRecord 对应 idempotency_records 表。
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

// replayDocument 查幂等记录并返回既有单据；指纹不一致时返回 ErrIdempotencyMismatch。
func replayDocument(tx *gorm.DB, groupID, userID uint64, scope, key, fingerprint string, kind Kind) (Document, bool, error) {
	var record idempotencyRecord
	err := tx.Where("group_id = ? AND user_id = ? AND scope = ? AND idempotency_key = ?", groupID, userID, scope, key).
		Take(&record).Error
	if errors.Is(err, gorm.ErrRecordNotFound) {
		return Document{}, false, nil
	}
	if err != nil {
		return Document{}, false, fmt.Errorf("find idempotency record: %w", err)
	}
	if record.RequestFingerprint != fingerprint {
		return Document{}, false, ErrIdempotencyMismatch
	}
	documentID, err := strconv.ParseUint(record.ResourceID, 10, 64)
	if err != nil {
		return Document{}, false, fmt.Errorf("parse idempotency resource id: %w", err)
	}
	document, err := findDocument(tx, groupID, kind, documentID)
	if err != nil {
		return Document{}, false, err
	}
	return document, true, nil
}

func insertIdempotencyRecord(tx *gorm.DB, groupID, userID uint64, scope, key, fingerprint, resourceType string, resourceID uint64, now time.Time) error {
	record := idempotencyRecord{
		GroupID: groupID, UserID: userID, Scope: scope, IdempotencyKey: key,
		RequestFingerprint: fingerprint, ResourceType: resourceType,
		ResourceID: strconv.FormatUint(resourceID, 10), CreatedAt: now,
	}
	if err := tx.Create(&record).Error; err != nil {
		// 唯一键冲突说明同一请求被并发重放，交给上层按冲突处理即可。
		if errors.Is(err, gorm.ErrDuplicatedKey) {
			return ErrDocumentNoConflict
		}
		return fmt.Errorf("insert idempotency record: %w", err)
	}
	return nil
}
