package reporting

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"time"

	"CBizDocsManager/backend/internal/authorization"
	"CBizDocsManager/backend/internal/document"
	"CBizDocsManager/backend/internal/identity"
	"CBizDocsManager/backend/pkg/apperror"
	"CBizDocsManager/backend/pkg/money"
)

var (
	// ErrSnapshotNotFound 表示总结算快照不存在或不属于当前组。
	ErrSnapshotNotFound = errors.New("report snapshot not found")
	// ErrPeriodEmpty 表示统计周期内没有任何已提交单据，无法生成有意义的总结算。
	ErrPeriodEmpty = errors.New("report period has no submitted document")
	// ErrSnapshotNoConflict 表示总结算单号并发撞车（由仓储重试）。
	ErrSnapshotNoConflict = errors.New("report snapshot no conflict")
)

// Repository 是汇总统计模块的存储接口。所有方法都必须带 group_id 条件，保证组间数据隔离。
type Repository interface {
	// LoadSettlements 读取统计周期内每张单据的总额与三类记录合计，用于在内存里聚合。
	LoadSettlements(ctx context.Context, groupID uint64, query AggregateQuery) ([]DocumentSettlement, error)
	// CountParties 统计周期内涉及的进项公司与客户数量。
	CountParties(ctx context.Context, groupID uint64, query AggregateQuery) (supplierCount, customerCount int64, err error)
	// LoadItems 分页读取按「往来单位 + 品名 + 型号 + 单位」聚合的明细。
	LoadItems(ctx context.Context, groupID uint64, kind document.Kind, query ItemQuery) (ItemPage, error)
	// LoadBusinessUserTotals 按业务员分组统计利润。
	LoadBusinessUserTotals(ctx context.Context, groupID uint64, query AggregateQuery) ([]BusinessUserTotals, error)
	// CreateSnapshots 在事务内生成总结算快照（单号、批次号、审计）。
	CreateSnapshots(ctx context.Context, input CreateSnapshotInput) ([]Snapshot, error)
	// ListSnapshots 分页查询总结算快照。
	ListSnapshots(ctx context.Context, groupID uint64, query SnapshotQuery) (SnapshotPage, error)
	// FindSnapshot 读取一张总结算快照。
	FindSnapshot(ctx context.Context, groupID, snapshotID uint64) (Snapshot, error)
	// LoadUsers 返回用户摘要，避免 Service 直接依赖 identity 仓储。
	LoadUsers(ctx context.Context, ids []uint64) (map[uint64]identity.UserSummary, error)
}

// Service 承载汇总统计的业务规则：权限、周期解析、指标推导与总结算快照生成。
type Service struct {
	repo       Repository
	authorizer authorization.Authorizer
	now        func() time.Time
}

// NewService 创建汇总统计服务。
func NewService(repo Repository, authorizer authorization.Authorizer) *Service {
	return &Service{repo: repo, authorizer: authorizer, now: time.Now}
}

/* ------------------------------------------------------------------ 查询 */

// Overview 返回后台数据汇总看板（FR-BACK-01 / FR-BACK-02 / FR-BACK-03 的合计指标）。
func (s *Service) Overview(ctx context.Context, principal identity.Principal, query PeriodQuery) (*OverviewData, error) {
	scope, err := s.resolveScope(ctx, principal)
	if err != nil {
		return nil, err
	}
	period, aggregate, err := s.normalizedAggregate(query.Period, query.BusinessUserID)
	if err != nil {
		return nil, err
	}
	totals, err := s.periodTotals(ctx, scope.groupID, aggregate)
	if err != nil {
		return nil, err
	}
	return buildOverviewData(period, totals), nil
}

