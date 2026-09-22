package document

import (
	"strings"
	"time"

	"CBizDocsManager/backend/internal/identity"
	"CBizDocsManager/backend/pkg/apperror"
	"CBizDocsManager/backend/pkg/money"
)

// normalizedPayload 是通过校验与归一化之后的单据内容。
type normalizedPayload struct {
	Status         Status
	BusinessDate   time.Time
	BusinessUserID uint64
	ShippingUnit   *string
	SaleAmountType *SaleAmountType
	Remark         *string
	Parties        []PartyDraft
	TotalAmount    money.Amount
}

// payloadRequest 是创建 / 更新请求中参与构造单据内容的字段集合。
type payloadRequest struct {
	Status         Status
	BusinessDate   string
	BusinessUserID *uint64
	ShippingUnit   *string
	SaleAmountType *SaleAmountType
	Remark         *string
	Parties        []PartyRequest
}

// buildPayload 把请求内容归一化成可直接落库的草稿。
//
// 校验口径分两档：
//   - 草稿：结构必须完整（至少一个往来单位、每个单位至少一条明细、品名必填），
//     但允许单价或数量为 0，方便业务员先随手记下再补。
//   - 提交：在草稿基础上要求「数量 > 0 且 单价 > 0」，出库单还必须选择销售金额类型，
//     对应需求 FR-IN-04 / FR-OUT-02 / FR-DOC-02。
func buildPayload(kind Kind, principal identity.Principal, request payloadRequest) (normalizedPayload, error) {
	status := request.Status
	if status == "" {
		status = StatusDraft
	}
	if status != StatusDraft && status != StatusSubmitted {
		return normalizedPayload{}, apperror.ErrValidationFailed
	}

	businessDate, err := parseBusinessDate(request.BusinessDate)
	if err != nil {
		return normalizedPayload{}, apperror.ErrValidationFailed
	}

	businessUserID := principal.UserID
	if request.BusinessUserID != nil {
		if *request.BusinessUserID == 0 {
			return normalizedPayload{}, apperror.ErrValidationFailed
		}
		businessUserID = *request.BusinessUserID
	}

	shippingUnit, err := normalizeText(request.ShippingUnit, 191)
	if err != nil {
		return normalizedPayload{}, apperror.ErrValidationFailed
	}
	remark, err := normalizeText(request.Remark, 500)
	if err != nil {
		return normalizedPayload{}, apperror.ErrValidationFailed
	}

	saleAmountType, err := normalizeSaleAmountType(request.SaleAmountType)
	if err != nil {
		return normalizedPayload{}, err
	}

	if kind.IsInbound() {
		// 入库单没有「出货单位」和「销售金额类型」，客户端传了说明字段用错，直接拒绝。
		if shippingUnit != nil || saleAmountType != nil {
			return normalizedPayload{}, apperror.ErrValidationFailed
		}
	} else if status == StatusSubmitted && saleAmountType == nil {
		return normalizedPayload{}, apperror.ErrDocumentIncomplete
	}

	if len(request.Parties) == 0 || len(request.Parties) > maxPartiesPerDocument {
		return normalizedPayload{}, apperror.ErrValidationFailed
	}
	parties := make([]PartyDraft, 0, len(request.Parties))
	var total money.Amount
	for partyIndex, rawParty := range request.Parties {
		partyName, err := normalizeRequiredText(rawParty.PartyName, 191)
		if err != nil {
			return normalizedPayload{}, apperror.ErrValidationFailed
		}
		contactPhone, err := normalizeContactPhone(rawParty.ContactPhone, kind)
		if err != nil {
			return normalizedPayload{}, err
		}
		if len(rawParty.Items) == 0 || len(rawParty.Items) > maxItemsPerParty {
			return normalizedPayload{}, apperror.ErrValidationFailed
		}
		items := make([]ItemDraft, 0, len(rawParty.Items))
		var subtotal money.Amount
		for itemIndex, rawItem := range rawParty.Items {
			item, err := buildItemDraft(rawItem, status)
			if err != nil {
				return normalizedPayload{}, err
			}
			// 序号由服务端生成，保证删除 / 新增后仍然连续。
			item.Position = itemIndex + 1
			subtotal = subtotal.Add(item.Amount)
			items = append(items, item)
		}
		parties = append(parties, PartyDraft{
			Position: partyIndex + 1, PartyName: partyName, ContactPhone: contactPhone,
			DictionaryEntryID: rawParty.DictionaryEntryID, Subtotal: subtotal, Items: items,
		})
		total = total.Add(subtotal)
	}

	return normalizedPayload{
		Status: status, BusinessDate: businessDate, BusinessUserID: businessUserID,
		ShippingUnit: shippingUnit, SaleAmountType: saleAmountType, Remark: remark,
		Parties: parties, TotalAmount: total,
	}, nil
}

