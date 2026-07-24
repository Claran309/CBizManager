# CBizDocsManager Client

Flutter 跨平台客户端，目标平台为 Android、Windows 和 Web。当前交付的是不依赖正式原型图的数据与运行底座：认证状态、路由守卫、网络错误映射、原生 Drift 缓存、Outbox，以及成员和辅助字典 Repository/Controller；正式页面仍等待原型图。

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

## 三平台构建

```powershell
flutter build apk --debug
flutter build windows --debug
flutter build web
```

输出分别位于 `build/app/outputs/flutter-apk/`、`build/windows/x64/runner/Debug/` 和 `build/web/`。Debug APK 只用于开发验证，正式发布还需要配置 Android 应用 ID、签名、版本号和升级策略。