// InboundStats 返回入库统计：单据粒度的合计块 + 明细粒度的分页表格（FR-BACK-02）。
func (s *Service) InboundStats(ctx context.Context, principal identity.Principal, query ItemStatsQuery) (*InboundStatsData, error) {
	scope, err := s.resolveScope(ctx, principal)
	if err != nil {
		return nil, err
	}
	period, aggregate, itemQuery, err := s.normalizedItemQuery(query)
	if err != nil {
		return nil, err
	}
	totals, err := s.periodTotals(ctx, scope.groupID, aggregate)
	if err != nil {
		return nil, err
	}
	page, err := s.repo.LoadItems(ctx, scope.groupID, document.KindInbound, itemQuery)
	if err != nil {
		return nil, mapRepositoryError("load inbound items", err)
	}
	items, pageNo, pageSize, total := toItemPageData(page)
	return &InboundStatsData{
		Period: period,

		DocumentCount:    totals.InboundDocuments,
		AmountTotal:      totals.InboundAmount,
		AmountTotalUpper: upperOf(totals.InboundAmount),

		PaidAmount:          totals.Paid,
		UnpaidAmount:        totals.Unpaid(),
		UnpaidAmountUpper:   upperOf(totals.Unpaid()),
		UnpaidDocumentCount: totals.UnpaidDocuments,

		InvoicedAmount:          totals.Invoiced,
		UninvoicedAmount:        totals.Uninvoiced(),
		UninvoicedAmountUpper:   upperOf(totals.Uninvoiced()),
		UninvoicedDocumentCount: totals.UninvoicedDocuments,

		SupplierCount: totals.SupplierCount,

		Items: items, Page: pageNo, PageSize: pageSize, Total: total,
	}, nil
}

// OutboundStats 返回出库统计：单据粒度的合计块 + 三类销售金额分项 + 明细分页表格（FR-BACK-03）。
func (s *Service) OutboundStats(ctx context.Context, principal identity.Principal, query ItemStatsQuery) (*OutboundStatsData, error) {
	scope, err := s.resolveScope(ctx, principal)
	if err != nil {
		return nil, err
	}
	period, aggregate, itemQuery, err := s.normalizedItemQuery(query)
	if err != nil {
		return nil, err
	}
	totals, err := s.periodTotals(ctx, scope.groupID, aggregate)
	if err != nil {
		return nil, err
	}
	page, err := s.repo.LoadItems(ctx, scope.groupID, document.KindOutbound, itemQuery)
	if err != nil {
		return nil, mapRepositoryError("load outbound items", err)
	}
	items, pageNo, pageSize, total := toItemPageData(page)
	return &OutboundStatsData{
		Period: period,

		DocumentCount:    totals.OutboundDocuments,
		AmountTotal:      totals.OutboundAmount,
		AmountTotalUpper: upperOf(totals.OutboundAmount),

		ReceivedAmount:          totals.Received,
		UnreceivedAmount:        totals.Unreceived(),
		UnreceivedAmountUpper:   upperOf(totals.Unreceived()),
		UnreceivedDocumentCount: totals.UnreceivedDocuments,

		CustomerCount: totals.CustomerCount,

		SaleAmountTypes: saleAmountTypeData(totals.SaleAmountTotals),

		Items: items, Page: pageNo, PageSize: pageSize, Total: total,
	}, nil
}

// BusinessUsers 返回按业务员分组的利润统计（FR-BACK-05「支持查看业务员利润统计」）。
//
// 与总结算快照的区别：这里永远是实时数据，不冻结；需要冻结数值时走生成总结算。
func (s *Service) BusinessUsers(ctx context.Context, principal identity.Principal, query BusinessUserQuery) (*BusinessUserReportData, error) {
	scope, err := s.resolveScope(ctx, principal)
	if err != nil {
		return nil, err
	}
	period, aggregate, err := s.normalizedAggregate(query.Period, 0)
	if err != nil {
		return nil, err
	}
	rows, err := s.repo.LoadBusinessUserTotals(ctx, scope.groupID, aggregate)
	if err != nil {
		return nil, mapRepositoryError("load business user totals", err)
	}

	ids := make([]uint64, 0, len(rows))
	for _, row := range rows {
		ids = append(ids, row.BusinessUserID)
	}
	users, err := s.repo.LoadUsers(ctx, ids)
	if err != nil {
		return nil, mapRepositoryError("load business users", err)
	}

	result := &BusinessUserReportData{Period: period, Items: make([]BusinessUserSummaryData, 0, len(rows))}
	var inboundTotal, outboundTotal money.Amount
	var documentCount int64
	for _, row := range rows {
		grossProfit := row.GrossProfit()
		result.Items = append(result.Items, BusinessUserSummaryData{
			BusinessUser:     withID(users[row.BusinessUserID], row.BusinessUserID),
			InboundAmount:    row.InboundAmount,
			OutboundAmount:   row.OutboundAmount,
			GrossProfit:      grossProfit,
			GrossProfitUpper: upperOf(grossProfit),
			DocumentCount:    row.DocumentCount,
		})
		inboundTotal = inboundTotal.Add(row.InboundAmount)
		outboundTotal = outboundTotal.Add(row.OutboundAmount)
		documentCount += row.DocumentCount
	}
	summaryProfit := outboundTotal.Sub(inboundTotal)
	result.Summary = BusinessUserTotalsData{
		InboundAmount:    inboundTotal,
		OutboundAmount:   outboundTotal,
		GrossProfit:      summaryProfit,
		GrossProfitUpper: upperOf(summaryProfit),
		DocumentCount:    documentCount,
	}
	return result, nil
}

