// Package rmb 提供人民币金额大写转换。
//
// 客户端（Android / Windows / Web）都需要展示「RMB壹拾肆万陆仟玖佰捌拾贰元叁角叁分」，
// 放在服务端生成可以保证三端结果完全一致，避免各端各写一套算法产生分歧。
package rmb

import "CBizDocsManager/backend/pkg/money"

// 大写数字、节内单位与节单位。
var (
	digits   = [...]string{"零", "壹", "贰", "叁", "肆", "伍", "陆", "柒", "捌", "玖"}
	units    = [...]string{"", "拾", "佰", "仟"}
	sections = [...]string{"", "万", "亿", "万亿"}
)

// Upper 把金额转换成人民币大写，例如 14698233 分 → 「RMB壹拾肆万陆仟玖佰捌拾贰元叁角叁分」。
//
// 算法分三步：按万/亿分节、节内按拾佰仟逐位取字、节间与角分处补「零」。
// 超出 4 个节（即 1 亿元亿以上）的金额不在一期业务范围内，直接返回提示文本而不是 panic。
func Upper(amount money.Amount) string {
	cents := int64(amount)
	negative := cents < 0
	if negative {
		cents = -cents
	}
	if cents == 0 {
		return "RMB零元整"
	}

	integer := cents / 100
	fraction := cents % 100

	// 从低位节往高位节收集，随后倒序拼接。
	type sectionItem struct {
		value int64
		unit  string
	}
	items := make([]sectionItem, 0, len(sections))
	rest := integer
	for index := 0; rest > 0; index++ {
		if index >= len(sections) {
			return "RMB金额超出展示范围"
		}
		items = append(items, sectionItem{value: rest % 10000, unit: sections[index]})
		rest /= 10000
	}

	integerText := ""
	for index := len(items) - 1; index >= 0; index-- {
		item := items[index]
		if item.value == 0 {
			continue
		}
		// 高位节已经写过内容，而当前节不足千（千位为 0）时需要补一个「零」，
		// 例如 100000001 → 壹亿零壹。
		if integerText != "" && item.value < 1000 {
			integerText += "零"
		}
		integerText += sectionText(item.value) + item.unit
	}

	fractionText := ""
	if fraction > 0 {
		jiao := fraction / 10
		fen := fraction % 10
		if jiao > 0 {
			fractionText += digits[jiao] + "角"
		}
		if fen > 0 {
			// 有元无角时补「零」，避免出现「壹佰元伍分」这种读不通的写法。
			if jiao == 0 && integer > 0 {
				fractionText += "零"
			}
			fractionText += digits[fen] + "分"
		}
	} else {
		fractionText = "整"
	}

	head := "零元"
	if integer > 0 {
		head = integerText + "元"
	}
	prefix := "RMB"
	if negative {
		prefix = "RMB负"
	}
	return prefix + head + fractionText
}

// sectionText 把一个 0–9999 的节转成字串（不含节单位），节内连续零只保留一个且不留尾零。
func sectionText(section int64) string {
	text := ""
	unitIndex := 0
	zeroPending := false
	for section > 0 {
		digit := section % 10
		section /= 10
		if digit == 0 {
			if text != "" {
				zeroPending = true
			}
		} else {
			if zeroPending {
				text = "零" + text
				zeroPending = false
			}
			text = digits[digit] + units[unitIndex] + text
		}
		unitIndex++
	}
	return text
}
