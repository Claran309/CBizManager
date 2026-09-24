import 'dart:async';

import 'package:c_biz_docs_manager/core/error/app_failure.dart';
import 'package:c_biz_docs_manager/features/platform/application/platform_group_detail_controller.dart';
import 'package:c_biz_docs_manager/features/platform/data/platform_repository.dart';
import 'package:c_biz_docs_manager/features/platform/domain/platform_group.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_platform_repository.dart';
import '../../support/platform_fixtures.dart';

void main() {
  late FakePlatformRepository repository;

  setUp(() => repository = FakePlatformRepository());

  ProviderContainer newContainer() {
    final container = ProviderContainer(
      overrides: [platformRepositoryProvider.overrideWithValue(repository)],
    );
    addTearDown(container.dispose);
    return container;
  }

  test('加载详情后状态就位', () async {
    repository.detailResult = domainDetail();
    final container = newContainer();
    final controller = container.read(
      platformGroupDetailControllerProvider(7).notifier,
    );

    await controller.load();

    expect(repository.detailRequests, <int>[7]);
    final state = container.read(platformGroupDetailControllerProvider(7));
    expect(state.detail!.group.name, '钢材一组');
    expect(state.detail!.memberCounts, domainMemberCounts());
    expect(state.detail!.ownerCandidates, hasLength(1));
    expect(state.isLoading, isFalse);
    expect(state.failure, isNull);
  });

  test('不同组的详情状态互不干扰', () async {
    repository.queuedDetails.addAll(<Future<PlatformGroupDetail>>[
      Future<PlatformGroupDetail>.value(
        domainDetail(group: domainGroup(id: 7, name: '钢材一组')),
      ),
      Future<PlatformGroupDetail>.value(
        domainDetail(group: domainGroup(id: 8, name: '钢材二组')),
      ),
    ]);
    final container = newContainer();

    // 每个 groupId 各有一份状态：从 A 组退出来进 B 组时，界面绝不会先闪一下
    // A 组的主账号与成员数。
    await container
        .read(platformGroupDetailControllerProvider(7).notifier)
        .load();
    await container
        .read(platformGroupDetailControllerProvider(8).notifier)
        .load();

    expect(repository.detailRequests, <int>[7, 8]);
    expect(
      container
          .read(platformGroupDetailControllerProvider(7))
          .detail!
          .group
          .name,
      '钢材一组',
    );
    expect(
      container
          .read(platformGroupDetailControllerProvider(8))
          .detail!
          .group
          .name,
      '钢材二组',
    );
  });

  test('启停成功后只替换摘要，成员构成保持不动', () async {
    repository
      ..detailResult = domainDetail(group: domainGroup(version: 3))
      ..statusResult = domainGroup(status: GroupStatus.disabled, version: 4);
    final container = newContainer();
    final controller = container.read(
      platformGroupDetailControllerProvider(7).notifier,
    );
    await controller.load();

    await controller.changeStatus(GroupStatus.disabled);

    final detail = container
        .read(platformGroupDetailControllerProvider(7))
        .detail!;
    expect(detail.group.status, GroupStatus.disabled);
    expect(detail.group.version, 4);
    // 启停不改变成员构成：计数与候选人还是原来那一份，不该被清成空。
    expect(detail.memberCounts, domainMemberCounts());
    expect(detail.ownerCandidates, hasLength(1));
  });

  test('交接成功后详情换成服务端返回的那一份', () async {
    repository
      ..detailResult = domainDetail()
      ..ownerResult = domainDetail(
        group: domainGroup(
          version: 4,
          owner: domainOwner(id: 22, username: 'sales', displayName: '李四'),
        ),
        // 交接完成后，被提升的人自然要从候选人里消失。
        ownerCandidates: const <OwnerCandidate>[],
      );
    final container = newContainer();
    final controller = container.read(
      platformGroupDetailControllerProvider(7).notifier,
    );
    await controller.load();

    await controller.changeOwner(
      const ExistingMemberOwnerDraft(membershipId: 9, version: 3),
    );

    expect(repository.ownerDrafts.single, isA<ExistingMemberOwnerDraft>());
    final detail = container
        .read(platformGroupDetailControllerProvider(7))
        .detail!;
    expect(detail.group.owner.displayName, '李四');
    expect(detail.group.version, 4);
    expect(detail.ownerCandidates, isEmpty);
  });

  test('版本冲突时保留失败原因，并自动重读最新详情', () async {
    repository
      ..detailResult = domainDetail(group: domainGroup(version: 3))
      ..statusError = const ConflictFailure('组已被其他请求修改');
    final container = newContainer();
    final controller = container.read(
      platformGroupDetailControllerProvider(7).notifier,
    );
    await controller.load();

    // 冲突的根因是别人把组改到了 version 5，重读应当看到这个新版本。
    repository.detailResult = domainDetail(
      group: domainGroup(status: GroupStatus.disabled, version: 5),
    );
    await controller.changeStatus(GroupStatus.disabled);

    final state = container.read(platformGroupDetailControllerProvider(7));
    expect(repository.detailRequests, <int>[7, 7]);
    expect(state.detail!.group.version, 5);
    // 刷新不等于成功：失败原因必须留着，否则用户会以为操作生效了。
    expect(state.failure, isA<ConflictFailure>());
    expect(state.isWriting, isFalse);
  });

  test('冲突后重读又失败时，保留更紧迫的那个失败', () async {
    repository
      ..detailResult = domainDetail()
      ..statusError = const ConflictFailure('组已被其他请求修改');
    final container = newContainer();
    final controller = container.read(
      platformGroupDetailControllerProvider(7).notifier,
    );
    await controller.load();

    repository
      ..detailResult = null
      ..detailError = const NetworkFailure('网络不可用，请稍后重试');
    await controller.changeStatus(GroupStatus.disabled);

    // 此刻用户最需要知道的是「网断了」，而不是那条已经被刷新尝试掩盖的版本冲突。
    expect(
      container.read(platformGroupDetailControllerProvider(7)).failure,
      isA<NetworkFailure>(),
    );
  });

  test('详情还没到手就触发启停时静默返回，不发请求', () async {
    final container = newContainer();
    final controller = container.read(
      platformGroupDetailControllerProvider(7).notifier,
    );

    await controller.changeStatus(GroupStatus.disabled);

    // 界面在详情到手前不会渲染出操作按钮；真发生了说明有竞态，
    // 静默不做事比拿着不知哪来的 version 发请求安全。
    expect(repository.changeStatusCalls, 0);
  });

  test('作用域销毁后在途的加载不再写回状态', () async {
    final gate = Completer<PlatformGroupDetail>();
    repository.queuedDetails.add(gate.future);
    final container = ProviderContainer(
      overrides: [platformRepositoryProvider.overrideWithValue(repository)],
    );
    final controller = container.read(
      platformGroupDetailControllerProvider(7).notifier,
    );

    final pending = controller.load();
    await Future<void>.delayed(Duration.zero);
    container.dispose();

    gate.complete(domainDetail());
    await pending;
  });
}
