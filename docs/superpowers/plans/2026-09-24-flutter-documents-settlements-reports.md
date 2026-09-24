# CBizDocsManager Flutter 单据·结算·报表实现计划

## 前置条件与执行边界

- 后端契约已全部就绪：`document`（入库/出库单据）、`settlement`（结算审批）、
  `finance`（收付款开票）、`reporting`（汇总报表）四个模块的 API、OpenAPI schema、
  真实 MySQL 集成测试均已完成。本计划只做 Flutter 客户端的对应数据层与页面。
- 复用上一计划已确立的客户端底座：`PageResult`（平铺分页）、`ApiEnvelope` /
  `error_mapper`、`FailurePresenter`、`ResponsiveScaffold`、`ServerFieldErrorsMixin`、
  `PasswordField`、`tenantDestinations`、`pumpRealApp` / `FakeBackend` 纵向闭环测试基座。
- 本计划实现中性、响应式、可用的功能壳，**不冻结品牌视觉**；正式原型到达后替换
  Theme 与页面布局，不改 Repository/Controller API。
- 直接在 `main` 执行，不创建分支或 worktree；每个 Task 独立测试和提交。
- **金额铁律**：所有金额/单价/数量在传输层一律是**字符串**；客户端用定点整数 /
  `BigInt` 表示与运算，**禁止 `double`/`num` 参与任何金额计算**。人民币大写**信任
  服务端 `*_upper` 字段直接展示，不自实现**。
- 写操作（单据、结算、财务登记、快照生成）全部在线执行，不进 Outbox。
- Windows build 只有在宿主机启用开发者模式、可创建插件 symlink 时才可宣称成功；
  否则记录环境阻塞，`flutter analyze` / `flutter test` / Android / Web 仍须执行。

## 文件边界

- `client/lib/core/money/`：定点金额 / 单价 / 数量（新增，对齐后端 `pkg/money`）。
- `client/lib/core/bizdate/`：业务日期 / 月份解析与格式化（新增，对齐后端 `pkg/bizdate`）。
- `client/lib/features/documents/`：单据 domain、remote repository、controller、填写页与历史页。
- `client/lib/features/settlements/`：结算 domain、repository、controller、列表与详情审批页。
- `client/lib/features/finance/`：收付款开票 domain、repository、controller、登记与结清视图。
- `client/lib/features/reports/`：报表 domain、repository、controller、看板与各统计页。
- `client/lib/app/router.dart`：新增单据/结算/财务/报表的路由与守卫。
- `client/lib/features/home/presentation/tenant_shell.dart`：租户导航增补新入口。
- `client/test/`：money / bizdate 单测、各 domain 的 fromJson 契约测试、repository 测试、
  controller 测试、页面测试，以及纵向闭环集成测试。

## 关键口径速记（写代码时对照，全部来自后端契约）

1. **金额三件套**：金额 `DECIMAL(18,2)`（分）、单价 `DECIMAL(18,4)`（万分之一元）、
   数量 `DECIMAL(18,3)`（千分之一）。JSON 一律字符串，如 `"146982.33"` / `"2975.4300"` /
   `"17.050"`。
2. **单号三套**：单据 `RK/CK + YYYYMMDD + -4位当日序号`；结算 `JS + YYYYMM + -4位当月序号`；
   总结算 `ZJS + YYYYMM + -4位当月序号`。
3. **状态机三套**：单据 `draft → submitted → voided`（voided 终态）；结算
   `pending → approved/rejected`（都终态，单级审批）；开票状态
   `none/partial/full/not_applicable`（服务端推导，出库单恒 `not_applicable`）。
4. **权限码七个**：`document.view_others`、`document.edit_others`、`report.view`、
   `member.manage`、`dictionary.manage`、`settlement.approve`、`finance.record`。
   主账号（group_owner）隐式拥有全部，走 `AuthProfile.hasPermission`。
5. **`business_user` 嵌套陷阱**：单据**列表行**只回填 `id` + `display_name`
   （`username` / `account_type` 可能缺失），`fromJson` 不能强校验这两个字段；
   结算/财务/报表里的 `requester` / `business_user` 才是完整 `UserSummary`。
