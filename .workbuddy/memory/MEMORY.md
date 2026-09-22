# CBizDocsManager 项目长期笔记

## 新增业务模块的标准步骤（Task 4/5/6/7 已验证的配方）

每新增一个业务模块（如 Task 7 的收付款开票），按这个顺序做，一次就能全绿：

1. **迁移**：`backend/migrations/00000N_<name>.{up,down}.sql`。表设计三件套 —— 金额列一律
   `DECIMAL(18,2)`（数量 18,3 / 单价 18,4）、`group_id` 必带且加索引、状态列用 ENUM。
2. **七件套**：`internal/<mod>/{model,dto,normalize,service,repository,handler}.go`。
   - `model.go`：实体 + 枚举（含 `IsTerminal()` / `ParseStatus()` / `Label()`）+ 仓储入参结构体。
   - `dto.go`：请求 / 响应。金额字段用 `money.Amount`，大写由服务端生成（`rmb.Upper`）。
   - `service.go`：`resolveScope` 做数据范围收敛 + `mapRepositoryError(operation, err)` 做错误码映射。
   - `repository.go`：所有方法强制带 `group_id`；并发撞唯一索引就重试（不锁表）。
   - `handler.go`：`XxxService` 接口 + `Identity.PrincipalFromContext` 取身份。
3. **错误码**：`pkg/apperror/error.go` 加 `CodeXxx` + `ErrXxx`（须带合适 HTTP 状态）。
4. **路由**：`internal/infrastructure/httpserver/router.go` 加 `XxxRouteSet` + 注册；
   `cmd/api/main.go` 装配 Service 与 Handler；`router_test.go` 同步补路由断言。
5. **契约**：`api/openapi/cbizdocsmanager-v1.yaml` 加 tag / path / path 参数 / schema，
   **ErrorCode enum 必须补**；`backend/tests/openapi_contract_test.go` 补操作与错误码断言 +
   一个 `TestOpenAPIContractXxx`。
6. **测试三层**：`service_test.go`（内存桩，业务规则）+ `repository_test.go`（sqlite，
   真实 SQL）+ `handler_test.go`（gin，协议转换）；单测文件与生产代码同包。
7. **集成测试**：`backend/tests/integration/<mod>_flow_test.go`，带 `//go:build integration`，
   用 `openAuthFlowMySQL(t)`（无 `TEST_MYSQL_DSN` 自动 SKIP）。
8. **验证**：`go build ./...` → `go vet ./...` → `go test ./... -count=1` →
   `go vet -tags integration ./tests/integration/` → 格式检查 → 提交。

## 已确立的关键不变量（新模块必须沿用）

- **金额一律服务端计算，禁止浮点**：`pkg/money` 定点十进制，JSON 用字符串；客户端提交的
  amount 一律忽略。人民币大写由服务端给出（`pkg/rmb`）。
- **业务日期解析统一走 `pkg/bizdate`**（`ParseDate` 兼容 5 种写法并回读校验、`ParseMonth`、
  `FormatMonth` 带横线、`FormatMonthCompact` 紧凑 YYYYMM 用于单号）。不要再各模块自己写一套。
- **单号格式**：单据 `RK/CK + YYYYMMDD + -4位当日序号`；结算 `JS + YYYYMM + -4位当月序号`。
  并发撞车靠唯一索引 + 重试，不用悲观锁。
- **幂等**：`Idempotency-Key` 请求头 + sha256 载荷指纹，共用 `idempotency_records` 表，
  用 `scope` 区分场景（`document.create` / `settlement.create`）。同键同载荷返回首次结果，
  同键异载荷返回 `IDEMPOTENCY_KEY_REUSED`。缺省不带幂等键是合法请求。
- **状态机**：单据 `draft → submitted → voided`；结算 `pending → approved/rejected`（都终态）。
  重新编辑终态返回 `*_STATUS_INVALID`；财务记录无状态机（登记即生效，撤销走硬删除）。
- **乐观锁**：所有可变实体带 `version`，更新条件必须含 `version = ?`，未命中行数报
  `RESOURCE_VERSION_CONFLICT`。
- **数据范围**：主账号（`group_owner` + `member_type=owner`）默认全权限；子账号默认只看本人，
  **未授权返回 false 而非 403**（这是正常业务路径）；看/改他人需 `document.view_others` /
  `document.edit_others`，审批需 `settlement.approve`，登记/撤销财务记录需 `finance.record`。
  注意：**派生视图也要做数据范围校验**（如结清视图要按 `business_user_id` 拦），
  否则成员能靠猜 ID 读他人聚合数据。
- **单据方向口径（finance）**：入库单只涉及付款（不会收款），出库单只涉及收款（无需开票）。
  结清视图不落冗余状态列，一律由 `finance_records` 按 `kind` 合计推导；**不适用方向恒为 0**，
  出库单的开票状态恒为 `not_applicable`（不是 `none`），避免客户端显示假数据。
- **记录类型由路由注入，不接受客户端 `kind`**：Handler 由构造参数决定类型，请求体不声明 kind 字段。
- **累计金额上限在事务内锁单据行校验**：`SELECT ... FOR UPDATE` 锁单据行 → 复检状态/类型 → 锁内 `SUM` 校验上限。
- **财务记录撤销 = 硬删除 + 删对应幂等记录 + 审计**：删幂等记录后同一幂等键可重新登记，额度随之回收。
- **脱敏**：银行卡只存卡号后 4 位（`card_tail CHAR(4)`），完整卡号一律不落库。
- **时间戳用注入时钟**：仓储创建行时显式写 `created_at/updated_at = input.Now`，
  不要让 GORM 取墙上时间——否则「按 created_at 过滤月份」会与按注入时钟生成的单号月份错位。
- **审计**：写 `audit_logs`（`group_id/operator_user_id/action/resource_type/resource_id/summary/created_at`），
  摘要由仓储在拿到单号后统一拼装。

## 环境坑（本机 / 本会话实测）

- 本会话 bash 是受限 shim：**`head` / `tail` / `grep` / `find` / `sleep` / `docker` 全都不可用**。
  不要用 `| head` / `| tail` 过滤命令输出，会把真实输出吞掉并误判成「无输出」。
  要过滤就用 python 脚本，或改用 Read / Grep / Glob 工具。
- `gofmt -l .` 在本仓库会列出几乎所有 `.go` 文件，根因是 `core.autocrlf=true`（工作区 CRLF、
  索引 LF），不是没格式化。判断自己的改动是否合规：把单文件按 LF 归一化后再跑 `gofmt -l`。
- `git push` 依赖的环境代理不稳定，多次出现 `CONNECT tunnel failed, response 502` 或
  `schannel: server closed abruptly`；此时提交照做，推送待网络恢复后重试，不要反复空转。
- 本机沙箱会过滤 `.git/refs/remotes` 的写入：`git fetch` 会打印 `[new branch] main -> origin/main`，
  但随后 `git show-ref` 里**看不到** `refs/remotes/origin/main`，`git branch -vv` 会显示
  `[origin/main: gone]`。这是显示残留、**不代表远端丢提交**。核对是否已推送请用
  `git ls-remote origin refs/heads/main` 与本地 `git rev-parse HEAD` 直接比对哈希。
- 本机 Docker Desktop 引擎未启动，`go test -tags integration` 一律门控 SKIP；
  要跑真实集成需先起 Docker Desktop 并设 `TEST_MYSQL_DSN`。
