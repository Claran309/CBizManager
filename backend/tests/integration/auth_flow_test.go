//go:build integration

package integration

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"os"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"CBizDocsManager/backend/internal/identity"
	"CBizDocsManager/backend/internal/infrastructure/database"
	"CBizDocsManager/backend/internal/organization"
	"CBizDocsManager/backend/internal/platform"
	"CBizDocsManager/backend/migrations"
	"CBizDocsManager/backend/pkg/apperror"
	jwtmanager "CBizDocsManager/backend/pkg/jwt"
	mysqldriver "github.com/go-sql-driver/mysql"
	gormmysql "gorm.io/driver/mysql"
	"gorm.io/gorm"
	"gorm.io/gorm/logger"
)

var authFlowDatabaseSequence atomic.Uint64

func TestAuthenticationAndOrganizationFlow(t *testing.T) {
	db := openAuthFlowMySQL(t)
	identityRepo := identity.NewRepository(db)
	organizationRepo := organization.NewRepository(db)
	platformRepo := platform.NewRepository(db)
	passwords := identity.NewPasswordManager()
	tokens, err := jwtmanager.NewManager("integration-secret-at-least-32-bytes", "integration", 15*time.Minute)
	if err != nil {
		t.Fatalf("NewManager() error = %v", err)
	}
	identityService := identity.NewService(identityRepo, passwords, tokens, 15*time.Minute, 7*24*time.Hour)
	platformService := platform.NewService(platformRepo, passwords)
	organizationService := organization.NewService(organizationRepo, passwords)
	ctx := context.Background()

	created, err := identityService.BootstrapPlatformAdmin(ctx, "admin", "temporary-admin-password")
	if err != nil || !created {
		t.Fatalf("BootstrapPlatformAdmin(first)=(%v,%v)", created, err)
	}
	created, err = identityService.BootstrapPlatformAdmin(ctx, "other-admin", "must-not-overwrite")
	if err != nil || created {
		t.Fatalf("BootstrapPlatformAdmin(second)=(%v,%v), want (false,nil)", created, err)
	}

	adminTokens, err := identityService.Login(ctx, identity.LoginRequest{Username: "admin", Password: "temporary-admin-password"})
	if err != nil {
		t.Fatalf("admin Login() error=%v", err)
	}
	adminPrincipal := authenticateIntegration(t, identityService, adminTokens.AccessToken)
	if !adminPrincipal.MustChangePassword {
		t.Fatal("bootstrap admin is not forced to change password")
	}
	if err := identityService.ChangePassword(ctx, *adminPrincipal, identity.ChangePasswordRequest{CurrentPassword: "temporary-admin-password", NewPassword: "permanent-admin-password"}); err != nil {
		t.Fatalf("admin ChangePassword() error=%v", err)
	}
	adminPrincipal = authenticateIntegration(t, identityService, adminTokens.AccessToken)
	if adminPrincipal.MustChangePassword {
		t.Fatal("admin still forced to change password")
	}

	groupResult, err := platformService.CreateGroup(ctx, *adminPrincipal, platform.CreateGroupRequest{
		Name: "Finance", OwnerUsername: "finance-owner", OwnerDisplayName: "Finance Owner", OwnerTemporaryPassword: "temporary-owner-password",
	})
	if err != nil {
		t.Fatalf("CreateGroup() error=%v", err)
	}
	ownerTokens, err := identityService.Login(ctx, identity.LoginRequest{Username: "finance-owner", Password: "temporary-owner-password"})
	if err != nil {
		t.Fatalf("owner Login() error=%v", err)
	}
	ownerPrincipal := authenticateIntegration(t, identityService, ownerTokens.AccessToken)
	if ownerPrincipal.GroupID == nil || *ownerPrincipal.GroupID != groupResult.Group.ID || ownerPrincipal.GroupName != "Finance" || !ownerPrincipal.MustChangePassword {
		t.Fatalf("owner principal=%+v", ownerPrincipal)
	}
	if err := identityService.ChangePassword(ctx, *ownerPrincipal, identity.ChangePasswordRequest{CurrentPassword: "temporary-owner-password", NewPassword: "permanent-owner-password"}); err != nil {
		t.Fatalf("owner ChangePassword() error=%v", err)
	}
	ownerPrincipal = authenticateIntegration(t, identityService, ownerTokens.AccessToken)

	invitation, err := organizationService.CreateInvitation(ctx, *ownerPrincipal, organization.CreateInvitationRequest{})
	if err != nil {
		t.Fatalf("CreateInvitation() error=%v", err)
	}
	registration, err := organizationService.Register(ctx, organization.RegisterRequest{
		InvitationCode: invitation.InvitationCode, Username: "member-one", Password: "member-password", DisplayName: "Member One",
	})
	if err != nil {
		t.Fatalf("Register() error=%v", err)
	}
	if registration.Group.ID != groupResult.Group.ID || registration.User.AccountType != identity.AccountTypeMember {
		t.Fatalf("registration=%+v", registration)
	}

	memberTokens, err := identityService.Login(ctx, identity.LoginRequest{Username: "member-one", Password: "member-password"})
	if err != nil {
		t.Fatalf("member Login() error=%v", err)
	}
	refreshed, err := identityService.Refresh(ctx, identity.RefreshRequest{RefreshToken: memberTokens.RefreshToken})
	if err != nil {
		t.Fatalf("Refresh() error=%v", err)
	}
	_, err = identityService.Refresh(ctx, identity.RefreshRequest{RefreshToken: memberTokens.RefreshToken})
	assertIntegrationCode(t, err, apperror.CodeAuthRefreshInvalid)
	memberPrincipal := authenticateIntegration(t, identityService, refreshed.AccessToken)
	if err := identityService.Logout(ctx, *memberPrincipal); err != nil {
		t.Fatalf("Logout() error=%v", err)
	}
	_, err = identityService.Refresh(ctx, identity.RefreshRequest{RefreshToken: refreshed.RefreshToken})
	assertIntegrationCode(t, err, apperror.CodeAuthRefreshInvalid)

	concurrentInvitation, err := organizationService.CreateInvitation(ctx, *ownerPrincipal, organization.CreateInvitationRequest{})
	if err != nil {
		t.Fatalf("CreateInvitation(concurrent) error=%v", err)
	}
	results := make(chan error, 2)
	for index := range 2 {
		go func(index int) {
			_, registerErr := organizationService.Register(ctx, organization.RegisterRequest{
				InvitationCode: concurrentInvitation.InvitationCode,
				Username:       fmt.Sprintf("concurrent-member-%d", index),
				Password:       "member-password",
				DisplayName:    "Concurrent Member",
			})
			results <- registerErr
		}(index)
	}
	successes, used := 0, 0
	for range 2 {
		registerErr := <-results
		if registerErr == nil {
			successes++
			continue
		}
		var appErr *apperror.Error
		if errors.As(registerErr, &appErr) && appErr.Code == apperror.CodeInvitationUsed {
			used++
		}
	}
	if successes != 1 || used != 1 {
		t.Fatalf("concurrent registration: success=%d used=%d", successes, used)
	}
}

