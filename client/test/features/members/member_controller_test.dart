import 'dart:async';

import 'package:c_biz_docs_manager/core/error/app_failure.dart';
import 'package:c_biz_docs_manager/features/members/application/member_controller.dart';
import 'package:c_biz_docs_manager/features/members/data/member_repository.dart';
import 'package:c_biz_docs_manager/features/members/domain/member.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

final class FakeMemberRepository implements MemberRepository {
  List<Member> members = const <Member>[];
  List<Future<List<Member>>> listResults = <Future<List<Member>>>[];
  List<Completer<Member>> statusWrites = <Completer<Member>>[];
  int statusWriteCalls = 0;
  Object? writeError;

  @override
  Future<Member> changeStatus(
    int membershipId,
    MemberStatus status,
    int version,
  ) async {
    statusWriteCalls++;
    if (statusWrites.isNotEmpty) {
      return statusWrites.removeAt(0).future;
    }
    final error = writeError;
    if (error != null) throw error;
    return members.single;
  }

  @override
  Future<MemberPermissions> getPermissions(int membershipId) async =>
      MemberPermissions(
        membershipId: membershipId,
        permissionCodes: const <String>{},
        version: 1,
      );

  @override
  Future<List<Member>> listMembers() async {
    if (listResults.isNotEmpty) return listResults.removeAt(0);
    return members;
  }

  @override
  Future<MemberPermissions> replacePermissions(
    int membershipId,
    Set<String> codes,
    int version,
  ) async => MemberPermissions(
    membershipId: membershipId,
    permissionCodes: codes,
    version: version + 1,
  );
}

void main() {
  test('controller exposes loaded members and write conflicts', () async {
    final repository = FakeMemberRepository()
      ..members = const <Member>[cachedMemberForController];
    final container = ProviderContainer(
      overrides: [memberRepositoryProvider.overrideWithValue(repository)],
    );
    addTearDown(container.dispose);
    final controller = container.read(memberControllerProvider.notifier);

    await controller.load();
    expect(container.read(memberControllerProvider).items, hasLength(1));

    repository.writeError = const ConflictFailure('stale');
    await controller.changeStatus(7, MemberStatus.disabled, 1);
    expect(
      container.read(memberControllerProvider).failure,
      isA<ConflictFailure>(),
    );
  });

  test(
    'newer member load cannot be overwritten by an older response',
    () async {
      final first = Completer<List<Member>>();
      final second = Completer<List<Member>>();
      final repository = FakeMemberRepository()
        ..listResults = <Future<List<Member>>>[first.future, second.future];
      final container = ProviderContainer(
        overrides: [memberRepositoryProvider.overrideWithValue(repository)],
      );
      addTearDown(container.dispose);
      final controller = container.read(memberControllerProvider.notifier);

      final olderLoad = controller.load();
      final newerLoad = controller.load();
      second.complete(const <Member>[newerMemberForController]);
      await newerLoad;
      first.complete(const <Member>[cachedMemberForController]);
      await olderLoad;

      expect(container.read(memberControllerProvider).items, const <Member>[
        newerMemberForController,
      ]);
    },
  );

  test(
    'member writes are serialized and keep writing state accurate',
    () async {
      final first = Completer<Member>();
      final second = Completer<Member>();
      final repository = FakeMemberRepository()
        ..members = const <Member>[cachedMemberForController]
        ..statusWrites = <Completer<Member>>[first, second];
      final container = ProviderContainer(
        overrides: [memberRepositoryProvider.overrideWithValue(repository)],
      );
      addTearDown(container.dispose);
      final controller = container.read(memberControllerProvider.notifier);
      await controller.load();

      final firstWrite = controller.changeStatus(7, MemberStatus.disabled, 1);
      final secondWrite = controller.changeStatus(7, MemberStatus.active, 2);
      await Future<void>.delayed(Duration.zero);
      expect(repository.statusWriteCalls, 1);
      first.complete(disabledMemberForController);
      await firstWrite;
      await Future<void>.delayed(Duration.zero);
      expect(repository.statusWriteCalls, 2);
      expect(container.read(memberControllerProvider).isWriting, isTrue);
      second.complete(newerMemberForController);
      await secondWrite;

      final state = container.read(memberControllerProvider);
      expect(state.isWriting, isFalse);
      expect(state.items, const <Member>[newerMemberForController]);
    },
  );
}

const cachedMemberForController = Member(
  membershipId: 7,
  username: 'alice',
  displayName: 'Alice',
  memberType: 'member',
  status: MemberStatus.active,
  permissionCodes: <String>{},
  version: 1,
);

const disabledMemberForController = Member(
  membershipId: 7,
  username: 'alice',
  displayName: 'Alice',
  memberType: 'member',
  status: MemberStatus.disabled,
  permissionCodes: <String>{},
  version: 2,
);

const newerMemberForController = Member(
  membershipId: 7,
  username: 'alice',
  displayName: 'Alice',
  memberType: 'member',
  status: MemberStatus.active,
  permissionCodes: <String>{},
  version: 3,
);
