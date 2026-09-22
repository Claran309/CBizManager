package reporting

import (
	"context"
	"errors"
	"fmt"
	"strconv"
	"strings"

	"CBizDocsManager/backend/internal/document"
	"CBizDocsManager/backend/internal/identity"
	"CBizDocsManager/backend/pkg/bizdate"
	"CBizDocsManager/backend/pkg/money"
	"gorm.io/gorm"
)

type gormRepository struct{ db *gorm.DB }

// NewRepository 创建汇总统计仓储。
func NewRepository(db *gorm.DB) Repository { return &gormRepository{db: db} }

/* ------------------------------------------------------------------ 读取：周期合计 */

// settlementRow 是「单据 + 三类记录合计」的查询结果行。
//
// sale_amount_type 用 COALESCE 转成非空字符串再扫描：入库单这一列本来就是 NULL，
// 直接扫进 string 类型会在 MySQL 与 SQLite 上都报「不能把 NULL 转成 string」，
// 而为了一个可空列把整行改成指针字段又会把后面的聚合逻辑写得到处判空。
type settlementRow struct {
	ID             uint64
	Kind           document.Kind
	SaleAmountType string
	TotalAmount    money.Amount
	Paid           money.Amount
	Invoiced       money.Amount
	Received       money.Amount
}

// LoadSettlements 读取统计周期内每张已提交单据的总额与三类记录合计。
//
// 口径说明：
//   - 只统计 status = submitted 的单据。草稿金额还没定，作废单已经失效，
//     把它们算进「未付款」会让财务对着一个永远付不掉的数字干活。
//   - 付款 / 开票 / 收款合计不按发生日期过滤，取的是这些单据「截至当前」的余额：
//     需求要的是本周期单据的应付 / 应收余额，而不是本周期发生了多少笔流水。
func (r *gormRepository) LoadSettlements(ctx context.Context, groupID uint64, query AggregateQuery) ([]DocumentSettlement, error) {
	statement := strings.Builder{}
	statement.WriteString(`SELECT d.id AS id, d.kind AS kind, COALESCE(d.sale_amount_type, '') AS sale_amount_type,
        d.total_amount AS total_amount,
        COALESCE(p.paid, 0) AS paid, COALESCE(i.invoiced, 0) AS invoiced, COALESCE(rc.received, 0) AS received
    FROM documents d
    LEFT JOIN (SELECT document_id, SUM(amount) AS paid FROM finance_records
               WHERE group_id = ? AND kind = ? GROUP BY document_id) p ON p.document_id = d.id
    LEFT JOIN (SELECT document_id, SUM(amount) AS invoiced FROM finance_records
               WHERE group_id = ? AND kind = ? GROUP BY document_id) i ON i.document_id = d.id
    LEFT JOIN (SELECT document_id, SUM(amount) AS received FROM finance_records
               WHERE group_id = ? AND kind = ? GROUP BY document_id) rc ON rc.document_id = d.id
    WHERE d.group_id = ? AND d.status = ? AND d.business_date >= ? AND d.business_date < ?`)
	args := []any{
		groupID, string(KindPaymentRecord),
		groupID, string(KindInvoiceRecord),
		groupID, string(KindReceiptRecord),
		groupID, string(document.StatusSubmitted), query.PeriodStart, query.PeriodEnd,
	}
	if query.BusinessUserID != 0 {
		statement.WriteString(" AND d.business_user_id = ?")
		args = append(args, query.BusinessUserID)
	}
	statement.WriteString(" ORDER BY d.id ASC")

	var rows []settlementRow
	if err := r.db.WithContext(ctx).Raw(statement.String(), args...).Scan(&rows).Error; err != nil {
		return nil, fmt.Errorf("load document settlements: %w", err)
	}
	result := make([]DocumentSettlement, 0, len(rows))
	for _, row := range rows {
		settlement := DocumentSettlement{
			Kind: row.Kind, TotalAmount: row.TotalAmount,
			Paid: row.Paid, Invoiced: row.Invoiced, Received: row.Received,
		}
		if row.SaleAmountType != "" {
			saleAmountType := document.SaleAmountType(row.SaleAmountType)
			settlement.SaleAmountType = &saleAmountType
		}
		result = append(result, settlement)
	}
	return result, nil
}

