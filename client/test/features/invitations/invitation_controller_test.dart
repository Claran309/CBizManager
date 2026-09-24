import 'dart:async';

import 'package:c_biz_docs_manager/core/error/app_failure.dart';
import 'package:c_biz_docs_manager/core/network/page_result.dart';
import 'package:c_biz_docs_manager/features/invitations/application/invitation_controller.dart';
import 'package:c_biz_docs_manager/features/invitations/data/invitation_repository.dart';
import 'package:c_biz_docs_manager/features/invitations/domain/invitation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
// `Override` 在 Riverpod 3 里由 misc.dart 导出，主入口只给常用的那一组。
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_invitation_repository.dart';
import '../../support/invitation_fixtures.dart';

void main() {
  late FakeInvitationRepository repository;

  setUp(() => repository = FakeInvitationRepository());

  ProviderContainer newContainer() {
    final container = ProviderContainer(
      overrides: <Override>[
        invitationRepositoryProvider.overrideWithValue(repository),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  /* -------------------------------------------------------------- 列表加载 */

  test('load 把筛选条件传下去并把结果放进状态', () async {
    repository.listResult = domainInvitationPage();
    final container = newContainer();

    await container
        .read(invitationControllerProvider.notifier)
        .load(status: InvitationStatus.active);

    expect(repository.listCalls.single.status, InvitationStatus.active);
    final state = container.read(invitationControllerProvider);
    expect(state.items.single.id, 9);
    expect(state.isLoading, isFalse);
    expect(state.failure, isNull);
    expect(state.visibleSecret, isNull);
  });

  test('refresh 复用上一次的筛选条件', () async {
    repository.listResult = domainInvitationPage();
    final container = newContainer();
    final controller = container.read(invitationControllerProvider.notifier);

    await controller.load(status: InvitationStatus.used);
    await controller.refresh();

    expect(repository.listCalls, hasLength(2));
    expect(repository.listCalls.last.status, InvitationStatus.used);
  });

  test('先发的那次 load 晚回来时，不能覆盖后发那次的结果', () async {
    final older = Completer<PageResult<InvitationSummary>>();
    final newer = Completer<PageResult<InvitationSummary>>();
    repository.queuedLists.addAll(<Future<PageResult<InvitationSummary>>>[
      older.future,
      newer.future,
    ]);
    final container = newContainer();
    final controller = container.read(invitationControllerProvider.notifier);

    final olderLoad = controller.load(status: InvitationStatus.active);
    final newerLoad = controller.load(status: InvitationStatus.used);

    newer.complete(
      domainInvitationPage(
        items: <InvitationSummary>[
          domainInvitation(id: 10, status: InvitationStatus.used),
        ],
      ),
    );
    await newerLoad;
    older.complete(
      domainInvitationPage(
        items: <InvitationSummary>[
          domainInvitation(id: 9, status: InvitationStatus.active),
        ],
      ),
    );
    await olderLoad;

    final state = container.read(invitationControllerProvider);
    expect(state.items.single.id, 10);
    expect(state.isLoading, isFalse);
  });

  test('加载失败时保留失败原因且不影响已有列表', () async {
    repository.listResult = domainInvitationPage();
    final container = newContainer();
    final controller = container.read(invitationControllerProvider.notifier);
    await controller.load();

    repository
      ..listResult = null
      ..listError = const NetworkFailure('offline');
    await controller.refresh();

    final state = container.read(invitationControllerProvider);
    expect(state.failure, isA<NetworkFailure>());
    expect(state.items, hasLength(1));
  });

  /* -------------------------------------------------------- 明文的生命周期 */

  test('查看明文后状态里就有它了', () async {
    repository
      ..listResult = domainInvitationPage()
      ..revealResult = domainSecret(code: 'CODE-A');
    final container = newContainer();
    final controller = container.read(invitationControllerProvider.notifier);
    await controller.load();

    await controller.reveal(9);

    expect(repository.revealRequests, <int>[9]);
    final state = container.read(invitationControllerProvider);
    expect(state.visibleSecret?.code, 'CODE-A');
    expect(state.hasSecret, isTrue);
    expect(state.isWriting, isFalse);
  });

  test('查看另一条之前先清掉当前明文', () async {
    final gate = Completer<InvitationSecret>();
    repository
      ..listResult = domainInvitationPage()
      ..revealResult = domainSecret(invitationId: 9, code: 'CODE-A');
    final container = newContainer();
    final controller = container.read(invitationControllerProvider.notifier);
    await controller.load();
    await controller.reveal(9);
    expect(
      container.read(invitationControllerProvider).visibleSecret?.code,
      'CODE-A',
    );

    // 第二次查看：把响应卡在在途，此时屏幕上绝不能还留着 A 的明文 ——
    // 否则用户会以为看到的就是 B 的码，然后把它发给别人。
    repository.queuedReveals.add(gate.future);
    final pending = controller.reveal(10);
    await Future<void>.delayed(Duration.zero);
    expect(container.read(invitationControllerProvider).visibleSecret, isNull);

    gate.complete(domainSecret(invitationId: 10, code: 'CODE-B'));
    await pending;
    expect(
      container.read(invitationControllerProvider).visibleSecret?.code,
      'CODE-B',
    );
  });

  test('查看失败时不会留下上一条明文', () async {
    repository
      ..listResult = domainInvitationPage()
      ..revealResult = domainSecret(code: 'CODE-A');
    final container = newContainer();
    final controller = container.read(invitationControllerProvider.notifier);
    await controller.load();
    await controller.reveal(9);

    repository
      ..revealResult = null
      ..revealError = const ConflictFailure('邀请码不可查看');
    await controller.reveal(10);

    final state = container.read(invitationControllerProvider);
    expect(state.visibleSecret, isNull);
    expect(state.failure, isA<ConflictFailure>());
    expect(state.isWriting, isFalse);
  });

  test('列表刷新后，已经不再 active 的邀请码明文被清掉', () async {
    repository
      ..listResult = domainInvitationPage()
      ..revealResult = domainSecret(invitationId: 9);
    final container = newContainer();
    final controller = container.read(invitationControllerProvider.notifier);
    await controller.load();
    await controller.reveal(9);

    // 服务端现在把这一条投影成 used（可能刚被人用掉）。
    repository.listResult = domainInvitationPage(
      items: <InvitationSummary>[
        domainInvitation(id: 9, status: InvitationStatus.used),
      ],
    );
    await controller.refresh();

    // 判据完全交给服务端下发的 status，客户端不去拿 expiresAt 和本地时钟比 ——
    // 那会引入第二个真相，还会被时钟偏差坑。
    expect(container.read(invitationControllerProvider).visibleSecret, isNull);
  });

  test('列表里找不到的邀请码，其明文也会被清掉', () async {
    repository
      ..listResult = domainInvitationPage()
      ..revealResult = domainSecret(invitationId: 9);
    final container = newContainer();
    final controller = container.read(invitationControllerProvider.notifier);
    await controller.load();
    await controller.reveal(9);

    // 可能被翻页挡住了，也可能真被别处撤销了 —— 无法确认就不继续展示。
    repository.listResult = domainInvitationPage(
      items: <InvitationSummary>[domainInvitation(id: 99)],
    );
    await controller.refresh();

    expect(container.read(invitationControllerProvider).visibleSecret, isNull);
  });

  test('仍然 active 的邀请码，刷新后明文保留', () async {
    repository
      ..listResult = domainInvitationPage()
      ..revealResult = domainSecret(invitationId: 9, code: 'CODE-A');
    final container = newContainer();
    final controller = container.read(invitationControllerProvider.notifier);
    await controller.load();
    await controller.reveal(9);

    await controller.refresh();

    // 反面用例：不能为了"安全"把刷新变成无条件清除 —— 那样用户刚拿到的码
    // 会被一次自动刷新抹掉，只能反复重点「查看」。
    expect(
      container.read(invitationControllerProvider).visibleSecret?.code,
      'CODE-A',
    );
  });

  test('clearSecret 手动收起明文', () async {
    repository
      ..listResult = domainInvitationPage()
      ..revealResult = domainSecret();
    final container = newContainer();
    final controller = container.read(invitationControllerProvider.notifier);
    await controller.load();
    await controller.reveal(9);

    controller.clearSecret();

    expect(container.read(invitationControllerProvider).visibleSecret, isNull);
    // 再调一次不能出错：界面可能在多个收尾路径上都调它。
    controller.clearSecret();
  });

  /* -------------------------------------------------------------- 创建 */

  test('创建成功后明文立刻可见，刷新列表后仍然保留', () async {
    repository
      ..createResult = domainSecret(invitationId: 42, code: 'NEW-CODE')
      ..listResult = domainInvitationPage(
        items: <InvitationSummary>[domainInvitation(id: 42)],
      );
    final container = newContainer();

    await container
        .read(invitationControllerProvider.notifier)
        .create(expiresInDays: 3);

    expect(repository.createRequests, <int?>[3]);
    final state = container.read(invitationControllerProvider);
    // 创建响应是唯一一次能拿到明文的机会，必须直接摆出来。
    expect(state.visibleSecret?.code, 'NEW-CODE');
    // 列表也刷新过了：新邀请码出现在第一行。
    expect(state.items.single.id, 42);
    expect(state.isWriting, isFalse);
  });

  test('创建成功但列表刷新失败时，明文仍然保留', () async {
    repository
      ..createResult = domainSecret(invitationId: 42, code: 'NEW-CODE')
      ..listError = const NetworkFailure('offline');
    final container = newContainer();

    await container.read(invitationControllerProvider.notifier).create();

    final state = container.read(invitationControllerProvider);
    // 用户正需要复制这串码；因为"列表没刷出来"就把它藏起来毫无道理。
    expect(state.visibleSecret?.code, 'NEW-CODE');
    expect(state.failure, isA<NetworkFailure>());
  });

  /* -------------------------------------------------------------- 撤销 */

  test('撤销正在展示的邀请码时明文立刻消失', () async {
    repository
      ..listResult = domainInvitationPage()
      ..revealResult = domainSecret(invitationId: 9)
      ..revokeResult = domainInvitation(
        status: InvitationStatus.revoked,
        version: 2,
      );
    final container = newContainer();
    final controller = container.read(invitationControllerProvider.notifier);
    await controller.load();
    await controller.reveal(9);

    await controller.revoke(domainInvitation(version: 1));

    expect(repository.revokeRequests.single.version, 1);
    final state = container.read(invitationControllerProvider);
    // 它已经不再是有效凭证，继续留在屏幕上只会被人复制走。
    expect(state.visibleSecret, isNull);
    expect(state.items.single.status, InvitationStatus.revoked);
    expect(state.items.single.version, 2);
  });

  test('撤销别的邀请码时不动当前明文', () async {
    repository
      ..listResult = domainInvitationPage(
        items: <InvitationSummary>[
          domainInvitation(id: 9),
          domainInvitation(id: 10),
        ],
      )
      ..revealResult = domainSecret(invitationId: 9, code: 'CODE-A')
      ..revokeResult = domainInvitation(
        id: 10,
        status: InvitationStatus.revoked,
        version: 2,
      );
    final container = newContainer();
    final controller = container.read(invitationControllerProvider.notifier);
    await controller.load();
    await controller.reveal(9);

    await controller.revoke(domainInvitation(id: 10, version: 1));

    // 撤 A 不该让人正在看的 B 里消失。
    expect(
      container.read(invitationControllerProvider).visibleSecret?.invitationId,
      9,
    );
  });

  test('撤销遇到版本冲突时清掉对应明文并保留失败', () async {
    repository
      ..listResult = domainInvitationPage()
      ..revealResult = domainSecret(invitationId: 9)
      ..revokeError = const ConflictFailure('邀请码已被其他请求修改');
    final container = newContainer();
    final controller = container.read(invitationControllerProvider.notifier);
    await controller.load();
    await controller.reveal(9);

    await controller.revoke(domainInvitation());

    final state = container.read(invitationControllerProvider);
    // 冲突说明这个码的状态已经不掌握在我们手里，无法确认它还有效 ——
    // 所以比一般失败多做一步：把明文清掉。
    expect(state.visibleSecret, isNull);
    expect(state.failure, isA<ConflictFailure>());
    // 列表保留：用户点的那一行还在眼前，配上「刷新后重试」的提示才有意义。
    expect(state.items, hasLength(1));
    expect(state.isWriting, isFalse);
  });

  test('撤销遇到断网这类失败时保留明文', () async {
    repository
      ..listResult = domainInvitationPage()
      ..revealResult = domainSecret(invitationId: 9, code: 'CODE-A')
      ..revokeError = const NetworkFailure('offline');
    final container = newContainer();
    final controller = container.read(invitationControllerProvider.notifier);
    await controller.load();
    await controller.reveal(9);

    await controller.revoke(domainInvitation());

    // 断网不改变本地对状态的判断：这个码多半仍然有效，用户马上还要复制。
    expect(
      container.read(invitationControllerProvider).visibleSecret?.code,
      'CODE-A',
    );
  });

  /* ------------------------------------------------------------ 串行与销毁 */

  test('写操作串行执行，写状态全程准确', () async {
    final revealGate = Completer<InvitationSecret>();
    final revokeGate = Completer<InvitationSummary>();
    repository
      ..listResult = domainInvitationPage()
      ..queuedReveals.add(revealGate.future)
      ..queuedRevokes.add(revokeGate.future);
    final container = newContainer();
    final controller = container.read(invitationControllerProvider.notifier);
    await controller.load();

    final reveal = controller.reveal(9);
    final revoke = controller.revoke(domainInvitation());
    await Future<void>.delayed(Duration.zero);

    // 查看还在途，撤销必须还在排队 —— 并发发出去会让两次操作各自拿着一份
    // version，必然有一个撞 409。
    expect(repository.revealRequests, hasLength(1));
    expect(repository.revokeRequests, isEmpty);
    expect(container.read(invitationControllerProvider).isWriting, isTrue);

    revealGate.complete(domainSecret());
    await reveal;
    await Future<void>.delayed(Duration.zero);
    expect(repository.revokeRequests, hasLength(1));

    revokeGate.complete(
      domainInvitation(status: InvitationStatus.revoked, version: 2),
    );
    await revoke;

    expect(container.read(invitationControllerProvider).isWriting, isFalse);
  });

  test('作用域销毁时在途的查看不会把明文写回状态', () async {
    final gate = Completer<InvitationSecret>();
    repository
      ..listResult = domainInvitationPage()
      ..queuedReveals.add(gate.future);
    final container = ProviderContainer(
      overrides: <Override>[
        invitationRepositoryProvider.overrideWithValue(repository),
      ],
    );
    final controller = container.read(invitationControllerProvider.notifier);
    await controller.load();

    final pending = controller.reveal(9);
    await Future<void>.delayed(Duration.zero);

    // 相当于登出 / 切账号：整个会话作用域被卸载。
    container.dispose();

    gate.complete(domainSecret(code: 'CODE-A'));
    // 控制器若没有在 dispose 时让在途结果作废，这里会因为向已销毁的 Notifier
    // 写 state 而抛错 —— 那等于把明文写进了一个已经不属于当前会话的状态里。
    await pending;
  });

  test('销毁后新建作用域，不会看到上一份明文', () async {
    repository
      ..listResult = domainInvitationPage()
      ..revealResult = domainSecret(code: 'CODE-A');
    final first = ProviderContainer(
      overrides: <Override>[
        invitationRepositoryProvider.overrideWithValue(repository),
      ],
    );
    await first.read(invitationControllerProvider.notifier).load();
    await first.read(invitationControllerProvider.notifier).reveal(9);
    expect(first.read(invitationControllerProvider).visibleSecret, isNotNull);

    first.dispose();

    final second = newContainer();
    final state = second.read(invitationControllerProvider);
    // 明文的唯一持有处就是 state，作用域销毁后它随 Notifier 一起不可达。
    expect(state.visibleSecret, isNull);
    expect(state.items, isEmpty);
  });
}
