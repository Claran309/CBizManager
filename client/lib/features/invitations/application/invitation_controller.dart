import 'package:c_biz_docs_manager/core/error/app_failure.dart';
import 'package:c_biz_docs_manager/features/invitations/data/invitation_repository.dart';
import 'package:c_biz_docs_manager/features/invitations/domain/invitation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 邀请码列表与「临时可见的明文」的状态持有者。
///
/// [dependencies] 这一行是必须的：Riverpod 3 的传递式作用域只会把「显式声明了
/// 依赖」的 Provider 挂到覆盖了该依赖的那个容器里。这里依赖
/// [invitationRepositoryProvider]（只由组主账号的会话作用域覆盖），声明之后
/// 本 Controller 就跟着作用域一起生灭 —— 登出即销毁，上一个人的邀请码列表
/// 与明文都不会留在根容器里被下一个会话读到。
final invitationControllerProvider =
    NotifierProvider<InvitationController, InvitationState>(
      InvitationController.new,
      dependencies: [invitationRepositoryProvider],
    );

final class InvitationState {
  const InvitationState({
    this.items = const <InvitationSummary>[],
    this.visibleSecret,
    this.isLoading = false,
    this.isWriting = false,
    this.failure,
  });

  /// 当前这一页的邀请码。
  final List<InvitationSummary> items;

  /// 当前**唯一**可见的邀请码明文。
  ///
  /// 它是全项目唯一承载明文秘密的状态，因此规则是「一次只留一份、任何可能让
  /// 它失效的事件发生就立刻清空」：查看另一个时清、撤销后清、刷新后列表里
  /// 不再有效时清、作用域销毁时随之不可达。详见 [InvitationController]。
  final InvitationSecret? visibleSecret;

  final bool isLoading;

  /// 是否有写操作在途（创建 / 查看 / 撤销）。界面据此禁用按钮。
  final bool isWriting;

  final AppFailure? failure;

  /// 界面上是否正展示着某份明文。
  bool get hasSecret => visibleSecret != null;

  InvitationState copyWith({
    List<InvitationSummary>? items,
    InvitationSecret? visibleSecret,
    bool? isLoading,
    bool? isWriting,
    AppFailure? failure,
    bool clearSecret = false,
    bool clearFailure = false,
  }) {
    return InvitationState(
      items: items ?? this.items,
      // 秘密要做「清除」和「保留」两件事，用一个 bool 明确区分：
      // 传 null 同时也是「不改」的意思，表达不了清除。
      visibleSecret: clearSecret ? null : visibleSecret ?? this.visibleSecret,
      isLoading: isLoading ?? this.isLoading,
      isWriting: isWriting ?? this.isWriting,
      failure: clearFailure ? null : failure ?? this.failure,
    );
  }
}

/// 邀请码的加载、创建、查看明文与撤销。
///
/// **明文的生命周期是本类存在的全部理由**。邀请码明文只在服务端存哈希与密文，
/// 一旦泄漏就是一张长期有效的入组凭证，所以这里的每一条规则都围绕「让它尽量少
/// 存在、尽早消失」：
///
/// 1. 同一时刻只保留一份明文（`state.visibleSecret`），且它是唯一的持有处；
/// 2. 查看另一条之前**先清掉旧的**（网络还没回来时屏幕上不能留着上一条）；
/// 3. 撤销成功后立刻清掉对应明文；
/// 4. 每次列表刷新后，逐条核对「它还在不在、还是不是 active」，不在就清；
/// 5. 作用域销毁时随 Notifier / state 一起变得不可达（`ref.onDispose`）。
final class InvitationController extends Notifier<InvitationState> {
  /// 加载轮次。每次 [load] 自增，回来的结果必须还是最新一轮才允许写 state。
  var _loadGeneration = 0;

  /// 写操作队列的尾巴。创建 / 查看 / 撤销都要排队：并发点两个按钮时，
  /// 每个请求各自拿一份 version，交错执行必然有一个撞 409。
  Future<void> _writeTail = Future<void>.value();

  /// 会话作用域是否已销毁。销毁后写 state 会抛错，更糟的是会把上一个人的
  /// 数据画到新会话的界面上，所以每个写入点都要先看这个标记。
  var _disposed = false;

  /// 当前筛选条件。[load] 会记住它，供 [refresh] 复用。
  InvitationStatus? _status;

  InvitationRepository get _repository =>
      ref.read(invitationRepositoryProvider);

  bool _isCurrent(int generation) =>
      !_disposed && generation == _loadGeneration;

  @override
  InvitationState build() {
    ref.onDispose(() {
      _disposed = true;
      // 让在途的 load / reveal 结果立刻作废 —— 这一步对明文尤其关键：
      // 「查看」的响应若在作用域销毁后才回来，它会把明文写进一个已经不属于
      // 当前会话的状态里。
      _loadGeneration++;
      clearSecret();
    });
    return const InvitationState();
  }

