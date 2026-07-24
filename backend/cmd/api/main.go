package main

import (
	"context"
	"errors"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"syscall"
	"time"

	"CBizDocsManager/backend/internal/identity"
	"CBizDocsManager/backend/internal/infrastructure/cache"
	"CBizDocsManager/backend/internal/infrastructure/database"
	"CBizDocsManager/backend/internal/infrastructure/httpserver"
	"CBizDocsManager/backend/internal/organization"
	"CBizDocsManager/backend/internal/platform"
	"CBizDocsManager/backend/migrations"
	"CBizDocsManager/backend/pkg/config"
	jwtmanager "CBizDocsManager/backend/pkg/jwt"
	applogger "CBizDocsManager/backend/pkg/logger"
	"go.uber.org/zap"
)

const (
	defaultConfigPath = "config/config.yaml"
	startupTimeout    = 30 * time.Second
	shutdownTimeout   = 10 * time.Second
)

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	configPath := strings.TrimSpace(os.Getenv("CONFIG_PATH"))
	if configPath == "" {
		configPath = defaultConfigPath
	}
	if err := run(ctx, configPath); err != nil {
		log.Printf("CBizDocsManager API 启动失败: %v", err)
		os.Exit(1)
	}
}

func run(ctx context.Context, configPath string) error {
	cfg, err := config.Load(configPath)
	if err != nil {
		return fmt.Errorf("加载配置: %w", err)
	}

	logger, err := applogger.New(cfg.App.Env, cfg.App.LogLevel)
	if err != nil {
		return err
	}
	defer func() { _ = logger.Sync() }()

	startupCtx, cancelStartup := context.WithTimeout(ctx, startupTimeout)
	defer cancelStartup()
	db, err := database.OpenMySQL(startupCtx, cfg.MySQL)
	if err != nil {
		return err
	}
	sqlDB, err := db.DB()
	if err != nil {
		return fmt.Errorf("获取 MySQL 连接池: %w", err)
	}
	defer func() { _ = sqlDB.Close() }()
	if err := database.Migrate(startupCtx, sqlDB, migrations.Files); err != nil {
		return fmt.Errorf("执行数据库迁移: %w", err)
	}

	redisClient, redisState := cache.Open(startupCtx, cfg.Redis, logger)
	if redisClient != nil {
		defer func() { _ = redisClient.Close() }()
	}

	tokens, err := jwtmanager.NewManager(cfg.JWT.Secret, cfg.JWT.Issuer, cfg.JWT.AccessTTL)
	if err != nil {
		return fmt.Errorf("初始化 JWT: %w", err)
	}
	passwords := identity.NewPasswordManager()
	identityService := identity.NewService(identity.NewRepository(db), passwords, tokens, cfg.JWT.AccessTTL, cfg.JWT.RefreshTTL)
	platformService := platform.NewService(platform.NewRepository(db), passwords)
	organizationService := organization.NewService(organization.NewRepository(db), passwords)

	created, err := identityService.BootstrapPlatformAdmin(startupCtx, cfg.Bootstrap.AdminUsername, cfg.Bootstrap.AdminPassword)
	if err != nil {
		return fmt.Errorf("初始化平台管理员: %w", err)
	}
	if !strings.EqualFold(strings.TrimSpace(cfg.App.Env), "production") &&
		cfg.Bootstrap.AdminUsername == "admin" && cfg.Bootstrap.AdminPassword == "123456" {
		logger.Warn("检测到开发环境默认管理员凭据，仅允许用于本地开发")
	}
	if created {
		logger.Info("平台管理员已完成幂等初始化", zap.String("username", cfg.Bootstrap.AdminUsername))
	}

	identityHandler := identity.NewHandler(identityService)
	platformHandler := platform.NewHandler(platformService)
	organizationHandler := organization.NewHandler(organizationService)
	router := httpserver.NewRouter(httpserver.RouterDependencies{
		Logger:        logger,
		CORS:          cfg.CORS,
		Authenticator: identityService,
		Health:        httpserver.NewRuntimeHealthChecker(sqlDB, redisClient, redisState),
		Routes: httpserver.RouteHandlers{
			Login: identityHandler.Login, Register: organizationHandler.Register,
			Refresh: identityHandler.Refresh, Logout: identityHandler.Logout,
			Me: identityHandler.Me, ChangePassword: identityHandler.ChangePassword,
			CreateGroup: platformHandler.CreateGroup, CreateInvitation: organizationHandler.CreateInvitation,
		},
	})

	server := &http.Server{
		Addr:         net.JoinHostPort(cfg.HTTP.Host, strconv.Itoa(cfg.HTTP.Port)),
		Handler:      router,
		ReadTimeout:  cfg.HTTP.ReadTimeout,
		WriteTimeout: cfg.HTTP.WriteTimeout,
		IdleTimeout:  cfg.HTTP.IdleTimeout,
	}
	serverErrors := make(chan error, 1)
	go func() {
		logger.Info("HTTP 服务开始监听", zap.String("address", server.Addr), zap.String("redis", string(redisState)))
		serverErrors <- server.ListenAndServe()
	}()

	select {
	case serverErr := <-serverErrors:
		if errors.Is(serverErr, http.ErrServerClosed) {
			return nil
		}
		return fmt.Errorf("HTTP 服务监听失败: %w", serverErr)
	case <-ctx.Done():
	}

	shutdownCtx, cancelShutdown := context.WithTimeout(context.Background(), shutdownTimeout)
	defer cancelShutdown()
	if err := server.Shutdown(shutdownCtx); err != nil {
		return fmt.Errorf("HTTP 服务优雅关闭: %w", err)
	}
	logger.Info("HTTP 服务已关闭")
	return nil
}
