package migrations

import "embed"

// Files 包含后端发布时随二进制分发的全部 SQL 迁移。
//
//go:embed *.sql
var Files embed.FS
