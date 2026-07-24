# CBizDocsManager Backend Foundation and Authentication Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 建立可启动、可测试、可迁移的 Go 单体后端，并完成平台管理员、组主账号、邀请码子账号和可撤销会话的认证闭环。

**Architecture:** 使用 Gin 作为 HTTP 入口，业务按 Handler → Service → Repository 分层并通过构造函数注入；GORM 只负责数据访问，生产表结构由版本化 SQL 迁移创建。Access Token 使用短时 JWT，Refresh Token 使用随机不透明字符串并仅以 SHA-256 哈希落库；Redis 始终是可选依赖，认证正确性只依赖 MySQL。

**Tech Stack:** Go 1.25.3、Gin、GORM/MySQL、Viper、Zap、validator、golang-jwt/jwt/v5、bcrypt、go-redis/v9、kin-openapi、Docker Compose。

---

## 文件边界

### 契约

- `api/openapi/cbizdocsmanager-v1.yaml`：首批 REST API 的唯一契约。
- `backend/tests/openapi_contract_test.go`：解析、语义校验以及必需路径/错误码断言。

### 通用基础包

- `backend/pkg/apperror/error.go`：稳定业务错误码、HTTP 状态与错误包装。
- `backend/pkg/config/config.go`：YAML、`.env`、系统环境变量加载及生产安全校验。
- `backend/pkg/jwt/manager.go`：HS256 Access JWT 签发、解析与算法校验。
- `backend/pkg/logger/logger.go`：Zap 初始化。
- `backend/pkg/password/password.go`：bcrypt 哈希与校验。
- `backend/pkg/requestid/requestid.go`：Request ID 生成、上下文保存和响应头。
- `backend/pkg/response/response.go`：统一成功/失败 Envelope。

### 领域模块

- `backend/internal/identity/model.go`：`User`、`RefreshSession`、账号枚举和当前身份 `Principal`。
- `backend/internal/identity/dto.go`：登录、刷新、本人信息、改密 DTO。
- `backend/internal/identity/repository.go`：认证查询、会话创建/轮换/撤销、改密和管理员引导的数据访问。
- `backend/internal/identity/service.go`：认证、会话和管理员引导业务规则。
- `backend/internal/identity/handler.go`：除邀请码注册外的 `/auth/*` HTTP 适配。
- `backend/internal/organization/model.go`：`Group`、`Membership`、`Invitation`。
- `backend/internal/organization/dto.go`：邀请码创建和注册 DTO。
- `backend/internal/organization/repository.go`：邀请码写入和原子消费。
- `backend/internal/organization/service.go`：主账号邀请和邀请码注册规则。
- `backend/internal/organization/handler.go`：`/groups/invitations` 与 `/auth/register`。
- `backend/internal/platform/dto.go`：平台创建组请求/响应。
- `backend/internal/platform/repository.go`：创建组、主账号、成员关系和审计日志的事务。
- `backend/internal/platform/service.go`：平台管理员建组规则。
- `backend/internal/platform/handler.go`：`/platform/groups`。

### 基础设施与启动

- `backend/internal/infrastructure/database/mysql.go`：MySQL/GORM 连接池。
- `backend/internal/infrastructure/database/migrate.go`：嵌入并按版本执行 SQL 迁移。
- `backend/internal/infrastructure/database/migrations/*.sql`：由根 `backend/migrations/` 嵌入的迁移副本入口；实现时使用 `go:embed ../../../migrations/*.sql` 不可行，因此迁移 runner 放在 `backend/migrations/embed.go`，数据库包只消费 `fs.FS`。
- `backend/migrations/embed.go`：嵌入迁移文件并导出 `FS`。
- `backend/migrations/000001_auth.up.sql`：首批六张表、外键、唯一索引和状态索引。
- `backend/migrations/000001_auth.down.sql`：逆序删除首批表。
- `backend/internal/infrastructure/cache/redis.go`：可选 Redis 初始化与降级状态。
- `backend/internal/infrastructure/httpserver/middleware.go`：Recovery、访问日志、CORS、认证和角色/强制改密守卫。
- `backend/internal/infrastructure/httpserver/router.go`：路由装配与健康检查。
- `backend/cmd/api/main.go`：composition root、迁移、管理员引导、优雅退出。
- `backend/config/config.yaml`、`backend/.env.example`：本地默认配置和环境变量示例。
- `backend/Dockerfile`、`deploy/docker-compose.yml`：API、MySQL、可选 Redis 的开发环境。
- `backend/README.md`：启动、迁移、测试和默认管理员安全说明。

