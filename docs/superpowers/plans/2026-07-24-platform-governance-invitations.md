# CBizDocsManager Platform Governance and Invitation Lifecycle Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 为平台管理员补齐组查询、启停和 owner 交接，并为组主账号交付可列表、可重复查看、可撤销且并发安全的邀请码生命周期。

**Architecture:** 后端继续采用 Gin Handler -> Service -> GORM Repository；平台治理事务集中在 `internal/platform`，邀请码生命周期集中在 `internal/organization`，AES-256-GCM 位于独立基础设施包。MySQL 是治理状态、乐观锁、会话撤销和邀请码终态的唯一事实源，明文邀请码仅在创建或显式查看响应中短暂出现。

**Tech Stack:** Go 1.25.3、Gin、GORM、MySQL 8、Viper、AES-256-GCM、OpenAPI 3.0、Docker Desktop、Go testing。

---

## 执行边界与顺序

- 本计划只实现后端契约和治理能力，不创建 Flutter 页面。
- 直接在 `main` 执行，不创建分支或 worktree；每个 Task 通过验证后独立提交，普通 push 放在全部 Task 完成后。
- 单元测试不依赖 Docker；只有标记为 `integration` 的测试连接 Docker MySQL。
- 运行真实集成测试前必须执行 `docker context show`、`docker ps -a`、`docker inspect MySQL`，并记录容器原始状态；如果由本次执行启动，测试后恢复为原状态。
- 不读取、打印或提交 Docker 容器密码。`TEST_MYSQL_DSN`、`INVITATION_ENCRYPTION_KEY` 只通过当前进程环境或本地未跟踪 `.env` 注入。
- `000001` 和 `000002` 不改写；所有结构变化只进入 `000003_platform_governance_invitations.*.sql`。

## 文件边界

- `api/openapi/cbizdocsmanager-v1.yaml`：新增 7 个治理/邀请操作、oneOf owner 请求、分页 DTO 和稳定错误码。
- `backend/migrations/000003_platform_governance_invitations.*.sql`：组版本、邀请码密文/nonce/撤销字段和状态枚举。
- `backend/internal/infrastructure/cryptography/invitation_cipher.go`：唯一负责邀请码 AES-GCM 加解密和 AAD 绑定。
- `backend/pkg/config/config.go`：加载并验证独立的 Base64 32 字节邀请码密钥。
- `backend/internal/platform/`：组列表、详情、状态变更和两种 owner 交接事务。
- `backend/internal/organization/`：邀请码创建、列表、secret、撤销和注册消费并发一致性。
- `backend/internal/infrastructure/httpserver/`、`backend/cmd/api/main.go`：路由和依赖装配。
- `backend/tests/integration/platform_governance_invitation_flow_test.go`：真实 MySQL 纵向治理闭环和并发验证。

### Task 1: 固化 OpenAPI、错误码和第三版迁移契约

**Files:**
- Modify: `api/openapi/cbizdocsmanager-v1.yaml`
- Modify: `backend/tests/openapi_contract_test.go`
- Modify: `backend/pkg/apperror/error.go`
- Modify: `backend/pkg/apperror/error_test.go`
- Modify: `backend/internal/organization/model.go`
- Modify: `backend/internal/identity/dto.go`
- Modify: `backend/internal/identity/repository.go`
- Modify: `backend/internal/identity/repository_test.go`
- Modify: `backend/internal/identity/service.go`
- Modify: `backend/internal/identity/service_test.go`
- Create: `backend/migrations/000003_platform_governance_invitations.up.sql`
- Create: `backend/migrations/000003_platform_governance_invitations.down.sql`
- Modify: `backend/internal/infrastructure/database/migrate_test.go`

- [ ] **Step 1: 写 OpenAPI 路径、oneOf 和错误码失败测试**

在 `openapi_contract_test.go` 增加精确断言：

```go
var governanceOperations = []string{
	"GET /api/v1/platform/groups",
	"GET /api/v1/platform/groups/{group_id}",
	"PATCH /api/v1/platform/groups/{group_id}/status",
	"PUT /api/v1/platform/groups/{group_id}/owner",
	"GET /api/v1/groups/invitations",
	"GET /api/v1/groups/invitations/{invitation_id}/secret",
	"PATCH /api/v1/groups/invitations/{invitation_id}/revoke",
}

var governanceErrorCodes = []string{
	"GROUP_NOT_FOUND", "GROUP_STATUS_INVALID", "OWNER_TARGET_INVALID",
	"OWNER_TARGET_FORBIDDEN", "INVITATION_NOT_FOUND",
	"INVITATION_NOT_REVEALABLE", "INVITATION_NOT_REVOKABLE",
	"INVITATION_DECRYPT_FAILED",
}
```

同时加载 `ChangeGroupOwnerRequest`，断言 `oneOf` 恰好引用 `PromoteExistingMemberOwnerRequest` 和 `CreateNewOwnerRequest`，且 discriminator 为 `mode`。

Run: `cd backend; go test ./tests ./pkg/apperror -count=1`

Expected: FAIL，报告路径、schema 或错误码缺失。

- [ ] **Step 2: 写迁移结构失败测试**

在 `migrate_test.go` 对嵌入迁移内容断言以下片段存在，并断言 down 迁移按外键、列、索引逆序回滚：

```go
required := []string{
	"ADD COLUMN version BIGINT UNSIGNED NOT NULL DEFAULT 1",
	"MODIFY COLUMN status ENUM('active', 'used', 'revoked')",
	"ADD COLUMN code_ciphertext VARBINARY(255) NULL",
	"ADD COLUMN code_nonce VARBINARY(12) NULL",
	"ADD COLUMN revoked_at DATETIME(6) NULL",
	"ADD COLUMN revoked_by BIGINT UNSIGNED NULL",
	"ADD COLUMN version BIGINT UNSIGNED NOT NULL DEFAULT 1",
	"CONSTRAINT fk_invitations_revoked_by",
}
```

