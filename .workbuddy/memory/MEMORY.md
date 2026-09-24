# CBizDocsManager 项目长期笔记

## 新增业务模块的标准步骤（Task 4/5/6/7 已验证的配方）

每新增一个业务模块（如 Task 7 的收付款开票、汇总统计），按这个顺序做，一次就能全绿：

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
  **每个写路径都必须传 `Now`，幂等记录与审计记录同样要**：漏传会落零值日期，MySQL 严格模式直接
  `Error 1292: Incorrect datetime value '0000-00-00'` 拒绝写入（SQLite 容忍，单测查不出来）。
  document 模块的 `Service.Create` / `Update` 就漏了，是真跑集成测试才抓到的。
- **邀请码与组治理（organization / platform）**：邀请码状态 `active/used/revoked/expired`，
  **撤销是幂等的**（对已撤销的再撤销静默成功并返回 revoked，不报错——设计文档明确写了「撤销幂等」）；
  查看明文在 used/expired/revoked 后返回 `INVITATION_NOT_REVEALABLE`。
  **owner 交接后旧主账号降级为 member 且 `status=disabled`（停用）**，权限记录被清空，两人刷新会话都撤销；
  停用账号登录统一返回 `AUTH_INVALID_CREDENTIALS`（防账号枚举，不是 `AUTH_ACCESS_INACTIVE`）。
  组启停：目标状态与当前一致时幂等成功且**不涨 version**。
- **审计**：写 `audit_logs`（`group_id/operator_user_id/action/resource_type/resource_id/summary/created_at`），
  摘要由仓储在拿到单号后统一拼装。
- **汇总统计（reporting）特有口径**：
  - **只有「看全组」一种数据范围，无权限直接 403**（不是返回空报表——空报表会让人误以为「本月确实没数据」）。
    权限复用 `report.view`（看板与生成总结算共用一个码）。
  - **只统计 `status=submitted`**；已付 / 已收 / 已开金额**不按发生日期过滤**（取余额口径）；
    **未结清单据数逐单比较**（总额相减会被多付/少付互相抵消而藏匿）。
  - **明细行不含已付 / 未付**：付款挂在单据而非明细，摊派到明细是「假精确」。合计块才是单据粒度精确值。
  - **比率一律用百万分之一整数（ppm）**：`207500 = 20.75%`，`big.Int` 先乘 1e6 再四舍五入；展示文本由服务端给。
  - **快照即冻结**：`report_snapshots` 与 `settlements` 分开两张表（快照无审批流、不占用源单据）；
    快照无 `version` 列、无修改接口，要更正只能重新生成。业务员姓名随快照冻结落库。
  - 单号 `ZJS + YYYYMM + -4位当月序号`；**批次号取本批第一张快照的单号**；**审计逐张写**（不是整批一条）。

## GORM / MySQL 方言坑（SQLite 单测查不出，必须真跑 MySQL）

- **`groups` 是 MySQL 8.0 保留字**（窗口函数的 `GROUPS` 帧单位）。GORM `Table()` 有两条分支：
  - 传**不含空格/反引号**的纯表名 → 走标识符引用路径，自动加反引号并正确设置 `Statement.Table`。
    实测 `Table("groups")` + `First()` → ``FROM `groups` WHERE id = ? ORDER BY `groups`.`id` LIMIT ?`` ✅
  - 传**含空格或反引号**的串 → 当原样 SQL 输出、**不做任何转义**：`Table("groups AS g")` 直接
    `Error 1064`，必须手写 `Table("`groups` AS g")`。
  - **陷阱**：带别名的写法会让 `Statement.Table` 落空，所以**只有后续用 `Count`/`Scan`
    （不依赖 `Statement.Table`）时才可手写反引号**；若配 `First()` 手写反引号会拼出
    ``ORDER BY `.`id`` 的语法错误——那种情况保持 `Table("groups")` 原样交给 GORM。
- **`Scan(&[]SomeDTO)` 的 DTO 不能带嵌套结构体字段**：GORM 会当成关联关系解析并报
  `invalid field found for struct ...: define a valid foreign key for relations`。
  做法：先用扁平的匿名行结构体接住结果，再手工组装成 DTO（`platform.GetGroupDetail` 踩过）。
