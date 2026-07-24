# Flutter 多角色可操作闭环设计

## 1. 背景

Flutter 客户端已经具备跨端认证、401 单飞刷新、Riverpod 认证状态、GoRouter 守卫、原生 Drift 缓存、Outbox 底座，以及成员和字典 Repository/Controller。当前界面只是路由测试壳，`/auth/me` 客户端模型也只保留 `must_change_password`，尚不能按角色装配真实功能区。

本设计依赖《平台治理与可重复查看邀请码设计》中新增的平台和邀请 API。两项工作按“后端契约与治理能力 -> Flutter 数据层 -> Flutter 功能壳 -> 纵向验证”的顺序执行。

## 2. 目标

- 同一个 Flutter 客户端承载平台管理员、组主账号和普通成员。
- 根据服务端 `/auth/me` 返回的真实身份自动分流。
- 从平台管理员创建组开始，走通主账号改密、邀请码、注册、授权和字典操作。
- 页面使用可长期保留的 Repository/Controller 边界，正式原型到达后只替换视觉与布局。
- Android、Windows 和 Web 使用同一业务状态模型，同时保留平台差异。

## 3. 非目标

- 不实现入库、出库、结算和报表页面。
- 不冻结正式品牌色、字体、复杂动效或业务表单布局。
- 不实现二维码、系统分享、Deep Link 或推送通知。
- 不为 Web 启用 Drift 业务离线数据库。
- 不允许 Widget 直接调用 Dio 或 Drift。

## 4. 认证会话模型

扩展 Flutter `AuthProfile` 和 `AuthSession`，完整保存服务端 `/auth/me`：

```text
user.id
user.username
user.display_name
user.account_type
group?.id
group?.name
member_type?
must_change_password
```

客户端不解析 JWT 推断角色。服务端 profile 是导航和缓存 scope 的唯一身份事实源。

账户类型：

- `platform_admin`
- `group_owner`
- `member`

成员类型：

- `owner`
- `member`
- 平台管理员为 null

## 5. 路由

```text
公开区域
├─ /login
└─ /register

强制改密
└─ /change-password

平台管理员
├─ /platform/groups
├─ /platform/groups/new
└─ /platform/groups/:groupId

租户用户
├─ /home
├─ /invitations
├─ /members
├─ /members/:membershipId/permissions
└─ /dictionaries
```

守卫优先级：

1. `restoring` 只进入 splash。
2. 未登录只允许 login/register。
3. `must_change_password=true` 只允许 change-password、me 和 logout 所需流程。
4. 平台管理员只能进入 `/platform/*`。
5. 租户用户不能进入 `/platform/*`。
6. owner 才能进入 invitations 和权限替换页。
7. 普通成员的功能入口根据服务端权限隐藏；后端仍做最终授权。

无权地址统一回到该角色首页，避免重定向循环。

## 6. 会话级依赖装配

### 6.1 应用级依赖

- `Dio`
- `ApiClient`
- `AuthRepository`
- `AccessTokenStore`
- 原生 `AppDatabase`；Web 不创建业务离线数据库

### 6.2 会话级依赖

- `PlatformRepository`
- `InvitationRepository`
- `MemberRepository`
- `DictionaryRepository`
- 对应 Riverpod Controller

会话级依赖从 `AuthSession` 读取 `userId/groupId/accountType/memberType`。账号或组发生变化时，旧 Provider scope 必须销毁并重新创建，不能只替换 Access Token 后继续使用旧 Repository。

平台管理员没有 `groupId`，禁止创建租户 Repository。租户用户缺少 `groupId` 视为服务端 profile 异常并终止进入业务区。

## 7. 数据层

### 7.1 Auth

扩展现有 AuthRepository：

- 完整解析 `/auth/me`。
- 增加修改密码方法。
- 登录、恢复和改密成功后刷新 profile。
- 邀请注册不自动创建登录会话；成功后返回用户名供登录页预填。

### 7.2 Platform

新增：

- `PlatformGroup`、`PlatformGroupDetail`、分页查询对象。
- `PlatformRepository` 和 Dio remote adapter。
- `PlatformGroupController`：列表、筛选、刷新、启停。
- `PlatformGroupDetailController`：详情、owner 交接。
- `CreateGroupController`：创建组和初始 owner。

平台数据首期只走远端，不进入 Drift 或 Outbox。

### 7.3 Invitations

新增：

- `InvitationSummary`、`InvitationSecret` 和状态枚举。
- `InvitationRepository`：创建、列表、查看 secret、撤销。
- `InvitationController`：列表与写状态。

邀请码管理写操作和 secret 不缓存、不进入 Outbox。secret 只存在 Controller 的临时内存字段，以下事件必须清除：

- 页面离开或 Controller dispose。
- 邀请码撤销、使用或变为过期。
- 账号退出或会话失效。
- 查看另一个邀请码。

### 7.4 Members and dictionaries

复用现有 Repository/Controller，并补充：

- 权限目录读取。
- 从会话 scope 自动构造 Repository。
- 页面所需筛选与刷新入口。
- 409 后刷新最新资源并保留可展示的 `ConflictFailure`。