Run: `cd backend; go test ./internal/infrastructure/database -count=1`

Expected: FAIL，因为 `000003` 尚不存在。

- [ ] **Step 3: 新增稳定业务错误**

在 `apperror/error.go` 增加以下常量和实例，客户端消息不得包含密钥、nonce 或密文：

```go
const (
	CodeGroupNotFound             = "GROUP_NOT_FOUND"
	CodeGroupStatusInvalid        = "GROUP_STATUS_INVALID"
	CodeOwnerTargetInvalid        = "OWNER_TARGET_INVALID"
	CodeOwnerTargetForbidden      = "OWNER_TARGET_FORBIDDEN"
	CodeInvitationNotFound        = "INVITATION_NOT_FOUND"
	CodeInvitationNotRevealable   = "INVITATION_NOT_REVEALABLE"
	CodeInvitationNotRevokable    = "INVITATION_NOT_REVOKABLE"
	CodeInvitationDecryptFailed   = "INVITATION_DECRYPT_FAILED"
)

var (
	ErrGroupNotFound           = New(CodeGroupNotFound, "组不存在", http.StatusNotFound)
	ErrGroupStatusInvalid      = New(CodeGroupStatusInvalid, "组状态不允许执行此操作", http.StatusConflict)
	ErrOwnerTargetInvalid      = New(CodeOwnerTargetInvalid, "新主账号目标无效", http.StatusBadRequest)
	ErrOwnerTargetForbidden    = New(CodeOwnerTargetForbidden, "新主账号目标不允许交接", http.StatusConflict)
	ErrInvitationNotFound      = New(CodeInvitationNotFound, "邀请码不存在", http.StatusNotFound)
	ErrInvitationNotRevealable = New(CodeInvitationNotRevealable, "邀请码当前不可查看", http.StatusConflict)
	ErrInvitationNotRevokable  = New(CodeInvitationNotRevokable, "邀请码当前不可撤销", http.StatusConflict)
	ErrInvitationDecryptFailed = New(CodeInvitationDecryptFailed, "邀请码暂时无法查看", http.StatusInternalServerError)
)
```

在 `error_test.go` 表驱动断言 code、HTTP status 和安全消息。

- [ ] **Step 4: 实现可逆 `000003` 迁移并同步 GORM 模型**

Up 迁移使用以下结构，不触碰历史迁移：

```sql
ALTER TABLE `groups`
    ADD COLUMN version BIGINT UNSIGNED NOT NULL DEFAULT 1;

ALTER TABLE invitations
    MODIFY COLUMN status ENUM('active', 'used', 'revoked') NOT NULL DEFAULT 'active',
    ADD COLUMN code_ciphertext VARBINARY(255) NULL AFTER code_hash,
    ADD COLUMN code_nonce VARBINARY(12) NULL AFTER code_ciphertext,
    ADD COLUMN revoked_at DATETIME(6) NULL AFTER used_by,
    ADD COLUMN revoked_by BIGINT UNSIGNED NULL AFTER revoked_at,
    ADD COLUMN version BIGINT UNSIGNED NOT NULL DEFAULT 1 AFTER status,
    ADD KEY idx_invitations_revoked_by (revoked_by),
    ADD CONSTRAINT fk_invitations_revoked_by
      FOREIGN KEY (revoked_by) REFERENCES users (id)
      ON UPDATE RESTRICT ON DELETE SET NULL;
```

Down 迁移先删除 `fk_invitations_revoked_by` 和索引，再删除新增列，将状态恢复为 `active|used`，最后删除 `groups.version`。`organization.Group` 增加 `Version uint64`；`InvitationStatus` 增加 `revoked`，`Invitation` 增加 `CodeCiphertext []byte`、`CodeNonce []byte`、`RevokedAt *time.Time`、`RevokedBy *uint64`、`Version uint64`。

- [ ] **Step 5: 补齐 OpenAPI schemas 和响应**

契约固定以下请求形状：

```yaml
ChangeGroupStatusRequest:
  type: object
  required: [status, version]
  additionalProperties: false
  properties:
    status: {type: string, enum: [active, disabled]}
    version: {type: integer, format: int64, minimum: 1}
ChangeGroupOwnerRequest:
  oneOf:
    - $ref: '#/components/schemas/PromoteExistingMemberOwnerRequest'
    - $ref: '#/components/schemas/CreateNewOwnerRequest'
  discriminator:
    propertyName: mode
    mapping:
      existing_member: '#/components/schemas/PromoteExistingMemberOwnerRequest'
      new_account: '#/components/schemas/CreateNewOwnerRequest'
RevokeInvitationRequest:
  type: object
  required: [version]
  additionalProperties: false
  properties:
    version: {type: integer, format: int64, minimum: 1}
```

`InvitationSummaryData` 只包含 ID、display status、创建者/使用者摘要、时间和 version；禁止包含 `invitation_code`、`code_ciphertext`、`code_nonce`。`PlatformGroupDetailData` 额外包含 `owner_candidates`，每项只含 active 普通成员的 membership ID 和用户摘要，用于平台管理员选择交接目标；它属于治理元数据，不包含权限、字典或业务单据数据。

为满足 Flutter 根据服务端权限隐藏普通成员入口，`MeResponse`/OpenAPI `MeData` 增加 `permission_codes: string[]`：平台管理员和 owner 返回空数组（能力分别由 account type/member type 决定），普通成员返回当前 active membership 的显式权限。identity Repository 增加：

