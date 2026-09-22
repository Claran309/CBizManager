package money

import (
	"encoding/json"
	"errors"
	"testing"
)

func TestParseAndFormatRoundTrip(t *testing.T) {
	amountCases := map[string]Amount{
		"0.00":              0,
		"146982.33":         14698233,
		"-33.05":            -3305,
		"1,234,567.89":      123456789,
		"99999999999999.99": 9999999999999999,
	}
	for text, want := range amountCases {
		got, err := ParseAmount(text)
		if err != nil {
			t.Fatalf("ParseAmount(%q) error = %v", text, err)
		}
		if got != want {
			t.Fatalf("ParseAmount(%q) = %d, want %d", text, got, want)
		}
	}

	if got := Amount(14698233).String(); got != "146982.33" {
		t.Fatalf("Amount.String() = %q, want %q", got, "146982.33")
	}
	if got := Amount(-3305).String(); got != "-33.05" {
		t.Fatalf("Amount.String() = %q, want %q", got, "-33.05")
	}
	if got := Price(29754300).String(); got != "2975.4300" {
		t.Fatalf("Price.String() = %q, want %q", got, "2975.4300")
	}
	if got := Quantity(17050).String(); got != "17.050" {
		t.Fatalf("Quantity.String() = %q, want %q", got, "17.050")
	}
	// Yuan 去掉尾零，供人民币大写展示使用。
	if got := Amount(14698200).Yuan(); got != "146982" {
		t.Fatalf("Amount.Yuan() = %q, want %q", got, "146982")
	}
}

func TestParseRejectsSilentPrecisionLoss(t *testing.T) {
	cases := []string{
		"1.005",                   // 金额只允许 2 位小数，且第 3 位非 0
		"1e3",                     // 科学计数法意味着上游已用浮点
		"abc",                     // 非数字
		"1.2.3",                   // 多个小数点
		"",                        // 空
		"   ",                     // 空白
		"1.2x",                    // 混入字母
		"-.",                      // 只有符号
		"99999999999999999999.00", // 超出 int64
	}
	for _, text := range cases {
		if _, err := ParseAmount(text); err == nil {
			t.Errorf("ParseAmount(%q) expected error, got nil", text)
		} else if !errors.Is(err, ErrInvalidValue) {
			t.Errorf("ParseAmount(%q) error = %v, want ErrInvalidValue", text, err)
		}
	}
	// 超出精度但多余位全为 0 属于可无损转换，必须接受。
	if got, err := ParseAmount("1.200"); err != nil || got != 120 {
		t.Fatalf("ParseAmount(\"1.200\") = %d, %v; want 120, nil", got, err)
	}
}

func TestMulRoundsHalfUpToCents(t *testing.T) {
	cases := []struct {
		name     string
		price    string
		quantity string
		want     string
	}{
		{name: "整数相乘", price: "1800.0000", quantity: "40.000", want: "72000.00"},
		{name: "标称精度相乘", price: "1742.86", quantity: "14.000", want: "24400.04"},
		{name: "带小数数量", price: "2975.43", quantity: "17.050", want: "50731.08"},
		{name: "进位到分", price: "0.3333", quantity: "1.000", want: "0.33"},
		{name: "半值向上取整", price: "0.0050", quantity: "1.000", want: "0.01"},
		{name: "零数量", price: "1234.5600", quantity: "0.000", want: "0.00"},
		{name: "四舍五入到分", price: "12.3456", quantity: "3.000", want: "37.04"},
	}
	for _, testCase := range cases {
		t.Run(testCase.name, func(t *testing.T) {
			price, err := ParsePrice(testCase.price)
			if err != nil {
				t.Fatalf("ParsePrice(%q) error = %v", testCase.price, err)
			}
			quantity, err := ParseQuantity(testCase.quantity)
			if err != nil {
				t.Fatalf("ParseQuantity(%q) error = %v", testCase.quantity, err)
			}
			want, err := ParseAmount(testCase.want)
			if err != nil {
				t.Fatalf("ParseAmount(%q) error = %v", testCase.want, err)
			}
			if got := Mul(price, quantity); got != want {
				t.Fatalf("Mul(%s, %s) = %s, want %s", testCase.price, testCase.quantity, got, want)
			}
		})
	}
}

