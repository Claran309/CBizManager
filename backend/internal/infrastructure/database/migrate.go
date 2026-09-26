package database

import (
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
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

// 迁移互斥锁的名字前缀。
//
// MySQL 的 `GET_LOCK` 名字是**服务器级**的（与当前 database 无关），所以必须把
// 库名编进锁名 —— 否则同一台 MySQL 上两个不同的库（生产库、各测试库）会互相阻塞。
// 后果不只是慢：`go test ./...` 会**并行跑多个包**，各包迁移自己的测试库却抢同一把
// 锁，「迁移结束后锁已释放」这类断言会被无关的持锁者打翻（本仓库真踩过）。
//
// 改成按库派生之后：同一个库的并发迁移仍然严格互斥（这是唯一需要的保证），
// 不同库之间不再互相牵连。
const mysqlMigrationLockPrefix = "cbizdocsmanager_migrations_"

// mysqlLockNameMaxLength 是 MySQL 对 user-level lock 名字的长度上限。
// 前缀 27 字符 + 16 位十六进制摘要 = 43，留足余量。
const mysqlLockNameMaxLength = 64

// migrationLockName 按「当前连接所在的 database」派生迁移锁名。
//
// 用摘要而不是原名，是为了绕开 MySQL 的 64 字符上限（库名可以很长，例如
// `cbizdocsmanager_test_auth_<纳秒>_<序号>`）。取不到库名时回退成空串的摘要，
// 退化为「整台服务器一把锁」，与改造前的行为一致。
func migrationLockName(ctx context.Context, conn *sql.Conn) (string, error) {
	var schema sql.NullString
	if err := conn.QueryRowContext(ctx, `SELECT DATABASE()`).Scan(&schema); err != nil {
		return "", fmt.Errorf("读取当前数据库名: %w", err)
	}
	digest := sha256.Sum256([]byte(schema.String))
	name := mysqlMigrationLockPrefix + hex.EncodeToString(digest[:8])
	if len(name) > mysqlLockNameMaxLength {
		return "", fmt.Errorf("迁移锁名过长: %d", len(name))
	}
	return name, nil
}

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

	lockName, err := migrationLockName(ctx, conn)
	if err != nil {
		return nil, err
	}

	var acquired sql.NullInt64
	if err := conn.QueryRowContext(ctx, `SELECT GET_LOCK(?, ?)`, lockName, 30).Scan(&acquired); err != nil {
		return nil, fmt.Errorf("获取 MySQL 迁移锁: %w", err)
	}
	if !acquired.Valid || acquired.Int64 != 1 {
		return nil, fmt.Errorf("获取 MySQL 迁移锁超时")
	}

	return func() {
		releaseCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		var released sql.NullInt64
		_ = conn.QueryRowContext(releaseCtx, `SELECT RELEASE_LOCK(?)`, lockName).Scan(&released)
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
