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

	"CBizDocsManager/backend/internal/authorization"
	"CBizDocsManager/backend/internal/dictionary"
	"CBizDocsManager/backend/internal/document"
	"CBizDocsManager/backend/internal/finance"
	"CBizDocsManager/backend/internal/identity"
	"CBizDocsManager/backend/internal/infrastructure/cache"
	"CBizDocsManager/backend/internal/infrastructure/cryptography"
	"CBizDocsManager/backend/internal/infrastructure/database"
	"CBizDocsManager/backend/internal/infrastructure/httpserver"
	"CBizDocsManager/backend/internal/member"
	"CBizDocsManager/backend/internal/organization"
	"CBizDocsManager/backend/internal/platform"
	"CBizDocsManager/backend/internal/reporting"
	"CBizDocsManager/backend/internal/settlement"
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
	// 邀请码明文只在「签发」和「查看」两次响应里出现，其余时间以 AES-GCM 密文落库。
	// 密钥缺失或长度不对属于配置错误，直接拒绝启动，而不是静默降级成不加密存储。
	invitationKey, err := config.DecodeInvitationEncryptionKey(cfg.Invitation.EncryptionKey)
	if err != nil {
		return fmt.Errorf("解析邀请码加密密钥: %w", err)
	}
	invitationCipher, err := cryptography.NewInvitationCipher(invitationKey)
	if err != nil {
		return fmt.Errorf("初始化邀请码加密器: %w", err)
	}
	identityRepo := identity.NewRepository(db)
	identityService := identity.NewService(identityRepo, passwords, tokens, cfg.JWT.AccessTTL, cfg.JWT.RefreshTTL)
	platformService := platform.NewService(platform.NewRepository(db), passwords)
	organizationService := organization.NewService(organization.NewRepository(db), passwords, invitationCipher)
	authorizer := authorization.NewAuthorizer(authorization.NewRepository(db))
	memberService := member.NewService(member.NewRepository(db), authorizer)
	dictionaryService := dictionary.NewService(dictionary.NewRepository(db), authorizer)
	documentService := document.NewService(document.NewRepository(db), authorizer)
	settlementService := settlement.NewService(settlement.NewRepository(db), authorizer)
	financeService := finance.NewService(finance.NewRepository(db), authorizer)
	reportingService := reporting.NewService(reporting.NewRepository(db), authorizer)

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
	webIdentityHandler := identity.NewWebHandler(identityService, cfg.WebAuth)
	platformHandler := platform.NewHandler(platformService)
	organizationHandler := organization.NewHandler(organizationService)
	memberHandler := member.NewHandler(memberService)
	dictionaryHandler := dictionary.NewHandler(dictionaryService)
	// 入库与出库共用同一套单据服务，只在构造 Handler 时区分 kind。
	inboundHandler := document.NewHandler(documentService, document.KindInbound)
	outboundHandler := document.NewHandler(documentService, document.KindOutbound)
	settlementHandler := settlement.NewHandler(settlementService)
	// 付款 / 收款 / 开票共用同一个财务服务，只在构造 Handler 时区分 kind。
	// kind 固化在路由上，客户端无法通过请求体篡改记录类型。
	paymentHandler := finance.NewHandler(financeService, finance.KindPayment)
	receiptHandler := finance.NewHandler(financeService, finance.KindReceipt)
	invoiceHandler := finance.NewHandler(financeService, finance.KindInvoice)
	// 汇总统计只有一个 Handler：看板、统计表与总结算快照共用一套权限规则，不需要按类型分叉。
	reportHandler := reporting.NewHandler(reportingService)
	router := httpserver.NewRouter(httpserver.RouterDependencies{
		Logger:        logger,
		CORS:          cfg.CORS,
		WebAuth:       cfg.WebAuth,
		Authenticator: identityService,
		Health:        httpserver.NewRuntimeHealthChecker(sqlDB, redisClient, redisState),
		Routes: httpserver.RouteHandlers{
			Login: identityHandler.Login, Register: organizationHandler.Register,
			Refresh: identityHandler.Refresh, Logout: identityHandler.Logout,
			Me: identityHandler.Me, ChangePassword: identityHandler.ChangePassword,
			CreateGroup: platformHandler.CreateGroup, CreateInvitation: organizationHandler.CreateInvitation,
			ListGroups: platformHandler.ListGroups, GetGroup: platformHandler.GetGroup,
			ChangeGroupStatus: platformHandler.ChangeGroupStatus, ChangeGroupOwner: platformHandler.ChangeGroupOwner,
			ListInvitations: organizationHandler.ListInvitations, RevealInvitation: organizationHandler.RevealInvitation,
			RevokeInvitation: organizationHandler.RevokeInvitation,
			WebLogin:         webIdentityHandler.Login, WebRefresh: webIdentityHandler.Refresh, WebLogout: webIdentityHandler.Logout,
			ListMembers: memberHandler.List, ChangeMemberStatus: memberHandler.ChangeStatus,
			GetMemberPermissions: memberHandler.GetPermissions, ReplaceMemberPermissions: memberHandler.ReplacePermissions,
			PermissionCatalog: memberHandler.PermissionCatalog,
			ListDictionaries:  dictionaryHandler.List, CreateDictionary: dictionaryHandler.Create,
			UpdateDictionary: dictionaryHandler.Update, ChangeDictionaryStatus: dictionaryHandler.ChangeStatus,
			InboundDocuments: httpserver.DocumentRouteSet{
				Create: inboundHandler.Create, List: inboundHandler.List, Get: inboundHandler.Get,
				Update: inboundHandler.Update, Submit: inboundHandler.Submit, Void: inboundHandler.Void,
				MonthlySummary: inboundHandler.MonthlySummary,
			},
			OutboundDocuments: httpserver.DocumentRouteSet{
				Create: outboundHandler.Create, List: outboundHandler.List, Get: outboundHandler.Get,
				Update: outboundHandler.Update, Submit: outboundHandler.Submit, Void: outboundHandler.Void,
				MonthlySummary: outboundHandler.MonthlySummary,
			},
			Settlements: httpserver.SettlementRouteSet{
				Create: settlementHandler.Create, List: settlementHandler.List, Get: settlementHandler.Get,
				Approve: settlementHandler.Approve, Reject: settlementHandler.Reject,
			},
			Payments: httpserver.FinanceRouteSet{
				Create: paymentHandler.Create, List: paymentHandler.List, Revoke: paymentHandler.Revoke,
			},
			Receipts: httpserver.FinanceRouteSet{
				Create: receiptHandler.Create, List: receiptHandler.List, Revoke: receiptHandler.Revoke,
			},
			Invoices: httpserver.FinanceRouteSet{
				Create: invoiceHandler.Create, List: invoiceHandler.List, Revoke: invoiceHandler.Revoke,
			},
			FinanceStatement: paymentHandler.Statement,
			Reports: httpserver.ReportRouteSet{
				Overview: reportHandler.Overview, InboundStats: reportHandler.InboundStats,
				OutboundStats: reportHandler.OutboundStats, BusinessUsers: reportHandler.BusinessUsers,
				CreateSnapshot: reportHandler.CreateSnapshots, ListSnapshots: reportHandler.ListSnapshots,
				GetSnapshot: reportHandler.GetSnapshot,
			},
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
