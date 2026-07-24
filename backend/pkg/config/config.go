package config

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/joho/godotenv"
	"github.com/spf13/viper"
)

const defaultDevelopmentJWTSecret = "development-only-change-me"

var (
	ErrUnsafeProductionJWTSecret         = errors.New("production 环境 JWT 密钥至少 32 字节且不得使用开发默认值")
	ErrBootstrapAdminUsernameRequired    = errors.New("production 环境必须显式配置 bootstrap 管理员用户名")
	ErrBootstrapAdminPasswordRequired    = errors.New("production 环境必须显式配置 bootstrap 管理员密码")
	ErrUnsafeProductionBootstrapPassword = errors.New("production 环境 bootstrap 管理员密码至少 12 字节且不得使用开发默认值")
)

// Config 汇总服务启动所需的全部基础配置。
type Config struct {
	App       AppConfig       `mapstructure:"app"`
	HTTP      HTTPConfig      `mapstructure:"http"`
	MySQL     MySQLConfig     `mapstructure:"mysql"`
	Redis     RedisConfig     `mapstructure:"redis"`
	JWT       JWTConfig       `mapstructure:"jwt"`
	CORS      CORSConfig      `mapstructure:"cors"`
	Bootstrap BootstrapConfig `mapstructure:"bootstrap"`
}

type AppConfig struct {
	Name     string `mapstructure:"name"`
	Env      string `mapstructure:"env"`
	LogLevel string `mapstructure:"log_level"`
}

type HTTPConfig struct {
	Host         string        `mapstructure:"host"`
	Port         int           `mapstructure:"port"`
	ReadTimeout  time.Duration `mapstructure:"read_timeout"`
	WriteTimeout time.Duration `mapstructure:"write_timeout"`
	IdleTimeout  time.Duration `mapstructure:"idle_timeout"`
}

type MySQLConfig struct {
	DSN             string        `mapstructure:"dsn"`
	MaxOpenConns    int           `mapstructure:"max_open_conns"`
	MaxIdleConns    int           `mapstructure:"max_idle_conns"`
	ConnMaxLifetime time.Duration `mapstructure:"conn_max_lifetime"`
}

type RedisConfig struct {
	Addr         string        `mapstructure:"addr"`
	Password     string        `mapstructure:"password"`
	DB           int           `mapstructure:"db"`
	DialTimeout  time.Duration `mapstructure:"dial_timeout"`
	ReadTimeout  time.Duration `mapstructure:"read_timeout"`
	WriteTimeout time.Duration `mapstructure:"write_timeout"`
}

type JWTConfig struct {
	Secret     string        `mapstructure:"secret"`
	Issuer     string        `mapstructure:"issuer"`
	AccessTTL  time.Duration `mapstructure:"access_ttl"`
	RefreshTTL time.Duration `mapstructure:"refresh_ttl"`
}

type CORSConfig struct {
	AllowedOrigins   []string      `mapstructure:"allowed_origins"`
	AllowedMethods   []string      `mapstructure:"allowed_methods"`
	AllowedHeaders   []string      `mapstructure:"allowed_headers"`
	AllowCredentials bool          `mapstructure:"allow_credentials"`
	MaxAge           time.Duration `mapstructure:"max_age"`
}

type BootstrapConfig struct {
	AdminUsername string `mapstructure:"admin_username"`
	AdminPassword string `mapstructure:"admin_password"`
}

// Load 按“默认值 < YAML < .env/进程环境变量”的顺序加载配置。
func Load(path string) (*Config, error) {
	if err := loadDotEnv(path); err != nil {
		return nil, err
	}

	v := viper.New()
	setDefaults(v)
	bindEnvironment(v)

	if path != "" {
		v.SetConfigFile(path)
		if err := v.ReadInConfig(); err != nil {
			return nil, fmt.Errorf("读取配置文件 %q: %w", path, err)
		}
	}

	var cfg Config
	if err := v.Unmarshal(&cfg); err != nil {
		return nil, fmt.Errorf("解析服务配置: %w", err)
	}
	if err := validateProductionSecurity(v, &cfg); err != nil {
		return nil, err
	}
	return &cfg, nil
}

func loadDotEnv(configPath string) error {
	paths := []string{".env"}
	if configPath != "" {
		configDotEnv := filepath.Join(filepath.Dir(configPath), ".env")
		if filepath.Clean(configDotEnv) != filepath.Clean(paths[0]) {
			paths = append(paths, configDotEnv)
		}
	}
	for _, dotEnvPath := range paths {
		if err := godotenv.Load(dotEnvPath); err != nil && !errors.Is(err, os.ErrNotExist) {
			return fmt.Errorf("读取环境文件 %q: %w", dotEnvPath, err)
		}
	}
	return nil
}

