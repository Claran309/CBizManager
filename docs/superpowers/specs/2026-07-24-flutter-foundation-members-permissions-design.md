# CBizDocsManager 跨端基础设施、成员权限与辅助字典设计

## 1. 目标

在业务原型图尚未交付时，先完成不依赖视觉布局的第二批纵向闭环：

1. 为 Android、Windows 和 Web 建立可复用的 Flutter 网络、认证、状态管理和错误处理基础设施。
2. 为 Android、Windows 建立本地数据库、缓存、草稿和 Outbox 同步底座；Web 一期保持在线使用。
3. 在 Go 后端完成普通成员生命周期、细粒度权限和辅助填写字典能力。
4. 将后端 OpenAPI、Flutter Repository 和自动化测试作为同一纵向能力同时交付，避免后端与客户端长期分离开发。

本批不设计正式页面，不猜测原型图中的导航、表单布局、颜色、字号或交互细节。

## 2. 实施策略

采用纵向闭环，而不是先铺设全部后端或全部 Flutter 空骨架。每项能力按照以下顺序完成：

```text
业务规则与 OpenAPI
  -> 后端迁移、Repository、Service、Handler
  -> Flutter DTO、数据源、Repository、状态
  -> 单元、契约和集成测试
```

首批纵向切片依次为：

1. 跨端认证与安全凭据。
2. 成员生命周期和权限。
3. 辅助填写字典。
4. Android/Windows 本地存储与通用 Outbox 基础设施。

## 3. 范围边界

### 3.1 本批包含

- Android/Windows JSON Refresh Token 认证闭环。
- Web HttpOnly Cookie Refresh Token 认证闭环。
- Flutter 登录状态恢复、单飞刷新、退出清理和路由守卫。
- 成员列表、停用、恢复和软移除。
- 主账号为普通成员配置权限。
- 公司、客户、品名、型号、单位和出货单位字典。
- Android/Windows Drift 数据库、缓存和 Outbox 状态机。
- OpenAPI、Go、Dart 单元测试和真实 MySQL 集成测试。

### 3.2 本批不包含

- 正式登录页、成员管理页、字典管理页或业务单据页面。
- 入库、出库、结算、审批、资金和报表业务实现。
- Web 业务离线数据库与 Web 离线同步。
- 普通成员提交新字典词条申请的工作流。
- 后台任务调度器、消息队列、微服务或 Kubernetes。
- 自定义角色模板、任意表达式权限或跨组账号切换。

## 4. 总体架构

```text
Flutter feature
  -> Riverpod controller
  -> Repository interface
     -> Remote data source (Dio/OpenAPI)
     -> Local data source (Drift, native only)
     -> Credential store (platform adapter)
  -> Go HTTP Handler
  -> Service authorization and business rules
  -> GORM Repository transaction
  -> MySQL source of truth
```

后端继续使用现有 Handler -> Service -> Repository 分层。Flutter 使用 feature-first 目录，但共享设施集中在 `core/`，业务 feature 不直接依赖 Dio、Drift 或平台 API。

## 5. 后端模块

### 5.1 authorization

职责：

- 维护后端认可的固定权限码注册表。
- 根据 Principal、组、资源归属、操作和权限码给出授权结论。
- 为 Handler 中间件和 Service 提供统一授权接口。
- 禁止客户端提交未注册权限码。

首批稳定权限码：

| 权限码 | 含义 |
|---|---|
| `document.view_others` | 查看同组其他成员创建的单据 |
| `document.edit_others` | 编辑同组其他成员创建的单据 |
| `report.view` | 查看组内汇总和报表 |
| `member.manage` | 查看并管理普通成员状态 |
| `dictionary.manage` | 新增、修改和停用辅助字典 |
| `settlement.approve` | 审批结算申请 |

本批只实际使用 `member.manage` 和 `dictionary.manage`，其余权限码提前固定供后续业务模块引用，不提前实现对应业务。

主账号不需要为自己持久化权限记录，后端将其解释为组内全部权限。平台管理员不属于业务组，不能依靠平台身份访问租户业务数据。

### 5.2 member

职责：

- 分页查询当前组成员。
- 停用、恢复和软移除普通成员。
- 查询成员权限。
- 由主账号整体替换某个普通成员的权限集合。

规则：

