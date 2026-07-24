package httpserver

import (
	"context"
	"database/sql"
	"errors"
	"testing"

	"CBizDocsManager/backend/internal/infrastructure/cache"
	_ "github.com/glebarez/sqlite"
)

func TestRuntimeHealthCheckerPingsMySQLAndReportsRedisState(t *testing.T) {
	db, err := sql.Open("sqlite", ":memory:")
	if err != nil {
		t.Fatalf("open test database: %v", err)
	}
	redisErr := error(nil)
	health := newRuntimeHealthChecker(db, cache.StateUp, func(context.Context) error { return redisErr })

	if err := health.PingMySQL(context.Background()); err != nil {
		t.Fatalf("PingMySQL() error = %v", err)
	}
	if got := health.RedisState(context.Background()); got != "up" {
		t.Fatalf("RedisState() = %q, want up", got)
	}
	redisErr = errors.New("redis unavailable")
	if got := health.RedisState(context.Background()); got != "down" {
		t.Fatalf("RedisState() after ping failure = %q, want down", got)
	}

	if err := db.Close(); err != nil {
		t.Fatalf("close test database: %v", err)
	}
	if err := health.PingMySQL(context.Background()); err == nil {
		t.Fatal("PingMySQL() must report a closed database")
	}
}

func TestRuntimeHealthCheckerPreservesDisabledRedisState(t *testing.T) {
	health := newRuntimeHealthChecker(nil, cache.StateDisabled, nil)
	if got := health.RedisState(context.Background()); got != "disabled" {
		t.Fatalf("RedisState() = %q, want disabled", got)
	}
}
