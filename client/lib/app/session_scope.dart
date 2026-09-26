import 'package:c_biz_docs_manager/core/auth/auth_models.dart';
import 'package:c_biz_docs_manager/core/database/app_database.dart';
import 'package:c_biz_docs_manager/features/dictionaries/application/dictionary_controller.dart';
import 'package:c_biz_docs_manager/features/dictionaries/data/dictionary_repository.dart';
import 'package:c_biz_docs_manager/features/documents/data/document_repository.dart';
import 'package:c_biz_docs_manager/features/documents/domain/document.dart';
import 'package:c_biz_docs_manager/features/finance/data/finance_repository.dart';
import 'package:c_biz_docs_manager/features/finance/domain/finance.dart';
import 'package:c_biz_docs_manager/features/invitations/data/invitation_repository.dart';
import 'package:c_biz_docs_manager/features/members/application/member_controller.dart';
import 'package:c_biz_docs_manager/features/members/data/member_repository.dart';
import 'package:c_biz_docs_manager/features/platform/data/platform_repository.dart';
import 'package:c_biz_docs_manager/features/reports/data/report_repository.dart';
import 'package:c_biz_docs_manager/features/settlements/data/settlement_repository.dart';
import 'package:dio/dio.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;

/// 会话级依赖的装配层。
///
/// 这里解决一个具体问题：**换账号、换组之后不能看到上一个人的数据**。
///
/// 做法是把 Provider 分成两层：
///
/// 1. *应用级*（本文件上半部分）—— Dio、本地数据库、缓存开关。整个进程只需
///    一份，与"当前是谁"无关，因此不随登录登出重建。
/// 2. *会话级*（[activeSessionProvider] 与各业务 Repository）—— 它们各自持有
///    `userId` / `groupId`，必须与"当前是谁"严格绑定。它们**不设默认实现**，
///    只能由 [AuthenticatedSessionScope] 在登录后装配、登出后随作用域一起销毁。
///
/// 关键在于"不设默认实现"：一个能兜底读数的默认 Repository，等于给跨账号
/// 串数据留了一条静默的后路。宁可让误读在读取瞬间抛 [StateError]，
/// 也不要让它悄悄读到别人的列表。

/* ------------------------------------------------------------ 应用级依赖 */

/// 全局 HTTP 客户端。
///
/// 它是应用级的：访问令牌由 `ApiClient` 拦截器在每次请求时注入，与"当前是谁"
/// 无关；把 Dio 放进会话作用域只会让连接池、拦截器随每次登录反复重建，
/// 反而增加握手开销。
///
/// 刻意不提供默认值——忘记装配时立刻抛 [StateError]，
/// 总好过让一个没有 `baseUrl` 的客户端悄悄把请求发到 localhost。
final dioProvider = Provider<Dio>((Ref ref) {
  throw StateError('Dio has not been configured');
});

/// 进程内共享的本地数据库句柄（Drift / SQLite）。
///
/// 一个进程只需要一条 SQLite 连接：跨账号的数据隔离由各缓存表上的
/// `(user_id, group_id)` 联合主键保证，而不是"一人一个数据库文件"。
/// 所以它同样属于应用级，会话切换时**不应该**重建。
///
/// 默认 `null` 表示"本次运行没有本地数据库"（例如 Web 端，或尚未初始化）。
final appDatabaseProvider = Provider<AppDatabase?>((Ref ref) => null);

/// 是否启用本地离线缓存。
///
/// 默认关闭是刻意的：缓存是**可用性优化**，不是正确性依赖。
/// 在没有数据库句柄的前提下强行打开，会直接踩中 Repository 构造函数里
/// `assert(!cacheEnabled || database != null)`，所以"默认关、需要时显式开"
/// 比"默认开、出错再排查"安全得多。
final nativeCacheEnabledProvider = Provider<bool>((Ref ref) => false);

/* ------------------------------------------------------------ 会话级依赖 */

/// 当前生效的会话。
///
/// 只在 [AuthenticatedSessionScope] 内部可读。未登录时读取会抛 [StateError]，
/// 这正是我们想要的：未登录状态下任何"我是谁"的读取都是 bug，
/// 不应该拿到一个空壳身份继续把流程走下去。
final activeSessionProvider = Provider<AuthSession>((Ref ref) {
  throw StateError('No authenticated session is active');
});

