//go:build integration

package integration

import (
	"context"
	"testing"

	"CBizDocsManager/backend/internal/authorization"
	"CBizDocsManager/backend/internal/document"
	"CBizDocsManager/backend/internal/identity"
	"CBizDocsManager/backend/internal/member"
	"CBizDocsManager/backend/internal/organization"
	"CBizDocsManager/backend/pkg/apperror"
	"CBizDocsManager/backend/pkg/money"
	"CBizDocsManager/backend/pkg/rmb"
)

// TestDocumentInboundOutboundFlow 用真实 MySQL 覆盖入库 / 出库单据主链路：
//
//	金额服务端计算 → 单号生成 → 幂等重放 → 提交完整性校验 → 出库销售金额类型
//	→ 子账号数据范围与权限收敛 → 状态机（提交 / 作废 / 终态）→ 乐观锁 → 月度汇总。
//
// 之所以走真实方言，是因为这里要用到唯一索引（单号 / 幂等键）、行级乐观锁更新、
// 以及 DECIMAL 列在真实 MySQL 下的四舍五入与聚合行为，sqlite 桩数据无法替代。
func TestDocumentInboundOutboundFlow(t *testing.T) {
	db := openAuthFlowMySQL(t)
	ctx := context.Background()
	passwords := identity.NewPasswordManager()

	ownerHash, err := passwords.Hash("owner-password")
	if err != nil {
		t.Fatalf("hash owner password: %v", err)
	}
	memberHash, err := passwords.Hash("member-password")
	if err != nil {
		t.Fatalf("hash member password: %v", err)
	}

	ownerUser := identity.User{
		Username: "doc-owner", PasswordHash: ownerHash, DisplayName: "单据主账号",
		AccountType: identity.AccountTypeGroupOwner, Status: identity.UserStatusActive,
	}
	memberUser := identity.User{
		Username: "doc-member", PasswordHash: memberHash, DisplayName: "单据业务员",
		AccountType: identity.AccountTypeMember, Status: identity.UserStatusActive,
	}
	for _, user := range []*identity.User{&ownerUser, &memberUser} {
		if err := db.Create(user).Error; err != nil {
			t.Fatalf("seed user: %v", err)
		}
	}

	group := organization.Group{
		Name: "单据流转组", Status: organization.GroupStatusActive,
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

	ownerPrincipal := identity.Principal{
		UserID: ownerUser.ID, GroupID: &group.ID,
		AccountType: identity.AccountTypeGroupOwner, MemberType: "owner",
	}
	memberPrincipal := identity.Principal{
		UserID: memberUser.ID, GroupID: &group.ID,
		AccountType: identity.AccountTypeMember, MemberType: "member",
	}

	businessDate := "2026-05-12"

	// 1. 入库单草稿：金额一律由服务端按「单价 × 数量」计算，并生成单号。
	mainParties := []document.PartyRequest{
		{
			PartyName: "  北京  钢铁贸易有限公司 ",
			Items: []document.ItemRequest{
				{
					ProductName: "螺纹钢", ProductModel: strPtrValue("HRB400"), Unit: strPtrValue("吨"),
					Quantity: mustQuantityValue(t, "40"), UnitPrice: mustPriceValue(t, "1800"),
					PriceTaxMode: document.PriceTaxIncluded,
				},
				{
					ProductName: "线材", Quantity: mustQuantityValue(t, "1.5"),
					UnitPrice: mustPriceValue(t, "2500.5"), PriceTaxMode: document.PriceTaxExcluded,
				},
			},
		},
		{
			PartyName: "天津物资公司",
			Items: []document.ItemRequest{
				{
					ProductName: "钢板", Quantity: mustQuantityValue(t, "2"),
					UnitPrice: mustPriceValue(t, "1000"), PriceTaxMode: document.PriceTaxIncluded,
				},
			},
		},
	}
	mainDoc, err := documentService.Create(ctx, ownerPrincipal, document.KindInbound, document.CreateRequest{
		Status: document.StatusDraft, BusinessDate: businessDate, Parties: mainParties,
	}, "inbound-create-1")
	if err != nil {
		t.Fatalf("Create(inbound draft) error = %v", err)
	}
	if mainDoc.DocumentNo != "RK20260512-0001" {
		t.Fatalf("DocumentNo = %q, want RK20260512-0001", mainDoc.DocumentNo)
	}
	if mainDoc.Status != document.StatusDraft || mainDoc.Kind != document.KindInbound {
		t.Fatalf("created document = %+v", mainDoc)
	}
	// 往来单位名称要做空白折叠，避免「北京  钢铁」和「北京 钢铁」被当成两家公司。
	if len(mainDoc.Parties) != 2 || mainDoc.Parties[0].PartyName != "北京 钢铁贸易有限公司" {
		t.Fatalf("parties = %+v", mainDoc.Parties)
	}
	// 72000.00 + 3750.75 = 75750.75，再加上钢板 2000.00，合计 77750.75。
	if mainDoc.Parties[0].Subtotal.String() != "75750.75" {
		t.Fatalf("party subtotal = %s, want 75750.75", mainDoc.Parties[0].Subtotal)
	}
	if mainDoc.TotalAmount.String() != "77750.75" {
		t.Fatalf("total amount = %s, want 77750.75", mainDoc.TotalAmount)
	}
	if mainDoc.TotalAmountUpper != rmb.Upper(mainDoc.TotalAmount) {
		t.Fatalf("total upper = %q, want %q", mainDoc.TotalAmountUpper, rmb.Upper(mainDoc.TotalAmount))
	}
	// 序号由服务端生成，保证删除 / 新增后仍然连续。
	if mainDoc.Parties[0].Position != 1 || mainDoc.Parties[1].Position != 2 ||
		mainDoc.Parties[0].Items[0].Position != 1 || mainDoc.Parties[0].Items[1].Position != 2 {
		t.Fatalf("positions are not normalized: %+v", mainDoc.Parties)
	}

	// 2. 幂等重放：同一个幂等键 + 同一份载荷必须返回同一张单据，而不是新建一张。
	replay, err := documentService.Create(ctx, ownerPrincipal, document.KindInbound, document.CreateRequest{
		Status: document.StatusDraft, BusinessDate: businessDate, Parties: mainParties,
	}, "inbound-create-1")
	if err != nil {
		t.Fatalf("Create(idempotent replay) error = %v", err)
	}
	if replay.DocumentID != mainDoc.DocumentID || replay.DocumentNo != mainDoc.DocumentNo {
		t.Fatalf("idempotent replay created a new document: %+v", replay)
	}
	// 同一个幂等键换一份载荷则必须报错，而不是静默复用旧单据。
	mutatedParties := []document.PartyRequest{{
		PartyName: "北京 钢铁贸易有限公司",
		Items: []document.ItemRequest{{
			ProductName: "螺纹钢", Quantity: mustQuantityValue(t, "999"),
			UnitPrice: mustPriceValue(t, "1800"), PriceTaxMode: document.PriceTaxIncluded,
		}},
	}}
	if _, err = documentService.Create(ctx, ownerPrincipal, document.KindInbound, document.CreateRequest{
		Status: document.StatusDraft, BusinessDate: businessDate, Parties: mutatedParties,
	}, "inbound-create-1"); err != nil {
		assertIntegrationCode(t, err, apperror.CodeIdempotencyKeyReused)
	} else {
		t.Fatal("Create(reused key with different payload) = nil error, want IDEMPOTENCY_KEY_REUSED")
	}

	// 3. 提交完整性：草稿允许单价 / 数量为 0，但提交前必须补齐。
	emptyDoc, err := documentService.Create(ctx, ownerPrincipal, document.KindInbound, document.CreateRequest{
		Status: document.StatusDraft, BusinessDate: businessDate,
		Parties: []document.PartyRequest{{
			PartyName: "待补录客户",
			Items: []document.ItemRequest{{
				ProductName: "待定价钢材", Quantity: mustQuantityValue(t, "0"),
				UnitPrice: mustPriceValue(t, "0"), PriceTaxMode: document.PriceTaxIncluded,
			}},
		}},
	}, "")
	if err != nil {
		t.Fatalf("Create(incomplete draft) error = %v", err)
	}
	if _, err = documentService.Submit(ctx, ownerPrincipal, document.KindInbound, emptyDoc.DocumentID, document.VersionRequest{Version: emptyDoc.Version}); err != nil {
		assertIntegrationCode(t, err, apperror.CodeDocumentIncomplete)
	} else {
		t.Fatal("Submit(incomplete draft) = nil error, want DOCUMENT_INCOMPLETE")
	}

	// 4. 出库单：草稿可缺销售金额类型，但提交时必须选择。
	shippingUnit := "顺丰运输"
	outboundDraft, err := documentService.Create(ctx, ownerPrincipal, document.KindOutbound, document.CreateRequest{
		Status: document.StatusDraft, BusinessDate: businessDate, ShippingUnit: &shippingUnit,
		Parties: []document.PartyRequest{{
			PartyName: "上海建材客户", ContactPhone: strPtrValue("13800000000"),
			Items: []document.ItemRequest{{
				ProductName: "热轧卷板", Quantity: mustQuantityValue(t, "3"),
				UnitPrice: mustPriceValue(t, "1000"), PriceTaxMode: document.PriceTaxIncluded,
			}},
		}},
	}, "")
	if err != nil {
		t.Fatalf("Create(outbound draft) error = %v", err)
	}
	if outboundDraft.DocumentNo[:2] != "CK" {
		t.Fatalf("outbound DocumentNo = %q, want CK prefix", outboundDraft.DocumentNo)
	}
	if _, err = documentService.Submit(ctx, ownerPrincipal, document.KindOutbound, outboundDraft.DocumentID, document.VersionRequest{Version: outboundDraft.Version}); err != nil {
		assertIntegrationCode(t, err, apperror.CodeDocumentIncomplete)
	} else {
		t.Fatal("Submit(outbound without sale amount type) = nil error, want DOCUMENT_INCOMPLETE")
	}
	saleAmountType := document.SaleAmountVATSpecial
	updatedOutbound, err := documentService.Update(ctx, ownerPrincipal, document.KindOutbound, outboundDraft.DocumentID, document.UpdateRequest{
		Version: outboundDraft.Version, Status: document.StatusDraft, BusinessDate: businessDate,
		ShippingUnit: &shippingUnit, SaleAmountType: &saleAmountType,
		Parties: []document.PartyRequest{{
			PartyName: "上海建材客户", ContactPhone: strPtrValue("13800000000"),
			Items: []document.ItemRequest{{
				ProductName: "热轧卷板", Quantity: mustQuantityValue(t, "3"),
				UnitPrice: mustPriceValue(t, "1000"), PriceTaxMode: document.PriceTaxIncluded,
			}},
		}},
	}, "")
	if err != nil {
		t.Fatalf("Update(outbound with sale amount type) error = %v", err)
	}
	if updatedOutbound.SaleAmountType == nil || *updatedOutbound.SaleAmountType != document.SaleAmountVATSpecial {
		t.Fatalf("sale amount type = %v", updatedOutbound.SaleAmountType)
	}
	submittedOutbound, err := documentService.Submit(ctx, ownerPrincipal, document.KindOutbound, updatedOutbound.DocumentID, document.VersionRequest{Version: updatedOutbound.Version})
	if err != nil {
		t.Fatalf("Submit(outbound) error = %v", err)
	}
	if submittedOutbound.Status != document.StatusSubmitted {
		t.Fatalf("outbound status = %q, want submitted", submittedOutbound.Status)
	}

	// 5. 子账号数据范围：无权限时只能看到本人单据，且看不到他人详情。
	memberDoc, err := documentService.Create(ctx, ownerPrincipal, document.KindInbound, document.CreateRequest{
		Status: document.StatusDraft, BusinessDate: businessDate, BusinessUserID: &memberUser.ID,
		Parties: []document.PartyRequest{{
			PartyName: "代录客户",
			Items: []document.ItemRequest{{
				ProductName: "角钢", Quantity: mustQuantityValue(t, "5"),
				UnitPrice: mustPriceValue(t, "100"), PriceTaxMode: document.PriceTaxIncluded,
			}},
		}},
	}, "")
	if err != nil {
		t.Fatalf("Create(document for member) error = %v", err)
	}

	memberPage, err := documentService.List(ctx, memberPrincipal, document.KindInbound, document.ListQuery{})
	if err != nil {
		t.Fatalf("member List() error = %v", err)
	}
	if memberPage.Total != 1 || memberPage.Items[0].DocumentID != memberDoc.DocumentID {
		t.Fatalf("member List() = %+v, want only own document", memberPage)
	}
	if _, err = documentService.Get(ctx, memberPrincipal, document.KindInbound, mainDoc.DocumentID); err != nil {
		assertIntegrationCode(t, err, apperror.CodeForbidden)
	} else {
		t.Fatal("member Get(other's document) = nil error, want FORBIDDEN")
	}
	// 显式指定他人业务员也必须被拒绝，不能靠前端不传就绕过。
	if _, err = documentService.List(ctx, memberPrincipal, document.KindInbound, document.ListQuery{BusinessUserID: ownerUser.ID}); err != nil {
		assertIntegrationCode(t, err, apperror.CodeForbidden)
	} else {
		t.Fatal("member List(business_user_id=other) = nil error, want FORBIDDEN")
	}
	// 月度汇总同样是派生视图，未授权时必须收敛到本人。
	// 汇总接口没有单号参数，容易被误以为「天然安全」，这里专门盯住它不能靠猜参数越权。
	scopedSummary, err := documentService.MonthlySummary(ctx, memberPrincipal, document.KindInbound, "2026-05", 10)
	if err != nil {
		t.Fatalf("member MonthlySummary() error = %v", err)
	}
	if scopedSummary.DocumentCount != 1 || scopedSummary.TotalAmount.String() != "500.00" {
		t.Fatalf("member summary = %+v", scopedSummary)
	}

	// 6. 授信后可见范围放开：view_others 能看他人，但仍不能改他人（缺 edit_others）。
	if _, err = memberService.ReplacePermissions(ctx, ownerPrincipal, memberMembership.ID, member.ReplacePermissionsRequest{
		PermissionCodes: []authorization.Code{authorization.PermissionDocumentViewOthers}, Version: 1,
	}); err != nil {
		t.Fatalf("ReplacePermissions(view others) error = %v", err)
	}
	memberPage, err = documentService.List(ctx, memberPrincipal, document.KindInbound, document.ListQuery{})
	if err != nil {
		t.Fatalf("member List(with view_others) error = %v", err)
	}
	if memberPage.Total != 3 {
		t.Fatalf("member List(with view_others) total = %d, want 3", memberPage.Total)
	}
	if _, err = documentService.Get(ctx, memberPrincipal, document.KindInbound, mainDoc.DocumentID); err != nil {
		t.Fatalf("member Get(with view_others) error = %v", err)
	}
	if _, err = documentService.Update(ctx, memberPrincipal, document.KindInbound, mainDoc.DocumentID, document.UpdateRequest{
		Version: mainDoc.Version, Status: document.StatusDraft, BusinessDate: businessDate, Parties: mainParties,
	}, ""); err != nil {
		assertIntegrationCode(t, err, apperror.CodeForbidden)
	} else {
		t.Fatal("member Update(other's document) = nil error, want FORBIDDEN (missing edit_others)")
	}

	// 7. 状态机：草稿 → 已提交 → 已作废（终态），作废后不可再改也不可再作废。
	submittedMain, err := documentService.Submit(ctx, ownerPrincipal, document.KindInbound, mainDoc.DocumentID, document.VersionRequest{Version: mainDoc.Version})
	if err != nil {
		t.Fatalf("Submit(main inbound) error = %v", err)
	}
	if submittedMain.Status != document.StatusSubmitted || submittedMain.SubmittedAt == nil {
		t.Fatalf("submitted document = %+v", submittedMain)
	}
	voidedMain, err := documentService.Void(ctx, ownerPrincipal, document.KindInbound, mainDoc.DocumentID, document.VersionRequest{Version: submittedMain.Version})
	if err != nil {
		t.Fatalf("Void(main inbound) error = %v", err)
	}
	if voidedMain.Status != document.StatusVoided {
		t.Fatalf("voided status = %q", voidedMain.Status)
	}
	if _, err = documentService.Void(ctx, ownerPrincipal, document.KindInbound, mainDoc.DocumentID, document.VersionRequest{Version: voidedMain.Version}); err != nil {
		assertIntegrationCode(t, err, apperror.CodeDocumentStatusInvalid)
	} else {
		t.Fatal("Void(voided document) = nil error, want DOCUMENT_STATUS_INVALID")
	}
	if _, err = documentService.Update(ctx, ownerPrincipal, document.KindInbound, mainDoc.DocumentID, document.UpdateRequest{
		Version: voidedMain.Version, Status: document.StatusDraft, BusinessDate: businessDate, Parties: mainParties,
	}, ""); err != nil {
		assertIntegrationCode(t, err, apperror.CodeDocumentStatusInvalid)
	} else {
		t.Fatal("Update(voided document) = nil error, want DOCUMENT_STATUS_INVALID")
	}

	// 8. 乐观锁：客户端拿着过期版本号写入必须冲突，避免覆盖他人改动。
	if _, err = documentService.Update(ctx, ownerPrincipal, document.KindInbound, emptyDoc.DocumentID, document.UpdateRequest{
		Version: emptyDoc.Version + 5, Status: document.StatusDraft, BusinessDate: businessDate,
		Parties: []document.PartyRequest{{
			PartyName: "待补录客户",
			Items: []document.ItemRequest{{
				ProductName: "待定价钢材", Quantity: mustQuantityValue(t, "1"),
				UnitPrice: mustPriceValue(t, "1"), PriceTaxMode: document.PriceTaxIncluded,
			}},
		}},
	}, ""); err != nil {
		assertIntegrationCode(t, err, apperror.CodeResourceVersionConflict)
	} else {
		t.Fatal("Update(stale version) = nil error, want RESOURCE_VERSION_CONFLICT")
	}

	// 9. 月度汇总：作废单计入 voided_count，但不计入金额合计。
	summary, err := documentService.MonthlySummary(ctx, ownerPrincipal, document.KindInbound, "2026-05", 10)
	if err != nil {
		t.Fatalf("MonthlySummary() error = %v", err)
	}
	if summary.Month != "2026-05" || summary.DocumentCount != 3 || summary.VoidedCount != 1 || summary.DraftCount != 2 || summary.SubmittedCount != 0 {
		t.Fatalf("inbound summary = %+v", summary)
	}
	// 作废的 77750.75 不计入，只剩代录客户的 500.00。
	if summary.TotalAmount.String() != "500.00" {
		t.Fatalf("inbound summary total = %s, want 500.00", summary.TotalAmount)
	}
	if summary.TotalAmountUpper != rmb.Upper(summary.TotalAmount) {
		t.Fatalf("summary upper = %q, want %q", summary.TotalAmountUpper, rmb.Upper(summary.TotalAmount))
	}
	// 往来单位分布与 TotalAmount 同一口径：排除作废单、包含草稿单。
	// 「待补录客户」这张 0 元草稿虽然金额为 0，但它是本月真实存在的往来单位，
	// 需要提醒业务员补录定价，因此必须出现在列表里（否则金额合计与单据数会对不上）。
	// 排序按金额倒序：代录客户 500.00 在前，待补录客户 0.00 在后。
	if len(summary.Parties) != 2 ||
		summary.Parties[0].PartyName != "代录客户" || summary.Parties[0].TotalAmount.String() != "500.00" || summary.Parties[0].DocumentCount != 1 ||
		summary.Parties[1].PartyName != "待补录客户" || summary.Parties[1].TotalAmount.String() != "0.00" || summary.Parties[1].DocumentCount != 1 {
		t.Fatalf("summary parties = %+v", summary.Parties)
	}

	// 子账号在获得 view_others 之后，月度汇总的数据范围与主账号一致（全组 3 张单）。
	memberSummary, err := documentService.MonthlySummary(ctx, memberPrincipal, document.KindInbound, "2026-05", 10)
	if err != nil {
		t.Fatalf("member MonthlySummary(with view_others) error = %v", err)
	}
	if memberSummary.DocumentCount != 3 || memberSummary.TotalAmount.String() != "500.00" || len(memberSummary.Parties) != 2 {
		t.Fatalf("member MonthlySummary(with view_others) = %+v", memberSummary)
	}
	// 未授权的月份参数必须被拒绝。
	if _, err = documentService.MonthlySummary(ctx, ownerPrincipal, document.KindInbound, "2026-13", 10); err != nil {
		assertIntegrationCode(t, err, apperror.CodeValidationFailed)
	} else {
		t.Fatal("MonthlySummary(invalid month) = nil error, want VALIDATION_FAILED")
	}

	// 10. 列表过滤：状态过滤与关键字过滤都要命中真实索引路径。
	draftPage, err := documentService.List(ctx, ownerPrincipal, document.KindInbound, document.ListQuery{Status: document.StatusDraft})
	if err != nil {
		t.Fatalf("List(status=draft) error = %v", err)
	}
	if draftPage.Total != 2 {
		t.Fatalf("List(status=draft) total = %d, want 2", draftPage.Total)
	}
	keywordPage, err := documentService.List(ctx, ownerPrincipal, document.KindInbound, document.ListQuery{Keyword: "RK20260512-0001"})
	if err != nil {
		t.Fatalf("List(keyword=document no) error = %v", err)
	}
	if keywordPage.Total != 1 || keywordPage.Items[0].DocumentID != mainDoc.DocumentID {
		t.Fatalf("List(keyword=document no) = %+v", keywordPage)
	}
	// 非法分页参数必须被拒绝，不能静默截断。
	if _, err = documentService.List(ctx, ownerPrincipal, document.KindInbound, document.ListQuery{PageSize: 500}); err != nil {
		assertIntegrationCode(t, err, apperror.CodeValidationFailed)
	} else {
		t.Fatal("List(page_size=500) = nil error, want VALIDATION_FAILED")
	}

	// 11. 业务员必须是本组有效成员，防止把单据挂到组外或不存在的账号上。
	stranger := identity.User{
		Username: "doc-stranger", PasswordHash: ownerHash, DisplayName: "组外人员",
		AccountType: identity.AccountTypeMember, Status: identity.UserStatusActive,
	}
	if err := db.Create(&stranger).Error; err != nil {
		t.Fatalf("seed stranger: %v", err)
	}
	if _, err = documentService.Create(ctx, ownerPrincipal, document.KindInbound, document.CreateRequest{
		Status: document.StatusDraft, BusinessDate: businessDate, BusinessUserID: &stranger.ID, Parties: mainParties,
	}, ""); err != nil {
		assertIntegrationCode(t, err, apperror.CodeValidationFailed)
	} else {
		t.Fatal("Create(business user outside group) = nil error, want VALIDATION_FAILED")
	}

	// 12. 入库单不允许携带出库单专属字段，字段用错要立刻报错而不是被静默忽略。
	if _, err = documentService.Create(ctx, ownerPrincipal, document.KindInbound, document.CreateRequest{
		Status: document.StatusDraft, BusinessDate: businessDate, ShippingUnit: &shippingUnit, Parties: mainParties,
	}, ""); err != nil {
		assertIntegrationCode(t, err, apperror.CodeValidationFailed)
	} else {
		t.Fatal("Create(inbound with shipping unit) = nil error, want VALIDATION_FAILED")
	}

	// 13. 组外身份（无 group）直接拒绝，避免越权跨组。
	if _, err = documentService.List(ctx, identity.Principal{UserID: ownerUser.ID, AccountType: identity.AccountTypePlatformAdmin}, document.KindInbound, document.ListQuery{}); err != nil {
		assertIntegrationCode(t, err, apperror.CodeForbidden)
	} else {
		t.Fatal("List(platform admin without group) = nil error, want FORBIDDEN")
	}
}

/* ---------------------------------------------------------------- 测试辅助 */

func strPtrValue(value string) *string { return &value }

func mustAmountValue(t *testing.T, raw string) money.Amount {
	t.Helper()
	value, err := money.ParseAmount(raw)
	if err != nil {
		t.Fatalf("ParseAmount(%q) error = %v", raw, err)
	}
	return value
}

func mustPriceValue(t *testing.T, raw string) money.Price {
	t.Helper()
	value, err := money.ParsePrice(raw)
	if err != nil {
		t.Fatalf("ParsePrice(%q) error = %v", raw, err)
	}
	return value
}

func mustQuantityValue(t *testing.T, raw string) money.Quantity {
	t.Helper()
	value, err := money.ParseQuantity(raw)
	if err != nil {
		t.Fatalf("ParseQuantity(%q) error = %v", raw, err)
	}
	return value
}
