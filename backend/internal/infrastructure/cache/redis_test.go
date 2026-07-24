package cache

import (
	"context"
	"testing"
	"time"

	"CBizDocsManager/backend/pkg/config"
	"go.uber.org/zap"
)

func TestRedisDisabledAndConnectionFailureDegradeWithoutStartupError(t *testing.T) {
	tests := []struct {
		name      string
		cfg       config.RedisConfig
		wantState State
	}{
		{name: "disabled", cfg: config.RedisConfig{}, wantState: StateDisabled},
		{
			name: "unavailable",
			cfg: config.RedisConfig{
				Addr: "127.0.0.1:1", DialTimeout: 50 * time.Millisecond,
				ReadTimeout: 50 * time.Millisecond, WriteTimeout: 50 * time.Millisecond,
			},
			wantState: StateDown,
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			client, state := Open(context.Background(), tt.cfg, zap.NewNop())
			if client != nil {
				t.Fatalf("Open() client=%v, want nil", client)
			}
			if state != tt.wantState {
				t.Fatalf("Open() state=%q, want %q", state, tt.wantState)
			}
		})
	}
}
