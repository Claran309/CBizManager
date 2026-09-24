import 'dart:async';

import 'package:c_biz_docs_manager/core/network/page_result.dart';
import 'package:c_biz_docs_manager/features/platform/data/platform_repository.dart';
import 'package:c_biz_docs_manager/features/platform/domain/platform_group.dart';

/// 可编程的平台治理仓储假实现，供 Controller 测试使用。
///
/// 每个方法支持三种行为，按优先级：
/// 1. **排队响应**（`queuedXxx`）—— 放一个尚未完成的 `Completer.future` 进去，
///    就能把调用卡在「在途」，用来构造乱序返回、请求在途时销毁作用域这些时序场景；
/// 2. **注入错误**（`xxxError`）—— 以 Future 的错误完成，正好被 Controller 的
///    `on AppFailure catch` 接住；
/// 3. **默认结果**（`xxxResult`）—— 什么都没配时才用到；若也没配，抛 [StateError]
///    提醒用例漏了装配（而不是悄悄返回一个空结果，让断言以莫名其妙的方式通过）。
///
/// 调用参数都会被记录，方便断言「界面选的条件确实传到了仓储」。
final class FakePlatformRepository implements PlatformRepository {
  /* ---------------------------------------------------------------- 列表 */

  final List<PlatformGroupQuery> listQueries = <PlatformGroupQuery>[];
  final List<Future<PageResult<PlatformGroup>>> queuedLists =
      <Future<PageResult<PlatformGroup>>>[];
  PageResult<PlatformGroup>? listResult;
  Object? listError;

  @override
  Future<PageResult<PlatformGroup>> listGroups(PlatformGroupQuery query) {
    listQueries.add(query);
    return _next<PageResult<PlatformGroup>>(
      queuedLists,
      listResult,
      listError,
      'listGroups',
    );
  }

  /* ---------------------------------------------------------------- 详情 */

  final List<int> detailRequests = <int>[];
  final List<Future<PlatformGroupDetail>> queuedDetails =
      <Future<PlatformGroupDetail>>[];
  PlatformGroupDetail? detailResult;
  Object? detailError;

  @override
  Future<PlatformGroupDetail> getGroup(int groupId) {
    detailRequests.add(groupId);
    return _next<PlatformGroupDetail>(
      queuedDetails,
      detailResult,
      detailError,
      'getGroup',
    );
  }

  /* ---------------------------------------------------------------- 启停 */

  int changeStatusCalls = 0;
  final List<Future<PlatformGroup>> queuedStatusWrites =
      <Future<PlatformGroup>>[];
  PlatformGroup? statusResult;
  Object? statusError;

  @override
  Future<PlatformGroup> changeStatus(
    int groupId,
    GroupStatus status,
    int version,
  ) {
    changeStatusCalls++;
    return _next<PlatformGroup>(
      queuedStatusWrites,
      statusResult,
      statusError,
      'changeStatus',
    );
  }

  /* ---------------------------------------------------------------- 交接 */

  final List<OwnerChangeDraft> ownerDrafts = <OwnerChangeDraft>[];
  final List<Future<PlatformGroupDetail>> queuedOwnerWrites =
      <Future<PlatformGroupDetail>>[];
  PlatformGroupDetail? ownerResult;
  Object? ownerError;

  @override
  Future<PlatformGroupDetail> changeOwner(int groupId, OwnerChangeDraft draft) {
    ownerDrafts.add(draft);
    return _next<PlatformGroupDetail>(
      queuedOwnerWrites,
      ownerResult,
      ownerError,
      'changeOwner',
    );
  }

  /* ---------------------------------------------------------------- 创建 */

  final List<CreateGroupDraft> createDrafts = <CreateGroupDraft>[];
  final List<Future<CreateGroupResult>> queuedCreateWrites =
      <Future<CreateGroupResult>>[];
  CreateGroupResult? createResult;
  Object? createError;

  @override
  Future<CreateGroupResult> createGroup(CreateGroupDraft draft) {
    createDrafts.add(draft);
    return _next<CreateGroupResult>(
      queuedCreateWrites,
      createResult,
      createError,
      'createGroup',
    );
  }
}

/// 依次尝试「排队响应 → 注入错误 → 默认结果」。
Future<T> _next<T>(
  List<Future<T>> queue,
  T? fallback,
  Object? error,
  String method,
) {
  if (queue.isNotEmpty) return queue.removeAt(0);
  if (error != null) return Future<T>.error(error);
  if (fallback == null) {
    return Future<T>.error(StateError('FakePlatformRepository.$method 未配置响应'));
  }
  return Future<T>.value(fallback);
}
