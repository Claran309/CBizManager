# 平台治理与可重复查看邀请码设计

## 1. 背景

CBizDocsManager 已具备平台管理员创建组、主账号首次改密、主账号创建一次性邀请码、子账号注册、成员权限和辅助字典 API。当前还缺少平台组治理、主账号交接、邀请码列表/撤销，以及有效邀请码重复查看能力。

项目尚未投入使用，没有需要兼容的真实业务数据。本设计仍采用新增迁移而不是改写历史迁移，保证任意环境可以按既定版本顺序升级和回滚。

## 2. 目标

- 平台管理员可以分页查询、搜索和查看组。
- 平台管理员可以启用、停用组，不提供硬删除。
- 平台管理员可以把现有普通成员提升为新主账号，或直接创建一个新主账号。
- owner 交接始终保持每个组只有一个有效 owner，并完整记录审计。
- 主账号可以查询邀请码历史、重复查看有效邀请码、复制和撤销邀请码。
- 邀请码明文以加密形式保存，列表、日志、审计和错误响应不泄漏明文。
- 注册、撤销和查看邀请码在并发下保持一致。

## 3. 非目标

- 不实现组硬删除。
- 不实现平台管理员直接查看租户业务数据。
- 不实现二维码、分享链接、短信、企业微信或 Deep Link。
- 不实现通用密钥轮换后台；首期只支持一个显式配置的当前邀请码加密密钥。
- 不实现审计日志查询页面，但所有治理写操作必须追加审计日志。
- 不实现入库、出库、结算等业务单据。

## 4. 角色与权限边界

### 4.1 平台管理员

- 可查询所有组的治理元数据。
- 可创建组和初始 owner。
- 可启用、停用组。
- 可更换组 owner。
- 不会因为平台身份获得任何租户业务权限。

### 4.2 组主账号

- 可创建、查询、查看和撤销当前组邀请码。
- 可管理当前组普通成员、权限和字典。
- 不能通过租户成员接口创建第二个 owner 或更换 owner。

### 4.3 普通成员

- 无权查看邀请码明文。
- 即使拥有 `member.manage`，也不能更换 owner 或替其他成员授权。

## 5. 数据模型

新增迁移：

```text
000003_platform_governance_invitations.up.sql
000003_platform_governance_invitations.down.sql
```

### 5.1 groups

增加：

- `version BIGINT UNSIGNED NOT NULL DEFAULT 1`
- 用于组状态和 owner 交接的乐观锁。

合法状态转换只有：

```text
active <-> disabled
```

同状态请求为幂等成功；不同状态但版本过期返回 `RESOURCE_VERSION_CONFLICT`。

### 5.2 invitations

保留现有 `code_hash` 作为注册查找和恒定时间比较依据，增加：

- `code_ciphertext VARBINARY(255) NULL`
- `code_nonce VARBINARY(12) NULL`
- `version BIGINT UNSIGNED NOT NULL DEFAULT 1`
- `revoked_at DATETIME(6) NULL`
- `revoked_by BIGINT UNSIGNED NULL`
- `status` 扩展为 `active|used|revoked`

接口展示状态为：

- `active`：数据库为 active 且尚未过期。
- `expired`：数据库为 active，但当前时间已达到 `expires_at`。
- `used`：已被成功注册消费。
- `revoked`：已被 owner 撤销。

邀请码变成 `used` 或 `revoked` 时，在同一事务中清空 `code_ciphertext` 和 `code_nonce`。过期邀请码不自动写库，但任何 secret 查询都必须拒绝解密。

### 5.3 owner 唯一性

继续依赖并强化以下事实：

- `groups.owner_user_id` 指向当前 owner 用户。
- `memberships.active_owner_group_id` 生成列唯一索引保证每组只有一个 active owner membership。
- owner 交接必须在单个事务中锁定组、旧 owner、目标用户和相关 membership。

## 6. 邀请码加密

新增环境变量：

```text
INVITATION_ENCRYPTION_KEY=<base64-encoded-32-byte-key>
```

规则：

- 所有环境都必须显式配置，不能复用 `JWT_SECRET`。
- 配置加载时 Base64 解码并校验恰好 32 字节。
- 使用 AES-256-GCM，每个邀请码生成独立的 12 字节随机 nonce。
- AAD 使用稳定的 `group_id + code_hash`，防止密文被移动到其他组或其他邀请码记录。
- 明文只在创建响应或显式 secret 响应中出现。
- 响应设置 `Cache-Control: no-store`；日志和审计只记录邀请码 ID。
- 密钥丢失时，已有邀请码仍可凭 `code_hash` 完成注册，但无法再次展示；服务返回稳定的内部错误并记录不含密文的错误日志。
- 首期不支持在线密钥轮换；更换密钥前应撤销所有 active 邀请码。

## 7. 平台 API

### 7.1 组列表

```text
GET /api/v1/platform/groups?page=&page_size=&status=&keyword=
```

返回组 ID、名称、状态、owner 摘要、成员数量、版本、创建及更新时间。稳定排序为 `created_at DESC, id DESC`。

### 7.2 组详情

```text
GET /api/v1/platform/groups/{group_id}
```

返回组摘要、当前 owner、按状态统计的成员数量和版本，不返回租户业务数据。

### 7.3 组状态

```text
PATCH /api/v1/platform/groups/{group_id}/status
```

请求：

```json
{"status":"disabled","version":1}
```

