package database

import (
	"context"
	"errors"
	"fmt"
	"time"

	mysqldriver "github.com/go-sql-driver/mysql"
	"gorm.io/driver/mysql"
	"gorm.io/gorm"

	"CBizDocsManager/backend/pkg/config"
)

// OpenMySQL 创建 GORM/MySQL 连接，设置连接池并验证数据库可用性。
func OpenMySQL(ctx context.Context, cfg config.MySQLConfig) (*gorm.DB, error) {
	if cfg.DSN == "" {
		return nil, errors.New("MySQL DSN 不能为空")
	}
	dsn, err := normalizedMySQLDSN(cfg.DSN)
	if err != nil {
		return nil, err
	}

	db, err := gorm.Open(mysql.Open(dsn), &gorm.Config{TranslateError: true})
	if err != nil {
		return nil, fmt.Errorf("打开 MySQL: %w", err)
	}
	sqlDB, err := db.DB()
	if err != nil {
		return nil, fmt.Errorf("获取 MySQL 连接池: %w", err)
	}
	sqlDB.SetMaxOpenConns(cfg.MaxOpenConns)
	sqlDB.SetMaxIdleConns(cfg.MaxIdleConns)
	if cfg.ConnMaxLifetime > 0 {
		sqlDB.SetConnMaxLifetime(cfg.ConnMaxLifetime)
	}
	if err := sqlDB.PingContext(ctx); err != nil {
		_ = sqlDB.Close()
		return nil, fmt.Errorf("连接 MySQL: %w", err)
	}
	return db, nil
}

func normalizedMySQLDSN(raw string) (string, error) {
	dsn, err := mysqldriver.ParseDSN(raw)
	if err != nil {
		return "", fmt.Errorf("解析 MySQL DSN: %w", err)
	}
	dsn.ParseTime = true
	dsn.Loc = time.UTC
	dsn.MultiStatements = true
	return dsn.FormatDSN(), nil
}