- 仅主账号可以授予或撤销权限。
- 拥有 `member.manage` 的普通成员可以查询成员并改变普通成员状态，但不能管理主账号、不能授权、不能操作自己。
- 主账号不能通过成员接口被停用或移除；主账号变更继续由平台流程负责。
- 移除使用 membership 的 `removed` 状态，不删除用户、历史业务或审计记录。
- 合法状态转换只有 `active <-> disabled` 以及 `active|disabled -> removed`；`removed` 是终态，重新加入必须使用新的成员关系。
- 账号被停用或移除后，现有受保护请求即时失败，Refresh Session 全部撤销。
- 所有状态和权限修改都写入只追加审计日志。

### 5.3 dictionary

字典类型固定为：

- `supplier_company`
- `customer`
- `product_name`
- `product_model`
- `unit`
- `shipping_unit`

规则：

- 任意有效组成员可以读取本组启用的字典。
- 主账号和拥有 `dictionary.manage` 的成员可以创建、修改和停用字典。
- `product_model` 必须通过 `parent_id` 关联同组启用的 `product_name`。
- `customer` 允许保存可空联系电话；其他类型不接收联系电话。
- 字典按组隔离，并保存规范化名称用于组内去重。
- 停用代替硬删除；历史业务未来保存名称快照，不依赖字典当前名称展示。
- 管理写操作必须携带版本号，版本不一致返回冲突。

## 6. 数据模型

### 6.1 membership_permissions

- `id`: BIGINT UNSIGNED 主键。
- `group_id`: 冗余保存组 ID，便于强制组范围和索引。
- `membership_id`: 被授权成员关系。
- `permission_code`: 固定权限码。
- `granted_by`: 执行授权的主账号用户 ID。
- `created_at`: 授权时间。
- `(membership_id, permission_code)` 唯一。
- memberships 增加 `(id, group_id)` 唯一索引，权限表使用 `(membership_id, group_id)` 复合外键，确保 membership 与 group 属于同一组；Repository 写入前再次校验。

权限更新采用“完整集合替换”语义，并在同一事务内完成差异删除、差异新增、membership 版本更新和审计记录。

### 6.2 memberships 扩展

- 增加 `version`，默认 1，每次状态或权限变化原子加 1。
- 保留现有 `active`、`disabled`、`removed` 状态。
- 成员写接口必须提交当前版本，避免两个管理员互相覆盖。

### 6.3 dictionary_entries

- `id`、`group_id`、`kind`。
- `name`、`normalized_name`。
- 可空 `parent_id`。
- 可空 `contact_phone`，仅 customer 使用。
- `status`: `active` 或 `disabled`。
- `version`: 乐观锁版本。
- `created_by`、`updated_by`、`created_at`、`updated_at`。
- 使用生成列 `parent_scope_id = COALESCE(parent_id, 0)`，对 `(group_id, kind, parent_scope_id, normalized_name)` 建立唯一索引，避免 MySQL 的 NULL 唯一键语义允许重复顶级词条。

规范化规则固定为：去除首尾空白、连续空白折叠为一个半角空格、Unicode NFKC 规范化、拉丁字母转小写。展示仍保留用户提交并通过校验的 `name`。

数据库迁移继续使用嵌入式 SQL，不使用生产 AutoMigrate。

## 7. API 契约

### 7.1 Web Cookie 认证

原生端保留现有接口：

```text
POST /api/v1/auth/login
POST /api/v1/auth/refresh
POST /api/v1/auth/logout
```

Web 增加明确分离的接口：

```text
POST /api/v1/auth/web/login
POST /api/v1/auth/web/refresh
POST /api/v1/auth/web/logout
```

Web 登录和刷新仅在响应体返回 Access Token；Refresh Token 写入 HttpOnly Cookie，不进入 JSON、日志或 JavaScript 可访问存储。登录成功同时设置非 HttpOnly CSRF Cookie；Flutter Web 从该 Cookie 读取值并写入 `X-CSRF-Token`，刷新和退出要求 Header 与 Cookie 一致，并校验 Origin。

生产 Refresh Cookie 使用：

- `Secure=true`
- `HttpOnly=true`
- `SameSite=Lax`
- host-only，不配置宽泛 Domain
- Path 限制到 `/api/v1/auth/web`

生产 CSRF Cookie 使用：

- `Secure=true`、`HttpOnly=false`、`SameSite=Lax`、Path 为 `/`
- Domain 只能配置为 Web 与 API 共用且完全受控的父域，例如 `example.com`
- 本地 localhost 开发不设置 Domain
- 若无法提供受控共用父域，启动时拒绝启用 Web Cookie 认证，而不是降低 CSRF 保护

