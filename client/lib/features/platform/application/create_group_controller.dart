import 'package:c_biz_docs_manager/core/error/app_failure.dart';
import 'package:c_biz_docs_manager/features/platform/data/platform_repository.dart';
import 'package:c_biz_docs_manager/features/platform/domain/platform_group.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 新建组的提交状态。
final createGroupControllerProvider =
    NotifierProvider<CreateGroupController, CreateGroupState>(
      CreateGroupController.new,
      dependencies: [platformRepositoryProvider],
    );

final class CreateGroupState {
  const CreateGroupState({
    this.isSubmitting = false,
    this.failure,
    this.createdGroupId,
  });

  /// 是否正在提交。界面据此禁用「创建」按钮。
  final bool isSubmitting;

  /// 最近一次提交失败的原因（组名重复、用户名重复、密码太短…）。
  final AppFailure? failure;

  /// 创建成功后的组 id。
  ///
  /// 用「状态里的一个值」而不是回调来驱动导航：创建与导航之间隔着一次异步请求，
  /// 回调在页面被销毁后触发就会操作一个已卸载的 `BuildContext`；而状态是页面的
  /// 一部分，页面没了就没人监听，天然安全。页面 watch 到它非空即跳详情，
  /// 跳之前调 [CreateGroupController.reset] 清掉，免得返回本页时又被弹走。
  final int? createdGroupId;

  CreateGroupState copyWith({
    bool? isSubmitting,
    AppFailure? failure,
    bool clearFailure = false,
    int? createdGroupId,
    bool clearCreatedGroupId = false,
  }) {
    return CreateGroupState(
      isSubmitting: isSubmitting ?? this.isSubmitting,
      failure: clearFailure ? null : failure ?? this.failure,
      createdGroupId: clearCreatedGroupId
          ? null
          : createdGroupId ?? this.createdGroupId,
    );
  }
}

/// 新建组及其主账号的提交控制器。
final class CreateGroupController extends Notifier<CreateGroupState> {
  var _disposed = false;

  PlatformRepository get _repository => ref.read(platformRepositoryProvider);

  @override
  CreateGroupState build() {
    ref.onDispose(() => _disposed = true);
    return const CreateGroupState();
  }

  /// 提交创建请求；返回创建结果，失败返回 null（原因在 [CreateGroupState.failure]）。
  Future<CreateGroupResult?> submit(CreateGroupDraft draft) async {
    // 防重复提交的关键是「判空 + 置位」之间**不能有 await**：
    // 两行都是同步的，所以即使连点两次，第二次进来时看到的已经是 true，
    // 会直接返回而不发第二个请求（否则会创建出两个组或撞组名重复）。
    if (_disposed || state.isSubmitting) return null;
    state = state.copyWith(
      isSubmitting: true,
      clearFailure: true,
      clearCreatedGroupId: true,
    );
    // 取好仓储再 await：dispose 之后再碰 ref 会抛错。
    final repository = _repository;
    try {
      final result = await repository.createGroup(draft);
      if (_disposed) return result;
      state = state.copyWith(
        createdGroupId: result.groupId,
        clearFailure: true,
      );
      return result;
    } on AppFailure catch (failure) {
      if (_disposed) return null;
      state = state.copyWith(failure: failure);
      return null;
    } finally {
      if (!_disposed) {
        state = state.copyWith(isSubmitting: false);
      }
    }
  }

  /// 清空提交结果与失败原因。
  ///
  /// 两个时机要调：导航去详情页之前（避免返回时重复跳转）、用户改完表单重新提交之前
  /// （避免旧的「组名已存在」一直挂在那里）。
  void reset() {
    if (_disposed) return;
    state = const CreateGroupState();
  }
}
