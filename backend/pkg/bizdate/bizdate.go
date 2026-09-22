// Package bizdate 提供业务日期与月份的解析口径。
//
// 单据与结算两个模块都要处理用户手写的日期，如果各写一套解析，很容易出现
// 「入库单接受 2026年3月14日、结算列表却不接受」这类口径漂移。
// 因此把解析规则集中在这里，各模块只调用不复制。
package bizdate

import (
	"fmt"
	"strconv"
	"strings"
	"time"
)

// ErrInvalid 表示日期或月份无法解析。
var ErrInvalid = fmt.Errorf("业务日期格式无效")

// dateReplacer 把用户可能输入的分隔符统一折叠成 "-"。
// 覆盖需求 FR-ASSIST-05「用户可输入由空格分隔的日期」。
var dateReplacer = strings.NewReplacer(
	"年", "-", "月", "-", "日", "",
	"/", "-", ".", "-", " ", "-", "\t", "-", "\\", "-",
)

// monthReplacer 只处理「YYYY-MM」这一种粒度。
var monthReplacer = strings.NewReplacer("/", "-", "年", "-", "月", "", ".", "-", " ", "-")

// ParseDate 解析业务日期并统一成 UTC 零点。
//
// 兼容「2026-09-22」「2026/9/22」「2026 3 14」「2026年3月14日」「20260922」五种写法，
// 并回读校验 time.Date 的规范化结果，避免 2026-02-31 被悄悄变成 2026-03-03 后落库。
func ParseDate(raw string) (time.Time, error) {
	text := strings.TrimSpace(raw)
	if text == "" {
		return time.Time{}, ErrInvalid
	}
	fields := strings.Split(dateReplacer.Replace(text), "-")

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
			return time.Time{}, ErrInvalid
		}
		year, month, day = atoiOrZero(parts[0][0:4]), atoiOrZero(parts[0][4:6]), atoiOrZero(parts[0][6:8])
	case 3:
		year, month, day = atoiOrZero(parts[0]), atoiOrZero(parts[1]), atoiOrZero(parts[2])
	default:
		return time.Time{}, ErrInvalid
	}
	if year < 2000 || year > 2100 || month < 1 || month > 12 || day < 1 || day > 31 {
		return time.Time{}, ErrInvalid
	}

	date := time.Date(year, time.Month(month), day, 0, 0, 0, 0, time.UTC)
	if date.Year() != year || int(date.Month()) != month || date.Day() != day {
		return time.Time{}, ErrInvalid
	}
	return date, nil
}

// ParseMonth 解析「YYYY-MM」，返回该月起止时间（左闭右开）。
func ParseMonth(raw string) (time.Time, time.Time, error) {
	text := strings.TrimSpace(monthReplacer.Replace(raw))
	parts := strings.Split(text, "-")
	if len(parts) != 2 {
		return time.Time{}, time.Time{}, ErrInvalid
	}
	year, month := atoiOrZero(parts[0]), atoiOrZero(parts[1])
	if year < 2000 || year > 2100 || month < 1 || month > 12 {
		return time.Time{}, time.Time{}, ErrInvalid
	}
	start := time.Date(year, time.Month(month), 1, 0, 0, 0, 0, time.UTC)
	return start, start.AddDate(0, 1, 0), nil
}

// MonthStart 返回给定时刻所属月份的起点（UTC），用于「缺省查当月」这类场景。
func MonthStart(at time.Time) time.Time {
	utc := at.UTC()
	return time.Date(utc.Year(), utc.Month(), 1, 0, 0, 0, 0, time.UTC)
}

// FormatMonth 把时刻格式化成「YYYY-MM」。
func FormatMonth(at time.Time) string { return at.Format("2006-01") }

// atoiOrZero 把字符串转成整数，失败时返回 0（由调用方做范围校验）。
func atoiOrZero(raw string) int {
	value, err := strconv.Atoi(strings.TrimSpace(raw))
	if err != nil {
		return 0
	}
	return value
}
