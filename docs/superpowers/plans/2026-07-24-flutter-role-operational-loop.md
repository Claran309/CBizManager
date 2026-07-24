# CBizDocsManager Flutter Multi-Role Operational Loop Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在同一个 Flutter 客户端中，根据 `/auth/me` 的服务端身份自动装配平台管理员、组主账号和普通成员功能，并走通创建组、改密、邀请码注册、授权、字典和 owner 交接闭环。

**Architecture:** 应用级 Provider 只持有 Dio、认证仓库、AccessTokenStore 和原生数据库；登录后以完整 `AuthSession` 生成带 user/group/role key 的会话级 ProviderContainer，账号或组变化时整体销毁。功能按 domain -> data -> application -> presentation 分层，Widget 不直接调用 Dio/Drift；平台和管理写操作必须在线执行，不进入 Outbox。

**Tech Stack:** Flutter 3.44.6、Dart 3.12.2、Riverpod 3、GoRouter 17、Dio 5、Drift、flutter_secure_storage、Material 3、flutter_test、mocktail。

---

## 前置条件与执行边界

- 必须先完成 `docs/superpowers/plans/2026-07-24-platform-governance-invitations.md` 的后端契约和 API；Flutter Task 4 之后依赖这些 endpoint。
- 本计划实现中性、响应式、可用的功能壳，不冻结品牌视觉；正式原型到达后替换 Theme 和页面布局，不改 Repository/Controller API。
- 直接在 `main` 执行，不创建分支或 worktree；每个 Task 独立测试和提交，全部完成后普通 push。
- Web 不创建 Drift 业务数据库；Android/Windows 保留现有按 `userId + groupId` 隔离的缓存。
- 平台治理、成员/权限、字典写操作和邀请码操作都必须在线执行；不得写入 Outbox。邀请码 secret 不写 Drift、Secure Storage、日志或错误追踪。
- Windows build 只有在宿主机启用开发者模式、可创建插件 symlink 时才可宣称成功；否则记录环境阻塞，但 `flutter analyze`、`flutter test`、Android 和 Web 构建仍须执行。

## 文件边界

- `client/lib/core/auth/`：完整身份 profile、注册、改密、登录恢复和会话失效。
- `client/lib/app/session_scope.dart`：根据 authenticated session 创建并销毁会话级 Repository/Controller overrides。
- `client/lib/app/router.dart`：角色路由矩阵和无循环 redirect。
- `client/lib/core/presentation/`：响应式壳、异步状态和错误反馈等无业务组件。
- `client/lib/features/platform/`：平台组 domain、remote repository、controllers 和页面。
- `client/lib/features/invitations/`：邀请码 domain、remote repository、secret 生命周期 controller 和页面。
- `client/lib/features/members/`：补充查询、权限目录、权限页和成员管理页。
- `client/lib/features/dictionaries/`：补充筛选和可写性页面。
- `client/lib/features/auth/`：登录、注册和强制改密页面。
- `client/test/`：DTO、会话 scope、controller、router、widget 和纵向 fake API 测试。

### Task 1: 完整认证身份模型和 `/auth/me` 解析

**Files:**
- Modify: `client/lib/core/auth/auth_models.dart`
- Modify: `client/lib/core/auth/auth_repository.dart`
- Modify: `client/test/core/auth/auth_repository_test.dart`
- Create: `client/test/core/auth/auth_models_test.dart`

- [ ] **Step 1: 写完整 profile 解析失败测试**

覆盖 platform admin 的 null group/memberType、owner、member、未知 account type、租户缺 group、account/member type 不一致。

```dart
test('parses a group owner profile without reading JWT claims', () {
  final profile = AuthProfile.fromJson(<String, Object?>{
    'user': <String, Object?>{
      'id': 11,
      'username': 'owner',
      'display_name': 'Owner',
      'account_type': 'group_owner',
    },
    'group': <String, Object?>{'id': 7, 'name': 'Finance'},
    'member_type': 'owner',
    'must_change_password': false,
    'permission_codes': <Object?>[],
  });
  expect(profile.accountType, AccountType.groupOwner);
  expect(profile.group?.id, 7);
  expect(profile.memberType, MemberType.owner);
});
```

Run: `cd client; flutter test test/core/auth/auth_models_test.dart test/core/auth/auth_repository_test.dart`

Expected: FAIL，因为类型和 parser 尚不存在。

- [ ] **Step 2: 定义强类型身份对象**

```dart
enum AccountType {
  platformAdmin('platform_admin'), groupOwner('group_owner'), member('member');
  const AccountType(this.wireValue);
  final String wireValue;
  static AccountType fromWireValue(String value) => values.firstWhere(
    (item) => item.wireValue == value,
    orElse: () => throw FormatException('Unknown account type: $value'),
  );
}

enum MemberType {
  owner('owner'), member('member');
  const MemberType(this.wireValue);
  final String wireValue;
}

final class AuthUser {
  const AuthUser({required this.id, required this.username, required this.displayName, required this.accountType});
  final int id; final String username; final String displayName; final AccountType accountType;
  factory AuthUser.fromJson(Map<String, Object?> json);
}
final class AuthGroup {
  const AuthGroup({required this.id, required this.name});
  final int id; final String name;
  factory AuthGroup.fromJson(Map<String, Object?> json);
}
final class AuthProfile {
  const AuthProfile({required this.user, required this.group, required this.memberType, required this.mustChangePassword, required this.permissionCodes});
  final AuthUser user; final AuthGroup? group; final MemberType? memberType; final bool mustChangePassword; final Set<String> permissionCodes;
  AccountType get accountType => user.accountType;
  bool hasPermission(String code) => accountType == AccountType.groupOwner || permissionCodes.contains(code);
  factory AuthProfile.fromJson(Map<String, Object?> json);
}
```

`fromJson` 必须验证：platform admin 的 group/memberType 均为 null；groupOwner 必须有 group 且 memberType=owner；member 必须有 group 且 memberType=member；`permission_codes` 必须是去重字符串数组，否则抛 `FormatException`。客户端不从本地猜测普通成员权限。

- [ ] **Step 3: 让 AuthSession 持有 profile**

```dart
final class AuthSession {
  const AuthSession({required this.accessToken, required this.profile, this.accessExpiresAt});
  final String accessToken;
  final AuthProfile profile;
  final DateTime? accessExpiresAt;
  bool get mustChangePassword => profile.mustChangePassword;
  String get scopeKey {
    final permissions = profile.permissionCodes.toList()..sort();
    return '${profile.user.id}:${profile.group?.id ?? 0}:${profile.accountType.wireValue}:${profile.memberType?.wireValue ?? '-'}:${profile.mustChangePassword}:${permissions.join(',')}';
  }
}
```

