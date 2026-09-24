import 'package:c_biz_docs_manager/core/auth/auth_controller.dart';
import 'package:c_biz_docs_manager/core/auth/auth_models.dart';
import 'package:c_biz_docs_manager/features/auth/presentation/change_password_page.dart';
import 'package:c_biz_docs_manager/features/auth/presentation/login_page.dart';
import 'package:c_biz_docs_manager/features/auth/presentation/register_page.dart';
import 'package:c_biz_docs_manager/features/auth/presentation/splash_page.dart';
import 'package:c_biz_docs_manager/features/dictionaries/presentation/dictionaries_page.dart';
import 'package:c_biz_docs_manager/features/home/presentation/tenant_home_page.dart';
import 'package:c_biz_docs_manager/features/invitations/presentation/invitations_page.dart';
import 'package:c_biz_docs_manager/features/members/presentation/member_permissions_page.dart';
import 'package:c_biz_docs_manager/features/members/presentation/members_page.dart';
import 'package:c_biz_docs_manager/features/platform/presentation/create_group_page.dart';
import 'package:c_biz_docs_manager/features/platform/presentation/platform_group_detail_page.dart';
import 'package:c_biz_docs_manager/features/platform/presentation/platform_groups_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

/* ------------------------------------------------------ 路由分类与角色首页 */

/// 公开区域：未登录也能停留的地址。
///
/// `/register` 与 `/login` 同级：注册只建账号、不建会话，所以它必须能在
/// 未登录态访问；但它同样不该被已登录用户停留（会被送去角色首页）。
bool isPublicLocation(String path) => path == '/login' || path == '/register';

/// 平台管理员专属区域。
///
/// 用 `startsWith('/platform/groups/')` 覆盖详情页这类子路径，
/// 而不是逐个枚举——新增子路由时不会漏判成「租户可访问」。
bool isPlatformLocation(String path) =>
    path == '/platform/groups' || path.startsWith('/platform/groups/');

/// 仅组主账号可进入的地址。
///
/// 两处都属于「分配权限」的元操作：邀请码决定谁能进组，权限页决定组员能看什么。
bool isOwnerOnlyLocation(String path) =>
    path == '/invitations' || path.endsWith('/permissions');

/// 成员管理入口。组主账号隐式允许，普通成员需 `member.manage`。
bool isMemberManagementLocation(String path) => path == '/members';

/// 当前身份的「角色首页」。
///
/// 无权地址一律回到这里，而不是回登录页：用户是合法登录态，
/// 只是走错了地方，把他踢回登录页会让人以为自己被登出了；
/// 而且回到一个**该角色必然有权停留**的地址，才不会再被重定向，
/// 从根上避免 redirect 循环。
String roleHome(AuthProfile profile) =>
    profile.accountType == AccountType.platformAdmin
    ? '/platform/groups'
    : '/home';

/* ---------------------------------------------------------------- 守卫矩阵 */

/// 计算一次跳转：返回 null 表示「允许停留在 [location]」。
///
/// 判定顺序严格按设计规格，**顺序本身就是语义**：
///
/// 1. `restoring` —— 还不知道用户是谁，只能停在 `/splash`。
/// 2. 未登录（或已登录却没有会话这种非法组合）—— 只允许公开区域。
/// 3. `must_change_password` —— 只能停在 `/change-password`，
///    优先级高于角色分域：改密没完成时，连自己的角色首页都不该进。
/// 4. 平台管理员 —— 只能进 `/platform/*`。
/// 5. 租户用户 —— 不能进 `/platform/*`。
/// 6. owner 专属 —— 邀请码与权限替换页。
/// 7. `member.manage` —— 普通成员进入成员管理页的前提。
/// 8. 过渡页 —— 已登录用户不该再停在 splash / login / register / change-password。
///
/// 「平台/租户分域」放在「owner 专属」之前是必要的：否则平台管理员访问
/// `/invitations` 会先被第 6 条判成 owner-only、再回落到平台首页，
/// 虽然结果相同，但顺序错了以后加日志或加提示就会收到误导性信息。
String? authRedirect(AuthState auth, String location) {
  // 1. 会话恢复中：任何业务入口都先回 splash。
  if (auth.phase == AuthPhase.restoring) {
    return location == '/splash' ? null : '/splash';
  }

  final session = auth.session;
  if (session == null) {
    // 2. 未登录。这里用 `session == null` 而不是 `phase == unauthenticated`，
    // 顺带把「已登录却没会话」这种被 AuthState 断言禁止的组合也兜住：
    // release 下断言不生效，万一真有 bug 造出这种状态，
    // 当成未登录处理是唯一不会泄露他人数据的方向。
    return isPublicLocation(location) ? null : '/login';
  }

  final profile = session.profile;

  // 3. 强制改密是硬门槛。
  if (profile.mustChangePassword) {
    return location == '/change-password' ? null : '/change-password';
  }

  final home = roleHome(profile);

  // 4./5. 平台管理员与租户用户互不越界。
  if (profile.accountType == AccountType.platformAdmin) {
    return isPlatformLocation(location) ? null : home;
  }
  if (isPlatformLocation(location)) {
    return home;
  }

  // 6. owner 专属地址。hasPermission 对主账号恒为 true，但这里要的是
  // 「只有主账号」——所以判 accountType，而不是权限码。
  if (isOwnerOnlyLocation(location) &&
      profile.accountType != AccountType.groupOwner) {
    return home;
  }

  // 7. 成员管理入口：主账号隐式持有组内全部权限（AuthProfile.hasPermission
  // 内部已处理），普通成员则必须拿到服务端显式下发的 member.manage。
  if (isMemberManagementLocation(location) &&
      !profile.hasPermission('member.manage')) {
    return home;
  }

  // 8. 过渡页：登录完成后不该再停留在公开页面。
  if (location == '/splash' ||
      isPublicLocation(location) ||
      location == '/change-password') {
    return home;
  }

  return null;
}

