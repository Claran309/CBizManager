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

## Flutter 客户端（`client/`）约定与门禁

- **身份的唯一事实源是 `/auth/me` 响应体，客户端绝不解析 JWT 声明**。`AuthProfile.fromJson`
  是**严格**解析：身份组合自相矛盾（平台管理员带 group/memberType、主账号 member_type≠owner、
  成员 member_type≠member、缺 `permission_codes`）一律抛 `FormatException`，不静默降级成
  「权限更宽」的对象。新增身份字段时同步补 `AuthProfile` 与契约 `MeData`。
- **`AuthSession.scopeKey`**（`user:group:accountType:memberType:mustChangePassword:权限排序`）
  是会话级 Provider 的重建键；账号 / 组 / 角色 / 改密态 / 权限任一变化都会整体销毁重建。
- **注册不建立会话**：`/api/v1/auth/register` 只回 `user` + `group`（没有令牌），成功后必须停在
  未登录态并把用户名回填登录页；否则新人被静默当成已登录，**绕过登录页与强制改密两道关**。
- **改密复用同一个 access token**：后端 `ChangePassword` 既不吊销当前令牌也不签发新的，
  所以客户端改完密码要**用原令牌重读 `/auth/me`**，不能重新登录、不能把密码写进任何本地存储。
- **改密失败必须保留原已登录会话**（只写 `state.failure`），否则用户会以为被登出。
- **Controller 的错误处理按返回类型分**：返回 `void` 的方法按项目既有约定只写 `state.failure`
  （不抛）；返回**业务值**的方法（如 `register` 返回 `RegistrationResult`）必须把 `AppFailure`
  原样抛出——调用方要区分成功与失败（成功要跳回登录页），而返回值无法用空值表达失败。
- **所有 Dio 适配器都要包一层 `_guard`**，把 `DioException` → `mapDioFailure`、
  `FormatException`/`TypeError` → `ServerFailure`。否则原始 `DioException` 会逃逸出状态机，
  `state.failure` 永远拿不到值、字段错误也映射不到输入框。
  `DioAuthRemoteDataSource` 原先是漏的（Task 2 补齐）。
- **改接口就要立刻 `flutter analyze`**：给 `abstract interface class` 加方法会让**所有**测试替身
  编译失败（`non_abstract_class_inherits_abstract_member`），`flutter test` 不一定先报这个。
- **客户端门禁三道**：`dart format --output=none --set-exit-if-changed lib test` →
  `flutter analyze` → `flutter test`。

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
- **本机环境（及宿主注入的子进程环境）带 `HTTP_PROXY` / `HTTPS_PROXY` 指向本机代理端口，
  这是 `flutter test` 全盘失败的头号原因**：测试框架在 127.0.0.1 起 harness 服务，`flutter_tester`
  要直连完成 WebSocket 握手，`dart:io` 的 `HttpClient` 尊重 `HTTP_PROXY` 把握手塞给代理，于是报
  `Unable to connect to flutter_tester process: WebSocketException: Invalid WebSocket upgrade request`。
  **判据**：连改动前的旧测试文件也一起挂 ⇒ 环境故障，不要改代码。
  取证：`flutter test <旧文件> --verbose`，在 `Starting flutter_tester process with command=`
  那一行的 `environment={...}` 里能看到注入的 `HTTP_PROXY`。
  修法：跑前 `Remove-Item Env:HTTP_PROXY,Env:HTTPS_PROXY,Env:ALL_PROXY` 并
  `$env:NO_PROXY='127.0.0.1,localhost,::1'`。宿主可能每轮重新注入，**每次都要清**。
  现成包装脚本：`.workbuddy/tmp/flutter_test.ps1`（已封装清代理 + 编码 + 落日志）。
