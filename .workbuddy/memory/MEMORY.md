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
  2026-09-24 晚（Task 16）又变了：CLI + Docker Desktop 已完整安装（29.0.1），但 **daemon 在
  受限/后台 shell 里拉不起来**——`Docker Desktop.exe` 拉起后进程立即退出、WSL2 后端未初始化、
  `dockerDesktopLinuxEngine` 命名管道不存在，连续 30s `docker ps` 全失败。即「装了 ≠ 能跑」，
  daemon 需要主人**在可交互终端/完整桌面会话里**启动 Docker Desktop。
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
- **dart / flutter 子命令统一走 `.workbuddy/tmp/dart.ps1`**：第一个参数是**用哪个可执行文件**
  （`dart` / `flutter`），之后原样透传 —— `dart.ps1 dart format <files>`、
  `dart.ps1 flutter analyze`、`dart.ps1 flutter test <path> -r expanded`。
  内部清代理 + UTF-8 无 BOM 落日志 + 显式 `exit $LASTEXITCODE`，日志路径用 `CBIZ_DART_LOG` 覆盖。
  （别在 ps1 里把子命令当成可选参数：`& $exe $Tool @Args` 与 `& $exe @Args` 只能选一种，
  写错的表现是 `Could not find a command named "lib/features/..."`。）
  **本机 bash shim 跑不了 dart / flutter**（`ls` / `dirname` 都缺），只能用 PowerShell。
- **写 git 提交信息文件不要用 `Out-File -Encoding UTF8`**：Windows PowerShell 5.1 会加 UTF-8 BOM，
  于是提交标题变成 `\ufefffeat: ...`。用 Write 工具或 .NET UTF8Encoding($false) 写。
  自检脚本：`.workbuddy/tmp/check_bom.py`（扫最近提交标题是否以 BOM 开头）。
- **本机 `dart format` 报 Changed 不要先归因于 CRLF**：`client/` 下的文件实测是**纯 LF**，
  `dart format` 只在真需要折行 / 调缩进时才报（超过 80 列未折行最常见）。
  判断方法：用 Python 统计 `\r\n` 与孤立 `\n`。git 打印的 `LF will be replaced by CRLF`
  只是 `core.autocrlf=true` 的提示，无害。
- **跨端构建的三个环境阻塞（Task 17 实测）**：
  - **Android**：Gradle 在沙箱里报 `FileNotFoundException ...\9.1.0\transforms\xxx.lock
    (拒绝访问)`，重试换了个 hash 仍复现 ⇒ 沙箱对 Gradle **文件锁机制**的干扰，不是单个
    stale lock（删掉报错那个也没用）。
  - **Windows**：plugin symlink 阻塞 —— `PathExistsException: Cannot create link ...
    .plugin_symlink`，根因**开发者模式未启用**（计划 Step4 预料到）。
  - **Windows 另有一坑**：`client/build/windows/CMakeCache.txt` 是**旧路径
    `d:/CodeStudy/ProjectF/`**（项目从 ProjectF 搬到了 CBizDocsManager），CMake 报
    `source does not match`。修法：删 `client/build/windows/` 重建（build 在 gitignore 里，无损）。
  - Web 构建不依赖上述任何一点，✅ 直接成功。
