package dictionary

import (
	"strings"
	"unicode"

	"golang.org/x/text/unicode/norm"
)

func NormalizeName(value string) string {
	// NFKC 先统一全角、兼容字符和组合形式，再折叠所有 Unicode 空白。
	value = strings.Join(strings.Fields(norm.NFKC.String(value)), " ")
	return strings.Map(func(char rune) rune {
		if unicode.In(char, unicode.Latin) {
			return unicode.ToLower(char)
		}
		return char
	}, value)
}
