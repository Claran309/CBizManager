//go:build integration

package integration

import (
	"context"
	"testing"
	"time"

	"CBizDocsManager/backend/internal/authorization"
	"CBizDocsManager/backend/internal/document"
	"CBizDocsManager/backend/internal/finance"
	"CBizDocsManager/backend/internal/identity"
	"CBizDocsManager/backend/internal/member"
	"CBizDocsManager/backend/internal/organization"
	"CBizDocsManager/backend/internal/reporting"
	"CBizDocsManager/backend/pkg/apperror"
)

// TestReportingFlow 用真实 MySQL 覆盖汇总统计与月度总结算主链路：
//
//	看板聚合口径（只算已提交 / 余额不按发生日期过滤 / 未结清逐单比较）
//	→ 入库与出库统计的「单据级合计 + 明细级分页」两层口径 → 三类销售金额分项
//	→ 业务员维度利润统计 → 总结算快照的生成 / 序号 / 批次号 / 审计
//	→ 快照冻结语义 → 列表过滤与分页 → 权限收敛与跨组隔离。
//
// 之所以必须走真实方言：DECIMAL(18,2) 的回读精度、SUM 聚合、透视排序列
// 以及「取当月最大序号 + 1」都要真实 MySQL 才能覆盖；SQLite 内存桩无法体现这些语义。
func TestReportingFlow(t *testing.T) {
	db := openAuthFlowMySQL(t)
	ctx := context.Background()
	passwords := identity.NewPasswordManager()

	ownerHash, err := passwords.Hash("report-owner-password")
	if err != nil {
		t.Fatalf("hash owner password: %v", err)
	}
	memberHash, err := passwords.Hash("report-member-password")
	if err != nil {
		t.Fatalf("hash member password: %v", err)
	}
	outsiderHash, err := passwords.Hash("report-outsider-password")
	if err != nil {
		t.Fatalf("hash outsider password: %v", err)
	}

	ownerUser := identity.User{
		Username: "report-owner", PasswordHash: ownerHash, DisplayName: "汇总主账号",
		AccountType: identity.AccountTypeGroupOwner, Status: identity.UserStatusActive,
	}
	memberUser := identity.User{
		Username: "report-member", PasswordHash: memberHash, DisplayName: "汇总业务员",
		AccountType: identity.AccountTypeMember, Status: identity.UserStatusActive,
	}
	outsiderUser := identity.User{
		Username: "report-outsider", PasswordHash: outsiderHash, DisplayName: "别组主账号",
		AccountType: identity.AccountTypeGroupOwner, Status: identity.UserStatusActive,
	}
	for _, user := range []*identity.User{&ownerUser, &memberUser, &outsiderUser} {
		if err := db.Create(user).Error; err != nil {
			t.Fatalf("seed user: %v", err)
		}
	}

	group := organization.Group{
		Name: "汇总流转组", Status: organization.GroupStatusActive,
		OwnerUserID: ownerUser.ID, CreatedBy: ownerUser.ID,
	}
	otherGroup := organization.Group{
		Name: "汇总对照组", Status: organization.GroupStatusActive,
		OwnerUserID: outsiderUser.ID, CreatedBy: outsiderUser.ID,
	}
	for _, entity := range []*organization.Group{&group, &otherGroup} {
		if err := db.Create(entity).Error; err != nil {
			t.Fatalf("seed group: %v", err)
		}
	}
	ownerMembership := organization.Membership{
		GroupID: group.ID, UserID: ownerUser.ID, MemberType: organization.MemberTypeOwner,
		Status: organization.MembershipStatusActive, Version: 1,
	}
	memberMembership := organization.Membership{
		GroupID: group.ID, UserID: memberUser.ID, MemberType: organization.MemberTypeMember,
		Status: organization.MembershipStatusActive, Version: 1,
	}
	outsiderMembership := organization.Membership{
		GroupID: otherGroup.ID, UserID: outsiderUser.ID, MemberType: organization.MemberTypeOwner,
		Status: organization.MembershipStatusActive, Version: 1,
	}
	for _, entity := range []*organization.Membership{&ownerMembership, &memberMembership, &outsiderMembership} {
		if err := db.Create(entity).Error; err != nil {
			t.Fatalf("seed membership: %v", err)
		}
	}

	authorizer := authorization.NewAuthorizer(authorization.NewRepository(db))
	documentService := document.NewService(document.NewRepository(db), authorizer)
	memberService := member.NewService(member.NewRepository(db), authorizer)
	financeService := finance.NewService(finance.NewRepository(db), authorizer)
	reportingService := reporting.NewService(reporting.NewRepository(db), authorizer)

	ownerPrincipal := identity.Principal{
		UserID: ownerUser.ID, GroupID: &group.ID,
		AccountType: identity.AccountTypeGroupOwner, MemberType: "owner",
	}
	memberPrincipal := identity.Principal{
		UserID: memberUser.ID, GroupID: &group.ID,
		AccountType: identity.AccountTypeMember, MemberType: "member",
	}
	outsiderPrincipal := identity.Principal{
		UserID: outsiderUser.ID, GroupID: &otherGroup.ID,
		AccountType: identity.AccountTypeGroupOwner, MemberType: "owner",
	}

	const period = "2026-05"

	/* ---------------- 1. 准备已提交单据：两张入库 + 三张出库（三类销售金额各一张） ---------------- */

	inboundOwner := createSubmittedDocument(t, ctx, documentService, ownerPrincipal,
		document.KindInbound, "2026-05-10", "北京钢铁贸易有限公司", "40", "2500", nil, "rep-in-owner")
	inboundMember := createSubmittedDocument(t, ctx, documentService, memberPrincipal,
		document.KindInbound, "2026-05-12", "河北钢材市场", "25", "2000", nil, "rep-in-member")

	outboundOwnerA := createSubmittedDocument(t, ctx, documentService, ownerPrincipal,
		document.KindOutbound, "2026-05-11", "天津建筑集团", "60", "3000",
		saleAmountTypePointer(document.SaleAmountVATSpecial), "rep-out-owner-a")
	outboundOwnerB := createSubmittedDocument(t, ctx, documentService, ownerPrincipal,
		document.KindOutbound, "2026-05-13", "广州建材", "5", "1000",
		saleAmountTypePointer(document.SaleAmountNoInvoice), "rep-out-owner-b")
	outboundMember := createSubmittedDocument(t, ctx, documentService, memberPrincipal,
		document.KindOutbound, "2026-05-14", "上海贸易", "10", "2000",
		saleAmountTypePointer(document.SaleAmountVATGeneral), "rep-out-member")

	// 金额锁定：出库合计 205000，入库合计 150000。
	if inboundOwner.TotalAmount.String() != "100000.00" || inboundMember.TotalAmount.String() != "50000.00" ||
		outboundOwnerA.TotalAmount.String() != "180000.00" || outboundOwnerB.TotalAmount.String() != "5000.00" ||
		outboundMember.TotalAmount.String() != "20000.00" {
		t.Fatalf("源单据金额 = %s / %s / %s / %s / %s",
			inboundOwner.TotalAmount, inboundMember.TotalAmount,
			outboundOwnerA.TotalAmount, outboundOwnerB.TotalAmount, outboundMember.TotalAmount)
	}

	// 草稿单、上月单据、别组单据都必须被排除在五月汇总之外。
	if _, err := documentService.Create(ctx, ownerPrincipal, document.KindInbound, document.CreateRequest{
		Status: document.StatusDraft, BusinessDate: "2026-05-15",
		Parties: []document.PartyRequest{{
			PartyName: "草稿供应商",
			Items: []document.ItemRequest{{
				ProductName: "螺纹钢", Quantity: mustQuantityValue(t, "10"),
				UnitPrice: mustPriceValue(t, "3000"), PriceTaxMode: document.PriceTaxIncluded,
			}},
		}},
	}, "rep-draft"); err != nil {
		t.Fatalf("Create(draft) error = %v", err)
	}
	prevMonth := createSubmittedDocument(t, ctx, documentService, ownerPrincipal,
		document.KindInbound, "2026-04-15", "上月供应商", "10", "1000", nil, "rep-in-prev")
	outsiderInbound := createSubmittedDocument(t, ctx, documentService, outsiderPrincipal,
		document.KindInbound, "2026-05-10", "别组供应商", "20", "1000", nil, "rep-in-outsider")
	if prevMonth.TotalAmount.String() != "10000.00" || outsiderInbound.TotalAmount.String() != "20000.00" {
		t.Fatalf("对照单据金额 = %s / %s", prevMonth.TotalAmount, outsiderInbound.TotalAmount)
	}

	/* ---------------- 2. 登记财务记录：制造已付 / 已开 / 已收的余额差异 ---------------- */

	// 入库主单：付 30000（未付清）、开票 40000（未开满）；出库主单：收 80000（未收清）。
	if _, err := financeService.Create(ctx, ownerPrincipal, finance.KindPayment, finance.CreateRequest{
		DocumentID: inboundOwner.DocumentID, Amount: "30000.00", OccurredOn: "2026-05-20", Method: "transfer",
	}, "rep-pay-1"); err != nil {
		t.Fatalf("Create(payment) error = %v", err)
	}
	if _, err := financeService.Create(ctx, ownerPrincipal, finance.KindInvoice, finance.CreateRequest{
		DocumentID: inboundOwner.DocumentID, Amount: "40000.00", OccurredOn: "2026-05-21",
	}, "rep-inv-1"); err != nil {
		t.Fatalf("Create(invoice) error = %v", err)
	}
	if _, err := financeService.Create(ctx, ownerPrincipal, finance.KindReceipt, finance.CreateRequest{
		DocumentID: outboundOwnerA.DocumentID, Amount: "80000.00", OccurredOn: "2026-05-22", Method: "transfer",
	}, "rep-recv-1"); err != nil {
		t.Fatalf("Create(receipt) error = %v", err)
	}

	/* ---------------- 3. 看板：合计口径 ---------------- */

	overview, err := reportingService.Overview(ctx, ownerPrincipal, reporting.PeriodQuery{Period: period})
	if err != nil {
		t.Fatalf("Overview() error = %v", err)
	}
	if overview.Period != period {
		t.Fatalf("Overview period = %q, want %q", overview.Period, period)
	}
	if overview.InboundDocumentCount != 2 || overview.InboundAmount.String() != "150000.00" {
		t.Fatalf("入库合计 = %d 张 / %s", overview.InboundDocumentCount, overview.InboundAmount)
	}
	if overview.OutboundDocumentCount != 3 || overview.OutboundAmount.String() != "205000.00" {
		t.Fatalf("出库合计 = %d 张 / %s", overview.OutboundDocumentCount, overview.OutboundAmount)
	}
	// 毛利润 = 出库 205000 − 入库 150000 = 55000；毛利率 = 55000 / 205000 = 26.83%。
	if overview.GrossProfit.String() != "55000.00" || overview.GrossMarginPPM != 268293 ||
		overview.GrossMarginPercent != "26.83" {
		t.Fatalf("毛利润 = %s / %d / %s", overview.GrossProfit, overview.GrossMarginPPM, overview.GrossMarginPercent)
	}
	// 余额口径：已付 30000、未付 120000；两张入库单都没付清。
	if overview.PaidAmount.String() != "30000.00" || overview.UnpaidAmount.String() != "120000.00" ||
		overview.UnpaidDocumentCount != 2 {
		t.Fatalf("付款口径 = %s / %s / %d",
			overview.PaidAmount, overview.UnpaidAmount, overview.UnpaidDocumentCount)
	}
	if overview.InvoicedAmount.String() != "40000.00" || overview.UninvoicedAmount.String() != "110000.00" ||
		overview.UninvoicedDocumentCount != 2 {
		t.Fatalf("开票口径 = %s / %s / %d",
			overview.InvoicedAmount, overview.UninvoicedAmount, overview.UninvoicedDocumentCount)
	}
	// 已收 80000、未收 125000；三张出库单都没收清。
	if overview.ReceivedAmount.String() != "80000.00" || overview.UnreceivedAmount.String() != "125000.00" ||
		overview.UnreceivedDocumentCount != 3 {
		t.Fatalf("收款口径 = %s / %s / %d",
			overview.ReceivedAmount, overview.UnreceivedAmount, overview.UnreceivedDocumentCount)
	}
	if overview.SupplierCount != 2 || overview.CustomerCount != 3 {
		t.Fatalf("涉及家数 = 供应商 %d / 客户 %d", overview.SupplierCount, overview.CustomerCount)
	}
	// 三类销售金额按固定顺序 Y-1 / y-N / N 返回。
	if len(overview.SaleAmountTypes) != 3 {
		t.Fatalf("销售金额分项数 = %d, want 3", len(overview.SaleAmountTypes))
	}
	assertSaleAmountTotal(t, overview.SaleAmountTypes[0], document.SaleAmountVATSpecial, "180000.00", 878049, "87.80")
	assertSaleAmountTotal(t, overview.SaleAmountTypes[1], document.SaleAmountVATGeneral, "20000.00", 97561, "9.76")
	assertSaleAmountTotal(t, overview.SaleAmountTypes[2], document.SaleAmountNoInvoice, "5000.00", 24390, "2.44")
	if overview.InboundAmountUpper == "" || overview.OutboundAmountUpper == "" || overview.UnpaidAmountUpper == "" {
		t.Fatal("看板缺少人民币大写")
	}

	// 按业务员筛选：只看主账号经手的单据。
	ownerOnly, err := reportingService.Overview(ctx, ownerPrincipal, reporting.PeriodQuery{
		Period: period, BusinessUserID: ownerUser.ID,
	})
	if err != nil {
		t.Fatalf("Overview(business_user_id) error = %v", err)
	}
	if ownerOnly.InboundDocumentCount != 1 || ownerOnly.OutboundDocumentCount != 2 ||
		ownerOnly.OutboundAmount.String() != "185000.00" || ownerOnly.CustomerCount != 2 {
		t.Fatalf("按业务员筛选看板 = %+v", ownerOnly)
	}

	/* ---------------- 4. 入库统计：单据级合计 + 明细级分页 ---------------- */

	inboundStats, err := reportingService.InboundStats(ctx, ownerPrincipal, reporting.ItemStatsQuery{Period: period})
	if err != nil {
		t.Fatalf("InboundStats() error = %v", err)
	}
	if inboundStats.DocumentCount != 2 || inboundStats.AmountTotal.String() != "150000.00" ||
		inboundStats.PaidAmount.String() != "30000.00" || inboundStats.UnpaidAmount.String() != "120000.00" ||
		inboundStats.UnpaidDocumentCount != 2 || inboundStats.SupplierCount != 2 {
		t.Fatalf("入库统计合计块 = %+v", inboundStats)
	}
	if inboundStats.InvoicedAmount.String() != "40000.00" || inboundStats.UninvoicedAmount.String() != "110000.00" ||
		inboundStats.UninvoicedDocumentCount != 2 {
		t.Fatalf("入库统计开票块 = %+v", inboundStats)
	}
	// 明细按「往来单位 + 品名 + 型号 + 单位」聚合，按金额倒序：北京钢铁贸易 100000 在前。
	if len(inboundStats.Items) != 2 || inboundStats.Total != 2 {
		t.Fatalf("入库明细行数 = %d（total=%d）", len(inboundStats.Items), inboundStats.Total)
	}
	firstInbound := inboundStats.Items[0]
	if firstInbound.PartyName != "北京钢铁贸易有限公司" || firstInbound.ProductName != "螺纹钢" ||
		firstInbound.Amount.String() != "100000.00" || firstInbound.Quantity.String() != "40.000" ||
		firstInbound.DocumentCount != 1 {
		t.Fatalf("入库明细首行 = %+v", firstInbound)
	}
	// 明细行不给已付 / 未付：付款挂在单据上，无法分摊到某一品名。
	if firstInbound.ProductModel != nil || firstInbound.Unit != nil {
		t.Fatalf("入库明细可空列应为 nil = %+v", firstInbound)
	}

	// 字段查询：按往来单位关键词过滤。
	filteredInbound, err := reportingService.InboundStats(ctx, ownerPrincipal, reporting.ItemStatsQuery{
		Period: period, PartyName: "河北",
	})
	if err != nil {
		t.Fatalf("InboundStats(party_name) error = %v", err)
	}
	if len(filteredInbound.Items) != 1 || filteredInbound.Items[0].PartyName != "河北钢材市场" ||
		filteredInbound.Total != 1 {
		t.Fatalf("按往来单位过滤 = %+v", filteredInbound.Items)
	}

	/* ---------------- 5. 出库统计：三类销售金额分项 + 明细 ---------------- */

	outboundStats, err := reportingService.OutboundStats(ctx, ownerPrincipal, reporting.ItemStatsQuery{Period: period})
	if err != nil {
		t.Fatalf("OutboundStats() error = %v", err)
	}
	if outboundStats.DocumentCount != 3 || outboundStats.AmountTotal.String() != "205000.00" ||
		outboundStats.ReceivedAmount.String() != "80000.00" ||
		outboundStats.UnreceivedAmount.String() != "125000.00" ||
		outboundStats.UnreceivedDocumentCount != 3 || outboundStats.CustomerCount != 3 {
		t.Fatalf("出库统计合计块 = %+v", outboundStats)
	}
	assertSaleAmountTotal(t, outboundStats.SaleAmountTypes[0], document.SaleAmountVATSpecial, "180000.00", 878049, "87.80")
	assertSaleAmountTotal(t, outboundStats.SaleAmountTypes[1], document.SaleAmountVATGeneral, "20000.00", 97561, "9.76")
	assertSaleAmountTotal(t, outboundStats.SaleAmountTypes[2], document.SaleAmountNoInvoice, "5000.00", 24390, "2.44")
	if len(outboundStats.Items) != 3 || outboundStats.Items[0].PartyName != "天津建筑集团" ||
		outboundStats.Items[0].Amount.String() != "180000.00" {
		t.Fatalf("出库明细 = %+v", outboundStats.Items)
	}
	// 分页：按金额倒序取前两条。
	pageOne, err := reportingService.OutboundStats(ctx, ownerPrincipal, reporting.ItemStatsQuery{
		Period: period, Page: 1, PageSize: 2,
	})
	if err != nil {
		t.Fatalf("OutboundStats(page=1) error = %v", err)
	}
	if len(pageOne.Items) != 2 || pageOne.Total != 3 || pageOne.Page != 1 || pageOne.PageSize != 2 {
		t.Fatalf("出库明细分页首页 = %d 条（total=%d）", len(pageOne.Items), pageOne.Total)
	}
	pageTwo, err := reportingService.OutboundStats(ctx, ownerPrincipal, reporting.ItemStatsQuery{
		Period: period, Page: 2, PageSize: 2,
	})
	if err != nil {
		t.Fatalf("OutboundStats(page=2) error = %v", err)
	}
	if len(pageTwo.Items) != 1 || pageTwo.Total != 3 {
		t.Fatalf("出库明细分页第二页 = %d 条（total=%d）", len(pageTwo.Items), pageTwo.Total)
	}

	/* ---------------- 6. 业务员维度利润统计 ---------------- */

	businessUsers, err := reportingService.BusinessUsers(ctx, ownerPrincipal, reporting.BusinessUserQuery{Period: period})
	if err != nil {
		t.Fatalf("BusinessUsers() error = %v", err)
	}
	if len(businessUsers.Items) != 2 {
		t.Fatalf("业务员行数 = %d, want 2", len(businessUsers.Items))
	}
	// 按 business_user_id 升序：主账号先生成，ID 更小。
	ownerRow := businessUsers.Items[0]
	if ownerRow.BusinessUser.ID != ownerUser.ID || ownerRow.InboundAmount.String() != "100000.00" ||
		ownerRow.OutboundAmount.String() != "185000.00" || ownerRow.GrossProfit.String() != "85000.00" ||
		ownerRow.DocumentCount != 3 {
		t.Fatalf("主账号利润行 = %+v", ownerRow)
	}
	memberRow := businessUsers.Items[1]
	if memberRow.BusinessUser.ID != memberUser.ID || memberRow.InboundAmount.String() != "50000.00" ||
		memberRow.OutboundAmount.String() != "20000.00" || memberRow.GrossProfit.String() != "-30000.00" ||
		memberRow.DocumentCount != 2 {
		t.Fatalf("业务员利润行 = %+v", memberRow)
	}
	// 合计行等于全组口径。
	if businessUsers.Summary.InboundAmount.String() != "150000.00" ||
		businessUsers.Summary.OutboundAmount.String() != "205000.00" ||
		businessUsers.Summary.GrossProfit.String() != "55000.00" ||
		businessUsers.Summary.DocumentCount != 5 {
		t.Fatalf("业务员利润合计 = %+v", businessUsers.Summary)
	}

	/* ---------------- 7. 生成总结算快照：公司维度 / 业务员维度 ---------------- */

	companyBatch, err := reportingService.CreateSnapshots(ctx, ownerPrincipal, reporting.CreateSnapshotRequest{
		Period: period, Scope: string(reporting.ScopeCompany), Remark: strPtrValue("五月公司总结算"),
	})
	if err != nil {
		t.Fatalf("CreateSnapshots(company) error = %v", err)
	}
	if companyBatch.Period != period || len(companyBatch.Snapshots) != 1 {
		t.Fatalf("公司维度批次 = %+v", companyBatch)
	}
	companySnapshot := companyBatch.Snapshots[0]
	if companySnapshot.SnapshotNo != "ZJS202605-0001" || companySnapshot.BatchNo != "ZJS202605-0001" {
		t.Fatalf("公司维度单号/批次 = %q / %q", companySnapshot.SnapshotNo, companySnapshot.BatchNo)
	}
	if companySnapshot.Scope != reporting.ScopeCompany || companySnapshot.BusinessUser.ID != 0 {
		t.Fatalf("公司维度不应绑定业务员 = %+v", companySnapshot)
	}
	if companySnapshot.InboundAmount.String() != "150000.00" ||
		companySnapshot.OutboundAmount.String() != "205000.00" ||
		companySnapshot.GrossProfit.String() != "55000.00" ||
		companySnapshot.GrossMarginPPM != 268293 ||
		companySnapshot.DocumentCount != 5 {
		t.Fatalf("公司维度快照金额 = %+v", companySnapshot)
	}
	if companySnapshot.Remark == nil || *companySnapshot.Remark != "五月公司总结算" ||
		companySnapshot.CreatedBy.ID != ownerUser.ID {
		t.Fatalf("公司维度快照备注/创建人 = %+v", companySnapshot)
	}
	createdAt := companySnapshot.CreatedAt

	// 业务员维度不带业务员 ID：为该周期内的全部业务员各生成一张，共用同一批次号。
	memberBatch, err := reportingService.CreateSnapshots(ctx, ownerPrincipal, reporting.CreateSnapshotRequest{
		Period: period, Scope: string(reporting.ScopeBusinessUser),
	})
	if err != nil {
		t.Fatalf("CreateSnapshots(business_user all) error = %v", err)
	}
	if len(memberBatch.Snapshots) != 2 {
		t.Fatalf("业务员维度张数 = %d, want 2", len(memberBatch.Snapshots))
	}
	if memberBatch.BatchNo != "ZJS202605-0002" {
		t.Fatalf("业务员维度批次号 = %q, want ZJS202605-0002", memberBatch.BatchNo)
	}
	if memberBatch.Snapshots[0].SnapshotNo != "ZJS202605-0002" ||
		memberBatch.Snapshots[1].SnapshotNo != "ZJS202605-0003" ||
		memberBatch.Snapshots[0].BatchNo != memberBatch.BatchNo ||
		memberBatch.Snapshots[1].BatchNo != memberBatch.BatchNo {
		t.Fatalf("业务员维度单号/批次 = %+v", memberBatch.Snapshots)
	}
	if memberBatch.Snapshots[0].BusinessUser.ID != ownerUser.ID ||
		memberBatch.Snapshots[0].BusinessUser.DisplayName != "汇总主账号" ||
		memberBatch.Snapshots[0].GrossProfit.String() != "85000.00" {
		t.Fatalf("主账号快照 = %+v", memberBatch.Snapshots[0])
	}
	if memberBatch.Snapshots[1].BusinessUser.ID != memberUser.ID ||
		memberBatch.Snapshots[1].GrossProfit.String() != "-30000.00" {
		t.Fatalf("业务员快照 = %+v", memberBatch.Snapshots[1])
	}

	// 业务员维度带业务员 ID：只生成指定业务员那一张。
	memberOnlyBatch, err := reportingService.CreateSnapshots(ctx, ownerPrincipal, reporting.CreateSnapshotRequest{
		Period: period, Scope: string(reporting.ScopeBusinessUser), BusinessUserID: memberUser.ID,
	})
	if err != nil {
		t.Fatalf("CreateSnapshots(business_user specific) error = %v", err)
	}
	if len(memberOnlyBatch.Snapshots) != 1 || memberOnlyBatch.Snapshots[0].SnapshotNo != "ZJS202605-0004" ||
		memberOnlyBatch.Snapshots[0].BusinessUser.ID != memberUser.ID {
		t.Fatalf("指定业务员快照 = %+v", memberOnlyBatch.Snapshots)
	}

	// 每张快照都要有审计记录，否则出问题追不到是谁生成的。
	var auditCount int64
	if err := db.Table("audit_logs").
		Where("group_id = ? AND action = ?", group.ID, "report.summary_settlement.generated").
		Count(&auditCount).Error; err != nil {
		t.Fatalf("count audit logs: %v", err)
	}
	if auditCount != 4 {
		t.Fatalf("总结算审计条数 = %d, want 4", auditCount)
	}

	/* ---------------- 8. 快照列表、详情与冻结语义 ---------------- */

	page, err := reportingService.ListSnapshots(ctx, ownerPrincipal, reporting.SnapshotListQuery{})
	if err != nil {
		t.Fatalf("ListSnapshots() error = %v", err)
	}
	if page.Total != 4 || page.Page != 1 || page.PageSize != 20 {
		t.Fatalf("快照列表 = total %d / page %d / size %d", page.Total, page.Page, page.PageSize)
	}
	// 列表按周期倒序、同周期按 ID 倒序：最新生成的排在最前。
	if page.Items[0].SnapshotID <= page.Items[len(page.Items)-1].SnapshotID {
		t.Fatalf("快照列表顺序不是按 ID 倒序 = %+v", page.Items)
	}

	byPeriod, err := reportingService.ListSnapshots(ctx, ownerPrincipal, reporting.SnapshotListQuery{Period: period})
	if err != nil {
		t.Fatalf("ListSnapshots(period) error = %v", err)
	}
	if byPeriod.Total != 4 {
		t.Fatalf("按周期过滤 total = %d, want 4", byPeriod.Total)
	}
	byScope, err := reportingService.ListSnapshots(ctx, ownerPrincipal, reporting.SnapshotListQuery{
		Period: period, Scope: reporting.ScopeCompany,
	})
	if err != nil {
		t.Fatalf("ListSnapshots(scope) error = %v", err)
	}
	if byScope.Total != 1 || byScope.Items[0].SnapshotNo != "ZJS202605-0001" {
		t.Fatalf("按维度过滤 = %+v", byScope.Items)
	}
	byUser, err := reportingService.ListSnapshots(ctx, ownerPrincipal, reporting.SnapshotListQuery{
		Period: period, BusinessUserID: memberUser.ID,
	})
	if err != nil {
		t.Fatalf("ListSnapshots(business_user_id) error = %v", err)
	}
	if byUser.Total != 2 {
		t.Fatalf("按业务员过滤 total = %d, want 2", byUser.Total)
	}

	detail, err := reportingService.GetSnapshot(ctx, ownerPrincipal, companySnapshot.SnapshotID)
	if err != nil {
		t.Fatalf("GetSnapshot() error = %v", err)
	}
	// created_at 列是 DATETIME(6)（微秒），而生成时用的是纳秒时钟，逐位比较会因截断而不等，
	// 这里按「一毫秒以内」判定，既不放过真正的错位，又不受精度截断干扰。
	if detail.SnapshotNo != companySnapshot.SnapshotNo {
		t.Fatalf("快照详情单号 = %q, want %q", detail.SnapshotNo, companySnapshot.SnapshotNo)
	}
	if drift := detail.CreatedAt.Sub(createdAt); drift < 0 || drift > time.Millisecond {
		t.Fatalf("快照详情创建时间 = %s, want ≈%s", detail.CreatedAt, createdAt)
	}
	_, err = reportingService.GetSnapshot(ctx, ownerPrincipal, 999999)
	assertIntegrationCode(t, err, apperror.CodeReportSnapshotNotFound)

	// 冻结语义：作废一张源出库单后，已生成的快照数值不变，新看板才反映变化。
	voided, err := documentService.Void(ctx, ownerPrincipal, document.KindOutbound,
		outboundOwnerB.DocumentID, document.VersionRequest{Version: outboundOwnerB.Version})
	if err != nil {
		t.Fatalf("Void(outbound) error = %v", err)
	}
	if voided.Status != document.StatusVoided {
		t.Fatalf("作废后状态 = %q", voided.Status)
	}
	frozen, err := reportingService.GetSnapshot(ctx, ownerPrincipal, companySnapshot.SnapshotID)
	if err != nil {
		t.Fatalf("GetSnapshot(frozen) error = %v", err)
	}
	if frozen.OutboundAmount.String() != "205000.00" || frozen.DocumentCount != 5 {
		t.Fatalf("快照应保持冻结 = %+v", frozen)
	}
	updated, err := reportingService.Overview(ctx, ownerPrincipal, reporting.PeriodQuery{Period: period})
	if err != nil {
		t.Fatalf("Overview(after void) error = %v", err)
	}
	if updated.OutboundAmount.String() != "200000.00" || updated.OutboundDocumentCount != 2 {
		t.Fatalf("作废后看板未更新 = %+v", updated)
	}
	// 重新生成一张，冻结的才是新口径。
	regenerated, err := reportingService.CreateSnapshots(ctx, ownerPrincipal, reporting.CreateSnapshotRequest{
		Period: period, Scope: string(reporting.ScopeCompany),
	})
	if err != nil {
		t.Fatalf("CreateSnapshots(after void) error = %v", err)
	}
	if regenerated.Snapshots[0].SnapshotNo != "ZJS202605-0005" ||
		regenerated.Snapshots[0].OutboundAmount.String() != "200000.00" {
		t.Fatalf("重新生成的快照 = %+v", regenerated.Snapshots[0])
	}

	/* ---------------- 9. 空周期与非法参数 ---------------- */

	emptyOverview, err := reportingService.Overview(ctx, ownerPrincipal, reporting.PeriodQuery{Period: "2026-08"})
	if err != nil {
		t.Fatalf("Overview(empty period) error = %v", err)
	}
	if emptyOverview.InboundAmount != 0 || emptyOverview.OutboundAmount != 0 ||
		emptyOverview.GrossMarginPercent != "0.00" || len(emptyOverview.SaleAmountTypes) != 3 {
		t.Fatalf("空周期看板 = %+v", emptyOverview)
	}
	// 周期内没有任何已提交单据时不允许生成总结算。
	_, err = reportingService.CreateSnapshots(ctx, ownerPrincipal, reporting.CreateSnapshotRequest{
		Period: "2026-08", Scope: string(reporting.ScopeCompany),
	})
	assertIntegrationCode(t, err, apperror.CodeReportPeriodEmpty)
	// 非法周期与非法维度都按参数错误处理。
	_, err = reportingService.Overview(ctx, ownerPrincipal, reporting.PeriodQuery{Period: "2026-13"})
	assertIntegrationCode(t, err, apperror.CodeValidationFailed)
	_, err = reportingService.CreateSnapshots(ctx, ownerPrincipal, reporting.CreateSnapshotRequest{
		Period: period, Scope: "unit",
	})
	assertIntegrationCode(t, err, apperror.CodeValidationFailed)
	_, err = reportingService.ListSnapshots(ctx, ownerPrincipal, reporting.SnapshotListQuery{PageSize: 101})
	assertIntegrationCode(t, err, apperror.CodeValidationFailed)

	/* ---------------- 10. 权限收敛：汇总只有「看全组」一种数据范围 ---------------- */

	// 子账号没有 report.view 时直接 403，而不是返回空报表。
	_, err = reportingService.Overview(ctx, memberPrincipal, reporting.PeriodQuery{Period: period})
	assertIntegrationCode(t, err, apperror.CodeForbidden)
	_, err = reportingService.InboundStats(ctx, memberPrincipal, reporting.ItemStatsQuery{Period: period})
	assertIntegrationCode(t, err, apperror.CodeForbidden)
	_, err = reportingService.ListSnapshots(ctx, memberPrincipal, reporting.SnapshotListQuery{})
	assertIntegrationCode(t, err, apperror.CodeForbidden)

	// 授予 report.view 后即可查看全组（不是只看本人）。
	if _, err := memberService.ReplacePermissions(ctx, ownerPrincipal, memberMembership.ID, member.ReplacePermissionsRequest{
		PermissionCodes: []authorization.Code{authorization.PermissionReportView}, Version: 1,
	}); err != nil {
		t.Fatalf("ReplacePermissions(report.view) error = %v", err)
	}
	memberOverview, err := reportingService.Overview(ctx, memberPrincipal, reporting.PeriodQuery{Period: period})
	if err != nil {
		t.Fatalf("member Overview() error = %v", err)
	}
	if memberOverview.InboundDocumentCount != 2 || memberOverview.OutboundDocumentCount != 2 {
		t.Fatalf("拿到 report.view 后应看全组 = %+v", memberOverview)
	}
	// 业务员维度统计同样对全组可见，且能生成总结算。
	memberBusinessUsers, err := reportingService.BusinessUsers(ctx, memberPrincipal, reporting.BusinessUserQuery{Period: period})
	if err != nil {
		t.Fatalf("member BusinessUsers() error = %v", err)
	}
	if len(memberBusinessUsers.Items) != 2 {
		t.Fatalf("member BusinessUsers 行数 = %d, want 2", len(memberBusinessUsers.Items))
	}
	memberGenerated, err := reportingService.CreateSnapshots(ctx, memberPrincipal, reporting.CreateSnapshotRequest{
		Period: period, Scope: string(reporting.ScopeCompany),
	})
	if err != nil {
		t.Fatalf("member CreateSnapshots() error = %v", err)
	}
	if memberGenerated.Snapshots[0].CreatedBy.ID != memberUser.ID {
		t.Fatalf("快照创建人应为业务员 = %+v", memberGenerated.Snapshots[0].CreatedBy)
	}

	/* ---------------- 11. 跨组隔离 ---------------- */

	outsiderOverview, err := reportingService.Overview(ctx, outsiderPrincipal, reporting.PeriodQuery{Period: period})
	if err != nil {
		t.Fatalf("outsider Overview() error = %v", err)
	}
	if outsiderOverview.InboundDocumentCount != 1 || outsiderOverview.InboundAmount.String() != "20000.00" ||
		outsiderOverview.OutboundDocumentCount != 0 {
		t.Fatalf("别组看板 = %+v", outsiderOverview)
	}
	// 别组读本组快照只会得到「快照不存在」。
	_, err = reportingService.GetSnapshot(ctx, outsiderPrincipal, companySnapshot.SnapshotID)
	assertIntegrationCode(t, err, apperror.CodeReportSnapshotNotFound)
	outsiderSnapshots, err := reportingService.ListSnapshots(ctx, outsiderPrincipal, reporting.SnapshotListQuery{})
	if err != nil {
		t.Fatalf("outsider ListSnapshots() error = %v", err)
	}
	if outsiderSnapshots.Total != 0 {
		t.Fatalf("别组快照列表 total = %d, want 0", outsiderSnapshots.Total)
	}
}

// assertSaleAmountTotal 校验一类销售金额的分项统计。
func assertSaleAmountTotal(
	t *testing.T,
	actual reporting.SaleAmountTotalData,
	wantType document.SaleAmountType,
	wantAmount string,
	wantPPM int64,
	wantPercent string,
) {
	t.Helper()
	if actual.SaleAmountType != wantType {
		t.Errorf("销售金额类型 = %q, want %q", actual.SaleAmountType, wantType)
	}
	if actual.Amount.String() != wantAmount {
		t.Errorf("%s 金额 = %s, want %s", wantType, actual.Amount, wantAmount)
	}
	if actual.SharePPM != wantPPM {
		t.Errorf("%s 占比 ppm = %d, want %d", wantType, actual.SharePPM, wantPPM)
	}
	if actual.SharePercent != wantPercent {
		t.Errorf("%s 占比文本 = %q, want %q", wantType, actual.SharePercent, wantPercent)
	}
	if actual.AmountUpper == "" {
		t.Errorf("%s 缺少人民币大写", wantType)
	}
}
