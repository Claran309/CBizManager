# CBizDocsManager

**客户端 + 后端**全栈业务单据管理系统：Go 单体 API + Flutter 跨平台客户端（Android / Windows / Web），面向钢材批发的开单、结算与对账。

---

## ⚠️ 项目已搁置（被甲方鸽了）

需求、原型、验收表都给了，写到「能跑通全链路的基础 MVP」之后甲方就不再推进（原话：「等等吧」）。不是技术做不下去，是人没了。

![甲方回复：等等吧](docs/images/甲方回复-等等吧.jpg)

目前只是**草草 vibe 出来的基础 MVP**：链路通、测试绿，但没做过真机 UI 验收，没打包，没部署。

## 功能

- 分组与权限（主账号 / 业务员子账号）、邀请码入组、辅助字典
- 入库／出库单据：草稿 → 提交 → 作废，金额服务端定点计算，单号 `RK/CK + 日期 + 序号`
- 结算：勾选源单据申请 → 审批通过 / 驳回，单号 `JS + 年月 + 序号`
- 财务：付款 / 收款 / 开票登记与撤销、单据结清视图（已付未付 / 已收未收 / 开票状态）
- 报表：看板、入出库统计、业务员利润、总结算快照

## 技术栈

| | |
|---|---|
| 后端 `backend/` | Go 1.25 · gin · GORM · MySQL · Redis · viper/zap · 内嵌 SQL 迁移（启动自动执行） |
| 客户端 `client/` | Flutter（Dart 3.12）· Riverpod · GoRouter · Dio · drift |
| 契约 | `api/openapi/cbizdocsmanager-v1.yaml`（52 路径 / 65 操作） |

## 快速开始

```bash
# 后端（MySQL / Redis 走 Docker，别在宿主机重复装）
cd backend && cp .env.example .env    # 填连接串与密钥
go run ./cmd/api

# 客户端
cd client && flutter pub get
flutter run -d chrome                 # 或 -d windows / 安卓真机
```

## 测试

```bash
cd backend
go test ./... -count=1                                         # 单元
TEST_MYSQL_DSN='...' go test -tags integration ./... -count=1  # 真实 MySQL 集成

cd client
flutter analyze && flutter test                                # 551 项
```

## 还没做

离线能力只覆盖成员与字典（单据/结算/财务/报表仍在线）、真机 UI 验收、打包 APK 与部署、版本更新。

## 文档

[docs/output/](docs/output/) 需求 · 技术设计 · 测试验收 ｜ [docs/甲方/](docs/甲方/) 甲方原始资料 ｜ [backend/README.md](backend/README.md) ｜ [client/README.md](client/README.md)
