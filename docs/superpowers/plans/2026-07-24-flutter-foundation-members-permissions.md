# CBizDocsManager Flutter Foundation, Members and Permissions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在不依赖正式原型图的前提下，交付 Go 成员权限、辅助字典、Web Cookie 认证，以及 Flutter 跨端认证、缓存和 Outbox 的可测试纵向闭环。

**Architecture:** 后端沿用 Gin Handler -> Service -> GORM Repository，并以 MySQL 作为权限和租户数据的唯一事实源；原生端使用 JSON Refresh Token，Web 使用 HttpOnly Refresh Cookie、Origin 与双提交 CSRF。Flutter 采用 feature-first 结构，Riverpod 负责依赖和状态，Dio 负责网络与单飞刷新，Drift 只为 Android/Windows 提供按用户和组隔离的本地数据。

**Tech Stack:** Go 1.25.3、Gin、GORM/MySQL、OpenAPI 3.0、Flutter 3.44.6、Dart 3.12.2、Riverpod、GoRouter、Dio、flutter_secure_storage、Drift/SQLite、connectivity_plus、Docker Desktop。

---

## 文件边界

- `api/openapi/cbizdocsmanager-v1.yaml`：后端与 Flutter 共用的 HTTP 契约和稳定错误码。
- `backend/migrations/000002_members_permissions_dictionaries.*.sql`：成员版本、权限和字典表结构。
- `backend/internal/authorization/`：固定权限目录与实时授权判断。
- `backend/internal/member/`：成员生命周期、权限完整替换与审计。
- `backend/internal/dictionary/`：租户字典、规范化和乐观锁。
- `backend/internal/identity/web_handler.go`：Web Cookie 登录、刷新和退出适配。
- `backend/internal/infrastructure/httpserver/`：Origin、CSRF、CORS 与新增路由装配。
- `client/lib/core/`：跨 feature 的配置、错误、网络、认证、数据库和同步底座。
- `client/lib/features/members/`、`client/lib/features/dictionaries/`：领域模型、Repository 和 Riverpod Controller，不建立正式页面。
- `client/lib/app/`：启动恢复和最小 GoRouter 壳。

### Task 1: OpenAPI、错误码与第二版数据库迁移

**Files:**
- Modify: `api/openapi/cbizdocsmanager-v1.yaml`
- Modify: `backend/tests/openapi_contract_test.go`
- Modify: `backend/pkg/apperror/error.go`
- Modify: `backend/pkg/apperror/error_test.go`
- Modify: `backend/internal/organization/model.go`
- Create: `backend/migrations/000002_members_permissions_dictionaries.up.sql`
- Create: `backend/migrations/000002_members_permissions_dictionaries.down.sql`
- Modify: `backend/internal/infrastructure/database/migrate_test.go`

- [x] **Step 1: 先扩展契约和迁移失败测试**

在 `openapi_contract_test.go` 断言 12 条新增路径和 10 个稳定错误码；在迁移测试中断言 `memberships.version`、`membership_permissions`、`dictionary_entries`、复合外键、生成列 `parent_scope_id` 和唯一索引存在。

```go
var secondSliceOperations = []string{
    "POST /api/v1/auth/web/login", "POST /api/v1/auth/web/refresh", "POST /api/v1/auth/web/logout",
    "GET /api/v1/groups/members", "PATCH /api/v1/groups/members/{membership_id}/status",
    "GET /api/v1/groups/members/{membership_id}/permissions", "PUT /api/v1/groups/members/{membership_id}/permissions",
    "GET /api/v1/groups/permission-catalog", "GET /api/v1/dictionaries", "POST /api/v1/dictionaries",
    "PUT /api/v1/dictionaries/{dictionary_id}", "PATCH /api/v1/dictionaries/{dictionary_id}/status",
}
```

Run: `cd backend; go test ./tests ./pkg/apperror ./internal/infrastructure/database -count=1`

Expected: FAIL，报告新增路径、错误码和 `000002` 迁移缺失。

- [x] **Step 2: 写入稳定契约和错误映射**

