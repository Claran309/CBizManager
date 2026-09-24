import 'dart:async';

import 'package:c_biz_docs_manager/core/error/app_failure.dart';
import 'package:c_biz_docs_manager/features/members/application/member_controller.dart';
import 'package:c_biz_docs_manager/features/members/data/member_repository.dart';
import 'package:c_biz_docs_manager/features/members/domain/member.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
// `Override` 在 Riverpod 3 里由 misc.dart 导出，主入口只给常用的那一组。
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

/// 可编程的成员仓储假实现。
///
/// 每个方法支持三种行为，按优先级：**排队响应**（把未完成的 `Completer` 放进去，
/// 用来制造「在途」时序）→ **注入错误** → **默认结果**。
/// 调用参数全被记录，方便断言「界面上点的确实是这一条、带的是这个 version」。
final class FakeMemberRepository implements MemberRepository {
  List<Member> members = const <Member>[];
  List<PermissionCatalogItem> catalog = const <PermissionCatalogItem>[];

  /* ---------------------------------------------------------------- 列表 */

  final List<MemberQuery> queries = <MemberQuery>[];
  final List<Future<List<Member>>> queuedLists = <Future<List<Member>>>[];
  Object? listError;

  /// 只让**下一次**查询失败（一次性）。
  ///
  /// 用它而不是往 [queuedLists] 里塞一个 `Future.error`：后者在测试体里被创建时
  /// 还没有任何监听者，Dart 会把它当作未处理的异步错误报给测试框架，
  /// 用例就会红在一个跟被测逻辑完全无关的地方。这里是在方法**被调用时**才构造
  /// 失败的 Future，调用方紧接着 await，不存在裸露窗口。
  Object? nextListError;

  @override
  Future<List<Member>> listMembers(MemberQuery query) {
    queries.add(query);
    final nextError = nextListError;
    if (nextError != null) {
      nextListError = null;
      return Future<List<Member>>.error(nextError);
    }
    return _next<List<Member>>(queuedLists, members, listError, 'listMembers');
  }

  /* ------------------------------------------------------------ 权限目录 */

  int catalogCalls = 0;
  final List<Future<List<PermissionCatalogItem>>> queuedCatalogs =
      <Future<List<PermissionCatalogItem>>>[];
  Object? catalogError;

  @override
  Future<List<PermissionCatalogItem>> getPermissionCatalog() {
    catalogCalls++;
    return _next<List<PermissionCatalogItem>>(
      queuedCatalogs,
      catalog,
      catalogError,
      'getPermissionCatalog',
    );
  }

  /* ------------------------------------------------------------ 权限快照 */

  final List<int> permissionReads = <int>[];
  final List<Future<MemberPermissions>> queuedPermissionReads =
      <Future<MemberPermissions>>[];
  Object? permissionsError;

  @override
  Future<MemberPermissions> getPermissions(int membershipId) {
    permissionReads.add(membershipId);
    return _next<MemberPermissions>(
      queuedPermissionReads,
      MemberPermissions(
        membershipId: membershipId,
        permissionCodes: const <String>{},
        version: 1,
      ),
      permissionsError,
      'getPermissions',
    );
  }

  /* ---------------------------------------------------------------- 写操作 */

  int statusWriteCalls = 0;
  final List<Completer<Member>> statusWrites = <Completer<Member>>[];
  final List<Future<MemberPermissions>> queuedPermissionWrites =
      <Future<MemberPermissions>>[];
  Object? writeError;

  @override
  Future<Member> changeStatus(
    int membershipId,
    MemberStatus status,
    int version,
  ) {
    statusWriteCalls++;
    if (statusWrites.isNotEmpty) return statusWrites.removeAt(0).future;
    final error = writeError;
    if (error != null) return Future<Member>.error(error);
    if (members.isEmpty) {
      return Future<Member>.error(StateError('FakeMemberRepository 没有可返回的成员'));
    }
    return Future<Member>.value(members.single);
  }

  final List<({int membershipId, Set<String> codes, int version})>
  permissionWrites = <({int membershipId, Set<String> codes, int version})>[];

  @override
  Future<MemberPermissions> replacePermissions(
    int membershipId,
    Set<String> codes,
    int version,
  ) {
    permissionWrites.add((
      membershipId: membershipId,
      codes: codes,
      version: version,
    ));
    return _next<MemberPermissions>(
      queuedPermissionWrites,
      MemberPermissions(
        membershipId: membershipId,
        permissionCodes: codes,
        version: version + 1,
      ),
      writeError,
      'replacePermissions',
    );
  }
}