`DioAuthRemoteDataSource.me` 只把 Envelope data 传给 `AuthProfile.fromJson`，禁止解析 JWT。

- [ ] **Step 4: 修改 `_accept` 并验证登录/恢复**

`DefaultAuthRepository._accept` 在安全保存 native refresh token 后调用 `remote.me`，再设置 memory access token，返回携带完整 profile 的 session。更新现有 fake 和期望值。

- [ ] **Step 5: GREEN 并提交 Task 1**

Run: `cd client; flutter test test/core/auth -r expanded`

Expected: PASS。

Commit: `git add client/lib/core/auth client/test/core/auth && git commit -m "feat: 完整解析客户端身份信息"`

### Task 2: 注册、修改密码和认证 Controller 状态

**Files:**
- Modify: `client/lib/core/auth/auth_repository.dart`
- Modify: `client/lib/core/auth/auth_controller.dart`
- Modify: `client/lib/core/auth/auth_models.dart`
- Modify: `client/test/core/auth/auth_repository_test.dart`
- Modify: `client/test/core/auth/auth_controller_test.dart`

- [ ] **Step 1: 写注册与改密失败测试**

测试注册调用 `/api/v1/auth/register` 且不创建 session；返回 username 供登录页预填。改密调用 `/api/v1/auth/password` 后重新请求 `/auth/me` 并更新 session profile；失败时保留旧 authenticated session。

Run: `cd client; flutter test test/core/auth/auth_repository_test.dart test/core/auth/auth_controller_test.dart`

Expected: FAIL。

- [ ] **Step 2: 定义请求/结果和 Repository 方法**

```dart
final class RegistrationDraft {
  const RegistrationDraft({required this.invitationCode, required this.username, required this.displayName, required this.password});
  final String invitationCode; final String username; final String displayName; final String password;
}
final class RegistrationResult { const RegistrationResult({required this.username, required this.groupName}); final String username; final String groupName; }

abstract interface class AuthRemoteDataSource {
  Future<TokenResponse> loginNative(String username, String password);
  Future<TokenResponse> loginWeb(String username, String password);
  Future<TokenResponse> refreshNative(String refreshToken);
  Future<TokenResponse> refreshWeb();
  Future<AuthProfile> me(String accessToken);
  Future<void> logout({required bool web, String? accessToken});
  Future<RegistrationResult> register(RegistrationDraft draft);
  Future<void> changePassword(String currentPassword, String newPassword);
}

abstract interface class AuthRepository {
  Future<AuthSession> login(String username, String password);
  Future<AuthSession> restore();
  Future<RegistrationResult> register(RegistrationDraft draft);
  Future<AuthSession> changePassword(String currentPassword, String newPassword);
  Future<void> logout();
}
```

- [ ] **Step 3: 实现 Dio 契约**

注册 POST body 固定为 `invitation_code,username,display_name,password`。改密 PUT body 固定为 `current_password,new_password`，使用 ApiClient 自动 Bearer；成功后从 `AccessTokenStore` 读取 token 并调用 `me(token)`，不得重新登录或保存密码。

- [ ] **Step 4: 扩展 AuthState 和 Controller**

```dart
final class AuthState {
  const AuthState(this.phase, {this.session, this.isSubmitting = false, this.failure, this.loginPrefill});
  final AuthPhase phase; final AuthSession? session; final bool isSubmitting;
  final AppFailure? failure; final String? loginPrefill;
}

Future<RegistrationResult> register(RegistrationDraft draft)
Future<void> changePassword(String currentPassword, String newPassword)
void clearFailure()
```

register 成功保持 unauthenticated 并设置 `loginPrefill=result.username`；changePassword 成功替换完整 session；logout/invalidator 清除 failure 和 prefill。

- [ ] **Step 5: GREEN 并提交 Task 2**

Run: `cd client; flutter test test/core/auth -r expanded`

Expected: PASS。

Commit: `git add client/lib/core/auth client/test/core/auth && git commit -m "feat: 添加注册与强制改密流程"`

### Task 3: 会话级依赖 Scope 和销毁重建

**Files:**
- Create: `client/lib/app/session_scope.dart`
- Modify: `client/lib/app/bootstrap.dart`
- Modify: `client/lib/app/app.dart`
- Modify: `client/lib/features/members/application/member_controller.dart`
- Modify: `client/lib/features/dictionaries/application/dictionary_controller.dart`
- Create: `client/test/app/session_scope_test.dart`

- [ ] **Step 1: 写 scope 隔离失败测试**

测试 owner(group 7) -> member(group 8) 时，Member/Dictionary repository 实例、Controller state 和缓存 key 全部变化；logout 销毁旧 scope；platform admin 不创建 tenant repository；tenant 缺 group 抛 profile 错误。

Run: `cd client; flutter test test/app/session_scope_test.dart`

Expected: FAIL。

- [ ] **Step 2: 定义应用级依赖**

```dart
final dioProvider = Provider<Dio>((ref) => throw StateError('Dio not configured'));
final appDatabaseProvider = Provider<AppDatabase?>((ref) => throw StateError('Database not configured'));
final nativeCacheEnabledProvider = Provider<bool>((ref) => !kIsWeb);
final activeSessionProvider = Provider<AuthSession>((ref) => throw StateError('No authenticated session'));
```

`bootstrap.dart` 对 Web 注入 `null` database；Android/Windows 创建一个应用级 `AppDatabase` 并在 ProviderScope dispose 时关闭。数据库不随用户切换重建，数据访问仍以 user/group scope 过滤。

- [ ] **Step 3: 构建 `AuthenticatedSessionScope`**

```dart
final class AuthenticatedSessionScope extends StatefulWidget {
  const AuthenticatedSessionScope({required this.session, required this.child, super.key});
  final AuthSession session; final Widget child;
}

// State 使用 session.scopeKey 作为 ProviderScope key：
ProviderScope(
  key: ValueKey<String>(widget.session.scopeKey),
  overrides: buildSessionOverrides(widget.session),
  child: widget.child,
)
```

`buildSessionOverrides` 对 platform admin 只 override `activeSessionProvider`；Task 6 再加入 Platform repository。对租户用户用 profile userId/groupId 构造 Member/Dictionary repository；Task 9 仅为 owner 加入 Invitation repository。任何 Repository 不得捕获可变的全局 current group。