### 测试

- 与生产文件同目录的 `*_test.go`：纯单元和 Handler 测试，可直接运行 `go test ./...`。
- `backend/internal/testkit/*_test.go` 不建立生产测试包；各模块在测试文件内使用完整行为 fake，避免测试专用生产 API。
- `backend/tests/integration/auth_flow_test.go`：带 `//go:build integration` 的 MySQL 真实闭环测试。

---

### Task 1: OpenAPI 契约与通用安全基础包

**Files:**
- Create: `backend/go.mod`
- Create: `backend/tests/openapi_contract_test.go`
- Create: `api/openapi/cbizdocsmanager-v1.yaml`
- Create: `backend/pkg/apperror/error.go`
- Create: `backend/pkg/apperror/error_test.go`
- Create: `backend/pkg/password/password.go`
- Create: `backend/pkg/password/password_test.go`
- Create: `backend/pkg/jwt/manager.go`
- Create: `backend/pkg/jwt/manager_test.go`
- Create: `backend/pkg/config/config.go`
- Create: `backend/pkg/config/config_test.go`
- Create: `backend/pkg/logger/logger.go`
- Create: `backend/pkg/requestid/requestid.go`
- Create: `backend/pkg/requestid/requestid_test.go`
- Create: `backend/pkg/response/response.go`
- Create: `backend/pkg/response/response_test.go`

- [x] **Step 1: 建立最小 Go 模块并先写 OpenAPI 失败测试**

`backend/go.mod` 先只声明模块、Go 版本和测试所需依赖：

```go
module CBizDocsManager/backend

go 1.25.3

require github.com/getkin/kin-openapi v0.133.0
```

`backend/tests/openapi_contract_test.go` 必须先加载 `../../api/openapi/cbizdocsmanager-v1.yaml`，调用 `openapi3.Loader.LoadFromFile` 和 `doc.Validate(context.Background())`，并逐项断言以下 operation 存在：

```go
var requiredOperations = map[string]string{
    "POST /api/v1/auth/login":          "post",
    "POST /api/v1/auth/register":       "post",
    "POST /api/v1/auth/refresh":        "post",
    "POST /api/v1/auth/logout":         "post",
    "GET /api/v1/auth/me":              "get",
    "PUT /api/v1/auth/password":        "put",
    "POST /api/v1/platform/groups":     "post",
    "POST /api/v1/groups/invitations":  "post",
    "GET /health/live":                 "get",
    "GET /health/ready":                "get",
}
```

测试还要断言 `ApiResponse` 必含 `code`、`message`、`data`、`request_id`，并断言稳定错误码枚举包含规格中的 12 个值。

- [x] **Step 2: 运行 OpenAPI 测试并确认 RED**

Run: `cd backend; go test ./tests -run TestOpenAPIContract -v`

Expected: FAIL，原因必须是 `api/openapi/cbizdocsmanager-v1.yaml` 不存在，而不是 Go 编译或路径拼写错误。

- [x] **Step 3: 写完整 OpenAPI 契约并确认 GREEN**

规范使用 OpenAPI `3.0.3`、`/api/v1` 路径、Bearer JWT 安全方案和统一 Envelope。固定请求字段：

```yaml
LoginRequest: {username: string, password: string}
RegisterRequest: {invitation_code: string, username: string, password: string, display_name: string}
RefreshRequest: {refresh_token: string}
ChangePasswordRequest: {current_password: string, new_password: string}
CreateGroupRequest: {name: string, owner_username: string, owner_display_name: string, owner_temporary_password: string}
CreateInvitationRequest: {expires_in_days: integer, minimum: 1, maximum: 30, default: 7}
```

登录/刷新返回 `access_token`、`refresh_token`、`access_expires_at`、`refresh_expires_at`；注册返回用户与组摘要；邀请码明文只在创建响应出现。`auth/me` 返回用户、可空组、可空成员类型和 `must_change_password`，不返回权限全集。

Run: `cd backend; go test ./tests -run TestOpenAPIContract -v`

Expected: PASS。

- [x] **Step 4: 按测试优先实现错误、密码、JWT、配置、Request ID 和响应包**

每个包先写最小失败测试，再实现下列公开 API：