// ListSnapshots 分页查询总结算快照。
func (s *Service) ListSnapshots(ctx context.Context, principal identity.Principal, query SnapshotListQuery) (*SnapshotPageData, error) {
	scope, err := s.resolveScope(ctx, principal)
	if err != nil {
		return nil, err
	}
	page, pageSize, err := normalizePagination(query.Page, query.PageSize)
	if err != nil {
		return nil, apperror.ErrValidationFailed
	}
	repositoryQuery := SnapshotQuery{Page: page, PageSize: pageSize}
	if strings.TrimSpace(query.Period) != "" {
		_, start, end, err := normalizePeriod(query.Period, s.now())
		if err != nil {
			return nil, apperror.ErrValidationFailed
		}
		repositoryQuery.PeriodStart, repositoryQuery.PeriodEnd = &start, &end
	}
	if strings.TrimSpace(string(query.Scope)) != "" {
		parsed, ok := ParseScope(strings.TrimSpace(string(query.Scope)))
		if !ok {
			return nil, apperror.ErrValidationFailed
		}
		repositoryQuery.Scope = &parsed
	}
	if query.BusinessUserID != 0 {
		businessUser := query.BusinessUserID
		repositoryQuery.BusinessUserID = &businessUser
	}

	result, err := s.repo.ListSnapshots(ctx, scope.groupID, repositoryQuery)
	if err != nil {
		return nil, mapRepositoryError("list report snapshots", err)
	}
	items, err := s.snapshotDataList(ctx, result.Items)
	if err != nil {
		return nil, err
	}
	return &SnapshotPageData{Items: items, Page: result.Page, PageSize: result.PageSize, Total: result.Total}, nil
}

// GetSnapshot 读取一张总结算快照。
func (s *Service) GetSnapshot(ctx context.Context, principal identity.Principal, snapshotID uint64) (*SnapshotData, error) {
	scope, err := s.resolveScope(ctx, principal)
	if err != nil {
		return nil, err
	}
	if snapshotID == 0 {
		return nil, apperror.ErrValidationFailed
	}
	snapshot, err := s.repo.FindSnapshot(ctx, scope.groupID, snapshotID)
	if err != nil {
		return nil, mapRepositoryError("find report snapshot", err)
	}
	items, err := s.snapshotDataList(ctx, []Snapshot{snapshot})
	if err != nil {
		return nil, err
	}
	return &items[0], nil
}

/* ------------------------------------------------------------------ 生成总结算 */