停用组时在同一事务撤销组内全部未撤销 Refresh Session。重新启用不会恢复旧会话，用户必须重新登录。

### 7.4 owner 交接

```text
PUT /api/v1/platform/groups/{group_id}/owner
```

请求使用 OpenAPI `oneOf` 和 `mode` discriminator，严格二选一：

```json
{
  "mode":"existing_member",
  "membership_id":21,
  "version":3
}
```

或：

```json
{
  "mode":"new_account",
  "username":"new-owner",
  "display_name":"New Owner",
  "temporary_password":"temporary-password",
  "version":3
}
```

交接事务：

1. 锁定组并校验 version。
2. 锁定旧 owner 用户和 membership。
3. 校验或创建新 owner 用户和 membership。
4. 清除新 owner 原有显式权限，把用户类型改为 `group_owner`、membership 改为 active owner。
5. 把旧 owner 用户类型改为 `member`、membership 改为 disabled member，并清除显式权限。
6. 更新 `groups.owner_user_id` 和 `groups.version + 1`。
7. 撤销旧 owner 和被提升成员的全部 Refresh Session。
8. 写 `platform.group.owner_changed` 审计后提交事务。

若采用 `new_account`，新账号必须 `must_change_password=true`。disabled 组也允许交接 owner，但新 owner 只能在组重新启用后登录。

## 8. 邀请 API

### 8.1 创建

保留：

```text
POST /api/v1/groups/invitations
```

响应首次返回完整邀请码，同时保存哈希与加密密文。

### 8.2 列表

```text
GET /api/v1/groups/invitations?page=&page_size=&status=
```

列表只返回 ID、展示状态、创建者、使用者、到期时间、使用/撤销时间和 version，不返回密文或明文。

### 8.3 查看有效邀请码

```text
GET /api/v1/groups/invitations/{invitation_id}/secret
```

仅 owner 可调用。必须同时满足同组、数据库状态 active、未过期、密文存在。响应携带 `Cache-Control: no-store`。

### 8.4 撤销

```text
PATCH /api/v1/groups/invitations/{invitation_id}/revoke
```

请求包含 version。`active -> revoked` 成功；已 revoked 为幂等成功；used 或 expired 返回 `INVITATION_NOT_REVOKABLE`。

## 9. 注册、查看与撤销并发

- 注册通过 `code_hash` 锁定 invitation 行。
- 注册只消费 active 且未过期的邀请码。
- 撤销同样锁定 invitation 行。
- 注册与撤销竞争时，先获得锁并提交的一方成功，另一方根据最新状态得到稳定业务错误。
- secret 查询必须在同一次 Repository 操作中读取状态和密文，不允许先查状态再无锁读取密文。

## 10. 错误码

新增或复用：

- `GROUP_NOT_FOUND`：404。
- `RESOURCE_VERSION_CONFLICT`：409。
- `GROUP_STATUS_INVALID`：409。
- `OWNER_TARGET_INVALID`：400。
- `OWNER_TARGET_FORBIDDEN`：409。
- `INVITATION_NOT_FOUND`：404。
- `INVITATION_NOT_REVEALABLE`：409。
- `INVITATION_NOT_REVOKABLE`：409。
- `INVITATION_DECRYPT_FAILED`：500，仅向客户端返回通用消息。

跨组资源对租户用户统一按既有安全策略返回禁止或不存在，不泄漏资源归属。

## 11. 后端模块边界

- `internal/platform`：组列表、详情、状态和 owner 交接。
- `internal/organization`：邀请码生命周期和注册消费。
- `internal/infrastructure/cryptography`：AES-GCM 邀请码加解密接口与实现。
- `pkg/config`：密钥加载与启动校验。
- `internal/infrastructure/httpserver`：平台及邀请路由装配。

Service 负责权限、状态和事务意图；Repository 负责锁、持久化和事务原子性；Handler 只处理 HTTP 绑定和统一 Envelope。

## 12. 测试

### 12.1 单元测试

- Base64 密钥校验、AES-GCM 加解密、错误密钥和篡改密文。
- 平台管理员、owner、普通成员和跨组权限矩阵。
- 组状态幂等、版本冲突和会话撤销。
- 两种 owner 交接模式、旧 owner 降级停用和字段互斥验证。
- 邀请码四种展示状态、secret 边界、撤销幂等和明文不进入列表。

### 12.2 Docker MySQL 集成测试

- 每组唯一 active owner 约束。
- owner 交接任一步失败时整体回滚。
- 组停用撤销全部会话。
- 注册与撤销并发只有一个成功。
- 邀请码使用/撤销后密文字段被清空。
- 所有列表、详情和写操作保持组隔离。

### 12.3 契约与安全测试

- OpenAPI 路径、oneOf、枚举和错误码解析。
- 响应、日志和审计不包含密码、邀请码密文或明文。
- Secret 响应包含 `Cache-Control: no-store`。

## 13. 验收标准

- 平台管理员可以从零创建组和 owner，并完成启停和一次 owner 交接。
- owner 可以创建邀请码，稍后再次查看同一有效邀请码并撤销。
- used、expired、revoked 邀请码均无法再次显示明文。
- 子账号可以用未过期且未撤销的邀请码注册。
- owner 交接后旧 owner 会话立即失效，数据库不存在第二个 active owner。
- 全量 Go 单元测试、`go vet` 和真实 Docker MySQL 集成测试通过。
