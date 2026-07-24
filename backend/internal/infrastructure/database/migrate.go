package database

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"io/fs"
	"path"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	mysqldriver "github.com/go-sql-driver/mysql"
)

const mysqlMigrationLockName = "cbizdocsmanager_schema_migrations"

var (
	upMigrationNamePattern = regexp.MustCompile(`^([0-9]+)_.+\.up\.sql$`)
	migrationLocks         sync.Map
)

var ErrDirtyMigration = errors.New("dirty migration")

type migration struct {
	version  uint64
	filename string
}

// Migrate 按文件名顺序执行根目录中的 up 迁移，并在 SQL 成功后记录版本。
func Migrate(ctx context.Context, db *sql.DB, migrationFS fs.FS) error {
	migrations, err := discoverMigrations(migrationFS)
	if err != nil {
		return err
	}
	localLock := migrationLockFor(db)
	localLock.Lock()
	defer localLock.Unlock()

	conn, err := db.Conn(ctx)
	if err != nil {
		return fmt.Errorf("获取迁移数据库连接: %w", err)
	}
	defer conn.Close()

	releaseLock, err := acquireMigrationLock(ctx, db, conn)
	if err != nil {
		return err
	}
	defer releaseLock()

	if _, err := conn.ExecContext(ctx, `CREATE TABLE IF NOT EXISTS schema_migrations (
        version BIGINT NOT NULL PRIMARY KEY,
        filename VARCHAR(255) NOT NULL,
        dirty BOOLEAN NOT NULL DEFAULT FALSE,
        applied_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
    )`); err != nil {
		return fmt.Errorf("创建 schema_migrations: %w", err)
	}
	if err := rejectDirtyMigration(ctx, conn); err != nil {
		return err
	}

	for _, item := range migrations {
		if err := applyMigration(ctx, conn, migrationFS, item); err != nil {
			return err
		}
	}
	return nil
}

func migrationLockFor(db *sql.DB) *sync.Mutex {
	lock, _ := migrationLocks.LoadOrStore(db, &sync.Mutex{})
	return lock.(*sync.Mutex)
}

func acquireMigrationLock(ctx context.Context, db *sql.DB, conn *sql.Conn) (func(), error) {
	if _, ok := db.Driver().(*mysqldriver.MySQLDriver); !ok {
		return func() {}, nil
	}

	var acquired sql.NullInt64
	if err := conn.QueryRowContext(ctx, `SELECT GET_LOCK(?, ?)`, mysqlMigrationLockName, 30).Scan(&acquired); err != nil {
		return nil, fmt.Errorf("获取 MySQL 迁移锁: %w", err)
	}
	if !acquired.Valid || acquired.Int64 != 1 {
		return nil, fmt.Errorf("获取 MySQL 迁移锁超时")
	}

	return func() {
		releaseCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		var released sql.NullInt64
		_ = conn.QueryRowContext(releaseCtx, `SELECT RELEASE_LOCK(?)`, mysqlMigrationLockName).Scan(&released)
	}, nil
}

func discoverMigrations(migrationFS fs.FS) ([]migration, error) {
	entries, err := fs.ReadDir(migrationFS, ".")
	if err != nil {
		return nil, fmt.Errorf("读取迁移目录: %w", err)
	}

	versions := make(map[uint64]string)
	migrations := make([]migration, 0, len(entries))
	for _, entry := range entries {
		if entry.IsDir() || !strings.HasSuffix(entry.Name(), ".up.sql") {
			continue
		}
		matches := upMigrationNamePattern.FindStringSubmatch(entry.Name())
		if matches == nil {
			return nil, fmt.Errorf("非法迁移文件名 %q", entry.Name())
		}
		version, err := strconv.ParseUint(matches[1], 10, 64)
		if err != nil {
			return nil, fmt.Errorf("解析迁移版本 %q: %w", entry.Name(), err)
		}
		if previous, exists := versions[version]; exists {
			return nil, fmt.Errorf("duplicate migration version %d: %s and %s", version, previous, entry.Name())
		}
		versions[version] = entry.Name()
		migrations = append(migrations, migration{version: version, filename: entry.Name()})
	}
	sort.Slice(migrations, func(i, j int) bool { return migrations[i].filename < migrations[j].filename })
	return migrations, nil
}

func applyMigration(ctx context.Context, db *sql.Conn, migrationFS fs.FS, item migration) error {
	var dirty bool
	err := db.QueryRowContext(ctx, `SELECT dirty FROM schema_migrations WHERE version = ?`, item.version).Scan(&dirty)
	if err == nil {
		if dirty {
			return dirtyMigrationError(item.version, item.filename)
		}
		return nil
	}
	if !errors.Is(err, sql.ErrNoRows) {
		return fmt.Errorf("检查迁移 %s: %w", item.filename, err)
	}
	if _, err := db.ExecContext(ctx, `INSERT INTO schema_migrations(version, filename, dirty) VALUES (?, ?, ?)`, item.version, item.filename, true); err != nil {
		return fmt.Errorf("标记迁移 %s 为 dirty: %w", item.filename, err)
	}

	tx, err := db.BeginTx(ctx, nil)
	if err != nil {
		return fmt.Errorf("开始迁移 %s: %w", item.filename, err)
	}
	defer func() { _ = tx.Rollback() }()

	sqlBytes, err := fs.ReadFile(migrationFS, path.Clean(item.filename))
	if err != nil {
		return fmt.Errorf("读取迁移 %s: %w", item.filename, err)
	}
	if _, err := tx.ExecContext(ctx, string(sqlBytes)); err != nil {
		return fmt.Errorf("执行迁移 %s: %w", item.filename, err)
	}
	if err := tx.Commit(); err != nil {
		return fmt.Errorf("提交迁移 %s: %w", item.filename, err)
	}
	result, err := db.ExecContext(ctx, `UPDATE schema_migrations SET dirty = ? WHERE version = ? AND dirty = ?`, false, item.version, true)
	if err != nil {
		return fmt.Errorf("清理迁移 %s dirty 状态: %w", item.filename, err)
	}
	rowsAffected, err := result.RowsAffected()
	if err != nil {
		return fmt.Errorf("检查迁移 %s dirty 状态: %w", item.filename, err)
	}
	if rowsAffected != 1 {
		return dirtyMigrationError(item.version, item.filename)
	}
	return nil
}

func rejectDirtyMigration(ctx context.Context, db *sql.Conn) error {
	var item migration
	err := db.QueryRowContext(ctx, `SELECT version, filename FROM schema_migrations WHERE dirty = ? ORDER BY version LIMIT 1`, true).
		Scan(&item.version, &item.filename)
	if errors.Is(err, sql.ErrNoRows) {
		return nil
	}
	if err != nil {
		return fmt.Errorf("检查 dirty migration: %w", err)
	}
	return dirtyMigrationError(item.version, item.filename)
}

func dirtyMigrationError(version uint64, filename string) error {
	return fmt.Errorf("%w: version %d file %s", ErrDirtyMigration, version, filename)
}