/* ------------------------------------------------------------------ 路由表 */

/// 解析 `/platform/groups/:groupId` 里的组编号。
///
/// 返回 null 表示地址里的编号非法。调用方负责把用户送回组列表并提示，
/// 而不是让详情页带着一个假 ID 去请求 —— 那样只会拿到一个 404，
/// 外加一条完全没法指导下一步的提示。
int? parseGroupId(String? raw) => _parsePositiveId(raw);

/// 解析 `/members/:membershipId/permissions` 里的成员编号。
///
/// 与 [parseGroupId] 共用同一套判定（正整数、下界 1），只是语义不同。
/// 拆成两个具名函数是为了让调用点读起来就是「组编号」「成员编号」，
/// 而不是满屏的 `parsePositiveId` —— 读错语义时没人拦得住你。
int? parseMembershipId(String? raw) => _parsePositiveId(raw);

/// 契约里所有 `*_id` 都是 `minimum: 1`，所以 0 与负数一律非法。
int? _parsePositiveId(String? raw) {
  if (raw == null) return null;
  final value = int.tryParse(raw);
  if (value == null || value < 1) return null;
  return value;
}

/// 组详情地址的跳转决策：编号非法就回列表并带上提示，合法则留在原地。
///
/// 单独抽成一个纯函数，是为了让「非法编号会去哪」这件事能被直接断言 ——
/// 在 `redirect` 回调里构造一个 `GoRouterState` 只为了测一个 if，
/// 会让人宁可不测。
String? groupDetailRedirect(String? rawGroupId) =>
    parseGroupId(rawGroupId) == null
    ? '/platform/groups?notice=invalid_group_id'
    : null;

/// 权限替换地址的跳转决策：编号非法就回成员列表并带上提示。
///
/// 与组详情同样的理由：一个假 ID 打到 `/members/0/permissions` 只会得到 404，
/// 用户既不知道发生了什么，也不知道下一步该去哪。
String? memberPermissionsRedirect(String? rawMembershipId) =>
    parseMembershipId(rawMembershipId) == null
    ? '/members?notice=invalid_membership_id'
    : null;