- **抓 flutter 日志不能用 PowerShell 的 `*>` / `Out-File`**：flutter 输出 UTF-8，而 PowerShell 按
  系统代码页（GBK）解码子进程输出，中文用例名会变成 `韬綋鐭╅樀` 这种乱码，
  且 `Read` 会报 "Cannot display content of binary file"。正确做法：先设
  `[Console]::OutputEncoding = [System.Text.Encoding]::UTF8`，把输出**捕获进变量**，
  再用 `[System.IO.File]::WriteAllText(..., New-Object System.Text.UTF8Encoding($false))` 落盘。
- **PowerShell 工具在本会话不返回 stdout**，`Write-Output` 看不到结果 ⇒ 一律写文件再 `Read`。
- **写 git 提交信息文件不要用 `Out-File -Encoding UTF8`**：Windows PowerShell 5.1 会加 UTF-8 BOM，
  于是提交标题变成 `\ufefffeat: ...`。用 Write 工具或 .NET UTF8Encoding($false) 写。
  自检脚本：`.workbuddy/tmp/check_bom.py`（扫最近提交标题是否以 BOM 开头）。
- **本机 `dart format` 报 Changed 不要先归因于 CRLF**：`client/` 下的文件实测是**纯 LF**，
  `dart format` 只在真需要折行 / 调缩进时才报（超过 80 列未折行最常见）。
  判断方法：用 Python 统计 `\r\n` 与孤立 `\n`。git 打印的 `LF will be replaced by CRLF`
  只是 `core.autocrlf=true` 的提示，无害。

## Flutter 客户端（client/）既有约定与坑

- **身份只从 `/auth/me` 响应体读取，绝不解析 JWT 声明**；`AuthSession.scopeKey`
  由 user/group/角色/改密态/权限集合拼成，作为「会话作用域」的重建键。
- **Provider 分两层**（`client/lib/app/session_scope.dart`）：
  - 应用级、跨会话共享：`dioProvider` / `appDatabaseProvider` / `nativeCacheEnabledProvider`；
  - 会话级、不设默认实现（误读即抛 `StateError`）：`activeSessionProvider` 与各业务 Repository。
  应用外壳 `app.dart` 只在已登录时包 `AuthenticatedSessionScope`
  （`ProviderScope(key: ValueKey(session.scopeKey))`），登出即卸载销毁旧作用域。
- **Riverpod 3 传递式作用域必须显式声明 `dependencies:`**：只声明了
  `$allTransitiveDependencies` 的 Provider 才会被挂到「覆盖了其依赖项的那个容器」，
  否则退回根容器被所有会话共享。Controller 若只通过**方法里的 `ref.read`** 取仓储，
  Riverpod 无从推断 ⇒ 必须在 `NotifierProvider(..., dependencies: [xxxRepositoryProvider])`
  手写一行，否则换账号/换组后旧数据会跟过来。
- **Notifier dispose 后写 `state` 会抛错**：Controller 用 `_disposed` 标记
  （`ref.onDispose` 里置位）作废在途结果；排队的写操作要在调用时**先取好 Repository**，
  因为 dispose 之后再碰 `ref` 同样会抛。
- **Riverpod 3 把 provider 内部异常包成 `ProviderException`（`.exception` 才是原始错误）**
  再交给 `read` 调用方；`overrides` 装配阶段抛的错则是裸异常。
  `Override` / `ProviderException` 不在主入口导出，需
  `import 'package:flutter_riverpod/misc.dart' show ...`。
- 同一容器重复覆盖同一 Provider 会被断言拦下
  （`Tried to override a provider twice within the same container`）。
- 渲染真实 App 的 Widget 测试必须像 `bootstrap` 一样提供 `dioProvider`，
  否则 `AuthenticatedSessionScope.build` 当场抛 `Dio has not been configured`。
- **改 `abstract interface class` 后立刻跑 `flutter analyze`**：`flutter test` 不一定先报
  漏实现（`non_abstract_class_inherits_abstract_member`），analyze 才会。
## Flutter 路由与守卫（client/lib/app/router.dart）