// CountParties 统计周期内涉及的进项公司与客户数量（FR-BACK-02 / FR-BACK-03「涉及 N 家」）。
func (r *gormRepository) CountParties(ctx context.Context, groupID uint64, query AggregateQuery) (int64, int64, error) {
	statement := strings.Builder{}
	statement.WriteString(`SELECT d.kind AS kind, COUNT(DISTINCT dp.party_name) AS total
    FROM document_parties dp
    JOIN documents d ON d.id = dp.document_id
    WHERE d.group_id = ? AND d.status = ? AND d.business_date >= ? AND d.business_date < ?`)
	args := []any{groupID, string(document.StatusSubmitted), query.PeriodStart, query.PeriodEnd}
	if query.BusinessUserID != 0 {
		statement.WriteString(" AND d.business_user_id = ?")
		args = append(args, query.BusinessUserID)
	}
	statement.WriteString(" GROUP BY d.kind")

	var rows []struct {
		Kind  document.Kind
		Total int64
	}
	if err := r.db.WithContext(ctx).Raw(statement.String(), args...).Scan(&rows).Error; err != nil {
		return 0, 0, fmt.Errorf("count report parties: %w", err)
	}
	var suppliers, customers int64
	for _, row := range rows {
		switch row.Kind {
		case document.KindInbound:
			suppliers = row.Total
		case document.KindOutbound:
			customers = row.Total
		}
	}
	return suppliers, customers, nil
}

/* ------------------------------------------------------------------ 读取：明细聚合 */

// itemRow 是明细聚合的查询结果行，可空列统一用 COALESCE 转成空串再转换。
type itemRow struct {
	PartyName     string
	ProductName   string
	ProductModel  string
	Unit          string
	DocumentCount int64
	Quantity      money.Quantity
	Amount        money.Amount
}

// LoadItems 分页读取按「往来单位 + 品名 + 型号 + 单位」聚合的明细（FR-BACK-02 / FR-BACK-03）。
func (r *gormRepository) LoadItems(ctx context.Context, groupID uint64, kind document.Kind, query ItemQuery) (ItemPage, error) {
	buildWhere := func() (string, []any) {
		statement := strings.Builder{}
		statement.WriteString(` FROM document_items di
        JOIN documents d ON d.id = di.document_id
        JOIN document_parties dp ON dp.id = di.party_id
        WHERE d.group_id = ? AND d.kind = ? AND d.status = ? AND d.business_date >= ? AND d.business_date < ?`)
		args := []any{groupID, string(kind), string(document.StatusSubmitted), query.PeriodStart, query.PeriodEnd}
		if query.BusinessUserID != 0 {
			statement.WriteString(" AND d.business_user_id = ?")
			args = append(args, query.BusinessUserID)
		}
		if query.PartyKeyword != "" {
			statement.WriteString(" AND dp.party_name LIKE ?")
			args = append(args, "%"+query.PartyKeyword+"%")
		}
		if query.ProductKeyword != "" {
			statement.WriteString(" AND di.product_name LIKE ?")
			args = append(args, "%"+query.ProductKeyword+"%")
		}
		if query.ModelKeyword != "" {
			statement.WriteString(" AND di.product_model LIKE ?")
			args = append(args, "%"+query.ModelKeyword+"%")
		}
		return statement.String(), args
	}
	groupBy := ` GROUP BY dp.party_name, di.product_name, di.product_model, di.unit`

	// 总数用「分组后的行数」而不是明细条数：分页是按聚合行分的，
	// 拿明细条数当总数会让客户端以为还有好几页，实际翻过去全是空页。
	whereClause, whereArgs := buildWhere()
	var total int64
	countSQL := "SELECT COUNT(*) FROM (SELECT 1" + whereClause + groupBy + ") AS grouped_items"
	if err := r.db.WithContext(ctx).Raw(countSQL, whereArgs...).Scan(&total).Error; err != nil {
		return ItemPage{}, fmt.Errorf("count report items: %w", err)
	}

	selectSQL := `SELECT dp.party_name AS party_name, di.product_name AS product_name,
        COALESCE(di.product_model, '') AS product_model, COALESCE(di.unit, '') AS unit,
        COUNT(DISTINCT d.id) AS document_count,
        COALESCE(SUM(di.quantity), 0) AS quantity, COALESCE(SUM(di.amount), 0) AS amount` +
		whereClause + groupBy + ` ORDER BY amount DESC, dp.party_name ASC, di.product_name ASC LIMIT ? OFFSET ?`
	listArgs := append(append([]any{}, whereArgs...), query.PageSize, (query.Page-1)*query.PageSize)

	var rows []itemRow
	if err := r.db.WithContext(ctx).Raw(selectSQL, listArgs...).Scan(&rows).Error; err != nil {
		return ItemPage{}, fmt.Errorf("list report items: %w", err)
	}
	page := ItemPage{Items: make([]ItemTotals, 0, len(rows)), Page: query.Page, PageSize: query.PageSize, Total: total}
	for _, row := range rows {
		item := ItemTotals{
			PartyName: row.PartyName, ProductName: row.ProductName,
			DocumentCount: row.DocumentCount, Quantity: row.Quantity, Amount: row.Amount,
		}
		if row.ProductModel != "" {
			model := row.ProductModel
			item.ProductModel = &model
		}
		if row.Unit != "" {
			unit := row.Unit
			item.Unit = &unit
		}
		page.Items = append(page.Items, item)
	}
	return page, nil
}

