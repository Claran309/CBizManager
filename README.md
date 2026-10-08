# CBizDocsManager

原钢材批发公司用开单系统，客户端全栈项目

Golang后端 + Flutter & Dart客户端，可跑Andriod/Windows/Web

需求和原型收到后，vibe 的一版MVP跑通整条业务链后从此再无下文，目前被搁置，暂废弃

![甲方回复：等等吧](docs/images/甲方回复-等等吧.jpg)

## 技术栈

后端 Go 1.25，gin + GORM + MySQL + Redis

客户端 Flutter（Dart 3.12），Riverpod 状态 + GoRouter 路由 + Dio 请求 + drift 本地

接口契约 `api/openapi/cbizdocsmanager-v1.yaml`

## 跑起来

后端：

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

## 文档

后端和客户端各自的说明见 [backend/README.md](backend/README.md) 和 [client/README.md](client/README.md)。