```go
// apperror
type Error struct { Code string; Message string; HTTPStatus int; Cause error }
func New(code, message string, status int) *Error
func Wrap(base *Error, cause error) *Error
func As(err error) *Error

// password
func Hash(plain string) (string, error)
func Verify(hash, plain string) bool

// jwt
type Claims struct { UserID uint64; GroupID *uint64; AccountType string; SessionID uint64; jwt.RegisteredClaims }
type Manager struct { /* secret and TTL */ }
func NewManager(secret, issuer string, ttl time.Duration) (*Manager, error)
func (m *Manager) Sign(claims Claims, now time.Time) (string, time.Time, error)
func (m *Manager) Parse(raw string) (*Claims, error)

// requestid
const Header = "X-Request-ID"
func Middleware() gin.HandlerFunc
func FromContext(c *gin.Context) string

// response
type Envelope struct { Code string; Message string; Data any; RequestID string; FieldErrors []FieldError }
func Success(c *gin.Context, status int, data any)
func Failure(c *gin.Context, err error, fields []FieldError)
```

JWT 测试必须覆盖正确签发、过期、错误密钥和拒绝非 HS256 算法；密码测试覆盖哈希不等于明文、正确/错误密码；配置测试覆盖环境变量覆盖、生产环境拒绝默认 JWT/管理员密码；响应测试覆盖稳定 HTTP 状态和 Request ID。

- [x] **Step 5: 运行 Task 1 全部测试并整理依赖**

Run: `cd backend; go mod tidy; go test ./pkg/... ./tests -v`

Expected: PASS，且日志/响应测试不输出密码或完整 Token。

---

### Task 2: 数据模型、SQL 迁移与 GORM Repository

**Files:**
- Create: `backend/internal/identity/model.go`
- Create: `backend/internal/organization/model.go`
- Create: `backend/migrations/embed.go`
- Create: `backend/migrations/000001_auth.up.sql`
- Create: `backend/migrations/000001_auth.down.sql`
- Create: `backend/internal/infrastructure/database/mysql.go`
- Create: `backend/internal/infrastructure/database/migrate.go`
- Create: `backend/internal/infrastructure/database/migrate_test.go`
- Create: `backend/internal/identity/repository.go`
- Create: `backend/internal/identity/repository_test.go`
- Create: `backend/internal/organization/repository.go`
- Create: `backend/internal/organization/repository_test.go`
- Create: `backend/internal/platform/repository.go`
- Create: `backend/internal/platform/repository_test.go`

- [x] **Step 1: 先写迁移契约失败测试**

`migrate_test.go` 使用内存 `fstest.MapFS` 测试迁移按文件名排序、同一版本只执行一次、失败时不写 `schema_migrations`；另读取真实 `000001_auth.up.sql` 断言包含六张业务表：

```go
for _, table := range []string{"users", "groups", "memberships", "invitations", "refresh_sessions", "audit_logs"} {
    if !strings.Contains(sql, "CREATE TABLE "+table) { t.Fatalf("missing table %s", table) }
}
```

Run: `cd backend; go test ./internal/infrastructure/database -run TestMigration -v`

Expected: FAIL，因为迁移 runner 和 SQL 文件尚不存在。

- [x] **Step 2: 实现模型和首版 SQL 迁移**

账号枚举固定为 `platform_admin`、`group_owner`、`member`；状态固定为 `active`、`disabled`，成员额外含 `removed`。SQL 必须包含：

```sql
UNIQUE KEY uk_users_username (username),
UNIQUE KEY uk_groups_name (name),
UNIQUE KEY uk_groups_owner_user_id (owner_user_id),
UNIQUE KEY uk_memberships_group_user (group_id, user_id),
UNIQUE KEY uk_memberships_user (user_id),
UNIQUE KEY uk_invitations_code_hash (code_hash),
UNIQUE KEY uk_refresh_sessions_token_hash (token_hash)
```

`memberships` 增加可空生成列 `active_owner_group_id`，值仅在 `member_type='owner' AND status='active'` 时等于 `group_id`，并建立唯一索引，保证一个组只有一个有效 owner membership。所有表使用 `utf8mb4`、InnoDB 和明确外键；`audit_logs` 不提供更新时间字段。

- [x] **Step 3: 实现可重复迁移 runner 并确认 GREEN**

`migrations/embed.go`：

```go
//go:embed *.sql
var Files embed.FS
```

`database.Migrate(ctx, sqlDB, migrations.Files)` 创建 `schema_migrations`，只执行 `*.up.sql`，成功后记录版本；单个文件在事务中执行，执行失败回滚版本记录并返回带文件名的错误。

Run: `cd backend; go test ./internal/infrastructure/database -v`

Expected: PASS。