```go
ListCurrentPermissionCodes(ctx context.Context, userID uint64, groupID uint64) ([]string, error)
```

查询必须 join active membership，并按 `permission_code ASC` 排序；`Service.Me` 仅对 `account_type=member` 调用该方法。这样客户端仍以 `/auth/me` 为唯一身份与导航事实源，不解析 JWT。

- [ ] **Step 6: 验证并提交 Task 1**

Run: `cd backend; go test ./tests ./pkg/apperror ./internal/infrastructure/database -count=1`

Expected: PASS。

Commit: `git add api/openapi backend/tests/openapi_contract_test.go backend/pkg/apperror backend/internal/organization/model.go backend/internal/identity backend/migrations backend/internal/infrastructure/database/migrate_test.go && git commit -m "feat: 定义平台治理与邀请码契约"`

### Task 2: 独立邀请码密钥配置与 AES-256-GCM

**Files:**
- Modify: `backend/pkg/config/config.go`
- Modify: `backend/pkg/config/config_test.go`
- Modify: `backend/.env.example`
- Modify: `backend/config/config.yaml`
- Modify: `deploy/docker-compose.yml`
- Create: `backend/internal/infrastructure/cryptography/invitation_cipher.go`
- Create: `backend/internal/infrastructure/cryptography/invitation_cipher_test.go`

- [ ] **Step 1: 写配置和密码学失败测试**

测试以下行为：未显式配置、非 Base64、解码后不是 32 字节均返回同一配置错误；随机 nonce 使同一明文两次密文不同；正确 AAD 可解密；错误 group、错误 hash、错误 key、篡改 ciphertext/nonce 均失败。

```go
func TestInvitationCipherBindsCiphertextToGroupAndHash(t *testing.T) {
	key := bytes.Repeat([]byte{0x42}, 32)
	cipher, err := NewInvitationCipher(key)
	if err != nil { t.Fatal(err) }
	ciphertext, nonce, err := cipher.Encrypt("secret-code", 7, strings.Repeat("a", 64))
	if err != nil { t.Fatal(err) }
	if _, err := cipher.Decrypt(ciphertext, nonce, 8, strings.Repeat("a", 64)); err == nil {
		t.Fatal("Decrypt() with another group succeeded")
	}
}
```

Run: `cd backend; go test ./pkg/config ./internal/infrastructure/cryptography -count=1`

Expected: FAIL，因为配置字段和包尚不存在。

- [ ] **Step 2: 定义配置并强制显式密钥**

```go
var ErrInvitationEncryptionKeyInvalid = errors.New("邀请码加密密钥必须显式配置为 Base64 编码的 32 字节密钥")

type InvitationConfig struct {
	EncryptionKey string `mapstructure:"encryption_key"`
}

type Config struct {
	App AppConfig `mapstructure:"app"`; HTTP HTTPConfig `mapstructure:"http"`
	MySQL MySQLConfig `mapstructure:"mysql"`; Redis RedisConfig `mapstructure:"redis"`
	JWT JWTConfig `mapstructure:"jwt"`; CORS CORSConfig `mapstructure:"cors"`
	WebAuth WebAuthConfig `mapstructure:"web_auth"`; Bootstrap BootstrapConfig `mapstructure:"bootstrap"`
	Invitation InvitationConfig `mapstructure:"invitation"`
}

func DecodeInvitationEncryptionKey(raw string) ([]byte, error) {
	decoded, err := base64.StdEncoding.DecodeString(strings.TrimSpace(raw))
	if err != nil || len(decoded) != 32 {
		return nil, ErrInvitationEncryptionKeyInvalid
	}
	return decoded, nil
}
```

`Load` 在所有环境调用该校验；`bindEnvironment` 绑定 `INVITATION_ENCRYPTION_KEY`。`.env.example` 只写占位符；Compose 透传 `${INVITATION_ENCRYPTION_KEY:-}`，不得提供可用默认密钥。

- [ ] **Step 3: 实现只接受字节的 Cipher 接口**

```go
type InvitationCipher interface {
	Encrypt(plain string, groupID uint64, codeHash string) (ciphertext, nonce []byte, err error)
	Decrypt(ciphertext, nonce []byte, groupID uint64, codeHash string) (string, error)
}

func invitationAAD(groupID uint64, codeHash string) []byte {
	return []byte(strconv.FormatUint(groupID, 10) + ":" + codeHash)
}
```

`NewInvitationCipher` 拒绝非 32 字节 key；`Encrypt` 每次读取 `gcm.NonceSize()` 个 `crypto/rand` 字节并调用 `Seal(nil, nonce, []byte(plain), aad)`；`Decrypt` 先校验 nonce 长度，再调用 `Open`。错误只包装操作名，不拼接 key、ciphertext、nonce、code hash 或明文。

- [ ] **Step 4: 运行测试并提交 Task 2**

Run: `cd backend; go test ./pkg/config ./internal/infrastructure/cryptography -count=1`

Expected: PASS。

Commit: `git add backend/pkg/config backend/.env.example backend/config/config.yaml deploy/docker-compose.yml backend/internal/infrastructure/cryptography && git commit -m "feat: 添加邀请码独立加密能力"`

### Task 3: 平台组列表与详情查询

**Files:**
- Modify: `backend/internal/platform/dto.go`
- Modify: `backend/internal/platform/repository.go`
- Modify: `backend/internal/platform/repository_test.go`
- Modify: `backend/internal/platform/service.go`
- Modify: `backend/internal/platform/service_test.go`
- Modify: `backend/internal/platform/handler.go`
- Modify: `backend/internal/platform/handler_test.go`

- [ ] **Step 1: 写查询权限、筛选和稳定排序失败测试**