OpenAPI 明确定义 `MemberData`、`PermissionCatalogItem`、`DictionaryEntryData`、分页 Envelope，以及版本字段；`apperror` 增加以下错误并保持 HTTP 映射固定：

```go
ErrMemberNotFound            // 404 MEMBER_NOT_FOUND
ErrMemberOwnerProtected      // 403 MEMBER_OWNER_PROTECTED
ErrMemberSelfForbidden       // 403 MEMBER_SELF_OPERATION_FORBIDDEN
ErrPermissionCodeInvalid     // 400 PERMISSION_CODE_INVALID
ErrDictionaryNotFound        // 404 DICTIONARY_NOT_FOUND
ErrDictionaryNameExists      // 409 DICTIONARY_NAME_EXISTS
ErrDictionaryParentInvalid   // 400 DICTIONARY_PARENT_INVALID
ErrResourceVersionConflict   // 409 RESOURCE_VERSION_CONFLICT
ErrCSRFInvalid               // 403 CSRF_INVALID
ErrOriginForbidden           // 403 ORIGIN_FORBIDDEN
```

- [x] **Step 3: 实现 `000002` 可逆迁移**

`memberships` 增加 `version BIGINT UNSIGNED NOT NULL DEFAULT 1` 和 `UNIQUE(id, group_id)`；`membership_permissions` 使用 `(membership_id, permission_code)` 唯一键及 `(membership_id, group_id)` 复合外键；`dictionary_entries` 使用：

```sql
parent_scope_id BIGINT UNSIGNED GENERATED ALWAYS AS (COALESCE(parent_id, 0)) STORED,
UNIQUE KEY uk_dictionary_scope_name
  (group_id, kind, parent_scope_id, normalized_name)
```

Down 迁移按外键逆序删除字典表、权限表、成员复合索引和 `version`。

- [x] **Step 4: 运行 Task 1 测试并提交**

Run: `cd backend; go test ./tests ./pkg/apperror ./internal/infrastructure/database -count=1`

Expected: PASS。

Commit: `git add api/openapi backend/tests backend/pkg/apperror backend/internal/organization/model.go backend/migrations backend/internal/infrastructure/database/migrate_test.go && git commit -m "feat: 扩展成员权限与字典契约"`

### Task 2: Authorization 固定权限引擎

**Files:**
- Create: `backend/internal/authorization/permission.go`
- Create: `backend/internal/authorization/permission_test.go`
- Create: `backend/internal/authorization/repository.go`
- Create: `backend/internal/authorization/repository_test.go`

- [x] **Step 1: 写授权矩阵失败测试**

表驱动测试覆盖 owner 隐式全权限、普通成员显式权限、停用成员、跨组资源、平台管理员和未知权限码；未知码必须在查询数据库前拒绝。

```go
tests := []struct{ name string; principal identity.Principal; groupID uint64; code Code; allowed bool }{
    {"owner", owner, 7, PermissionMemberManage, true},
    {"member granted", member, 7, PermissionDictionaryManage, true},
    {"cross group", member, 8, PermissionDictionaryManage, false},
    {"platform admin", platformAdmin, 7, PermissionMemberManage, false},
}
```

Run: `cd backend; go test ./internal/authorization -count=1`

Expected: FAIL，因为包尚不存在。

- [x] **Step 2: 实现权限注册表与查询接口**

```go
type Code string
const (
    PermissionDocumentViewOthers Code = "document.view_others"
    PermissionDocumentEditOthers Code = "document.edit_others"
    PermissionReportView Code = "report.view"
    PermissionMemberManage Code = "member.manage"
    PermissionDictionaryManage Code = "dictionary.manage"
    PermissionSettlementApprove Code = "settlement.approve"
)
func Catalog() []Code
func IsKnown(code Code) bool
type Repository interface { HasPermission(context.Context, uint64, uint64, Code) (bool, error) }
type Authorizer interface { Require(context.Context, identity.Principal, uint64, Code) error }
```

`Require` 只允许组内有效 owner 或拥有记录的有效 member，所有拒绝统一返回 `FORBIDDEN`；Repository 查询必须同时带 `membership_id`、`group_id` 和 active membership 条件。