- [x] **Step 4: 先写 Repository 行为测试，再实现 GORM 数据访问**

测试使用 `gorm.io/driver/sqlite` 的共享内存库和测试内 `AutoMigrate`，只用于验证 Repository 行为，不进入生产启动路径。至少覆盖：

```text
identity: 按用户名查用户；创建/撤销会话；轮换后旧哈希不可再次轮换；管理员初始化不覆盖已有密码。
platform: 创建组时同时创建主账号、owner membership 和审计；用户名或组名冲突时整个事务回滚。
organization: 邀请码不存在/过期/已用；成功注册同时创建 member、标记 used、写审计；第二次消费失败。
```

Repository 所有方法接收 `context.Context` 并使用 `WithContext`。MySQL 下的 Refresh 和邀请码消费使用事务加 `clause.Locking{Strength: "UPDATE"}`；唯一键冲突映射为可判断的领域错误，不把 GORM 错误直接暴露给 Handler。

- [x] **Step 5: 运行 Repository 与迁移测试**

Run: `cd backend; go test ./internal/identity ./internal/organization ./internal/platform ./internal/infrastructure/database -v`

Expected: PASS。

---

### Task 3: 登录、改密、刷新、退出和当前用户接口

**Files:**
- Create: `backend/internal/identity/dto.go`
- Create: `backend/internal/identity/service.go`
- Create: `backend/internal/identity/service_test.go`
- Create: `backend/internal/identity/handler.go`
- Create: `backend/internal/identity/handler_test.go`
- Create: `backend/internal/infrastructure/httpserver/middleware.go`
- Create: `backend/internal/infrastructure/httpserver/middleware_test.go`

- [x] **Step 1: 写 Identity Service 失败测试**

在测试文件中建立线程安全 fake repository，完整模拟用户、成员、组和 Refresh Session 状态，不断言 fake 调用次数，只断言真实 Service 输出。覆盖：

```text
登录成功；用户名不存在和错误密码统一 AUTH_INVALID_CREDENTIALS；禁用用户拒绝；禁用组/成员拒绝；平台管理员 group_id 为 null；强制改密账号仍可登录但 Principal 标记受限；改密校验旧密码并清除 must_change_password；Refresh 正常轮换；旧 Refresh 重放 AUTH_REFRESH_INVALID；Logout 撤销当前 session。
```

Run: `cd backend; go test ./internal/identity -run TestService -v`

Expected: FAIL，因为 `Service` 尚不存在。

- [x] **Step 2: 实现 Identity Service 最小业务逻辑**

公开 API 固定为：

```go
type Service struct { repo Repository; passwords PasswordManager; tokens *jwt.Manager; now func() time.Time }
func NewService(repo Repository, passwords PasswordManager, tokens *jwt.Manager, accessTTL, refreshTTL time.Duration) *Service
func (s *Service) Login(ctx context.Context, req LoginRequest) (*TokenPair, error)
func (s *Service) Refresh(ctx context.Context, req RefreshRequest) (*TokenPair, error)
func (s *Service) Logout(ctx context.Context, principal Principal) error
func (s *Service) Me(ctx context.Context, principal Principal) (*MeResponse, error)
func (s *Service) ChangePassword(ctx context.Context, principal Principal, req ChangePasswordRequest) error
func (s *Service) Authenticate(ctx context.Context, rawAccessToken string) (*Principal, error)
func (s *Service) BootstrapPlatformAdmin(ctx context.Context, username, plainPassword string) (bool, error)
```

Refresh Token 使用 `crypto/rand` 生成 32 字节并用 `base64.RawURLEncoding` 编码，持久层只接收 SHA-256 十六进制哈希。登录成功先创建 Refresh Session 取得 `session_id`，再签 Access JWT。每个受保护请求在解析 JWT 后重新查询用户、组和成员状态，满足禁用/移组立即失效。

- [x] **Step 3: 写 Handler 与中间件失败测试**

使用 `httptest` 和 Gin test mode 覆盖：字段校验 400/`VALIDATION_FAILED`、错误密码 401、Bearer 缺失 401、请求头 Request ID 原样回显、未提供时生成、`auth/me` 成功、强制改密用户只能访问 me/password/logout、普通成员访问平台接口 403、panic 被 Recovery 转换为 `INTERNAL_ERROR` 且带 Request ID。

Run: `cd backend; go test ./internal/identity ./internal/infrastructure/httpserver -run 'TestHandler|TestMiddleware' -v`

Expected: FAIL，因为 Handler 和中间件尚不存在。

