import 'dart:async';

import 'package:c_biz_docs_manager/core/error/app_failure.dart';
import 'package:c_biz_docs_manager/features/platform/application/create_group_controller.dart';
import 'package:c_biz_docs_manager/features/platform/data/platform_repository.dart';
import 'package:c_biz_docs_manager/features/platform/domain/platform_group.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_platform_repository.dart';
import '../../support/platform_fixtures.dart';

const _draft = CreateGroupDraft(
  name: '钢材一组',
  ownerUsername: 'owner',
  ownerDisplayName: '张三',
  ownerTemporaryPassword: 'secret123',
);

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

  test('提交成功后给出组 id 并复位提交中标记', () async {
    repository.createResult = domainCreateResult(groupId: 7);
    final container = newContainer();
    final controller = container.read(createGroupControllerProvider.notifier);

    final result = await controller.submit(_draft);

    expect(repository.createDrafts.single.name, '钢材一组');
    expect(result!.groupId, 7);
    final state = container.read(createGroupControllerProvider);
    // 页面就是盯着这个 id 去跳详情的。
    expect(state.createdGroupId, 7);
    expect(state.isSubmitting, isFalse);
    expect(state.failure, isNull);
  });

  test('提交失败时保留失败原因，且不产生组 id', () async {
    repository.createError = const ConflictFailure('组名已存在');
    final container = newContainer();
    final controller = container.read(createGroupControllerProvider.notifier);

    final result = await controller.submit(_draft);

    expect(result, isNull);
    final state = container.read(createGroupControllerProvider);
    expect(state.failure, isA<ConflictFailure>());
    expect(state.createdGroupId, isNull);
    // 失败后必须能再试一次，否则用户改完组名只能重启应用。
    expect(state.isSubmitting, isFalse);
  });

  test('提交在途时重复调用不会发出第二个请求', () async {
    final gate = Completer<CreateGroupResult>();
    repository.queuedCreateWrites.add(gate.future);
    final container = newContainer();
    final controller = container.read(createGroupControllerProvider.notifier);

    final first = controller.submit(_draft);
    // 第二次调用在第一个 await 之前就撞上了 isSubmitting，直接返回。
    final second = controller.submit(_draft);

    expect(await second, isNull);
    expect(repository.createDrafts, hasLength(1));

    gate.complete(domainCreateResult());
    expect((await first)!.groupId, 7);
    expect(repository.createDrafts, hasLength(1));
    expect(container.read(createGroupControllerProvider).isSubmitting, isFalse);
  });

  test('失败后再提交会重新发起请求，并清掉上一次的失败', () async {
    repository.createError = const ConflictFailure('用户名已存在');
    final container = newContainer();
    final controller = container.read(createGroupControllerProvider.notifier);
    await controller.submit(_draft);
    expect(
      container.read(createGroupControllerProvider).failure,
      isA<ConflictFailure>(),
    );

    repository
      ..createError = null
      ..createResult = domainCreateResult(groupId: 8);
    await controller.submit(_draft);

    final state = container.read(createGroupControllerProvider);
    expect(repository.createDrafts, hasLength(2));
    expect(state.failure, isNull);
    expect(state.createdGroupId, 8);
  });

  test('reset 清空提交结果与失败原因', () async {
    repository.createResult = domainCreateResult();
    final container = newContainer();
    final controller = container.read(createGroupControllerProvider.notifier);
    await controller.submit(_draft);
    expect(container.read(createGroupControllerProvider).createdGroupId, 7);

    // 导航去详情页之前清一次，否则从详情页返回本页时会被再弹走一次。
    controller.reset();

    final state = container.read(createGroupControllerProvider);
    expect(state.createdGroupId, isNull);
    expect(state.failure, isNull);
    expect(state.isSubmitting, isFalse);
  });

  test('作用域销毁后在途的提交不再写回状态', () async {
    final gate = Completer<CreateGroupResult>();
    repository.queuedCreateWrites.add(gate.future);
    final container = ProviderContainer(
      overrides: [platformRepositoryProvider.overrideWithValue(repository)],
    );
    final controller = container.read(createGroupControllerProvider.notifier);

    final pending = controller.submit(_draft);
    await Future<void>.delayed(Duration.zero);
    container.dispose();

    gate.complete(domainCreateResult());
    // 销毁后写 state 会抛错，这里能正常 await 完就说明控制器已经让结果作废了。
    await pending;
  });
}
