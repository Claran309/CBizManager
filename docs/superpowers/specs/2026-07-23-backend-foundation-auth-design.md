# ProjectF 后端基础框架与认证设计

## 1. 目标

在产品原型尚未交付时，先建立可持续扩展的 Go 单体后端骨架，并完成认证、公司/组初始化、主账号邀请子账号、全局平台管理员和基础运维能力。

首批交付必须采用契约优先：先完成并校验 OpenAPI 规范，再根据契约编写测试、数据库迁移和 Go 实现。

## 2. 已确认业务规则

- 系统不开放“任意用户注册并创建公司”。
- 平台运营人员创建公司/组，同时指定该组唯一的主账号。
- 主账号就是组内管理员，默认拥有组内全部业务与管理权限。
- 主账号生成一次性邀请码，子账号凭邀请码注册并自动加入对应组。
- 普通子账号不能自行创建组，也不能指定或更换主账号。
- 全局平台管理员不属于任何业务组，不默认拥有租户业务数据访问权限。
- 开发环境首次启动需要幂等创建全局平台管理员 `admin / 123456`。

## 3. 参考项目码风

实现风格融合主人现有两个 Go 项目：

- 沿用 `ClaranCloudDisk` 的 Gin 单体形态、Handler → Service → Repository 分层、构造函数注入、中文业务注释和 Zap 日志习惯。
- 沿用 `ClaranAIM` 的 `context.Context` 传递、接口化 Repository、配置文件加环境变量覆盖、Redis 可选降级、启动健康检查和明确的 Access/Refresh Token 区分。
- 不照搬参考项目中的历史问题：业务错误不得全部返回 HTTP 500，不记录完整 Token 或密码，Refresh Token 必须支持服务端撤销和轮换，Handler 不包含业务逻辑。

Go 模块位于 `backend/`，模块名使用 `ProjectF/backend`。

## 4. 工程结构

```text
backend/
├─ cmd/api/main.go
├─ config/config.yaml
├─ internal/
│  ├─ identity/
│  │  ├─ handler.go
│  │  ├─ service.go
│  │  ├─ repository.go
│  │  ├─ model.go
│  │  └─ dto.go
│  ├─ organization/
│  │  ├─ handler.go
│  │  ├─ service.go
│  │  ├─ repository.go
│  │  ├─ model.go
│  │  └─ dto.go
│  ├─ platform/
│  │  ├─ handler.go
│  │  ├─ service.go
│  │  └─ dto.go
│  └─ infrastructure/
│     ├─ database/
│     ├─ cache/
│     └─ httpserver/
├─ pkg/
│  ├─ apperror/
│  ├─ config/
│  ├─ jwt/
│  ├─ logger/
│  ├─ password/
│  ├─ requestid/
│  └─ response/
├─ migrations/
├─ tests/
├─ .env.example
├─ Dockerfile
├─ go.mod
└─ go.sum

api/openapi/projectf-v1.yaml
deploy/docker-compose.yml
```

业务模块内部继续保持主人熟悉的分层，不建立微服务、RPC、Etcd 或消息队列。

## 5. 首批 API 契约

OpenAPI 文件固定为 `api/openapi/projectf-v1.yaml`，使用 `/api/v1` 前缀，至少定义以下接口：

```text
POST /api/v1/auth/login
POST /api/v1/auth/register
POST /api/v1/auth/refresh
POST /api/v1/auth/logout
GET  /api/v1/auth/me
PUT  /api/v1/auth/password

POST /api/v1/platform/groups

POST /api/v1/groups/invitations

GET  /health/live
GET  /health/ready
```

接口语义：

- `auth/register` 必须携带有效邀请码，不接受创建公司字段。
- `platform/groups` 由全局平台管理员调用，在同一事务中创建组、主账号和主账号成员关系；创建时设置临时密码，主账号首次登录后必须修改密码。
- `groups/invitations` 仅允许该组主账号调用；邀请码默认七天过期且只能成功使用一次。
- `auth/password` 用于修改当前账号密码，也用于全局管理员首次登录后更换默认密码。
- `auth/me` 返回用户、所属组、账号类型和是否必须修改密码，不返回权限全集或密码哈希。

