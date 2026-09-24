import 'dart:async';

import 'package:c_biz_docs_manager/app/session_scope.dart';
import 'package:c_biz_docs_manager/core/auth/auth_models.dart';
import 'package:c_biz_docs_manager/features/dictionaries/application/dictionary_controller.dart';
import 'package:c_biz_docs_manager/features/dictionaries/data/dictionary_repository.dart';
import 'package:c_biz_docs_manager/features/dictionaries/domain/dictionary_entry.dart';
import 'package:c_biz_docs_manager/features/members/application/member_controller.dart';
import 'package:c_biz_docs_manager/features/members/data/member_repository.dart';
import 'package:c_biz_docs_manager/features/members/domain/member.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
// `Override` / `ProviderException` 这两个类型名在 Riverpod 3 里被挪进了 misc.dart，
// 主入口只导出常用的那一组。
import 'package:flutter_riverpod/misc.dart' show Override, ProviderException;
import 'package:flutter_test/flutter_test.dart';

import '../support/auth_fixtures.dart';

/// 把 [buildSessionOverrides] 包成 Provider，好在测试里拿到「带 Ref 的构造器」：
/// 构造 override 必须读应用级 Provider（Dio / 数据库 / 缓存开关），而只有 Ref 能读。
final _overridesBuilderProvider =
    Provider<List<Override> Function(AuthSession)>(
      (Ref ref) =>
          (AuthSession session) => buildSessionOverrides(ref, session),
    );

void main() {
  late ProviderContainer app;
  late List<Override> Function(AuthSession) overridesFor;

  setUp(() {
    app = ProviderContainer(
      overrides: <Override>[
        dioProvider.overrideWithValue(
          Dio(BaseOptions(baseUrl: 'https://api.example.test')),
        ),
        appDatabaseProvider.overrideWithValue(null),
        // 本文件只验证作用域装配，不验证本地缓存；关掉缓存即可省去真实 Drift 库。
        nativeCacheEnabledProvider.overrideWithValue(false),
      ],
    );
    addTearDown(app.dispose);
    overridesFor = app.read(_overridesBuilderProvider);
  });

  test('换账号或换组会重建会话级 Repository、Controller 与缓存键', () {
    final owner = ownerSession();
    final other = memberSession(
      userId: 31,
      username: 'other',
      groupId: 8,
      groupName: 'Sales',
    );

    final ownerScope = ProviderContainer(
      parent: app,
      overrides: overridesFor(owner),
    );
    addTearDown(ownerScope.dispose);
    final otherScope = ProviderContainer(
      parent: app,
      overrides: overridesFor(other),
    );
    addTearDown(otherScope.dispose);

    // 会话本身随作用域隔离。
    expect(ownerScope.read(activeSessionProvider).scopeKey, owner.scopeKey);
    expect(otherScope.read(activeSessionProvider).scopeKey, other.scopeKey);
    expect(owner.scopeKey, isNot(other.scopeKey));

    // Repository 实例不共享 —— 它们各自持有 userId / groupId，共享会让
    // 本地缓存与在线请求落到上一个人、上一个组身上。
    final ownerMembers =
        ownerScope.read(memberRepositoryProvider) as DefaultMemberRepository;
    final otherMembers =
        otherScope.read(memberRepositoryProvider) as DefaultMemberRepository;
    expect(identical(ownerMembers, otherMembers), isFalse);
    expect((ownerMembers.userId, ownerMembers.groupId), (11, 7));
    expect((otherMembers.userId, otherMembers.groupId), (31, 8));

    final ownerDictionaries =
        ownerScope.read(dictionaryRepositoryProvider)
            as DefaultDictionaryRepository;
    final otherDictionaries =
        otherScope.read(dictionaryRepositoryProvider)
            as DefaultDictionaryRepository;
    expect(identical(ownerDictionaries, otherDictionaries), isFalse);
    expect((ownerDictionaries.userId, ownerDictionaries.groupId), (11, 7));
    expect((otherDictionaries.userId, otherDictionaries.groupId), (31, 8));

    // Controller 也是各自作用域里的新实例，状态从空开始：
    // 上一个人的成员列表与字典不会跟过来。
    expect(
      identical(
        ownerScope.read(memberControllerProvider.notifier),
        otherScope.read(memberControllerProvider.notifier),
      ),
      isFalse,
    );
    expect(otherScope.read(memberControllerProvider).items, isEmpty);
    expect(otherScope.read(memberControllerProvider).isLoading, isFalse);
    expect(otherScope.read(dictionaryControllerProvider).items, isEmpty);
  });

  test('平台管理员不装配任何租户 Repository', () {
    final scope = ProviderContainer(
      parent: app,
      overrides: overridesFor(platformAdminSession()),
    );
    addTearDown(scope.dispose);

    expect(
      scope.read(activeSessionProvider).profile.accountType,
      AccountType.platformAdmin,
    );
    // 「未装配」意味着读取立刻抛错，而不是悄悄退化成某个能读到别组数据的默认实现。
    expect(() => scope.read(memberRepositoryProvider), _throwsStateError);
    expect(() => scope.read(dictionaryRepositoryProvider), _throwsStateError);
  });

  test('租户会话缺少 group 时装配直接抛错', () {
    // AuthProfile.fromJson 会挡住这种身份；这里刻意手搓一个绕过严格解析的
    // profile，验证装配层不会退化成 groupId=0 去读写别人的缓存。
    final session = AuthSession(
      accessToken: 'access',
      profile: const AuthProfile(
        user: AuthUser(
          id: 22,
          username: 'sales',
          displayName: 'Sales',
          accountType: AccountType.member,
        ),
        group: null,
        memberType: MemberType.member,
        mustChangePassword: false,
        permissionCodes: <String>{},
      ),
    );

    expect(() => overridesFor(session), throwsStateError);
  });

  test('登出销毁旧作用域后，重新登录拿到的是干净状态', () {
    final ownerScope = ProviderContainer(
      parent: app,
      overrides: overridesFor(ownerSession()),
    );
    final previousController = ownerScope.read(
      memberControllerProvider.notifier,
    );

    // 等价于 AuthenticatedSessionScope 因 scopeKey 变化被卸载。
    ownerScope.dispose();

    expect(() => ownerScope.read(memberControllerProvider), throwsStateError);

    final nextScope = ProviderContainer(
      parent: app,
      overrides: overridesFor(ownerSession(accessToken: 'next-access')),
    );
    addTearDown(nextScope.dispose);

    expect(
      identical(
        previousController,
        nextScope.read(memberControllerProvider.notifier),
      ),
      isFalse,
    );
    expect(nextScope.read(memberControllerProvider).items, isEmpty);
  });

  test('作用域销毁后在途的 load 与写操作都不再写 state', () async {
    final loadGate = Completer<List<Member>>();
    final writeGate = Completer<Member>();
    final dictionaryGate = Completer<List<DictionaryEntry>>();
    // 这里不能把 overridesFor(...) 铺开再追加仓储覆盖：
    // 同一个容器里重复覆盖同一个 Provider 会被 Riverpod 直接断言拦下。
    final scope = ProviderContainer(
      parent: app,
      overrides: <Override>[
        activeSessionProvider.overrideWithValue(ownerSession()),
        memberRepositoryProvider.overrideWithValue(
          _GatedMemberRepository(loadGate: loadGate, writeGate: writeGate),
        ),
        dictionaryRepositoryProvider.overrideWithValue(
          _GatedDictionaryRepository(loadGate: dictionaryGate),
        ),
      ],
    );
    final memberController = scope.read(memberControllerProvider.notifier);
    final dictionaryController = scope.read(
      dictionaryControllerProvider.notifier,
    );

    final pendingMemberLoad = memberController.load();
    final pendingMemberWrite = memberController.changeStatus(
      7,
      MemberStatus.disabled,
      1,
    );
    final pendingDictionaryLoad = dictionaryController.load(
      const DictionaryQuery(),
    );
    await Future<void>.delayed(Duration.zero);

    scope.dispose();

    loadGate.complete(const <Member>[_memberForScope]);
    writeGate.complete(_memberForScope);
    dictionaryGate.complete(const <DictionaryEntry>[_dictionaryEntryForScope]);
    // 控制器若没有在 dispose 时让在途请求作废，这三个 await 会因为向已销毁的
    // Notifier 写 state 而抛错。
    await pendingMemberLoad;
    await pendingMemberWrite;
    await pendingDictionaryLoad;
  });
}