- [ ] **Step 4: 为会话结束增加 dispose 清理**

Member/Dictionary Controller 的 `build` 使用 `ref.onDispose(() { _loadGeneration++; })`，旧 Future 完成后因 generation 不匹配不得写 state。Session scope key 改变时 Riverpod 自动 dispose 旧 controllers，包括后续 Invitation secret。

- [ ] **Step 5: 在 App 中按认证状态包裹 Router**

`CBizDocsApp` 继续持有顶层 router；authenticated 时将页面 builder 放入 `AuthenticatedSessionScope`。不得在 `MaterialApp.router` 外创建第二个 GoRouter。

- [ ] **Step 6: GREEN 并提交 Task 3**

Run: `cd client; flutter test test/app/session_scope_test.dart test/core/auth -r expanded`

Expected: PASS。

Commit: `git add client/lib/app client/lib/features/members/application client/lib/features/dictionaries/application client/test/app/session_scope_test.dart && git commit -m "feat: 隔离认证会话级依赖"`

### Task 4: 多角色 GoRouter 守卫矩阵

**Files:**
- Modify: `client/lib/app/router.dart`
- Modify: `client/test/app/router_test.dart`

- [ ] **Step 1: 写完整 redirect 表驱动失败测试**

覆盖 restoring、unauthenticated 的 login/register、must-change-password、platform admin、owner 和 member；直接输入无权 URL 要回角色首页且不得形成 redirect loop。

```dart
final cases = <({AuthState auth, String location, String? redirect})>[
  (auth: restoring, location: '/login', redirect: '/splash'),
  (auth: signedOut, location: '/register', redirect: null),
  (auth: forcedOwner, location: '/members', redirect: '/change-password'),
  (auth: admin, location: '/home', redirect: '/platform/groups'),
  (auth: owner, location: '/platform/groups', redirect: '/home'),
  (auth: member, location: '/invitations', redirect: '/home'),
];
```

Run: `cd client; flutter test test/app/router_test.dart`

Expected: FAIL。

- [ ] **Step 2: 固定路由分类函数**

```dart
bool isPublicLocation(String path) => path == '/login' || path == '/register';
bool isPlatformLocation(String path) => path == '/platform/groups' || path.startsWith('/platform/groups/');
bool isOwnerOnlyLocation(String path) => path == '/invitations' || path.endsWith('/permissions');
bool isMemberManagementLocation(String path) => path == '/members';
String roleHome(AuthProfile profile) => profile.accountType == AccountType.platformAdmin ? '/platform/groups' : '/home';
```

redirect 优先级严格按规格：restoring -> unauthenticated -> mustChange -> platform/tenant boundary -> owner-only -> `member.manage` 普通成员入口 -> public/auth transitional pages。owner 隐式允许 `/members`；普通成员只有 `profile.hasPermission('member.manage')` 才可进入。

- [ ] **Step 3: 注册全部稳定路由**

```text
/splash, /login, /register, /change-password
/platform/groups, /platform/groups/new, /platform/groups/:groupId
/home, /invitations, /members, /members/:membershipId/permissions, /dictionaries
```

本 Task 仍可使用具名占位 Widget，但必须是可替换的 route target 类，例如 `PlatformGroupsPage` 的临时构造不允许继续使用单一 `_RouteShell`；后续 Task 逐页创建真实类。

- [ ] **Step 4: GREEN 并提交 Task 4**

Run: `cd client; flutter test test/app/router_test.dart`

Expected: PASS。

Commit: `git add client/lib/app/router.dart client/test/app/router_test.dart && git commit -m "feat: 添加多角色路由守卫"`

### Task 5: 通用响应式功能壳和错误反馈

**Files:**
- Create: `client/lib/core/presentation/responsive_scaffold.dart`
- Create: `client/lib/core/presentation/async_state_view.dart`
- Create: `client/lib/core/presentation/failure_presenter.dart`
- Create: `client/test/core/presentation/responsive_scaffold_test.dart`
- Create: `client/test/core/presentation/failure_presenter_test.dart`

- [ ] **Step 1: 写窄屏/宽屏和错误映射失败测试**

在 390x844 下断言使用 AppBar + NavigationBar 且无横向 overflow；在 1280x800 下断言 NavigationRail。错误映射断言 Validation 字段错误、Conflict 刷新提示、Network 在线要求、Server requestId 可复制。

Run: `cd client; flutter test test/core/presentation -r expanded`

Expected: FAIL。

- [ ] **Step 2: 实现响应式壳 API**

```dart
final class AppDestination {
  const AppDestination({required this.label, required this.icon, required this.route});
  final String label; final IconData icon; final String route;
}

final class ResponsiveScaffold extends StatelessWidget {
  const ResponsiveScaffold({required this.title, required this.destinations, required this.currentRoute, required this.body, this.actions = const <Widget>[], super.key});
  // < 720 logical pixels: Scaffold + AppBar + NavigationBar
  // >= 720: Row(NavigationRail, VerticalDivider, Expanded(body))
}
```

所有 icon button 必须提供 tooltip；导航 destination 使用明确 label 和 semantics。

- [ ] **Step 3: 实现加载/空/错误和 failure presenter**

`AsyncStateView<T>` 明确接收 `isLoading,failure,isEmpty,onRetry,child`。`FailurePresenter` 返回 `FailurePresentation(message,fieldErrors,requestId,shouldLeavePage,shouldRefresh)`；`ForbiddenFailure.shouldLeavePage=true`，`ConflictFailure.shouldRefresh=true`。

- [ ] **Step 4: GREEN 并提交 Task 5**

Run: `cd client; flutter test test/core/presentation -r expanded`

Expected: PASS。

Commit: `git add client/lib/core/presentation client/test/core/presentation && git commit -m "feat: 添加响应式管理功能壳"`

### Task 6: Platform 领域模型与远端 Repository

**Files:**
- Create: `client/lib/features/platform/domain/platform_group.dart`
- Create: `client/lib/features/platform/data/platform_repository.dart`
- Create: `client/lib/core/network/page_result.dart`
- Create: `client/test/features/platform/platform_group_test.dart`
- Create: `client/test/features/platform/platform_repository_test.dart`
- Create: `client/test/core/network/page_result_test.dart`
- Modify: `client/lib/app/session_scope.dart`

- [ ] **Step 1: 写 DTO 和 HTTP 契约失败测试**

