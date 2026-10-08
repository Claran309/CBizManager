# CBizDocsManager Backend

Go 单体 API。当前包含平台管理员初始化、登录与令牌轮换、首次改密、分组及主账号创建与交接、邀请码注册、成员生命周期、细粒度权限、辅助字典、健康检查，以及完整的业务链：**入库／出库单据、结算单、收付款与开票、汇总报表与总结算快照**。

> ⚠️ **项目已被甲方搁置**（见根目录 [README](../README.md)）。功能链路是通的、测试是绿的，但未做部署上线与生产化收尾。

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

## Web Cookie 认证

原生客户端使用响应体中的 Refresh Token；Web 使用 `/api/v1/auth/web/*`，Refresh Token 只进入 `HttpOnly` Cookie，不返回给 JavaScript。Web 刷新和退出还必须同时满足：

- 请求 `Origin` 与 `WEB_AUTH_ALLOWED_ORIGINS` 中的 scheme、host、port 完全匹配。
- 可读 CSRF Cookie 的值与 `X-CSRF-Token` 请求头相同。
- 跨源开发时前端开启 `withCredentials`，后端只允许配置的 Origin 携带凭据。

本地 HTTP 开发可设置 `WEB_AUTH_SECURE=false`；生产必须使用 HTTPS、`WEB_AUTH_SECURE=true`，并配置精确的允许 Origin。生产配置校验不通过时服务会拒绝启动。Refresh Cookie 固定为 `HttpOnly`、`SameSite=Lax` 且 Path 为 `/api/v1/auth/web`；不要把 Refresh Token、Cookie 或 CSRF 值写入日志。

## 成员、权限与字典

租户接口从认证 Principal 取得 `group_id`，不接受客户端自报租户。主账号拥有权限目录中的全部能力；普通成员只拥有显式授权。`member.manage` 可以查询和改变其他普通成员状态，但只有主账号能整体替换成员权限。`dictionary.manage` 控制六类辅助字典的创建、修改和停用。

成员状态、权限集合和字典写接口都要求提交 `version`。版本过期返回 409，客户端应刷新后再让用户决定是否重试，不能静默覆盖他人的修改。

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

成员、权限、字典及 Web Cookie 的定向单元测试：

```powershell
go test -count=1 ./internal/authorization ./internal/member ./internal/dictionary ./internal/identity ./internal/infrastructure/httpserver
```

真实 MySQL 集成测试会创建并在结束时删除名称以 `cbizdocsmanager_test_` 开头的独立临时数据库。`TEST_MYSQL_DSN` 中可带任意数据库名，测试只使用其中的服务器连接信息和凭据：

```powershell
$env:TEST_MYSQL_DSN = 'root:<local-password>@tcp(127.0.0.1:3306)/mysql?charset=utf8mb4&parseTime=true&loc=UTC'
go test -count=1 -tags=integration ./tests/integration -v
```

要执行仓库中全部带 `integration` build tag 的真实 MySQL 测试，使用：

```powershell
go test -count=1 -tags=integration ./...
```