- [x] **Step 3: GREEN 并提交**

Run: `cd backend; go test ./internal/authorization -count=1`

Expected: PASS。

Commit: `git add backend/internal/authorization && git commit -m "feat: 添加组内固定权限引擎"`

### Task 3: 成员生命周期与权限 API

**Files:**
- Create: `backend/internal/member/model.go`
- Create: `backend/internal/member/dto.go`
- Create: `backend/internal/member/repository.go`
- Create: `backend/internal/member/repository_test.go`
- Create: `backend/internal/member/service.go`
- Create: `backend/internal/member/service_test.go`
- Create: `backend/internal/member/handler.go`
- Create: `backend/internal/member/handler_test.go`

- [x] **Step 1: 写 Service 与 Handler 失败测试**

测试覆盖分页组隔离、`active <-> disabled`、进入 `removed`、removed 终态、owner 保护、自操作保护、普通管理员不能授权、权限 PUT 的幂等旧版本成功、差异集合旧版本冲突，以及状态改变撤销该用户全部 Refresh Session。

```go
type ReplacePermissionsRequest struct {
    PermissionCodes []authorization.Code `json:"permission_codes" validate:"dive,required"`
    Version uint64 `json:"version" validate:"required,min=1"`
}
type ChangeStatusRequest struct {
    Status organization.MembershipStatus `json:"status" validate:"required,oneof=active disabled removed"`
    Version uint64 `json:"version" validate:"required,min=1"`
}
```

Run: `cd backend; go test ./internal/member -count=1`

Expected: FAIL，因为成员模块尚不存在。

- [x] **Step 2: 实现事务 Repository**

Repository 公开 `List`、`GetPermissions`、`ChangeStatus`、`ReplacePermissions`。两个写方法先以 `FOR UPDATE` 锁定目标 membership；权限替换先比较集合，相同则直接返回当前版本，不同才校验版本、差异写入、版本 `+1`、追加审计。停用或移除时在同一事务更新 membership、版本、撤销目标用户全部未撤销会话并写审计。

- [x] **Step 3: 实现 Service 和 HTTP 适配**

```go
func (s *Service) List(ctx context.Context, p identity.Principal, q ListQuery) (Page, error)
func (s *Service) ChangeStatus(ctx context.Context, p identity.Principal, membershipID uint64, req ChangeStatusRequest) (Member, error)
func (s *Service) GetPermissions(ctx context.Context, p identity.Principal, membershipID uint64) (PermissionSet, error)
func (s *Service) ReplacePermissions(ctx context.Context, p identity.Principal, membershipID uint64, req ReplacePermissionsRequest) (PermissionSet, error)
func (s *Service) PermissionCatalog(ctx context.Context, p identity.Principal) ([]authorization.Code, error)
```

owner 可执行全部操作；普通成员必须有 `member.manage`，且仅可列表和改变其他普通成员状态；所有 Handler 使用统一 Envelope 与字段校验。

- [x] **Step 4: GREEN 并提交**

Run: `cd backend; go test ./internal/member ./internal/authorization -count=1`

Expected: PASS。

Commit: `git add backend/internal/member backend/internal/authorization && git commit -m "feat: 实现成员生命周期与权限管理"`

### Task 4: 辅助字典 API

**Files:**
- Create: `backend/internal/dictionary/model.go`
- Create: `backend/internal/dictionary/dto.go`
- Create: `backend/internal/dictionary/normalize.go`
- Create: `backend/internal/dictionary/normalize_test.go`
- Create: `backend/internal/dictionary/repository.go`
- Create: `backend/internal/dictionary/repository_test.go`
- Create: `backend/internal/dictionary/service.go`
- Create: `backend/internal/dictionary/service_test.go`
- Create: `backend/internal/dictionary/handler.go`
- Create: `backend/internal/dictionary/handler_test.go`

- [x] **Step 1: 写规范化与业务规则失败测试**