// CreateSnapshots 生成月度总结算快照（FR-BACK-05）。
func (s *Service) CreateSnapshots(ctx context.Context, principal identity.Principal, request CreateSnapshotRequest) (*CreateSnapshotData, error) {
	scope, err := s.resolveScope(ctx, principal)
	if err != nil {
		return nil, err
	}
	reportScope, ok := ParseScope(strings.TrimSpace(request.Scope))
	if !ok {
		return nil, apperror.ErrValidationFailed
	}
	period, aggregate, err := s.normalizedAggregate(request.Period, 0)
	if err != nil {
		return nil, err
	}
	remark, err := normalizeRemark(request.Remark)
	if err != nil {
		return nil, apperror.ErrValidationFailed
	}

	candidates, err := s.buildCandidates(ctx, scope.groupID, reportScope, request.BusinessUserID, aggregate, remark)
	if err != nil {
		return nil, err
	}
	if len(candidates) == 0 {
		return nil, apperror.ErrReportPeriodEmpty
	}

	created, err := s.repo.CreateSnapshots(ctx, CreateSnapshotInput{
		GroupID: scope.groupID, PeriodStart: aggregate.PeriodStart, PeriodEnd: aggregate.PeriodEnd,
		Candidates: candidates, OperatorUserID: principal.UserID, Now: s.now().UTC(),
	})
	if err != nil {
		return nil, mapRepositoryError("create report snapshots", err)
	}

	items, err := s.snapshotDataList(ctx, created)
	if err != nil {
		return nil, err
	}
	batchNo := ""
	if len(created) > 0 {
		batchNo = created[0].BatchNo
	}
	return &CreateSnapshotData{BatchNo: batchNo, Period: period, Snapshots: items}, nil
}

// buildCandidates 组装本次要写入的全部快照候选。
func (s *Service) buildCandidates(
	ctx context.Context,
	groupID uint64,
	reportScope Scope,
	businessUserID uint64,
	aggregate AggregateQuery,
	remark *string,
) ([]SnapshotCandidate, error) {
	switch reportScope {
	case ScopeCompany:
		totals, err := s.periodTotals(ctx, groupID, aggregate)
		if err != nil {
			return nil, err
		}
		if totals.InboundDocuments == 0 && totals.OutboundDocuments == 0 {
			return nil, apperror.ErrReportPeriodEmpty
		}
		return []SnapshotCandidate{companyCandidate(totals, remark)}, nil

	case ScopeBusinessUser:
		if businessUserID != 0 {
			query := aggregate
			query.BusinessUserID = businessUserID
			totals, err := s.periodTotals(ctx, groupID, query)
			if err != nil {
				return nil, err
			}
			if totals.InboundDocuments == 0 && totals.OutboundDocuments == 0 {
				return nil, apperror.ErrReportPeriodEmpty
			}
			users, err := s.repo.LoadUsers(ctx, []uint64{businessUserID})
			if err != nil {
				return nil, mapRepositoryError("load business user", err)
			}
			user := businessUserID
			name := withID(users[businessUserID], businessUserID).DisplayName
			return []SnapshotCandidate{businessUserCandidate(user, name, totals)}, nil
		}

		rows, err := s.repo.LoadBusinessUserTotals(ctx, groupID, aggregate)
		if err != nil {
			return nil, mapRepositoryError("load business user totals", err)
		}
		if len(rows) == 0 {
			return nil, apperror.ErrReportPeriodEmpty
		}
		ids := make([]uint64, 0, len(rows))
		for _, row := range rows {
			ids = append(ids, row.BusinessUserID)
		}
		users, err := s.repo.LoadUsers(ctx, ids)
		if err != nil {
			return nil, mapRepositoryError("load business users", err)
		}
		candidates := make([]SnapshotCandidate, 0, len(rows))
		for _, row := range rows {
			name := withID(users[row.BusinessUserID], row.BusinessUserID).DisplayName
			candidates = append(candidates, candidateOf(
				ScopeBusinessUser, &row.BusinessUserID, nameOrNil(name),
				row.InboundAmount, row.OutboundAmount, row.SaleAmountTotals, row.DocumentCount, remark,
			))
		}
		return candidates, nil

	default:
		return nil, apperror.ErrValidationFailed
	}
}

// companyCandidate 由公司维度周期合计构造快照候选。
func companyCandidate(totals PeriodTotals, remark *string) SnapshotCandidate {
	return candidateOf(
		ScopeCompany, nil, nil,
		totals.InboundAmount, totals.OutboundAmount, totals.SaleAmountTotals,
		totals.InboundDocuments+totals.OutboundDocuments, remark,
	)
}

// businessUserCandidate 由业务员维度周期合计构造快照候选。
func businessUserCandidate(businessUserID uint64, businessUserName string, totals PeriodTotals) SnapshotCandidate {
	return candidateOf(
		ScopeBusinessUser, &businessUserID, nameOrNil(businessUserName),
		totals.InboundAmount, totals.OutboundAmount, totals.SaleAmountTotals,
		totals.InboundDocuments+totals.OutboundDocuments, nil,
	)
}