func TestMulDoesNotOverflowOnLargeProduct(t *testing.T) {
	// 单价 1 亿元/吨 × 数量 10 亿吨，乘积远超 int64，必须得到确定的饱和值而不是负数。
	price, err := ParsePrice("100000000.0000")
	if err != nil {
		t.Fatalf("ParsePrice error = %v", err)
	}
	quantity, err := ParseQuantity("1000000000.000")
	if err != nil {
		t.Fatalf("ParseQuantity error = %v", err)
	}
	if got := Mul(price, quantity); got <= 0 {
		t.Fatalf("Mul() = %d, want a positive saturated value", got)
	}
}

func TestSumAmounts(t *testing.T) {
	total := SumAmounts([]Amount{9640000, 5058233, 0, 14698233})
	if total != 29396466 {
		t.Fatalf("SumAmounts() = %d, want 29396466", total)
	}
	if total.String() != "293964.66" {
		t.Fatalf("SumAmounts().String() = %q, want %q", total.String(), "293964.66")
	}
}

func TestJSONUsesStringsAndAcceptsNumbers(t *testing.T) {
	type payload struct {
		Amount   Amount   `json:"amount"`
		Price    Price    `json:"price"`
		Quantity Quantity `json:"quantity"`
	}
	encoded, err := json.Marshal(payload{Amount: 14698233, Price: 29754300, Quantity: 17050})
	if err != nil {
		t.Fatalf("Marshal() error = %v", err)
	}
	want := `{"amount":"146982.33","price":"2975.4300","quantity":"17.050"}`
	if string(encoded) != want {
		t.Fatalf("Marshal() = %s, want %s", encoded, want)
	}

	var decoded payload
	fixture := []byte(`{"amount":146982.33,"price":"1742.86","quantity":"17.05"}`)
	if err := json.Unmarshal(fixture, &decoded); err != nil {
		t.Fatalf("Unmarshal() error = %v", err)
	}
	if decoded.Amount != 14698233 || decoded.Price != 17428600 || decoded.Quantity != 17050 {
		t.Fatalf("Unmarshal() = %+v", decoded)
	}

	// null 视为零值，便于客户端省略可选字段。
	var nullable payload
	if err := json.Unmarshal([]byte(`{"amount":null,"price":null,"quantity":null}`), &nullable); err != nil {
		t.Fatalf("Unmarshal(null) error = %v", err)
	}
	if nullable.Amount != 0 || nullable.Price != 0 || nullable.Quantity != 0 {
		t.Fatalf("Unmarshal(null) = %+v, want zero values", nullable)
	}
}

func TestScanAndValueSupportDriverTypes(t *testing.T) {
	var amount Amount
	if err := amount.Scan([]byte("146982.33")); err != nil {
		t.Fatalf("Scan([]byte) error = %v", err)
	}
	if amount != 14698233 {
		t.Fatalf("Scan([]byte) = %d, want 14698233", amount)
	}
	if err := amount.Scan("12.5"); err != nil {
		t.Fatalf("Scan(string) error = %v", err)
	}
	if amount != 1250 {
		t.Fatalf("Scan(string) = %d, want 1250", amount)
	}
	// sqlite 的 NUMERIC 亲和性可能把 DECIMAL 交回 float64。
	if err := amount.Scan(float64(33.1)); err != nil {
		t.Fatalf("Scan(float64) error = %v", err)
	}
	if amount != 3310 {
		t.Fatalf("Scan(float64) = %d, want 3310", amount)
	}
	// 整数 7 表示 7.00 元。
	if err := amount.Scan(int64(7)); err != nil {
		t.Fatalf("Scan(int64) error = %v", err)
	}
	if amount != 700 {
		t.Fatalf("Scan(int64) = %d, want 700", amount)
	}

	value, err := Amount(14698233).Value()
	if err != nil {
		t.Fatalf("Value() error = %v", err)
	}
	if value != "146982.33" {
		t.Fatalf("Value() = %v, want \"146982.33\"", value)
	}

	if err := amount.Scan(struct{}{}); err == nil {
		t.Fatal("Scan(struct{}) expected error, got nil")
	}
}
