# ProjectF 根目录 `.gitignore` 设计

## 目标

在一个 Git 仓库中同时支持 Go 后端和 Flutter 客户端，避免把本地缓存、构建产物、密钥及个人开发环境提交到仓库，同时保留能够复现构建和协作所需的文件。

## 采用方案

使用平衡型根目录 `.gitignore`，统一覆盖以下内容：

- 操作系统临时文件和常见编辑器私有文件。
- Go 编译产物、测试产物、性能分析文件和本地运行文件。
- Flutter、Dart、Android、Windows 和 Web 的构建缓存与生成目录。
- `.env`、证书、签名文件及其他本地密钥。
- 日志、临时目录、覆盖率文件和 Docker 本地持久化数据。

## 必须保留的文件

以下内容即使属于依赖或部署相关文件，也必须纳入版本控制：

- Go 的 `go.mod` 和 `go.sum`。
- Flutter 应用的 `pubspec.yaml` 和 `pubspec.lock`。
- OpenAPI/Swagger 契约、数据库迁移和初始化脚本。
- Dockerfile、Compose 文件及 `.env.example`。
- Flutter 的 `android/`、`windows/`、`web/` 平台工程源文件。
- `docs/` 下的需求、设计、验收和甲方原始资料。

## VS Code 策略

默认忽略 `.vscode/` 中的个人配置，但允许提交以下共享配置：

- `.vscode/extensions.json`：推荐团队安装的扩展。
- `.vscode/settings.json`：项目统一的格式化与分析设置。

个人调试配置和本地任务参数默认不提交，避免其中出现绝对路径、端口或密钥。

## 验证方式

生成后使用 `git check-ignore -v` 检查代表性文件：构建产物和密钥应被忽略；`go.sum`、`pubspec.lock`、OpenAPI、迁移文件、Compose 文件和项目文档不得被忽略。