- **12 条稳定路由**：`/splash` `/login` `/register` `/change-password`
  `/platform/groups` `/platform/groups/new` `/platform/groups/:groupId`
  `/home` `/invitations` `/members` `/members/:membershipId/permissions` `/dictionaries`。
  **字面量路由必须声明在参数路由之前**（`/platform/groups/new` 否则会被
  `/platform/groups/:groupId` 抢成 `groupId='new'`）。
- **守卫判定顺序即语义**（`authRedirect`，导出 `isPublicLocation` /
  `isPlatformLocation` / `isOwnerOnlyLocation` / `isMemberManagementLocation` / `roleHome`）：
  restoring → 未登录 → 强制改密 → 平台/租户分域 → owner 专属 → `member.manage` → 过渡页。
  - 未登录判 `session == null`（不是 `phase == unauthenticated`），顺带兜住 release 下
    断言失效的「已登录却无会话」。
  - 强制改密**优先于**角色分域；owner 专属判 `accountType`，不判权限码
    （`hasPermission` 对 owner 恒真，判码会放行持码的普通成员）。
  - **无权地址统一回角色首页**（`roleHome`：平台管理员 `/platform/groups`，其余 `/home`），
    绝不回登录页——合法登录态被踢回登录页像被登出，且回角色首页才能根除循环。
- **占位页按「后续任务的最终路径」落盘**：`features/<feature>/presentation/<page>.dart`，
  每个路由一个具名可替换目标类（不用共用的 `_RouteShell`）。后续任务只替换文件内容，
  不必再改路由 import；若把占位类写在 `router.dart` 里，后面建真实类时会撞名。
- 路由测试用 `UncontrolledProviderScope` + 自建 `ProviderContainer`，
  可直接 `container.read(routerProvider).go('/deep/link')` 模拟深链。
## Flutter 展示层约定（client/lib/core/presentation/）

- **`ResponsiveScaffold`**：断点 `kResponsiveScaffoldBreakpoint = 720` 逻辑像素。
  窄屏 `Scaffold + AppBar + NavigationBar`；宽屏 `AppBar + Row(NavigationRail | VerticalDivider | Expanded(body))`。
  `AppDestination{label, icon, route}` 只描述「叫什么/长什么样/去哪」，两种布局共用一份。
  - 高亮解析：先精确匹配，再取**最长**路径前缀（`/members/7/permissions` → 点亮「成员」）。
  - 点当前项**直接 return**，不 `context.go`，否则重建页面会丢滚动位置与未提交表单。
  - `build` 里 assert：AppBar 的 `IconButton` 必须提供 `tooltip`。
  - 框架约束：`NavigationBar.selectedIndex` 是非空 `int` 且要求 `destinations.length >= 2`；
    `NavigationRail.selectedIndex` 是 `int?`。所以索引用 `int?`，Rail 直传、Bar 传 `?? 0`。
  - **`destinations` 少于 2 项时整个导航都不渲染**（`hasNavigation = destinations.length >= 2`），
    否则会撞上 `NavigationBar` 的 `length >= 2` 断言直接崩 —— 平台管理员只有「组管理」
    一项，正是这种情形。退化后就是一块普通内容区，该分支有独立测试守着。
- **`AsyncStateView`**：加载/失败/空/内容四态统一视图，判定顺序
  **失败 > 加载 > 空 > 内容**。要「刷新时保留旧列表」就传
  `isLoading: isLoading && items.isEmpty`。`loadingMessage` / `emptyMessage` 可覆盖。
  **实现为无类型参数**（计划写作 `AsyncStateView<T>`，但 T 不出现于该 API 任何位置）。