Future<T> _next<T>(
  List<Future<T>> queue,
  T? fallback,
  Object? error,
  String method,
) {
  if (queue.isNotEmpty) return queue.removeAt(0);
  if (error != null) return Future<T>.error(error);
  if (fallback == null) return Future<T>.error(StateError('未配置 $method 的响应'));
  return Future<T>.value(fallback);
}

/* ------------------------------------------------------------------ 夹具 */

const memberFixture = Member(
  membershipId: 7,
  userId: 101,
  username: 'alice',
  displayName: 'Alice',
  memberType: 'member',
  status: MemberStatus.active,
  permissionCodes: <String>{},
  version: 1,
);

const disabledMemberFixture = Member(
  membershipId: 7,
  userId: 101,
  username: 'alice',
  displayName: 'Alice',
  memberType: 'member',
  status: MemberStatus.disabled,
  permissionCodes: <String>{},
  version: 2,
);

const newerMemberFixture = Member(
  membershipId: 7,
  userId: 101,
  username: 'alice',
  displayName: 'Alice',
  memberType: 'member',
  status: MemberStatus.active,
  permissionCodes: <String>{},
  version: 3,
);

const catalogFixture = <PermissionCatalogItem>[
  PermissionCatalogItem(
    code: 'document.view_others',
    name: '查看他人单据',
    description: '可以查看同组其他业务员的单据',
  ),
  PermissionCatalogItem(
    code: 'member.manage',
    name: '成员管理',
    description: '可以新增、停用成员并调整权限',
  ),
];

