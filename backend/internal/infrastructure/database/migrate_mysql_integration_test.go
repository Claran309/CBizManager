//go:build integration

package database

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"os"
	"strings"
	"sync/atomic"
	"testing"
	"testing/fstest"
	"time"

	mysqldriver "github.com/go-sql-driver/mysql"

	"CBizDocsManager/backend/migrations"
)

var mysqlIntegrationDatabaseSequence atomic.Uint64

func TestMySQLMigrationSerializesIndependentConnectionPools(t *testing.T) {
	firstDB, secondDB := openMySQLIntegrationDatabase(t)
	migrationFS := &blockingMigrationFS{
		FS: fstest.MapFS{
			"000001_lock_probe.up.sql": &fstest.MapFile{Data: []byte(`
				CREATE TABLE migration_lock_probe (id BIGINT NOT NULL PRIMARY KEY, name VARCHAR(32) NOT NULL);
				INSERT INTO migration_lock_probe(id, name) VALUES (1, 'once');
			`)},
		},
		entered: make(chan struct{}),
		release: make(chan struct{}),
	}

	firstResult := make(chan error, 1)
	go func() { firstResult <- Migrate(context.Background(), firstDB, migrationFS) }()
	select {
	case <-migrationFS.entered:
	case <-time.After(5 * time.Second):
		t.Fatal("first MySQL migration did not reach blocked SQL read")
	}

	secondResult := make(chan error, 1)
	go func() { secondResult <- Migrate(context.Background(), secondDB, migrationFS) }()
	time.Sleep(100 * time.Millisecond)
	close(migrationFS.release)

	if err := <-firstResult; err != nil {
		t.Errorf("first Migrate() error = %v", err)
	}
	if err := <-secondResult; err != nil {
		t.Errorf("second Migrate() error = %v", err)
	}

	var count int
	if err := firstDB.QueryRow(`SELECT COUNT(*) FROM migration_lock_probe`).Scan(&count); err != nil {
		t.Fatalf("count migration lock probe rows: %v", err)
	}
	if count != 1 {
		t.Fatalf("migration lock probe row count = %d, want 1", count)
	}
	var lockIsFree sql.NullInt64
	if err := firstDB.QueryRow(`SELECT IS_FREE_LOCK(?)`, mysqlMigrationLockName).Scan(&lockIsFree); err != nil {
		t.Fatalf("check migration lock release: %v", err)
	}
	if !lockIsFree.Valid || lockIsFree.Int64 != 1 {
		t.Fatalf("migration lock free state = %+v, want 1", lockIsFree)
	}
}

func TestMySQLMigrationLeavesDirtyMarkerAfterDDLFailure(t *testing.T) {
	db, _ := openMySQLIntegrationDatabase(t)
	broken := &fstest.MapFile{Data: []byte(`
		CREATE TABLE mysql_dirty_probe (id BIGINT NOT NULL PRIMARY KEY);
		INSERT INTO missing_mysql_table(id) VALUES (1);
	`)}
	migrationFS := fstest.MapFS{"000001_dirty_probe.up.sql": broken}

	err := Migrate(context.Background(), db, migrationFS)
	if err == nil || !strings.Contains(err.Error(), "000001_dirty_probe.up.sql") {
		t.Fatalf("Migrate() error = %v, want named migration failure", err)
	}
	var dirty bool
	if err := db.QueryRow(`SELECT dirty FROM schema_migrations WHERE version = 1`).Scan(&dirty); err != nil {
		t.Fatalf("load dirty marker: %v", err)
	}
	if !dirty {
		t.Fatal("failed MySQL DDL migration is not marked dirty")
	}

	broken.Data = []byte(`CREATE TABLE must_not_replay (id BIGINT NOT NULL PRIMARY KEY);`)
	err = Migrate(context.Background(), db, migrationFS)
	if !errors.Is(err, ErrDirtyMigration) {
		t.Fatalf("Migrate() after dirty failure error = %v, want ErrDirtyMigration", err)
	}
	var replayed int
	if err := db.QueryRow(`SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = DATABASE() AND table_name = 'must_not_replay'`).Scan(&replayed); err != nil {
		t.Fatalf("check dirty migration replay: %v", err)
	}
	if replayed != 0 {
		t.Fatal("dirty MySQL migration was replayed")
	}
}

func TestMySQLMigrationEnforcesSinglePlatformAdmin(t *testing.T) {
	db, _ := openMySQLIntegrationDatabase(t)
	if err := Migrate(context.Background(), db, migrations.Files); err != nil {
		t.Fatalf("Migrate(auth) error = %v", err)
	}
	insertUser := func(username string) error {
		_, err := db.Exec(`
			INSERT INTO users(username, password_hash, display_name, account_type, status, must_change_password)
			VALUES (?, ?, ?, 'platform_admin', 'active', FALSE)
		`, username, "hash", username)
		return err
	}
	if err := insertUser("admin-one"); err != nil {
		t.Fatalf("insert first platform admin: %v", err)
	}
	if err := insertUser("admin-two"); err == nil {
		t.Fatal("insert second platform admin error = nil, want unique constraint failure")
	}
	var count int
	if err := db.QueryRow(`SELECT COUNT(*) FROM users WHERE account_type = 'platform_admin'`).Scan(&count); err != nil {
		t.Fatalf("count platform admins: %v", err)
	}
	if count != 1 {
		t.Fatalf("platform admin count = %d, want 1", count)
	}
}

func openMySQLIntegrationDatabase(t *testing.T) (*sql.DB, *sql.DB) {
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

	databaseName := fmt.Sprintf("cbizdocsmanager_test_%d_%d", time.Now().UnixNano(), mysqlIntegrationDatabaseSequence.Add(1))
	if !strings.HasPrefix(databaseName, "cbizdocsmanager_test_") {
		t.Fatalf("unsafe integration database name %q", databaseName)
	}
	if _, err := adminDB.Exec("CREATE DATABASE `" + databaseName + "` CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci"); err != nil {
		t.Fatalf("create integration database: %v", err)
	}
	t.Cleanup(func() {
		if !strings.HasPrefix(databaseName, "cbizdocsmanager_test_") {
			t.Errorf("refusing to drop unsafe integration database %q", databaseName)
			return
		}
		if _, err := adminDB.Exec("DROP DATABASE IF EXISTS `" + databaseName + "`"); err != nil {
			t.Errorf("drop integration database %s: %v", databaseName, err)
		}
	})

	databaseCfg := cfg.Clone()
	databaseCfg.DBName = databaseName
	firstDB := openMySQLIntegrationPool(t, databaseCfg)
	secondDB := openMySQLIntegrationPool(t, databaseCfg)
	return firstDB, secondDB
}

func openMySQLIntegrationPool(t *testing.T, cfg *mysqldriver.Config) *sql.DB {
	t.Helper()
	db, err := sql.Open("mysql", cfg.FormatDSN())
	if err != nil {
		t.Fatalf("open MySQL integration connection: %v", err)
	}
	db.SetMaxOpenConns(4)
	t.Cleanup(func() { _ = db.Close() })
	if err := db.Ping(); err != nil {
		t.Fatalf("ping MySQL integration connection: %v", err)
	}
	return db
}