6. **分页是平铺** `items/page/page_size/total`，直接复用 `PageResult`（区别于成员/字典
   那种嵌套 `pagination`）。
7. **金额一律服务端算**：明细行的 `amount` = 单价×数量 由服务端计算，客户端提交的
   amount 被忽略（请求里不收 amount）。
8. **财务 `kind` 由路由决定**：`payment→入库单`、`receipt→出库单`、`invoice→入库单`，
   请求体不含 kind。结清视图三类金额服务端按记录合计推导，不适用方向恒 0。

---

### Task 1: 定点金额与业务日期工具

**Files:**
- Create: `client/lib/core/money/money.dart`
- Create: `client/lib/core/bizdate/bizdate.dart`
- Create: `client/test/core/money_test.dart`
- Create: `client/test/core/bizdate_test.dart`

- [ ] **Step 1: 写 money 与 bizdate 失败测试**

money：解析 `"146982.33"` → 分（定点 int）；拒绝科学计数法、拒绝超精度非零尾数
（`"1.999"` 对 Amount 报错）、去千分位逗号与 `+` 前缀；`format` 补零到 scale；
`add` / `sub` / `mul(单价×数量四舍五入到分)`；`isZero` / `isNegative`。
bizdate：`ParseDate` 支持 5 种写法（`2026-09-22` / `2026/9/22` / `2026 3 14` /
`2026年3月14日` / `20260922`），回读校验拒绝 `2026-02-31`；`ParseMonth` 只收 `YYYY-MM`；
`FormatMonth` 带横线、`FormatMonthCompact` 紧凑 `YYYYMM`。

Run: `cd client; flutter test test/core/money_test.dart test/core/bizdate_test.dart`

Expected: FAIL。

- [ ] **Step 2: 实现 money**

内部用 `BigInt`（分 / 万分之一元 / 千分之一），提供 `Money`（scale 可配）或三个具名
类型 `Amount`(2) / `UnitPrice`(4) / `Quantity`(3)。`parse(String)` 严格校验、`format()`
补零到 scale、`mul` 单价×数量 `/10^5` 四舍五入到分、算术返回新实例不原地改。

- [ ] **Step 3: 实现 bizdate**

`parseDate` 折叠分隔符（`-`/`/`/空格/`年月日`）后解析，年份 `[2000,2100]`，回读校验；
`parseMonth` 只收 `YYYY-MM`；`formatMonth` / `formatMonthCompact`；`businessDate` 的
字符串表示统一 `YYYY-MM-DD`（给请求）与展示格式化分开。

- [ ] **Step 4: GREEN 并提交 Task 1**

Commit: `git add client/lib/core/money client/lib/core/bizdate client/test/core && git commit -m "feat(client): 添加定点金额与业务日期工具"`

### Task 2: 单据 domain 模型与严格解析

**Files:**
- Create: `client/lib/features/documents/domain/document.dart`
- Create: `client/test/features/documents/document_domain_test.dart`

- [ ] **Step 1: 写 fromJson 失败测试**

覆盖 `DocumentSummary`（列表行，business_user 只认 id+display_name、不读 username）、
`DocumentDetail`（含 parties[].items[]、金额字段全是 string、`total_amount_upper`）、
`DocumentKind` / `DocumentStatus` / `SaleAmountType` / `PriceTaxMode` 的 wire 值解析，
非法取值抛 FormatException；`amount` 字段非 string 抛错。

- [ ] **Step 2: 实现 domain**

枚举 + wire 值 + `fromWireValue`；`DocumentSummary.fromJson` / `DocumentDetail.fromJson` /
`DocumentParty.fromJson` / `DocumentItem.fromJson`；金额字段存 `Money` 或原始 string
（展示直接透传 string，运算交给服务端）。请求草稿 `DocumentDraft`（含 parties/items 的
可编辑结构，金额不参与客户端计算）。

- [ ] **Step 3: GREEN 并提交 Task 2**

Commit: `git add client/lib/features/documents/domain client/test/features/documents && git commit -m "feat(client): 添加单据领域模型与严格解析"`

