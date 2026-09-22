// Package money 提供定点十进制数值类型，用于在 HTTP、Service、仓储和数据库之间
// 全程避免二进制浮点误差。数量级约定如下：
//
//   - Amount   ：金额，内部单位「分」（1 元 = 100 分），数据库列 DECIMAL(18,2)。
//   - Price    ：单价，内部单位「万分之一元」，数据库列 DECIMAL(18,4)。
//   - Quantity ：数量，内部单位「千分之一」，数据库列 DECIMAL(18,3)。
//
// 三者的 JSON 表示统一使用十进制字符串（例如 "146982.33"），原因是 JS/Dart 的
// number 都是 IEEE-754 双精度，直接用数字传输会在客户端产生精度截断。
package money

import (
	"database/sql/driver"
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"math/big"
	"strconv"
	"strings"
)

const (
	// AmountScale 是金额的小数位数。
	AmountScale = 2
	// PriceScale 是单价的小数位数。
	PriceScale = 4
	// QuantityScale 是数量的小数位数。
	QuantityScale = 3
)

// ErrInvalidValue 表示字符串无法无误差地转换为定点数。
var ErrInvalidValue = errors.New("invalid fixed-point value")

// Amount 是以「分」为单位的金额。
type Amount int64

// Price 是以「万分之一元」为单位的单价。
type Price int64

// Quantity 是以「千分之一」为单位的数量/重量。
type Quantity int64

/* ------------------------------------------------------------------ 构造与格式化 */

// AmountFromYuan 用「元」构造金额，仅用于代码内常量与测试。
func AmountFromYuan(yuan int64) Amount { return Amount(yuan * 100) }

// ParseAmount 解析十进制字符串为金额。
func ParseAmount(raw string) (Amount, error) {
	value, err := parseFixed(raw, AmountScale)
	return Amount(value), err
}

// ParsePrice 解析十进制字符串为单价。
func ParsePrice(raw string) (Price, error) {
	value, err := parseFixed(raw, PriceScale)
	return Price(value), err
}

// ParseQuantity 解析十进制字符串为数量。
func ParseQuantity(raw string) (Quantity, error) {
	value, err := parseFixed(raw, QuantityScale)
	return Quantity(value), err
}

// String 返回金额的十进制字符串，例如 "146982.33"。
func (a Amount) String() string { return formatFixed(int64(a), AmountScale) }

// String 返回单价的十进制字符串，例如 "2975.4300"。
func (p Price) String() string { return formatFixed(int64(p), PriceScale) }

// String 返回数量的十进制字符串，例如 "17.050"。
func (q Quantity) String() string { return formatFixed(int64(q), QuantityScale) }

// Yuan 返回去掉小数尾零的金额文本，用于拼装人民币大写等展示场景。
func (a Amount) Yuan() string { return trimTrailingZeros(formatFixed(int64(a), AmountScale)) }

/* ------------------------------------------------------------------ 运算 */

// Add 返回两个金额之和。
func (a Amount) Add(other Amount) Amount { return a + other }

// Sub 返回两个金额之差。
func (a Amount) Sub(other Amount) Amount { return a - other }

// IsZero 判断金额是否为零。
func (a Amount) IsZero() bool { return a == 0 }

// IsNegative 判断金额是否为负。
func (a Amount) IsNegative() bool { return a < 0 }

// SumAmounts 累加一组金额，禁止使用浮点累加。
func SumAmounts(values []Amount) Amount {
	var total Amount
	for _, value := range values {
		total += value
	}
	return total
}

// Mul 计算「单价 × 数量」并四舍五入到分。
//
// price 的单位是 10^-4 元，quantity 的单位是 10^-3，两者相乘的单位是 10^-7 元；
// 换算成「分」（10^-2 元）需要除以 10^5。乘法用 big.Int 完成，避免 int64 溢出
// 造成静默错误（钢材场景下单价与数量的乘积很容易超过 9.2e18）。
func Mul(price Price, quantity Quantity) Amount {
	product := new(big.Int).Mul(big.NewInt(int64(price)), big.NewInt(int64(quantity)))
	divisor := big.NewInt(100000)
	quotient, remainder := new(big.Int), new(big.Int)
	quotient.QuoRem(product, divisor, remainder)

	// 余数绝对值达到除数的一半时进位：|remainder| * 2 >= divisor。
	doubled := new(big.Int).Abs(remainder)
	doubled.Lsh(doubled, 1)
	if doubled.Cmp(divisor) >= 0 {
		if product.Sign() < 0 {
			quotient.Sub(quotient, big.NewInt(1))
		} else {
			quotient.Add(quotient, big.NewInt(1))
		}
	}
	if !quotient.IsInt64() {
		return Amount(math.MaxInt64)
	}
	return Amount(quotient.Int64())
}

