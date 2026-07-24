package database

import (
	"context"
	"database/sql"
	"errors"
	"io/fs"
	"strings"
	"sync"
	"testing"
	"testing/fstest"
	"time"

	"github.com/glebarez/sqlite"
	mysqldriver "github.com/go-sql-driver/mysql"
	"gorm.io/gorm"

	"CBizDocsManager/backend/migrations"
)

func TestMigrationRunsInFilenameOrderAndOnlyOnce(t *testing.T) {
	db := openMigrationTestDB(t)
	migrationFS := fstest.MapFS{
		"000002_second.up.sql":   &fstest.MapFile{Data: []byte(`INSERT INTO migration_events(name) VALUES ('second');`)},
		"000001_first.up.sql":    &fstest.MapFile{Data: []byte(`CREATE TABLE migration_events (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL); INSERT INTO migration_events(name) VALUES ('first');`)},
		"000002_second.down.sql": &fstest.MapFile{Data: []byte(`DELETE FROM migration_events WHERE name = 'second';`)},
	}

	for range 2 {
		if err := Migrate(context.Background(), db, migrationFS); err != nil {
			t.Fatalf("Migrate() error = %v", err)
		}
	}

	rows, err := db.Query(`SELECT name FROM migration_events ORDER BY id`)
	if err != nil {
		t.Fatalf("query migration events: %v", err)
	}
	defer rows.Close()

	var got []string
	for rows.Next() {
		var name string
		if err := rows.Scan(&name); err != nil {
			t.Fatalf("scan migration event: %v", err)
		}
		got = append(got, name)
	}
	if err := rows.Err(); err != nil {
		t.Fatalf("iterate migration events: %v", err)
	}
	if strings.Join(got, ",") != "first,second" {
		t.Fatalf("migration execution order/count = %v, want [first second]", got)
	}

	var applied int
	if err := db.QueryRow(`SELECT COUNT(*) FROM schema_migrations`).Scan(&applied); err != nil {
		t.Fatalf("count schema migrations: %v", err)
	}
	if applied != 2 {
		t.Fatalf("schema_migrations count = %d, want 2", applied)
	}
}

func TestMigrationFailureLeavesDirtyMarkerAndNamesFile(t *testing.T) {
	db := openMigrationTestDB(t)
	broken := &fstest.MapFile{Data: []byte(`
		CREATE TABLE rolled_back_table (id INTEGER PRIMARY KEY, name TEXT NOT NULL);
		INSERT INTO rolled_back_table(id, name) VALUES (1, 'must be rolled back');
		INSERT INTO missing_table(id) VALUES (1);
	`)}
	migrationFS := fstest.MapFS{
		"000001_ok.up.sql":     &fstest.MapFile{Data: []byte(`CREATE TABLE stable_table (id INTEGER PRIMARY KEY);`)},
		"000002_broken.up.sql": broken,
	}

	err := Migrate(context.Background(), db, migrationFS)
	if err == nil {
		t.Fatal("Migrate() error = nil, want migration failure")
	}
	if !strings.Contains(err.Error(), "000002_broken.up.sql") {
		t.Fatalf("Migrate() error = %q, want failing filename", err)
	}

	var filename string
	var dirty bool
	if queryErr := db.QueryRow(`SELECT filename, dirty FROM schema_migrations WHERE version = 2`).Scan(&filename, &dirty); queryErr != nil {
		t.Fatalf("load failed migration state: %v", queryErr)
	}
	if filename != "000002_broken.up.sql" || !dirty {
		t.Fatalf("failed migration state = filename:%q dirty:%v, want dirty marker", filename, dirty)
	}

	var rolledBackTableCount int
	if queryErr := db.QueryRow(`SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'rolled_back_table'`).Scan(&rolledBackTableCount); queryErr != nil {
		t.Fatalf("check rolled-back migration effects: %v", queryErr)
	}
	if rolledBackTableCount != 0 {
		t.Fatalf("failed migration left rolled_back_table behind; CREATE TABLE and INSERT must roll back together")
	}

	broken.Data = []byte(`CREATE TABLE replayed_dirty_migration (id INTEGER PRIMARY KEY);`)
	err = Migrate(context.Background(), db, migrationFS)
	if !errors.Is(err, ErrDirtyMigration) {
		t.Fatalf("Migrate() after dirty failure error = %v, want ErrDirtyMigration", err)
	}
	if !strings.Contains(err.Error(), "2") || !strings.Contains(err.Error(), "000002_broken.up.sql") {
		t.Fatalf("dirty migration error = %q, want version and filename", err)
	}
	var replayedTableCount int
	if queryErr := db.QueryRow(`SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'replayed_dirty_migration'`).Scan(&replayedTableCount); queryErr != nil {
		t.Fatalf("check dirty migration replay: %v", queryErr)
	}
	if replayedTableCount != 0 {
		t.Fatal("dirty migration was replayed")
	}
}