final routerProvider = Provider<GoRouter>((Ref ref) {
  final refresh = _AuthRouterRefresh(ref);
  ref.onDispose(refresh.dispose);
  return GoRouter(
    initialLocation: '/splash',
    refreshListenable: refresh,
    redirect: (BuildContext context, GoRouterState state) =>
        authRedirect(ref.read(authControllerProvider), state.matchedLocation),
    routes: <RouteBase>[
      GoRoute(
        path: '/splash',
        builder: (BuildContext context, GoRouterState state) =>
            const SplashPage(),
      ),
      GoRoute(
        path: '/login',
        builder: (BuildContext context, GoRouterState state) =>
            const LoginPage(),
      ),
      GoRoute(
        path: '/register',
        builder: (BuildContext context, GoRouterState state) =>
            const RegisterPage(),
      ),
      GoRoute(
        path: '/change-password',
        builder: (BuildContext context, GoRouterState state) =>
            const ChangePasswordPage(),
      ),
      // 字面量路由必须排在参数路由之前：`/platform/groups/new` 同样会被
      // `/platform/groups/:groupId` 匹配，先声明具体的那个，才不会把
      // 「新建组」当成 groupId='new' 的详情页。
      GoRoute(
        path: '/platform/groups',
        builder: (BuildContext context, GoRouterState state) =>
            PlatformGroupsPage(
              // 提示由地址上的 query 参数带进来：这样「/platform/groups/abc
              // 跳回列表」之后地址栏和用户看到的内容是一致的 —— 用页面内
              // 的临时状态做提示，会让地址停在 `/abc` 上而内容却是列表。
              notice: state.uri.queryParameters['notice'],
            ),
      ),
      GoRoute(
        path: '/platform/groups/new',
        builder: (BuildContext context, GoRouterState state) =>
            const CreateGroupPage(),
      ),
      GoRoute(
        path: '/platform/groups/:groupId',
        // 编号非法时**重定向**而不是在 builder 里渲染列表页：builder 期间
        // 调 go() 会撞上「构建过程中改路由」的断言，而 redirect 是框架
        // 明确支持的地址改写时机。
        redirect: (BuildContext context, GoRouterState state) =>
            groupDetailRedirect(state.pathParameters['groupId']),
        builder: (BuildContext context, GoRouterState state) =>
            PlatformGroupDetailPage(
              // redirect 已经挡掉非法编号，类型系统却不知道，所以这里再解析
              // 一次；真拿到 null 说明 redirect 与 builder 的判断不一致，
              // 用 0 兜底会让详情页请求 `/groups/0` 并得到一个明确的 404，
              // 比在路由层抛异常更容易定位。
              groupId: parseGroupId(state.pathParameters['groupId']) ?? 0,
              key: ValueKey<String>('group-${state.pathParameters['groupId']}'),
            ),
      ),
      GoRoute(
        path: '/home',
        builder: (BuildContext context, GoRouterState state) =>
            const TenantHomePage(),
      ),
      GoRoute(
        path: '/invitations',
        builder: (BuildContext context, GoRouterState state) =>
            const InvitationsPage(),
      ),
      GoRoute(
        path: '/members',
        builder: (BuildContext context, GoRouterState state) => MembersPage(
          // 非法 membershipsId 被重定向回来时由地址上的 query 带提示，
          // 与平台组列表同一套做法：地址栏与内容始终一致。
          notice: state.uri.queryParameters['notice'],
        ),
      ),
      GoRoute(
        path: '/members/:membershipId/permissions',
        // 编号非法就**重定向**回成员列表，而不是在 builder 里渲染别的页面：
        // builder 期间调 go() 会撞上「构建过程中改路由」的断言。
        redirect: (BuildContext context, GoRouterState state) =>
            memberPermissionsRedirect(state.pathParameters['membershipId']),
        builder: (BuildContext context, GoRouterState state) =>
            MemberPermissionsPage(
              // redirect 已经挡掉非法编号，类型系统却不知道，所以这里再解析
              // 一次；真拿到 null 说明 redirect 与 builder 的判断不一致，
              // 用 0 兜底会让页面请求 `/members/0/permissions` 并得到一个明确的
              // 404，比在路由层抛异常更容易定位。
              membershipId:
                  parseMembershipId(state.pathParameters['membershipId']) ?? 0,
              // 换一个成员就是一个新的页面状态：草稿、失败提示都该从头开始。
              key: ValueKey<String>(
                'member-permissions-${state.pathParameters['membershipId']}',
              ),
            ),
      ),
      GoRoute(
        path: '/dictionaries',
        builder: (BuildContext context, GoRouterState state) =>
            const DictionariesPage(),
      ),
    ],
  );
});

/// 把 Riverpod 里的认证状态变化桥接成 GoRouter 能监听的 [Listenable]。
///
/// GoRouter 只在 `refreshListenable` 通知时重跑 redirect，
/// 所以「令牌刷新失败 → 状态转未登录 → 跳登录页」全靠这个订阅。
final class _AuthRouterRefresh extends ChangeNotifier {
  _AuthRouterRefresh(Ref ref) {
    _subscription = ref.listen<AuthState>(authControllerProvider, (
      AuthState? previous,
      AuthState next,
    ) {
      notifyListeners();
    });
  }

  late final ProviderSubscription<AuthState> _subscription;

  @override
  void dispose() {
    _subscription.close();
    super.dispose();
  }
}
