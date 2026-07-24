package cache

import (
	"context"
	"fmt"
	"strings"

	"CBizDocsManager/backend/pkg/config"
	"github.com/redis/go-redis/v9"
	"go.uber.org/zap"
)

type State string

const (
	StateUp       State = "up"
	StateDown     State = "down"
	StateDisabled State = "disabled"
)

func Open(ctx context.Context, cfg config.RedisConfig, log *zap.Logger) (*redis.Client, State) {
	if strings.TrimSpace(cfg.Addr) == "" {
		return nil, StateDisabled
	}
	if log == nil {
		log = zap.NewNop()
	}
	redis.SetLogger(&redisZapLogger{log: log})
	client := redis.NewClient(&redis.Options{
		Addr: cfg.Addr, Password: cfg.Password, DB: cfg.DB,
		DialTimeout: cfg.DialTimeout, ReadTimeout: cfg.ReadTimeout, WriteTimeout: cfg.WriteTimeout,
	})
	if err := client.Ping(ctx).Err(); err != nil {
		_ = client.Close()
		log.Warn("Redis 不可用，服务以降级模式启动", zap.Error(err))
		return nil, StateDown
	}
	return client, StateUp
}

type redisZapLogger struct {
	log *zap.Logger
}

func (l *redisZapLogger) Printf(_ context.Context, format string, values ...interface{}) {
	l.log.Debug("Redis 客户端诊断", zap.String("detail", fmt.Sprintf(format, values...)))
}