/* ------------------------------------------------------------------ 读取：业务员维度 */

// LoadBusinessUserTotals 按业务员分组统计利润与三类销售金额。
//
// 先按「业务员 + 单据类型 + 销售金额类型」在 SQL 里分组，再在 Go 里归并到业务员维度：
// 业务员数量在十位级，多一层的归并成本可以忽略，换来的是不用写一层嵌套子查询。
func (r *gormRepository) LoadBusinessUserTotals(ctx context.Context, groupID uint64, query AggregateQuery) ([]BusinessUserTotals, error) {
	statement := strings.Builder{}
	statement.WriteString(`SELECT d.business_user_id AS business_user_id, d.kind AS kind,
        COALESCE(d.sale_amount_type, '') AS sale_amount_type,
        COUNT(*) AS document_count, COALESCE(SUM(d.total_amount), 0) AS total_amount
    FROM documents d
    WHERE d.group_id = ? AND d.status = ? AND d.business_date >= ? AND d.business_date < ?`)
	args := []any{groupID, string(document.StatusSubmitted), query.PeriodStart, query.PeriodEnd}
	if query.BusinessUserID != 0 {
		statement.WriteString(" AND d.business_user_id = ?")
		args = append(args, query.BusinessUserID)
	}
	statement.WriteString(" GROUP BY d.business_user_id, d.kind, d.sale_amount_type ORDER BY d.business_user_id ASC")

	var rows []struct {
		BusinessUserID uint64
		Kind           document.Kind
		SaleAmountType string
		DocumentCount  int64
		TotalAmount    money.Amount
	}
	if err := r.db.WithContext(ctx).Raw(statement.String(), args...).Scan(&rows).Error; err != nil {
		return nil, fmt.Errorf("load business user totals: %w", err)
	}

	// 保持业务员首次出现的顺序，让同一批数据每次返回的行序稳定
	// （总结算快照的批次号与行序绑定，顺序漂移会让前后两次生成的结果对不上）。
	order := make([]uint64, 0, len(rows))
	byUser := make(map[uint64]*BusinessUserTotals, len(rows))
	for _, row := range rows {
		entry, exists := byUser[row.BusinessUserID]
		if !exists {
			entry = &BusinessUserTotals{BusinessUserID: row.BusinessUserID}
			byUser[row.BusinessUserID] = entry
			order = append(order, row.BusinessUserID)
		}
		entry.DocumentCount += row.DocumentCount
		switch row.Kind {
		case document.KindInbound:
			entry.InboundAmount = entry.InboundAmount.Add(row.TotalAmount)
		case document.KindOutbound:
			entry.OutboundAmount = entry.OutboundAmount.Add(row.TotalAmount)
			switch document.SaleAmountType(row.SaleAmountType) {
			case document.SaleAmountVATSpecial:
				entry.SaleAmountTotals.VATSpecial = entry.SaleAmountTotals.VATSpecial.Add(row.TotalAmount)
			case document.SaleAmountVATGeneral:
				entry.SaleAmountTotals.VATGeneral = entry.SaleAmountTotals.VATGeneral.Add(row.TotalAmount)
			case document.SaleAmountNoInvoice:
				entry.SaleAmountTotals.NoInvoice = entry.SaleAmountTotals.NoInvoice.Add(row.TotalAmount)
			}
		}
	}
	result := make([]BusinessUserTotals, 0, len(order))
	for _, userID := range order {
		result = append(result, *byUser[userID])
	}
	return result, nil
}