- **⚠️ D 盘长期处于「满」的边缘（2026-09-24 实测被顶爆）**：跑测试撞
  `ENOSPC: no space left on device`，D 盘物理只剩 1.6MB。大头全是主人个人数据
  （SteamLibrary 22GB、CodeStudy 29GB、WeChat Files 13GB、QQ 10GB、Temp 7GB 等）。
  Android/Windows 构建会生成 2GB+ 中间产物（`client/build/app` 就近 2GB），很容易顶爆。
  **教训**：① 跑构建前先 `Get-PSDrive D` 探剩余；② `client/build/` 是再生缓存、可安全删
  （等价 flutter clean）；③ 个人文件（Steam/微信/QQ/网盘）**绝不动**，清理需主人决定；
  ④ 建议主人把 Gradle/构建缓存挪到 C 盘（还有 54GB）。本次已清 `client/build` 腾出 2GB。

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
- **客户端单据/结算/报表**：见
  `docs/superpowers/plans/2026-09-24-flutter-documents-settlements-reports.md`（12 个 Task）。
  三个必踩的口径坑（后端契约已定，客户端 fromJson 要对齐）：
  1. 金额/单价/数量 JSON 一律**字符串**，客户端定点整数/BigInt、禁 double；
     人民币大写信任服务端 `*_upper`，不自实现 rmb。
  2. **单据列表行的 `business_user` 只回填 `id`+`display_name`**，`username`/`account_type`
     是零值空串 ⇒ 单据列表行用 `DocumentBusinessUser`（宽松解析，只强校验 id+display_name）；
     而**结算/财务/报表的 `requester`/`operator`/`decided_by`/`business_user`/`created_by`
     是完整 UserSummary** ⇒ 一律用 core 的 `AuthUser`（`aeb6b72` 时曾叫 `SettlementUser`，
     `9efa534` 已合并去重；严格解析，account_type 走 `AccountType.fromWireValue`，
     空串/未知抛错）。两者是**不同的类型**，别混用。
     **唯一例外**：报表**公司维度快照**的 `business_user` 是全零值（id=0/username 空），
     要按「id 是否为正整数」解析成 `null`（`report.dart` 的 `_readOptionalUser`），
     不能 strict 解析（会抛）。
  3. 单据/结算/财务/报表的分页是**平铺** `items/page/page_size/total`，复用 `PageResult`
     （区别于成员/字典那种嵌套 `pagination`）。
- **客户端定点金额/日期工具已就绪（Task 1 交付，`aeb6b72`）**：
  - `core/money/money.dart`：`Amount`(分/scale2)、`UnitPrice`(万分之一元/scale4)、
    `Quantity`(千分之一/scale3)，不可互换、内部 BigInt、禁 double；`Amount.mul` 对齐后端
    `money.Mul`（余数×2>=除数进位、负数向负）。
  - `core/bizdate/bizdate.dart`：`parseDate` 兼容 5 种写法+回读校验、`parseMonth` 只收
    `YYYY-MM`（月份不补零）、`formatMonth`/`formatMonthCompact`。
  新模块（单据/结算/财务/报表）一律用这两个包，不要再各写一套。
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
- **`ServerFieldErrorsMixin<T extends StatefulWidget>`（`form_feedback.dart`）**：
  四个表单页（登录 / 注册 / 改密 / 新建业务组）共用的「服务端逐字段错误」状态。
  实现方只需给出 `formFieldNames`（本页真正渲染了输入框的契约字段名）与 `formKey`，然后：
  `validateRequired` / `validateMinLength`（**服务端错误优先于本地规则** —— 服务端知道得更多，
  比如「该账号已被占用」本地判断不了）、`clearServerError(field)`（用户一改就清，
  否则「组名已存在」会一直挂着，哪怕用户已经改名）、`presentFieldErrors(presentation)`
  （每条错误都能挂到本页输入框才内联并返回 true，否则返回 false 让调用方弹条 ——
  同一条错误不说两遍）、`clearAllServerErrors()`、`showMessage()`。
  抄四遍的必然结果是有三份会漏掉「用户一改就清」。
- **`PasswordField`（`password_field.dart`）**：自带「显示 / 隐藏」开关的密码框，5 处密码输入共用。
  可见性状态留在组件内部**不上传**。手写一遍就会在某一处漏 `obscureText`（明文显示在屏幕上）
  或漏 tooltip（读屏用户听到一个没有名字的按钮）。`autofillHints` 固定为空数组：
  登录账号是组内自建的，让系统猜「保存的密码」只会给错候选。