  /// 按 [status] 加载一页；不传表示不筛状态。
  Future<void> load({InvitationStatus? status}) async {
    final generation = ++_loadGeneration;
    if (_disposed) return;
    // 立刻记住条件：即使这次请求还没回来，refresh 也应该按新条件刷。
    _status = status;
    state = state.copyWith(isLoading: true, clearFailure: true);
    try {
      final page = await _repository.list(status: status);
      if (!_isCurrent(generation)) return;
      state = state.copyWith(items: page.items, clearFailure: true);
      _dropSecretIfNoLongerOpen();
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

  /// 用当前筛选条件重新加载。
  Future<void> refresh() => load(status: _status);

  /// 创建邀请码，并把新明文摆出来供用户复制。
  Future<void> create({int? expiresInDays}) {
    final repository = _repository;
    return _enqueueWrite(() async {
      if (_disposed) return;
      state = state.copyWith(isWriting: true, clearFailure: true);
      try {
        final secret = await repository.create(expiresInDays: expiresInDays);
        if (_disposed) return;
        // 创建响应是**唯一**一次能拿到明文的机会，直接摆出来：让用户还要再去
        // 列表里找一遍、再点一次「查看」，除了多一次往返没有任何好处。
        state = state.copyWith(visibleSecret: secret, clearFailure: true);
        // 接着刷新列表，让新邀请码出现在第一行。注意明文不会被这次刷新清掉：
        // 它刚建出来，必然是 active 且在列表里。
        await load(status: _status);
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

  /// 查看某个邀请码的明文。
  Future<void> reveal(int invitationId) {
    final repository = _repository;
    return _enqueueWrite(() async {
      if (_disposed) return;
      // **先清旧明文再发请求**，这一步不能省：用户点了 B 的「查看」之后，
      // 屏幕上若还留着 A 的明文，在响应回来之前的那段时间里他会以为看到的就是
      // B 的码，然后把它发给别人。宁可出现一小段"什么都没有"的空白。
      state = state.copyWith(
        isWriting: true,
        clearFailure: true,
        clearSecret: true,
      );
      try {
        final secret = await repository.revealSecret(invitationId);
        if (_disposed) return;
        state = state.copyWith(visibleSecret: secret, clearFailure: true);
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

  /// 撤销邀请码。
  ///
  /// 把整个 [invitation] 传进来而不是只传 id：乐观锁需要它身上的 `version`，
  /// 而列表里每一行恰好就有最新的一份。
  Future<void> revoke(InvitationSummary invitation) {
    final repository = _repository;
    return _enqueueWrite(() async {
      if (_disposed) return;
      state = state.copyWith(isWriting: true, clearFailure: true);
      try {
        final updated = await repository.revoke(
          invitation.id,
          invitation.version,
        );
        if (_disposed) return;
        state = state.copyWith(
          items: _replaceInvitation(state.items, updated),
          // 撤销成功后，正在展示的明文若是这一个，必须立刻消失 ——
          // 它已经不再是有效凭证，继续留在屏幕上只会被人复制走。
          clearSecret: _secretBelongsTo(invitation.id),
          clearFailure: true,
        );
      } on ConflictFailure catch (failure) {
        if (_disposed) return;
        // 冲突说明这个邀请码的状态已经不掌握在我们手里了（可能刚被使用、
        // 刚被别处撤销，或者刚好过期）。**既然无法确认它还有效，就不该继续把
        // 明文留在屏幕上**，所以这里比一般失败多做一步清理。
        state = state.copyWith(
          failure: failure,
          clearSecret: _secretBelongsTo(invitation.id),
        );
      } on AppFailure catch (failure) {
        if (_disposed) return;
        // 其余失败（断网、服务端错误）不改变本地对状态的判断，
        // 明文该留就留着：它多半仍然有效，用户马上还要复制。
        state = state.copyWith(failure: failure);
      } finally {
        if (!_disposed) {
          state = state.copyWith(isWriting: false);
        }
      }
    });
  }

  /// 手动收起明文（用户点「收起」或离开页面时调用）。
  ///
  /// 这是唯一一处会让明文消失的地方：`state.visibleSecret` 是它唯一的持有者，
  /// 所以清空 state 就是彻底清除。作用域销毁时（[build] 里的 `ref.onDispose`）
  /// 也会调它，那时 `_disposed` 已置位，方法直接返回 —— 明文随 Notifier 与
  /// state 一起变得不可达，而 dispose 之后写 state 本身也是不允许的。
  void clearSecret() {
    if (_disposed) return;
    if (state.visibleSecret == null) return;
    state = state.copyWith(clearSecret: true);
  }

  /// 当前展示的明文是否属于 [invitationId]。
  bool _secretBelongsTo(int invitationId) =>
      state.visibleSecret?.invitationId == invitationId;

  /// 列表刷新后，把「已经不该继续展示」的明文清掉。
  ///
  /// 判据是「列表里还能找到它、且状态仍然是 active」。不需要自己拿 `expiresAt`
  /// 和当前时间比 —— 服务端下发的 status 已经是投影过的结果（active 过期会变成
  /// expired），本地再算一遍只会引入第二个真相和一堆时钟偏差问题。
  ///
  /// 找不到也一并清掉：可能被翻页挡住了，也可能真被别处撤销了。宁可贵一点
  /// （用户重新点一次「查看」），也不要让一个可能已失效的明文继续挂在屏幕上。
  void _dropSecretIfNoLongerOpen() {
    final secret = state.visibleSecret;
    if (secret == null) return;
    final stillOpen = state.items.any(
      (InvitationSummary item) =>
          item.id == secret.invitationId && item.status.isOpen,
    );
    if (stillOpen) return;
    state = state.copyWith(clearSecret: true);
  }

  /// 把写操作追加到串行队列。
  ///
  /// 返回的是**这一次**操作的结果，而队列尾巴只关心「前一个结束了」，
  /// 所以尾巴上挂了空错误处理：某一次写失败不该让后续写永远无法开始。
  Future<void> _enqueueWrite(Future<void> Function() operation) {
    final result = _writeTail.then((_) => operation());
    _writeTail = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }
}

List<InvitationSummary> _replaceInvitation(
  List<InvitationSummary> items,
  InvitationSummary updated,
) => <InvitationSummary>[
  for (final item in items)
    if (item.id == updated.id) updated else item,
];
