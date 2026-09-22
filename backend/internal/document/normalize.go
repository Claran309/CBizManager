package document

import (
	"fmt"
	"strconv"
	"strings"
	"time"
)

const (
	maxPartiesPerDocument = 50
	maxItemsPerParty      = 200
	maxQuantityValue      = "1000000000.000"
	maxUnitPriceValue     = "100000000.0000"
)

// errInvalidBusinessDate 表示业务日期无法解析。
var errInvalidBusinessDate = fmt.Errorf("业务日期格式无效")

// parseBusinessDate 解析业务日期并统一成 UTC 零点。
// 兼容「2026-09-22」「2026/9/22」「2026 3 14」「2026年3月14日」「20260922」五种写法，
// 对应需求 FR-ASSIST-05「用户可输入由空格分隔的日期」。
func parseBusinessDate(raw string) (time.Time, error) {
	text := strings.TrimSpace(raw)
	if text == "" {
		return time.Time{}, errInvalidBusinessDate
	}
	replacer := strings.NewReplacer("年", "-", "月", "-", "日", "", "/", "-", ".", "-", " ", "-", "\t", "-", "\\", "-")
	fields := strings.Split(replacer.Replace(text), "-")

	parts := make([]string, 0, 3)
	for _, field := range fields {
		if trimmed := strings.TrimSpace(field); trimmed != "" {
			parts = append(parts, trimmed)
		}
	}

	var year, month, day int
	switch len(parts) {
	case 1:
		// 紧凑写法 20260922。
		if len(parts[0]) != 8 {
			return time.Time{}, errInvalidBusinessDate
		}
		year, month, day = atoiOrZero(parts[0][0:4]), atoiOrZero(parts[0][4:6]), atoiOrZero(parts[0][6:8])
	case 3:
		year, month, day = atoiOrZero(parts[0]), atoiOrZero(parts[1]), atoiOrZero(parts[2])
	default:
		return time.Time{}, errInvalidBusinessDate
	}
	if year < 2000 || year > 2100 || month < 1 || month > 12 || day < 1 || day > 31 {
		return time.Time{}, errInvalidBusinessDate
	}

	date := time.Date(year, time.Month(month), day, 0, 0, 0, 0, time.UTC)
	// time.Date 会把 2026-02-31 规范化成 2026-03-03，必须回读校验，避免脏数据落库。
	if date.Year() != year || int(date.Month()) != month || date.Day() != day {
		return time.Time{}, errInvalidBusinessDate
	}
	return date, nil
}

// parseMonthRange 解析「YYYY-MM」，返回该月起止时间（左闭右开）。
func parseMonthRange(raw string) (time.Time, time.Time, error) {
	text := strings.TrimSpace(strings.NewReplacer("/", "-", "年", "-", "月", "", ".", "-").Replace(raw))
	parts := strings.Split(text, "-")
	if len(parts) != 2 {
		return time.Time{}, time.Time{}, errInvalidBusinessDate
	}
	year, month := atoiOrZero(parts[0]), atoiOrZero(parts[1])
	if year < 2000 || year > 2100 || month < 1 || month > 12 {
		return time.Time{}, time.Time{}, errInvalidBusinessDate
	}
	start := time.Date(year, time.Month(month), 1, 0, 0, 0, 0, time.UTC)
	return start, start.AddDate(0, 1, 0), nil
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

func atoiOrZero(raw string) int {
	value, err := strconv.Atoi(strings.TrimSpace(raw))
	if err != nil {
		return 0
	}
	return value
}