// candidateOf 由基础金额构造一张快照候选。
//
// 毛利润与毛利率只在服务端这一处计算，避免「快照生成」与「实时看板」两条路径
// 各写一遍扣减逻辑而慢慢漂移。
func candidateOf(
	reportScope Scope,
	businessUserID *uint64,
	businessUserName *string,
	inboundAmount, outboundAmount money.Amount,
	saleAmountTotals SaleAmountTotals,
	documentCount int64,
	remark *string,
) SnapshotCandidate {
	grossProfit := outboundAmount.Sub(inboundAmount)
	return SnapshotCandidate{
		Scope: reportScope, BusinessUserID: businessUserID, BusinessUserName: businessUserName,

		InboundAmount:  inboundAmount,
		OutboundAmount: outboundAmount,
		GrossProfit:    grossProfit,
		GrossMarginPPM: ppmRatio(grossProfit, outboundAmount),

		VATSpecialAmount: saleAmountTotals.VATSpecial,
		VATGeneralAmount: saleAmountTotals.VATGeneral,
		NoInvoiceAmount:  saleAmountTotals.NoInvoice,

		DocumentCount: documentCount,
		Remark:        remark,
	}
}

/* ------------------------------------------------------------------ 权限与数据范围 */

// scope 描述当前身份在汇总统计模块中的可见范围。
//
// 与单据 / 财务模块不同，汇总统计只有「看全组」一种数据范围，不存在「只看本人」：
// 需求把「汇总」定义为一项独立的子账号权限（FR 4.2「配置子账号的查看、编辑、汇总及账号管理权限」），
// 拿到它的人本来就应该看到全组数据。业务员看自己的月度数据走单据模块的 /monthly-summary，
// 那条路径不需要汇总权限，也不会因为这里收紧而被堵住。
type scope struct {
	groupID uint64
}

// resolveScope 校验身份并检查汇总权限。
//
// 这里对「没有 report.view 权限」直接抛 403，而不是像单据数据范围那样返回空结果：
// 汇总接口整个就是权限本身，没有权限的人访问它属于越权；
// 返回空报表会让人以为「本月确实没有数据」，比明确拒绝更容易造成误判。
func (s *Service) resolveScope(ctx context.Context, principal identity.Principal) (scope, error) {
	if principal.GroupID == nil || principal.AccountType == identity.AccountTypePlatformAdmin {
		return scope{}, apperror.ErrForbidden
	}
	if principal.MustChangePassword {
		return scope{}, apperror.ErrAuthPasswordChangeRequired
	}
	groupID := *principal.GroupID
	if principal.AccountType == identity.AccountTypeGroupOwner && principal.MemberType == "owner" {
		// 主账号默认拥有组内全部业务与管理权限，其中包含汇总查看。
		return scope{groupID: groupID}, nil
	}
	if principal.AccountType != identity.AccountTypeMember || principal.MemberType != "member" {
		return scope{}, apperror.ErrForbidden
	}
	// 汇总权限复用 report.view：需求里「汇总」是一项整体能力，
	// 查看看板与生成总结算同属其中，不拆成两个权限码以免出现「能看汇总却不能生成」的权限空洞
	// （与财务模块「登记与撤销共用 finance.record」的取舍一致）。
	if err := s.authorizer.Require(ctx, principal, groupID, authorization.PermissionReportView); err != nil {
		return scope{}, err
	}
	return scope{groupID: groupID}, nil
}

/* ------------------------------------------------------------------ 内部工具 */

// normalizedAggregate 解析周期与业务员筛选，产出仓储查询条件。
func (s *Service) normalizedAggregate(rawPeriod string, businessUserID uint64) (string, AggregateQuery, error) {
	period, start, end, err := normalizePeriod(rawPeriod, s.now())
	if err != nil {
		return "", AggregateQuery{}, apperror.ErrValidationFailed
	}
	return period, AggregateQuery{PeriodStart: start, PeriodEnd: end, BusinessUserID: businessUserID}, nil
}