func authenticateIntegration(t *testing.T, service *identity.Service, accessToken string) *identity.Principal {
	t.Helper()
	principal, err := service.Authenticate(context.Background(), accessToken)
	if err != nil {
		t.Fatalf("Authenticate() error=%v", err)
	}
	return principal
}

func assertIntegrationCode(t *testing.T, err error, code string) {
	t.Helper()
	var appErr *apperror.Error
	if !errors.As(err, &appErr) || appErr.Code != code {
		t.Fatalf("error=%v, want %s", err, code)
	}
}

func openAuthFlowMySQL(t *testing.T) *gorm.DB {
	t.Helper()
	rawDSN := os.Getenv("TEST_MYSQL_DSN")
	if rawDSN == "" {
		t.Skip("TEST_MYSQL_DSN is not set")
	}
	cfg, err := mysqldriver.ParseDSN(rawDSN)
	if err != nil {
		t.Fatalf("parse TEST_MYSQL_DSN: %v", err)
	}
	cfg.ParseTime = true
	cfg.Loc = time.UTC
	cfg.MultiStatements = true
	adminCfg := cfg.Clone()
	adminCfg.DBName = ""
	adminDB, err := sql.Open("mysql", adminCfg.FormatDSN())
	if err != nil {
		t.Fatalf("open MySQL admin connection: %v", err)
	}
	t.Cleanup(func() { _ = adminDB.Close() })
	if err := adminDB.Ping(); err != nil {
		t.Fatalf("ping MySQL admin connection: %v", err)
	}
	databaseName := fmt.Sprintf("cbizdocsmanager_test_auth_%d_%d", time.Now().UnixNano(), authFlowDatabaseSequence.Add(1))
	if !strings.HasPrefix(databaseName, "cbizdocsmanager_test_") {
		t.Fatalf("unsafe integration database name %q", databaseName)
	}
	if _, err := adminDB.Exec("CREATE DATABASE `" + databaseName + "` CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci"); err != nil {
		t.Fatalf("create auth integration database: %v", err)
	}
	t.Cleanup(func() {
		if !strings.HasPrefix(databaseName, "cbizdocsmanager_test_") {
			t.Errorf("refusing to drop unsafe database %q", databaseName)
			return
		}
		if _, err := adminDB.Exec("DROP DATABASE IF EXISTS `" + databaseName + "`"); err != nil {
			t.Errorf("drop auth integration database: %v", err)
		}
	})
	dbCfg := cfg.Clone()
	dbCfg.DBName = databaseName
	db, err := gorm.Open(gormmysql.Open(dbCfg.FormatDSN()), &gorm.Config{TranslateError: true, Logger: logger.Default.LogMode(logger.Silent)})
	if err != nil {
		t.Fatalf("open auth integration GORM: %v", err)
	}
	sqlDB, err := db.DB()
	if err != nil {
		t.Fatalf("access auth integration sql.DB: %v", err)
	}
	t.Cleanup(func() { _ = sqlDB.Close() })
	if err := database.Migrate(context.Background(), sqlDB, migrations.Files); err != nil {
		t.Fatalf("migrate auth integration database: %v", err)
	}
	return db
}