覆盖 trim、连续 Unicode 空白折叠、NFKC、拉丁小写；覆盖六种 kind、仅 customer 接收电话、product_model 必须关联同组 active product_name、唯一冲突、版本冲突、普通成员只能读 active、跨组拒绝。

```go
func TestNormalizeName(t *testing.T) {
    if got := NormalizeName("  Ａcme\t  公司 "); got != "acme 公司" { t.Fatalf("got %q", got) }
}
```

Run: `cd backend; go test ./internal/dictionary -count=1`

Expected: FAIL，因为字典模块尚不存在。

- [x] **Step 2: 实现模型、Repository 与 Service**

```go
type Kind string
const (
    KindSupplierCompany Kind = "supplier_company"; KindCustomer Kind = "customer"
    KindProductName Kind = "product_name"; KindProductModel Kind = "product_model"
    KindUnit Kind = "unit"; KindShippingUnit Kind = "shipping_unit"
)
type Entry struct { ID, GroupID uint64; Kind Kind; Name, NormalizedName string; ParentID *uint64; ContactPhone *string; Status Status; Version uint64 }
```

所有 Repository 条件都包含 `group_id`；管理写操作要求 owner 或 `dictionary.manage`；唯一键映射为 `DICTIONARY_NAME_EXISTS`，乐观锁 `RowsAffected == 0` 映射为 `RESOURCE_VERSION_CONFLICT`，停用不删除数据。

- [x] **Step 3: 实现 Handler、GREEN 并提交**

GET 支持 `kind`、`parent_id`、`status`、`keyword`、`page`、`page_size`，稳定排序为 `kind ASC, parent_scope_id ASC, normalized_name ASC, id ASC`。

Run: `cd backend; go test ./internal/dictionary ./internal/authorization -count=1`

Expected: PASS。

Commit: `git add backend/internal/dictionary && git commit -m "feat: 实现组内辅助字典"`

### Task 5: Web Cookie、Origin 与 CSRF 认证

**Files:**
- Modify: `backend/pkg/config/config.go`
- Modify: `backend/pkg/config/config_test.go`
- Modify: `backend/config/config.yaml`
- Modify: `backend/.env.example`
- Create: `backend/internal/identity/web_handler.go`
- Create: `backend/internal/identity/web_handler_test.go`
- Modify: `backend/internal/infrastructure/httpserver/middleware.go`
- Modify: `backend/internal/infrastructure/httpserver/middleware_test.go`

- [x] **Step 1: 写配置与 Cookie 安全失败测试**

测试生产环境拒绝 `secure=false`、拒绝无法与 Web/API 共用的 Cookie 父域、拒绝 Origin 白名单中的 `*`；Handler 测试断言 Refresh Token 不进入 JSON，Refresh Cookie 为 HttpOnly，CSRF Cookie 可读，并覆盖错误 Origin、缺失/不匹配 CSRF 和清理 Cookie。

Run: `cd backend; go test ./pkg/config ./internal/identity ./internal/infrastructure/httpserver -run "Web|Cookie|CSRF|Origin" -count=1`

Expected: FAIL，缺少 WebAuth 配置和处理器。

- [x] **Step 2: 实现 WebAuth 配置和 Origin/CSRF 守卫**

```go
type WebAuthConfig struct {
    Enabled bool; Secure bool; AllowedOrigins []string
    CookieDomain string; RefreshCookieName string; CSRFCookieName string
}
```

Origin 使用 `url.Parse` 后按 scheme/host/port 精确匹配；refresh/logout 同时要求允许 Origin 与 `X-CSRF-Token == csrf cookie`，使用常量时间比较。生产 Refresh Cookie 固定 `HttpOnly=true, SameSite=Lax, Path=/api/v1/auth/web`，CSRF Cookie 固定 `HttpOnly=false, SameSite=Lax, Path=/`。

- [x] **Step 3: 实现 Web 登录、刷新、退出**

Web Handler 复用现有 Identity Service：登录/刷新把 `TokenPair.RefreshToken` 写 Cookie 后，从 JSON 数据中移除；退出从 Refresh Cookie 解析并撤销该会话，不依赖 Access Token；成功和失败退出都清理两个 Cookie，且日志不包含 Cookie 或 Token。