/* ------------------------------------------------------------------ 写入：总结算快照 */

// CreateSnapshots 在事务内生成总结算快照。
//
// 单号生成与单据 / 结算模块同一套路：取当月最大序号 + 1，并发撞车靠唯一索引报错后重试，
// 而不是用悲观锁把整张表串行化。
func (r *gormRepository) CreateSnapshots(ctx context.Context, input CreateSnapshotInput) ([]Snapshot, error) {
	if len(input.Candidates) == 0 {
		return nil, ErrPeriodEmpty
	}
	month := bizdate.FormatMonthCompact(input.PeriodStart)
	for attempt := 0; attempt < maxSnapshotNoAttempts; attempt++ {
		created, err := r.tryCreateSnapshots(ctx, input, month)
		if err == nil {
			return created, nil
		}
		if !errors.Is(err, ErrSnapshotNoConflict) {
			return nil, err
		}
	}
	return nil, fmt.Errorf("总结算单号连续 %d 次冲突: %w", maxSnapshotNoAttempts, ErrSnapshotNoConflict)
}

func (r *gormRepository) tryCreateSnapshots(ctx context.Context, input CreateSnapshotInput, month string) ([]Snapshot, error) {
	var created []Snapshot
	err := r.db.WithContext(ctx).Transaction(func(tx *gorm.DB) error {
		tx = tx.WithContext(ctx)

		sequence, err := nextSnapshotSequence(tx, input.GroupID, month)
		if err != nil {
			return err
		}
		// 批次号取本批第一张快照的单号：单号本身唯一，用它当批次号既不用额外生成规则，
		// 也能让「这次生成产出了哪几张」一眼可见。
		batchNo := formatSnapshotNo(month, sequence)

		created = make([]Snapshot, 0, len(input.Candidates))
		for index, candidate := range input.Candidates {
			snapshot := Snapshot{
				GroupID:    input.GroupID,
				SnapshotNo: formatSnapshotNo(month, sequence+index),
				BatchNo:    batchNo,
				Scope:      candidate.Scope,
				PeriodStart: input.PeriodStart, PeriodEnd: input.PeriodEnd,
				BusinessUserID: candidate.BusinessUserID, BusinessUserName: candidate.BusinessUserName,

				InboundAmount:  candidate.InboundAmount,
				OutboundAmount: candidate.OutboundAmount,
				GrossProfit:    candidate.GrossProfit,
				GrossMarginPPM: candidate.GrossMarginPPM,

				VATSpecialAmount: candidate.VATSpecialAmount,
				VATGeneralAmount: candidate.VATGeneralAmount,
				NoInvoiceAmount:  candidate.NoInvoiceAmount,

				DocumentCount: candidate.DocumentCount, Remark: candidate.Remark,
				CreatedBy: input.OperatorUserID, CreatedAt: input.Now,
			}
			if err := tx.Create(&snapshot).Error; err != nil {
				if errors.Is(err, gorm.ErrDuplicatedKey) {
					return ErrSnapshotNoConflict
				}
				return fmt.Errorf("insert report snapshot: %w", err)
			}
			created = append(created, snapshot)
		}

		// 审计逐张写：审计查询要能按单号定位到「这张总结算单是谁生成的」，
		// 整批只写一条会让业务员维度的多张单只剩一个笼统的批次记录。
		for _, snapshot := range created {
			if err := appendSnapshotAudit(tx, input.GroupID, input.OperatorUserID, snapshot); err != nil {
				return err
			}
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	return created, nil
}

// nextSnapshotSequence 取当月「组」内最大序号 + 1。
// 只用 MAX 而不是 COUNT：总结算快照只增不删，但用 MAX 可以避免以后引入删除后序号被复用。
func nextSnapshotSequence(tx *gorm.DB, groupID uint64, month string) (int, error) {
	var latest string
	err := tx.Model(&Snapshot{}).
		Select("snapshot_no").
		Where("group_id = ? AND snapshot_no LIKE ?", groupID, snapshotNoLikePattern(month)).
		Order("snapshot_no DESC").Limit(1).
		Scan(&latest).Error
	if err != nil {
		return 0, fmt.Errorf("load latest report snapshot no: %w", err)
	}
	sequence := sequenceFromSnapshotNo(latest) + 1
	if sequence > 9999 {
		return 0, fmt.Errorf("当月总结算单号已用尽")
	}
	return sequence, nil
}

// appendSnapshotAudit 追加审计日志，摘要由仓储在拿到单号后统一拼装。
func appendSnapshotAudit(tx *gorm.DB, groupID, userID uint64, snapshot Snapshot) error {
	target := snapshot.Scope.Label()
	if snapshot.BusinessUserName != nil && *snapshot.BusinessUserName != "" {
		target = fmt.Sprintf("%s %s", snapshot.Scope.Label(), *snapshot.BusinessUserName)
	}
	summary := fmt.Sprintf("总结算单 %s %s 生成", snapshot.SnapshotNo, target)
	err := tx.Table("audit_logs").Create(map[string]any{
		"group_id": groupID, "operator_user_id": userID, "action": "report.summary_settlement.generated",
		"resource_type": "report_snapshot", "resource_id": strconv.FormatUint(snapshot.ID, 10),
		"summary": summary, "created_at": snapshot.CreatedAt,
	}).Error
	if err != nil {
		return fmt.Errorf("append report snapshot audit: %w", err)
	}
	return nil
}

/* ------------------------------------------------------------------ 读取：总结算快照 */

// ListSnapshots 分页查询总结算快照。
func (r *gormRepository) ListSnapshots(ctx context.Context, groupID uint64, query SnapshotQuery) (SnapshotPage, error) {
	db := r.db.WithContext(ctx)
	// 每次重建查询条件：GORM 的链式查询被 Count 复用后继续 Find 容易串到旧条件。
	buildQuery := func() *gorm.DB {
		statement := db.Model(&Snapshot{}).Where("group_id = ?", groupID)
		if query.PeriodStart != nil {
			statement = statement.Where("period_start >= ?", *query.PeriodStart)
		}
		if query.PeriodEnd != nil {
			statement = statement.Where("period_start < ?", *query.PeriodEnd)
		}
		if query.Scope != nil {
			statement = statement.Where("scope = ?", string(*query.Scope))
		}
		if query.BusinessUserID != nil {
			statement = statement.Where("business_user_id = ?", *query.BusinessUserID)
		}
		return statement
	}

	var total int64
	if err := buildQuery().Count(&total).Error; err != nil {
		return SnapshotPage{}, fmt.Errorf("count report snapshots: %w", err)
	}

	var snapshots []Snapshot
	offset := (query.Page - 1) * query.PageSize
	if err := buildQuery().Order("period_start DESC").Order("id DESC").
		Offset(offset).Limit(query.PageSize).Find(&snapshots).Error; err != nil {
		return SnapshotPage{}, fmt.Errorf("list report snapshots: %w", err)
	}
	return SnapshotPage{
		Items: snapshots, Page: query.Page, PageSize: query.PageSize, Total: total,
	}, nil
}

// FindSnapshot 按组读取一张总结算快照。
func (r *gormRepository) FindSnapshot(ctx context.Context, groupID, snapshotID uint64) (Snapshot, error) {
	var snapshot Snapshot
	err := r.db.WithContext(ctx).Where("id = ? AND group_id = ?", snapshotID, groupID).Take(&snapshot).Error
	if errors.Is(err, gorm.ErrRecordNotFound) {
		return Snapshot{}, ErrSnapshotNotFound
	}
	if err != nil {
		return Snapshot{}, fmt.Errorf("find report snapshot: %w", err)
	}
	return snapshot, nil
}

/* ------------------------------------------------------------------ 用户摘要 */

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

/* ------------------------------------------------------------------ 常量 */

// finance_records.kind 的取值。汇总模块只读这张表，按 kind 过滤时用这里的常量，
// 不 import finance 包：财务模块改一个枚举名不应该牵动汇总统计的编译。
const (
	KindPaymentRecord = "payment"
	KindReceiptRecord = "receipt"
	KindInvoiceRecord = "invoice"
)