void main() {
  late FakeMemberRepository repository;

  setUp(() => repository = FakeMemberRepository());

  ({ProviderContainer container, MemberController controller})
  setUpContainer() {
    final container = ProviderContainer(
      overrides: <Override>[
        memberRepositoryProvider.overrideWithValue(repository),
      ],
    );
    addTearDown(container.dispose);
    return (
      container: container,
      controller: container.read(memberControllerProvider.notifier),
    );
  }

  MemberState stateOf(ProviderContainer container) =>
      container.read(memberControllerProvider);

  /* ------------------------------------------------------------ 查询条件 */

  group('成员查询', () {
    test('筛选条件传给仓储，refresh 复用同一份条件', () async {
      final (:ProviderContainer container, :MemberController controller) =
          setUpContainer();

      await controller.load(
        const MemberQuery(keyword: 'alice', status: MemberStatus.disabled),
      );
      expect(repository.queries, hasLength(1));
      expect(repository.queries.single.keyword, 'alice');
      expect(repository.queries.single.status, MemberStatus.disabled);

      await controller.refresh();

      // refresh 若丢了条件，用户点「刷新」之后看到的是全量名单 ——
      // 他会以为筛选被自动取消了。
      expect(repository.queries, hasLength(2));
      expect(repository.queries.last.keyword, 'alice');
      expect(repository.queries.last.status, MemberStatus.disabled);
      expect(stateOf(container).items, isEmpty);
    });

    test('新的一轮加载不被旧响应覆盖', () async {
      final first = Completer<List<Member>>();
      final second = Completer<List<Member>>();
      repository.queuedLists.addAll(<Future<List<Member>>>[
        first.future,
        second.future,
      ]);
      final (:ProviderContainer container, :MemberController controller) =
          setUpContainer();

      final olderLoad = controller.load(const MemberQuery(keyword: 'old'));
      final newerLoad = controller.load(const MemberQuery(keyword: 'new'));
      second.complete(const <Member>[newerMemberFixture]);
      await newerLoad;
      first.complete(const <Member>[memberFixture]);
      await olderLoad;

      expect(stateOf(container).items, const <Member>[newerMemberFixture]);
    });
  });

  /* ------------------------------------------------------------ 权限目录 */

  group('权限目录', () {
    test('目录只拉一次，重复进入权限页不会重复请求', () async {
      repository.catalog = catalogFixture;
      final (:ProviderContainer container, :MemberController controller) =
          setUpContainer();

      await controller.loadPermissionCatalog();
      expect(repository.catalogCalls, 1);
      expect(stateOf(container).permissionCatalog, catalogFixture);

      await controller.loadPermissionCatalog();

      // 目录是后端固化的常量表，每次进权限页都重拉只是白发一次请求。
      expect(repository.catalogCalls, 1);
      expect(stateOf(container).isLoadingCatalog, isFalse);
    });

    test('目录拉取失败如实上报，重试能恢复', () async {
      repository.catalogError = const NetworkFailure('offline');
      final (:ProviderContainer container, :MemberController controller) =
          setUpContainer();

      await controller.loadPermissionCatalog();
      expect(stateOf(container).failure, isA<NetworkFailure>());
      expect(stateOf(container).permissionCatalog, isEmpty);

      // 失败时目录仍为空，所以下一次进入必须还能重试 ——
      // 否则用户永远看不到复选框列表。
      repository.catalogError = null;
      repository.catalog = catalogFixture;
      await controller.loadPermissionCatalog();

      expect(stateOf(container).permissionCatalog, catalogFixture);
      expect(stateOf(container).failure, isNull);
    });
  });

  /* ------------------------------------------------------------ 权限快照 */

  group('权限快照', () {
    test('切换成员时先清掉上一份快照，不显示错人的权限', () async {
      final (:ProviderContainer container, :MemberController controller) =
          setUpContainer();
      repository.queuedPermissionReads.add(
        Future<MemberPermissions>.value(
          const MemberPermissions(
            membershipId: 7,
            permissionCodes: <String>{'member.manage'},
            version: 3,
          ),
        ),
      );
      await controller.loadPermissions(7);
      expect(stateOf(container).permissionsMembershipId, 7);

      // 换到 8，请求挂在在途状态。
      final gate = Completer<MemberPermissions>();
      repository.queuedPermissionReads.add(gate.future);
      final pending = controller.loadPermissions(8);
      await Future<void>.delayed(Duration.zero);

      // 用户点开 B 的权限页时，屏幕上若还留着 A 的勾选状态，
      // 他会拿一个错的基线去改，保存下去就是把 B 的权限换成 A 那一套。
      expect(stateOf(container).permissions, isNull);
      expect(stateOf(container).isLoadingPermissions, isTrue);

      gate.complete(
        const MemberPermissions(
          membershipId: 8,
          permissionCodes: <String>{},
          version: 1,
        ),
      );
      await pending;
      expect(stateOf(container).permissionsMembershipId, 8);
      expect(stateOf(container).isLoadingPermissions, isFalse);
    });

    test('读取快照会把列表里那一行的权限一起对齐', () async {
      repository.members = const <Member>[memberFixture];
      final (:ProviderContainer container, :MemberController controller) =
          setUpContainer();
      await controller.load();
      repository.queuedPermissionReads.add(
        Future<MemberPermissions>.value(
          const MemberPermissions(
            membershipId: 7,
            permissionCodes: <String>{'member.manage', 'report.view'},
            version: 5,
          ),
        ),
      );

      await controller.loadPermissions(7);

      final row = stateOf(container).items.single;
      expect(row.version, 5);
      expect(row.permissionCodes, <String>{'member.manage', 'report.view'});
    });
  });

  /* ---------------------------------------------------------------- 冲突 */

  group('冲突刷新', () {
    test('停用撞 409 后重读列表，并保留冲突提示', () async {
      repository.members = const <Member>[memberFixture];
      final (:ProviderContainer container, :MemberController controller) =
          setUpContainer();
      await controller.load();
      repository.writeError = const ConflictFailure('版本过期');

      await controller.changeStatus(7, MemberStatus.disabled, 1);

      // 重读了一次列表（初始一次 + 冲突后一次）。
      expect(repository.queries, hasLength(2));
      // 「刷新不等于成功」：数据确实变了，只是没变成用户要的样子，
      // 提示必须留到用户重新做决定之后。
      expect(stateOf(container).failure, isA<ConflictFailure>());
      expect(stateOf(container).isWriting, isFalse);
    });

    test('替换权限撞 409 后连快照一起重读，并保留冲突提示', () async {
      repository.members = const <Member>[memberFixture];
      final (:ProviderContainer container, :MemberController controller) =
          setUpContainer();
      await controller.load();
      await controller.loadPermissions(7);
      // 第一次读取快照 + 冲突后重读 = 2 次。
      expect(repository.permissionReads, hasLength(1));

      repository.writeError = const ConflictFailure('版本过期');
      await controller.replacePermissions(7, const <String>{'report.view'}, 1);

      expect(repository.queries, hasLength(2));
      expect(repository.permissionReads, hasLength(2));
      expect(stateOf(container).failure, isA<ConflictFailure>());
    });

    test('重读本身也失败时，保留那个更新的失败', () async {
      repository.members = const <Member>[memberFixture];
      final (:ProviderContainer container, :MemberController controller) =
          setUpContainer();
      await controller.load();
      repository.nextListError = const NetworkFailure('offline');
      repository.writeError = const ConflictFailure('版本过期');

      await controller.changeStatus(7, MemberStatus.disabled, 1);

      // 「连不上」比「版本过期」更紧迫：用户先得能连上，才谈得上重新决定。
      expect(stateOf(container).failure, isA<NetworkFailure>());
    });
  });

  /* ------------------------------------------------------------ 写操作 */

  group('写操作', () {
    test('权限替换成功后列表行与快照一起换成新版本', () async {
      repository.members = const <Member>[memberFixture];
      final (:ProviderContainer container, :MemberController controller) =
          setUpContainer();
      await controller.load();

      await controller.replacePermissions(7, const <String>{'report.view'}, 1);

      expect(repository.permissionWrites.single.version, 1);
      final state = stateOf(container);
      // 不跟着涨 version 的话，用户紧接着再改一次，用的还是旧凭据，
      // 会白撞一次 409。
      expect(state.items.single.version, 2);
      expect(state.permissions?.version, 2);
      expect(state.items.single.permissionCodes, <String>{'report.view'});
    });

    test('权限被后端拒绝时如实呈现 ForbiddenFailure，而不是自行放行', () async {
      repository.members = const <Member>[memberFixture];
      final (:ProviderContainer container, :MemberController controller) =
          setUpContainer();
      await controller.load();
      // 普通成员（没有 member.manage）在页面上不该看到入口，
      // 但 Controller **不做角色判断**：授权始终以后端为准，
      // 这里要验证的是后端拒绝时客户端如实呈现、不吞掉也不假成功。
      repository.writeError = const ForbiddenFailure('无权修改成员权限');

      await controller.replacePermissions(7, const <String>{'report.view'}, 1);

      expect(stateOf(container).failure, isA<ForbiddenFailure>());
      // 列表里那一行必须**原样保留**：失败的替换不能让本地先"看起来成功了"。
      expect(stateOf(container).items.single.permissionCodes, isEmpty);
      expect(stateOf(container).items.single.version, 1);
    });

    test('写操作串行，且 isWriting 在两次之间保持为真', () async {
      final first = Completer<Member>();
      final second = Completer<Member>();
      repository
        ..members = const <Member>[memberFixture]
        ..statusWrites.addAll(<Completer<Member>>[first, second]);
      final (:ProviderContainer container, :MemberController controller) =
          setUpContainer();
      await controller.load();

      final firstWrite = controller.changeStatus(7, MemberStatus.disabled, 1);
      final secondWrite = controller.changeStatus(7, MemberStatus.active, 2);
      await Future<void>.delayed(Duration.zero);
      expect(repository.statusWriteCalls, 1);

      first.complete(disabledMemberFixture);
      await firstWrite;
      await Future<void>.delayed(Duration.zero);
      expect(repository.statusWriteCalls, 2);
      expect(stateOf(container).isWriting, isTrue);

      second.complete(newerMemberFixture);
      await secondWrite;

      expect(stateOf(container).isWriting, isFalse);
      expect(stateOf(container).items, const <Member>[newerMemberFixture]);
    });

    test('作用域销毁后写 state 不抛错，也不把结果写回去', () async {
      final gate = Completer<Member>();
      repository
        ..members = const <Member>[memberFixture]
        ..statusWrites.add(gate);
      final container = ProviderContainer(
        overrides: <Override>[
          memberRepositoryProvider.overrideWithValue(repository),
        ],
      );
      final controller = container.read(memberControllerProvider.notifier);
      await controller.load();

      final pending = controller.changeStatus(7, MemberStatus.disabled, 1);
      await Future<void>.delayed(Duration.zero);
      container.dispose();
      gate.complete(disabledMemberFixture);

      // 不抛异常就算过：这里要守住的是「上一个人的数据不会被画到新会话的界面上」。
      await expectLater(pending, completes);
    });
  });
}