- **Widget 测试坑**：有 `CircularProgressIndicator` 时只能 `pump()`，`pumpAndSettle()` 会因无限动画超时；
  点导航项要用 `find.descendant(of: find.byType(NavigationBar), matching: find.text(label)).first`，
  否则可能点到 AppBar 同名标题上、变成「什么都没发生却通过」。
- **`find.text()` 连 `EditableText` 的 controller 内容一起匹配**。断言「密码没泄漏到提示里」时
  `find.text('secret')` 会命中输入框自己那条 `EditableText`，红得莫名其妙。
  要断言「没有哪个 Text 拿着它」就用 `find.widgetWithText(Text, ...)`，
  要断言「提示条里没有它」就 `find.descendant(of: find.byType(SnackBar), matching: ...)`。
## Flutter 认证与会话约定（client/lib/core/auth/）

- **`AuthController.login` 失败后必须落 `AuthPhase.unauthenticated`，不能保留原 phase。**
  初始状态是 `AuthState(restoring)`；失败若保留 `restoring`，守卫只允许 `restoring` 停在
  `/splash` ⇒ 用户会被**永久留在启动页**上出不来。（`changePassword` 正相反：必须保留已有会话，
  不能把人踢下线。）登录的语义就是「试图建立会话」，没建立起来就一定是未登录。
- **三个认证流程的失败传递方式不同，不要统一**：`login` / `changePassword` 把详情写进
  `state.failure` 并**吞掉异常**（页面 `await` 后读一次 `state.failure` 即可，UI 层不用再包
  try/catch —— 那一层迟早有人忘了写，而「点了登录什么也没提示」是最难受的一种坏）；
  只有 `register` **原样 rethrow**，因为它的返回类型 `RegistrationResult` 表达不了失败，
  而调用方必须区分成败（成功要跳回登录页）。
  两者都用同一条读数判据：开工时会重建一个不带 failure 的状态 ⇒ `await` 之后读到的非空
  `failure` 一定属于本次。
- **注册不建立会话**：服务端不签发令牌，成功后 `loginPrefill = result.username`，
  页面 `context.go('/login')`（用 go 不用 push，免得返回栈里留着用过的注册表单），
  登录页在 `initState` 里读 `loginPrefill` 预填。
- **`AuthSession.scopeKey`** 是会话级依赖的装配键：账号 / 所属组 / 角色 / 改密态 /
  权限集合**任一变化**都会得到不同 key，供 Riverpod 整体销毁并重建会话级 Provider。
- **强制改密页刻意不渲染任何业务导航**（传空 `destinations`）：强制改密期间所有业务地址都会被
  守卫弹回本页，摆一排点了就回来的导航项只会让用户以为功能坏了。但**必须**留「退出登录」——
  一个拿不到旧密码的用户不该被永久锁死在这一页上。
- **已知遗留（属 `core/network`，尚未动手）**：`ApiClient.canRefresh` 只排除了 `/auth/refresh`
  与已重试的请求，**没排除 `/auth/login` / `/auth/web/login`** ⇒ 密码输错（401）会触发一次
  无意义的令牌刷新（native 无刷新令牌 / web 无 CSRF，必然失败 ⇒ `clearSession()` + invalidator）。
  最终结果碰巧是对的（失败详情随后照样落进状态），但多跑一次往返、还顺手清了一次会话状态。

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

## Flutter 成员与权限数据层约定（client/lib/features/members/）

- **缓存的权威性以「是否带筛选」划界**：`MemberQuery.isUnfiltered`（keyword 只有空白
  也算没筛）为真时才写本地缓存、断网时才回退缓存；**带筛选一律不写也不回退** ——
  写会让全量缓存变残缺（而缓存是断网时唯一的兜底，缺了就没东西能纠正），
  回退等于把全量冒充成筛选结果，用户会看到一堆不匹配的成员还以为筛选生效了。
