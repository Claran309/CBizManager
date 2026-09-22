//go:build integration

package integration

import (
	"context"
	"fmt"
	"testing"
	"time"

	"CBizDocsManager/backend/internal/authorization"
	"CBizDocsManager/backend/internal/document"
	"CBizDocsManager/backend/internal/identity"
	"CBizDocsManager/backend/internal/member"
	"CBizDocsManager/backend/internal/organization"
	"CBizDocsManager/backend/internal/settlement"
	"CBizDocsManager/backend/pkg/apperror"
	"CBizDocsManager/backend/pkg/rmb"
)

// TestSettlementApprovalFlow 用真实 MySQL 覆盖结算与单级审批主链路：
//
//	金额快照 → 单号生成 → 幂等重放 → 源单据占用与释放 → 数据范围收敛
//	→ 乐观锁 → 单级审批终态 → 驳回释放后可重新结算 → 列表过滤。
//
// 之所以必须走真实方言：这里依赖 (group_id, active_document_id) 唯一索引来兜底
// 「同一源单据不能被两张有效结算单引用」，并依赖「释放置 NULL、多个 NULL 可共存」
// 这一 MySQL 与 SQLite 共有但对 NULL 处理必须真实的语义。sqlite 桩数据无法替代。
func TestSettlementApprovalFlow(t *testing.T) {
	db := openAuthFlowMySQL(t)
	ctx := context.Background()
	passwords := identity.NewPasswordManager()

	ownerHash, err := passwords.Hash("settle-owner-password")
	if err != nil {
		t.Fatalf("hash owner password: %v", err)
	}
	memberHash, err := passwords.Hash("settle-member-password")
	if err != nil {
		t.Fatalf("hash member password: %v", err)
	}

	ownerUser := identity.User{
		Username: "settle-owner", PasswordHash: ownerHash, DisplayName: "结算主账号",
		AccountType: identity.AccountTypeGroupOwner, Status: identity.UserStatusActive,
	}
	memberUser := identity.User{
		Username: "settle-member", PasswordHash: memberHash, DisplayName: "结算业务员",
		AccountType: identity.AccountTypeMember, Status: identity.UserStatusActive,
	}
	for _, user := range []*identity.User{&ownerUser, &memberUser} {
		if err := db.Create(user).Error; err != nil {
			t.Fatalf("seed user: %v", err)
		}
	}

	group := organization.Group{
		Name: "结算流转组", Status: organization.GroupStatusActive,
		OwnerUserID: ownerUser.ID, CreatedBy: ownerUser.ID,
	}
	if err := db.Create(&group).Error; err != nil {
		t.Fatalf("seed group: %v", err)
	}
	ownerMembership := organization.Membership{
		GroupID: group.ID, UserID: ownerUser.ID, MemberType: organization.MemberTypeOwner,
		Status: organization.MembershipStatusActive, Version: 1,
	}
	memberMembership := organization.Membership{
		GroupID: group.ID, UserID: memberUser.ID, MemberType: organization.MemberTypeMember,
		Status: organization.MembershipStatusActive, Version: 1,
	}
	for _, membership := range []*organization.Membership{&ownerMembership, &memberMembership} {
		if err := db.Create(membership).Error; err != nil {
			t.Fatalf("seed membership: %v", err)
		}
	}

	authorizer := authorization.NewAuthorizer(authorization.NewRepository(db))
	documentService := document.NewService(document.NewRepository(db), authorizer)
	memberService := member.NewService(member.NewRepository(db), authorizer)
	settlementService := settlement.NewService(settlement.NewRepository(db), authorizer)

	ownerPrincipal := identity.Principal{
		UserID: ownerUser.ID, GroupID: &group.ID,
		AccountType: identity.AccountTypeGroupOwner, MemberType: "owner",
	}
	memberPrincipal := identity.Principal{
		UserID: memberUser.ID, GroupID: &group.ID,
		AccountType: identity.AccountTypeMember, MemberType: "member",
	}
	businessDate := "2026-05-12"

	/* ---------------- 1. 准备源单据：三张已提交 + 一张草稿 ---------------- */

	inboundOwner := createSubmittedDocument(t, ctx, documentService, ownerPrincipal,
		document.KindInbound, businessDate, "北京钢铁贸易有限公司", "40", "2500", nil, "src-in-owner")
	outboundOwner := createSubmittedDocument(t, ctx, documentService, ownerPrincipal,
		document.KindOutbound, businessDate, "天津建筑集团", "60", "3000",
		saleAmountTypePointer(document.SaleAmountVATSpecial), "src-out-owner")
	inboundMember := createSubmittedDocument(t, ctx, documentService, memberPrincipal,
		document.KindInbound, businessDate, "河北钢材市场", "25", "2000", nil, "src-in-member")
	// 稍后用于「驳回释放后重新结算」，先备好一张空闲单据。
	inboundReusable := createSubmittedDocument(t, ctx, documentService, ownerPrincipal,
		document.KindInbound, businessDate, "河北钢材市场", "14", "5000", nil, "src-in-reusable")

	// 草稿单不允许参与结算：金额还没定，结算快照会变成「当时的中间态」。
	draftDoc, err := documentService.Create(ctx, ownerPrincipal, document.KindInbound, document.CreateRequest{
		Status: document.StatusDraft, BusinessDate: businessDate,
		Parties: []document.PartyRequest{{
			PartyName: "草稿供应商",
			Items: []document.ItemRequest{{
				ProductName: "螺纹钢", Quantity: mustQuantityValue(t, "10"),
				UnitPrice: mustPriceValue(t, "3000"), PriceTaxMode: document.PriceTaxIncluded,
			}},
		}},
	}, "src-draft")
	if err != nil {
		t.Fatalf("Create(draft) error = %v", err)
	}
	if draftDoc.Status != document.StatusDraft {
		t.Fatalf("draft status = %q", draftDoc.Status)
	}

	if inboundOwner.TotalAmount.String() != "100000.00" || outboundOwner.TotalAmount.String() != "180000.00" ||
		inboundMember.TotalAmount.String() != "50000.00" || inboundReusable.TotalAmount.String() != "70000.00" {
		t.Fatalf("source totals = %s / %s / %s / %s", inboundOwner.TotalAmount, outboundOwner.TotalAmount,
			inboundMember.TotalAmount, inboundReusable.TotalAmount)
	}

	/* ---------------- 2. 主账号提交结算申请：金额快照 + 单号 ---------------- */

	created, err := settlementService.Create(ctx, ownerPrincipal, settlement.CreateRequest{
		Remark: strPtrValue("  五月  第一批  "),
		Sources: []settlement.SourceRequest{
			{DocumentID: inboundOwner.DocumentID},
			{DocumentID: outboundOwner.DocumentID},
			{DocumentID: inboundMember.DocumentID},
		},
	}, "settle-1")
	if err != nil {
		t.Fatalf("Create(settlement) error = %v", err)
	}
	if created.SettlementNo != settlementNumber(t, 1) {
		t.Fatalf("SettlementNo = %q, want %q", created.SettlementNo, settlementNumber(t, 1))
	}
	if created.Status != settlement.StatusPending || created.SourceCount != 3 || created.Version != 1 {
		t.Fatalf("created settlement = %+v", created)
	}
	// 进项 100000.00 + 50000.00 = 150000.00，销售 180000.00，毛利 30000.00。
	if created.InboundTotal.String() != "150000.00" || created.OutboundTotal.String() != "180000.00" {
		t.Fatalf("totals = %s / %s", created.InboundTotal, created.OutboundTotal)
	}
	if created.GrossProfit.String() != "30000.00" {
		t.Fatalf("GrossProfit = %s, want 30000.00", created.GrossProfit)
	}
	// 三项大写由服务端生成，三端共用同一口径。
	if created.InboundUpper != rmb.Upper(created.InboundTotal) ||
		created.OutboundUpper != rmb.Upper(created.OutboundTotal) ||
		created.GrossProfitUpper != rmb.Upper(created.GrossProfit) {
		t.Fatalf("uppercase mismatch: %q / %q / %q", created.InboundUpper, created.OutboundUpper, created.GrossProfitUpper)
	}
	// 备注折叠内部空白。
	if created.Remark == nil || *created.Remark != "五月 第一批" {
		t.Fatalf("remark = %v", created.Remark)
	}
	// 申请本身就是审批链路的第一条记录。
	if len(created.ApprovalRecords) != 1 || created.ApprovalRecords[0].Action != settlement.ActionSubmitted {
		t.Fatalf("approval records = %+v", created.ApprovalRecords)
	}
	// 源单据快照按 kind 升序：两张入库在前、一张出库在后，且都带单号快照。
	if len(created.Sources) != 3 || created.Sources[0].Kind != document.KindInbound ||
		created.Sources[2].Kind != document.KindOutbound {
		t.Fatalf("sources = %+v", created.Sources)
	}
	if created.Sources[0].DocumentNo != inboundOwner.DocumentNo || created.Sources[0].Released {
		t.Fatalf("first source = %+v", created.Sources[0])
	}
	if created.Requester.ID != ownerUser.ID || created.Requester.DisplayName != "结算主账号" {
		t.Fatalf("requester = %+v", created.Requester)
	}

	/* ---------------- 3. 幂等重放与源单据占用 ---------------- */

	replayPayload := settlement.CreateRequest{
		Remark: strPtrValue("  五月  第一批  "),
		Sources: []settlement.SourceRequest{
			{DocumentID: inboundOwner.DocumentID},
			{DocumentID: outboundOwner.DocumentID},
			{DocumentID: inboundMember.DocumentID},
		},
	}
	replayed, err := settlementService.Create(ctx, ownerPrincipal, replayPayload, "settle-1")
	if err != nil {
		t.Fatalf("replay Create() error = %v", err)
	}
	if replayed.SettlementID != created.SettlementID {
		t.Fatalf("replayed settlement id = %d, want %d", replayed.SettlementID, created.SettlementID)
	}

	// 同一源单据不允许被第二张有效结算单引用。
	_, err = settlementService.Create(ctx, ownerPrincipal, settlement.CreateRequest{
		Sources: []settlement.SourceRequest{{DocumentID: inboundOwner.DocumentID}},
	}, "settle-conflict")
	assertIntegrationCode(t, err, apperror.CodeSettlementSourceConflict)

	// 草稿单不允许参与结算。
	_, err = settlementService.Create(ctx, ownerPrincipal, settlement.CreateRequest{
		Sources: []settlement.SourceRequest{{DocumentID: draftDoc.DocumentID}},
	}, "settle-draft")
	assertIntegrationCode(t, err, apperror.CodeSettlementSourceInvalid)

	// 同一张源单据在一次请求里重复出现也要被拒。
	_, err = settlementService.Create(ctx, ownerPrincipal, settlement.CreateRequest{
		Sources: []settlement.SourceRequest{{DocumentID: inboundReusable.DocumentID}, {DocumentID: inboundReusable.DocumentID}},
	}, "settle-duplicate")
	assertIntegrationCode(t, err, apperror.CodeValidationFailed)

	// 子账号未持有 view_others：不能结算他人单据、看不到他人结算单、也不能审批。
	_, err = settlementService.Create(ctx, memberPrincipal, settlement.CreateRequest{
		Sources: []settlement.SourceRequest{{DocumentID: inboundReusable.DocumentID}},
	}, "settle-member-denied")
	assertIntegrationCode(t, err, apperror.CodeForbidden)

	memberPage, err := settlementService.List(ctx, memberPrincipal, settlement.ListQuery{})
	if err != nil {
		t.Fatalf("member List() error = %v", err)
	}
	if memberPage.Total != 0 {
		t.Fatalf("member List() total = %d, want 0", memberPage.Total)
	}
	_, err = settlementService.Get(ctx, memberPrincipal, created.SettlementID)
	assertIntegrationCode(t, err, apperror.CodeForbidden)
	_, err = settlementService.Approve(ctx, memberPrincipal, created.SettlementID, settlement.DecideRequest{Version: created.Version})
	assertIntegrationCode(t, err, apperror.CodeForbidden)

	/* ---------------- 4. 授信后可见范围放开 ---------------- */

	if _, err := memberService.ReplacePermissions(ctx, ownerPrincipal, memberMembership.ID, member.ReplacePermissionsRequest{
		PermissionCodes: []authorization.Code{authorization.PermissionDocumentViewOthers}, Version: 1,
	}); err != nil {
		t.Fatalf("ReplacePermissions(view others) error = %v", err)
	}
	if _, err := settlementService.Get(ctx, memberPrincipal, created.SettlementID); err != nil {
		t.Fatalf("member Get(with view_others) error = %v", err)
	}
	memberPage, err = settlementService.List(ctx, memberPrincipal, settlement.ListQuery{})
	if err != nil {
		t.Fatalf("member List(with view_others) error = %v", err)
	}
	if memberPage.Total != 1 {
		t.Fatalf("member List(with view_others) total = %d, want 1", memberPage.Total)
	}
	// view_others 不等于可以审批：审批资格由 settlement.approve 单独控制。
	_, err = settlementService.Approve(ctx, memberPrincipal, created.SettlementID, settlement.DecideRequest{Version: created.Version})
	assertIntegrationCode(t, err, apperror.CodeForbidden)

	/* ---------------- 5. 乐观锁与单级审批终态 ---------------- */

	_, err = settlementService.Approve(ctx, ownerPrincipal, created.SettlementID, settlement.DecideRequest{
		Version: created.Version + 1,
	})
	assertIntegrationCode(t, err, apperror.CodeResourceVersionConflict)

	approved, err := settlementService.Approve(ctx, ownerPrincipal, created.SettlementID, settlement.DecideRequest{
		Version: created.Version,
	})
	if err != nil {
		t.Fatalf("Approve() error = %v", err)
	}
	if approved.Status != settlement.StatusApproved || approved.Version != created.Version+1 {
		t.Fatalf("approved settlement = %+v", approved)
	}
	if approved.DecidedBy == nil || approved.DecidedBy.ID != ownerUser.ID {
		t.Fatalf("decided_by = %+v", approved.DecidedBy)
	}
	if len(approved.ApprovalRecords) != 2 || approved.ApprovalRecords[1].Action != settlement.ActionApproved {
		t.Fatalf("approval records = %+v", approved.ApprovalRecords)
	}
	// 审批通过不释放源单据：通过意味着这批次金额已经被采纳。
	_, err = settlementService.Create(ctx, ownerPrincipal, settlement.CreateRequest{
		Sources: []settlement.SourceRequest{{DocumentID: inboundOwner.DocumentID}},
	}, "settle-after-approve")
	assertIntegrationCode(t, err, apperror.CodeSettlementSourceConflict)

	// 单级审批：通过与驳回都是终态，重复审批必须冲突。
	_, err = settlementService.Approve(ctx, ownerPrincipal, created.SettlementID, settlement.DecideRequest{
		Version: approved.Version,
	})
	assertIntegrationCode(t, err, apperror.CodeSettlementStatusInvalid)

	/* ---------------- 6. 驳回必填原因，并释放源单据 ---------------- */

	pending, err := settlementService.Create(ctx, ownerPrincipal, settlement.CreateRequest{
		Sources: []settlement.SourceRequest{{DocumentID: inboundReusable.DocumentID}},
	}, "settle-2")
	if err != nil {
		t.Fatalf("Create(second settlement) error = %v", err)
	}
	if pending.SettlementNo != settlementNumber(t, 2) {
		t.Fatalf("second SettlementNo = %q, want %q", pending.SettlementNo, settlementNumber(t, 2))
	}

	_, err = settlementService.Reject(ctx, ownerPrincipal, pending.SettlementID, settlement.DecideRequest{Version: pending.Version})
	assertIntegrationCode(t, err, apperror.CodeSettlementRemarkRequired)

	rejected, err := settlementService.Reject(ctx, ownerPrincipal, pending.SettlementID, settlement.DecideRequest{
		Version: pending.Version, Remark: strPtrValue("入库单价填错，已让业务员改单"),
	})
	if err != nil {
		t.Fatalf("Reject() error = %v", err)
	}
	if rejected.Status != settlement.StatusRejected || rejected.Version != pending.Version+1 {
		t.Fatalf("rejected settlement = %+v", rejected)
	}
	// 驳回后源单据被释放：关联行保留（可追溯），但已不占用唯一索引。
	if len(rejected.Sources) != 1 || !rejected.Sources[0].Released {
		t.Fatalf("released sources = %+v", rejected.Sources)
	}
	if rejected.DecisionRemark == nil || *rejected.DecisionRemark != "入库单价填错，已让业务员改单" {
		t.Fatalf("decision remark = %v", rejected.DecisionRemark)
	}

	// 释放后可以重新申请：这正是不用「软删除」而是用「活跃引用置 NULL」的原因。
	recreated, err := settlementService.Create(ctx, ownerPrincipal, settlement.CreateRequest{
		Sources: []settlement.SourceRequest{{DocumentID: inboundReusable.DocumentID}},
	}, "settle-3")
	if err != nil {
		t.Fatalf("Create(after release) error = %v", err)
	}
	if recreated.SettlementNo != settlementNumber(t, 3) {
		t.Fatalf("recreated SettlementNo = %q, want %q", recreated.SettlementNo, settlementNumber(t, 3))
	}

	/* ---------------- 7. 列表过滤 ---------------- */

	month := time.Now().UTC().Format("2006-01")
	allPage, err := settlementService.List(ctx, ownerPrincipal, settlement.ListQuery{})
	if err != nil {
		t.Fatalf("List() error = %v", err)
	}
	if allPage.Total != 3 {
		t.Fatalf("List() total = %d, want 3", allPage.Total)
	}
	// 按月份过滤：三张都在本月创建。
	monthPage, err := settlementService.List(ctx, ownerPrincipal, settlement.ListQuery{Month: month})
	if err != nil {
		t.Fatalf("List(month=%s) error = %v", month, err)
	}
	if monthPage.Total != 3 {
		t.Fatalf("List(month) total = %d, want 3", monthPage.Total)
	}
	// 按状态过滤：只有第二张被驳回。
	rejectedPage, err := settlementService.List(ctx, ownerPrincipal, settlement.ListQuery{Status: settlement.StatusRejected})
	if err != nil {
		t.Fatalf("List(status=rejected) error = %v", err)
	}
	if rejectedPage.Total != 1 || rejectedPage.Items[0].SettlementID != pending.SettlementID {
		t.Fatalf("rejected page = %+v", rejectedPage.Items)
	}
	// 关键词按单号过滤。
	keywordPage, err := settlementService.List(ctx, ownerPrincipal, settlement.ListQuery{Keyword: created.SettlementNo})
	if err != nil {
		t.Fatalf("List(keyword) error = %v", err)
	}
	if keywordPage.Total != 1 || keywordPage.Items[0].SettlementNo != created.SettlementNo {
		t.Fatalf("keyword page = %+v", keywordPage.Items)
	}
	// 列表行的申请人必须是完整用户对象，不能只回填姓名。
	if keywordPage.Items[0].Requester.Username != ownerUser.Username ||
		keywordPage.Items[0].Requester.AccountType != identity.AccountTypeGroupOwner {
		t.Fatalf("list requester = %+v", keywordPage.Items[0].Requester)
	}
	// 分页参数非法要报校验错误，而不是把整表拉出来。
	if _, err := settlementService.List(ctx, ownerPrincipal, settlement.ListQuery{PageSize: 101}); err != nil {
		assertIntegrationCode(t, err, apperror.CodeValidationFailed)
	} else {
		t.Fatal("List(page_size=101) = nil error, want VALIDATION_FAILED")
	}
}

