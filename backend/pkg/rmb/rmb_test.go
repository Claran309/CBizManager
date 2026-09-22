package rmb

import (
	"testing"

	"CBizDocsManager/backend/pkg/money"
)

func TestUpperMatchesPrototypeCases(t *testing.T) {
	// 与 docs/prototype/index.html 中经自检脚本验证过的 16 组用例保持一致：
	// 前端原型与后端必须给出同一结果，否则三端展示会互相矛盾。
	cases := []struct {
		amount string
		want   string
	}{
		{amount: "146982.33", want: "RMB壹拾肆万陆仟玖佰捌拾贰元叁角叁分"},
		{amount: "173540.00", want: "RMB壹拾柒万叁仟伍佰肆拾元整"},
		{amount: "0.00", want: "RMB零元整"},
		{amount: "1.00", want: "RMB壹元整"},
		{amount: "100000000.00", want: "RMB壹亿元整"},
		{amount: "100000000.50", want: "RMB壹亿元伍角"},
		{amount: "72000.00", want: "RMB柒万贰仟元整"},
		{amount: "10001.00", want: "RMB壹万零壹元整"},
		{amount: "3782.33", want: "RMB叁仟柒佰捌拾贰元叁角叁分"},
		{amount: "100.05", want: "RMB壹佰元零伍分"},
		{amount: "1000001.00", want: "RMB壹佰万零壹元整"},
		{amount: "10010001.00", want: "RMB壹仟零壹万零壹元整"},
		{amount: "100000001.00", want: "RMB壹亿零壹元整"},
		{amount: "10.00", want: "RMB壹拾元整"},
		{amount: "20.40", want: "RMB贰拾元肆角"},
		{amount: "3000000000000.00", want: "RMB叁万亿元整"},
	}
	for _, testCase := range cases {
		t.Run(testCase.amount, func(t *testing.T) {
			amount, err := money.ParseAmount(testCase.amount)
			if err != nil {
				t.Fatalf("ParseAmount(%q) error = %v", testCase.amount, err)
			}
			if got := Upper(amount); got != testCase.want {
				t.Fatalf("Upper(%s) = %q, want %q", testCase.amount, got, testCase.want)
			}
		})
	}
}

func TestUpperHandlesNegativeAndOutOfRange(t *testing.T) {
	amount, err := money.ParseAmount("-146982.33")
	if err != nil {
		t.Fatalf("ParseAmount error = %v", err)
	}
	if got := Upper(amount); got != "RMB负壹拾肆万陆仟玖佰捌拾贰元叁角叁分" {
		t.Fatalf("Upper(negative) = %q", got)
	}

	// 超过 4 个节（万亿以上）时给出明确提示，而不是越界 panic。
	huge := money.Amount(9223372036854775807)
	if got := Upper(huge); got != "RMB金额超出展示范围" {
		t.Fatalf("Upper(huge) = %q, want 超出范围提示", got)
	}
}