## 6. 统一响应和错误处理

成功响应：

```json
{
  "code": "OK",
  "message": "success",
  "data": {},
  "request_id": "..."
}
```

失败响应：

```json
{
  "code": "AUTH_INVALID_CREDENTIALS",
  "message": "用户名或密码错误",
  "data": null,
  "request_id": "...",
  "field_errors": []
}
```

HTTP 状态码与错误类别保持一致：参数错误使用 400，未登录使用 401，无权限使用 403，资源不存在使用 404，重复资源使用 409，服务端未知错误使用 500。

首批稳定业务错误码包括：

- `VALIDATION_FAILED`
- `AUTH_INVALID_CREDENTIALS`
- `AUTH_TOKEN_EXPIRED`
- `AUTH_REFRESH_INVALID`
- `AUTH_PASSWORD_CHANGE_REQUIRED`
- `USER_USERNAME_EXISTS`
- `INVITATION_INVALID`
- `INVITATION_EXPIRED`
- `INVITATION_USED`
- `GROUP_NAME_EXISTS`
- `FORBIDDEN`
- `INTERNAL_ERROR`

Service 返回可判断的应用错误，Handler 只负责绑定请求、调用 Service 和映射响应。

## 7. 数据模型

### users

- `id`: BIGINT UNSIGNED 自增主键。
- `username`: 唯一用户名。
- `password_hash`: bcrypt 哈希。
- `display_name`: 展示名称。
- `account_type`: `platform_admin`、`group_owner`、`member`。
- `status`: `active`、`disabled`。
- `must_change_password`: 是否必须修改默认密码。
- `created_at`、`updated_at`。

### groups

- `id`、`name`、`status`。
- `owner_user_id`: 当前唯一主账号。
- `created_by`: 创建该组的平台管理员。
- `created_at`、`updated_at`。

### memberships

- `id`、`group_id`、`user_id`。
- `member_type`: `owner`、`member`。
- `status`: `active`、`disabled`、`removed`。
- `(group_id, user_id)` 唯一索引。

### invitations

- `id`、`group_id`、`created_by`。
- `code_hash`: 邀请码哈希，数据库不保存可直接使用的明文邀请码。
- `expires_at`、`used_at`、`used_by`、`status`。

### refresh_sessions

- `id`、`user_id`、可空 `group_id`。
- `token_hash`: Refresh Token 哈希。
- `expires_at`、`revoked_at`、`replaced_by_session_id`。
- `created_at`、`last_used_at`。

### audit_logs

- `id`、可空 `group_id`、`operator_user_id`。
- `action`、`resource_type`、`resource_id`、`summary`、`created_at`。
- 只追加，不向普通业务接口提供修改能力。

数据库结构通过 SQL 迁移管理，运行时不依赖 GORM `AutoMigrate` 修改生产表。

## 8. 认证与会话

- Access Token 使用 HS256 JWT，默认有效期 30 分钟，可配置。
- JWT 只保存 `user_id`、可空 `group_id`、`account_type`、`session_id`、签发与过期时间，不写入完整权限集合。
- Refresh Token 使用密码学安全的随机字符串；数据库只保存 SHA-256 哈希，默认有效期七天。
- 每次刷新都撤销旧 Refresh Session 并签发新 Refresh Token，防止重放。
- Logout 撤销当前 Refresh Session；Access Token 在短有效期结束后自然失效。
- 用户、成员关系或组被禁用后，刷新必须失败；受保护接口还要根据数据库状态进行必要校验。
- 密码使用 bcrypt；日志、响应和审计摘要都不得出现密码、完整 JWT 或 Refresh Token。

## 9. 全局平台管理员引导

开发环境默认配置：

```env
BOOTSTRAP_ADMIN_USERNAME=admin
BOOTSTRAP_ADMIN_PASSWORD=123456
```

