package httpserver

import (
	"context"
	"database/sql"
	"errors"

	"CBizDocsManager/backend/internal/infrastructure/cache"
	"github.com/redis/go-redis/v9"
)

type RuntimeHealthChecker struct {
	db         *sql.DB
	redisState cache.State
	redisPing  func(context.Context) error
}

func NewRuntimeHealthChecker(db *sql.DB, redisClient *redis.Client, redisState cache.State) *RuntimeHealthChecker {
	var redisPing func(context.Context) error
	if redisClient != nil {
		redisPing = func(ctx context.Context) error { return redisClient.Ping(ctx).Err() }
	}
	return newRuntimeHealthChecker(db, redisState, redisPing)
}

func newRuntimeHealthChecker(db *sql.DB, redisState cache.State, redisPing func(context.Context) error) *RuntimeHealthChecker {
	return &RuntimeHealthChecker{db: db, redisState: redisState, redisPing: redisPing}
}

func (h *RuntimeHealthChecker) PingMySQL(ctx context.Context) error {
	if h.db == nil {
		return errors.New("MySQL 连接未初始化")
	}
	return h.db.PingContext(ctx)
}

func (h *RuntimeHealthChecker) RedisState(ctx context.Context) string {
	if h.redisState == cache.StateDisabled {
		return string(cache.StateDisabled)
	}
	if h.redisPing == nil || h.redisPing(ctx) != nil {
		return string(cache.StateDown)
	}
	return string(cache.StateUp)
}