// createSubmittedDocument 造一张金额确定的单据并提交，供结算 / 汇总引用。
//
// 出库单在提交时必须带销售金额类型（validateCompleteness 会返回 DOCUMENT_INCOMPLETE），
// 因此这里额外接收 saleAmountType：入库单传 nil，出库单必须传一个合法类型。
// 之前漏了这一项，导致所有「出库单 + 提交」的集成测试实际上都跑不过。
func createSubmittedDocument(
	t *testing.T,
	ctx context.Context,
	service *document.Service,
	principal identity.Principal,
	kind document.Kind,
	businessDate, partyName, quantity, unitPrice string,
	saleAmountType *document.SaleAmountType,
	idempotencyKey string,
) *document.DocumentData {
	t.Helper()
	created, err := service.Create(ctx, principal, kind, document.CreateRequest{
		Status: document.StatusDraft, BusinessDate: businessDate,
		SaleAmountType: saleAmountType,
		Parties: []document.PartyRequest{{
			PartyName: partyName,
			Items: []document.ItemRequest{{
				ProductName: "螺纹钢", Quantity: mustQuantityValue(t, quantity),
				UnitPrice: mustPriceValue(t, unitPrice), PriceTaxMode: document.PriceTaxIncluded,
			}},
		}},
	}, idempotencyKey)
	if err != nil {
		t.Fatalf("Create(%s) error = %v", kind, err)
	}
	submitted, err := service.Submit(ctx, principal, kind, created.DocumentID, document.VersionRequest{Version: created.Version})
	if err != nil {
		t.Fatalf("Submit(%s) error = %v", kind, err)
	}
	if submitted.Status != document.StatusSubmitted {
		t.Fatalf("submitted status = %q", submitted.Status)
	}
	return submitted
}

// saleAmountTypePointer 返回销售金额类型的指针，便于传给出库单创建请求。
func saleAmountTypePointer(value document.SaleAmountType) *document.SaleAmountType {
	return &value
}

// settlementNumber 按「JS + 当月年月 + 4 位序号」拼出期望单号。
// 结算单号取自服务端当前时间，因此测试也从当前时间推导，避免写死月份。
func settlementNumber(t *testing.T, sequence int) string {
	t.Helper()
	return fmt.Sprintf("JS%s-%04d", time.Now().UTC().Format("200601"), sequence)
}