- [x] **Step 4: GREEN 并提交**

Run: `cd backend; go test ./pkg/config ./internal/identity ./internal/infrastructure/httpserver -count=1`

Expected: PASS。

Commit: `git add backend/pkg/config backend/config backend/.env.example backend/internal/identity backend/internal/infrastructure/httpserver && git commit -m "feat: 添加 Web Cookie 认证防护"`

### Task 6: 路由装配与真实 MySQL 集成验证

**Files:**
- Modify: `backend/internal/infrastructure/httpserver/router.go`
- Modify: `backend/internal/infrastructure/httpserver/router_test.go`
- Modify: `backend/cmd/api/main.go`
- Create: `backend/tests/integration/member_dictionary_flow_test.go`
- Modify: `backend/tests/openapi_contract_test.go`

- [x] **Step 1: 写路由与真实行为失败测试**

路由测试断言新增 12 条路由及守卫顺序；集成测试创建临时数据库、执行 000001+000002、建立 owner/member，验证权限替换、停用即时阻止认证、字典生成列唯一约束和跨组隔离。

Run: `cd backend; go test ./internal/infrastructure/httpserver ./cmd/api -count=1`

Expected: FAIL，新增处理器尚未装配。

- [x] **Step 2: 装配依赖和路由**

`RouteHandlers` 增加 Web auth、成员和字典处理器；`main.go` 构造 authorization/member/dictionary Repository、Service、Handler。平台管理员只进入 `/platform`，租户 API 统一经过 Authentication、RequirePasswordChanged 和组身份检查。

- [x] **Step 3: 检查 Docker 并运行真实 MySQL 集成测试**

先执行：

```powershell
docker context show
docker ps -a
docker inspect MySQL --format '{{json .State}} {{json .NetworkSettings.Ports}}'
```

若 `MySQL` 仍停止，只启动既有 `MySQL` 容器，不删除、不重建；从本地安全环境构造 `TEST_MYSQL_DSN`，不得把密码回显或写入仓库。测试完成后恢复容器原停止状态。

Run: `cd backend; go test -tags=integration ./tests/integration -run "Member|Dictionary" -count=1 -v`

Expected: PASS，且临时数据库由测试清理。

- [x] **Step 4: 全量 Go 验证并提交**

Run: `cd backend; go test ./... -count=1; go vet ./...`

Expected: 两条命令均 PASS。

Commit: `git add backend/internal/infrastructure/httpserver backend/cmd/api backend/tests && git commit -m "feat: 装配成员字典纵向接口"`

### Task 7: Flutter 依赖、配置、Envelope 与领域错误

**Files:**
- Modify: `client/pubspec.yaml`
- Modify: `client/pubspec.lock`
- Create: `client/lib/core/config/app_config.dart`
- Create: `client/lib/core/error/app_failure.dart`
- Create: `client/lib/core/network/api_envelope.dart`
- Create: `client/lib/core/network/error_mapper.dart`
- Create: `client/test/core/network/api_envelope_test.dart`
- Create: `client/test/core/network/error_mapper_test.dart`

- [x] **Step 1: 加依赖并写 DTO/错误失败测试**

添加 `flutter_riverpod`、`riverpod_annotation`、`go_router`、`dio`、`flutter_secure_storage`、`drift`、`sqlite3_flutter_libs`、`path_provider`、`path`、`connectivity_plus`，开发依赖添加 `build_runner`、`drift_dev`、`riverpod_generator`、`mocktail`。

测试解析成功、字段错误、未知错误码和无响应 DioException。

```dart
sealed class AppFailure { const AppFailure(this.message, {this.requestId}); final String message; final String? requestId; }
final class UnauthenticatedFailure extends AppFailure { const UnauthenticatedFailure(super.message, {super.requestId}); }
final class ForbiddenFailure extends AppFailure { const ForbiddenFailure(super.message, {super.requestId}); }
final class ValidationFailure extends AppFailure { const ValidationFailure(super.message, this.fields, {super.requestId}); final Map<String, String> fields; }
final class ConflictFailure extends AppFailure { const ConflictFailure(super.message, {super.requestId}); }
final class NetworkFailure extends AppFailure { const NetworkFailure(super.message); }
final class ServerFailure extends AppFailure { const ServerFailure(super.message, {super.requestId}); }
```

