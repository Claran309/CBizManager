package config_test

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"testing"
	"time"

	"CBizDocsManager/backend/pkg/config"
	applogger "CBizDocsManager/backend/pkg/logger"
)

const strongProductionJWTSecret = "production-jwt-secret-at-least-32-bytes"

func TestLoadReadsYAMLAndEnvironmentOverrides(t *testing.T) {
	path := writeConfig(t, `
app:
  name: from-file
  env: development
  log_level: debug
http:
  host: 127.0.0.1
  port: 8081
  read_timeout: 3s
  write_timeout: 4s
  idle_timeout: 5s
mysql:
  dsn: file-dsn
  max_open_conns: 20
  max_idle_conns: 10
  conn_max_lifetime: 45m
redis:
  addr: redis.internal:6379
  password: redis-password
  db: 2
  dial_timeout: 2s
  read_timeout: 3s
  write_timeout: 4s
jwt:
  secret: file-secret
  issuer: file-issuer
  access_ttl: 10m
  refresh_ttl: 240h
cors:
  allowed_origins:
    - https://file.example.com
  allowed_methods:
    - GET
    - POST
  allowed_headers:
    - Authorization
    - Content-Type
  allow_credentials: true
  max_age: 30m
bootstrap:
  admin_username: file-admin
  admin_password: file-password
`)
	t.Setenv("HTTP_PORT", "9090")
	t.Setenv("MYSQL_DSN", "env-dsn")
	t.Setenv("JWT_SECRET", "env-secret")
	t.Setenv("BOOTSTRAP_ADMIN_USERNAME", "env-admin")

	cfg, err := config.Load(path)
	if err != nil {
		t.Fatalf("Load() error = %v", err)
	}

	if cfg.App.Name != "from-file" || cfg.App.Env != "development" || cfg.App.LogLevel != "debug" {
		t.Fatalf("App = %#v", cfg.App)
	}
	if cfg.HTTP.Host != "127.0.0.1" || cfg.HTTP.Port != 9090 {
		t.Fatalf("HTTP = %#v", cfg.HTTP)
	}
	if cfg.HTTP.ReadTimeout != 3*time.Second || cfg.HTTP.WriteTimeout != 4*time.Second || cfg.HTTP.IdleTimeout != 5*time.Second {
		t.Fatalf("HTTP durations = %#v", cfg.HTTP)
	}
	if cfg.MySQL.DSN != "env-dsn" || cfg.MySQL.MaxOpenConns != 20 || cfg.MySQL.MaxIdleConns != 10 || cfg.MySQL.ConnMaxLifetime != 45*time.Minute {
		t.Fatalf("MySQL = %#v", cfg.MySQL)
	}
	if cfg.Redis.Addr != "redis.internal:6379" || cfg.Redis.Password != "redis-password" || cfg.Redis.DB != 2 {
		t.Fatalf("Redis = %#v", cfg.Redis)
	}
	if cfg.Redis.DialTimeout != 2*time.Second || cfg.Redis.ReadTimeout != 3*time.Second || cfg.Redis.WriteTimeout != 4*time.Second {
		t.Fatalf("Redis durations = %#v", cfg.Redis)
	}
	if cfg.JWT.Secret != "env-secret" || cfg.JWT.Issuer != "file-issuer" {
		t.Fatalf("JWT = %#v", cfg.JWT)
	}
	if cfg.JWT.AccessTTL != 10*time.Minute || cfg.JWT.RefreshTTL != 240*time.Hour {
		t.Fatalf("JWT durations = %#v", cfg.JWT)
	}
	if len(cfg.CORS.AllowedOrigins) != 1 || cfg.CORS.AllowedOrigins[0] != "https://file.example.com" {
		t.Fatalf("CORS allowed origins = %#v", cfg.CORS.AllowedOrigins)
	}
	if !cfg.CORS.AllowCredentials || cfg.CORS.MaxAge != 30*time.Minute {
		t.Fatalf("CORS = %#v", cfg.CORS)
	}
	if cfg.Bootstrap.AdminUsername != "env-admin" || cfg.Bootstrap.AdminPassword != "file-password" {
		t.Fatalf("Bootstrap = %#v", cfg.Bootstrap)
	}
}

func TestLoadReadsDotEnvBesideConfig(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "config.yaml")
	if err := os.WriteFile(path, []byte("app:\n  env: development\n"), 0o600); err != nil {
		t.Fatalf("write config: %v", err)
	}
	if err := os.WriteFile(filepath.Join(dir, ".env"), []byte("JWT_SECRET=dotenv-secret\n"), 0o600); err != nil {
		t.Fatalf("write .env: %v", err)
	}
	temporarilyUnsetEnv(t, "JWT_SECRET")

	cfg, err := config.Load(path)
	if err != nil {
		t.Fatalf("Load() error = %v", err)
	}
	if cfg.JWT.Secret != "dotenv-secret" {
		t.Fatalf("JWT.Secret = %q, want dotenv-secret", cfg.JWT.Secret)
	}
}