- **成员缓存表不存账号 ID**：`_readCachedMembers` 把 `Member.userId` 填 0 当哨兵
  （契约 `UserSummary.id` 是 `minimum: 1`，撞不上真实账号）。界面判断「这一行是不是
  我自己」只认 `userId == profile.user.id`，**绝不用 username 比**（用户名可改）；
  对缓存数据一律判不出来 —— 宁可少禁用一次按钮（服务端还会再拒），也不靠猜。
- **权限目录必须来自服务端**（`GET /groups/permission-catalog`），客户端不维护自己的一份：
  本地写死的清单会在后端新增权限码之后变成「少一项」，而整体替换权限时会顺手把那一项清掉。
  目录不写本地缓存、断网也不回退。
- **权限快照（`MemberPermissions`）守与邀请码明文同样的规矩**：换目标先清旧的再拉，
  否则用户会拿上一个人的勾选状态当基线去改，保存下去就是把 B 的权限换成 A 那一套。

## Flutter 辅助字典约定（client/lib/features/dictionaries/）

- **`DictionaryKindRules` 扩展是唯一的口径来源**（`domain/dictionary_entry.dart` 的
  `label` / `acceptsContactPhone` / `requiresParent` / `usesParent`），规则直接来自后端
  `validateDraft`，**不是界面偏好**：只有 `customer` 接受 `contact_phone`（其余 kind 带上即
  `VALIDATION_FAILED`）；非型号 kind 带 `parent_id` 判 `DICTIONARY_PARENT_INVALID`；
  只有 `product_model` 的 `parent_id` **必填**，且父级必须是**启用中的** `product_name`；
  `name` 上限按 **rune** 计 191。（Task 13 的计划文档把口径写成了「supplier / customer 都显示
  contact phone」，与后端和 foundation 设计文档都不符 —— **以后端 + 设计文档为准**。）
- **`DictionaryQuery.status == null` = 「只看启用中」，不是「全部」**：契约里根本没有
  「两种状态一起返回」的取值（服务端无 `status` 参数时收敛成 active，显式 `disabled` 需要
  `dictionary.manage`）。所以状态筛选只有两项、`null` 同时是本地兜底缓存的写入判据，
  本地合并判断也必须同口径（`entry.status == (query.status ?? active)`），
  否则刚停用的条目会继续留在「启用中」的列表里，看起来像筛选没生效。
- **父级候选与主列表必须分开**（`DictionaryState.parentOptions`）：六 kind 共页，主列表是当前
  筛选的 kind，父级候选固定是 `product_name` 的 active；混进 `items` 会让主列表凭空多出一批品名。
  **刻意不做「已拿到就跳过」的缓存** —— 用户刚在别处新建了品名，下拉里必须能看到；
  调用点只有两个（切到型号、打开型号 editor），每次重拉的代价远小于「看不到刚建的数据」。
- **写结果合并必须双向**：匹配当前筛选 → 替换 / 追加；**不匹配 → 摘掉**；
  **匹配但不在列表里 → 补回去**。只做前两个会漏掉「连续两次写」（停用 → 启用、或两次快速
  改状态）：第一步已把条目摘掉，第二步的写结果走替换分支时列表里没有可替换的行，
  条目就永久消失 —— 而服务端下一次全量查询一定会把它带回来，表现为「刷新一下又有了」。
  补的时候追加在末尾即可（服务端排序依据客户端并不知道，别猜位置）。
- **页面级角色裁剪**：状态筛选只对有 `dictionary.manage` 的人显示；本地残留的「已停用」选择在
  权限丢失时一律退回默认口径（绝不发一个必然 403 的请求）；行里的父级品名不在候选里就
  **如实显示 `品名 #id`**，不要编名字（品名可能刚被停用，也可能这次就没拉到候选）。