- **`FailurePresenter.present(AppFailure)` → `FailurePresentation{message, fieldErrors,
  requestId, shouldLeavePage, shouldRefresh}`**：
  Validation 保留服务端 message + fields；Conflict 丢弃底层文案换固定话术 + `shouldRefresh`；
  Forbidden `shouldLeavePage`；**Unauthenticated 两个标记都不设**（全局单飞刷新 + 守卫负责跳转，
  页面再跳会抢跑）；Network 文案必须点明「需要联网」；Server 带 requestId。
  失败视图 Request ID 用 `SelectableText`（唯一用途是被复制走），
  冲突时按钮文案变「重新加载」、其余「重试」。
- **Widget 测试坑**：有 `CircularProgressIndicator` 时只能 `pump()`，`pumpAndSettle()` 会因无限动画超时；
  点导航项要用 `find.descendant(of: find.byType(NavigationBar), matching: find.text(label)).first`，
  否则可能点到 AppBar 同名标题上、变成「什么都没发生却通过」。
## Flutter 平台治理数据层约定（client/lib/features/platform/ + core/network/page_result.dart）

- **列表分页字段是平铺的**：本项目所有列表接口把 `items / page / page_size / total`
  直接放在响应 `data` 里（`GroupPageData`），**不是**嵌一层 `pagination`。
  字典那个接口才是嵌 pagination 的，别互相照抄。统一走
  `PageResult<T>.fromJson(data, decodeItem)`（`core/network/page_result.dart`），
  它严格校验（items 必须是对象数组、page/pageSize >= 1、total >= 0），
  非法结构一律 FormatException —— 宁可报错也不放行会被渲染成「翻不到头的空列表」的数据。
- **领域解析一律严格**：缺字段 / 类型不符 / 时间串非法都抛 `FormatException`
  （仓储的 `_guard` 会收敛成 `ServerFailure`）。枚举用 `fromWireValue`，
  未知取值抛错，不做静默降级。时间统一 `DateTime.parse(v).toUtc()`。
- **平台仓储只持有 Dio**，**不接 AppDatabase / Outbox**：平台管理员没有 group，
  缓存键只能落到 `group_id=0`；而停用整组、交接主账号是全局破坏性操作，离线排队
  偷偷执行比当场失败危险。有测试守着「跑完全部方法后本地库与 Outbox 全空」。
- **`platformRepositoryProvider` 定义在 `features/platform/data/platform_repository.dart`
  （data 层）**，默认抛 StateError；`session_scope.dart` 里**只有 platformAdmin 分支**
  用 `DioPlatformRepository(appDio)` override，租户分支不装配（读取抛 StateError）。
  这是与 member/dictionary（provider 定义在 application 层的 controller 文件里）
  不同的地方：因为 Task 6 要先能在 session_scope 里 override，而 controller 是 Task 7 才建。
- **交接主账号 `changeOwner` 是「PUT 后再 GET 详情」两次请求**：契约的写响应
  `OwnerChangedData{group, owner}` 不含 `member_counts` / `owner_candidates`，
  而方法返回类型是 `PlatformGroupDetail`。重读换来的是自洽数据（被提升者已从候选人消失）。
  写假适配器时**必须按 method 分发响应**，否则重读那步会拿到写响应而解析失败。
- **两种交接模式（existing_member / new_account）用 sealed class + `switch` 穷尽匹配
  拼互斥请求体**，不是「大对象 + 可空字段」：新增模式会编译报错；测试断言另一种模式的
  字段一个都不能出现（多带会让服务端 400，或更糟，被忽略而让人以为生效了）。
- **`GroupMemberCounts` 三个键必填且非负**：契约把它写成松散 map，但缺键退化成 0
  会显示「活跃成员 0 人」这种会让人以为组被清空的假数字；Go 的 `map[string]int`
  零值键不会消失，严格假设成立。
- **可选查询参数用「有才带」写法**（`if (x != null) 'k': x`）：显式传 null 会序列化成空串，
  服务端按非法枚举拒绝，于是「不筛」反而报 400。
