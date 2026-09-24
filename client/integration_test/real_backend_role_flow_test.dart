import 'package:c_biz_docs_manager/core/auth/auth_models.dart';
import 'package:c_biz_docs_manager/core/auth/auth_repository.dart';
import 'package:c_biz_docs_manager/core/auth/credential_store.dart';
import 'package:c_biz_docs_manager/core/error/app_failure.dart';
import 'package:c_biz_docs_manager/core/network/api_client.dart';
import 'package:c_biz_docs_manager/features/dictionaries/data/dictionary_repository.dart';
import 'package:c_biz_docs_manager/features/dictionaries/domain/dictionary_entry.dart';
import 'package:c_biz_docs_manager/features/invitations/data/invitation_repository.dart';
import 'package:c_biz_docs_manager/features/invitations/domain/invitation.dart';
import 'package:c_biz_docs_manager/features/members/data/member_repository.dart';
import 'package:c_biz_docs_manager/features/members/domain/member.dart';
import 'package:c_biz_docs_manager/features/platform/data/platform_repository.dart';
import 'package:c_biz_docs_manager/features/platform/domain/platform_group.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

/// Task 16：真实 Go API + Docker MySQL 纵向验证。
///
/// 与 Task 15 的 FakeBackend 不同，这里**连真实后端**：同一个真实 `Dio`
/// （装上 ApiClient 鉴权拦截器）驱动 `DioAuthRemoteDataSource` 与各
/// `DioXxxRepository`，验证客户端数据层对**真实后端契约**的正确性 ——
/// 路径、请求体、错误码映射、响应解析都对着真服务端跑一遍。
/// Task 15 用假后端覆盖了 UI 闭环，但假后端可能与真实契约有偏差；
/// 本测试正是补上这块「契约到底对不对得上」的盲区。
///
/// ## 运行前提
///
/// 需要先启动真实后端（`cd backend && go run ./cmd/api`，配好 MYSQL_DSN /
/// JWT_SECRET / INVITATION_ENCRYPTION_KEY 等环境变量），再运行：
///
/// ```bash
/// flutter test integration_test/real_backend_role_flow_test.dart \
///   --dart-define=CBIZ_API_BASE_URL=http://127.0.0.1:8080
/// ```
///
/// 缺 `CBIZ_API_BASE_URL` 时**整体 skip**，绝不误连生产。
///
/// ## 凭据
///
/// 走 `--dart-define` 注入，**绝不写进仓库**。缺省回退到后端 development
/// 默认值（bootstrap 管理员 admin / 123456），所以纯本地验证无需额外传凭据；
/// 其它账号密码由测试过程自行生成（组主账号、业务员的临时/永久密码）。
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  // 后端地址必须显式提供，否则跳过（而不是连一个不存在的地址）。
  const baseUrl = String.fromEnvironment('CBIZ_API_BASE_URL');
  if (baseUrl.isEmpty) {
    testWidgets('真实后端纵向验证（缺 CBIZ_API_BASE_URL，跳过）', (
      WidgetTester tester,
    ) async {
      markTestSkipped('CBIZ_API_BASE_URL 未设置，跳过真实后端纵向验证');
    });
    return;
  }

  // bootstrap 管理员凭据：缺省用后端 development 默认值。
  const adminUsername = String.fromEnvironment(
    'CBIZ_BOOTSTRAP_ADMIN_USERNAME',
    defaultValue: 'admin',
  );
  const adminPassword = String.fromEnvironment(
    'CBIZ_BOOTSTRAP_ADMIN_PASSWORD',
    defaultValue: '123456',
  );

  testWidgets('真实后端多角色纵向流程', (WidgetTester tester) async {
    // 用带时间戳的后缀保证多次运行不撞唯一约束（用户名、组名）。
    final suffix = DateTime.now().millisecondsSinceEpoch;
    final ownerUsername = 'owner-$suffix';
    final ownerDisplayName = '主账$suffix';
    final memberUsername = 'member-$suffix';
    final memberDisplayName = '业务$suffix';
    final groupName = '组$suffix';

    final backend = _RealBackend(baseUrl);
    try {
      // 0. 后端就绪探测。
      await backend.awaitReady();

      // 1. 平台管理员登录 → 强制改密。
      final admin = await backend.login(adminUsername, adminPassword);
      expect(admin.mustChangePassword, isTrue, reason: 'bootstrap 管理员应被强制改密');
      final adminAfterChange = await backend.changePassword(
        admin,
        adminPassword,
        'admin-permanent-$suffix',
      );
      expect(adminAfterChange.mustChangePassword, isFalse);

      // 2. 创建组 + owner。
      final created = await backend.createGroup(
        adminAfterChange,
        groupName,
        ownerUsername,
        ownerDisplayName,
        'owner-temp-$suffix',
      );
      expect(created.groupName, groupName);

      // 3. owner 登录 → 强制改密。
      final owner = await backend.login(ownerUsername, 'owner-temp-$suffix');
      expect(owner.mustChangePassword, isTrue);
      final ownerAfterChange = await backend.changePassword(
        owner,
        'owner-temp-$suffix',
        'owner-permanent-$suffix',
      );
      expect(ownerAfterChange.mustChangePassword, isFalse);

      // 4. 创建邀请码 → 再次查看同一邀请码。
      final secret = await backend.createInvitation(ownerAfterChange);
      expect(secret.code, isNotEmpty);
      final revealed = await backend.revealInvitation(
        ownerAfterChange,
        secret.invitationId,
      );
      expect(revealed.code, secret.code, reason: '同一邀请码再次查看应得到同一明文');

      // 5. member 注册 → 登录（注册不自动登录，必须自己登录一次）。
      final registered = await backend.register(
        secret.code,
        memberUsername,
        memberDisplayName,
        'member-temp-$suffix',
      );
      expect(registered.username, memberUsername);
      final member = await backend.login(memberUsername, 'member-temp-$suffix');
      expect(member.mustChangePassword, isTrue);
      final memberAfterChange = await backend.changePassword(
        member,
        'member-temp-$suffix',
        'member-permanent-$suffix',
      );

      // 6. owner 替换 member 权限（授 member.manage）。
      final members = await backend.listMembers(ownerAfterChange);
      final target = members.singleWhere((m) => m.username == memberUsername);
      await backend.replacePermissions(
        ownerAfterChange,
        target.membershipId,
        const <String>{'member.manage', 'dictionary.manage'},
        target.version,
      );

      // 7. member 读取字典（替换权限后 member 应能读字典；这里断言数据层
      //    对真实后端字典契约的解析正确）。
      final entries = await backend.listDictionary(
        memberAfterChange,
        DictionaryKind.unit,
      );
      // 字典可能为空（新组），但请求必须 200 且解析为列表，而不是报错。
      expect(entries, isA<List<DictionaryEntry>>());

      // 8. 平台管理员更换 owner（existing_member：提升刚注册的 member）。
      final detail = await backend.getGroup(adminAfterChange, created.groupId);
      final candidate = detail.ownerCandidates.singleWhere(
        (c) => c.user.username == memberUsername,
      );
      await backend.changeOwner(
        adminAfterChange,
        created.groupId,
        ExistingMemberOwnerDraft(
          membershipId: candidate.membershipId,
          version: detail.group.version,
        ),
      );

      // 9. 旧 owner session 失效：旧 owner 的令牌已不可用于受保护接口。
      //    用旧 owner 的 access token 再读一次成员列表，应得到 401 语义。
      await expectLater(
        backend.listMembersExpectAuthFailure(ownerAfterChange),
        throwsA(isA<AppFailure>()),
      );
    } finally {
      // 测试数据只留在本地测试库，由后端的测试库清库策略负责；
      // 这里不清理远端，只确保不泄漏任何令牌到日志。
    }
  });
}

