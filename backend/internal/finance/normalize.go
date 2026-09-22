package finance

import (
	"fmt"
	"strings"
	"time"
	"unicode"

	"CBizDocsManager/backend/pkg/bizdate"
	"CBizDocsManager/backend/pkg/money"
)

const (
	// maxRemarkLength 财务记录备注的长度上限。
	maxRemarkLength = 500
	// maxMethodNoteLength 转账备注（微信 / 支付宝）的长度上限。
	maxMethodNoteLength = 100
	// maxInvoiceNoLength 发票号长度上限。
	maxInvoiceNoLength = 64
	// cardTailLength 卡尾号固定 4 位。
	cardTailLength = 4
)

// normalizeOptionalText 折叠内部连续空白并去除首尾空白；结果为空时返回 nil。
//
// 与单据 / 结算模块的文本归一化规则保持一致（同一套表单体系不允许出现两种空白口径）。
func normalizeOptionalText(raw *string, maxLength int) (*string, error) {
	if raw == nil {
		return nil, nil
	}
	cleaned := strings.Join(strings.Fields(*raw), " ")
	if cleaned == "" {
		return nil, nil
	}
	if len([]rune(cleaned)) > maxLength {
		return nil, fmt.Errorf("文本长度超过 %d", maxLength)
	}
	return &cleaned, nil
}

// normalizeAmount 解析并校验本次付款 / 收款 / 开票金额。
//
// 必须严格大于 0：0 元记录没有业务含义，却会在列表里制造噪音；
// 负数应当用「撤销已有记录」表达，而不是登记一笔负数。
func normalizeAmount(raw string) (money.Amount, error) {
	text := strings.TrimSpace(raw)
	if text == "" {
		return 0, fmt.Errorf("金额不能为空")
	}
	amount, err := money.ParseAmount(text)
	if err != nil {
		return 0, fmt.Errorf("金额格式无效")
	}
	if amount <= 0 {
		return 0, fmt.Errorf("金额必须大于 0")
	}
	return amount, nil
}

// parseOccurredOn 解析实际发生日期。
//
// 口径与单据业务日期完全一致（兼容 2026-09-22 / 2026/9/22 / 2026 9 22 /
// 2026年9月22日 / 20260922），统一走 pkg/bizdate，避免财务与业务两套日期规则。
func parseOccurredOn(raw string) (time.Time, error) {
	date, err := bizdate.ParseDate(raw)
	if err != nil {
		return time.Time{}, fmt.Errorf("发生日期格式无效")
	}
	return date, nil
}

// normalizeMethod 校验并解析付款 / 收款方式，同时按方式校验配套字段。
//
// 三类方式的字段要求（FR-OUT-06）：
//   - transfer：可备注微信 / 支付宝（method_note），不允许带卡尾号；
//   - private_card：必须带 4 位卡尾号，不允许带转账备注；
//   - public_account：两者都不允许。
//
// 不匹配的字段一律报错而不是静默丢弃：财务数据出错代价很高，
// 「客户端传了却没生效」比「直接报错」危险得多。
func normalizeMethod(kind Kind, rawMethod string, rawNote, rawCardTail *string) (*Method, *string, *string, error) {
	if !kind.CarriesMethod() {
		if strings.TrimSpace(rawMethod) != "" || rawNote != nil || rawCardTail != nil {
			return nil, nil, nil, fmt.Errorf("%s记录不携带付款 / 收款方式", kind.Label())
		}
		return nil, nil, nil, nil
	}

	method, ok := ParseMethod(strings.TrimSpace(rawMethod))
	if !ok {
		return nil, nil, nil, fmt.Errorf("付款 / 收款方式无效")
	}
	note, err := normalizeOptionalText(rawNote, maxMethodNoteLength)
	if err != nil {
		return nil, nil, nil, err
	}
	cardTail, err := normalizeCardTail(rawCardTail)
	if err != nil {
		return nil, nil, nil, err
	}

	switch method {
	case MethodTransfer:
		if cardTail != nil {
			return nil, nil, nil, fmt.Errorf("转账方式不能填写卡尾号")
		}
	case MethodPrivateCard:
		if cardTail == nil {
			return nil, nil, nil, fmt.Errorf("对私卡方式必须填写卡尾号")
		}
		if note != nil {
			return nil, nil, nil, fmt.Errorf("对私卡方式不能填写转账备注")
		}
	case MethodPublicAccount:
		if cardTail != nil || note != nil {
			return nil, nil, nil, fmt.Errorf("对公账户方式不能填写卡尾号或转账备注")
		}
	}
	return &method, note, cardTail, nil
}

// normalizeCardTail 校验卡尾号必须是 4 位数字。
//
// 只接受 4 位数字的另一个作用是防止客户端把完整卡号传上来：
// 超出 4 位直接报错，完整卡号不会进入数据库、日志或审计摘要。
func normalizeCardTail(raw *string) (*string, error) {
	if raw == nil {
		return nil, nil
	}
	trimmed := strings.TrimSpace(*raw)
	if trimmed == "" {
		return nil, nil
	}
	if len([]rune(trimmed)) != cardTailLength {
		return nil, fmt.Errorf("卡尾号必须是 %d 位", cardTailLength)
	}
	for _, char := range trimmed {
		if !unicode.IsDigit(char) {
			return nil, fmt.Errorf("卡尾号必须是数字")
		}
	}
	return &trimmed, nil
}

// normalizeInvoiceNo 校验发票号，只有开票记录允许携带。
func normalizeInvoiceNo(kind Kind, raw *string) (*string, error) {
	if !kind.CarriesInvoiceNo() {
		if raw != nil && strings.TrimSpace(*raw) != "" {
			return nil, fmt.Errorf("%s记录不携带发票号", kind.Label())
		}
		return nil, nil
	}
	return normalizeOptionalText(raw, maxInvoiceNoLength)
}

// normalizeDocumentID 校验单据 ID。
func normalizeDocumentID(raw uint64) (uint64, error) {
	if raw == 0 {
		return 0, fmt.Errorf("单据 ID 非法")
	}
	return raw, nil
}