- **editor 里父级下拉的 `initialValue` 不在 items 里时（父级被停用）必须补一个占位项**，
  否则 `DropdownButton` 会直接断言「value 不在 items 里」把对话框搞崩。页面上的父级筛选
  下拉同理。

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
  默认结果」三档优先级的可编程假仓储，新模块的 Controller 测试可照这个模式写
  （字典模块的 `fake_dictionary_repository.dart` 还多了「按 kind 分流」的 `byKind`：
  六 kind 共页时主列表与父级候选是**两路并发 list**，只有一个 `entries` 兜底会拿到同一批数据）。
- **假仓储的写方法必须返回「变更后的实体」**：真实的 `create` / `update` / `changeStatus`
  都返回修改后的那一条，控制器正是靠它把新状态合回本地列表。假实现原样返回旧条目（或
  `entries.first`）会让「停用后条目从筛选里消失」这类断言测的是一个**假前提** ——
  红得莫名其妙，而且会把排查方向带偏（看起来像合并逻辑错了）。
  默认就**按入参合成实体**（`changeStatus` 造 status 改后且 version+1 的副本；`update` 应用
  draft 但不动 status；`create` 用 `maxId+1` 造新条目），只在刻意要造固定数据时才用
  `writeResult` 直接覆盖；引用了不存在的 id 直接 `throw`（用例自己写错就该红在看得懂的地方）。
  三个写方法用 `async` + `throw`，与「返回失败的 Future」语义一致且没有同步抛的时序差异。
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
- **绝不在 `State.dispose()` 里同步改 Riverpod 状态**：那一刻本 Element 已进入 defunct
  状态，Riverpod 把新 state 推给订阅者时会 `markNeedsBuild` → 撞
  `_lifecycleState != _ElementLifecycle.defunct` 断言（线上同样会抛，不只是测试问题）。
  要做「离开页面就清掉」的状态（邀请码明文就是），写成
  `scheduleMicrotask(controller.clearSecret);` —— 推到下一个微任务，等卸载流程走完、
  订阅已摘掉再清，那次改动只落在状态里、不触发 build。
  另外要记住：会话作用域里的 provider 是**非 autoDispose** 的（要跨页面复用），
  所以「路由离开」不会销毁 Controller，`ref.onDispose` 只是作用域销毁时的兜底，
  **页面侧必须自己显式清一次**。
- **页面测试里断言「某个 widget 不在」要当心空态退化**：像 `InvitationSecretPanel`
  在没有明文时 build 出 `SizedBox.shrink()`，但 widget 本身仍在树上，
  `find.byType(X), findsNothing` 永远失败。判据换成「它渲染的那句话还在不在」。
  同理 `find.byTooltip` 命中的是 `Tooltip` 而不是 `IconButton`（取按钮用
  `find.widgetWithIcon`），`find.textContaining` 会同时命中列表与弹层（用 `descendant` 收窄）。

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
- **但「输入型」表单是例外，要自带写操作**（`DictionaryEditorDialog`）：上面那条针对的是
  **确认型**对话框；一旦输入是用户一个字一个字敲出来的，失败丢回页面 + 立刻关掉就等于他敲的
  一屏因为一次网抖全没了。所以约定成：校验失败 / 网络失败**内联横幅展示并保持打开**，
  只有**成功**与**乐观锁冲突**才关闭 —— 冲突时手里那个 version 已作废、重试必然再失败，
  回列表看最新数据才是唯一正确动作。结果用 sealed 值交回页面
  （`Saved` / `Conflict(failure)` / null=取消），不要用「可空 draft 兼职表达失败」。
  配套：写操作在途时 `PopScope(canPop: false)` + 禁用取消按钮；页面在对话框开着时
  **抑制自己的 SnackBar**（`_editorOpen` 判据），否则同一条错误说两遍、还会被对话框挡住。
  判断「本次写失败」不用另开返回值：`_write` 开工时会 `clearFailure`，
  所以 `await` 之后读到的非空 `state.failure` 一定是本次造成的。
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
  **但认证 / 角色落点这类用例是例外，要走真实的 `routerProvider`**：
  手搭几条 GoRoute 会把「落点由守卫算出来」整个测没，剩下一个自己导航给自己看的假流程。
  已封成 `test/support/real_router_harness.dart` 的 `pumpRealApp(tester, repository:)` ——
  装配假仓储 → `pumpWidget` → 调一次 `restore()` → 守卫自动把人送到
  `/login`（未登录）/ `/change-password`（待改密）/ `/home`（正常），**调用方不需要自己 go**。
  配套 `expectTenantHome()`（限定 `find.widgetWithText(AppBar, '首页')`，
  因为租户壳的导航项也叫「首页」，全树搜索会命中两次）与
  `expectDestination(label, visible: …)`（同时查 `NavigationRail` 与 `NavigationBar` 子树，
  断言就不依赖窗口宽度）。