覆盖列表分页、详情 member counts、status/version、existing/new owner 请求体、409/404 映射。断言 Repository 只持有 Dio，不接受 AppDatabase/Outbox。

Run: `cd client; flutter test test/features/platform -r expanded`

Expected: FAIL。

- [ ] **Step 2: 定义 Platform domain 类型**

```dart
enum GroupStatus { active('active'), disabled('disabled'); const GroupStatus(this.wireValue); final String wireValue; }
final class PlatformOwner {
  const PlatformOwner({required this.id, required this.username, required this.displayName});
  final int id; final String username; final String displayName;
  factory PlatformOwner.fromJson(Map<String, Object?> json);
}
final class PlatformGroup {
  const PlatformGroup({required this.id, required this.name, required this.status, required this.owner, required this.memberCount, required this.version, required this.createdAt, required this.updatedAt});
  final int id; final String name; final GroupStatus status; final PlatformOwner owner;
  final int memberCount; final int version; final DateTime createdAt; final DateTime updatedAt;
  factory PlatformGroup.fromJson(Map<String, Object?> json);
}
final class GroupMemberCounts { const GroupMemberCounts({required this.active, required this.disabled, required this.removed}); final int active; final int disabled; final int removed; }
final class OwnerCandidate { const OwnerCandidate({required this.membershipId, required this.user}); final int membershipId; final PlatformOwner user; }
final class PlatformGroupDetail { const PlatformGroupDetail({required this.group, required this.memberCounts, required this.ownerCandidates}); final PlatformGroup group; final GroupMemberCounts memberCounts; final List<OwnerCandidate> ownerCandidates; }
final class PlatformGroupQuery { const PlatformGroupQuery({this.keyword, this.status, this.page = 1, this.pageSize = 20}); final String? keyword; final GroupStatus? status; final int page; final int pageSize; }
final class CreateGroupDraft { const CreateGroupDraft({required this.name, required this.ownerUsername, required this.ownerDisplayName, required this.ownerTemporaryPassword}); final String name; final String ownerUsername; final String ownerDisplayName; final String ownerTemporaryPassword; }
final class CreateGroupResult { const CreateGroupResult({required this.groupId, required this.groupName, required this.owner}); final int groupId; final String groupName; final PlatformOwner owner; }
sealed class OwnerChangeDraft { const OwnerChangeDraft(this.version); final int version; }
final class ExistingMemberOwnerDraft extends OwnerChangeDraft { const ExistingMemberOwnerDraft({required this.membershipId, required super.version}); final int membershipId; }
final class NewAccountOwnerDraft extends OwnerChangeDraft { const NewAccountOwnerDraft({required this.username, required this.displayName, required this.temporaryPassword, required super.version}); final String username; final String displayName; final String temporaryPassword; }
```

- [ ] **Step 3: 定义 Repository 和 Dio adapter**

```dart
final class PageResult<T> {
  const PageResult({required this.items, required this.page, required this.pageSize, required this.total});
  final List<T> items; final int page; final int pageSize; final int total;
}

abstract interface class PlatformRepository {
  Future<PageResult<PlatformGroup>> listGroups(PlatformGroupQuery query);
  Future<PlatformGroupDetail> getGroup(int groupId);
  Future<CreateGroupResult> createGroup(CreateGroupDraft draft);
  Future<PlatformGroup> changeStatus(int groupId, GroupStatus status, int version);
  Future<PlatformGroupDetail> changeOwner(int groupId, OwnerChangeDraft draft);
}
```

路径严格使用 `/api/v1/platform/groups`。`changeOwner` 用 Dart sealed class 生成互斥 body；不得序列化另一模式字段。所有 DioException 通过 `mapDioFailure`。

- [ ] **Step 4: 在会话 Scope 中只为 platform admin 注入**

新增 `platformRepositoryProvider`；只有 `AccountType.platformAdmin` override 为 `DioPlatformRepository(dio)`。租户访问 provider 时抛 StateError，路由守卫保证正常 UI 不触发。

- [ ] **Step 5: GREEN 并提交 Task 6**

Run: `cd client; flutter test test/features/platform test/core/network/page_result_test.dart test/app/session_scope_test.dart -r expanded`

Expected: PASS。

Commit: `git add client/lib/features/platform client/lib/core/network/page_result.dart client/lib/app/session_scope.dart client/test/features/platform client/test/core/network/page_result_test.dart client/test/app/session_scope_test.dart && git commit -m "feat: 添加平台治理数据层"`

### Task 7: Platform Controllers 的乱序、串行写与冲突刷新

**Files:**
- Create: `client/lib/features/platform/application/platform_group_controller.dart`
- Create: `client/lib/features/platform/application/platform_group_detail_controller.dart`
- Create: `client/lib/features/platform/application/create_group_controller.dart`
- Create: `client/test/features/platform/platform_group_controller_test.dart`
- Create: `client/test/features/platform/platform_group_detail_controller_test.dart`
- Create: `client/test/features/platform/create_group_controller_test.dart`

- [ ] **Step 1: 写 Controller 失败测试**

覆盖列表第二次请求先返回时第一请求不能覆盖；启停/owner 写操作串行；409 时保留 `ConflictFailure` 并自动刷新最新详情；dispose 后 Future 不更新状态；创建提交防重复。

Run: `cd client; flutter test test/features/platform -r expanded`

Expected: FAIL。

- [ ] **Step 2: 定义列表状态和 Controller**

```dart
final class PlatformGroupState {
  const PlatformGroupState({this.items = const [], this.query = const PlatformGroupQuery(), this.isLoading = false, this.isWriting = false, this.failure});
  final List<PlatformGroup> items; final PlatformGroupQuery query;
  final bool isLoading; final bool isWriting; final AppFailure? failure;
  PlatformGroupState copyWith({List<PlatformGroup>? items, PlatformGroupQuery? query, bool? isLoading, bool? isWriting, AppFailure? failure, bool clearFailure = false});
}

final platformGroupControllerProvider = NotifierProvider<PlatformGroupController, PlatformGroupState>(PlatformGroupController.new);

class PlatformGroupController extends Notifier<PlatformGroupState> {
  int _generation = 0; Future<void> _writeTail = Future<void>.value();
  Future<void> load(PlatformGroupQuery query);
  Future<void> refresh();
  Future<void> changeStatus(PlatformGroup group, GroupStatus status);
}
```

- [ ] **Step 3: 定义详情和创建 Controller**