Repository 测试断言 keyword 使用转义后的 `LIKE`、status 可选、排序固定为 `groups.created_at DESC, groups.id DESC`，成员统计不重复计数。Service 测试断言仅 `platform_admin` 且已改密可查询；Handler 测试断言非法 ID/分页返回 `VALIDATION_FAILED`。

Run: `cd backend; go test ./internal/platform -count=1`

Expected: FAIL，报告查询接口未定义。

- [ ] **Step 2: 定义 DTO 和 Repository 查询边界**

```go
type GroupQuery struct {
	Page int `form:"page" binding:"omitempty,min=1"`
	PageSize int `form:"page_size" binding:"omitempty,min=1,max=100"`
	Status organization.GroupStatus `form:"status" binding:"omitempty,oneof=active disabled"`
	Keyword string `form:"keyword" binding:"omitempty,max=191"`
}

type GroupSummaryData struct {
	ID uint64 `json:"id"`; Name string `json:"name"`
	Status organization.GroupStatus `json:"status"`
	Owner identity.UserSummary `json:"owner"`
	MemberCount int64 `json:"member_count"`; Version uint64 `json:"version"`
	CreatedAt time.Time `json:"created_at"`; UpdatedAt time.Time `json:"updated_at"`
}

type GroupCreatedData struct {
	GroupID uint64 `json:"group_id"`; GroupName string `json:"group_name"`
	Owner identity.UserSummary `json:"owner"`
}

type GroupDetailData struct {
	Group GroupSummaryData `json:"group"`
	MemberCounts map[organization.MembershipStatus]int64 `json:"member_counts"`
	OwnerCandidates []OwnerCandidateData `json:"owner_candidates"`
}

type OwnerCandidateData struct {
	MembershipID uint64 `json:"membership_id"`
	User identity.UserSummary `json:"user"`
}

type Repository interface {
	CreateGroupWithOwner(context.Context, CreateGroupInput) (*GroupCreation, error)
	ListGroups(context.Context, GroupQuery) ([]GroupSummaryData, int64, error)
	GetGroupDetail(context.Context, uint64) (*GroupDetailData, error)
}
```

查询只 join 用户、membership 统计等治理元数据，不 join 字典或未来单据表。`OwnerCandidates` 只查询同组 `member_type='member' AND status='active'`，按 `users.display_name ASC,memberships.id ASC` 稳定排序。

同步调整现有创建组响应为 `GroupCreatedData`，明确返回 `group_id`、`group_name` 和 owner 摘要；Flutter 创建成功后只依赖 group ID 导航到详情，再由 GET 获取 version/status/counts。

- [ ] **Step 3: 实现 Service 和 Handler**

```go
func (s *Service) ListGroups(ctx context.Context, p identity.Principal, q GroupQuery) (*GroupPageData, error)
func (s *Service) GetGroup(ctx context.Context, p identity.Principal, groupID uint64) (*GroupDetailData, error)
func (h *Handler) ListGroups(c *gin.Context)
func (h *Handler) GetGroup(c *gin.Context)
```

Service 统一调用 `requirePlatformAdmin(principal)`；Repository 的 `gorm.ErrRecordNotFound` 转换为 package sentinel `ErrGroupMissing`，Service 再映射为 `apperror.ErrGroupNotFound`。分页默认 `page=1,page_size=20`，keyword `TrimSpace`。

- [ ] **Step 4: GREEN 并提交 Task 3**

Run: `cd backend; go test ./internal/platform -count=1`

Expected: PASS。

Commit: `git add backend/internal/platform && git commit -m "feat: 添加平台组查询能力"`

### Task 4: 组启停、乐观锁和会话撤销

**Files:**
- Modify: `backend/internal/platform/dto.go`
- Modify: `backend/internal/platform/repository.go`
- Modify: `backend/internal/platform/repository_test.go`
- Modify: `backend/internal/platform/service.go`
- Modify: `backend/internal/platform/service_test.go`
- Modify: `backend/internal/platform/handler.go`
- Modify: `backend/internal/platform/handler_test.go`

- [ ] **Step 1: 写状态机失败测试**

覆盖：`active -> disabled`、`disabled -> active`、同状态旧版本幂等成功、不同状态旧版本冲突、非法状态、组不存在、非平台管理员；停用时必须撤销组内所有未撤销 session，启用不恢复 session。

Run: `cd backend; go test ./internal/platform -run 'GroupStatus|ChangeStatus' -count=1`

Expected: FAIL。

- [ ] **Step 2: 定义请求和事务结果**

```go
type ChangeGroupStatusRequest struct {
	Status organization.GroupStatus `json:"status" binding:"required,oneof=active disabled"`
	Version uint64 `json:"version" binding:"required,min=1"`
}

type ChangeGroupStatusInput struct {
	GroupID uint64; Status organization.GroupStatus; ExpectedVersion uint64
	OperatorUserID uint64; Now time.Time
}

func (r *gormRepository) ChangeGroupStatus(ctx context.Context, in ChangeGroupStatusInput) (*GroupSummaryData, error)
```

- [ ] **Step 3: 实现单事务状态变更**

事务按顺序执行：`SELECT groups ... FOR UPDATE`；若目标状态相同直接返回当前详情；否则先校验 version，再更新 `status, version=version+1, updated_at`；目标为 disabled 时执行：

```go
tx.Model(&identity.RefreshSession{}).
	Where("group_id = ? AND revoked_at IS NULL", in.GroupID).
	Updates(map[string]any{"revoked_at": in.Now, "last_used_at": in.Now})
```

最后追加 `platform.group.status_changed` 审计。任一步失败整笔回滚。

- [ ] **Step 4: 实现 Service/Handler 与错误映射**