开发环境允许通过显式配置关闭 Secure，仅用于本地 HTTP；生产环境不得关闭。

### 7.2 成员与权限

```text
GET    /api/v1/groups/members
PATCH  /api/v1/groups/members/{membership_id}/status
GET    /api/v1/groups/members/{membership_id}/permissions
PUT    /api/v1/groups/members/{membership_id}/permissions
GET    /api/v1/groups/permission-catalog
```

状态接口只接受合法状态转换并要求 `version`。权限 PUT 接收完整权限码集合和 `version`；若目标集合已经等于数据库当前集合，则返回当前结果和当前版本，即使请求携带的是完成该修改前的旧版本也保持幂等。若目标集合不同且版本过期，则返回 `RESOURCE_VERSION_CONFLICT`。

### 7.3 辅助字典

```text
GET    /api/v1/dictionaries
POST   /api/v1/dictionaries
PUT    /api/v1/dictionaries/{dictionary_id}
PATCH  /api/v1/dictionaries/{dictionary_id}/status
```

查询支持 `kind`、`parent_id`、`status`、关键字、分页和稳定排序。普通成员默认只能查询 active 数据；管理者可以显式查询 disabled 数据。

## 8. Flutter 工程边界

建议目录：

```text
client/lib/
├─ app/
│  ├─ app.dart
│  ├─ router.dart
│  └─ bootstrap.dart
├─ core/
│  ├─ config/
│  ├─ network/
│  ├─ auth/
│  ├─ storage/
│  ├─ database/
│  ├─ sync/
│  └─ error/
└─ features/
   ├─ members/
   │  ├─ data/
   │  ├─ domain/
   │  └─ application/
   └─ dictionaries/
      ├─ data/
      ├─ domain/
      └─ application/
```

技术选择：

- Riverpod：状态管理和依赖注入。
- GoRouter：登录、首次改密和权限路由守卫。
- Dio：HTTP、请求 ID、Access Token 和错误转换。
- flutter_secure_storage：Android/Windows Refresh Token。
- Drift：Android/Windows 本地缓存、草稿和 Outbox。
- connectivity_plus：仅触发重试机会，不作为网络真实可用性的判断依据。

本批不引入视觉组件库，不创建正式 feature 页面。测试通过 Controller、Repository 和最小路由壳验证行为。

## 9. 跨端认证数据流

### 9.1 Android/Windows

```text
登录
  -> JSON Access + Refresh Token
  -> Access Token 仅保存在内存
  -> Refresh Token 写入系统安全存储
  -> 启动时读取 Refresh Token 并恢复会话
```

### 9.2 Web

```text
登录
  -> 后端设置 HttpOnly Refresh Cookie + 可读 CSRF Cookie
  -> JSON 只返回 Access Token
  -> Access Token 仅保存在内存
  -> 页面刷新后调用 Web Refresh 恢复会话
```

### 9.3 单飞刷新

多个请求同时收到 401 时，只允许一个 Refresh 执行。其他请求等待同一个 Future：刷新成功后各自重试一次；刷新失败后统一清理认证状态，禁止递归刷新和无限重试。

## 10. 本地数据库与同步

Android 和 Windows建立 Drift 数据库，首批包含：

- `cached_members`
- `cached_member_permissions`
- `cached_dictionary_entries`
- `draft_records`
- `outbox_operations`

成员和字典查询采用在线优先：在线成功后覆盖本地缓存；网络失败时返回同一用户、同一组的缓存。成员状态、权限和字典管理写操作首批仅允许在线执行，不进入 Outbox。

Outbox 只建立供后续业务单据复用的通用状态机：

```text
pending -> syncing -> succeeded
                   -> retryable_failed -> pending
                   -> conflict
                   -> permanently_failed
```

每条 Outbox 操作保存用户 ID、组 ID、客户端请求 ID、资源类型、操作类型、序列化负载、尝试次数、下次重试时间和错误摘要。切换用户时不得读取或同步其他用户的队列。

后端后续写接口使用 `Idempotency-Key` 接收客户端请求 ID。相同用户、相同组、相同 Key 和相同请求摘要返回首次结果；同 Key 不同摘要返回冲突。

## 11. 错误处理

新增稳定错误码：