`PlatformGroupDetailController` 使用 family provider keyed by groupId，公开 `load/changeStatus/changeOwner`；冲突时保存 failure 后 `await load()`。`CreateGroupController` state 包含 `isSubmitting,failure,createdGroupId`，成功时由页面导航到详情。

- [ ] **Step 4: 实现 dispose 和串行保证**

每个 controller `ref.onDispose(() => _generation++)`；所有 load 在提交 state 前比较 generation；写操作复用 `_writeTail.then`，按钮依据 `isWriting/isSubmitting` 禁用。

- [ ] **Step 5: GREEN 并提交 Task 7**

Run: `cd client; flutter test test/features/platform -r expanded`

Expected: PASS。

Commit: `git add client/lib/features/platform/application client/test/features/platform && git commit -m "feat: 添加平台治理状态控制器"`

### Task 8: Platform 响应式页面

**Files:**
- Create: `client/lib/features/platform/presentation/platform_groups_page.dart`
- Create: `client/lib/features/platform/presentation/create_group_page.dart`
- Create: `client/lib/features/platform/presentation/platform_group_detail_page.dart`
- Create: `client/lib/features/platform/presentation/change_owner_dialog.dart`
- Modify: `client/lib/app/router.dart`
- Create: `client/test/features/platform/platform_pages_test.dart`

- [ ] **Step 1: 写页面交互失败测试**

测试关键词/状态筛选、刷新、新建、进入详情、启停确认、两种 owner 表单、提交中禁用和 409 刷新提示；390/1280 两个宽度 `tester.takeException()` 为 null。

Run: `cd client; flutter test test/features/platform/platform_pages_test.dart`

Expected: FAIL。

- [ ] **Step 2: 实现组列表和新建表单**

手机用 Card/ListTile 展示 name/status/owner/member count；宽屏用紧凑 DataTable。新建字段固定为 name、ownerUsername、ownerDisplayName、ownerTemporaryPassword；密码字段 obscure，Controller/日志不持久化。

- [ ] **Step 3: 实现详情和 owner 交接 dialog**

详情展示 group version、owner、active/disabled/removed 计数。existing 模式从 `PlatformGroupDetail.ownerCandidates` 选择 active 普通成员，显示 display name 与 username，提交对应 membership ID；new 模式使用 username/display name/temporary password。两模式控件互斥并构造对应 sealed draft。

- [ ] **Step 4: 接入真实路由 target**

将 `/platform/groups`、`/platform/groups/new`、`/platform/groups/:groupId` 指向真实页面；解析 groupId 失败回平台列表并显示 validation 消息。

- [ ] **Step 5: GREEN 并提交 Task 8**

Run: `cd client; flutter test test/features/platform test/app/router_test.dart -r expanded`

Expected: PASS。

Commit: `git add client/lib/features/platform/presentation client/lib/app/router.dart client/test/features/platform client/test/app/router_test.dart && git commit -m "feat: 添加平台组管理页面"`

### Task 9: Invitation 数据层和 secret 生命周期 Controller

**Files:**
- Create: `client/lib/features/invitations/domain/invitation.dart`
- Create: `client/lib/features/invitations/data/invitation_repository.dart`
- Create: `client/lib/features/invitations/application/invitation_controller.dart`
- Modify: `client/lib/app/session_scope.dart`
- Create: `client/test/features/invitations/invitation_repository_test.dart`
- Create: `client/test/features/invitations/invitation_controller_test.dart`

- [ ] **Step 1: 写 DTO、HTTP 和 secret 清理失败测试**

覆盖 4 状态、创建/列表/secret/revoke body、no-store 不影响解析；查看 B 自动清除 A；revoke/use/expired 清除 secret；dispose/logout 清除；写串行、乱序 load 和 409 刷新。

Run: `cd client; flutter test test/features/invitations -r expanded`

Expected: FAIL。

- [ ] **Step 2: 定义 Invitation domain**

```dart
enum InvitationStatus { active('active'), expired('expired'), used('used'), revoked('revoked'); const InvitationStatus(this.wireValue); final String wireValue; }
final class InvitationSummary {
  const InvitationSummary({required this.id, required this.status, required this.createdBy, this.usedBy, required this.expiresAt, this.usedAt, this.revokedAt, required this.createdAt, required this.version});
  final int id; final InvitationStatus status; final AuthUser createdBy; final AuthUser? usedBy;
  final DateTime expiresAt; final DateTime? usedAt; final DateTime? revokedAt; final DateTime createdAt; final int version;
  factory InvitationSummary.fromJson(Map<String, Object?> json);
}
final class InvitationSecret { const InvitationSecret({required this.invitationId, required this.code, required this.expiresAt}); final int invitationId; final String code; final DateTime expiresAt; }
```

- [ ] **Step 3: 定义纯远端 Repository**

```dart
abstract interface class InvitationRepository {
  Future<PageResult<InvitationSummary>> list({InvitationStatus? status, int page = 1, int pageSize = 20});
  Future<InvitationSecret> create({int? expiresInDays});
  Future<InvitationSecret> revealSecret(int invitationId);
  Future<InvitationSummary> revoke(int invitationId, int version);
}
```

不得接受 AppDatabase、CredentialStore 或 Outbox。create 解析现有 `invitation_code`；secret 解析相同语义字段并立即返回内存对象。

- [ ] **Step 4: 实现 Controller 临时 secret 规则**

```dart
final class InvitationState {
  const InvitationState({this.items = const [], this.visibleSecret, this.isLoading = false, this.isWriting = false, this.failure});
  final InvitationSecret? visibleSecret;
  final List<InvitationSummary> items; final bool isLoading; final bool isWriting; final AppFailure? failure;
  InvitationState copyWith({List<InvitationSummary>? items, InvitationSecret? visibleSecret, bool? isLoading, bool? isWriting, AppFailure? failure, bool clearSecret = false, bool clearFailure = false});
}

class InvitationController extends Notifier<InvitationState> {
  Future<void> load({InvitationStatus? status});
  Future<void> create({int? expiresInDays});
  Future<void> reveal(int invitationId);
  Future<void> revoke(InvitationSummary invitation);
  void clearSecret();
}
```

`reveal` 在网络调用前清除旧 secret；revoke 成功先清 secret 再替换列表项；load 发现当前 visible invitation 不再 active 时清除；`ref.onDispose(clearSecret)`。

- [ ] **Step 5: 只为 owner 注入 Repository**

Session scope 仅当 accountType=groupOwner 且 memberType=owner 时 override `invitationRepositoryProvider`。普通成员即使有 `member.manage` 也没有 Invitation Controller。