```go
func (s *Service) ChangeGroupStatus(ctx context.Context, p identity.Principal, groupID uint64, req ChangeGroupStatusRequest) (*GroupSummaryData, error)
func (h *Handler) ChangeGroupStatus(c *gin.Context)
```

`ErrGroupMissing -> GROUP_NOT_FOUND`，`ErrVersionConflict -> RESOURCE_VERSION_CONFLICT`，Repository 非法状态 -> `GROUP_STATUS_INVALID`。

- [ ] **Step 5: GREEN 并提交 Task 4**

Run: `cd backend; go test ./internal/platform ./internal/identity -count=1`

Expected: PASS。

Commit: `git add backend/internal/platform && git commit -m "feat: 支持平台启停业务组"`

### Task 5: owner 交接请求校验和两种事务模式

**Files:**
- Modify: `backend/internal/platform/dto.go`
- Modify: `backend/internal/platform/repository.go`
- Modify: `backend/internal/platform/repository_test.go`
- Modify: `backend/internal/platform/service.go`
- Modify: `backend/internal/platform/service_test.go`
- Modify: `backend/internal/platform/handler.go`
- Modify: `backend/internal/platform/handler_test.go`

- [ ] **Step 1: 写严格二选一和权限失败测试**

Handler 测试覆盖未知字段、缺 mode、两组字段混用、existing 缺 membership、new 缺账号字段。Service 测试覆盖平台管理员限定、目标为旧 owner、目标跨组、removed/disabled 目标、username 冲突和版本冲突；另加 disabled 组允许交接的成功用例，且新 owner 在组重新启用前无法登录。

Run: `cd backend; go test ./internal/platform -run Owner -count=1`

Expected: FAIL。

- [ ] **Step 2: 定义 discriminator DTO**

```go
type ChangeOwnerMode string
const (
	ChangeOwnerExistingMember ChangeOwnerMode = "existing_member"
	ChangeOwnerNewAccount ChangeOwnerMode = "new_account"
)

type ChangeGroupOwnerRequest struct {
	Mode ChangeOwnerMode `json:"mode" binding:"required,oneof=existing_member new_account"`
	MembershipID *uint64 `json:"membership_id"`
	Username *string `json:"username"`
	DisplayName *string `json:"display_name"`
	TemporaryPassword *string `json:"temporary_password"`
	Version uint64 `json:"version" binding:"required,min=1"`
}

func (r ChangeGroupOwnerRequest) ValidateModeFields() error
```

`existing_member` 只允许 `membership_id`；`new_account` 只允许 username/display_name/temporary_password，密码最少 8 字节。混用统一返回 `OWNER_TARGET_INVALID`。

- [ ] **Step 3: 定义 Repository 输入和返回**

```go
type ChangeOwnerInput struct {
	GroupID uint64; Mode ChangeOwnerMode; MembershipID *uint64
	Username, DisplayName, PasswordHash string
	ExpectedVersion, OperatorUserID uint64; Now time.Time
}

type OwnerChange struct {
	Group organization.Group
	OldOwner identity.User
	NewOwner identity.User
	NewOwnerMembership organization.Membership
}

func (r *gormRepository) ChangeOwner(ctx context.Context, in ChangeOwnerInput) (*OwnerChange, error)
```

同时在 package 内定义并在 Service 映射以下 sentinel：

```go
var (
	ErrGroupMissing = errors.New("group missing")
	ErrVersionConflict = errors.New("resource version conflict")
	ErrOwnerTargetInvalid = errors.New("owner target invalid")
	ErrOwnerTargetForbidden = errors.New("owner target forbidden")
)
```

- [ ] **Step 4: 实现锁顺序固定的 owner 交接事务**

锁顺序必须固定：group -> old owner membership -> old owner user -> target membership/user。existing 模式要求目标 membership 同组、`member_type=member,status=active`；new 模式创建 active 用户和 active member membership，`must_change_password=true`。

随后在同一事务执行：

```go
tx.Table("membership_permissions").
	Where("membership_id IN ?", []uint64{oldMembership.ID, targetMembership.ID}).Delete(nil)
tx.Model(&targetUser).Updates(map[string]any{"account_type": identity.AccountTypeGroupOwner, "updated_at": in.Now})
tx.Model(&targetMembership).Updates(map[string]any{"member_type": organization.MemberTypeOwner, "status": organization.MembershipStatusActive, "version": gorm.Expr("version + 1"), "updated_at": in.Now})
tx.Model(&oldUser).Updates(map[string]any{"account_type": identity.AccountTypeMember, "updated_at": in.Now})
tx.Model(&oldMembership).Updates(map[string]any{"member_type": organization.MemberTypeMember, "status": organization.MembershipStatusDisabled, "version": gorm.Expr("version + 1"), "updated_at": in.Now})
tx.Model(&organization.Group{}).Where("id = ? AND version = ?", in.GroupID, in.ExpectedVersion).
	Updates(map[string]any{"owner_user_id": targetUser.ID, "version": gorm.Expr("version + 1"), "updated_at": in.Now})
tx.Model(&identity.RefreshSession{}).Where("user_id IN ? AND revoked_at IS NULL", []uint64{oldUser.ID, targetUser.ID}).
	Updates(map[string]any{"revoked_at": in.Now, "last_used_at": in.Now})
```

最后写 `platform.group.owner_changed`，summary 只含用户 ID，不含临时密码。为了满足 active owner 唯一索引，应先把旧 membership 降级，再提升目标，且整个事务失败时回滚。

- [ ] **Step 5: 实现 Service 密码哈希与错误映射**

new account 模式仅在 Service 哈希临时密码；Repository 不接收明文。`ErrOwnerTargetInvalid -> OWNER_TARGET_INVALID`，跨组/终态/旧 owner -> `OWNER_TARGET_FORBIDDEN`，username 冲突 -> `USER_USERNAME_EXISTS`。

