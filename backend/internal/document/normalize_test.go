package document

import (
	"testing"
	"time"
)

func TestParseBusinessDateAcceptsHumanFormats(t *testing.T) {
	cases := map[string]string{
		"2026-09-22":    "2026-09-22",
		"2026/9/22":     "2026-09-22",
		"2026 9 22":     "2026-09-22",
		"2026年9月22日":    "2026-09-22",
		"2026.09.22":    "2026-09-22",
		"20260922":      "2026-09-22",
		"  2026 3 14  ": "2026-03-14",
		"2026-3-4":      "2026-03-04",
	}
	for raw, want := range cases {
		got, err := parseBusinessDate(raw)
		if err != nil {
			t.Fatalf("parseBusinessDate(%q) error = %v", raw, err)
		}
		if got.Format("2006-01-02") != want {
			t.Fatalf("parseBusinessDate(%q) = %s, want %s", raw, got.Format("2006-01-02"), want)
		}
		if got.Location() != time.UTC {
			t.Fatalf("parseBusinessDate(%q) location = %v, want UTC", raw, got.Location())
		}
	}
}

func TestParseBusinessDateRejectsInvalidInput(t *testing.T) {
	// 2026-02-31 会被 time.Date 规范化成 3 月 3 日，必须显式拒绝而不是静默落库。
	for _, raw := range []string{"", "  ", "2026-02-31", "2026-13-01", "2026-00-10", "2026-09", "202609", "1998-01-01", "abc"} {
		if _, err := parseBusinessDate(raw); err == nil {
			t.Errorf("parseBusinessDate(%q) expected error, got nil", raw)
		}
	}
}

func TestParseMonthRange(t *testing.T) {
	start, end, err := parseMonthRange("2026-09")
	if err != nil {
		t.Fatalf("parseMonthRange() error = %v", err)
	}
	if start.Format("2006-01-02") != "2026-09-01" || end.Format("2006-01-02") != "2026-10-01" {
		t.Fatalf("range = %s ~ %s", start, end)
	}
	// 12 月必须正确跨年。
	start, end, err = parseMonthRange("2026/12")
	if err != nil {
		t.Fatalf("parseMonthRange() error = %v", err)
	}
	if end.Format("2006-01-02") != "2027-01-01" {
		t.Fatalf("december end = %s, want 2027-01-01", end)
	}
	for _, raw := range []string{"", "2026", "2026-13", "26-1"} {
		if _, _, err := parseMonthRange(raw); err == nil {
			t.Errorf("parseMonthRange(%q) expected error", raw)
		}
	}
}

func TestDocumentNumberHelpers(t *testing.T) {
	date := time.Date(2026, time.September, 22, 0, 0, 0, 0, time.UTC)
	if got := formatDocumentNo(KindInbound, date, 7); got != "RK20260922-0007" {
		t.Fatalf("inbound number = %q", got)
	}
	if got := formatDocumentNo(KindOutbound, date, 11); got != "CK20260922-0011" {
		t.Fatalf("outbound number = %q", got)
	}
	if got := documentNoLikePattern(KindInbound, date); got != "RK20260922-%" {
		t.Fatalf("like pattern = %q", got)
	}
	cases := map[string]int{
		"RK20260922-0007": 7,
		"RK20260922-9999": 9999,
		"RK20260922":      0,
		"RK20260922-":     0,
		"RK20260922-abc":  0,
	}
	for raw, want := range cases {
		if got := sequenceFromDocumentNo(raw); got != want {
			t.Fatalf("sequenceFromDocumentNo(%q) = %d, want %d", raw, got, want)
		}
	}
}

func TestNormalizeTextFoldsWhitespace(t *testing.T) {
	value, err := normalizeText(textPointer("  宏达   建筑  "), 191)
	if err != nil {
		t.Fatalf("normalizeText() error = %v", err)
	}
	if value == nil || *value != "宏达 建筑" {
		t.Fatalf("normalizeText() = %v", value)
	}
	// 纯空白视为未填写，统一折叠成 nil，避免把 "" 和 "  " 当成两种值。
	empty, err := normalizeText(textPointer("   "), 191)
	if err != nil || empty != nil {
		t.Fatalf("normalizeText(blank) = %v, %v; want nil, nil", empty, err)
	}
	if _, err := normalizeText(textPointer("0123456789"), 5); err == nil {
		t.Fatal("超长文本必须被拒绝")
	}
	if _, err := normalizeRequiredText("  ", 10); err == nil {
		t.Fatal("必填文本为空必须被拒绝")
	}
}

func TestKindHelpers(t *testing.T) {
	if kind, err := ParseKind("inbound"); err != nil || kind != KindInbound {
		t.Fatalf("ParseKind(inbound) = %v, %v", kind, err)
	}
	if kind, err := ParseKind("outbound"); err != nil || !kind.IsInbound() == false {
		t.Fatalf("ParseKind(outbound) = %v, %v", kind, err)
	}
	if _, err := ParseKind("settlement"); err == nil {
		t.Fatal("ParseKind() must reject unknown kinds")
	}
	if KindOutbound.NumberPrefix() != "CK" || KindInbound.NumberPrefix() != "RK" {
		t.Fatal("number prefix mismatch")
	}
}