// buildItemDraft 校验并构造单条明细；金额一律由服务端按「单价 × 数量」计算，
// 不信任客户端提交的金额，避免出现前后端口径不一致。
func buildItemDraft(raw ItemRequest, status Status) (ItemDraft, error) {
	productName, err := normalizeRequiredText(raw.ProductName, 191)
	if err != nil {
		return ItemDraft{}, apperror.ErrValidationFailed
	}
	productModel, err := normalizeText(raw.ProductModel, 191)
	if err != nil {
		return ItemDraft{}, apperror.ErrValidationFailed
	}
	unit, err := normalizeText(raw.Unit, 32)
	if err != nil {
		return ItemDraft{}, apperror.ErrValidationFailed
	}
	remark, err := normalizeText(raw.Remark, 500)
	if err != nil {
		return ItemDraft{}, apperror.ErrValidationFailed
	}
	if raw.PriceTaxMode != PriceTaxIncluded && raw.PriceTaxMode != PriceTaxExcluded {
		return ItemDraft{}, apperror.ErrValidationFailed
	}
	if raw.Quantity < 0 || raw.Quantity > maxQuantity {
		return ItemDraft{}, apperror.ErrValidationFailed
	}
	if raw.UnitPrice < 0 || raw.UnitPrice > maxUnitPrice {
		return ItemDraft{}, apperror.ErrValidationFailed
	}
	if raw.Weight != nil && (*raw.Weight < 0 || *raw.Weight > maxQuantity) {
		return ItemDraft{}, apperror.ErrValidationFailed
	}

	amount := money.Mul(raw.UnitPrice, raw.Quantity)
	if status == StatusSubmitted && (raw.Quantity <= 0 || raw.UnitPrice <= 0 || amount <= 0) {
		return ItemDraft{}, apperror.ErrDocumentIncomplete
	}
	return ItemDraft{
		ProductName: productName, ProductModel: productModel, Unit: unit,
		Quantity: raw.Quantity, Weight: raw.Weight, UnitPrice: raw.UnitPrice,
		PriceTaxMode: raw.PriceTaxMode, Amount: amount, Remark: remark,
	}, nil
}

// normalizeSaleAmountType 校验出库单销售金额类型，落库保留稳定代码值。
func normalizeSaleAmountType(raw *SaleAmountType) (*SaleAmountType, error) {
	if raw == nil {
		return nil, nil
	}
	value := SaleAmountType(strings.TrimSpace(string(*raw)))
	switch value {
	case SaleAmountVATSpecial, SaleAmountVATGeneral, SaleAmountNoInvoice:
		return &value, nil
	default:
		return nil, apperror.ErrValidationFailed
	}
}

// normalizeContactPhone 归一化联系电话：入库单没有该字段，传了直接拒绝。
func normalizeContactPhone(raw *string, kind Kind) (*string, error) {
	if kind.IsInbound() {
		if raw != nil && strings.TrimSpace(*raw) != "" {
			return nil, apperror.ErrValidationFailed
		}
		return nil, nil
	}
	return normalizeText(raw, 50)
}

// validateTransition 校验状态机：草稿可提交、可作废；已提交只能作废；已作废是终态。
func validateTransition(current, target Status) error {
	switch target {
	case StatusSubmitted:
		if current != StatusDraft {
			return apperror.ErrDocumentStatusInvalid
		}
	case StatusVoided:
		if current == StatusVoided {
			return apperror.ErrDocumentStatusInvalid
		}
	default:
		return apperror.ErrValidationFailed
	}
	return nil
}

// validateCompleteness 在提交时对已落库内容再做一次完整性校验，
// 防止「先保存草稿、后补内容」路径上漏掉校验。
func validateCompleteness(kind Kind, detail Detail) error {
	if len(detail.Parties) == 0 {
		return apperror.ErrDocumentIncomplete
	}
	if !kind.IsInbound() && detail.Document.SaleAmountType == nil {
		return apperror.ErrDocumentIncomplete
	}
	for _, party := range detail.Parties {
		if strings.TrimSpace(party.PartyName) == "" || len(party.Items) == 0 {
			return apperror.ErrDocumentIncomplete
		}
		for _, item := range party.Items {
			if strings.TrimSpace(item.ProductName) == "" || item.Quantity <= 0 || item.UnitPrice <= 0 || item.Amount <= 0 {
				return apperror.ErrDocumentIncomplete
			}
		}
	}
	return nil
}