func TestMigrationRejectsInvalidFilenameAndDuplicateVersion(t *testing.T) {
	tests := []struct {
		name        string
		migrationFS fs.FS
		want        string
	}{
		{
			name: "invalid filename",
			migrationFS: fstest.MapFS{
				"initial.up.sql": &fstest.MapFile{Data: []byte(`SELECT 1;`)},
			},
			want: "initial.up.sql",
		},
		{
			name: "duplicate version",
			migrationFS: fstest.MapFS{
				"000001_first.up.sql":  &fstest.MapFile{Data: []byte(`SELECT 1;`)},
				"000001_second.up.sql": &fstest.MapFile{Data: []byte(`SELECT 1;`)},
			},
			want: "duplicate",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			err := Migrate(context.Background(), openMigrationTestDB(t), tt.migrationFS)
			if err == nil {
				t.Fatal("Migrate() error = nil, want validation error")
			}
			if !strings.Contains(strings.ToLower(err.Error()), strings.ToLower(tt.want)) {
				t.Fatalf("Migrate() error = %q, want %q", err, tt.want)
			}
		})
	}
}

func TestMigrationConcurrentCallsExecuteSideEffectsOnce(t *testing.T) {
	db := openConcurrentMigrationTestDB(t)
	migrationFS := &blockingMigrationFS{
		FS: fstest.MapFS{
			"000001_concurrent.up.sql": &fstest.MapFile{Data: []byte(`
				CREATE TABLE concurrent_migration_events (id INTEGER PRIMARY KEY, name TEXT NOT NULL);
				INSERT INTO concurrent_migration_events(id, name) VALUES (1, 'once');
			`)},
		},
		entered: make(chan struct{}),
		release: make(chan struct{}),
	}

	firstResult := make(chan error, 1)
	go func() {
		firstResult <- Migrate(context.Background(), db, migrationFS)
	}()
	select {
	case <-migrationFS.entered:
	case <-time.After(2 * time.Second):
		t.Fatal("first migration did not reach blocked SQL read")
	}

	secondStarted := make(chan struct{})
	secondResult := make(chan error, 1)
	go func() {
		close(secondStarted)
		secondResult <- Migrate(context.Background(), db, migrationFS)
	}()
	<-secondStarted
	time.Sleep(25 * time.Millisecond)
	close(migrationFS.release)

	if err := <-firstResult; err != nil {
		t.Errorf("first concurrent Migrate() error = %v", err)
	}
	if err := <-secondResult; err != nil {
		t.Errorf("second concurrent Migrate() error = %v", err)
	}

	var sideEffects int
	if err := db.QueryRow(`SELECT COUNT(*) FROM concurrent_migration_events`).Scan(&sideEffects); err != nil {
		t.Fatalf("count concurrent migration side effects: %v", err)
	}
	if sideEffects != 1 {
		t.Fatalf("concurrent migration side effects = %d, want 1", sideEffects)
	}
}