- [x] **Step 4: 实现 Handler 和中间件并确认 GREEN**

中间件顺序固定为：Request ID → Recovery → Access Log → CORS → 路由。认证中间件把 `identity.Principal` 存入 Gin context；`RequirePasswordChanged`、`RequirePlatformAdmin`、`RequireGroupOwner` 只读取 Principal，不重新解析 JWT。Handler 只做绑定、调用 Service 和映射统一响应。

`PUT /auth/password` 成功返回 204 Envelope 不合适，因此固定返回 HTTP 200 和空对象 `{}`；`POST /auth/logout` 同样返回 HTTP 200。不得记录密码、Authorization、Access Token 或 Refresh Token。

- [x] **Step 5: 运行身份模块测试**

Run: `cd backend; go test ./internal/identity ./internal/infrastructure/httpserver -v`

Expected: PASS。

---

### Task 4: 平台建组、主账号邀请和邀请码注册

**Files:**
- Create: `backend/internal/platform/dto.go`
- Create: `backend/internal/platform/service.go`
- Create: `backend/internal/platform/service_test.go`
- Create: `backend/internal/platform/handler.go`
- Create: `backend/internal/platform/handler_test.go`
- Create: `backend/internal/organization/dto.go`
- Create: `backend/internal/organization/service.go`
- Create: `backend/internal/organization/service_test.go`
- Create: `backend/internal/organization/handler.go`
- Create: `backend/internal/organization/handler_test.go`

- [x] **Step 1: 写平台建组失败测试**

覆盖：只有已改密的 `platform_admin` 可创建；创建结果含组和主账号摘要但不回显密码；owner 账号固定 `must_change_password=true`；组名重复映射 `GROUP_NAME_EXISTS`；用户名重复映射 `USER_USERNAME_EXISTS`；Repository 失败不返回半成品。

Run: `cd backend; go test ./internal/platform -run TestService -v`

Expected: FAIL。

- [x] **Step 2: 实现平台建组 Service/Handler 并通过测试**

Service 在调用事务 Repository 前完成 trim、密码最小长度和 bcrypt 哈希；Repository 同一事务创建 `users(group_owner)`、`groups`、`memberships(owner)` 与 `audit_logs(platform.group.created)`。Handler 依赖前一任务的 `RequirePasswordChanged` 和 `RequirePlatformAdmin`。

- [x] **Step 3: 写邀请和注册失败测试**

覆盖：主账号生成默认七天邀请码；允许 1–30 天覆盖；普通成员/强制改密 owner 被拒绝；数据库只接收哈希；响应只返回一次明文；邀请码无效、过期、已使用；用户名重复；成功注册为 `member` 且自动加入邀请所属组；两个并发注册只有一个成功。

Run: `cd backend; go test ./internal/organization -run TestService -v`

Expected: FAIL。

- [x] **Step 4: 实现邀请、原子注册和 Handler**

邀请码同样用 32 字节随机值和 SHA-256 哈希。`Register` 的 Repository 事务必须：锁邀请 → 验证状态/过期 → 验证组 active → 创建用户 → 创建 membership → 更新邀请 `used/used_at/used_by` → 写 `identity.member.registered` 审计。并发 loser 返回 `INVITATION_USED` 或 `INVITATION_INVALID`，不得 500。

`/auth/register` 是公开路由，但不接受 `group_id`、`account_type`、`member_type` 或创建公司字段。

- [x] **Step 5: 运行 Task 4 测试**

Run: `cd backend; go test ./internal/platform ./internal/organization -v`

Expected: PASS。

---

### Task 5: 路由装配、健康检查、启动、Docker 与真实 MySQL 验证

**Files:**
- Create: `backend/internal/infrastructure/cache/redis.go`
- Create: `backend/internal/infrastructure/cache/redis_test.go`
- Create: `backend/internal/infrastructure/httpserver/router.go`
- Create: `backend/internal/infrastructure/httpserver/router_test.go`
- Create: `backend/config/config.yaml`
- Create: `backend/.env.example`
- Create: `backend/cmd/api/main.go`
- Create: `backend/Dockerfile`
- Create: `deploy/docker-compose.yml`
- Create: `backend/tests/integration/auth_flow_test.go`
- Create: `backend/README.md`

- [x] **Step 1: 写路由、健康和 Redis 降级失败测试**

使用接口注入的 readiness checker，覆盖 `/health/live` 永远 200；MySQL ping 成功时 `/health/ready` 200，失败时 503；Redis 初始化失败返回 `nil` 客户端和 degraded 状态但不返回启动错误。Router 测试断言十个 OpenAPI 路由全部注册。