## 8. 页面与交互

### 8.1 登录与注册

- 登录页包含用户名、密码、登录按钮和“邀请码注册”入口。
- 注册页包含邀请码、用户名、显示名、密码和确认密码。
- 注册成功后返回登录页并预填用户名，不自动登录。
- 表单只保留必要校验；服务端字段错误映射到对应输入框。

### 8.2 平台组管理

- 组列表：关键词、状态筛选、刷新、新建、进入详情。
- 新建组：组名、owner 用户名、显示名、临时密码。
- 组详情：状态、owner、成员数量、版本、启停和 owner 交接。
- owner 交接使用两种模式：选择现有 active 成员，或填写新账号资料。
- 成功后刷新详情；409 提示数据已变化并重新加载。

### 8.3 邀请码

- 列表显示状态、到期时间、创建/使用/撤销时间。
- 创建后立即展示 secret 和复制操作。
- 有效邀请码可以显式再次查看；页面初始不批量加载 secret。
- 撤销需要确认，成功后立即清除本地 secret。
- used、expired、revoked 行不显示查看操作。

### 8.4 成员和权限

- 成员页支持关键词、状态、刷新和状态变更。
- owner 可以进入权限页，用复选框整体提交权限集合。
- 普通成员即使拥有 `member.manage`，也不展示授权入口。
- 当前账号和 owner 的受保护操作在 UI 中禁用，后端继续强制校验。

### 8.5 字典

- 六种 kind 使用同一页面和 Controller。
- 支持新增、编辑、启停和筛选。
- 普通成员只读；owner 或 `dictionary.manage` 成员显示写入口。

## 9. 响应式功能壳

- 窄屏使用 AppBar、列表、表单页和 NavigationBar。
- 宽屏使用 NavigationRail、紧凑表格和详情/表单区域。
- 不使用横向溢出的桌面表格硬塞进手机；手机列表按资源展示关键字段。
- 工具动作使用图标、tooltip 和明确的无障碍语义。
- 加载、空数据、错误、提交中和成功反馈均有独立状态。
- 当前采用中性 Material 主题；正式原型到达后允许替换主题和布局，不改变 Controller API。

## 10. 错误处理

- `ValidationFailure` 显示字段错误。
- `ConflictFailure` 显示“数据已被其他操作修改”，刷新后让用户重新决定。
- `ForbiddenFailure` 清除当前无权页面并回到角色首页。
- `UnauthenticatedFailure` 统一清理会话并回登录页。
- `NetworkFailure` 对平台和管理写操作显示在线要求，不加入 Outbox。
- `ServerFailure` 显示通用错误和可复制 Request ID。
- 不在 SnackBar、日志或错误追踪中输出密码、Refresh Token 或邀请码 secret。

## 11. 并发与状态

- Controller 加载请求使用递增 generation，只允许最新请求提交状态。
- 写操作按 Controller 串行，避免重复点击造成版本倒退。
- owner 交接、组启停、权限替换和邀请码撤销提交 version。
- 页面离开后完成的旧 Future 不得更新已销毁 Controller。
- 会话变化优先销毁会话级 Controller，再创建新 scope。

## 12. 测试

### 12.1 Dart 单元测试

- 完整 `/auth/me` 解析和角色模型。
- 平台、邀请、成员、字典 DTO 与请求体契约。
- 会话切换不复用旧 `userId/groupId` Repository。
- secret 生命周期和 dispose 清理。
- Controller 乱序加载、串行写、409 和网络失败。

### 12.2 Router/Widget 测试

- 未登录、强制改密、平台管理员、owner、普通成员路由矩阵。
- 平台管理员创建组、启停和 owner 交接页面路径。
- owner 创建/再次查看/撤销邀请码。
- 子账号注册后用户名预填并登录。
- owner 授权后普通成员的导航能力变化。
- 手机和宽屏两个尺寸无布局溢出。

### 12.3 纵向验证

使用真实 Go API 和 Docker MySQL 验证：

```text
平台管理员登录与改密
  -> 创建组和初始 owner
  -> owner 登录与改密
  -> 创建并再次查看邀请码
  -> 子账号注册并登录
  -> owner 替换权限
  -> 子账号读取字典
  -> 平台管理员更换 owner
  -> 旧 owner 会话失效
```

## 13. 构建与环境

- `flutter analyze` 和 `flutter test` 必须通过。
- 构建 Android Debug APK 和 Web。
- Web 构建不得初始化 Drift 业务离线数据库。
- Windows 构建需要宿主机先启用开发者模式以支持插件符号链接；未满足时必须记录为环境阻塞，不能宣称构建成功。

## 14. 验收标准

- 单客户端可以根据 `/auth/me` 自动进入正确角色区域。
- 从空数据库开始可以完成完整多角色闭环。
- 平台管理员和租户用户无法互相访问对方路由或 API。
- 有效邀请码可以重复查看，终态邀请码无法显示 secret。
- 账号切换不泄漏前一个用户或组的内存状态和本地缓存。
- 正式 UI 到达后无需重写 Auth、Repository、Controller 和路由权限边界。
