# CBizDocsManager Backend

Go 单体 API，当前包含平台管理员初始化、登录与令牌轮换、首次改密、分组及主账号创建、邀请码注册和健康检查。

## 本地运行

MySQL、Redis 默认连接 Docker 容器，不需要在 Windows 重复安装。先在 `backend` 目录准备本地环境文件：

```powershell
Copy-Item .env.example .env
```

修改 `.env` 中的 MySQL、Redis 和 JWT 配置后启动：

```powershell
go run ./cmd/api
```

Redis 是可选依赖。Redis 不可用时 API 会以降级模式启动；`GET /health/ready` 的 HTTP 状态只取决于 MySQL，响应中的 `redis` 字段会显示 `up`、`down` 或 `disabled`。

开发配置默认管理员是 `admin / 123456`，只允许本地开发使用。首次登录后必须调用 `PUT /api/v1/auth/password` 修改密码，之后才能创建分组。生产环境必须显式设置至少 32 字节的 `JWT_SECRET`、`BOOTSTRAP_ADMIN_USERNAME` 和至少 12 字节的 `BOOTSTRAP_ADMIN_PASSWORD`，缺失时进程会拒绝启动。

## Docker Compose

Compose 会创建本项目专用的 MySQL/Redis 容器、命名卷和网络，不复用或改动其他项目的容器：

```powershell
$env:MYSQL_ROOT_PASSWORD = '<set-locally>'
$env:REDIS_PASSWORD = '<set-locally>'
$env:JWT_SECRET = '<at-least-32-random-bytes>'
$env:BOOTSTRAP_ADMIN_USERNAME = '<admin-username>'
$env:BOOTSTRAP_ADMIN_PASSWORD = '<at-least-12-bytes>'
docker compose -f ..\deploy\docker-compose.yml up --build -d
```

API 只等待 MySQL 健康后启动，不依赖 Redis 健康；Redis 停止不会让 API 进程退出。

## 验证

```powershell
gofmt -w .
go mod tidy
go mod verify
go test -count=1 ./...
go vet ./...
go build -o "$env:TEMP\cbizdocsmanager-api.exe" ./cmd/api
docker compose -f ..\deploy\docker-compose.yml config --quiet
```

真实 MySQL 集成测试会创建并在结束时删除名称以 `cbizdocsmanager_test_` 开头的独立临时数据库。`TEST_MYSQL_DSN` 中可带任意数据库名，测试只使用其中的服务器连接信息和凭据：

```powershell
$env:TEST_MYSQL_DSN = 'root:<local-password>@tcp(127.0.0.1:3306)/mysql?charset=utf8mb4&parseTime=true&loc=UTC'
go test -count=1 -tags=integration ./tests/integration -v
```