/// 依据一次会话，算出该会话专属的 Provider 覆盖列表。
///
/// 之所以收敛成一个函数、而不是散落在各个 Widget 里，是因为它是**唯一**决定
/// "哪些 Repository 属于哪个人、哪个组"的地方——跨账号串数据这类缺陷只可能
/// 从这一处产生，所以也只需要在这一处修。
///
/// 约定：
/// - `activeSessionProvider` 永远被覆盖成 [session]；
/// - 平台管理员**只**装配平台治理仓储：它是跨组视角，没有租户数据可读，
///   任何租户 Repository 的读取都会当场抛错；
/// - 租户身份必须带 group，否则立刻抛错（绝不允许退化成 `groupId = 0`）；
/// - 租户**不**装配平台治理仓储：那是平台管理员的战场，路由守卫已经挡住了
///   界面入口，装配层再挡一道，防止将来有人从别处误读全平台的组；
/// - Repository 的 `userId` / `groupId` 取自**服务端返回的 profile**，
///   不取自本地缓存的旧值——本地缓存恰恰是最可能过期的那一份。
///
/// [ref] 应指向**会话作用域之外**的应用级 [Ref]：应用级依赖在那里才是稳定的。
List<Override> buildSessionOverrides(Ref ref, AuthSession session) {
  return _sessionOverrides(
    session: session,
    appDio: ref.read(dioProvider),
    database: ref.read(appDatabaseProvider),
    cacheEnabled: ref.read(nativeCacheEnabledProvider),
  );
}