- **纵向闭环测试用 `HttpClientAdapter` 假后端，别 mock 单个 Repository**
  （`test/support/fake_backend.dart`）：写一个内存状态机塞进真实 Dio，复刻
  `bootstrap.dart` 的装配（Dio + ApiClient 拦截器 + DefaultAuthRepository + 内存凭据库），
  再 pump `CBizDocsApp`。这样才能验证「跨模块状态真的流动」（组交接后旧 owner 令牌失效、
  身份降级）。三条铁律：假后端内部虽持有密码/令牌/邀请码明文，但 `toString` 只打印资源数量、
  失败记录只记 `method path -> code`（不记请求体）；`/auth/me` 必须实现（登录/改密后都用原
  令牌重读）；改密走 Authorization 头识别当前账号、只清该账号的改密标记。测试侧坑见
  `flutter-widget-testing` 技能第八节（宽屏表格文字按钮 vs 窄屏 tooltip、连续 pump 两个 app
  第二个 restore 卡 splash、`ensureVisible`、剪贴板 mock、`退出登录` 按钮非每页都有）。
- **点下拉 / 菜单里的某一项要用 `find.text(label).last`**：下拉**打开后**，按钮自己显示的
  那一项（当前值）会与菜单里的同一项一起命中 `find.text(label)`，唯一匹配的写法直接
  `Found 2 widgets` 报错。实测（初始值 `A`、选项 `A`/`B`）：关闭态 `A=1 / B=0`，
  打开态 `A=2 / B=1` —— 未选中项在关闭态**找不到**，会撞重复的只有「点回当前已选中的那一项」，
  点其它项仍只有一个匹配。菜单走在 overlay 上的新路由、遍历排在页面内容之后，
  所以 `.last` 在两种场景下都取到菜单项。封装成 `_tapMenuItem(tester, label)` 复用。
  （纠错：曾有「`DropdownButton` 把所有选项塞进 `IndexedStack`、未选中项也命中」的说法，实测不成立。）
- **SnackBar 的 4 秒定时器不需要在用例里跑完**：实测「弹完 SnackBar 直接结束用例」不会报
  「还有定时器没结束」，收尾不会因此变红。`_settleSnackBar`（`pump(5s)` + `pumpAndSettle()`）
  是可选的防御性清理，不是必需项。（纠错：曾误记成必需。）
- 后端 `ValidationErrors` 产出的 field 名就是契约里的 snake_case
  （`name` / `owner_username` / `owner_display_name` / `owner_temporary_password`），
  客户端可直接按契约字段名挂错误。
- **租户侧导航只有一处定义：`tenantDestinations(AuthProfile?)`**
  （`features/home/presentation/tenant_shell.dart`）。成员 / 成员权限 / 字典 / 邀请码 / 首页
  五页全部复用它。**此前每页各持有一份「单项」列表，而 `ResponsiveScaffold` 在目的地 < 2 时
  根本不渲染导航** —— 等于整条租户链路没有导航，业务员在字典页想去首页只能手改地址。
  规则：owner 得 `首页/邀请码/成员/字典`；普通成员恒得 `首页/字典`，
  只在 `hasPermission('member.manage')` 时补 `成员`；**普通成员永远没有邀请码入口**；
  `profile == null` ⇒ 返回**空列表**（宁可不显示，也不猜一个身份 ——
  猜成 owner 会让刚被降权的账号继续看见管理入口）。
  平台侧同理，参考 `platformDestinations`。
