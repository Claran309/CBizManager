//go:build integration

package identity

import (
	"context"
	"database/sql"
	"fmt"
	"os"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	mysqldriver "github.com/go-sql-driver/mysql"
	gormmysql "gorm.io/driver/mysql"
	"gorm.io/gorm"
	"gorm.io/gorm/logger"

	"CBizDocsManager/backend/internal/infrastructure/database"
	"CBizDocsManager/backend/migrations"
)

var identityMySQLDatabaseSequence atomic.Uint64

func TestMySQLRepositoryConcurrentBootstrapIsIdempotent(t *testing.T) {
	firstDB, secondDB := openIdentityMySQLIntegrationDatabase(t)
	barrierReady := registerBootstrapCreateBarrier(t, firstDB, secondDB)

	now := time.Date(2026, 7, 24, 13, 0, 0, 0, time.UTC)
	results := make(chan bootstrapResult, 2)
	admins := []*User{
		{Username: "concurrent-admin-one", PasswordHash: "hash-one", DisplayName: "Admin One"},
		{Username: "concurrent-admin-two", PasswordHash: "hash-two", DisplayName: "Admin Two"},
	}
	for index, db := range []*gorm.DB{firstDB, secondDB} {
		go func(repo Repository, admin *User) {
			created, err := repo.BootstrapPlatformAdmin(context.Background(), admin, now)
			results <- bootstrapResult{created: created, err: err}
		}(NewRepository(db), admins[index])
	}
	select {
	case err := <-barrierReady:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(6 * time.Second):
		t.Fatal("bootstrap create barrier did not report readiness")
	}

	createdCount := 0
	for range 2 {
		select {
		case result := <-results:
			if result.err != nil {
				t.Errorf("concurrent BootstrapPlatformAdmin() error = %v", result.err)
			}
			if result.created {
				createdCount++
			}
		case <-time.After(10 * time.Second):
			t.Fatal("concurrent BootstrapPlatformAdmin() timed out")
		}
	}
	if createdCount != 1 {
		t.Fatalf("created bootstrap count = %d, want 1", createdCount)
	}

	var adminCount int64
	if err := firstDB.Model(&User{}).Where("account_type = ?", AccountTypePlatformAdmin).Count(&adminCount).Error; err != nil {
		t.Fatalf("count platform admins: %v", err)
	}
	if adminCount != 1 {
		t.Fatalf("platform admin count = %d, want 1", adminCount)
	}
}

type bootstrapResult struct {
	created bool
	err     error
}

func registerBootstrapCreateBarrier(t *testing.T, databases ...*gorm.DB) <-chan error {
	t.Helper()
	arrived := make(chan struct{}, len(databases))
	release := make(chan struct{})
	ready := make(chan error, 1)
	var releaseOnce sync.Once
	for index, db := range databases {
		name := fmt.Sprintf("test:bootstrap-create-barrier-%d", index)
		if err := db.Callback().Create().Before("gorm:create").Register(name, func(tx *gorm.DB) {
			user, ok := tx.Statement.Dest.(*User)
			if !ok || user.AccountType != AccountTypePlatformAdmin {
				return
			}
			arrived <- struct{}{}
			<-release
		}); err != nil {
			t.Fatalf("register bootstrap create barrier: %v", err)
		}
		currentDB := db
		currentName := name
		t.Cleanup(func() { currentDB.Callback().Create().Remove(currentName) })
	}

	go func() {
		for range databases {
			select {
			case <-arrived:
			case <-time.After(5 * time.Second):
				ready <- fmt.Errorf("bootstrap create barrier timed out before all %d transactions arrived", len(databases))
				releaseOnce.Do(func() { close(release) })
				return
			}
		}
		ready <- nil
		releaseOnce.Do(func() { close(release) })
	}()
	return ready
}

func openIdentityMySQLIntegrationDatabase(t *testing.T) (*gorm.DB, *gorm.DB) {
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

	databaseName := fmt.Sprintf("cbizdocsmanager_test_identity_%d_%d", time.Now().UnixNano(), identityMySQLDatabaseSequence.Add(1))
	if !strings.HasPrefix(databaseName, "cbizdocsmanager_test_") {
		t.Fatalf("unsafe integration database name %q", databaseName)
	}
	if _, err := adminDB.Exec("CREATE DATABASE `" + databaseName + "` CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci"); err != nil {
		t.Fatalf("create identity integration database: %v", err)
	}
	t.Cleanup(func() {
		if !strings.HasPrefix(databaseName, "cbizdocsmanager_test_") {
			t.Errorf("refusing to drop unsafe integration database %q", databaseName)
			return
		}
		if _, err := adminDB.Exec("DROP DATABASE IF EXISTS `" + databaseName + "`"); err != nil {
			t.Errorf("drop identity integration database %s: %v", databaseName, err)
		}
	})

	databaseCfg := cfg.Clone()
	databaseCfg.DBName = databaseName
	firstDB := openIdentityMySQLGORM(t, databaseCfg)
	sqlDB, err := firstDB.DB()
	if err != nil {
		t.Fatalf("access first MySQL pool: %v", err)
	}
	if err := database.Migrate(context.Background(), sqlDB, migrations.Files); err != nil {
		t.Fatalf("migrate identity integration database: %v", err)
	}
	secondDB := openIdentityMySQLGORM(t, databaseCfg)
	return firstDB, secondDB
}

func openIdentityMySQLGORM(t *testing.T, cfg *mysqldriver.Config) *gorm.DB {
	t.Helper()
	db, err := gorm.Open(gormmysql.Open(cfg.FormatDSN()), &gorm.Config{TranslateError: true, Logger: logger.Default.LogMode(logger.Silent)})
	if err != nil {
		t.Fatalf("open MySQL GORM connection: %v", err)
	}
	sqlDB, err := db.DB()
	if err != nil {
		t.Fatalf("access MySQL GORM pool: %v", err)
	}
	sqlDB.SetMaxOpenConns(2)
	t.Cleanup(func() { _ = sqlDB.Close() })
	return db
}
