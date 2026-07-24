package dictionary

import "testing"

func TestNormalizeNameAppliesNFKCWhitespaceCollapseAndLatinLowercase(t *testing.T) {
	if got := NormalizeName("  Ａcme\t  公司\n"); got != "acme 公司" {
		t.Fatalf("NormalizeName()=%q want=%q", got, "acme 公司")
	}
	if got := NormalizeName("Cafe\u0301"); got != "café" {
		t.Fatalf("NormalizeName()=%q want=%q", got, "café")
	}
}