Run: `cd client; flutter test test/core/network`

Expected: FAIL，因为 core 类型尚不存在。

- [x] **Step 2: 实现配置、Envelope 与错误映射**

`AppConfig.fromEnvironment()` 读取 `API_BASE_URL`，默认 Android 模拟器 `http://10.0.2.2:8080`、Windows/Web `http://127.0.0.1:8080`；`ApiEnvelope<T>` 强制读取 `code/message/data/request_id`，错误映射只在 core 层判断 Dio/HTTP。

- [x] **Step 3: GREEN 并提交**

Run: `cd client; flutter pub get; flutter test test/core/network; flutter analyze`

Expected: PASS。

Commit: `git add client/pubspec.yaml client/pubspec.lock client/lib/core client/test/core && git commit -m "feat: 建立 Flutter 网络数据基础"`

### Task 8: Flutter Credential Store、认证 Repository 与单飞刷新

**Files:**
- Create: `client/lib/core/auth/auth_models.dart`
- Create: `client/lib/core/auth/credential_store.dart`
- Create: `client/lib/core/auth/native_credential_store.dart`
- Create: `client/lib/core/auth/web_credential_store.dart`
- Create: `client/lib/core/auth/auth_repository.dart`
- Create: `client/lib/core/network/api_client.dart`
- Create: `client/test/core/auth/auth_repository_test.dart`
- Create: `client/test/core/network/api_client_test.dart`

- [x] **Step 1: 写跨平台凭据和并发 401 失败测试**

原生 fake 验证 Refresh Token 写入、读取、删除；Web adapter 不保存 Refresh Token。使用受控 Dio adapter 同时返回三个 401，断言只调用一次 refresh、三个请求各重试一次；refresh 失败时统一清理且不递归。

Run: `cd client; flutter test test/core/auth test/core/network/api_client_test.dart`

Expected: FAIL，因为认证基础类尚不存在。

- [x] **Step 2: 实现平台适配和 AuthRepository**

```dart
abstract interface class CredentialStore {
  Future<String?> readRefreshToken();
  Future<void> writeRefreshToken(String token);
  Future<void> clear();
}
abstract interface class AuthRepository {
  Future<AuthSession> login(String username, String password);
  Future<AuthSession> restore();
  Future<void> logout();
}
```

Android/Windows 使用 `FlutterSecureStorage`；Web 的读写方法不接触 token，由 `/auth/web/*` Cookie 流程处理。Access Token 只存在内存 Session；安全存储异常直接返回失败，不回退明文存储。

- [x] **Step 3: 实现单飞刷新拦截器**

`ApiClient` 持有一个可空 `Future<AuthSession>`；第一个 401 创建 refresh Future，其余 await 同一个 Future。刷新成功时仅重试原请求一次并标记 `_retried=true`；刷新 endpoint 自身、已重试请求或刷新失败都不再刷新。

- [x] **Step 4: GREEN 并提交**

Run: `cd client; flutter test test/core/auth test/core/network; flutter analyze`

Expected: PASS。

Commit: `git add client/lib/core/auth client/lib/core/network client/test/core && git commit -m "feat: 实现 Flutter 跨端认证与单飞刷新"`

### Task 9: Riverpod 认证状态与 GoRouter 守卫

**Files:**
- Create: `client/lib/app/bootstrap.dart`
- Create: `client/lib/app/app.dart`
- Create: `client/lib/app/router.dart`
- Create: `client/lib/core/auth/auth_controller.dart`
- Modify: `client/lib/main.dart`
- Delete: `client/test/widget_test.dart`
- Create: `client/test/core/auth/auth_controller_test.dart`
- Create: `client/test/app/router_test.dart`

- [x] **Step 1: 写启动恢复与路由失败测试**

