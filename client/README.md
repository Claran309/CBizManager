# CBizDocsManager Client

Flutter 客户端，支持安卓、Windows 和浏览器，代码按 `features/<模块>/{domain,data,application,presentation}` 切分。

目前有登录和路由守卫、网络层和错误映射、Drift 本地库、Outbox，以及平台治理、邀请码、成员权限、辅助字典、单据、结算审批、财务登记和结清视图、报表这些模块的页面。

甲方已经搁置了这个项目，详见根目录 [README](../README.md)。离线目前只覆盖成员和字典，也没上真机验收过、没打包。

## 环境准备

确认 Flutter SDK、Android toolchain、Chrome 和 Visual Studio Windows 桌面组件：

```powershell
flutter doctor -v
flutter pub get
flutter devices
```

Windows 客户端使用的插件需要创建符号链接。若 `flutter build windows` 提示 `Building with plugins requires symlink support`，先在 Windows“设置 -> 系统 -> 开发者选项”中启用开发者模式，再重新打开终端执行构建。

Android 模拟器中的 `127.0.0.1` 指向模拟器自身，所以默认 API 地址是 `http://10.0.2.2:8080`。Windows 和本机 Web 默认使用 `http://127.0.0.1:8080`。真机调试需要改成电脑在局域网中的 IP，并确保防火墙允许访问。

可通过编译期参数覆盖地址：

```powershell
flutter run -d windows --dart-define=API_BASE_URL=http://127.0.0.1:8080
flutter run -d chrome --dart-define=API_BASE_URL=http://127.0.0.1:8080
flutter run -d <android-device-id> --dart-define=API_BASE_URL=http://10.0.2.2:8080
```

## 认证与本地数据

Android/Windows 把 Refresh Token 存入系统安全存储，Access Token 只保存在内存。Web 不持久化 Refresh Token，而是使用后端 `HttpOnly` Cookie，并自动携带 CSRF Header。

Drift 离线数据库首期只在 Android/Windows 启用。缓存、草稿和 Outbox 的 key 都包含 `userId/groupId`，账号或组切换时不能复用旧 Repository。Web 明确禁用业务离线数据库，只走远端 API。

成员和字典查询采用在线优先：成员完整列表、字典无筛选的单 kind 查询成功后更新当前 scope 的完整缓存，网络失败时可以从已有完整快照读取并筛选；409 等业务错误继续上抛。成员状态、授权和字典管理写操作首期只允许在线，不进入 Outbox。

正式 UI 接入时从 `MemberController`、`DictionaryController` 和 `AuthController` 读取状态并调用动作，不要让 Widget 直接调用 Dio。

## 代码生成与验证

修改 Drift 表或生成式 Riverpod 代码后执行：

```powershell
dart run build_runner build
```

日常验证：

```powershell
dart format --output=none --set-exit-if-changed lib test
flutter analyze
flutter test
```

## 真实后端纵向验证

`integration_test/real_backend_role_flow_test.dart` 会连一个**真实 Go 后端**，
把「平台管理员登录/改密 → 建组 → owner 登录/改密 → 创建并再次查看邀请码 →
member 注册/登录 → owner 替换权限 → member 读字典 → 换 owner → 旧 owner 失效」
整条流程对真服务端跑一遍，验证客户端数据层对真实后端契约（路径、请求体、
错误码映射、响应解析）的正确性。

### 前置：启动后端与数据库

先用 Docker 拉起 MySQL（首次）：

```powershell
docker context show
docker ps -a --filter "name=^/MySQL$"
docker run --name MySQL -e MYSQL_ROOT_PASSWORD=<本地密码> -e MYSQL_DATABASE=cbizdocsmanager -p 3306:3306 -d mysql:8
```

再以本地环境变量启动 API（变量名见 `backend/pkg/config/config.go` 的
`bindEnvironment`；`INVITATION_ENCRYPTION_KEY` 必须是 Base64 编码的 32 字节密钥）：

```powershell
$env:MYSQL_DSN = "<root:<密码>@tcp(127.0.0.1:3306)/cbizdocsmanager?parseTime=true&charset=utf8mb4>"
$env:JWT_SECRET = "<至少 32 字节的密钥>"
$env:INVITATION_ENCRYPTION_KEY = "<Base64 32 字节>"
$env:BOOTSTRAP_ADMIN_USERNAME = "<初始管理员名>"
$env:BOOTSTRAP_ADMIN_PASSWORD = "<初始管理员密码>"
cd backend; go run ./cmd/api
```

就绪探测：`Invoke-RestMethod http://127.0.0.1:8080/health/ready` 应返回
`status=ok`、`mysql=up`（Redis 降级 `disabled` 属正常，不阻塞核心 CRUD）。

### 运行纵向验证

```powershell
flutter test integration_test/real_backend_role_flow_test.dart --dart-define=CBIZ_API_BASE_URL=http://127.0.0.1:8080
```

缺 `CBIZ_API_BASE_URL` 时测试整体 skip，不会误连生产。bootstrap 管理员凭据可用
`CBIZ_BOOTSTRAP_ADMIN_USERNAME` / `CBIZ_BOOTSTRAP_ADMIN_PASSWORD` 覆盖（缺省回退
到后端 development 默认值）；组主账号与业务员的账号密码由测试过程自行生成，
测试数据只落在本地测试库。跑完按原状态恢复 Docker 容器。

> 注意：以上命令里的 `<...>` 是占位符，真实值一律通过本地环境变量 / 未跟踪
> 文件注入，**不写进仓库**。

## 三平台构建

```powershell
flutter build apk --debug
flutter build windows --debug
flutter build web
```

输出分别位于 `build/app/outputs/flutter-apk/`、`build/windows/x64/runner/Debug/` 和 `build/web/`。Debug APK 只用于开发验证，正式发布还需要配置 Android 应用 ID、签名、版本号和升级策略。