- `MEMBER_NOT_FOUND`
- `MEMBER_OWNER_PROTECTED`
- `MEMBER_SELF_OPERATION_FORBIDDEN`
- `PERMISSION_CODE_INVALID`
- `DICTIONARY_NOT_FOUND`
- `DICTIONARY_NAME_EXISTS`
- `DICTIONARY_PARENT_INVALID`
- `RESOURCE_VERSION_CONFLICT`
- `CSRF_INVALID`
- `ORIGIN_FORBIDDEN`

HTTP 映射：参数错误 400，认证失败 401，权限/CSRF/Origin 拒绝 403，资源不存在 404，唯一冲突和版本冲突 409，未知错误 500。

Flutter 将传输错误转换为稳定领域错误：未登录、无权限、校验失败、冲突、网络不可用和服务器错误。feature 不直接判断 DioException 或 HTTP 数字。

## 12. 安全约束

- Credential CORS 必须使用明确 Origin 白名单，禁止 `*`。
- Web Cookie Refresh 和 Logout 同时通过 SameSite、Origin 和 CSRF Token 防护。
- Access Token、Refresh Token、Cookie、CSRF Token、密码和完整请求体不得进入日志。
- Flutter 安全存储失败时不降级到 SharedPreferences 或明文文件。
- 后端权限是最终事实源；Flutter 缓存权限只控制展示和提前提示。
- 所有成员和字典 Repository 查询必须强制附带当前 group_id。
- 平台管理员不能调用租户成员和字典接口。

## 13. 测试策略

### 13.1 Go

- OpenAPI 契约测试覆盖全部新增路径、DTO 和错误码。
- authorization 表驱动测试覆盖主账号、普通成员、平台管理员、跨组和状态失效。
- member Service/Repository 测试覆盖状态转换、owner 保护、自操作保护、权限替换、乐观锁和审计回滚。
- dictionary 测试覆盖类型校验、型号父级、客户电话、规范化去重、停用和跨组隔离。
- Web auth Handler 测试覆盖 Cookie 属性、Origin、CSRF、刷新轮换和清理 Cookie。
- 真实 Docker MySQL 测试覆盖迁移、事务、唯一索引和并发权限更新。

### 13.2 Flutter

- DTO 与统一 Envelope JSON 转换。
- Dio 错误到领域错误的映射。
- Android/Windows 凭据存储适配器和 Web Cookie 适配器边界。
- 多个并发 401 只触发一次 Refresh。
- 启动恢复、首次改密、退出和认证失效状态转换。
- 成员和字典 Repository 的远端成功、本地回退、跨用户缓存隔离。
- Drift schema、迁移和 Outbox 状态转换。
- GoRouter 在未登录和必须改密状态下的守卫行为。

测试使用接口注入 fake 数据源；不向生产类增加只为测试服务的方法。

## 14. 完成标准

- OpenAPI 可解析并包含全部新增接口和稳定错误码。
- Android/Windows 可以通过无 UI 测试完成登录、会话恢复、单飞刷新和退出。
- Web 测试证明 Refresh Token 不出现在 JSON，Cookie 属性、Origin 和 CSRF 防护正确。
- 主账号可以管理普通成员状态和权限，授权修改在下一次请求即时生效。
- 获得 `dictionary.manage` 的成员可以维护字典，普通成员只能读取。
- 型号只能关联本组有效品名，跨组访问均被拒绝。
- Android/Windows 可以缓存成员和字典，并保持用户与组隔离。
- Outbox 状态机、幂等键和冲突保留具有自动化测试，但不提前实现业务单据同步。
- `go test ./...`、`go vet ./...`、`flutter analyze` 和 `flutter test` 通过。
- 真实 MySQL 集成测试通过，Redis 停止不影响本批正确性。

## 15. 实施顺序

1. 扩展 OpenAPI、错误码和第二版数据库迁移。
2. 实现 authorization 与成员生命周期纵向闭环。
3. 实现辅助字典纵向闭环。
4. 实现 Web Cookie、Origin 和 CSRF 认证闭环。
5. 建立 Flutter app/core 目录、依赖注入、网络与错误模型。
6. 实现 Flutter 原生安全存储、Web Cookie 和单飞刷新。
7. 实现 Flutter 成员、权限和字典 Repository 与状态。
8. 实现 Drift 缓存、草稿和 Outbox 状态机。
9. 执行 Go、Flutter、OpenAPI、真实 MySQL 和跨端认证验证。