func TestLoadReadsDotEnvFromWorkingDirectory(t *testing.T) {
	dir := t.TempDir()
	configDir := filepath.Join(dir, "config")
	if err := os.MkdirAll(configDir, 0o755); err != nil {
		t.Fatalf("create config directory: %v", err)
	}
	path := filepath.Join(configDir, "config.yaml")
	if err := os.WriteFile(path, []byte("app:\n  env: development\n"), 0o600); err != nil {
		t.Fatalf("write config: %v", err)
	}
	if err := os.WriteFile(filepath.Join(dir, ".env"), []byte("JWT_SECRET=working-directory-secret\n"), 0o600); err != nil {
		t.Fatalf("write .env: %v", err)
	}
	temporarilyUnsetEnv(t, "JWT_SECRET")
	previousWorkingDirectory, err := os.Getwd()
	if err != nil {
		t.Fatalf("get working directory: %v", err)
	}
	if err := os.Chdir(dir); err != nil {
		t.Fatalf("change working directory: %v", err)
	}
	t.Cleanup(func() { _ = os.Chdir(previousWorkingDirectory) })

	cfg, err := config.Load(filepath.Join("config", "config.yaml"))
	if err != nil {
		t.Fatalf("Load() error = %v", err)
	}
	if cfg.JWT.Secret != "working-directory-secret" {
		t.Fatalf("JWT.Secret = %q, want working-directory-secret", cfg.JWT.Secret)
	}
}

func TestLoadDoesNotOverrideProcessEnvironmentWithDotEnv(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "config.yaml")
	if err := os.WriteFile(path, []byte("app:\n  env: development\n"), 0o600); err != nil {
		t.Fatalf("write config: %v", err)
	}
	if err := os.WriteFile(filepath.Join(dir, ".env"), []byte("JWT_SECRET=dotenv-secret\n"), 0o600); err != nil {
		t.Fatalf("write .env: %v", err)
	}
	t.Setenv("JWT_SECRET", "process-secret")

	cfg, err := config.Load(path)
	if err != nil {
		t.Fatalf("Load() error = %v", err)
	}
	if cfg.JWT.Secret != "process-secret" {
		t.Fatalf("JWT.Secret = %q, want process-secret", cfg.JWT.Secret)
	}
}

func TestLoadUsesSafeDevelopmentDefaults(t *testing.T) {
	path := writeConfig(t, "app:\n  env: development\n")
	t.Setenv("JWT_SECRET", "")
	t.Setenv("BOOTSTRAP_ADMIN_USERNAME", "")
	t.Setenv("BOOTSTRAP_ADMIN_PASSWORD", "")

	cfg, err := config.Load(path)
	if err != nil {
		t.Fatalf("Load() error = %v", err)
	}
	if cfg.JWT.Secret == "" {
		t.Fatal("development JWT secret must have a non-empty default")
	}
	if cfg.JWT.AccessTTL != 30*time.Minute {
		t.Fatalf("development JWT access TTL = %v, want %v", cfg.JWT.AccessTTL, 30*time.Minute)
	}
	if cfg.Bootstrap.AdminUsername != "admin" || cfg.Bootstrap.AdminPassword != "123456" {
		t.Fatalf("Bootstrap defaults = %#v, want admin/123456", cfg.Bootstrap)
	}
}

func TestRepositoryDevelopmentConfigLoads(t *testing.T) {
	path := filepath.Join("..", "..", "config", "config.yaml")
	cfg, err := config.Load(path)
	if err != nil {
		t.Fatalf("Load(%q) error = %v", path, err)
	}
	if cfg.App.Env != "development" {
		t.Fatalf("App.Env = %q, want development", cfg.App.Env)
	}
	if cfg.MySQL.DSN == "" {
		t.Fatal("repository development config must define mysql.dsn")
	}
	if len(cfg.CORS.AllowedOrigins) == 0 {
		t.Fatal("repository development config must define at least one CORS origin")
	}
}

func TestLoadWebAuthConfiguration(t *testing.T) {
	path := writeConfig(t, `
app:
  env: development
web_auth:
  enabled: true
  secure: false
  allowed_origins: [http://localhost:3000]
  refresh_cookie_name: cbiz_refresh
  csrf_cookie_name: cbiz_csrf
`)
	cfg, err := config.Load(path)
	if err != nil {
		t.Fatalf("Load() error=%v", err)
	}
	if !cfg.WebAuth.Enabled || cfg.WebAuth.Secure || cfg.WebAuth.AllowedOrigins[0] != "http://localhost:3000" {
		t.Fatalf("WebAuth=%+v", cfg.WebAuth)
	}
}

