package document

import (
	"fmt"
	"strconv"
	"strings"
	"time"

	"CBizDocsManager/backend/pkg/bizdate"
)

const (
	maxPartiesPerDocument = 50
	maxItemsPerParty      = 200
	maxQuantityValue      = "1000000000.000"
	maxUnitPriceValue     = "100000000.0000"
)

// parseBusinessDate 解析业务日期并统一成 UTC 零点。
// 兼容「2026-09-22」「2026/9/22」「2026 3 14」「2026年3月14日」「20260922」五种写法，
// 对应需求 FR-ASSIST-05「用户可输入由空格分隔的日期」。
// 具体解析规则统一放在 pkg/bizdate，和结算模块共用同一套口径。
func parseBusinessDate(raw string) (time.Time, error) {
	return bizdate.ParseDate(raw)
}

// parseMonthRange 解析「YYYY-MM」，返回该月起止时间（左闭右开）。
func parseMonthRange(raw string) (time.Time, time.Time, error) {
	return bizdate.ParseMonth(raw)
}

// normalizeText 折叠内部连续空白并去除首尾空白；结果为空时返回 nil，便于统一判定「未填写」。
func normalizeText(raw *string, maxLength int) (*string, error) {
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

// normalizeRequiredText 归一化必填文本，空值返回错误。
func normalizeRequiredText(raw string, maxLength int) (string, error) {
	cleaned := strings.Join(strings.Fields(raw), " ")
	if cleaned == "" {
		return "", fmt.Errorf("必填文本为空")
	}
	if len([]rune(cleaned)) > maxLength {
		return "", fmt.Errorf("文本长度超过 %d", maxLength)
	}
	return cleaned, nil
}

// formatDocumentNo 生成单号：类型前缀 + 业务日期 + 4 位当日序号，例如 RK20260922-0007。
func formatDocumentNo(kind Kind, businessDate time.Time, sequence int) string {
	return fmt.Sprintf("%s%s-%04d", kind.NumberPrefix(), businessDate.Format("20060102"), sequence)
}

// documentNoLikePattern 返回按业务日期过滤单号的 LIKE 前缀。
func documentNoLikePattern(kind Kind, businessDate time.Time) string {
	return kind.NumberPrefix() + businessDate.Format("20060102") + "-%"
}

// sequenceFromDocumentNo 从既有单号中解析当日序号，解析失败时返回 0（由调用方从 1 重新开始）。
func sequenceFromDocumentNo(documentNo string) int {
	index := strings.LastIndex(documentNo, "-")
	if index < 0 || index == len(documentNo)-1 {
		return 0
	}
	sequence, err := strconv.Atoi(documentNo[index+1:])
	if err != nil || sequence < 0 {
		return 0
	}
	return sequence
}