- [ ] **Step 6: GREEN 并提交 Task 5**

Run: `cd backend; go test ./internal/platform ./internal/authorization ./internal/identity -count=1`

Expected: PASS。

Commit: `git add backend/internal/platform && git commit -m "feat: 支持平台交接组主账号"`

### Task 6: 邀请码创建时加密保存和安全列表

**Files:**
- Modify: `backend/internal/organization/dto.go`
- Modify: `backend/internal/organization/repository.go`
- Modify: `backend/internal/organization/repository_test.go`
- Modify: `backend/internal/organization/service.go`
- Modify: `backend/internal/organization/service_test.go`
- Modify: `backend/internal/organization/handler.go`
- Modify: `backend/internal/organization/handler_test.go`

- [ ] **Step 1: 写加密创建和四状态列表失败测试**

测试创建传入 hash/ciphertext/nonce；返回明文但列表结构中不存在明文/密文字段；`active+未过期 -> active`，`active+已过期 -> expired`，数据库 used/revoked 保持终态；分页稳定排序 `created_at DESC,id DESC`；仅 owner 可访问。

Run: `cd backend; go test ./internal/organization -run 'Invitation|List' -count=1`

Expected: FAIL。

- [ ] **Step 2: 扩展 DTO 和 Repository 接口**

```go
type InvitationDisplayStatus string
const (
	InvitationDisplayActive InvitationDisplayStatus = "active"
	InvitationDisplayExpired InvitationDisplayStatus = "expired"
	InvitationDisplayUsed InvitationDisplayStatus = "used"
	InvitationDisplayRevoked InvitationDisplayStatus = "revoked"
)

type InvitationQuery struct {
	Page int `form:"page" binding:"omitempty,min=1"`
	PageSize int `form:"page_size" binding:"omitempty,min=1,max=100"`
	Status InvitationDisplayStatus `form:"status" binding:"omitempty,oneof=active expired used revoked"`
}

type InvitationSummaryData struct {
	ID uint64 `json:"id"`; Status InvitationDisplayStatus `json:"status"`
	CreatedBy identity.UserSummary `json:"created_by"`; UsedBy *identity.UserSummary `json:"used_by"`
	ExpiresAt time.Time `json:"expires_at"`; UsedAt, RevokedAt *time.Time
	CreatedAt time.Time `json:"created_at"`; Version uint64 `json:"version"`
}

type CreateInvitationInput struct {
	GroupID, CreatedBy uint64; CodeHash string
	CodeCiphertext, CodeNonce []byte; ExpiresAt, Now time.Time
}

type Repository interface {
	CreateInvitation(context.Context, CreateInvitationInput) (*Invitation, error)
	ListInvitations(context.Context, uint64, InvitationQuery, time.Time) ([]InvitationSummaryData, int64, error)
	ConsumeInvitation(context.Context, ConsumeInvitationInput) (*Registration, error)
}
```

- [ ] **Step 3: 在 Service 中绑定 AAD 并加密**

`Service` 构造函数改为：

```go
func NewService(repo Repository, passwords identity.PasswordManager, cipher cryptography.InvitationCipher) *Service
```

创建流程固定为：生成 raw -> hash -> `cipher.Encrypt(raw, groupID, hash)` -> Repository。失败时返回安全的 internal error；创建响应和审计不包含密文/nonce。

- [ ] **Step 4: 实现 SQL 状态投影和列表 Handler**

Repository 使用 `CASE WHEN status='active' AND expires_at <= ? THEN 'expired' ELSE status END AS display_status`，status 过滤应用于同一表达式。Handler 增加 `ListInvitations`，分页 Envelope 沿用既有 `response.Pagination`。

- [ ] **Step 5: GREEN 并提交 Task 6**

Run: `cd backend; go test ./internal/organization -count=1`

Expected: PASS。

Commit: `git add backend/internal/organization && git commit -m "feat: 加密保存并查询邀请码"`

### Task 7: secret 查看、撤销幂等与注册清密文

**Files:**
- Modify: `backend/internal/organization/dto.go`
- Modify: `backend/internal/organization/repository.go`
- Modify: `backend/internal/organization/repository_test.go`
- Modify: `backend/internal/organization/service.go`
- Modify: `backend/internal/organization/service_test.go`
- Modify: `backend/internal/organization/handler.go`
- Modify: `backend/internal/organization/handler_test.go`

- [ ] **Step 1: 写 secret 和撤销状态机失败测试**

覆盖同组 active 未过期可查看；跨组/不存在 -> `INVITATION_NOT_FOUND`；expired/used/revoked/缺密文 -> `INVITATION_NOT_REVEALABLE`；解密失败 -> `INVITATION_DECRYPT_FAILED`。撤销覆盖 active 成功、revoked 旧版本幂等、used/expired 不可撤销、active 旧版本冲突。

Run: `cd backend; go test ./internal/organization -run 'Secret|Revoke|Consume' -count=1`

Expected: FAIL。

- [ ] **Step 2: 定义 secret 与撤销接口**

```go
type InvitationSecretData struct { InvitationID uint64 `json:"invitation_id"`; InvitationCode string `json:"invitation_code"`; ExpiresAt time.Time `json:"expires_at"` }
type RevokeInvitationRequest struct { Version uint64 `json:"version" binding:"required,min=1"` }

type RevealableInvitation struct { ID, GroupID uint64; CodeHash string; CodeCiphertext, CodeNonce []byte; ExpiresAt time.Time }
type RevokeInvitationInput struct { GroupID, InvitationID, ExpectedVersion, OperatorUserID uint64; Now time.Time }

func (r *gormRepository) GetRevealableInvitation(ctx context.Context, groupID, invitationID uint64, now time.Time) (*RevealableInvitation, error)
func (r *gormRepository) RevokeInvitation(ctx context.Context, in RevokeInvitationInput) (*InvitationSummaryData, error)
```