- 其余已知差异：`DATETIME(6)` 只到微秒（纳秒时钟读回会截断）；DECIMAL 在 SQLite 会以 REAL 落库。

## 环境坑（本机 / 本会话实测）

- 本会话 bash 是受限 shim：**`head` / `tail` / `grep` / `find` / `sleep` / `docker` 全都不可用**。
  不要用 `| head` / `| tail` 过滤命令输出，会把真实输出吞掉并误判成「无输出」。
  要过滤就用 python 脚本，或改用 Read / Grep / Glob 工具。
- `gofmt -l .` 在本仓库会列出几乎所有 `.go` 文件，根因是 `core.autocrlf=true`（工作区 CRLF、
  索引 LF），不是没格式化。判断自己的改动是否合规：把单文件按 LF 归一化后再跑 `gofmt -l`。
- `git push` 依赖的环境代理不稳定，多次出现 `CONNECT tunnel failed, response 502` 或
  `schannel: server closed abruptly`；此时提交照做，推送待网络恢复后重试，不要反复空转。
- **远端是 HTTPS（`github.com/Claran309/CBizManager.git`），凭据助手是 `helper-selector`**，
  它需要交互式终端才能取凭据。在受限 / 后台 shell 里推送（或 `git ls-remote`）会先被代理拖到
  超时（实测单次 24~37 分钟），最终报 `fatal: could not read Username for 'https://github.com':
  terminal prompts disabled`。**这不是提交出错、也不需要改仓库配置**——提交在本地是安全的，
  应在能力所及时由主人在可交互终端执行 `git push origin main`，或等代理恢复后重试。
  另外：`helper-selector` 只出现在本地 config（`git config credential.helper`），
  `--global` 里没有，`~/.git-credentials` 也不存在。
- 本机沙箱会过滤 `.git/refs/remotes` 的写入：`git fetch` 会打印 `[new branch] main -> origin/main`，
  但随后 `git show-ref` 里**看不到** `refs/remotes/origin/main`，`git branch -vv` 会显示
  `[origin/main: gone]`。这是显示残留、**不代表远端丢提交**。核对是否已推送请用
  `git ls-remote origin refs/heads/main` 与本地 `git rev-parse HEAD` 直接比对哈希。
- **Docker 可用性会变，每次先 `docker ps` 实测，不要照搬历史结论**。2026-09-23 之前本机 Docker
  完全不可用（`docker` 命令与 `com.docker.service` 都查不到），`-tags integration` 一律门控 SKIP；
  2026-09-24 主人启动后容器 `MySQL`（3306）已 healthy，7 个集成测试**首次真跑**并一次抓出
  4 个只在真实方言下才犯的错（保留字未转义、嵌套 struct 误判关联、零值日期、微秒截断）。
- **真跑集成测试的方法**：`.workbuddy/tmp/run_integration.py` —— 等 3306 就绪 → 从
  `docker inspect MySQL` 读 `MYSQL_ROOT_PASSWORD`（脱敏，不落盘不打印）→ 给子进程注入
  `TEST_MYSQL_DSN=root:<pwd>@tcp(127.0.0.1:3306)/?charset=utf8mb4` → 跑 go test，可带 `-run` 正则。
- Docker 不可用时的**替代验证手段**：在薄弱包内临时写只跑纯函数 / 纯聚合的测试，用同一批数据喂真实函数
  逐项比对（如 reporting 用 `newPeriodTotals` / `buildOverviewData` 复核毛利率与占比），通过后删除临时文件。
  但它**覆盖不到 DB 方言层**，凡涉及 SQL 的改动最终必须真跑 MySQL。
- 集成测试夹具易错点：出库单**提交时必须带 `sale_amount_type`**（否则 `DOCUMENT_INCOMPLETE`），
  共享 helper 造出库单别漏这个字段。
- 集成测试断言易错点：`created_at` 列是 `DATETIME(6)`（微秒），而代码里用的是纳秒时钟，
  **不要逐位比较时间**，改成「差在一毫秒以内」判定。