/* ------------------------------------------------------------------ database/sql 与 JSON */

// GormDataType 告知 GORM 该字段对应的数据库类型（迁移与 sqlite 测试需要）。
func (Amount) GormDataType() string { return "decimal(18,2)" }

// GormDataType 告知 GORM 该字段对应的数据库类型。
func (Price) GormDataType() string { return "decimal(18,4)" }

// GormDataType 告知 GORM 该字段对应的数据库类型。
func (Quantity) GormDataType() string { return "decimal(18,3)" }

// Value 实现 driver.Valuer，把金额以十进制字符串写入 DECIMAL 列。
func (a Amount) Value() (driver.Value, error) { return formatFixed(int64(a), AmountScale), nil }

// Scan 实现 sql.Scanner，兼容 MySQL 的 []byte 与 sqlite 的 string/float64。
func (a *Amount) Scan(src any) error {
	value, err := scanFixed(src, AmountScale)
	if err != nil {
		return err
	}
	*a = Amount(value)
	return nil
}

// Value 实现 driver.Valuer，把单价以十进制字符串写入 DECIMAL 列。
func (p Price) Value() (driver.Value, error) { return formatFixed(int64(p), PriceScale), nil }

// Scan 实现 sql.Scanner。
func (p *Price) Scan(src any) error {
	value, err := scanFixed(src, PriceScale)
	if err != nil {
		return err
	}
	*p = Price(value)
	return nil
}

// Value 实现 driver.Valuer，把数量以十进制字符串写入 DECIMAL 列。
func (q Quantity) Value() (driver.Value, error) { return formatFixed(int64(q), QuantityScale), nil }

// Scan 实现 sql.Scanner。
func (q *Quantity) Scan(src any) error {
	value, err := scanFixed(src, QuantityScale)
	if err != nil {
		return err
	}
	*q = Quantity(value)
	return nil
}

// MarshalJSON 让金额在 JSON 中以字符串输出，避免客户端浮点截断。
func (a Amount) MarshalJSON() ([]byte, error) { return marshalFixed(int64(a), AmountScale) }

// UnmarshalJSON 同时接受字符串与数字形式的金额。
func (a *Amount) UnmarshalJSON(data []byte) error {
	value, err := unmarshalFixed(data, AmountScale)
	if err != nil {
		return err
	}
	*a = Amount(value)
	return nil
}

// MarshalJSON 让单价在 JSON 中以字符串输出。
func (p Price) MarshalJSON() ([]byte, error) { return marshalFixed(int64(p), PriceScale) }

// UnmarshalJSON 同时接受字符串与数字形式的单价。
func (p *Price) UnmarshalJSON(data []byte) error {
	value, err := unmarshalFixed(data, PriceScale)
	if err != nil {
		return err
	}
	*p = Price(value)
	return nil
}

// MarshalJSON 让数量在 JSON 中以字符串输出。
func (q Quantity) MarshalJSON() ([]byte, error) { return marshalFixed(int64(q), QuantityScale) }

// UnmarshalJSON 同时接受字符串与数字形式的数量。
func (q *Quantity) UnmarshalJSON(data []byte) error {
	value, err := unmarshalFixed(data, QuantityScale)
	if err != nil {
		return err
	}
	*q = Quantity(value)
	return nil
}

/* ------------------------------------------------------------------ 内部实现 */

func marshalFixed(value int64, scale int) ([]byte, error) {
	return []byte(`"` + formatFixed(value, scale) + `"`), nil
}

func unmarshalFixed(data []byte, scale int) (int64, error) {
	text := strings.TrimSpace(string(data))
	if text == "null" {
		return 0, nil
	}
	if strings.HasPrefix(text, `"`) {
		var decoded string
		if err := json.Unmarshal(data, &decoded); err != nil {
			return 0, fmt.Errorf("%w: %v", ErrInvalidValue, err)
		}
		return parseFixed(decoded, scale)
	}
	return parseFixed(text, scale)
}

func scanFixed(src any, scale int) (int64, error) {
	switch value := src.(type) {
	case nil:
		return 0, nil
	case int64:
		return scaleUpInt64(value, scale)
	case float64:
		// sqlite 的 NUMERIC 亲和性可能把 DECIMAL 交回 float64，按 scale 位定点化并校验无损。
		return parseFixed(strconv.FormatFloat(value, 'f', scale, 64), scale)
	case string:
		return parseFixed(value, scale)
	case []byte:
		return parseFixed(string(value), scale)
	default:
		return 0, fmt.Errorf("%w: unsupported source type %T", ErrInvalidValue, src)
	}
}