- [ ] **Step 3: 实现单次读取 secret 与 no-store Handler**

`GetRevealableInvitation` 在一次 query 中带 `group_id,id,status='active',expires_at>?` 并读取密文、nonce，禁止 Service 先查状态再二次取密文。Service 解密使用记录自身的 group/hash。Handler 在成功响应前执行：

```go
c.Header("Cache-Control", "no-store")
c.Header("Pragma", "no-cache")
response.Success(c, http.StatusOK, result)
```

- [ ] **Step 4: 实现锁行撤销并清空秘密材料**

`RevokeInvitation` 使用 `SELECT ... FOR UPDATE`，先同组判定，再按状态处理：revoked 直接返回当前摘要；used 或已过期返回 not revokable；active 且 version 不同返回 version conflict；成功更新：

```go
map[string]any{
	"status": InvitationStatusRevoked,
	"revoked_at": in.Now, "revoked_by": in.OperatorUserID,
	"code_ciphertext": nil, "code_nonce": nil,
	"version": gorm.Expr("version + 1"),
}
```

并追加 `organization.invitation.revoked` 审计。

- [ ] **Step 5: 修改注册消费保证终态清密文**

保留 `code_hash FOR UPDATE`。成功消费更新必须同时设置 used 字段、清空 ciphertext/nonce、`version=version+1`。与撤销竞争时，后拿锁者根据最新状态稳定映射：撤销赢则注册返回 `INVITATION_INVALID`；注册赢则撤销返回 `INVITATION_NOT_REVOKABLE`。

- [ ] **Step 6: GREEN 并提交 Task 7**

Run: `cd backend; go test ./internal/organization -count=1`

Expected: PASS。

Commit: `git add backend/internal/organization && git commit -m "feat: 完成邀请码查看撤销生命周期"`

### Task 8: 路由、启动装配与 HTTP 安全契约

**Files:**
- Modify: `backend/internal/infrastructure/httpserver/router.go`
- Modify: `backend/internal/infrastructure/httpserver/router_test.go`
- Modify: `backend/cmd/api/main.go`
- Modify: `backend/tests/openapi_contract_test.go`
- Modify: `backend/internal/organization/handler_test.go`

- [ ] **Step 1: 写路由授权矩阵失败测试**

精确覆盖：平台路径必须通过 Authentication + RequirePasswordChanged + RequirePlatformAdmin；邀请列表/secret/revoke 必须通过 RequireTenantGroup + RequireGroupOwner；普通成员、平台管理员和未改密 owner 均被拒绝。

Run: `cd backend; go test ./internal/infrastructure/httpserver ./tests -count=1`

Expected: FAIL，因为新 handler 尚未装配。

- [ ] **Step 2: 扩展 RouteHandlers 并注册路径**

```go
type RouteHandlers struct {
	Login, Register, Refresh, Logout, Me, ChangePassword gin.HandlerFunc
	CreateGroup, CreateInvitation gin.HandlerFunc
	WebLogin, WebRefresh, WebLogout gin.HandlerFunc
	ListMembers, ChangeMemberStatus, GetMemberPermissions gin.HandlerFunc
	ReplaceMemberPermissions, PermissionCatalog gin.HandlerFunc
	ListDictionaries, CreateDictionary, UpdateDictionary, ChangeDictionaryStatus gin.HandlerFunc
	ListPlatformGroups, GetPlatformGroup gin.HandlerFunc
	ChangePlatformGroupStatus, ChangePlatformGroupOwner gin.HandlerFunc
	ListInvitations, RevealInvitationSecret, RevokeInvitation gin.HandlerFunc
}

platform.GET("/groups", deps.Routes.ListPlatformGroups)
platform.GET("/groups/:group_id", deps.Routes.GetPlatformGroup)
platform.PATCH("/groups/:group_id/status", deps.Routes.ChangePlatformGroupStatus)
platform.PUT("/groups/:group_id/owner", deps.Routes.ChangePlatformGroupOwner)
groups.GET("/invitations", RequireGroupOwner(), deps.Routes.ListInvitations)
groups.GET("/invitations/:invitation_id/secret", RequireGroupOwner(), deps.Routes.RevealInvitationSecret)
groups.PATCH("/invitations/:invitation_id/revoke", RequireGroupOwner(), deps.Routes.RevokeInvitation)
```

- [ ] **Step 3: 在 main 中安全构造 Cipher 和 Service**

启动顺序：`config.Load` 已校验 raw key -> `config.DecodeInvitationEncryptionKey` -> `cryptography.NewInvitationCipher` -> `organization.NewService(repo,passwords,cipher)`。任一步失败时只记录“初始化邀请码加密失败”，不输出 key。

- [ ] **Step 4: 验证 secret 响应和日志不泄密**

Handler 测试序列化响应，断言只有 secret endpoint 的 `data.invitation_code` 可出现明文；列表和错误响应不得含 `invitation_code`、`ciphertext`、`nonce`。secret 成功响应必须包含 `Cache-Control: no-store`。

- [ ] **Step 5: GREEN 并提交 Task 8**

Run: `cd backend; go test ./internal/infrastructure/httpserver ./internal/organization ./tests -count=1`

Expected: PASS。

Commit: `git add backend/internal/infrastructure/httpserver backend/cmd/api/main.go backend/tests/openapi_contract_test.go backend/internal/organization/handler_test.go && git commit -m "feat: 装配平台治理与邀请路由"`

### Task 9: 真实 MySQL 治理、回滚和并发集成测试

