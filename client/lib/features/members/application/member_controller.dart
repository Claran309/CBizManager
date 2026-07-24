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
    NotifierProvider<MemberController, MemberState>(MemberController.new);

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

  MemberRepository get _repository => ref.read(memberRepositoryProvider);

  @override
  MemberState build() => const MemberState();

  Future<void> load() async {
    final generation = ++_loadGeneration;
    state = state.copyWith(isLoading: true, clearFailure: true);
    try {
      final items = await _repository.listMembers();
      if (generation == _loadGeneration) {
        state = state.copyWith(items: items, clearFailure: true);
      }
    } on AppFailure catch (failure) {
      if (generation == _loadGeneration) {
        state = state.copyWith(failure: failure);
      }
    } finally {
      if (generation == _loadGeneration) {
        state = state.copyWith(isLoading: false);
      }
    }
  }

  Future<void> refresh() => load();

  Future<void> changeStatus(
    int membershipId,
    MemberStatus status,
    int version,
  ) => _enqueueWrite(() async {
    state = state.copyWith(isWriting: true, clearFailure: true);
    try {
      final updated = await _repository.changeStatus(
        membershipId,
        status,
        version,
      );
      state = state.copyWith(
        items: _replaceMember(state.items, updated),
        clearFailure: true,
      );
    } on AppFailure catch (failure) {
      state = state.copyWith(failure: failure);
    } finally {
      state = state.copyWith(isWriting: false);
    }
  });

  Future<void> replacePermissions(
    int membershipId,
    Set<String> codes,
    int version,
  ) => _enqueueWrite(() async {
    state = state.copyWith(isWriting: true, clearFailure: true);
    try {
      final permissions = await _repository.replacePermissions(
        membershipId,
        codes,
        version,
      );
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
      state = state.copyWith(failure: failure);
    } finally {
      state = state.copyWith(isWriting: false);
    }
  });

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