认证状态固定为 `restoring`、`authenticated`、`unauthenticated`；测试恢复成功/失败、登录、退出、refresh 失效，以及未登录跳 `/login`、必须改密跳 `/change-password`、正常认证进入 `/home`。

Run: `cd client; flutter test test/core/auth/auth_controller_test.dart test/app/router_test.dart`

Expected: FAIL，因为 Controller 和 Router 尚不存在。

- [x] **Step 2: 实现 ProviderScope、Controller 和最小路由壳**

```dart
enum AuthPhase { restoring, authenticated, unauthenticated }
final class AuthState { const AuthState(this.phase, {this.session}); final AuthPhase phase; final AuthSession? session; }
```

`bootstrap()` 先建立依赖再 `runApp(ProviderScope(...))`；路由页只使用 `Scaffold` 和语义文本作为测试壳，不决定正式 UI。redirect 在 restoring 时进入 `/splash`，且避免当前目标相同导致循环。

- [x] **Step 3: GREEN 并提交**

Run: `cd client; flutter test; flutter analyze`

Expected: PASS。

Commit: `git add client/lib client/test && git commit -m "feat: 添加 Flutter 认证状态与路由守卫"`

### Task 10: Drift 缓存、草稿与 Outbox 状态机

**Files:**
- Create: `client/lib/core/database/app_database.dart`
- Create: `client/lib/core/database/app_database.g.dart`
- Create: `client/lib/core/database/database_connection.dart`
- Create: `client/lib/core/database/database_connection_native.dart`
- Create: `client/lib/core/database/database_connection_web.dart`
- Create: `client/lib/core/sync/outbox.dart`
- Create: `client/test/core/database/app_database_test.dart`
- Create: `client/test/core/sync/outbox_test.dart`

- [x] **Step 1: 写 schema、隔离和状态转换失败测试**

内存 Drift 测试五张表、同用户同组覆盖缓存、用户切换不可见、草稿 CRUD；Outbox 测试合法转换 `pending -> syncing -> succeeded|retryable_failed|conflict|permanently_failed` 和 `retryable_failed -> pending`，非法转换抛领域异常。

Run: `cd client; flutter test test/core/database test/core/sync`

Expected: FAIL，因为 Drift 数据库尚不存在。

- [x] **Step 2: 实现 native 数据库与 Web 空实现边界**

表为 `cached_members`、`cached_member_permissions`、`cached_dictionary_entries`、`draft_records`、`outbox_operations`。每张缓存和 Outbox 表的查询键都包含 `userId/groupId`；Outbox 额外保存 `clientRequestId/resourceType/operationType/payload/attemptCount/nextRetryAt/errorSummary/status`。

Web 连接模块抛出明确的 `UnsupportedError('Web offline database is disabled in phase 1')`，且 bootstrap 在 Web 不实例化 Drift。

- [x] **Step 3: 生成代码、GREEN 并提交**

Run: `cd client; dart run build_runner build; flutter test test/core/database test/core/sync; flutter analyze`

Expected: PASS，生成文件无未提交差异。

Commit: `git add client/lib/core/database client/lib/core/sync client/test/core && git commit -m "feat: 建立 Flutter 缓存与 Outbox 底座"`

### Task 11: Flutter 成员与字典 Repository、Controller

**Files:**
- Create: `client/lib/features/members/domain/member.dart`
- Create: `client/lib/features/members/data/member_repository.dart`
- Create: `client/lib/features/members/application/member_controller.dart`
- Create: `client/lib/features/dictionaries/domain/dictionary_entry.dart`
- Create: `client/lib/features/dictionaries/data/dictionary_repository.dart`
- Create: `client/lib/features/dictionaries/application/dictionary_controller.dart`
- Create: `client/test/features/members/member_repository_test.dart`
- Create: `client/test/features/members/member_controller_test.dart`
- Create: `client/test/features/dictionaries/dictionary_repository_test.dart`
- Create: `client/test/features/dictionaries/dictionary_controller_test.dart`

- [x] **Step 1: 写在线优先、本地回退与在线写失败测试**