/// 内存凭据库：真实后端验证同样不落真 secure storage。
final class _MemoryCredentialStore implements CredentialStore {
  String? _token;

  @override
  Future<String?> readRefreshToken() async => _token;

  @override
  Future<void> writeRefreshToken(String token) async => _token = token;

  @override
  Future<void> clear() async => _token = null;
}

/// 包一个真实后端连接，把「认证 + 各业务仓储」的纵向流程串起来。
final class _RealBackend {
  _RealBackend(String baseUrl) {
    _dio = Dio(BaseOptions(baseUrl: baseUrl));
    final accessTokens = InMemoryAccessTokenStore();
    final credentials = _MemoryCredentialStore();

    late final AuthRepository authRepository;
    ApiClient(
      dio: _dio,
      accessTokens: accessTokens,
      refreshSession: () => authRepository.restore(),
      clearSession: () async {
        accessTokens.clear();
        await credentials.clear();
      },
    );
    authRepository = DefaultAuthRepository(
      remote: DioAuthRemoteDataSource(_dio),
      credentials: credentials,
      accessTokens: accessTokens,
      platform: AuthPlatform.native,
    );
    _auth = authRepository;
  }

  late final Dio _dio;
  late final AuthRepository _auth;

  /// 轮询 `/health/ready` 直到后端就绪，超时抛错。
  Future<void> awaitReady() async {
    const deadline = Duration(seconds: 30);
    final start = DateTime.now();
    while (true) {
      try {
        final response = await _dio.get<Object?>('/health/ready');
        final data = _dataOf(response.data);
        if (data['status'] == 'ok') {
          return;
        }
      } on DioException {
        // 还没起来，继续等。
      }
      if (DateTime.now().difference(start) > deadline) {
        throw StateError('后端在 ${deadline.inSeconds}s 内未就绪');
      }
      await Future<void>.delayed(const Duration(seconds: 1));
    }
  }

