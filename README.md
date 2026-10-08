# CBizDocsManager

> **一套「客户端 + 后端」的全栈业务单据管理系统** —— Go 单体 API + Flutter 跨平台客户端，面向中小钢材／贸易批发的开单、结算与对账场景。

---

## ⚠️ 项目现状：甲方搁置（被鸽了）

**这个项目已经停工。** 需求给了、原型给了、验收清单也给了，代码写到「能跑通全链路的基础 MVP」之后，甲方就再没回过消息。

![甲方回复：等等吧](docs/images/甲方回复-等等吧.jpg)

> 「所以这个项目还有下文吗」
> 「等等吧」
>
> —— 2026-07-29。这张图就是项目停在这里的全部原因。

说清楚一点，免得误会：

- **不是技术做不下去**，是**甲方不推进了**。需求、原型、验收表都在 `docs/` 里躺着，代码也在，就是人没了。
- **目前只到「草草地 vibe 出来的基础 MVP」**：功能链路是通的（开单 → 提交 → 结算 → 审批 → 收付款 → 报表），但它**没有经过真机 UI 验收、没有打包发布、没有部署上线**。工程闸门（单元／集成／契约测试）反而是后来补上的，比一般 vibe 项目扎实一些。
- 仓库**保留完整**，随时可以续做。缺什么见下面的[「如果续做」](#如果续做)。

---

## 这是什么

一家钢材批发公司（预计 100 人左右使用）的**内部开单与对账系统**。业务员用手机或电脑填写入库单／出库单，后台统一汇总、结算、审批，并按业务员统计业绩。

核心诉求（来自 `docs/output/需求.md`）：

- **分组 + 权限体系**：一个组有一个主账号（`group_owner`）和若干子账号（业务员），主账号控制子账号对不同单据的查看／编辑权限。
- **移动端单据填写体验**：明细行多、字段密，要适配手机窄屏。
- **汇总后台**：结算审批、收付款登记、业务员利润统计。

## 功能范围（已实现）

| 模块 | 已实现 |
|---|---|
| **身份认证** | 平台管理员 bootstrap、登录、Access/Refresh 令牌轮换、登出、强制首次改密；Web 端用 `HttpOnly` Cookie + 双提交 CSRF |
| **组织治理** | 组创建／启停／主账号交接（交接后旧主账号降级停用）、邀请码签发／查看／撤销（明文只在签发与查看两次响应出现，落库为 AES-256-GCM 密文） |
| **成员与权限** | 成员列表／启停、固定权限目录、按成员整组替换权限；主账号隐式全权限，子账号默认只看本人 |
| **辅助字典** | 六类字典的 CRUD 与启停（往来单位、品名、单位等） |
| **单据** | 入库单／出库单：草稿 → 提交 → 作废三态；多往来单位 + 多明细行；**金额一律服务端按「单价 × 数量」定点计算，人民币大写由服务端生成**；单号 `RK/CK + YYYYMMDD + 序号` |
| **结算** | 申请（勾选源单据）→ 审批通过／驳回；**同一源单据不允许被两张有效结算单引用**；驳回必填备注；单号 `JS + YYYYMM + 序号` |
| **财务** | 付款／收款／开票登记与撤销；单据维度的**结清视图**（已付／未付、已收／未收、已开票／未开票、开票状态）由服务端推导；银行卡只存后 4 位 |
| **报表** | 看板（月份口径）、入库／出库统计、业务员利润、总结算快照（生成后冻结，可列表与查看） |
| **工程基建** | 幂等（`Idempotency-Key` + 载荷指纹）、乐观锁（`version`）、审计日志、数据范围收敛、稳定错误码体系、OpenAPI 契约 |

## 技术栈

**后端**（`backend/`）

| 项 | 选型 |
|---|---|
| 语言 | Go 1.25.3（**单体架构**） |
| Web | gin 1.12.0 |
| ORM | GORM 1.31.1 + MySQL 驱动 1.6.0 |
| 存储 | MySQL 8（业务数据）、Redis 9（缓存／令牌） |
| 配置 / 日志 / 认证 | viper 1.21.0 / zap 1.28.0 / golang-jwt v5.3.1 |
| 迁移 | 内嵌 SQL 迁移（`backend/migrations/`，`000001`~`000007`），**启动时自动执行** |

**客户端**（`client/`）

| 项 | 选型 |
|---|---|
| 框架 | Flutter（Dart SDK `^3.12.2`），目标平台 **Android / Windows / Web** |
| 状态管理 | Riverpod 3.3.2 |
| 路由 | GoRouter 17.3.0（含登录态、改密态、权限三级守卫） |
| 网络 | Dio 5.10.0（统一信封解析、401 单飞刷新、错误映射） |
| 本地存储 | drift 2.34.2（离线库，按 `userId/groupId` 隔离）、flutter_secure_storage 10.3.1 |
| 架构 | 按 `features/<模块>/{domain,data,application,presentation}` 纵向切分 |

**契约与部署**

- OpenAPI：`api/openapi/cbizdocsmanager-v1.yaml`（**52 条路径 / 65 个操作 / 42 个错误码**）
- 部署：`deploy/docker-compose.yml`

## 仓库结构

```
CBizDocsManager/
├── backend/                  Go 单体 API
│   ├── cmd/api/              进程入口（装配 + 启动时迁移）
│   ├── internal/             11 个业务模块 + infrastructure
│   │   ├── identity/         认证与令牌
│   │   ├── organization/     组与邀请码
│   │   ├── member/           成员与权限
│   │   ├── dictionary/       辅助字典
│   │   ├── document/         入库／出库单据
│   │   ├── settlement/       结算单
│   │   ├── finance/          付款／收款／开票
│   │   ├── reporting/        报表与快照
│   │   ├── platform/         平台管理员治理
│   │   └── infrastructure/   数据库、缓存、HTTP、加解密
│   ├── migrations/           内嵌 SQL 迁移
│   ├── pkg/                  可复用基础包（定点金额、大写、日期、错误码…）
│   └── tests/integration/    7 个端到端流程测试
├── client/                   Flutter 跨平台客户端
│   ├── lib/
│   │   ├── app/              应用壳、路由与守卫、会话作用域装配
│   │   ├── core/             网络、认证、定点金额、日期、错误、数据库
│   │   └── features/         按模块纵向切分
│   ├── test/                 单元 + Widget + 集成测试（含真实后端报文契约夹具）
│   └── integration_test/
├── api/openapi/              OpenAPI 契约
├── deploy/                   Docker Compose
└── docs/                     需求、技术设计、原型、甲方原始资料
```

## 快速开始

### 后端

MySQL 与 Redis 走 Docker，**不要**在 Windows 宿主机重复安装。

```bash
# 1. 起中间件（按本机实际容器名）
docker start MySQL Redis

# 2. 准备配置（真实凭据不要提交）
cd backend
cp .env.example .env      # 然后填 MySQL DSN、JWT_SECRET、邀请码密钥等

# 3. 启动（会自动执行建库迁移并初始化平台管理员）
go run ./cmd/api
```

健康检查：`GET /health/live`、`GET /health/ready`。
详见 [`backend/README.md`](backend/README.md)。

### 客户端

```bash
cd client
flutter pub get
flutter devices            # 确认目标设备
flutter run -d chrome      # 或 -d windows / 安卓真机
```

各平台的后端地址差异、代码生成与构建命令见 [`client/README.md`](client/README.md)。

## 测试与质量闸门

**后端**

```bash
cd backend
go build ./...                                   # 编译
go vet ./...                                     # 静态检查
go test ./... -count=1                           # 单元测试（不依赖 Docker）

# 真实 MySQL 集成测试（会自建 cbizdocsmanager_test_* 库并在结束后删除）
TEST_MYSQL_DSN='root:<密码>@tcp(127.0.0.1:3306)/cbizdocsmanager?charset=utf8mb4&parseTime=true&loc=UTC' \
  go test -tags integration ./... -count=1
```

**客户端**

```bash
cd client
dart format --output=none --set-exit-if-changed lib test
flutter analyze
flutter test
```

当前状态：后端单测与真实 MySQL 集成测试全绿（含 7 个端到端流程测试）；客户端 `flutter analyze` 无告警、`flutter test` **551 项全绿**。

其中有两点值得单独说，因为它们是这个项目里**质量最实**的部分：

1. **真实报文契约测试**：用真后端抓下 12 份真实响应固化为夹具（`client/test/fixtures/real_backend/`），直接灌进客户端**严格**的 `fromJson` 逐字段断言。只对着测试替身跑，两边一起错是测不出来的。
2. **两层纵向闭环**：一是驱动真实 Repository 打假后端状态机（契约层），二是走真实 UI 壳（登录 → 建单 → 提交 → 申请结算 → 审批 → 登记付款 → 看结清金额联动）。

## 如果续做

停工时的**真实缺口**（不是"以后可以优化"，是当时就该做但没做的）：

| 缺口 | 说明 |
|---|---|
| **客户端离线能力** | 需求明确要求"本地缓存 + 离线能力"，但 drift 缓存目前**只覆盖成员与字典**；单据／结算／财务／报表仍是在线读写。 |
| **真机 UI 验收** | 契约层已在真后端验证过，但 UI 还没在真机上连着真后端完整点过一遍。 |
| **打包与部署** | 未打签名 APK，未做后端部署上线。 |
| **版本更新** | 需求提到的应用内版本更新未实现。 |
| **次要功能空白** | 单据表单未接字典下拉（往来单位／品名仍是手输）；单据历史页筛选只做了状态，月份／关键字／业务员后端支持但没上 UI；报表"生成总结算"未提供业务员选择（`scope=business_user` 后端已支持）。 |

## 文档索引

- [`docs/output/需求.md`](docs/output/需求.md)：一期需求基线、角色权限、业务流程与验收范围。
- [`docs/output/技术设计.md`](docs/output/技术设计.md)：系统边界与技术设计。
- [`docs/output/测试验收.md`](docs/output/测试验收.md)：测试策略与甲方验收场景。
- [`docs/output/项目现状分析.md`](docs/output/项目现状分析.md)：接手时的仓库状态分析（2026-09-22）。
- [`docs/甲方/`](docs/甲方/)：甲方提供的 Word／Excel／图片原始资料。
- [`api/openapi/cbizdocsmanager-v1.yaml`](api/openapi/cbizdocsmanager-v1.yaml)：OpenAPI 契约。

## License

见 [LICENSE](LICENSE)。
