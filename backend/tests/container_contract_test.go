package tests

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestDockerContextExcludesLocalSecretsAndBuildArtifacts(t *testing.T) {
	ignorePath := filepath.Join("..", ".dockerignore")
	content, err := os.ReadFile(ignorePath)
	if err != nil {
		t.Fatalf("read %s: %v", ignorePath, err)
	}

	rules := strings.Split(strings.ReplaceAll(string(content), "\r\n", "\n"), "\n")
	for _, required := range []string{".env", ".env.*", "!.env.example", "*.exe", "*.test", "tmp/", "dist/"} {
		if !containsLine(rules, required) {
			t.Errorf(".dockerignore is missing rule %q", required)
		}
	}
}

func containsLine(lines []string, wanted string) bool {
	for _, line := range lines {
		if strings.TrimSpace(line) == wanted {
			return true
		}
	}
	return false
}