- [ ] **Step 6: GREEN 并提交 Task 9**

Run: `cd client; flutter test test/features/invitations test/app/session_scope_test.dart -r expanded`

Expected: PASS。

Commit: `git add client/lib/features/invitations client/lib/app/session_scope.dart client/test/features/invitations client/test/app/session_scope_test.dart && git commit -m "feat: 添加邀请码安全状态管理"`

### Task 10: Invitation 页面、复制和撤销确认

**Files:**
- Create: `client/lib/features/invitations/presentation/invitations_page.dart`
- Create: `client/lib/features/invitations/presentation/invitation_secret_panel.dart`
- Modify: `client/lib/app/router.dart`
- Create: `client/test/features/invitations/invitations_page_test.dart`

- [ ] **Step 1: 写页面失败测试**

验证页面初始不批量 reveal；active 行显示查看/撤销，其他状态不显示；创建和查看后 secret 可复制；查看另一个时旧 secret 消失；撤销确认后 secret 立即消失；离开路由后 Controller dispose。

Run: `cd client; flutter test test/features/invitations/invitations_page_test.dart`

Expected: FAIL。

- [ ] **Step 2: 实现列表和筛选**

列表显示 status、expiresAt、createdAt、usedAt、revokedAt。手机使用纵向 Card，宽屏使用 DataTable。时间统一转换为本地时间展示，wire model 保持 UTC。

- [ ] **Step 3: 实现 secret panel 和复制**

`InvitationSecretPanel` 只从 `InvitationState.visibleSecret` 读取；复制使用 `Clipboard.setData(ClipboardData(text: secret.code))`，成功反馈不得再次打印 code。页面 dispose 调用 controller `clearSecret()` 作为 Riverpod dispose 之外的显式防线。

- [ ] **Step 4: 接入 `/invitations` 并验证**

Route 仅 owner 可达；返回 `/home` 时 secret 不得残留。撤销 dialog 显示 ID 和状态，不显示 code。

- [ ] **Step 5: GREEN 并提交 Task 10**

Run: `cd client; flutter test test/features/invitations test/app/router_test.dart -r expanded`

Expected: PASS。

Commit: `git add client/lib/features/invitations/presentation client/lib/app/router.dart client/test/features/invitations client/test/app/router_test.dart && git commit -m "feat: 添加邀请码管理页面"`

### Task 11: 成员查询、权限目录和冲突刷新

**Files:**
- Modify: `client/lib/features/members/domain/member.dart`
- Modify: `client/lib/features/members/data/member_repository.dart`
- Modify: `client/lib/features/members/application/member_controller.dart`
- Modify: `client/test/features/members/member_repository_test.dart`
- Modify: `client/test/features/members/member_controller_test.dart`

- [ ] **Step 1: 写查询和权限目录失败测试**

覆盖 keyword/status query、permission catalog 解析、成员分页；409 changeStatus/replacePermissions 后刷新列表或权限详情并保留 ConflictFailure；普通成员不能调用 replacePermissions 的 UI controller 方法。

Run: `cd client; flutter test test/features/members -r expanded`

Expected: FAIL。

- [ ] **Step 2: 扩展 domain 和 Repository**

```dart
final class MemberQuery { const MemberQuery({this.keyword, this.status}); final String? keyword; final MemberStatus? status; }
final class PermissionCatalogItem {
  const PermissionCatalogItem({required this.code, required this.name, required this.description});
  final String code; final String name; final String description;
  factory PermissionCatalogItem.fromJson(Map<String, Object?> json);
}

abstract interface class MemberRepository {
  Future<List<Member>> listMembers(MemberQuery query);
  Future<List<PermissionCatalogItem>> getPermissionCatalog();
  Future<Member> changeStatus(int membershipId, MemberStatus status, int version);
  Future<MemberPermissions> getPermissions(int membershipId);
  Future<MemberPermissions> replacePermissions(int membershipId, Set<String> codes, int version);
}
```

canonical 无筛选查询可写原生缓存；带 keyword/status 的在线结果不覆盖完整 canonical cache。

- [ ] **Step 3: 扩展 Controller**

保存 `_query` 和 permission catalog；`load(query)` 使用 generation；ConflictFailure 时先保留 failure，再执行 `refresh()`，由页面让用户重新决定。授权入口是否可调用由页面和会话角色控制，Repository 仍依赖后端最终授权。

- [ ] **Step 4: GREEN 并提交 Task 11**

Run: `cd client; flutter test test/features/members -r expanded`

Expected: PASS。

Commit: `git add client/lib/features/members client/test/features/members && git commit -m "feat: 完善成员与权限数据流"`

### Task 12: 成员列表和权限完整替换页面

**Files:**
- Create: `client/lib/features/members/presentation/members_page.dart`
- Create: `client/lib/features/members/presentation/member_permissions_page.dart`
- Modify: `client/lib/app/router.dart`
- Create: `client/test/features/members/member_pages_test.dart`

- [ ] **Step 1: 写角色和保护操作失败测试**

owner 可进入权限页；普通成员即使具备 `member.manage` 也不显示授权入口，但可看到成员状态管理入口；无 `member.manage` 的普通成员不显示成员导航；当前账号和 owner 的状态按钮 disabled；权限复选框按目录整体 PUT；窄/宽屏无 overflow。

Run: `cd client; flutter test test/features/members/member_pages_test.dart`

Expected: FAIL。

- [ ] **Step 2: 实现成员列表页**

提供 keyword、status、refresh；显示 username/displayName/memberType/status/version。状态操作对 owner 或具有 `member.manage` 的普通成员显示，只提供后端支持的 active/disabled/removed，并在提交中禁用。`Member` 从既有 `user.id` 解析 `userId`，用它与 `AuthProfile.user.id` 比较当前账号，禁止用 username 判断身份。

- [ ] **Step 3: 实现权限页面**

页面进入时并发读取 permissions 和 catalog；本地 `Set<String>` 作为草稿；保存时一次性调用 `replacePermissions(membershipId,codes,version)`。ConflictFailure 重新加载后保留明确提示，不自动重复提交旧集合。

- [ ] **Step 4: 接入真实路由并验证**

`/members` 对 tenant 用户开放；`/members/:membershipId/permissions` 只允许 owner。非法 membershipId 回 members 并显示 validation message。

- [ ] **Step 5: GREEN 并提交 Task 12**

Run: `cd client; flutter test test/features/members test/app/router_test.dart -r expanded`