func TestMigrationAuthSQLContract(t *testing.T) {
	upBytes, err := migrations.Files.ReadFile("000001_auth.up.sql")
	if err != nil {
		t.Fatalf("read embedded up migration: %v", err)
	}
	downBytes, err := migrations.Files.ReadFile("000001_auth.down.sql")
	if err != nil {
		t.Fatalf("read embedded down migration: %v", err)
	}

	up := normalizeSQL(string(upBytes))
	for _, table := range []string{"users", "`groups`", "memberships", "invitations", "refresh_sessions", "audit_logs"} {
		if !strings.Contains(up, "create table "+table) {
			t.Errorf("up migration missing CREATE TABLE %s", table)
		}
	}
	for _, index := range []string{
		"uk_users_username", "uk_users_platform_admin_guard", "uk_groups_name", "uk_groups_owner_user_id",
		"uk_memberships_group_user", "uk_memberships_user", "uk_memberships_active_owner_group",
		"uk_invitations_code_hash", "uk_refresh_sessions_token_hash",
	} {
		if !strings.Contains(up, "unique key "+index) {
			t.Errorf("up migration missing unique index %s", index)
		}
	}
	for _, fragment := range []string{
		"engine=innodb", "charset=utf8mb4", "platform_admin_guard", "active_owner_group_id", "generated always as",
		"member_type = 'owner'", "status = 'active'", "stored",
		"platform_admin", "group_owner", "member", "disabled", "removed", "used",
	} {
		if !strings.Contains(up, fragment) {
			t.Errorf("up migration missing contract fragment %q", fragment)
		}
	}
	if count := strings.Count(up, "engine=innodb"); count != 6 {
		t.Errorf("up migration InnoDB table count = %d, want 6", count)
	}
	if count := strings.Count(up, "charset=utf8mb4"); count != 6 {
		t.Errorf("up migration utf8mb4 table count = %d, want 6", count)
	}
	for _, constraint := range []string{
		"fk_groups_owner_user", "fk_groups_created_by", "fk_memberships_group", "fk_memberships_user",
		"fk_invitations_group", "fk_invitations_created_by", "fk_invitations_used_by",
		"fk_refresh_sessions_user", "fk_refresh_sessions_group", "fk_refresh_sessions_replacement",
		"fk_audit_logs_group", "fk_audit_logs_operator",
	} {
		if !strings.Contains(up, "constraint "+constraint+" foreign key") {
			t.Errorf("up migration missing foreign key %s", constraint)
		}
	}

	auditStart := strings.Index(up, "create table audit_logs")
	if auditStart < 0 {
		t.Fatal("up migration missing audit_logs")
	}
	auditEnd := strings.Index(up[auditStart:], ";")
	if auditEnd < 0 {
		t.Fatal("audit_logs CREATE TABLE missing terminator")
	}
	if strings.Contains(up[auditStart:auditStart+auditEnd], "updated_at") {
		t.Error("audit_logs must not contain updated_at")
	}

	down := normalizeSQL(string(downBytes))
	wantDropOrder := []string{"audit_logs", "refresh_sessions", "invitations", "memberships", "`groups`", "users"}
	lastPosition := -1
	for _, table := range wantDropOrder {
		position := strings.Index(down, "drop table if exists "+table)
		if position < 0 {
			t.Errorf("down migration missing DROP TABLE %s", table)
			continue
		}
		if position <= lastPosition {
			t.Errorf("down migration does not drop tables in reverse dependency order: %s", table)
		}
		lastPosition = position
	}
}

func TestMySQLDSNEnablesRequiredDriverOptions(t *testing.T) {
	normalized, err := normalizedMySQLDSN("testuser@tcp(127.0.0.1:3306)/testdb?parseTime=false&loc=Local&multiStatements=false")
	if err != nil {
		t.Fatalf("normalizedMySQLDSN() error = %v", err)
	}
	parsed, err := mysqldriver.ParseDSN(normalized)
	if err != nil {
		t.Fatalf("parse normalized DSN: %v", err)
	}
	if !parsed.ParseTime || parsed.Loc.String() != "UTC" || !parsed.MultiStatements {
		t.Fatalf("normalized DSN options = parseTime:%v loc:%v multiStatements:%v", parsed.ParseTime, parsed.Loc, parsed.MultiStatements)
	}
}

func openMigrationTestDB(t *testing.T) *sql.DB {
	t.Helper()
	dsn := "file:" + strings.ReplaceAll(t.Name(), "/", "_") + "?mode=memory&cache=shared&_foreign_keys=on"
	gormDB, err := gorm.Open(sqlite.Open(dsn), &gorm.Config{})
	if err != nil {
		t.Fatalf("open SQLite: %v", err)
	}
	db, err := gormDB.DB()
	if err != nil {
		t.Fatalf("access SQLite sql.DB: %v", err)
	}
	db.SetMaxOpenConns(1)
	t.Cleanup(func() { _ = db.Close() })
	if err := db.Ping(); err != nil {
		t.Fatalf("ping SQLite: %v", err)
	}
	return db
}

func openConcurrentMigrationTestDB(t *testing.T) *sql.DB {
	t.Helper()
	dsn := "file:" + strings.ReplaceAll(t.Name(), "/", "_") + "?mode=memory&cache=shared&_foreign_keys=on"
	gormDB, err := gorm.Open(sqlite.Open(dsn), &gorm.Config{})
	if err != nil {
		t.Fatalf("open concurrent SQLite: %v", err)
	}
	db, err := gormDB.DB()
	if err != nil {
		t.Fatalf("access concurrent SQLite sql.DB: %v", err)
	}
	db.SetMaxOpenConns(4)
	t.Cleanup(func() { _ = db.Close() })
	return db
}

type blockingMigrationFS struct {
	fs.FS
	once    sync.Once
	entered chan struct{}
	release chan struct{}
}

func (migrationFS *blockingMigrationFS) Open(name string) (fs.File, error) {
	blocked := false
	if strings.HasSuffix(name, ".up.sql") {
		migrationFS.once.Do(func() {
			blocked = true
			close(migrationFS.entered)
		})
	}
	if blocked {
		<-migrationFS.release
	}
	return migrationFS.FS.Open(name)
}

func normalizeSQL(value string) string {
	return strings.ToLower(strings.Join(strings.Fields(value), " "))
}
