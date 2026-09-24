import 'dart:async';

import 'package:c_biz_docs_manager/core/error/app_failure.dart';
import 'package:c_biz_docs_manager/core/network/page_result.dart';
import 'package:c_biz_docs_manager/features/platform/application/platform_group_controller.dart';
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

  test('加载把筛选条件传下去并把结果放进状态', () async {
    repository.listResult = domainGroupPage();
    final container = newContainer();
    final controller = container.read(platformGroupControllerProvider.notifier);

    await controller.load(const PlatformGroupQuery(keyword: '钢材', page: 2));

    expect(repository.listQueries, <PlatformGroupQuery>[
      const PlatformGroupQuery(keyword: '钢材', page: 2),
    ]);
    final state = container.read(platformGroupControllerProvider);
    expect(state.items.single.name, '钢材一组');
    expect(state.query, const PlatformGroupQuery(keyword: '钢材', page: 2));
    expect(state.isLoading, isFalse);
    expect(state.failure, isNull);
  });

  test('先发的那次加载晚回来时，不能覆盖后发那次的结果', () async {
    final older = Completer<PageResult<PlatformGroup>>();
    final newer = Completer<PageResult<PlatformGroup>>();
    repository.queuedLists.addAll(<Future<PageResult<PlatformGroup>>>[
      older.future,
      newer.future,
    ]);
    final container = newContainer();
    final controller = container.read(platformGroupControllerProvider.notifier);

    final olderLoad = controller.load(const PlatformGroupQuery(page: 1));
    final newerLoad = controller.load(const PlatformGroupQuery(page: 2));

    // 第二次先回来。
    newer.complete(
      domainGroupPage(
        items: <PlatformGroup>[domainGroup(id: 8, name: '钢材二组')],
        page: 2,
      ),
    );
    await newerLoad;
    // 第一次姗姗来迟 —— 它已经过期了，不允许把界面改回第 1 页的内容。
    older.complete(
      domainGroupPage(items: <PlatformGroup>[domainGroup(id: 7, name: '钢材一组')]),
    );
    await olderLoad;

    final state = container.read(platformGroupControllerProvider);
    expect(state.items.single.name, '钢材二组');
    expect(state.isLoading, isFalse);
  });

  test('refresh 复用上一次的筛选条件', () async {
    repository.listResult = domainGroupPage();
    final container = newContainer();
    final controller = container.read(platformGroupControllerProvider.notifier);

    await controller.load(
      const PlatformGroupQuery(
        keyword: '钢材',
        status: GroupStatus.disabled,
        page: 3,
      ),
    );
    await controller.refresh();

    expect(repository.listQueries, hasLength(2));
    expect(
      repository.listQueries.last,
      const PlatformGroupQuery(
        keyword: '钢材',
        status: GroupStatus.disabled,
        page: 3,
      ),
    );
    expect(container.read(platformGroupControllerProvider).isLoading, isFalse);
  });

  test('启停写操作串行执行，写状态全程准确', () async {
    final first = Completer<PlatformGroup>();
    final second = Completer<PlatformGroup>();
    repository
      ..listResult = domainGroupPage()
      ..queuedStatusWrites.addAll(<Future<PlatformGroup>>[
        first.future,
        second.future,
      ]);
    final container = newContainer();
    final controller = container.read(platformGroupControllerProvider.notifier);
    await controller.load(const PlatformGroupQuery());

    final firstWrite = controller.changeStatus(
      domainGroup(),
      GroupStatus.disabled,
    );
    final secondWrite = controller.changeStatus(
      domainGroup(),
      GroupStatus.active,
    );
    await Future<void>.delayed(Duration.zero);
    // 第一个还在途，第二个必须还在排队 —— 并发发出去会让两次操作各自
    // 拿着一份 version，必然有一个撞 409。
    expect(repository.changeStatusCalls, 1);
    expect(container.read(platformGroupControllerProvider).isWriting, isTrue);

    first.complete(domainGroup(status: GroupStatus.disabled, version: 4));
    await firstWrite;
    await Future<void>.delayed(Duration.zero);
    expect(repository.changeStatusCalls, 2);

    second.complete(domainGroup(version: 5));
    await secondWrite;

    final state = container.read(platformGroupControllerProvider);
    expect(state.isWriting, isFalse);
    expect(state.items.single.version, 5);
  });

  test('启停成功后列表项换成服务端回的新版本', () async {
    repository
      ..listResult = domainGroupPage(
        items: <PlatformGroup>[domainGroup(version: 3)],
      )
      ..statusResult = domainGroup(status: GroupStatus.disabled, version: 4);
    final container = newContainer();
    final controller = container.read(platformGroupControllerProvider.notifier);
    await controller.load(const PlatformGroupQuery());

    await controller.changeStatus(
      domainGroup(version: 3),
      GroupStatus.disabled,
    );

    final item = container.read(platformGroupControllerProvider).items.single;
    expect(item.status, GroupStatus.disabled);
    // 关键：version 跟着涨，用户紧接着再操作这一行时用的才是新凭据，
    // 否则每次点都会白撞一次 409。
    expect(item.version, 4);
  });

  test('启停遇到版本冲突时保留失败，且不清空已有列表', () async {
    repository
      ..listResult = domainGroupPage()
      ..statusError = const ConflictFailure('组已被其他请求修改');
    final container = newContainer();
    final controller = container.read(platformGroupControllerProvider.notifier);
    await controller.load(const PlatformGroupQuery());

    await controller.changeStatus(domainGroup(), GroupStatus.disabled);

    final state = container.read(platformGroupControllerProvider);
    expect(state.failure, isA<ConflictFailure>());
    // 列表保留：用户点的那一行还在眼前，配上「刷新后重试」的提示才有意义。
    expect(state.items, hasLength(1));
    expect(state.isWriting, isFalse);
  });

  test('作用域销毁后在途的加载不再写回状态', () async {
    final gate = Completer<PageResult<PlatformGroup>>();
    repository.queuedLists.add(gate.future);
    final container = ProviderContainer(
      overrides: [platformRepositoryProvider.overrideWithValue(repository)],
    );
    final controller = container.read(platformGroupControllerProvider.notifier);

    final pending = controller.load(const PlatformGroupQuery());
    await Future<void>.delayed(Duration.zero);
    expect(container.read(platformGroupControllerProvider).isLoading, isTrue);

    // 相当于切账号：整个会话作用域被卸载。
    container.dispose();

    gate.complete(domainGroupPage());
    // 控制器若没有在 dispose 时让在途请求作废，这里会因为向已销毁的
    // Notifier 写 state 而抛错。
    await pending;
  });
}