### Task 3: 单据 remote repository 与契约测试

**Files:**
- Create: `client/lib/features/documents/data/document_repository.dart`
- Create: `client/test/features/documents/document_repository_test.dart`

- [ ] **Step 1: 写 repository 契约测试**

用 `HttpClientAdapter` 记录请求，断言：`list` 打 `GET /inbound-documents`（或 outbound）
带对 query；`create` POST body 不含 `kind`/`amount`、含 `business_date`/`parties`；
`update` 带 `version`；`submit`/`void` POST body 只带 `version`；响应解析走信封。
金额字段在请求里是 string。

- [ ] **Step 2: 实现 `DioDocumentRepository`**

`list(query)` → `PageResult<DocumentSummary>`；`get(id)` → `DocumentDetail`；
`create/update(draft, version)`；`submit(id, version)`；`voidDocument(id, version)`。
`kind` 由构造参数决定（`inbound` / `outbound` 两个装配实例），路径前缀据此拼。
所有方法走 `_guard` + `mapDioFailure`。

- [ ] **Step 3: GREEN 并提交 Task 3**

Commit: `git add client/lib/features/documents/data client/test/features/documents && git commit -m "feat(client): 添加单据远端仓储与契约测试"`

### Task 4: 单据 controller（乱序、串行写、草稿）

**Files:**
- Create: `client/lib/features/documents/application/document_controller.dart`
- Create: `client/test/features/documents/document_controller_test.dart`

- [ ] **Step 1: 写 controller 测试**

覆盖：列表加载乱序丢弃（generation）、写操作串行（writeTail）、草稿不写回 state、
提交/作废后重读详情保留失败原因、乐观锁冲突后重读列表。

- [ ] **Step 2: 实现 controller**

沿用既有 Controller 约定（`dependencies` 声明 + `_disposed` + `_loadGeneration` +
`_writeTail`）。列表查询条件、详情缓存、写结果用 sealed 值交回页面（`Saved` /
`Conflict(failure)` / `Failed(failure)`）。

- [ ] **Step 3: GREEN 并提交 Task 4**

Commit: `git add client/lib/features/documents/application client/test/features/documents && git commit -m "feat(client): 添加单据控制器"`

### Task 5: 单据填写页与历史页

**Files:**
- Create: `client/lib/features/documents/presentation/document_form_page.dart`
- Create: `client/lib/features/documents/presentation/document_history_page.dart`
- Modify: `client/lib/app/router.dart`
- Modify: `client/lib/features/home/presentation/tenant_shell.dart`
- Create: `client/test/features/documents/document_pages_test.dart`

- [ ] **Step 1: 写页面失败测试**

填写页：明细行增删、金额只读展示（不参与输入）、日期走 bizdate 解析、提交/作废按
状态机裁剪；历史页：按方向/状态/月份筛选、卡片/表格两布局无 overflow。
写入口按 `document.edit_others`（主账号）与本人（无 view_others 只看本人）裁剪。

- [ ] **Step 2: 实现填写页**

中性壳 + 单据头（业务日期、业务员、备注、出库单的 shipping_unit / sale_amount_type）
+ 往来单位分组 + 明细行（品名/型号/单位/数量/单价/价税方式）。金额由服务端算，
客户端只填数量单价、展示服务端返回的 amount 与大写。

- [ ] **Step 3: 实现历史页**

复用 `ResponsiveScaffold` + `tenantDestinations`，列表用 `PageResult` 分页，筛选
（方向由路由决定、状态、月份、关键字）。

- [ ] **Step 4: GREEN 并提交 Task 5**

Commit: `git add client/lib/features/documents client/lib/app/router.dart client/lib/features/home/presentation/tenant_shell.dart client/test/features/documents && git commit -m "feat(client): 添加单据填写与历史页"`

### Task 6: 结算 domain、repository、controller

**Files:**
- Create: `client/lib/features/settlements/domain/settlement.dart`
- Create: `client/lib/features/settlements/data/settlement_repository.dart`
- Create: `client/lib/features/settlements/application/settlement_controller.dart`
- Create: `client/test/features/settlements/settlement_data_test.dart`
- Create: `client/test/features/settlements/settlement_controller_test.dart`

