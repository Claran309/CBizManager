import 'dart:async';

import 'package:c_biz_docs_manager/core/network/page_result.dart';
import 'package:c_biz_docs_manager/features/invitations/data/invitation_repository.dart';
import 'package:c_biz_docs_manager/features/invitations/domain/invitation.dart';

/// 可编程的邀请码仓储假实现，供 Controller 测试使用。
///
/// 每个方法支持三种行为，按优先级：
/// 1. **排队响应**（`queuedXxx`）—— 放一个尚未完成的 `Completer.future` 进去，
///    就能把调用卡在「在途」，用来构造「请求还没回来时明文该不该清」这类时序场景；
/// 2. **注入错误**（`xxxError`）—— 以 Future 的错误完成，正好被 Controller 的
///    `on AppFailure catch` 接住；
/// 3. **默认结果**（`xxxResult`）—— 什么都没配时才用到；若也没配，抛 [StateError]
///    提醒用例漏了装配（而不是悄悄返回一个空结果，让断言以莫名其妙的方式通过）。
///
/// 调用参数都会被记录，方便断言「界面点的确实是这一条、带的是这个 version」。
final class FakeInvitationRepository implements InvitationRepository {
  /* ---------------------------------------------------------------- 列表 */

  final List<({InvitationStatus? status, int page, int pageSize})> listCalls =
      <({InvitationStatus? status, int page, int pageSize})>[];
  final List<Future<PageResult<InvitationSummary>>> queuedLists =
      <Future<PageResult<InvitationSummary>>>[];
  PageResult<InvitationSummary>? listResult;
  Object? listError;

  @override
  Future<PageResult<InvitationSummary>> list({
    InvitationStatus? status,
    int page = 1,
    int pageSize = 20,
  }) {
    listCalls.add((status: status, page: page, pageSize: pageSize));
    return _next<PageResult<InvitationSummary>>(
      queuedLists,
      listResult,
      listError,
      'list',
    );
  }

  /* ---------------------------------------------------------------- 创建 */

  final List<int?> createRequests = <int?>[];
  final List<Future<InvitationSecret>> queuedCreates =
      <Future<InvitationSecret>>[];
  InvitationSecret? createResult;
  Object? createError;

  @override
  Future<InvitationSecret> create({int? expiresInDays}) {
    createRequests.add(expiresInDays);
    return _next<InvitationSecret>(
      queuedCreates,
      createResult,
      createError,
      'create',
    );
  }

  /* ------------------------------------------------------------ 查看明文 */

  final List<int> revealRequests = <int>[];
  final List<Future<InvitationSecret>> queuedReveals =
      <Future<InvitationSecret>>[];
  InvitationSecret? revealResult;
  Object? revealError;

  @override
  Future<InvitationSecret> revealSecret(int invitationId) {
    revealRequests.add(invitationId);
    return _next<InvitationSecret>(
      queuedReveals,
      revealResult,
      revealError,
      'revealSecret',
    );
  }

  /* ---------------------------------------------------------------- 撤销 */

  final List<({int invitationId, int version})> revokeRequests =
      <({int invitationId, int version})>[];
  final List<Future<InvitationSummary>> queuedRevokes =
      <Future<InvitationSummary>>[];
  InvitationSummary? revokeResult;
  Object? revokeError;

  @override
  Future<InvitationSummary> revoke(int invitationId, int version) {
    revokeRequests.add((invitationId: invitationId, version: version));
    return _next<InvitationSummary>(
      queuedRevokes,
      revokeResult,
      revokeError,
      'revoke',
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
    return Future<T>.error(
      StateError('FakeInvitationRepository.$method 未配置响应'),
    );
  }
  return Future<T>.value(fallback);
}