// scaleUpInt64 处理驱动直接返回整数的情况（例如 DECIMAL 列为整数值时）。
func scaleUpInt64(value int64, scale int) (int64, error) {
	unit := pow10(scale)
	if value > math.MaxInt64/unit || value < math.MinInt64/unit {
		return 0, fmt.Errorf("%w: integer %d overflows scale %d", ErrInvalidValue, value, scale)
	}
	return value * unit, nil
}

func formatFixed(value int64, scale int) string {
	if value == math.MinInt64 {
		// 取绝对值会溢出，这种极端值在业务上不可能出现，直接标记为非零最小值处理。
		return "-" + formatFixed(math.MaxInt64, scale)
	}
	negative := value < 0
	if negative {
		value = -value
	}
	unit := pow10(scale)
	text := strconv.FormatInt(value/unit, 10)
	if scale > 0 {
		digits := strconv.FormatInt(value%unit, 10)
		text += "." + strings.Repeat("0", scale-len(digits)) + digits
	}
	if negative {
		text = "-" + text
	}
	return text
}

func parseFixed(raw string, scale int) (int64, error) {
	text := strings.TrimSpace(strings.ReplaceAll(raw, ",", ""))
	text = strings.TrimSpace(text)
	if text == "" {
		return 0, fmt.Errorf("%w: empty value", ErrInvalidValue)
	}
	// 科学计数法意味着调用方已经在用浮点计算，拒绝而不是悄悄丢精度。
	if strings.ContainsAny(text, "eE") {
		return 0, fmt.Errorf("%w: scientific notation %q is not allowed", ErrInvalidValue, raw)
	}
	text = strings.TrimPrefix(text, "+")
	negative := strings.HasPrefix(text, "-")
	text = strings.TrimPrefix(text, "-")

	parts := strings.Split(text, ".")
	if len(parts) > 2 {
		return 0, fmt.Errorf("%w: %q has multiple decimal points", ErrInvalidValue, raw)
	}
	intPart := parts[0]
	fracPart := ""
	if len(parts) == 2 {
		fracPart = parts[1]
	}
	if intPart == "" && fracPart == "" {
		return 0, fmt.Errorf("%w: %q has no digits", ErrInvalidValue, raw)
	}
	if !isDigits(intPart) || !isDigits(fracPart) {
		return 0, fmt.Errorf("%w: %q contains non-digit characters", ErrInvalidValue, raw)
	}
	// 小数位超过精度时，多余位必须全为 0，否则拒绝，防止静默截断金额。
	if len(fracPart) > scale {
		for index := scale; index < len(fracPart); index++ {
			if fracPart[index] != '0' {
				return 0, fmt.Errorf("%w: %q exceeds %d decimal places", ErrInvalidValue, raw, scale)
			}
		}
		fracPart = fracPart[:scale]
	}
	fracPart += strings.Repeat("0", scale-len(fracPart))

	intValue := int64(0)
	if intPart != "" {
		parsed, err := strconv.ParseInt(intPart, 10, 64)
		if err != nil {
			return 0, fmt.Errorf("%w: %q integer part out of range", ErrInvalidValue, raw)
		}
		intValue = parsed
	}
	fracValue := int64(0)
	if fracPart != "" {
		parsed, err := strconv.ParseInt(fracPart, 10, 64)
		if err != nil {
			return 0, fmt.Errorf("%w: %q fraction part out of range", ErrInvalidValue, raw)
		}
		fracValue = parsed
	}

	unit := pow10(scale)
	if intValue > (math.MaxInt64-fracValue)/unit || intValue < (math.MinInt64+fracValue)/unit {
		return 0, fmt.Errorf("%w: %q out of range", ErrInvalidValue, raw)
	}
	total := intValue*unit + fracValue
	if negative {
		total = -total
	}
	return total, nil
}

func pow10(scale int) int64 {
	value := int64(1)
	for index := 0; index < scale; index++ {
		value *= 10
	}
	return value
}

func isDigits(text string) bool {
	for _, char := range text {
		if char < '0' || char > '9' {
			return false
		}
	}
	return true
}

// trimTrailingZeros 去掉小数部分末尾的 0，并在小数部分为空时去掉小数点。
func trimTrailingZeros(text string) string {
	if !strings.Contains(text, ".") {
		return text
	}
	text = strings.TrimRight(text, "0")
	return strings.TrimSuffix(text, ".")
}
