package logger

import (
	"fmt"
	"strings"

	"go.uber.org/zap"
	"go.uber.org/zap/zapcore"
)

// New 创建可注入的结构化 Zap Logger；production 使用 JSON，其余环境使用便于开发的控制台编码。
func New(env, level string) (*zap.Logger, error) {
	if strings.TrimSpace(level) == "" {
		level = "info"
	}

	var parsedLevel zapcore.Level
	if err := parsedLevel.UnmarshalText([]byte(level)); err != nil {
		return nil, fmt.Errorf("解析日志级别 %q: %w", level, err)
	}

	var cfg zap.Config
	if strings.EqualFold(strings.TrimSpace(env), "production") {
		cfg = zap.NewProductionConfig()
	} else {
		cfg = zap.NewDevelopmentConfig()
	}
	cfg.Level = zap.NewAtomicLevelAt(parsedLevel)

	log, err := cfg.Build()
	if err != nil {
		return nil, fmt.Errorf("初始化 Zap Logger: %w", err)
	}
	return log, nil
}