func setDefaults(v *viper.Viper) {
	v.SetDefault("app.name", "CBizDocsManager")
	v.SetDefault("app.env", "development")
	v.SetDefault("app.log_level", "info")

	v.SetDefault("http.host", "0.0.0.0")
	v.SetDefault("http.port", 8080)
	v.SetDefault("http.read_timeout", 10*time.Second)
	v.SetDefault("http.write_timeout", 30*time.Second)
	v.SetDefault("http.idle_timeout", 60*time.Second)

	v.SetDefault("mysql.dsn", "")
	v.SetDefault("mysql.max_open_conns", 20)
	v.SetDefault("mysql.max_idle_conns", 10)
	v.SetDefault("mysql.conn_max_lifetime", 30*time.Minute)

	v.SetDefault("redis.addr", "127.0.0.1:6379")
	v.SetDefault("redis.password", "")
	v.SetDefault("redis.db", 0)
	v.SetDefault("redis.dial_timeout", 3*time.Second)
	v.SetDefault("redis.read_timeout", 3*time.Second)
	v.SetDefault("redis.write_timeout", 3*time.Second)

	v.SetDefault("jwt.secret", defaultDevelopmentJWTSecret)
	v.SetDefault("jwt.issuer", "cbizdocsmanager")
	v.SetDefault("jwt.access_ttl", 30*time.Minute)
	v.SetDefault("jwt.refresh_ttl", 7*24*time.Hour)

	v.SetDefault("cors.allowed_origins", []string{"*"})
	v.SetDefault("cors.allowed_methods", []string{"GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"})
	v.SetDefault("cors.allowed_headers", []string{"Authorization", "Content-Type", "X-Request-ID"})
	v.SetDefault("cors.allow_credentials", false)
	v.SetDefault("cors.max_age", 12*time.Hour)

	v.SetDefault("bootstrap.admin_username", "admin")
	v.SetDefault("bootstrap.admin_password", "123456")
}

func bindEnvironment(v *viper.Viper) {
	v.SetEnvKeyReplacer(strings.NewReplacer(".", "_"))
	v.AutomaticEnv()

	bindings := map[string][]string{
		"app.name":                 {"APP_NAME"},
		"app.env":                  {"APP_ENV"},
		"app.log_level":            {"LOG_LEVEL", "APP_LOG_LEVEL"},
		"http.host":                {"HTTP_HOST"},
		"http.port":                {"HTTP_PORT"},
		"http.read_timeout":        {"HTTP_READ_TIMEOUT"},
		"http.write_timeout":       {"HTTP_WRITE_TIMEOUT"},
		"http.idle_timeout":        {"HTTP_IDLE_TIMEOUT"},
		"mysql.dsn":                {"MYSQL_DSN"},
		"mysql.max_open_conns":     {"MYSQL_MAX_OPEN_CONNS"},
		"mysql.max_idle_conns":     {"MYSQL_MAX_IDLE_CONNS"},
		"mysql.conn_max_lifetime":  {"MYSQL_CONN_MAX_LIFETIME"},
		"redis.addr":               {"REDIS_ADDR"},
		"redis.password":           {"REDIS_PASSWORD"},
		"redis.db":                 {"REDIS_DB"},
		"redis.dial_timeout":       {"REDIS_DIAL_TIMEOUT"},
		"redis.read_timeout":       {"REDIS_READ_TIMEOUT"},
		"redis.write_timeout":      {"REDIS_WRITE_TIMEOUT"},
		"jwt.secret":               {"JWT_SECRET"},
		"jwt.issuer":               {"JWT_ISSUER"},
		"jwt.access_ttl":           {"JWT_ACCESS_TTL"},
		"jwt.refresh_ttl":          {"JWT_REFRESH_TTL"},
		"cors.allowed_origins":     {"CORS_ALLOWED_ORIGINS"},
		"cors.allowed_methods":     {"CORS_ALLOWED_METHODS"},
		"cors.allowed_headers":     {"CORS_ALLOWED_HEADERS"},
		"cors.allow_credentials":   {"CORS_ALLOW_CREDENTIALS"},
		"cors.max_age":             {"CORS_MAX_AGE"},
		"bootstrap.admin_username": {"BOOTSTRAP_ADMIN_USERNAME"},
		"bootstrap.admin_password": {"BOOTSTRAP_ADMIN_PASSWORD"},
	}
	for key, envNames := range bindings {
		args := append([]string{key}, envNames...)
		_ = v.BindEnv(args...)
	}
}

func validateProductionSecurity(v *viper.Viper, cfg *Config) error {
	if !strings.EqualFold(strings.TrimSpace(cfg.App.Env), "production") {
		return nil
	}

	secret := strings.TrimSpace(cfg.JWT.Secret)
	if secret == defaultDevelopmentJWTSecret || len(secret) < 32 {
		return ErrUnsafeProductionJWTSecret
	}
	if !isExplicitNonEmpty(v, "bootstrap.admin_username", "BOOTSTRAP_ADMIN_USERNAME") {
		return ErrBootstrapAdminUsernameRequired
	}
	if !isExplicitNonEmpty(v, "bootstrap.admin_password", "BOOTSTRAP_ADMIN_PASSWORD") {
		return ErrBootstrapAdminPasswordRequired
	}
	password := strings.TrimSpace(cfg.Bootstrap.AdminPassword)
	if password == "123456" || len(password) < 12 {
		return ErrUnsafeProductionBootstrapPassword
	}
	return nil
}

func isExplicitNonEmpty(v *viper.Viper, key, envName string) bool {
	if value, ok := os.LookupEnv(envName); ok && strings.TrimSpace(value) != "" {
		return true
	}
	return v.InConfig(key) && strings.TrimSpace(v.GetString(key)) != ""
}