Run: `cd backend; go test ./internal/infrastructure/cache ./internal/infrastructure/httpserver -run 'TestRedis|TestHealth|TestRoutes' -v`

Expected: FAIL。

- [x] **Step 2: 实现 Router、健康检查和 Redis 可选初始化**

`/health/ready` 的 `data` 返回 `mysql: up|down` 与 `redis: up|down|disabled`；HTTP 就绪只由 MySQL 决定。CORS 只允许配置的 origins、Authorization/Content-Type/X-Request-ID 请求头和常用方法，不使用 `*` 搭配 credentials。

路由分组：

```text
public: login, register, refresh, live, ready
authenticated unrestricted: me, password, logout
authenticated + password changed + platform admin: platform/groups
authenticated + password changed + group owner: groups/invitations
```

- [x] **Step 3: 写 MySQL 集成测试文件**

文件添加 `//go:build integration`；从 `TEST_MYSQL_DSN` 读取独立测试库，未设置时 `t.Skip`。测试在空库执行 up migration，并通过真实 Repository/Service 完成：幂等 bootstrap → admin 登录/改密 → 创建组 owner → owner 登录/改密 → 创建邀请 → member 注册/登录 → refresh 轮换 → 旧 refresh 被拒绝 → logout 后 refresh 被拒绝。另用 goroutine 验证同一邀请码并发只有一次注册成功。

- [x] **Step 4: 实现 main、配置、Docker 与启动文档**

`main.go` 顺序固定：加载配置 → 初始化 logger → 连接 MySQL 并配置连接池 → 执行迁移 → 初始化可选 Redis → 构造 Repository/Service/Handler → 幂等 bootstrap admin → 构造 Router → 启动 HTTP server → 监听 SIGINT/SIGTERM 优雅关闭。生产环境缺少显式 `JWT_SECRET`、`BOOTSTRAP_ADMIN_USERNAME` 或 `BOOTSTRAP_ADMIN_PASSWORD` 时启动失败；开发环境默认 `admin/123456` 并记录不含密码的安全警告。

Dockerfile 使用多阶段构建和非 root 运行用户。Compose 提供 `mysql`、`redis`、`api`，Redis 停止不应让 API 退出；MySQL 健康后 API 才启动。README 给出 PowerShell 命令、默认凭据只用于开发的警告、首次改密流程和集成测试命令。

- [x] **Step 5: 执行完整验证**

Run:

```powershell
cd backend
gofmt -w .
go mod tidy
go mod verify
go test ./...
go vet ./...
go build -o "$env:TEMP\cbizdocsmanager-api.exe" ./cmd/api
docker compose -f ..\deploy\docker-compose.yml config --quiet
```

Expected: 所有命令通过。Docker daemon 可用且 `TEST_MYSQL_DSN` 已设置时，再运行：

```powershell
go test -tags=integration ./tests/integration -v
```

最后停止 Redis 后复跑认证集成闭环，结果仍通过；只允许 readiness data 中 Redis 状态变为 `down`。

---

## 规格自查

- 契约优先：Task 1 首先让 OpenAPI 测试因文件缺失失败，再创建规范。
- TDD：每个生产行为都在对应 Task 的失败测试后实现；配置、YAML、Dockerfile 属于 TDD 例外，但由契约/配置解析测试覆盖。
- 认证闭环：Task 3 覆盖登录、改密、刷新、退出、本人信息、状态即时校验。
- 组织闭环：Task 4 覆盖平台建组、唯一 owner、邀请和一次性注册。
- 运维闭环：Task 5 覆盖迁移、bootstrap、健康、Redis 降级、Docker 和真实 MySQL 集成。
- 首批排除项：计划不实现业务单据、Flutter 登录页、找回密码、多组切换、细粒度业务权限、限流、微服务或消息队列。
- 目录冲突：统一使用最新规格指定的 `backend/`，不创建旧 `server/`。
- Web Refresh Cookie/CSRF：本批契约采用跨端统一 JSON Refresh Token；HttpOnly Cookie 适配留给 Flutter Web 接入阶段，不在本批额外扩展。
- 审计：bootstrap、改密、建组、邀请、注册、Refresh/Logout 中至少账号/组织写操作写入只追加审计；登录失败不写敏感摘要。
- 工作区安全：不修改现有 Flutter 与改名文件，不执行自动 Git 提交。