// normalizedItemQuery 在 normalizedAggregate 基础上追加字段查询与分页。
func (s *Service) normalizedItemQuery(query ItemStatsQuery) (string, AggregateQuery, ItemQuery, error) {
	period, aggregate, err := s.normalizedAggregate(query.Period, query.BusinessUserID)
	if err != nil {
		return "", AggregateQuery{}, ItemQuery{}, err
	}
	party, err := normalizeKeyword(query.PartyName)
	if err != nil {
		return "", AggregateQuery{}, ItemQuery{}, apperror.ErrValidationFailed
	}
	product, err := normalizeKeyword(query.ProductName)
	if err != nil {
		return "", AggregateQuery{}, ItemQuery{}, apperror.ErrValidationFailed
	}
	model, err := normalizeKeyword(query.ProductModel)
	if err != nil {
		return "", AggregateQuery{}, ItemQuery{}, apperror.ErrValidationFailed
	}
	page, pageSize, err := normalizePagination(query.Page, query.PageSize)
	if err != nil {
		return "", AggregateQuery{}, ItemQuery{}, apperror.ErrValidationFailed
	}
	return period, aggregate, ItemQuery{
		AggregateQuery: aggregate,
		PartyKeyword:   party, ProductKeyword: product, ModelKeyword: model,
		Page: page, PageSize: pageSize,
	}, nil
}

// periodTotals 读取逐单结清关系并聚合出周期合计。
func (s *Service) periodTotals(ctx context.Context, groupID uint64, query AggregateQuery) (PeriodTotals, error) {
	rows, err := s.repo.LoadSettlements(ctx, groupID, query)
	if err != nil {
		return PeriodTotals{}, mapRepositoryError("load settlements", err)
	}
	totals := newPeriodTotals(rows)
	suppliers, customers, err := s.repo.CountParties(ctx, groupID, query)
	if err != nil {
		return PeriodTotals{}, mapRepositoryError("count report parties", err)
	}
	totals.SupplierCount, totals.CustomerCount = suppliers, customers
	return totals, nil
}

// snapshotDataList 批量补齐快照的创建人与业务员摘要，避免逐张回查。
func (s *Service) snapshotDataList(ctx context.Context, snapshots []Snapshot) ([]SnapshotData, error) {
	ids := make([]uint64, 0, len(snapshots)*2)
	for _, snapshot := range snapshots {
		ids = append(ids, snapshot.CreatedBy)
		if snapshot.BusinessUserID != nil {
			ids = append(ids, *snapshot.BusinessUserID)
		}
	}
	users, err := s.repo.LoadUsers(ctx, ids)
	if err != nil {
		return nil, mapRepositoryError("load report users", err)
	}
	items := make([]SnapshotData, 0, len(snapshots))
	for _, snapshot := range snapshots {
		var businessUser identity.UserSummary
		if snapshot.BusinessUserID != nil {
			businessUser = withID(users[*snapshot.BusinessUserID], *snapshot.BusinessUserID)
			// 姓名优先用快照里冻结的那一份：用户事后改名不应该改写历史报表的抬头。
			if snapshot.BusinessUserName != nil && *snapshot.BusinessUserName != "" {
				businessUser.DisplayName = *snapshot.BusinessUserName
			}
		}
		items = append(items, toSnapshotData(snapshot, withID(users[snapshot.CreatedBy], snapshot.CreatedBy), businessUser))
	}
	return items, nil
}

// withID 保证用户摘要里始终带 ID：LoadUsers 查不到人（已注销）时也要能显示「谁」。
func withID(summary identity.UserSummary, id uint64) identity.UserSummary {
	if summary.ID == 0 {
		summary.ID = id
	}
	return summary
}

// nameOrNil 把空姓名转成 nil，避免快照里写入空字符串。
func nameOrNil(name string) *string {
	if strings.TrimSpace(name) == "" {
		return nil
	}
	return &name
}

func mapRepositoryError(operation string, err error) error {
	switch {
	case errors.Is(err, ErrSnapshotNotFound):
		return apperror.ErrReportSnapshotNotFound
	case errors.Is(err, ErrPeriodEmpty):
		return apperror.ErrReportPeriodEmpty
	default:
		return apperror.Wrap(apperror.ErrInternal, fmt.Errorf("%s: %w", operation, err))
	}
}