Expected: PASS。

Commit: `git add client/lib/features/members/presentation client/lib/features/members/domain/member.dart client/lib/app/router.dart client/test/features/members client/test/app/router_test.dart && git commit -m "feat: 添加成员权限管理页面"`

### Task 13: 字典筛选、角色可写性和统一页面

**Files:**
- Modify: `client/lib/features/dictionaries/application/dictionary_controller.dart`
- Create: `client/lib/features/dictionaries/presentation/dictionaries_page.dart`
- Create: `client/lib/features/dictionaries/presentation/dictionary_editor_dialog.dart`
- Modify: `client/lib/app/router.dart`
- Modify: `client/test/features/dictionaries/dictionary_controller_test.dart`
- Create: `client/test/features/dictionaries/dictionary_page_test.dart`

- [ ] **Step 1: 写六 kind 和权限显示失败测试**

测试六种 kind 共用一个页面；owner 可写；普通成员只有 `AuthProfile.permissionCodes` 包含 `dictionary.manage` 才显示写入口，否则只读；不得从 JWT 猜权限。

Run: `cd client; flutter test test/features/dictionaries -r expanded`

Expected: FAIL。

- [ ] **Step 2: 完善 Controller 冲突行为**

create/update/changeStatus 发生 ConflictFailure 时保留 failure 并 `await refresh()`；NetworkFailure 明确显示“此管理操作需要联网”，绝不写 Outbox。load 仍允许 canonical query 从 Drift 降级读取。

- [ ] **Step 3: 实现统一页面和 editor**

页面提供 kind、parent、status、keyword 筛选；supplier/customer 显示 contact phone，其余 kind 不提交无关字段。editor 的 create/update 复用 `DictionaryDraft`；版本只从当前 entry 读取。

- [ ] **Step 4: 接入 `/dictionaries` 并验证**

窄屏用卡片，宽屏用紧凑表格；普通成员只读时隐藏新增/编辑/启停，而不是显示可点击后再报 403。后端仍做最终授权。

- [ ] **Step 5: GREEN 并提交 Task 13**

Run: `cd client; flutter test test/features/dictionaries test/app/router_test.dart -r expanded`

Expected: PASS。

Commit: `git add client/lib/features/dictionaries client/lib/app/router.dart client/test/features/dictionaries client/test/app/router_test.dart && git commit -m "feat: 添加辅助字典管理页面"`

### Task 14: 登录、注册、强制改密和角色首页

**Files:**
- Create: `client/lib/features/auth/presentation/login_page.dart`
- Create: `client/lib/features/auth/presentation/register_page.dart`
- Create: `client/lib/features/auth/presentation/change_password_page.dart`
- Create: `client/lib/features/home/presentation/tenant_home_page.dart`
- Modify: `client/lib/app/router.dart`
- Create: `client/test/features/auth/auth_pages_test.dart`
- Create: `client/test/features/home/tenant_home_page_test.dart`

- [ ] **Step 1: 写表单和导航失败测试**

登录页含注册入口；注册校验确认密码且成功后回登录并预填 username；改密成功由路由自动进入角色首页；字段 ValidationFailure 映射到对应输入框；密码不出现在 SnackBar。

Run: `cd client; flutter test test/features/auth test/features/home -r expanded`

Expected: FAIL。

- [ ] **Step 2: 实现登录和注册页**

登录只提交 username/password；注册提交 invitationCode/username/displayName/password，confirmPassword 只用于本地相等校验不进 Repository。TextEditingController 在 dispose 清理，password controller 不被 Provider 持久化。

- [ ] **Step 3: 实现强制改密页**

字段为 currentPassword/newPassword/confirmPassword；authenticated 且 mustChangePassword 时禁止展示退出之外的其他业务入口。提交成功后 AuthController 替换 profile，GoRouter 自动重定向。

- [ ] **Step 4: 实现租户首页导航**

owner destinations：home、invitations、members、dictionaries；普通成员始终显示 home、dictionaries，仅在 `member.manage` 已授予时显示 members，且永远无 invitation/permission replacement 入口。首页展示当前用户、组、账号类型和权限摘要，不展示 token。

- [ ] **Step 5: 替换全部认证 route target 并验证**

`/login,/register,/change-password,/home` 指向真实页面；删除旧 `_RouteShell`。

- [ ] **Step 6: GREEN 并提交 Task 14**

Run: `cd client; flutter test test/features/auth test/features/home test/app/router_test.dart -r expanded`

Expected: PASS。

Commit: `git add client/lib/features/auth client/lib/features/home client/lib/app/router.dart client/test/features/auth client/test/features/home client/test/app/router_test.dart && git commit -m "feat: 完成多角色认证入口"`

### Task 15: Fake API 纵向 Widget 闭环

**Files:**
- Create: `client/test/support/fake_backend.dart`
- Create: `client/test/integration/role_operational_loop_test.dart`
- Modify: `client/test/app/router_test.dart`

- [ ] **Step 1: 构建不含真实秘密日志的 Fake Backend**

FakeBackend 用 Dio `HttpClientAdapter` 或 mock remote repositories 实现确定性状态机：admin、group、owner、invitation、member、permissions、dictionary 和 session invalidation。测试失败输出只记录 resource ID/path，不打印 password、refresh token 或 invitation secret。

- [ ] **Step 2: 写平台管理员到 owner 的闭环测试**

Widget 流程：admin 登录 -> 强制改密 -> 创建组 -> 详情停用/启用 -> 新 owner 交接；断言路由始终位于 `/platform/*`，不能进入 tenant 页面。

- [ ] **Step 3: 写 owner 邀请和成员授权闭环测试**

owner 登录 -> 改密 -> 创建邀请码 -> 离开再返回 -> 显式 reveal 同一邀请码 -> 复制 -> 注册 member -> owner 替换权限 -> member 登录读取字典；断言注册不自动登录、登录页 username 已预填。

- [ ] **Step 4: 写会话切换与旧 owner 失效测试**

owner 交接后 fake API 对旧 owner 返回 401；ApiClient invalidator 清理 session，GoRouter 回 `/login`；新 owner 登录时旧 invitation secret、member list 和 dictionary state 均不存在。

- [ ] **Step 5: 验证两种尺寸**

同一闭环的关键页面在 390x844 和 1280x800 pump，断言无 overflow、无未处理 exception。

- [ ] **Step 6: GREEN 并提交 Task 15**

Run: `cd client; flutter test test/integration/role_operational_loop_test.dart -r expanded`