- **主账号的 `permission_codes` 恒为空数组**（权限是隐式的，靠 `accountType` 判）。
  任何「照着 `permission_codes` 裁剪导航 / 写入口 / 渲染权限摘要」的写法都会**把主账号的
  管理入口全砍掉**，必须走 `AuthProfile.hasPermission`（内部已处理主账号）。
  首页的权限摘要同理：不能照 `permission_codes` 渲染，那会得出「没有任何权限」
  这种与事实相反的画面，要说「组内全部权限」。
- **角色裁剪是两个不同的判定，别混**：
  `canManageStatus = 组主账号 || hasPermission('member.manage')`（改状态）；
  `canManagePermissions = accountType == groupOwner`（改权限）。
  **把授权入口交给被管理者等于给他一条自己给自己提权的路**；判 `accountType` 而不是权限码，
  因为 `hasPermission` 对 owner 恒真、判权限码会放行持码的普通成员。
- **受保护行由共享的 `MemberRowActions.isProtected` 统一判定**，卡片与表格共用同一套规则
  （各写一遍，用户切到宽屏就会看到不一样的入口）。保护两类：**组主账号**（停用他等于整个组
  没人能管理）与**当前账号自己**（停用自己是不可逆自锁，下一请求就 401），
  判定只认 `member.userId == profile.user.id`，**绝不用 username 比**（用户名可改，
  改过之后「自己」那一行会突然认不出来，本该禁止的操作重新变得可点）。
- **本地草稿（未提交的表单意图）不写回 Riverpod state**：权限替换页的 `_draft` 是
  「还没提交的意图」，写回 `MemberState.permissions` 会让列表页也看到一份没保存的权限，
  且「用户改主意了」无处安放。草稿**按 `version` 播种**（`_draftVersion` 不等才重播）：
  保存成功 / 冲突后重读 / 换目标都会换 version，不重播就会拿过期基线去**整体替换**。
  提交完整集合 + 快照里的 version（整体替换没有 version 就没有乐观锁）。
  没有改动时要禁用保存按钮（白点一次就是一次无意义的乐观锁冲突来源）。
- **「目录为空」不等于「目录之外」**：客户端不维护权限清单，`目录之外的权限码`（成员身上有、
  目录里没有）必须保留在草稿里、可取消勾选 —— 因「目录里没写」就静默丢弃，等于让管理员在
  毫不知情的情况下收回一项权限。但**只有拿到目录之后才谈得上「目录之外」**：
  目录为空（加载中/失败）时每个码都会被算成「目录之外」，会凭空弹出一段误导说明，
  所以渲染条件写成 `catalog.isNotEmpty && extraCodes.isNotEmpty`。
- **一页有多个失败出口时要去重**：权限页的三个出口 —— 无快照交给 `AsyncStateView` 整页呈现、
  目录为空由正文里那张「权限目录加载失败」卡片承担（自带重试）、其余才飘 SnackBar
  （冲突附「重新加载」动作）。判据 `shownInline = !hasSnapshotNow || catalog.isEmpty`，
  再配合 `!identical(failure, previous?.failure)`。**409 只重读 + 保留提示，绝不自动重提** ——
  替用户重提等于替他做了一个他并不知道自己在做的决定，而整体覆盖的代价很大。
- **同类页面的 `parseXxxId` / `xxxRedirect` 共用一套判定但保留两个具名函数**：
  `parseMembershipId` 与 `parseGroupId` 都转发 `_parsePositiveId`（正整数、下界 1），
  调用点读出来就是「成员编号」「组编号」——读错语义时没人拦得住你。
