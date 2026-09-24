import 'package:c_biz_docs_manager/core/error/app_failure.dart';
import 'package:c_biz_docs_manager/features/members/data/member_repository.dart';
import 'package:c_biz_docs_manager/features/members/domain/member.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Bootstrap or a future authenticated scope must provide the concrete
/// repository after the active user and group are known.
final memberRepositoryProvider = Provider<MemberRepository>((Ref ref) {
  throw StateError('MemberRepository has not been configured');
});

final memberControllerProvider =
    NotifierProvider<MemberController, MemberState>(
      MemberController.new,
      // 声明「本 Controller 属于 memberRepositoryProvider 所在的作用域」。
      //
      // Riverpod 3 的传递式作用域（transitive scoping）会据此把本 Provider
      // 挂载到**覆盖了该仓储的那个容器**里，也就是认证会话作用域；
      // 没被覆盖时（例如平台管理员）才退回根容器。
      //
      // 少了这一行，本 Controller 会挂在根容器上被所有会话共享：
      // 换账号时它不会重建，上一个人的成员列表会被下一个会话直接读到。
      // 这里读的是 ref.read 而不是 build 里的 watch，Riverpod 无从自动推断，
      // 所以必须手动声明。
      dependencies: [memberRepositoryProvider],
    );

final class MemberState {
  const MemberState({
    this.items = const <Member>[],
    this.isLoading = false,
    this.isWriting = false,
    this.failure,
  });

  final List<Member> items;
  final bool isLoading;
  final bool isWriting;
  final AppFailure? failure;

  MemberState copyWith({
    List<Member>? items,
    bool? isLoading,
    bool? isWriting,
    AppFailure? failure,
    bool clearFailure = false,
  }) {
    return MemberState(
      items: items ?? this.items,
      isLoading: isLoading ?? this.isLoading,
      isWriting: isWriting ?? this.isWriting,
      failure: clearFailure ? null : failure ?? this.failure,
    );
  }
}

/// Owns member screen state so widgets never need to call Dio directly.
final class MemberController extends Notifier<MemberState> {
  var _loadGeneration = 0;
  Future<void> _writeTail = Future<void>.value();

  /// 会话作用域是否已销毁。
  ///
  /// 销毁后仍然可能有一次在途请求回到这里（切账号的瞬间最容易发生），
  /// 此时写 state 会抛错，更糟的是会把上一个人的数据写到新会话的界面上。
  /// 所以每个写入点都要先看这个标记。
  var _disposed = false;

  MemberRepository get _repository => ref.read(memberRepositoryProvider);

  /// 在途结果是否还允许写回状态。已有更新的一轮请求或已被销毁时都不允许。
  bool _isCurrent(int generation) =>
      !_disposed && generation == _loadGeneration;

  @override
  MemberState build() {
    ref.onDispose(() {
      _disposed = true;
      // 让在途的 load 结果立刻作废。
      _loadGeneration++;
    });
    return const MemberState();
  }

  Future<void> load() async {
    final generation = ++_loadGeneration;
    if (_disposed) return;
    state = state.copyWith(isLoading: true, clearFailure: true);
    try {
      final items = await _repository.listMembers();
      if (_isCurrent(generation)) {
        state = state.copyWith(items: items, clearFailure: true);
      }
    } on AppFailure catch (failure) {
      if (_isCurrent(generation)) {
        state = state.copyWith(failure: failure);
      }
    } finally {
      if (_isCurrent(generation)) {
        state = state.copyWith(isLoading: false);
      }
    }
  }

  Future<void> refresh() => load();

  Future<void> changeStatus(
    int membershipId,
    MemberStatus status,
    int version,
  ) {
    // 先取好仓储：dispose 之后再碰 ref 会抛错，而写操作是排队的，
    // 真正执行时可能已经不在这个作用域里了。
    final repository = _repository;
    return _enqueueWrite(() async {
      if (_disposed) return;
      state = state.copyWith(isWriting: true, clearFailure: true);
      try {
        final updated = await repository.changeStatus(
          membershipId,
          status,
          version,
        );
        if (_disposed) return;
        state = state.copyWith(
          items: _replaceMember(state.items, updated),
          clearFailure: true,
        );
      } on AppFailure catch (failure) {
        if (_disposed) return;
        state = state.copyWith(failure: failure);
      } finally {
        if (!_disposed) {
          state = state.copyWith(isWriting: false);
        }
      }
    });
  }

  Future<void> replacePermissions(
    int membershipId,
    Set<String> codes,
    int version,
  ) {
    final repository = _repository;
    return _enqueueWrite(() async {
      if (_disposed) return;
      state = state.copyWith(isWriting: true, clearFailure: true);
      try {
        final permissions = await repository.replacePermissions(
          membershipId,
          codes,
          version,
        );
        if (_disposed) return;
        state = state.copyWith(
          items: <Member>[
            for (final member in state.items)
              if (member.membershipId == membershipId)
                Member(
                  membershipId: member.membershipId,
                  username: member.username,
                  displayName: member.displayName,
                  memberType: member.memberType,
                  status: member.status,
                  permissionCodes: permissions.permissionCodes,
                  version: permissions.version,
                )
              else
                member,
          ],
          clearFailure: true,
        );
      } on AppFailure catch (failure) {
        if (_disposed) return;
        state = state.copyWith(failure: failure);
      } finally {
        if (!_disposed) {
          state = state.copyWith(isWriting: false);
        }
      }
    });
  }

  Future<void> _enqueueWrite(Future<void> Function() operation) {
    final result = _writeTail.then((_) => operation());
    _writeTail = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }
}

List<Member> _replaceMember(List<Member> items, Member updated) => <Member>[
  for (final member in items)
    if (member.membershipId == updated.membershipId) updated else member,
];