- **Dart 语法坑**：命名构造函数**不能**带类型参数（`factory PageResult.fromJson` 才对，
  调用处照写 `PageResult<int>.fromJson`）；sealed 基类要写成命名参数
  `const Base({required this.version});`，子类才能 `required super.version`。

## Flutter Controller 约定（client/lib/features/*/application/）

**每个会话级 Controller 都要有三件套**（member / dictionary / platform 都已照此实现）：

1. `_loadGeneration`：`load` 开头 `++`，回来时 `if (!_disposed && gen == _loadGeneration)`
   才允许写 state —— 先发的请求晚回来时不能覆盖后发那次的结果。
2. `_writeTail`：写操作经 `_enqueueWrite(op)` 排队，`_writeTail.then((_) => op())`，
   尾巴上挂空错误处理（某次写失败不能让后续写永远开不了）。返回的是本次操作的结果。
3. `_disposed`：`build()` 里 `ref.onDispose(() { _disposed = true; _loadGeneration++; })`；
   写操作**先取好仓储**再进队列（dispose 后碰 `ref` 会抛），每个写入点前判 `_disposed`。

- **Provider 必须声明 `dependencies: [...]`**，否则 Riverpod 3 的传递式作用域不会把它
  挂到会话作用域上（详见上一节）。
- **Riverpod 3 的 family 没有 `FamilyNotifier`**：创建函数是 `NotifierT Function(ArgT)`，
  arg 从 **notifier 的构造函数**进来（`MyController(this.groupId)`），`build()` 仍无参：
  `NotifierProvider.family<C, S, int>(C.new, dependencies: [...])`。
  用**非 autoDispose**（会话作用域整体销毁即可；autoDispose 的 family 在测试里
  `container.read(x.notifier)` 会立即销毁，必须额外挂 listen）。
- **409 的处理分两层**：列表页只保留 failure（让 FailurePresenter 的 `shouldRefresh`
  驱动提示，自动刷新会冲掉翻页位置）；详情页保留 failure **并** `await load()` 重读。
  重读顺序不能反 —— `load()` 内部会 `clearFailure`，必须**先 await load 再放回冲突原因**；
  若重读也失败，保留那个更新的失败（`if (state.failure == null)` 才放回冲突）。
  文案遵循「刷新不等于成功」：写操作失败后数据可能已经变了，但没变成用户要的样子。
- **写成功后要用服务端回的新摘要替换本地那一份**（列表行 / 详情摘要），让 `version`
  跟着涨，否则用户紧接着再操作同一条会白撞一次 409。
- **防重复提交 = 「判空 + 置位」之间不夹 await**：`if (state.isSubmitting) return null;`
  紧跟 `state = state.copyWith(isSubmitting: true);`，一旦中间有 await 就失效。
- **写操作不替调用方改写 version**：不可逆操作（交接主账号）宁可让服务端 409 +
  重读详情让用户重新确认，也不要拿旧界面的意图去盖新数据。
- **导航用状态驱动而非回调**：创建成功把 `createdGroupId` 放进 state，页面 watch 到非空再跳，
  跳前调 `reset()`（避免返回时重复跳转）。回调在页面卸载后触发会操作已销毁的 Context。
- 测试夹具：`test/support/fake_platform_repository.dart` 是「排队响应 → 注入错误 →
  默认结果」三档优先级的可编程假仓储，新模块的 Controller 测试可照这个模式写。
- **敏感明文（邀请码）只活内存**：唯一承载字段是 state 的 `visibleSecret`；查看前先清旧
  （一次只留一份）、撤销成功 / 撤销冲突 / 刷新后列表里不再 active / 列表找不到 / `onDispose`
  都清。`InvitationSecret.toString` 主动隐藏 code，否则断言失败会把明文打进测试输出与堆栈。
- **「该操作需要联网」这类文案归展示层**（`FailurePresenter` 按失败类型补），仓储层只产出
  `NetworkFailure` 类型 —— 仓储层测试断言 `throwsA(isA<NetworkFailure>())` 就够，别断言文案。
