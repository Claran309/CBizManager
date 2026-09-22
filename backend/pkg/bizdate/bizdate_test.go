package bizdate

import (
	"testing"
	"time"
)

// TestParseDateAcceptsHumanFormats 锁定需求 FR-ASSIST-05 允许的五种手写写法。
func TestParseDateAcceptsHumanFormats(t *testing.T) {
	cases := map[string]string{
		"2026-09-22":    "标准横线写法",
		"2026/9/22":     "斜杠写法",
		"2026 9 22":     "空格分隔写法",
		"2026年9月22日":    "中文年月日写法",
		"20260922":      "紧凑写法",
		"  2026-9-22  ": "首尾空白应被容忍",
	}
	for raw, label := range cases {
		parsed, err := ParseDate(raw)
		if err != nil {
			t.Errorf("ParseDate(%q) [%s] error = %v", raw, label, err)
			continue
		}
		want := time.Date(2026, time.September, 22, 0, 0, 0, 0, time.UTC)
		if !parsed.Equal(want) {
			t.Errorf("ParseDate(%q) [%s] = %s, want %s", raw, label, parsed, want)
		}
	}
}

// TestParseDateRejectsInvalidInput 确认非法日期不会被 time.Date 悄悄规范化后落库。
func TestParseDateRejectsInvalidInput(t *testing.T) {
	for _, raw := range []string{
		"", "2026-13-01", "2026-00-10", "2026-02-31", "2026-04-31",
		"1999-12-31", "2101-01-01", "202609", "2026092", "abc", "2026-9",
	} {
		if parsed, err := ParseDate(raw); err == nil {
			t.Errorf("ParseDate(%q) = %s, want error", raw, parsed)
		}
	}
}

// TestParseMonthRange 校验「YYYY-MM」解析成左闭右开区间，并正确处理 12 月跨年。
func TestParseMonthRange(t *testing.T) {
	start, end, err := ParseMonth("2026-09")
	if err != nil {
		t.Fatalf("ParseMonth(2026-09) error = %v", err)
	}
	if !start.Equal(time.Date(2026, time.September, 1, 0, 0, 0, 0, time.UTC)) {
		t.Errorf("start = %s", start)
	}
	if !end.Equal(time.Date(2026, time.October, 1, 0, 0, 0, 0, time.UTC)) {
		t.Errorf("end = %s", end)
	}

	// 12 月必须跨到次年 1 月。
	_, decemberEnd, err := ParseMonth("2026年12月")
	if err != nil {
		t.Fatalf("ParseMonth(2026年12月) error = %v", err)
	}
	if !decemberEnd.Equal(time.Date(2027, time.January, 1, 0, 0, 0, 0, time.UTC)) {
		t.Errorf("december end = %s, want 2027-01-01", decemberEnd)
	}
}

func TestParseMonthRangeRejectsInvalidInput(t *testing.T) {
	for _, raw := range []string{"", "2026", "2026-13", "2026-00", "1999-01", "2101-12", "2026-09-22"} {
		if _, _, err := ParseMonth(raw); err == nil {
			t.Errorf("ParseMonth(%q) = nil error, want error", raw)
		}
	}
}

// TestMonthStartAndFormat 校验「缺省当月」与格式化这对配套能力。
func TestMonthStartAndFormat(t *testing.T) {
	at := time.Date(2026, time.September, 22, 18, 58, 32, 0, time.UTC)
	if start := MonthStart(at); !start.Equal(time.Date(2026, time.September, 1, 0, 0, 0, 0, time.UTC)) {
		t.Errorf("MonthStart() = %s", start)
	}
	if formatted := FormatMonth(at); formatted != "2026-09" {
		t.Errorf("FormatMonth() = %q, want 2026-09", formatted)
	}
	// 非 UTC 时刻必须先归一到 UTC，否则跨时区会把月份算错。
	shanghai := time.FixedZone("CST", 8*3600)
	edge := time.Date(2026, time.October, 1, 3, 0, 0, 0, shanghai)
	if start := MonthStart(edge); !start.Equal(time.Date(2026, time.September, 1, 0, 0, 0, 0, time.UTC)) {
		t.Errorf("MonthStart(edge) = %s, want 2026-09-01", start)
	}
}