/// [buildSessionOverrides] 的实现主体，依赖全部显式传入。
///
/// 单独拆出来是为了让 Widget 层（只有 `WidgetRef`，拿不到 `Ref`）也能复用
/// 同一套装配规则，而不必把判断逻辑抄第二遍——抄一遍就意味着两处都可能走偏。
List<Override> _sessionOverrides({
  required AuthSession session,
  required Dio appDio,
  required AppDatabase? database,
  required bool cacheEnabled,
}) {
  final overrides = <Override>[
    activeSessionProvider.overrideWithValue(session),
  ];

  final profile = session.profile;
  if (profile.accountType == AccountType.platformAdmin) {
    // 平台管理员不属于任何组，没有成员、字典这类租户数据可读，
    // 这里刻意**不**注册任何租户兜底实现：管理端界面一旦误读租户 Repository
    // 就会当场炸出来，而不是悄悄读到一个"默认组"的跨组数据。
    //
    // 但平台治理本身是他的本职工作，所以必须装配 —— 而且只装配这一个：
    // 它不需要 userId / groupId（看的是全平台的组），天然就没有数据范围可收敛。
    return <Override>[
      ...overrides,
      platformRepositoryProvider.overrideWithValue(
        DioPlatformRepository(appDio),
      ),
    ];
  }

  final group = profile.group;
  if (group == null) {
    // AuthProfile.fromJson 已经拦过这种身份，这里是第二道防线：
    // 即使有人手搓了一个不完整的 profile（例如测试里绕过严格解析），
    // 也不允许它把 groupId 当成 0 去读写别人的缓存。
    throw StateError('A tenant session must belong to a group');
  }

  // 只有确认拿到数据库句柄时才真的开缓存，避免断言失败。
  final canCache = cacheEnabled && database != null;
  final userId = profile.user.id;
  final groupId = group.id;

  return <Override>[
    ...overrides,
    memberRepositoryProvider.overrideWithValue(
      DefaultMemberRepository(
        remote: DioMemberRemoteDataSource(appDio),
        database: database,
        userId: userId,
        groupId: groupId,
        cacheEnabled: canCache,
      ),
    ),
    dictionaryRepositoryProvider.overrideWithValue(
      DefaultDictionaryRepository(
        remote: DioDictionaryRemoteDataSource(appDio),
        database: database,
        userId: userId,
        groupId: groupId,
        cacheEnabled: canCache,
      ),
    ),
    // 邀请码管理**只属于组主账号**。普通成员就算被授予了 `member.manage`
    // 也只是能管成员，不该能凭空造出入组凭证 —— 那等于给自己发一张提权门票。
    //
    // 所以这里不装配它的仓储：未装配意味着读取立刻抛 StateError，而不是悄悄
    // 退化成某个能读到邀请码的默认实现。界面入口那一侧由路由守卫挡住（`/invitations`
    // 是 owner-only），装配层这一侧再挡一道，防止将来有人从别处误读。
    //
    // 判两个条件而不是只判 accountType：AuthProfile 的严格解析已经保证
    // 「group_owner ⇒ member_type = owner」，但装配层不该依赖别处的校验结果 ——
    // 万一有谁手搓了一个不完整的 profile（测试里就这么干过），这里必须自己站稳。
    if (profile.accountType == AccountType.groupOwner &&
        profile.memberType == MemberType.owner)
      invitationRepositoryProvider.overrideWithValue(
        DioInvitationRepository(appDio),
      ),
    // 单据：入库 / 出库各一个实例（kind 由装配决定，路径前缀据此拼）。
    inboundDocumentRepositoryProvider.overrideWithValue(
      DioDocumentRepository(appDio, DocumentKind.inbound),
    ),
    outboundDocumentRepositoryProvider.overrideWithValue(
      DioDocumentRepository(appDio, DocumentKind.outbound),
    ),
    // 结算单：业务员申请本人的、审批人看全组，数据范围由服务端收敛。
    settlementRepositoryProvider.overrideWithValue(
      DioSettlementRepository(appDio),
    ),
    // 财务：付款 / 收款 / 开票各一个实例（kind 由装配决定）。
    // 登记资格（finance.record）由服务端逐请求校验，装配层不做权限裁剪 ——
    // 结清视图本身是「看单据」的延伸，任何能看该单据的人都该读到。
    paymentRepositoryProvider.overrideWithValue(
      DioFinanceRepository(appDio, FinanceKind.payment),
    ),
    receiptRepositoryProvider.overrideWithValue(
      DioFinanceRepository(appDio, FinanceKind.receipt),
    ),
    invoiceRepositoryProvider.overrideWithValue(
      DioFinanceRepository(appDio, FinanceKind.invoice),
    ),
    // 报表汇总统计的可见范围是「全组」，需要 report.view。与邀请码同样的思路：
    // 没有该权限时不装配 —— 读取立刻抛 StateError，而不是悄悄退化成某个默认实现。
    // 界面入口那一侧由路由守卫挡住（isReportLocation），装配层这一侧再挡一道。
    if (profile.hasPermission('report.view'))
      reportRepositoryProvider.overrideWithValue(DioReportRepository(appDio)),
  ];
}

/// 把认证后的界面整体包进一个"会话作用域"。
///
/// [ProviderScope] 的 key 取 [AuthSession.scopeKey]：账号、所属组、角色、
/// 改密态或权限集合**任一变化**都会得到不同的 key。key 一变，Flutter 就把
/// 这个 [ProviderScope] 当成全新的 Widget —— 卸载旧的（其 [State.dispose]
/// 会 dispose 掉整个子容器，连带销毁里面所有 Provider / Notifier），
/// 再挂载新的。这才是"换账号后看不到上一个人的列表"的真正保障，
/// 而不是在界面上手动清空列表。
///
/// 登出时上层直接不再渲染本组件，旧作用域同样被卸载销毁。
final class AuthenticatedSessionScope extends ConsumerWidget {
  const AuthenticatedSessionScope({
    super.key,
    required this.session,
    required this.child,
  });

  /// 本次作用域绑定的会话；由上层从认证状态里取。
  final AuthSession session;

  /// 作用域内的界面，通常是 `MaterialApp.router`。
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 这里用 read 而不是 watch：应用级依赖在整个进程生命周期内是常量，
    // 每次 build 都重新生成一份 override 只会让 ProviderScope 反复
    // 调用 updateOverrides，白白重建 Repository。
    return ProviderScope(
      key: ValueKey<String>(session.scopeKey),
      overrides: _sessionOverrides(
        session: session,
        appDio: ref.read(dioProvider),
        database: ref.read(appDatabaseProvider),
        cacheEnabled: ref.read(nativeCacheEnabledProvider),
      ),
      child: child,
    );
  }
}