func TestLoadRejectsUnsafeProductionWebAuth(t *testing.T) {
	base := `
app:
  env: production
jwt:
  secret: production-jwt-secret-at-least-32-bytes
bootstrap:
  admin_username: prod-admin
  admin_password: strong-password
cors:
  allowed_origins: [https://app.example.com]
  allow_credentials: true
web_auth:
  enabled: true
  secure: %t
  allowed_origins: ["%s"]
  cookie_domain: %s
`
	tests := []struct {
		name, origin, domain string
		secure               bool
		want                 error
	}{
		{"secure required", "https://app.example.com", "example.com", false, config.ErrUnsafeProductionWebAuth},
		{"wildcard forbidden", "*", "example.com", true, config.ErrUnsafeProductionWebAuth},
		{"uncontrolled cookie domain", "https://app.example.net", "example.com", true, config.ErrUnsafeProductionWebAuth},
		{"public suffix cookie domain", "https://app.com", "com", true, config.ErrUnsafeProductionWebAuth},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			path := writeConfig(t, fmt.Sprintf(base, test.secure, test.origin, test.domain))
			_, err := config.Load(path)
			if !errors.Is(err, test.want) {
				t.Fatalf("Load() error=%v want=%v", err, test.want)
			}
		})
	}
}

func TestLoadRejectsUnsafeProductionSecurityConfig(t *testing.T) {
	tests := []struct {
		name     string
		secret   string
		username string
		password string
		wantErr  error
	}{
		{
			name:     "empty jwt secret",
			secret:   "",
			username: "prod-admin",
			password: "strong-password",
			wantErr:  config.ErrUnsafeProductionJWTSecret,
		},
		{
			name:     "default jwt secret",
			secret:   "development-only-change-me",
			username: "prod-admin",
			password: "strong-password",
			wantErr:  config.ErrUnsafeProductionJWTSecret,
		},
		{
			name:     "short jwt secret",
			secret:   "short-production-secret",
			username: "prod-admin",
			password: "strong-password",
			wantErr:  config.ErrUnsafeProductionJWTSecret,
		},
		{
			name:     "missing bootstrap username",
			secret:   strongProductionJWTSecret,
			username: "",
			password: "strong-password",
			wantErr:  config.ErrBootstrapAdminUsernameRequired,
		},
		{
			name:     "missing bootstrap password",
			secret:   strongProductionJWTSecret,
			username: "prod-admin",
			password: "",
			wantErr:  config.ErrBootstrapAdminPasswordRequired,
		},
		{
			name:     "default bootstrap password",
			secret:   strongProductionJWTSecret,
			username: "prod-admin",
			password: "123456",
			wantErr:  config.ErrUnsafeProductionBootstrapPassword,
		},
		{
			name:     "short bootstrap password",
			secret:   strongProductionJWTSecret,
			username: "prod-admin",
			password: "short-pass",
			wantErr:  config.ErrUnsafeProductionBootstrapPassword,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			path := writeConfig(t, "app:\n  env: production\n")
			t.Setenv("JWT_SECRET", tt.secret)
			t.Setenv("BOOTSTRAP_ADMIN_USERNAME", tt.username)
			t.Setenv("BOOTSTRAP_ADMIN_PASSWORD", tt.password)

			_, err := config.Load(path)
			if !errors.Is(err, tt.wantErr) {
				t.Fatalf("Load() error = %v, want %v", err, tt.wantErr)
			}
		})
	}
}

func TestLoadAcceptsExplicitProductionSecurityConfig(t *testing.T) {
	path := writeConfig(t, "app:\n  env: production\n")
	t.Setenv("JWT_SECRET", strongProductionJWTSecret)
	t.Setenv("BOOTSTRAP_ADMIN_USERNAME", "prod-admin")
	t.Setenv("BOOTSTRAP_ADMIN_PASSWORD", "strong-password")

	cfg, err := config.Load(path)
	if err != nil {
		t.Fatalf("Load() error = %v", err)
	}
	if cfg.JWT.Secret != strongProductionJWTSecret {
		t.Fatalf("JWT.Secret = %q", cfg.JWT.Secret)
	}
	if cfg.Bootstrap.AdminUsername != "prod-admin" || cfg.Bootstrap.AdminPassword != "strong-password" {
		t.Fatalf("Bootstrap = %#v", cfg.Bootstrap)
	}
}

func TestLoggerNewReturnsInjectableLogger(t *testing.T) {
	log, err := applogger.New("development", "debug")
	if err != nil {
		t.Fatalf("logger.New() error = %v", err)
	}
	if log == nil {
		t.Fatal("logger.New() must return a logger")
	}
	_ = log.Sync()
}

func TestLoggerNewRejectsInvalidLevel(t *testing.T) {
	if _, err := applogger.New("production", "not-a-level"); err == nil {
		t.Fatal("logger.New() must reject an invalid log level")
	}
}

func writeConfig(t *testing.T, content string) string {
	t.Helper()

	path := filepath.Join(t.TempDir(), "config.yaml")
	if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
		t.Fatalf("write config: %v", err)
	}
	return path
}

func temporarilyUnsetEnv(t *testing.T, key string) {
	t.Helper()

	oldValue, existed := os.LookupEnv(key)
	if err := os.Unsetenv(key); err != nil {
		t.Fatalf("unset %s: %v", key, err)
	}
	t.Cleanup(func() {
		if existed {
			_ = os.Setenv(key, oldValue)
			return
		}
		_ = os.Unsetenv(key)
	})
}
