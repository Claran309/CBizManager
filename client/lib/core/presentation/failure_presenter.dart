import 'package:c_biz_docs_manager/core/error/app_failure.dart';

/// 一次失败在界面上「该呈现成什么」，以及「页面该做什么」。
///
/// 把这两件事放在一起，是因为它们是同一个判断的两面：看到 `ConflictFailure`
/// 就既要知道「提示数据已被改过」，也要知道「接下来必须刷新」。
/// 让页面各自去 `switch (failure)`，等于把同一套规则抄到每个页面里，
/// 迟早会出现「A 页刷新了、B 页忘了刷新」这种不一致。
///
/// [shouldLeavePage] / [shouldRefresh] 只是**建议**：本层不持有 `BuildContext`，
/// 不自己导航、不自己发请求。谁来执行由页面决定（页面才知道自己的路由与 Controller）。
final class FailurePresentation {
  const FailurePresentation({
    required this.message,
    this.fieldErrors = const <String, String>{},
    this.requestId,
    this.shouldLeavePage = false,
    this.shouldRefresh = false,
  });

  /// 给用户看的那一句话。
  ///
  /// 能用服务端返回的文案就用服务端的（它更具体，比如「组不存在」），
  /// 只在服务端文案无法指导用户下一步动作时才换成客户端固定文案。
  final String message;

  /// 字段名 → 错误文案，供表单把这些错误挂到对应输入框下方。
  final Map<String, String> fieldErrors;

  /// 服务端 Request ID。用于对账排查，界面上要能选中复制。
  final String? requestId;

  /// 当前地址对这个身份已经不再合法，页面应当立刻离开（守卫会接手）。
  final bool shouldLeavePage;

  /// 数据在本次操作期间被改动过，页面应当重新拉取后再让用户决定。
  final bool shouldRefresh;

  bool get hasFieldErrors => fieldErrors.isNotEmpty;
}

/// 把领域失败翻译成界面决策。
///
/// 覆盖规则严格对齐设计文档「错误处理」一节；每条分支都写清为什么，
/// 因为这里改一个字，全站所有页面的错误提示都会跟着变。
final class FailurePresenter {
  const FailurePresenter._();

  static FailurePresentation present(AppFailure failure) {
    switch (failure) {
      case ValidationFailure():
        // 服务端的 message 是这段错误的摘要，真正的细节在 fields 里，
        // 两者都要给出去：摘要用于顶部提示条，fields 用于逐字段标红。
        return FailurePresentation(
          message: failure.message,
          fieldErrors: failure.fields,
          requestId: failure.requestId,
        );

      case ConflictFailure():
        // 这里**刻意丢弃**服务端文案：无论冲突的具体字段是什么，
        // 用户唯一的正确动作都是「先看最新数据，再重新决定」。
        // 直接把「version 不等于 3」这类底层信息抛给业务员只会造成困惑。
        return FailurePresentation(
          message: '数据已被其他操作修改，请刷新后重新操作',
          requestId: failure.requestId,
          shouldRefresh: true,
        );

      case ForbiddenFailure():
        // 权限刚刚被收走时，当前页面上的数据已经不该继续展示，
        // 所以让页面主动离开，回到该角色的首页（守卫会放行那里）。
        return FailurePresentation(
          message: failure.message,
          requestId: failure.requestId,
          shouldLeavePage: true,
        );

      case UnauthenticatedFailure():
        // 这里**故意不设** shouldLeavePage：会话失效是全局事件，
        // 由 401 单飞刷新失败 → AuthSessionInvalidator → 路由守卫统一回登录页。
        // 页面若再跳一次，就会和守卫的跳转抢跑，出现两次导航甚至闪屏。
        return FailurePresentation(
          message: failure.message,
          requestId: failure.requestId,
        );

      case NetworkFailure():
        // 平台管理与组内管理类写操作都要求联网（不进 Outbox），
        // 所以文案必须点明「需要联网」，否则用户会以为是操作失败了。
        return FailurePresentation(message: '网络不可用，该操作需要联网，请检查网络后重试');

      case ServerFailure():
        // 服务端错误对用户没有可操作信息，只能给出通用文案；
        // requestId 是给客服/运维对账用的，所以必须原样带出去。
        return FailurePresentation(
          message: failure.message,
          requestId: failure.requestId,
        );
    }
  }
}
