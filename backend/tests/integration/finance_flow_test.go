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
	"CBizDocsManager/backend/pkg/apperror"
)

// TestFinanceRecordFlow 用真实 MySQL 覆盖付款 / 收款 / 开票主链路：
//
//	累计额度（事务内锁单据行 + SUM）→ 幂等重放与幂等键释放 → 记录类型与单据类型配对
//	→ 撤销后额度回收 → 三类金额与开票状态推导 → 数据范围与权限收敛 → 列表过滤与分页
//	→ 跨组隔离。
//
// 之所以必须走真实方言：累计上限依赖 InnoDB 的行锁（SELECT ... FOR UPDATE）把同一张单据上的
// 并发登记串行化，SQLite 的内存桩无法体现该语义；金额列是 DECIMAL(18,2)，回读精度也必须真实。
func TestFinanceRecordFlow(t *testing.T) {
	db := openAuthFlowMySQL(t)
	ctx := context.Background()
	passwords := identity.NewPasswordManager()

	ownerHash, err := passwords.Hash("finance-owner-password")
	if err != nil {
		t.Fatalf("hash owner password: %v", err)
	}
	memberHash, err := passwords.Hash("finance-member-password")
	if err != nil {
		t.Fatalf("hash member password: %v", err)
	}
	outsiderHash, err := passwords.Hash("finance-outsider-password")
	if err != nil {
		t.Fatalf("hash outsider password: %v", err)
	}

	ownerUser := identity.User{
		Username: "finance-owner", PasswordHash: ownerHash, DisplayName: "财务主账号",
		AccountType: identity.AccountTypeGroupOwner, Status: identity.UserStatusActive,
	}
	memberUser := identity.User{
		Username: "finance-member", PasswordHash: memberHash, DisplayName: "财务业务员",
		AccountType: identity.AccountTypeMember, Status: identity.UserStatusActive,
	}
	outsiderUser := identity.User{
		Username: "finance-outsider", PasswordHash: outsiderHash, DisplayName: "别组主账号",
		AccountType: identity.AccountTypeGroupOwner, Status: identity.UserStatusActive,
	}
	for _, user := range []*identity.User{&ownerUser, &memberUser, &outsiderUser} {
		if err := db.Create(user).Error; err != nil {
			t.Fatalf("seed user: %v", err)
		}
	}

	group := organization.Group{
		Name: "财务流转组", Status: organization.GroupStatusActive,
		OwnerUserID: ownerUser.ID, CreatedBy: ownerUser.ID,
	}
	otherGroup := organization.Group{
		Name: "财务对照组", Status: organization.GroupStatusActive,
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
	// 业务日期固定，发生日期用「2026年5月12日」这种手写写法，顺带验证与单据同一套解析口径。
	businessDate := "2026-05-12"
	occurredOn := "2026年5月12日"

	/* ---------------- 1. 准备单据：主账号入库 / 出库、业务员入库、一张草稿 ---------------- */

	inbound := createSubmittedDocument(t, ctx, documentService, ownerPrincipal,
		document.KindInbound, businessDate, "北京钢铁贸易有限公司", "40", "2500", "fin-src-in")
	outbound := createSubmittedDocument(t, ctx, documentService, ownerPrincipal,
		document.KindOutbound, businessDate, "天津建筑集团", "60", "3000", "fin-src-out")
	memberInbound := createSubmittedDocument(t, ctx, documentService, memberPrincipal,
		document.KindInbound, businessDate, "河北钢材市场", "25", "2000", "fin-src-in-member")

	draft, err := documentService.Create(ctx, ownerPrincipal, document.KindInbound, document.CreateRequest{
		Status: document.StatusDraft, BusinessDate: businessDate,
		Parties: []document.PartyRequest{{
			PartyName: "草稿供应商",
			Items: []document.ItemRequest{{
				ProductName: "螺纹钢", Quantity: mustQuantityValue(t, "10"),
				UnitPrice: mustPriceValue(t, "3000"), PriceTaxMode: document.PriceTaxIncluded,
			}},
		}},
	}, "fin-src-draft")
	if err != nil {
		t.Fatalf("Create(draft) error = %v", err)
	}

	if inbound.TotalAmount.String() != "100000.00" || outbound.TotalAmount.String() != "180000.00" ||
		memberInbound.TotalAmount.String() != "50000.00" {
		t.Fatalf("source totals = %s / %s / %s", inbound.TotalAmount, outbound.TotalAmount, memberInbound.TotalAmount)
	}

	/* ---------------- 2. 登记付款：单据快照、结清推导、幂等重放 ---------------- */

	first, err := financeService.Create(ctx, ownerPrincipal, finance.KindPayment, finance.CreateRequest{
		DocumentID: inbound.DocumentID, Amount: "30000.00", OccurredOn: occurredOn,
		Method: "transfer", MethodNote: strPtrValue("微信"),
	}, "fin-pay-1")
	if err != nil {
		t.Fatalf("Create(payment) error = %v", err)
	}
	if first.PaidAmount.String() != "30000.00" || first.UnpaidAmount.String() != "70000.00" {
		t.Fatalf("paid/unpaid = %s / %s", first.PaidAmount, first.UnpaidAmount)
	}
	if first.DocumentNo != inbound.DocumentNo || first.PartyName != "北京钢铁贸易有限公司" {
		t.Fatalf("statement document = %+v", first)
	}
	if first.PaymentCount != 1 || len(first.Records) != 1 || first.InvoiceCount != 0 || first.ReceiptCount != 0 {
		t.Fatalf("statement counts = %+v", first)
	}
	// 入库单只暴露付款与开票口径，收款方向必须是 0；开票状态尚未开票。
	if first.ReceivedAmount != 0 || first.UnreceivedAmount != 0 {
		t.Fatalf("入库单结清视图混入了收款口径: %+v", first)
	}
	if first.InvoiceStatus != finance.InvoiceStatusNone || first.UninvoicedAmount.String() != "100000.00" {
		t.Fatalf("invoice status = %s / uninvoiced = %s", first.InvoiceStatus, first.UninvoicedAmount)
	}
	if first.TotalUpper == "" || first.PaidUpper == "" || first.UnpaidUpper == "" || first.UninvoicedUpper == "" {
		t.Fatal("结清视图缺少人民币大写")
	}
	// 列表行必须带完整用户摘要，否则客户端会渲染出空白业务员列。
	if first.BusinessUser.Username != ownerUser.Username || first.BusinessUser.AccountType != identity.AccountTypeGroupOwner {
		t.Fatalf("statement business user = %+v", first.BusinessUser)
	}
	if first.Records[0].OccurredOn != "2026-05-12" || first.Records[0].AmountUpper == "" {
		t.Fatalf("record row = %+v", first.Records[0])
	}
	paymentRecordID := first.Records[0].RecordID

	// 幂等重放：同一个键 + 同样内容不应该产生第二条记录。
	replayed, err := financeService.Create(ctx, ownerPrincipal, finance.KindPayment, finance.CreateRequest{
		DocumentID: inbound.DocumentID, Amount: "30000.00", OccurredOn: occurredOn,
		Method: "transfer", MethodNote: strPtrValue("微信"),
	}, "fin-pay-1")
	if err != nil {
		t.Fatalf("Create(replay) error = %v", err)
	}
	if replayed.PaymentCount != 1 || len(replayed.Records) != 1 {
		t.Fatalf("幂等重放产生了重复记录: %+v", replayed.Records)
	}

	// 同一个键换内容 = 客户端复用了幂等键。
	_, err = financeService.Create(ctx, ownerPrincipal, finance.KindPayment, finance.CreateRequest{
		DocumentID: inbound.DocumentID, Amount: "31000.00", OccurredOn: occurredOn, Method: "transfer",
	}, "fin-pay-1")
	assertIntegrationCode(t, err, apperror.CodeIdempotencyKeyReused)

	/* ---------------- 3. 累计上限：不得超过单据总额，恰好等于允许 ---------------- */

	_, err = financeService.Create(ctx, ownerPrincipal, finance.KindPayment, finance.CreateRequest{
		DocumentID: inbound.DocumentID, Amount: "80000.00", OccurredOn: occurredOn, Method: "transfer",
	}, "fin-pay-2")
	assertIntegrationCode(t, err, apperror.CodeFinanceAmountExceeds)

	settled, err := financeService.Create(ctx, ownerPrincipal, finance.KindPayment, finance.CreateRequest{
		DocumentID: inbound.DocumentID, Amount: "70000.00", OccurredOn: occurredOn, Method: "public_account",
	}, "fin-pay-3")
	if err != nil {
		t.Fatalf("Create(payment to ceiling) error = %v", err)
	}
	if settled.PaidAmount.String() != "100000.00" || settled.UnpaidAmount.String() != "0.00" {
		t.Fatalf("付满后的结清视图 = %s / %s", settled.PaidAmount, settled.UnpaidAmount)
	}
	// 付满之后再付 1 分也要拒绝：说明看的是库里的实时合计。
	_, err = financeService.Create(ctx, ownerPrincipal, finance.KindPayment, finance.CreateRequest{
		DocumentID: inbound.DocumentID, Amount: "0.01", OccurredOn: occurredOn, Method: "transfer",
	}, "fin-pay-4")
	assertIntegrationCode(t, err, apperror.CodeFinanceAmountExceeds)

	/* ---------------- 4. 开票额度与付款额度互相独立 ---------------- */

	partial, err := financeService.Create(ctx, ownerPrincipal, finance.KindInvoice, finance.CreateRequest{
		DocumentID: inbound.DocumentID, Amount: "40000.00", OccurredOn: occurredOn, InvoiceNo: strPtrValue("INV-20260512-01"),
	}, "fin-inv-1")
	if err != nil {
		t.Fatalf("Create(invoice) error = %v", err)
	}
	if partial.InvoiceStatus != finance.InvoiceStatusPartial || partial.InvoicedAmount.String() != "40000.00" ||
		partial.UninvoicedAmount.String() != "60000.00" {
		t.Fatalf("部分开票结清视图 = %s / %s / %s", partial.InvoiceStatus, partial.InvoicedAmount, partial.UninvoicedAmount)
	}
	full, err := financeService.Create(ctx, ownerPrincipal, finance.KindInvoice, finance.CreateRequest{
		DocumentID: inbound.DocumentID, Amount: "60000.00", OccurredOn: occurredOn,
	}, "fin-inv-2")
	if err != nil {
		t.Fatalf("Create(invoice to ceiling) error = %v", err)
	}
	if full.InvoiceStatus != finance.InvoiceStatusFull || full.InvoiceCount != 2 || full.UninvoicedAmount.String() != "0.00" {
		t.Fatalf("开满后的结清视图 = %s / %d / %s", full.InvoiceStatus, full.InvoiceCount, full.UninvoicedAmount)
	}
	// 付满 + 开满后都能继续读，且两类额度互不影响。
	if full.PaidAmount.String() != "100000.00" {
		t.Fatalf("开票不应影响付款额度: %s", full.PaidAmount)
	}

	/* ---------------- 5. 字段校验：不匹配的字段一律报错而不是被静默忽略 ---------------- */

	invalidCases := []struct {
		name    string
		kind    finance.Kind
		request finance.CreateRequest
	}{
		{name: "金额为零", kind: finance.KindPayment,
			request: finance.CreateRequest{DocumentID: inbound.DocumentID, Amount: "0.00", OccurredOn: occurredOn, Method: "transfer"}},
		{name: "金额为负", kind: finance.KindPayment,
			request: finance.CreateRequest{DocumentID: inbound.DocumentID, Amount: "-1.00", OccurredOn: occurredOn, Method: "transfer"}},
		{name: "发生日期非法", kind: finance.KindPayment,
			request: finance.CreateRequest{DocumentID: inbound.DocumentID, Amount: "1.00", OccurredOn: "昨天", Method: "transfer"}},
		{name: "转账不允许卡尾号", kind: finance.KindPayment,
			request: finance.CreateRequest{DocumentID: inbound.DocumentID, Amount: "1.00", OccurredOn: occurredOn, Method: "transfer", CardTail: strPtrValue("1234")}},
		{name: "对私卡必须带卡尾号", kind: finance.KindPayment,
			request: finance.CreateRequest{DocumentID: inbound.DocumentID, Amount: "1.00", OccurredOn: occurredOn, Method: "private_card"}},
		{name: "开票不允许带付款方式", kind: finance.KindInvoice,
			request: finance.CreateRequest{DocumentID: inbound.DocumentID, Amount: "1.00", OccurredOn: occurredOn, Method: "transfer"}},
		{name: "付款不允许带发票号", kind: finance.KindPayment,
			request: finance.CreateRequest{DocumentID: inbound.DocumentID, Amount: "1.00", OccurredOn: occurredOn, Method: "transfer", InvoiceNo: strPtrValue("INV-X")}},
	}
	for _, tt := range invalidCases {
		t.Run(tt.name, func(t *testing.T) {
			_, err := financeService.Create(ctx, ownerPrincipal, tt.kind, tt.request, "")
			assertIntegrationCode(t, err, apperror.CodeValidationFailed)
		})
	}

	/* ---------------- 6. 记录类型与单据类型配对、单据状态 ---------------- */

	_, err = financeService.Create(ctx, ownerPrincipal, finance.KindReceipt, finance.CreateRequest{
		DocumentID: inbound.DocumentID, Amount: "1.00", OccurredOn: occurredOn, Method: "transfer",
	}, "")
	assertIntegrationCode(t, err, apperror.CodeFinanceDocumentMismatch)

	_, err = financeService.Create(ctx, ownerPrincipal, finance.KindPayment, finance.CreateRequest{
		DocumentID: outbound.DocumentID, Amount: "1.00", OccurredOn: occurredOn, Method: "transfer",
	}, "")
	assertIntegrationCode(t, err, apperror.CodeFinanceDocumentMismatch)

	_, err = financeService.Create(ctx, ownerPrincipal, finance.KindInvoice, finance.CreateRequest{
		DocumentID: outbound.DocumentID, Amount: "1.00", OccurredOn: occurredOn,
	}, "")
	assertIntegrationCode(t, err, apperror.CodeFinanceDocumentMismatch)

	// 草稿单金额还没定，不允许产生财务记录。
	_, err = financeService.Create(ctx, ownerPrincipal, finance.KindPayment, finance.CreateRequest{
		DocumentID: draft.DocumentID, Amount: "1.00", OccurredOn: occurredOn, Method: "transfer",
	}, "")
	assertIntegrationCode(t, err, apperror.CodeDocumentStatusInvalid)

	// 不存在的单据按「找不到」处理。
	_, err = financeService.Create(ctx, ownerPrincipal, finance.KindPayment, finance.CreateRequest{
		DocumentID: 999999, Amount: "1.00", OccurredOn: occurredOn, Method: "transfer",
	}, "")
	assertIntegrationCode(t, err, apperror.CodeDocumentNotFound)

	/* ---------------- 7. 收款挂出库单：对私卡只留后 4 位 ---------------- */

	receipt, err := financeService.Create(ctx, ownerPrincipal, finance.KindReceipt, finance.CreateRequest{
		DocumentID: outbound.DocumentID, Amount: "80000.00", OccurredOn: businessDate,
		Method: "private_card", CardTail: strPtrValue("8899"),
	}, "fin-recv-1")
	if err != nil {
		t.Fatalf("Create(receipt) error = %v", err)
	}
	if receipt.ReceivedAmount.String() != "80000.00" || receipt.UnreceivedAmount.String() != "100000.00" {
		t.Fatalf("received/unreceived = %s / %s", receipt.ReceivedAmount, receipt.UnreceivedAmount)
	}
	// 出库单方向不适用付款与开票：必须为 0 / not_applicable，不能返回「总额」误导客户端。
	if receipt.PaidAmount != 0 || receipt.UnpaidAmount != 0 || receipt.InvoicedAmount != 0 || receipt.UninvoicedAmount != 0 {
		t.Fatalf("出库单结清视图混入了其他口径: %+v", receipt)
	}
	if receipt.InvoiceStatus != finance.InvoiceStatusNotApplicable {
		t.Fatalf("出库单开票状态 = %s, want not_applicable", receipt.InvoiceStatus)
	}
	if receipt.Records[0].CardTail == nil || *receipt.Records[0].CardTail != "8899" {
		t.Fatalf("卡尾号 = %v", receipt.Records[0].CardTail)
	}

	/* ---------------- 8. 撤销：额度回收 + 幂等键随之释放 ---------------- */

	revoked, err := financeService.Revoke(ctx, ownerPrincipal, finance.KindPayment, paymentRecordID)
	if err != nil {
		t.Fatalf("Revoke() error = %v", err)
	}
	if revoked.PaidAmount.String() != "70000.00" || revoked.UnpaidAmount.String() != "30000.00" {
		t.Fatalf("撤销后的结清视图 = %s / %s", revoked.PaidAmount, revoked.UnpaidAmount)
	}
	if revoked.PaymentCount != 1 {
		t.Fatalf("撤销后付款笔数 = %d, want 1", revoked.PaymentCount)
	}
	// 撤销释放了额度：可以重新登记到满额。
	if _, err := financeService.Create(ctx, ownerPrincipal, finance.KindPayment, finance.CreateRequest{
		DocumentID: inbound.DocumentID, Amount: "30000.00", OccurredOn: occurredOn, Method: "transfer",
	}, "fin-pay-5"); err != nil {
		t.Fatalf("撤销后重新登记 error = %v", err)
	}
	// 幂等记录随记录一起释放：重放最开始的键会重新登记，而不是读到已删除的记录。
	recreated, err := financeService.Create(ctx, ownerPrincipal, finance.KindPayment, finance.CreateRequest{
		DocumentID: inbound.DocumentID, Amount: "30000.00", OccurredOn: occurredOn,
		Method: "transfer", MethodNote: strPtrValue("微信"),
	}, "fin-pay-1")
	if err != nil {
		t.Fatalf("撤销后重放同一个幂等键 error = %v", err)
	}
	if recreated.PaidAmount.String() != "100000.00" {
		t.Fatalf("重放后的已付金额 = %s, want 100000.00", recreated.PaidAmount)
	}
	// 取一条当前仍存在的付款记录，用于验证「用错记录类型的接口」这一分支。
	var livePaymentID uint64
	for _, record := range recreated.Records {
		if record.Kind == finance.KindPayment {
			livePaymentID = record.RecordID
			break
		}
	}
	if livePaymentID == 0 {
		t.Fatal("未找到仍然存在的付款记录")
	}

	// 撤销不存在的记录、以及用收款接口撤销付款记录，都按「记录不存在」处理。
	_, err = financeService.Revoke(ctx, ownerPrincipal, finance.KindPayment, 999999)
	assertIntegrationCode(t, err, apperror.CodeFinanceRecordNotFound)
	_, err = financeService.Revoke(ctx, ownerPrincipal, finance.KindReceipt, livePaymentID)
	assertIntegrationCode(t, err, apperror.CodeFinanceRecordNotFound)
	// 撤销后记录仍然存在（上一步并没有真的删掉它），额度也没有被误放。
	afterFailedRevoke, err := financeService.Statement(ctx, ownerPrincipal, inbound.DocumentID)
	if err != nil {
		t.Fatalf("Statement(after failed revoke) error = %v", err)
	}
	if afterFailedRevoke.PaidAmount.String() != "100000.00" {
		t.Fatalf("用错接口不应影响数据: paid = %s", afterFailedRevoke.PaidAmount)
	}

	/* ---------------- 9. 业务员：数据范围与 finance.record 权限 ---------------- */

	// 只授予记账权限时，业务员可以给自己经手的单据记账。
	if _, err := memberService.ReplacePermissions(ctx, ownerPrincipal, memberMembership.ID, member.ReplacePermissionsRequest{
		PermissionCodes: []authorization.Code{authorization.PermissionFinanceRecord}, Version: 1,
	}); err != nil {
		t.Fatalf("ReplacePermissions(finance.record) error = %v", err)
	}
	memberStatement, err := financeService.Create(ctx, memberPrincipal, finance.KindPayment, finance.CreateRequest{
		DocumentID: memberInbound.DocumentID, Amount: "10000.00", OccurredOn: businessDate, Method: "public_account",
	}, "fin-pay-member-1")
	if err != nil {
		t.Fatalf("member Create(own document) error = %v", err)
	}
	if memberStatement.PaidAmount.String() != "10000.00" {
		t.Fatalf("member paid = %s", memberStatement.PaidAmount)
	}

	// 他人单据：没有 document.view_others 时既不能记账也不能读结清视图。
	_, err = financeService.Create(ctx, memberPrincipal, finance.KindPayment, finance.CreateRequest{
		DocumentID: inbound.DocumentID, Amount: "1000.00", OccurredOn: businessDate, Method: "transfer",
	}, "fin-pay-member-2")
	assertIntegrationCode(t, err, apperror.CodeForbidden)

	_, err = financeService.Statement(ctx, memberPrincipal, outbound.DocumentID)
	assertIntegrationCode(t, err, apperror.CodeForbidden)

	memberPage, err := financeService.List(ctx, memberPrincipal, finance.KindPayment, finance.ListQuery{})
	if err != nil {
		t.Fatalf("member List() error = %v", err)
	}
	if memberPage.Total != 1 || memberPage.Items[0].Amount.String() != "10000.00" {
		t.Fatalf("业务员默认只看本人: %+v", memberPage.Items)
	}
	_, err = financeService.List(ctx, memberPrincipal, finance.KindPayment, finance.ListQuery{BusinessUserID: ownerUser.ID})
	assertIntegrationCode(t, err, apperror.CodeForbidden)

	// 授予 view_others 后可以看全组，并能按业务员过滤。
	if _, err := memberService.ReplacePermissions(ctx, ownerPrincipal, memberMembership.ID, member.ReplacePermissionsRequest{
		PermissionCodes: []authorization.Code{
			authorization.PermissionFinanceRecord, authorization.PermissionDocumentViewOthers,
		}, Version: 2,
	}); err != nil {
		t.Fatalf("ReplacePermissions(view others) error = %v", err)
	}
	memberPage, err = financeService.List(ctx, memberPrincipal, finance.KindPayment, finance.ListQuery{})
	if err != nil {
		t.Fatalf("member List(with view_others) error = %v", err)
	}
	// 组内付款共 3 笔：70000 / 30000 / 业务员自己的 10000。
	if memberPage.Total != 3 {
		t.Fatalf("member List(with view_others) total = %d, want 3", memberPage.Total)
	}
	ownerOnly, err := financeService.List(ctx, memberPrincipal, finance.KindPayment, finance.ListQuery{BusinessUserID: ownerUser.ID})
	if err != nil {
		t.Fatalf("member List(business_user_id=owner) error = %v", err)
	}
	if ownerOnly.Total != 2 {
		t.Fatalf("按业务员过滤 total = %d, want 2", ownerOnly.Total)
	}
	if _, err := financeService.Statement(ctx, memberPrincipal, outbound.DocumentID); err != nil {
		t.Fatalf("member Statement(with view_others) error = %v", err)
	}

	// 跨组完全不可见：别组主账号读本组单据只会得到「单据不存在」。
	_, err = financeService.Create(ctx, outsiderPrincipal, finance.KindPayment, finance.CreateRequest{
		DocumentID: inbound.DocumentID, Amount: "1.00", OccurredOn: businessDate, Method: "transfer",
	}, "fin-pay-outsider")
	assertIntegrationCode(t, err, apperror.CodeDocumentNotFound)
	_, err = financeService.Statement(ctx, outsiderPrincipal, inbound.DocumentID)
	assertIntegrationCode(t, err, apperror.CodeDocumentNotFound)

	/* ---------------- 10. 列表过滤、分页与结清视图读取 ---------------- */

	paymentPage, err := financeService.List(ctx, ownerPrincipal, finance.KindPayment, finance.ListQuery{})
	if err != nil {
		t.Fatalf("List() error = %v", err)
	}
	if paymentPage.Total != 3 || paymentPage.Page != 1 || paymentPage.PageSize != 20 {
		t.Fatalf("默认列表 = total %d / page %d / size %d", paymentPage.Total, paymentPage.Page, paymentPage.PageSize)
	}
	// 列表按发生日期倒序，同日再按 ID 倒序。
	for index := 1; index < len(paymentPage.Items); index++ {
		if paymentPage.Items[index-1].RecordID <= paymentPage.Items[index].RecordID {
			t.Fatalf("列表顺序不是按 ID 倒序: %+v", paymentPage.Items)
		}
	}
	if paymentPage.Items[0].DocumentNo == "" || paymentPage.Items[0].AmountUpper == "" ||
		paymentPage.Items[0].CreatedBy.Username == "" {
		t.Fatalf("列表行缺少快照或用户摘要: %+v", paymentPage.Items[0])
	}

	byDocument, err := financeService.List(ctx, ownerPrincipal, finance.KindPayment, finance.ListQuery{
		DocumentID: inbound.DocumentID,
	})
	if err != nil {
		t.Fatalf("List(document_id) error = %v", err)
	}
	if byDocument.Total != 2 {
		t.Fatalf("按单据过滤 total = %d, want 2", byDocument.Total)
	}

	byKeyword, err := financeService.List(ctx, ownerPrincipal, finance.KindPayment, finance.ListQuery{
		Keyword: inbound.DocumentNo,
	})
	if err != nil {
		t.Fatalf("List(keyword) error = %v", err)
	}
	if byKeyword.Total != 2 {
		t.Fatalf("按单号关键词过滤 total = %d, want 2", byKeyword.Total)
	}

	byMethod, err := financeService.List(ctx, ownerPrincipal, finance.KindPayment, finance.ListQuery{
		Method: finance.MethodPublicAccount,
	})
	if err != nil {
		t.Fatalf("List(method) error = %v", err)
	}
	if byMethod.Total != 2 {
		t.Fatalf("按方式过滤 total = %d, want 2", byMethod.Total)
	}

	// 月份按「发生日期」过滤，与单据业务日期不是同一个字段。
	byMonth, err := financeService.List(ctx, ownerPrincipal, finance.KindPayment, finance.ListQuery{Month: "2026-05"})
	if err != nil {
		t.Fatalf("List(month) error = %v", err)
	}
	if byMonth.Total != 3 {
		t.Fatalf("按月份过滤 total = %d, want 3", byMonth.Total)
	}
	emptyMonth, err := financeService.List(ctx, ownerPrincipal, finance.KindPayment, finance.ListQuery{Month: "2026-04"})
	if err != nil {
		t.Fatalf("List(empty month) error = %v", err)
	}
	if emptyMonth.Total != 0 {
		t.Fatalf("空月份 total = %d, want 0", emptyMonth.Total)
	}

	// date_to 是闭区间语义：仓储按左闭右开比较，服务层补一天。
	byRange, err := financeService.List(ctx, ownerPrincipal, finance.KindPayment, finance.ListQuery{
		DateFrom: "2026-05-12", DateTo: "2026-05-12",
	})
	if err != nil {
		t.Fatalf("List(date range) error = %v", err)
	}
	if byRange.Total != 3 {
		t.Fatalf("按单日区间过滤 total = %d, want 3", byRange.Total)
	}

	// 分页：当前页条数与匹配总数分开校验。
	firstPage, err := financeService.List(ctx, ownerPrincipal, finance.KindPayment, finance.ListQuery{Page: 1, PageSize: 2})
	if err != nil {
		t.Fatalf("List(page=1) error = %v", err)
	}
	if len(firstPage.Items) != 2 || firstPage.Total != 3 {
		t.Fatalf("首页 = %d 条（total=%d）", len(firstPage.Items), firstPage.Total)
	}
	secondPage, err := financeService.List(ctx, ownerPrincipal, finance.KindPayment, finance.ListQuery{Page: 2, PageSize: 2})
	if err != nil {
		t.Fatalf("List(page=2) error = %v", err)
	}
	if len(secondPage.Items) != 1 || secondPage.Total != 3 {
		t.Fatalf("第二页 = %d 条（total=%d）", len(secondPage.Items), secondPage.Total)
	}
	_, err = financeService.List(ctx, ownerPrincipal, finance.KindPayment, finance.ListQuery{PageSize: 101})
	assertIntegrationCode(t, err, apperror.CodeValidationFailed)

	// 结清视图：一次拿全三类金额与全部明细。
	statement, err := financeService.Statement(ctx, ownerPrincipal, inbound.DocumentID)
	if err != nil {
		t.Fatalf("Statement() error = %v", err)
	}
	if statement.PaidAmount.String() != "100000.00" || statement.UnpaidAmount.String() != "0.00" ||
		statement.InvoicedAmount.String() != "100000.00" || statement.InvoiceStatus != finance.InvoiceStatusFull {
		t.Fatalf("结清视图 = %+v", statement)
	}
	if statement.PaymentCount != 2 || statement.InvoiceCount != 2 || len(statement.Records) != 4 {
		t.Fatalf("结清视图计数 = payment %d / invoice %d / records %d",
			statement.PaymentCount, statement.InvoiceCount, len(statement.Records))
	}
	// 明细按发生日期、ID 升序返回，客户端可直接顺序渲染流水。
	if statement.Records[0].Kind != finance.KindPayment {
		t.Fatalf("明细首行应为付款: %+v", statement.Records[0])
	}
	for index := 1; index < len(statement.Records); index++ {
		if statement.Records[index-1].RecordID >= statement.Records[index].RecordID {
			t.Fatalf("明细顺序不是按 ID 升序: %+v", statement.Records)
		}
	}
	if _, err := financeService.Statement(ctx, ownerPrincipal, 999999); err == nil {
		t.Fatal("Statement(unknown document) = nil error, want DOCUMENT_NOT_FOUND")
	} else {
		assertIntegrationCode(t, err, apperror.CodeDocumentNotFound)
	}

	/* ---------------- 11. 列表按月过滤时区边界 ---------------- */

	// 月初/月末的边界记录必须落在本月区间内，避免因为时区或 DATE 列截断而跨月。
	monthStart, err := financeService.List(ctx, ownerPrincipal, finance.KindPayment, finance.ListQuery{
		DateFrom: time.Date(2026, 5, 1, 0, 0, 0, 0, time.UTC).Format("2006-01-02"),
		DateTo:   time.Date(2026, 5, 31, 0, 0, 0, 0, time.UTC).Format("2006-01-02"),
	})
	if err != nil {
		t.Fatalf("List(month bounds) error = %v", err)
	}
	if monthStart.Total != 3 {
		t.Fatalf("五月整月边界过滤 total = %d, want 3", monthStart.Total)
	}
}