**Files:**
- Modify: `backend/internal/infrastructure/database/migrate_mysql_integration_test.go`
- Create: `backend/tests/integration/platform_governance_invitation_flow_test.go`
- Modify: `backend/tests/integration/auth_flow_test.go`

- [ ] **Step 1: 检查 Docker 并准备临时测试 DSN**

Run: `docker context show`

Expected: 当前 context 可用，通常为 `desktop-linux`。

Run: `docker ps -a --filter "name=^/MySQL$"`

Run: `docker inspect MySQL`

Expected: 明确记录容器原始 running/stopped、端口和网络；不得输出环境变量字段。若容器原本停止，只执行 `docker start MySQL`，测试结束执行 `docker stop MySQL`。

- [ ] **Step 2: 写迁移与 owner 唯一性集成测试**

扩展迁移测试：运行全部迁移后断言 `groups.version`、邀请密文/nonce/撤销/version 字段存在；同组插入第二个 active owner membership 必须被唯一索引拒绝；down 测试使用专用临时库，不作用于现有业务库。

- [ ] **Step 3: 写纵向治理集成测试**

`platform_governance_invitation_flow_test.go` 从空临时库完成：bootstrap admin -> 改密 -> 创建两个组 -> 分页搜索 -> 停用组 -> 在 disabled 状态 owner 改为 existing member -> 验证新 owner 暂不能登录 -> 启用组 -> 新 owner 登录 -> owner 再改为 new account -> 验证旧 owner disabled、权限清空、sessions revoked、audit 存在。

为验证“事务最后一步失败也整体回滚”，在专用临时库创建仅拦截 `platform.group.owner_changed` 的 `BEFORE INSERT` trigger 并 `SIGNAL SQLSTATE '45000'`；执行 owner 交接应失败，随后断言 group owner/version、两侧 user/account type、membership/status、permissions 和 sessions 均保持原值，最后删除 trigger。

- [ ] **Step 4: 写邀请码并发和清密文集成测试**

创建两个 invitation：第一个并发执行 register/revoke，断言恰有一方成功，终态匹配胜者；第二个先 reveal 再 consume，断言 consume 后 `code_ciphertext IS NULL AND code_nonce IS NULL` 且 secret 被拒绝。再创建并 revoke，断言同样清空。使用第二个组 owner/principal 对第一个组 invitation 执行 list filter、secret 和 revoke，断言均不能观察或修改跨组记录。

- [ ] **Step 5: 运行真实 MySQL 测试**

在本地安全设置 `TEST_MYSQL_DSN` 和 Base64 密钥后运行：

Run: `cd backend; go test -tags=integration ./internal/infrastructure/database ./internal/identity ./tests/integration -count=1`

Expected: PASS；测试只创建并清理 `cbizdocsmanager_test_*` 临时数据库。

- [ ] **Step 6: 恢复 Docker 原始状态并提交 Task 9**

若 Step 1 发现 MySQL 原本停止，Run: `docker stop MySQL`；随后 `docker ps -a --filter "name=^/MySQL$"` 确认恢复。

Commit: `git add backend/internal/infrastructure/database/migrate_mysql_integration_test.go backend/tests/integration && git commit -m "test: 覆盖平台治理与邀请码并发"`

### Task 10: 后端全量质量门禁与计划完成检查

**Files:**
- Modify only if verification exposes an issue: files already listed in Tasks 1-9

- [ ] **Step 1: 运行格式化和单元测试**

Run: `cd backend; gofmt -w ./cmd ./internal ./pkg ./tests`

Run: `cd backend; go test ./... -count=1`

Expected: PASS；integration build tag 测试按 Go 规则跳过。

- [ ] **Step 2: 运行静态检查和契约测试**

Run: `cd backend; go vet ./...`

Run: `cd backend; go test ./tests -run OpenAPI -count=1`

Expected: PASS。

- [ ] **Step 3: 扫描敏感信息和危险字段**

Run: `rg -n "INVITATION_ENCRYPTION_KEY=.+|code_ciphertext|code_nonce|invitation_code" backend docs/superpowers/plans api/openapi`

Expected: 仅出现环境变量占位符、模型/迁移/测试字段名和创建/secret 合法响应；不得出现真实 key、真实邀请码或把秘密字段放进列表 schema。

- [ ] **Step 4: 检查改动范围并提交修复（如有）**

Run: `git status --short; git diff --check; git diff --stat`

Expected: 无空白错误、无无关改动。若门禁触发修复，重新运行受影响测试并提交：

```bash
git add <Tasks 1-9 中实际修复的文件>
git commit -m "fix: 完善平台治理验证"
```

- [ ] **Step 5: 推送当前 main**

Run: `git fetch origin main; git status --short --branch`

Expected: 当前 `main` 没有与 `origin/main` 分叉。若分叉，停止并请主人决定，不自动 rebase/merge。

Run: `git push origin main`

Expected: 普通 push 成功，禁止 force push。

## 后端验收清单

- 平台管理员可分页搜索组并读取治理详情，不读取租户业务数据。
- 组启停幂等且受 version 保护；停用撤销组内全部 refresh session，启用不恢复。
- 两种 owner 交接均保持每组一个 active owner，旧 owner 降级 disabled、权限清空、会话失效。
- 邀请码只在创建和显式 secret 响应出现明文；列表、日志、审计和错误不泄漏秘密。
- active 邀请可重复查看；expired、used、revoked 不可查看；used/revoked 清空密文和 nonce。
- 注册与撤销竞争由 MySQL 行锁序列化，只允许符合最终状态的一方成功。
- `go test ./...`、`go vet ./...`、OpenAPI 契约测试和 Docker MySQL integration 测试全部通过。