Android/Windows 查询远端成功后覆盖当前 user/group 缓存；网络失败返回同 scope 缓存；服务器业务错误不得伪装为离线数据。成员状态/权限和字典管理写操作在离线时返回 `NetworkFailure`，不得写入 Outbox。Web 查询只走远端。

Run: `cd client; flutter test test/features`

Expected: FAIL，因为 feature Repository 尚不存在。

- [x] **Step 2: 实现成员 Repository 和 Controller**

```dart
abstract interface class MemberRepository {
  Future<List<Member>> listMembers();
  Future<Member> changeStatus(int membershipId, MemberStatus status, int version);
  Future<MemberPermissions> getPermissions(int membershipId);
  Future<MemberPermissions> replacePermissions(int membershipId, Set<String> codes, int version);
}
```

Controller 只暴露加载、刷新和在线写状态，不包含 Widget；409 映射为可供未来 UI 提示重新加载的 `ConflictFailure`。

- [x] **Step 3: 实现字典 Repository 和 Controller**

```dart
abstract interface class DictionaryRepository {
  Future<List<DictionaryEntry>> list(DictionaryQuery query);
  Future<DictionaryEntry> create(DictionaryDraft draft);
  Future<DictionaryEntry> update(int id, DictionaryDraft draft, int version);
  Future<DictionaryEntry> changeStatus(int id, DictionaryStatus status, int version);
}
```

缓存保留 parent/contact/status/version，key 含 user/group；connectivity_plus 只触发刷新机会，最终以真实 HTTP 结果判断在线状态。

- [x] **Step 4: GREEN 并提交**

Run: `cd client; flutter test test/features; flutter analyze`

Expected: PASS。

Commit: `git add client/lib/features client/test/features && git commit -m "feat: 添加 Flutter 成员与字典数据层"`

### Task 12: 完整验证、运行文档与教学变更记录

**Files:**
- Modify: `backend/README.md`
- Modify: `client/README.md`
- Modify: `README.md`
- Create: `docs/update/2026-07-24-跨端基础设施与成员权限.md`
- Modify: `docs/superpowers/plans/2026-07-24-flutter-foundation-members-permissions.md`

- [x] **Step 1: 更新可执行文档**

后端 README 记录 Web Cookie 开发/生产约束、成员权限和字典测试命令；客户端 README 解释 Flutter 环境、`--dart-define=API_BASE_URL=...`、Android 模拟器与 Windows 地址差异、代码生成和三平台运行命令。根 README 只更新当前已完成能力和入口链接。

- [x] **Step 2: 使用 teaching-change-notes 技能写教学记录**

记录 Go 与 Flutter 的对应边界、原生和 Web 凭据差异、单飞刷新、Riverpod/GoRouter、Drift scope、Outbox 状态机，以及主人后续接正式 UI 时应从 Controller 开始而不是直接调用 Dio。

- [x] **Step 3: 执行最终静态与单元验证**

Run:

```powershell
Set-Location backend
go test ./... -count=1
go vet ./...
Set-Location ../client
dart run build_runner build
flutter analyze
flutter test
```

Expected: 所有命令退出码为 0。

- [ ] **Step 4: 执行真实 MySQL 和平台构建验证**

真实 MySQL、Android 和 Web 已通过；Windows 因本机未启用开发者模式而无法创建插件符号链接，待启用后重跑。

按 Task 6 的 Docker 状态保护流程运行全部 integration tests；随后执行：

```powershell
Set-Location client
flutter build apk --debug
flutter build windows --debug
flutter build web
```

Expected: 三个平台构建成功；Web 构建不包含 Drift SQLite 业务离线初始化。

- [x] **Step 5: 自查、提交和普通推送 main**

检查 `git diff --check`、`git status --short`、OpenAPI 解析、无 Token/密码进入 Git；把计划内完成项逐个改为 `[x]`。

Commit: `git add README.md backend/README.md client/README.md docs/update docs/superpowers/plans && git commit -m "docs: 记录跨端基础设施与成员权限"`

Push: `git push origin main`。若远端分叉则停止并请主人决定，禁止 force push。