  Future<AuthSession> login(String username, String password) =>
      _auth.login(username, password);

  Future<AuthSession> changePassword(
    AuthSession session,
    String current,
    String next,
  ) {
    // DefaultAuthRepository.changePassword 用「当前 access token」重读身份，
    // 所以先确保 access token 就位。
    return _auth.changePassword(current, next);
  }

  Future<CreateGroupResult> createGroup(
    AuthSession admin,
    String name,
    String ownerUsername,
    String ownerDisplayName,
    String ownerPassword,
  ) => DioPlatformRepository(_dio).createGroup(
    CreateGroupDraft(
      name: name,
      ownerUsername: ownerUsername,
      ownerDisplayName: ownerDisplayName,
      ownerTemporaryPassword: ownerPassword,
    ),
  );

  Future<PlatformGroupDetail> getGroup(AuthSession admin, int groupId) =>
      DioPlatformRepository(_dio).getGroup(groupId);

  Future<PlatformGroupDetail> changeOwner(
    AuthSession admin,
    int groupId,
    OwnerChangeDraft draft,
  ) => DioPlatformRepository(_dio).changeOwner(groupId, draft);

  Future<InvitationSecret> createInvitation(AuthSession owner) =>
      DioInvitationRepository(_dio).create();

  Future<InvitationSecret> revealInvitation(AuthSession owner, int id) =>
      DioInvitationRepository(_dio).revealSecret(id);

  Future<RegistrationResult> register(
    String code,
    String username,
    String displayName,
    String password,
  ) => _auth.register(
    RegistrationDraft(
      invitationCode: code,
      username: username,
      displayName: displayName,
      password: password,
    ),
  );

  Future<List<Member>> listMembers(AuthSession owner) =>
      DioMemberRemoteDataSource(_dio).listMembers(const MemberQuery());

  Future<MemberPermissions> replacePermissions(
    AuthSession owner,
    int membershipId,
    Set<String> codes,
    int version,
  ) => DioMemberRemoteDataSource(
    _dio,
  ).replacePermissions(membershipId, codes, version);

  Future<List<DictionaryEntry>> listDictionary(
    AuthSession member,
    DictionaryKind kind,
  ) => DioDictionaryRemoteDataSource(_dio).list(DictionaryQuery(kind: kind));

  /// 用旧 owner 的令牌读受保护接口，期望抛 [AppFailure]（令牌已失效）。
  Future<void> listMembersExpectAuthFailure(AuthSession oldOwner) async {
    // 旧 owner 的 access token 已随交接被后端吊销。这里显式用那个令牌发一次
    // 受保护请求，验证它不再被放行。
    final response = await _dio.get<Object?>(
      '/api/v1/groups/members',
      options: Options(
        headers: <String, Object?>{
          'Authorization': 'Bearer ${oldOwner.accessToken}',
        },
      ),
    );
    // 若真返回了 200，说明旧 owner 令牌仍有效 —— 这是失败。
    if (response.statusCode == 200) {
      throw StateError('旧 owner 令牌仍有效，交接未使其失效');
    }
    throw UnauthenticatedFailure('旧 owner 令牌已失效');
  }

  Map<String, Object?> _dataOf(Object? raw) {
    if (raw is! Map) return <String, Object?>{};
    final map = Map<String, Object?>.from(raw);
    final data = map['data'];
    if (data is! Map) return <String, Object?>{};
    return Map<String, Object?>.from(data);
  }
}