启动行为：

1. 查询 `platform_admin` 是否已经存在。
2. 不存在时创建 `admin`，密码保存为 bcrypt 哈希，`must_change_password=true`。
3. 已存在时不修改密码、不重复创建。
4. 使用默认密码启动时输出安全警告，但不打印密码内容。
5. 正式环境要求显式提供环境变量，不允许静默使用默认密码。

全局管理员首次登录可以获得受限会话，但除查看自身信息、修改密码和退出外，其他受保护接口返回 `AUTH_PASSWORD_CHANGE_REQUIRED`。

由平台管理员创建的主账号同样设置 `must_change_password=true`，首次登录完成改密后才能生成邀请码或操作组内业务。

## 10. 配置、日志和依赖降级

- 使用 Viper 加载 `config/config.yaml`，`.env` 与系统环境变量覆盖敏感配置。
- Zap 输出结构化日志，至少包含时间、级别、请求 ID、路径、方法、耗时和错误码。
- MySQL 是认证核心依赖；就绪检查在数据库不可用时失败。
- Redis 第一阶段只初始化可选连接和健康状态，不参与登录、注册、邀请码或 Refresh Session 的正确性。
- Redis 不可用时记录 Warn 并继续启动，核心业务直接使用 MySQL。
- 提供 Recovery、Request ID、访问日志、CORS、JWT 认证和平台管理员鉴权中间件。

## 11. 测试策略

采用测试驱动开发：先写失败测试，再实现最小代码。

### 单元测试

- 全局管理员幂等初始化，不覆盖已有密码。
- 邀请码注册成功、无效、过期、已使用和并发重复使用。
- 用户名重复。
- 密码哈希和校验。
- 登录成功、错误密码、禁用账号、强制改密。
- Refresh Token 轮换、撤销和重放拒绝。
- 平台管理员、主账号、普通子账号的鉴权边界。

### Handler 测试

- 请求绑定、字段错误、HTTP 状态码、稳定错误码和响应结构。
- JWT 中间件、Request ID 和密码修改限制。

### 集成测试

- SQL 迁移可从空 MySQL 创建完整表结构。
- 创建组、主账号和成员关系的事务原子性。
- 邀请码只能消费一次。
- Refresh Session 轮换事务。

不依赖 Docker 的单元与 Handler 测试必须能够直接通过 `go test ./...` 运行；MySQL 集成测试单独提供命令。

## 12. 实施顺序

1. 编写并校验 `api/openapi/projectf-v1.yaml`。
2. 根据 OpenAPI 创建请求、响应和错误契约测试。
3. 初始化 Go 模块、配置、日志、统一响应和 HTTP 中间件。
4. 创建首版 SQL 迁移和 Repository 接口。
5. 按 TDD 实现全局管理员引导、登录、改密、Refresh 和 Logout。
6. 按 TDD 实现平台创建组和主账号。
7. 按 TDD 实现邀请码生成与子账号注册。
8. 增加 Dockerfile、开发 Compose、健康检查和启动说明。
9. 执行格式化、单元测试、OpenAPI 校验和构建验证。

## 13. 首批不包含

- 入库、出库、结算等业务单据 API。
- Flutter 登录和注册页面。
- 邮箱、短信验证码及找回密码。
- 一个用户加入多个业务组及主动切换组。
- 复杂细粒度业务权限配置。
- Redis 缓存、限流和分布式锁的业务接入。
- 微服务、消息队列、Etcd、Kubernetes。

## 14. 完成标准

- OpenAPI 规范可以被工具解析和校验。
- `go test ./...` 通过。
- 后端可以构建并启动。
- 空数据库迁移后可以幂等创建全局管理员。
- 全局管理员修改默认密码后能够创建组和主账号。
- 主账号能够生成邀请码，子账号能够凭邀请码注册并登录。
- Refresh Token 可轮换、撤销，旧 Token 重放被拒绝。
- Redis 停止时上述认证闭环仍然可用。
- 所有接口返回统一响应并携带 Request ID。
