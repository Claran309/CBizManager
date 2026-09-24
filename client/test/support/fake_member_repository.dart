import 'dart:async';

import 'package:c_biz_docs_manager/features/members/data/member_repository.dart';
import 'package:c_biz_docs_manager/features/members/domain/member.dart';

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
