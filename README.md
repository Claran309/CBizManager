# CBizDocsManager

钢材批发公司用的开单系统。后端是 Go 单体服务（gin + GORM + MySQL + Redis），客户端用 Flutter，跑安卓、Windows 和浏览器。前后端都在这个仓库里。

## 现状：被甲方鸽了

需求和原型甲方早就给了，验收清单也列好了。我把整条业务链做到能跑通之后，他就没再回过消息。问了句还有没有下文，回我「等等吧」。

![甲方回复：等等吧](docs/images/甲方回复-等等吧.jpg)

项目就停在这了。做出来的部分能跑，但也就是随手 vibe 的一版基础 MVP，没上真机验收过，没打包，也没部署。

## 做出来的东西

- 组和账号：一个主账号带一堆业务员子账号，权限按人配，进组靠邀请码
- 开单：入库单和出库单，先存草稿改到满意再提交，金额和人民币大写都是后端算的
- 结算：挑几张单据申请结算，主账号审批，通过或打回
- 收付款：付款、收款、开票的记录，以及每张单据的结清情况
- 报表：看板、入出库月度统计、业务员业绩、总结算快照

## 技术栈

后端 Go 1.25，gin + GORM + MySQL + Redis。SQL 迁移直接嵌在二进制里，启动时自动跑。

客户端 Flutter（Dart 3.12），Riverpod 管状态，GoRouter 管路由，Dio 发请求，drift 存本地。

接口契约写在 `api/openapi/cbizdocsmanager-v1.yaml`，一共 52 条路径、65 个操作。

## 跑起来

后端（MySQL 和 Redis 走 Docker，别在 Windows 上重复装）：

```bash
cd backend && cp .env.example .env    # 填连接串和密钥
go run ./cmd/api
```

客户端：

```bash
cd client && flutter pub get
flutter run -d chrome                 # 也可以 -d windows 或者安卓真机
```

## 测试

```bash
cd backend
go test ./... -count=1                                         # 单元测试，不用 Docker
TEST_MYSQL_DSN='...' go test -tags integration ./... -count=1  # 真实 MySQL 集成测试

cd client
flutter analyze
flutter test                                                   # 551 项
```

## 没做的

离线只做了成员和字典两块，单据、结算、财务、报表还是得联网。真机上没完整点过一遍。没打 apk，没部署。应用内更新没写。

## 文档

需求、技术设计、验收标准在 `docs/output/`，甲方的原始 Word 和 Excel 在 `docs/甲方/`。后端和客户端各自的说明见 [backend/README.md](backend/README.md) 和 [client/README.md](client/README.md)。