- [ ] **Step 1: 写数据层失败测试**

fromJson 严格解析 `SettlementSummary` / `SettlementDetail`（sources、approval_records、
金额 string、大写）；repository 契约：`create` body `{remark, sources:[{document_id}]}`、
`approve`/`reject` body `{version, remark?}`、驳回必填 remark 由本地校验。

- [ ] **Step 2: 实现 domain + repository + controller**

结算 domain（状态 pending/approved/rejected、Action）；`DioSettlementRepository`；
`SettlementController`（列表 + 详情 + 创建 + 审批，串行写）。

- [ ] **Step 3: GREEN 并提交 Task 6**

Commit: `git add client/lib/features/settlements client/test/features/settlements && git commit -m "feat(client): 添加结算数据层"`

### Task 7: 结算列表与详情审批页

**Files:**
- Create: `client/lib/features/settlements/presentation/settlement_list_page.dart`
- Create: `client/lib/features/settlements/presentation/settlement_detail_page.dart`
- Modify: `client/lib/app/router.dart`
- Modify: `client/lib/features/home/presentation/tenant_shell.dart`
- Create: `client/test/features/settlements/settlement_pages_test.dart`

- [ ] **Step 1: 写页面失败测试**

列表按状态/月份筛选；详情展示源单据、金额、审批记录；审批按钮按 `settlement.approve`
裁剪；驳回必须填备注（本地拦，不发请求）。

- [ ] **Step 2: 实现页面**

- [ ] **Step 3: GREEN 并提交 Task 7**

Commit: `git add client/lib/features/settlements client/lib/app/router.dart client/lib/features/home/presentation/tenant_shell.dart client/test/features/settlements && git commit -m "feat(client): 添加结算列表与审批页"`

### Task 8: 财务登记、结清视图

**Files:**
- Create: `client/lib/features/finance/domain/finance.dart`
- Create: `client/lib/features/finance/data/finance_repository.dart`
- Create: `client/lib/features/finance/application/finance_controller.dart`
- Create: `client/lib/features/finance/presentation/finance_page.dart`
- Modify: `client/lib/app/router.dart`
- Modify: `client/lib/features/home/presentation/tenant_shell.dart`
- Create: `client/test/features/finance/finance_test.dart`

- [ ] **Step 1: 写失败测试**

`FinanceRecord` / `FinanceStatement` fromJson（金额 string、结清视图派生字段、
invoice_status 枚举）；repository：`create` body 不含 kind、`revoke` 硬删；
`method` 三态字段互斥（transfer 不带 card_tail、private_card 必带 card_tail、public_account 都不带）。

- [ ] **Step 2: 实现 domain + repository + controller + 页面**

kind 由装配决定（payment/receipt/invoice 三个实例）；结清视图展示已付/已收/已开与
未付/未收/未开（服务端推导）；登记入口按 `finance.record` 裁剪。

- [ ] **Step 3: GREEN 并提交 Task 8**

Commit: `git add client/lib/features/finance client/lib/app/router.dart client/lib/features/home/presentation/tenant_shell.dart client/test/features/finance && git commit -m "feat(client): 添加财务登记与结清视图"`

### Task 9: 报表 domain、repository、controller

**Files:**
- Create: `client/lib/features/reports/domain/report.dart`
- Create: `client/lib/features/reports/data/report_repository.dart`
- Create: `client/lib/features/reports/application/report_controller.dart`
- Create: `client/test/features/reports/report_data_test.dart`
- Create: `client/test/features/reports/report_controller_test.dart`

- [ ] **Step 1: 写失败测试**

fromJson 严格解析 overview / inbound-stats / outbound-stats / business-users /
summary-settlements 各 data（金额 string、ppm 整数、快照无 version）；repository 契约：
`summary-settlements` POST body `{period, scope, business_user_id?, remark?}`。

- [ ] **Step 2: 实现 domain + repository + controller**