/// Riverpod 3 会把 Provider 内部抛出的异常包一层 [ProviderException] 再交给
/// `read` 的调用方，断言时要剥掉这层壳才看得到真正的 [StateError]。
final Matcher _throwsStateError = throwsA(
  isA<ProviderException>().having(
    (ProviderException error) => error.exception,
    'exception',
    isA<StateError>(),
  ),
);

const _memberForScope = Member(
  membershipId: 7,
  username: 'alice',
  displayName: 'Alice',
  memberType: 'member',
  status: MemberStatus.active,
  permissionCodes: <String>{},
  version: 1,
);

const _dictionaryEntryForScope = DictionaryEntry(
  id: 5,
  groupId: 7,
  kind: DictionaryKind.customer,
  name: '示例客户',
  status: DictionaryStatus.active,
  version: 1,
);

/// 可以人为卡住的成员仓储，用来在「请求在途时销毁作用域」。
final class _GatedMemberRepository implements MemberRepository {
  _GatedMemberRepository({required this.loadGate, required this.writeGate});

  final Completer<List<Member>> loadGate;
  final Completer<Member> writeGate;

  @override
  Future<List<Member>> listMembers() => loadGate.future;

  @override
  Future<Member> changeStatus(
    int membershipId,
    MemberStatus status,
    int version,
  ) => writeGate.future;

  @override
  Future<MemberPermissions> getPermissions(int membershipId) =>
      throw UnsupportedError('本用例不覆盖权限查询');

  @override
  Future<MemberPermissions> replacePermissions(
    int membershipId,
    Set<String> codes,
    int version,
  ) => throw UnsupportedError('本用例不覆盖权限替换');
}

/// 同上，用于字典列表。
final class _GatedDictionaryRepository implements DictionaryRepository {
  _GatedDictionaryRepository({required this.loadGate});

  final Completer<List<DictionaryEntry>> loadGate;

  @override
  Future<List<DictionaryEntry>> list(DictionaryQuery query) => loadGate.future;

  @override
  Future<DictionaryEntry> create(DictionaryDraft draft) =>
      throw UnsupportedError('本用例不覆盖字典写操作');

  @override
  Future<DictionaryEntry> update(int id, DictionaryDraft draft, int version) =>
      throw UnsupportedError('本用例不覆盖字典写操作');

  @override
  Future<DictionaryEntry> changeStatus(
    int id,
    DictionaryStatus status,
    int version,
  ) => throw UnsupportedError('本用例不覆盖字典写操作');
}