Expected: PASS。

Commit: `git add client/test/support client/test/integration client/test/app/router_test.dart && git commit -m "test: 覆盖 Flutter 多角色操作闭环"`

### Task 16: 真实 Go API + Docker MySQL 纵向验证

**Files:**
- Create: `client/integration_test/real_backend_role_flow_test.dart`
- Modify: `client/pubspec.yaml`
- Modify: `client/README.md`

- [ ] **Step 1: 添加 integration_test 依赖和运行开关**

`dev_dependencies` 增加 Flutter SDK 自带 `integration_test`。测试读取 `--dart-define=CBIZ_API_BASE_URL=...` 和只在本地注入的测试账号，不把凭据写进仓库；缺少开关时使用 `skip`，不误连生产。

Run: `cd client; flutter pub get`

Expected: `pubspec.lock` 更新且依赖解析成功。

- [ ] **Step 2: 检查 Docker 原始状态**

Run: `docker context show`

Run: `docker ps -a --filter "name=^/MySQL$" --filter "name=^/Redis$"`

Run: `docker inspect MySQL`

Run: `docker inspect Redis`

Expected: 记录原始状态、端口和网络，不输出容器环境变量。只启动本轮需要且原本停止的容器，结束后恢复。

- [ ] **Step 3: 启动真实后端并验证 health**

通过本地未跟踪环境变量设置 `MYSQL_DSN`、`JWT_SECRET`、`INVITATION_ENCRYPTION_KEY` 和 bootstrap 凭据，再启动 API。Run: `Invoke-RestMethod http://127.0.0.1:8080/health/ready`。

Expected: HTTP 200，mysql=up；Redis 降级状态允许按现有健康契约显示，不得阻塞核心 CRUD。

- [ ] **Step 4: 执行真实纵向流程**

测试顺序固定为：平台管理员登录/改密 -> 创建组/owner -> owner 登录/改密 -> 创建并再次查看 invitation -> member 注册/登录 -> owner 替换权限 -> member 读取字典 -> platform admin 更换 owner -> 旧 owner session 失效。

- [ ] **Step 5: 运行 integration test**

Run: `cd client; flutter test integration_test/real_backend_role_flow_test.dart --dart-define=CBIZ_API_BASE_URL=http://127.0.0.1:8080`

Expected: PASS；测试数据只存在本地测试数据库。测试和后端进程结束后恢复 Docker 原始状态。

- [ ] **Step 6: 记录运行方法并提交 Task 16**

README 只记录命令、必要变量名、Docker 检查和恢复步骤，不记录真实值。

Commit: `git add client/pubspec.yaml client/pubspec.lock client/integration_test client/README.md && git commit -m "test: 添加真实后端角色闭环验证"`

### Task 17: Flutter 全量质量门禁和跨端构建

**Files:**
- Modify only if verification exposes an issue: files already listed in Tasks 1-16

- [ ] **Step 1: 格式化、分析和全量测试**

Run: `cd client; dart format --output=none --set-exit-if-changed lib test integration_test`

Run: `cd client; flutter analyze`

Run: `cd client; flutter test -r expanded`

Expected: 全部 PASS，无 analyzer warning/error。

- [ ] **Step 2: 构建 Web 并验证不初始化 Drift**

Run: `cd client; flutter build web --debug --dart-define=CBIZ_API_BASE_URL=http://127.0.0.1:8080`

Expected: PASS；Web bootstrap 使用 `AppDatabase? = null`，不导入 native sqlite 实现到 Web runtime。

- [ ] **Step 3: 构建 Android Debug APK**

Run: `cd client; flutter build apk --debug --dart-define=CBIZ_API_BASE_URL=http://10.0.2.2:8080`

Expected: PASS，输出 `build/app/outputs/flutter-apk/app-debug.apk`。`10.0.2.2` 仅为 Android Emulator 访问宿主机；真机需使用局域网地址或 adb reverse。

- [ ] **Step 4: 尝试 Windows 构建并诚实记录环境结果**

Run: `cd client; flutter build windows --debug --dart-define=CBIZ_API_BASE_URL=http://127.0.0.1:8080`

Expected: 若开发者模式已启用则 PASS；若仍因 plugin symlink 失败，记录为宿主机环境阻塞，不修改代码绕过，也不宣称 Windows 构建成功。

- [ ] **Step 5: 扫描秘密和离线越界**

Run: `rg -n "invitation(Code|Secret)|refreshToken|password" client/lib client/test`

Expected: password 仅存在表单/请求参数，refresh token 仅存在认证安全存储路径，invitation secret 仅存在 Invitation Controller/页面临时状态；不得出现在 Drift table、Outbox payload、日志或通用 failure message。

Run: `rg -n "Outbox|enqueue" client/lib/features/platform client/lib/features/invitations client/lib/features/members client/lib/features/dictionaries`

Expected: 管理写路径无 enqueue；现有 Outbox 底座未被这些 Controller 使用。

- [ ] **Step 6: 检查 diff 并提交验证修复（如有）**

Run: `git status --short; git diff --check; git diff --stat`

Expected: 无无关生成物、无 build 目录、无凭据。若修复，重跑对应测试并提交：

```bash
git add <Tasks 1-16 中实际修复的文件>
git commit -m "fix: 完善 Flutter 多角色闭环"
```

- [ ] **Step 7: 推送当前 main**

Run: `git fetch origin main; git status --short --branch`

Expected: main 未与远端分叉；若分叉则停止并请主人决定。

Run: `git push origin main`

Expected: 普通 push 成功，禁止 force push。

## Flutter 验收清单

- `/auth/me` 是角色、组和会话 scope 的唯一身份事实源，客户端不解析 JWT 推断权限。
- 登录、恢复、改密和账号切换都会创建正确的新 session scope，旧 Controller/Repository/secret 被销毁。
- platform admin 只能进入 `/platform/*`；tenant 用户不能进入平台区；普通成员不能进入 invitation/permissions 路由。
- 平台组、邀请码、成员权限和字典页面在手机/宽屏均可操作且无横向溢出。
- 邀请码只按用户动作单条查看，离页、查看另一条、撤销、终态、logout 和 session invalidation 都清除 secret。
- 平台与管理写操作在线失败时显示明确错误，绝不进入 Outbox。
- Fake API Widget 闭环和真实 Go API + Docker MySQL 闭环均通过。
- `flutter analyze`、`flutter test`、Web debug build、Android debug APK build 通过；Windows build 结果按真实宿主机能力记录。