报表只读，无写状态机（除快照生成）；「看全组一种数据范围」——无 `report.view` 直接
403 由后端保证，客户端只在入口裁剪（不渲染报表入口）。

- [ ] **Step 3: GREEN 并提交 Task 9**

Commit: `git add client/lib/features/reports client/test/features/reports && git commit -m "feat(client): 添加报表数据层"`

### Task 10: 报表看板与统计页（中性壳占位）

**Files:**
- Create: `client/lib/features/reports/presentation/report_overview_page.dart`
- Create: `client/lib/features/reports/presentation/report_stats_page.dart`
- Create: `client/lib/features/reports/presentation/summary_settlements_page.dart`
- Modify: `client/lib/app/router.dart`
- Modify: `client/lib/features/home/presentation/tenant_shell.dart`
- Create: `client/test/features/reports/report_pages_test.dart`

- [ ] **Step 1: 写页面失败测试**

看板展示入库/出库金额、毛利、未结清单数（逐单比较口径）；入库/出库统计页分页；
业务员利润页；总结算快照列表与生成入口。入口按 `report.view` 裁剪，无权限不渲染。

- [ ] **Step 2: 实现中性壳页面**

金额与大写直接透传服务端，比率展示 `*_percent` 文本 + ppm 原值；快照生成用
`scope` 选择 + period 选择，生成后展示 `batch_no`。

- [ ] **Step 3: GREEN 并提交 Task 10**

Commit: `git add client/lib/features/reports client/lib/app/router.dart client/lib/features/home/presentation/tenant_shell.dart client/test/features/reports && git commit -m "feat(client): 添加报表看板与统计页"`

### Task 11: FakeBackend 扩展与纵向闭环

**Files:**
- Modify: `client/test/support/fake_backend.dart`
- Create: `client/test/integration/document_settlement_loop_test.dart`

- [ ] **Step 1: 扩展 FakeBackend 覆盖单据/结算/财务/报表端点

在既有 FakeBackend 状态机里补：document（列表/详情/创建/更新/提交/作废）、
settlement（列表/详情/创建/审批）、finance（登记/撤销/结清）、reporting（看板/统计/
快照生成），金额用字符串、单号按规则生成、状态机严格校验。

- [ ] **Step 2: 写纵向闭环测试**

owner 建入库单 → 提交 → 建出库单 → 提交 → 建结算引用两单 → 审批通过 → 登记付款/收款
→ 查结清视图 → 看板统计。断言跨模块状态流动（结算引用后单据不可重复引用、
财务登记后未付/未收金额变化）。

- [ ] **Step 3: GREEN 并提交 Task 11**

Commit: `git add client/test/support/fake_backend.dart client/test/integration && git commit -m "test(client): 覆盖单据结算财务纵向闭环"`

### Task 12: 全量门禁与推送

- [ ] **Step 1**: `dart format --output=none --set-exit-if-changed lib test integration_test`
- [ ] **Step 2**: `flutter analyze`
- [ ] **Step 3**: `flutter test -r expanded`
- [ ] **Step 4**: `git status --short; git diff --check`（无无关生成物/凭据）
- [ ] **Step 5**: `git push origin main`（普通 push，禁 force）

Expected: 全绿；如有环境阻塞（Windows symlink / Android Gradle 锁）诚实记录。

## 验收清单

- 金额/单价/数量全程字符串 + 定点运算，客户端无任何 double 参与金额计算。
- 人民币大写全部来自服务端 `*_upper`，客户端不实现 rmb。
- 单据单号 `RK/CK + YYYYMMDD`、结算 `JS + YYYYMM`、总结算 `ZJS + YYYYMM` 与后端一致。
- 单据填写页明细行金额只读（服务端算），提交/作废按 `draft→submitted→voided` 裁剪。
- 结算审批按 `settlement.approve` 裁剪，驳回必填备注。
- 财务登记 kind 由路由决定，结清视图派生字段直接展示服务端结果。
- 报表入口按 `report.view` 裁剪，无权限不渲染（不返回空报表）。
- 所有页面在 390 与 1280 宽度下无横向溢出。