- **Dart 集合的可选字段用 null-aware 元素**：`{'k': ?maybeNull}` 与
  `if (x != null) 'k': x` 等价，但 lint `use_null_aware_elements` 只接受前者；
  「判空的是 key 变量、值表达式本身非空」（如 `'status': status.wireValue`）**不能**换 `?`，
  这种情况保持 `if (x != null)` 写法。发可选字段的空 body 要发 `{}` 而非 null（服务端
  `ShouldBindJSON` 在空 body 上报 EOF）。

## Flutter 页面层约定（client/lib/features/*/presentation/）

- **平台侧三个页面共用 `platform_shell.dart`** 的 `platformDestinations` /
  `groupStatusLabel` / `GroupStatusChip`：文案散落各文件迟早出现「列表页叫『已停用』、
  详情页叫『停用』」这种不一致。
- **表单的服务端字段错误必须合进 validator**：`TextFormField` 内部会
  `copyWith(errorText: _errorText.value)`，validator 返回 null 时就把
  `decoration.errorText` 抹成 null —— 挂在 decoration 上等于没挂。做法是失败时
  `setState` 存 `fields` 再 `_formKey.currentState!.validate()` 重跑；
  配套每个字段 `onChanged` 清掉自己的服务端错误。只有「每条错误都能落到本页字段」时
  才不弹提示条（否则同一错误说两遍）。
- **不要用 `RadioListTile.groupValue` / `onChanged`（已废弃，会让 analyze 非零退出）**：
  单选列表用 `ListTile(selected:, leading: Icon(radio_button_checked/unchecked), onTap:)` 自绘。
  （`DropdownButtonFormField.value` 也已改名 `initialValue`；`DropdownButton.value` 没有改。）
- **路由参数非法用 `redirect`，不要在 builder 里 `go()`**（构建期间导航会撞断言）。
  决策抽成纯函数 `parseGroupId` / `groupDetailRedirect` 以便零副作用断言；
  提示经 query 传参（`?notice=invalid_group_id`，地址栏与内容一致），
  页面在 `initState` 首帧后弹 SnackBar，**并在 `didUpdateWidget` 补一次** ——
  同页只换 query 时 `initState` 不会再跑，不补用户就完全看不到反馈。
- **对话框只收意图**：`ChangeOwnerDialog.show(...)` 返回 sealed draft 或 null，
  自身不发请求、不碰 Provider，页面拿到非空才调 Controller。候选人空时默认落
  `new_account` 模式（existing 模式无边可选，把用户丢在空列表前是最没必要的挫败）。
  两种模式控件互斥（`SegmentedButton`），避免「两组都填」造出自相矛盾的请求。
- **列表页按内容区宽度（`LayoutBuilder` 的 constraints）而非屏幕宽度切换卡片/表格**：
  宽屏左侧有导航栏，用屏幕宽度会让表格挤进一条比实际更窄的缝里。
- **失败呈现分档**：已有数据时只弹 SnackBar（冲突附「刷新」动作），不把整张表/整页
  换成错误视图；只有「什么都没有」的首次加载失败才交给 `AsyncStateView` 整页呈现，
  同一条错误不会说两遍。
- **页面测试不要套真实 App 壳**（`CBizDocsApp` 会由会话作用域装配**真实 Dio**），
  改「最小 GoRouter + `ProviderScope(overrides: [repo.overrideWithValue(fake)])`」；
  `Override` 必须从 `package:flutter_riverpod/misc.dart` 导入，主入口没有它。
  断言「提交中禁用」时请求挂在未完成的 `Completer` 上、只 `pump()` 一帧
  （按钮已换成 spinner，`pumpAndSettle` 会超时）。
- 后端 `ValidationErrors` 产出的 field 名就是契约里的 snake_case
  （`name` / `owner_username` / `owner_display_name` / `owner_temporary_password`），
  客户端可直接按契约字段名挂错误。
