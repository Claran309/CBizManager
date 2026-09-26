import 'dart:convert';

import 'package:c_biz_docs_manager/core/money/money.dart';
import 'package:dio/dio.dart';

/// 模拟服务端的**确定性状态机**，供纵向 Widget 闭环测试使用。
///
/// 它实现 [HttpClientAdapter]，被塞进一个真实 [Dio] 里 —— 于是从 UI 一路走
/// 到 `DioXxxRemoteDataSource` → Dio 拦截器 → 本类，再原路返回 `fromJson` 解析，
/// 整条链路与生产完全一致，只是「网络那头」换成了这个内存里的状态机。
/// 这正是 Task 15 要的「纵向闭环」：不再每个模块各自 mock 一个 Repository，
/// 而是让一个假的**后端**把各模块串起来，验证跨模块的状态真的会流动
/// （组交接后旧 owner 的邀请码 / 成员 / 字典状态随之不可见）。
///
/// ## 安全铁律
///
/// 状态机内部确实持有密码、访问令牌、刷新令牌与邀请码明文 —— 不持有它们就
/// 没法模拟「登录」「注册」这些动作。但**它们绝不允许出现在任何诊断输出里**：
///
/// - [toString] 只打印「各资源的 id 数量」这类无害摘要；
/// - 所有抛错 / 断言消息只携带 resource id 与 path，不带 payload；
/// - 失败输出（`failures` 记录）只记 `method path` 与错误码，不记请求体。
///
/// 测试失败时框架会把异常 / 状态打印出来，那是最常见的秘密泄漏渠道。
final class FakeBackend implements HttpClientAdapter {
  /* ------------------------------------------------------------ 内存状态 */

  /// 平台管理员账号：username -> (password, mustChangePassword)。
  final Map<String, ({String password, bool mustChangePassword})>
  _platformAdmins = <String, ({String password, bool mustChangePassword})>{
    'admin': (password: 'admin-pass', mustChangePassword: true),
  };

  /// 平台管理员会话：accessToken -> username。
  final Map<String, String> _adminTokens = <String, String>{};

  /// 租户访问令牌：accessToken -> username（主账号或业务员都落这里）。
  final Map<String, String> _tenantTokens = <String, String>{};

  /// 刷新令牌：refreshToken -> username（用于 /auth/refresh 反查）。
  final Map<String, String> _refreshTokens = <String, String>{};

  /// 组主账号：username -> 完整凭据。
  final Map<String, ({String password, bool mustChangePassword, int groupId})>
  _owners =
      <String, ({String password, bool mustChangePassword, int groupId})>{};

  /// 业务员：username -> 完整凭据。
  final Map<
    String,
    ({String password, bool mustChangePassword, int groupId, int userId})
  >
  _members =
      <
        String,
        ({String password, bool mustChangePassword, int groupId, int userId})
      >{};

  /// 业务组：id -> 组状态。
  final Map<int, _FakeGroup> _groups = <int, _FakeGroup>{};

  /// 邀请码：id -> 邀请码状态。
  final Map<int, _FakeInvitation> _invitations = <int, _FakeInvitation>{};

  /// 成员关系：groupId -> membershipId -> 成员。
  final Map<int, Map<int, _FakeMember>> _membersByGroup =
      <int, Map<int, _FakeMember>>{};

  /// 字典条目：groupId -> kind -> id -> 条目。
  final Map<int, Map<String, Map<int, _FakeDictionary>>> _dictionaries =
      <int, Map<String, Map<int, _FakeDictionary>>>{};

  /// 下一批可分配的 id（组 / 邀请码 / 成员关系 / 字典各一套）。
  int _nextGroupId = 1;
  int _nextInvitationId = 1;
  int _nextMembershipId = 1;
  int _nextDictionaryId = 1;
  int _nextUserId = 100;

  /* -------------------------------------------------- 业务单据 / 结算 / 财务 */

  /// 单据：id -> 单据（入库与出库共用一张表，由 kind 判别）。
  final Map<int, _FakeDocument> _documents = <int, _FakeDocument>{};

  /// 结算单：id -> 结算单。
  final Map<int, _FakeSettlement> _settlements = <int, _FakeSettlement>{};

  /// 财务记录：id -> 记录。
  final Map<int, _FakeFinanceRecord> _financeRecords =
      <int, _FakeFinanceRecord>{};

  /// 总结算快照：id -> 快照。
  final Map<int, _FakeSnapshot> _snapshots = <int, _FakeSnapshot>{};

  int _nextDocumentId = 1;
  int _nextSettlementId = 1;
  int _nextFinanceId = 1;
  int _nextSnapshotId = 1;

  /// 单号当日序号：`"groupId:前缀:YYYYMMDD" -> 已用序号`。
  final Map<String, int> _docSequences = <String, int>{};

  /// 结算单当月序号：`"groupId:YYYYMM" -> 已用序号`。
  final Map<String, int> _settlementSequences = <String, int>{};

  /// 每次 `fetch` 递增的请求序号，用来生成确定性的 request_id。
  int _requestCounter = 0;

  /// 权限目录（后端固化常量）。
  static const List<Map<String, Object?>> _permissionCatalog =
      <Map<String, Object?>>[
        <String, Object?>{
          'code': 'document.view_others',
          'name': '查看他人单据',
          'description': '查看同组其他业务员创建的单据',
        },
        <String, Object?>{
          'code': 'document.edit_others',
          'name': '编辑他人单据',
          'description': '编辑同组其他业务员创建的单据',
        },
        <String, Object?>{
          'code': 'report.view',
          'name': '查看汇总报表',
          'description': '查看入库/出库/结算等汇总统计',
        },
        <String, Object?>{
          'code': 'member.manage',
          'name': '管理成员',
          'description': '查看成员列表并管理成员状态',
        },
        <String, Object?>{
          'code': 'dictionary.manage',
          'name': '管理字典',
          'description': '新增、编辑和停用字典条目',
        },
        <String, Object?>{
          'code': 'settlement.approve',
          'name': '审批结算',
          'description': '审批组内的结算单',
        },
        <String, Object?>{
          'code': 'finance.record',
          'name': '登记财务',
          'description': '登记收付款与开票记录',
        },
      ];

  /// 失败记录：`"METHOD /path -> CODE"`，供断言「确实走了期望的失败路径」。
  /// 刻意不含请求体 —— 里面可能有密码 / 邀请码。
  final List<String> failures = <String>[];

  /* ---------------------------------------------------------- 辅助方法 */

  /// 预置一个「平台管理员已建好一个组、组主账号就位」的起点。
  ///
  /// 返回 (groupId, ownerUsername)。owner 已改密（mustChangePassword=false），
  /// 这样 Step3 的 owner 闭环可以从「登录即进首页」开始，不必再走一遍改密。
  int seedGroupWithOwner({
    String groupName = 'Finance',
    String ownerUsername = 'owner',
    String ownerDisplayName = '王主账',
  }) {
    final groupId = _nextGroupId++;
    _groups[groupId] = _FakeGroup(
      id: groupId,
      name: groupName,
      status: 'active',
      version: 1,
      ownerUsername: ownerUsername,
      ownerDisplayName: ownerDisplayName,
    );
    _owners[ownerUsername] = (
      password: 'owner-pass',
      mustChangePassword: false,
      groupId: groupId,
    );
    // 主账号同时也是「成员列表」里的 owner 那一行。
    final ownerUserId = _nextUserId++;
    _membersByGroup[groupId] = <int, _FakeMember>{
      _nextMembershipId++: _FakeMember(
        membershipId: _nextMembershipId - 1,
        userId: ownerUserId,
        username: ownerUsername,
        displayName: ownerDisplayName,
        memberType: 'owner',
        status: 'active',
        permissionCodes: const <String>{},
        version: 1,
      ),
    };
    return groupId;
  }

  /// 当前是否存在「登录后可进入业务区」的会话（供断言会话失效用）。
  bool get hasActiveTenantSession => _tenantTokens.isNotEmpty;

  int get groupCount => _groups.length;

  /* ------------------------------------------------------------ 响应构造 */

  Map<String, Object?> _ok(
    Object? data, {
    String requestId = '',
  }) => <String, Object?>{
    'code': 'OK',
    'message': 'success',
    'data': data,
    'request_id': requestId.isEmpty ? 'req-${++_requestCounter}' : requestId,
  };

  /// 构造一个错误信封，并记录失败（只记 method/path/code，不记 payload）。
  Map<String, Object?> _error(
    String code,
    String message, {
    String requestId = '',
  }) {
    return <String, Object?>{
      'code': code,
      'message': message,
      'data': null,
      'request_id': requestId.isEmpty ? 'req-${++_requestCounter}' : requestId,
    };
  }

  /* ------------------------------------------------------------ adapter */

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final method = options.method;
    final path = options.uri.path;
    final body = _readJsonBody(options.data);
    // ApiClient 拦截器注入的 Bearer 头；用来识别「当前是谁」。
    final auth = _bearerToken(options.headers['Authorization']);

    final response = _route(
      method,
      path,
      options.uri.queryParameters,
      body,
      auth,
    );
    final status = response.status;
    final payload = response.payload;

    if (status >= 400) {
      failures.add('$method $path -> ${payload['code']}');
    }

    return ResponseBody.fromString(
      jsonEncode(payload),
      status,
      headers: <String, List<String>>{
        Headers.contentTypeHeader: <String>[Headers.jsonContentType],
      },
    );
  }

  /// 从 `Bearer xxx` 头里解出 token；不是 Bearer 则返回 null。
  String? _bearerToken(Object? header) {
    if (header is! String || !header.startsWith('Bearer ')) return null;
    final token = header.substring('Bearer '.length);
    return token.isEmpty ? null : token;
  }

  /// 读请求体：Dio 传过来的是 Map，或已被 `_requestStream` 序列化成别的形态。
  /// 这里统一成 `Map<String, Object?>`；非对象（如空 body）返回空 map。
  Map<String, Object?> _readJsonBody(Object? data) {
    if (data is Map<String, Object?>) return data;
    if (data is Map) return Map<String, Object?>.from(data);
    return <String, Object?>{};
  }

  /* ------------------------------------------------------------ 路由 */

  _FakeResponse _route(
    String method,
    String path,
    Map<String, String> query,
    Map<String, Object?> body,
    String? auth,
  ) {
    // 认证接口（匿名 / 令牌无关）。
    if (path == '/api/v1/auth/login' && method == 'POST') {
      return _login(body, query, native: true);
    }
    if (path == '/api/v1/auth/register' && method == 'POST') {
      return _register(body, query);
    }
    if (path == '/api/v1/auth/refresh' && method == 'POST') {
      return _refresh(body);
    }
    if (path == '/api/v1/auth/me' && method == 'GET') {
      return _me(auth);
    }
    if (path == '/api/v1/auth/logout' && method == 'POST') {
      return _logout(auth);
    }
    if (path == '/api/v1/auth/password' && method == 'PUT') {
      return _changePassword(auth, body);
    }

    // 平台治理（要求平台管理员令牌）。
    if (path == '/api/v1/platform/groups' && method == 'GET') {
      return _platformGroupsList(query);
    }
    if (path == '/api/v1/platform/groups' && method == 'POST') {
      return _platformGroupCreate(body);
    }
    if (path.startsWith('/api/v1/platform/groups/')) {
      return _platformGroupSubpath(method, path, body);
    }

    // 邀请码（要求 owner 令牌）。
    if (path == '/api/v1/groups/invitations' && method == 'GET') {
      return _invitationsList(query);
    }
    if (path == '/api/v1/groups/invitations' && method == 'POST') {
      return _invitationCreate(body);
    }
    if (path.startsWith('/api/v1/groups/invitations/')) {
      return _invitationSubpath(method, path, body);
    }

    // 成员与权限。
    if (path == '/api/v1/groups/members' && method == 'GET') {
      return _membersList(query);
    }
    if (path == '/api/v1/groups/permission-catalog' && method == 'GET') {
      return _permissionCatalogList();
    }
    if (path.startsWith('/api/v1/groups/members/')) {
      return _memberSubpath(method, path, body);
    }

    // 字典。
    if (path == '/api/v1/dictionaries' && method == 'GET') {
      return _dictionaryList(query);
    }

    // 单据：入库 / 出库共用一套结构，由路径前缀决定 kind。
    if (path == '/api/v1/inbound-documents' && method == 'GET') {
      return _documentsList(auth, 'inbound', query);
    }
    if (path == '/api/v1/inbound-documents' && method == 'POST') {
      return _documentCreate(auth, 'inbound', body);
    }
    if (path.startsWith('/api/v1/inbound-documents/')) {
      return _documentSubpath(auth, method, path, 'inbound', body);
    }
    if (path == '/api/v1/outbound-documents' && method == 'GET') {
      return _documentsList(auth, 'outbound', query);
    }
    if (path == '/api/v1/outbound-documents' && method == 'POST') {
      return _documentCreate(auth, 'outbound', body);
    }
    if (path.startsWith('/api/v1/outbound-documents/')) {
      return _documentSubpath(auth, method, path, 'outbound', body);
    }

    // 结算单。
    if (path == '/api/v1/settlements' && method == 'GET') {
      return _settlementsList(auth, query);
    }
    if (path == '/api/v1/settlements' && method == 'POST') {
      return _settlementCreate(auth, body);
    }
    if (path.startsWith('/api/v1/settlements/')) {
      return _settlementSubpath(auth, path, body);
    }

    // 财务：付款 / 收款 / 开票共用一套结构；结清视图独立。
    if (path.startsWith('/api/v1/finance/statements/')) {
      return _statementHandler(auth, path);
    }
    for (final entry in const <String, String>{
      '/api/v1/finance/payments': 'payment',
      '/api/v1/finance/receipts': 'receipt',
      '/api/v1/finance/invoices': 'invoice',
    }.entries) {
      if (path == entry.key && method == 'GET') {
        return _financeList(auth, entry.value, query);
      }
      if (path == entry.key && method == 'POST') {
        return _financeCreate(auth, entry.value, body);
      }
      if (path.startsWith('${entry.key}/')) {
        return _financeRevoke(auth, path);
      }
    }

    // 报表。
    if (path == '/api/v1/reports/overview' && method == 'GET') {
      return _reportOverview(auth, query);
    }
    if (path == '/api/v1/reports/inbound-stats' && method == 'GET') {
      return _reportStats(auth, 'inbound', query);
    }
    if (path == '/api/v1/reports/outbound-stats' && method == 'GET') {
      return _reportStats(auth, 'outbound', query);
    }
    if (path == '/api/v1/reports/business-users' && method == 'GET') {
      return _reportBusinessUsers(auth, query);
    }
    if (path == '/api/v1/reports/summary-settlements' && method == 'GET') {
      return _snapshotsList(auth, query);
    }
    if (path == '/api/v1/reports/summary-settlements' && method == 'POST') {
      return _snapshotCreate(auth, body);
    }
    if (path.startsWith('/api/v1/reports/summary-settlements/')) {
      return _snapshotDetail(auth, path);
    }

    return _FakeResponse(
      404,
      _error('INTERNAL_ERROR', 'FakeBackend 未实现 $method $path'),
    );
  }

  /* ------------------------------------------------------------ 认证 */

  _FakeResponse _login(
    Map<String, Object?> body,
    Map<String, String> query, {
    required bool native,
  }) {
    final username = body['username'];
    final password = body['password'];
    if (username is! String || password is! String || username.isEmpty) {
      return _FakeResponse(400, _error('VALIDATION_FAILED', '参数不合法'));
    }

    // 平台管理员？
    final admin = _platformAdmins[username];
    if (admin != null) {
      if (admin.password != password) {
        return _FakeResponse(
          401,
          _error('AUTH_INVALID_CREDENTIALS', '用户名或密码错误'),
        );
      }
      final token = 'admin-token-$username-${_requestCounter++}';
      _adminTokens[token] = username;
      return _FakeResponse(
        200,
        _ok(_tokenPayload(token, username, native: native)),
      );
    }

    // 组主账号？
    final owner = _owners[username];
    if (owner != null) {
      if (owner.password != password) {
        return _FakeResponse(
          401,
          _error('AUTH_INVALID_CREDENTIALS', '用户名或密码错误'),
        );
      }
      final token = 'tenant-token-$username-${_requestCounter++}';
      _tenantTokens[token] = username;
      return _FakeResponse(
        200,
        _ok(_tokenPayload(token, username, native: native)),
      );
    }

    // 业务员？
    final member = _members[username];
    if (member != null) {
      if (member.password != password) {
        return _FakeResponse(
          401,
          _error('AUTH_INVALID_CREDENTIALS', '用户名或密码错误'),
        );
      }
      // 停用 / 移除的成员不能登录（与后端「停用账号登录统一返回无效凭据、
      // 防账号枚举」的口径一致）。
      final row = _memberRowOf(member.groupId, username);
      if (row != null && row.status != 'active') {
        return _FakeResponse(
          401,
          _error('AUTH_INVALID_CREDENTIALS', '用户名或密码错误'),
        );
      }
      final token = 'tenant-token-$username-${_requestCounter++}';
      _tenantTokens[token] = username;
      return _FakeResponse(
        200,
        _ok(_tokenPayload(token, username, native: native)),
      );
    }

    return _FakeResponse(401, _error('AUTH_INVALID_CREDENTIALS', '用户名或密码错误'));
  }

  Map<String, Object?> _tokenPayload(
    String token,
    String username, {
    required bool native,
  }) {
    if (native) {
      final refresh = 'refresh-$token';
      _refreshTokens[refresh] = username;
      return <String, Object?>{
        'access_token': token,
        'refresh_token': refresh,
        'access_expires_at': '2026-09-25T18:00:00Z',
        'refresh_expires_at': '2026-09-26T18:00:00Z',
      };
    }
    return <String, Object?>{
      'access_token': token,
      'access_expires_at': '2026-09-25T18:00:00Z',
    };
  }

  _FakeResponse _register(
    Map<String, Object?> body,
    Map<String, String> query,
  ) {
    final code = body['invitation_code'];
    final username = body['username'];
    final displayName = body['display_name'];
    final password = body['password'];
    if (code is! String ||
        username is! String ||
        displayName is! String ||
        password is! String) {
      return _FakeResponse(400, _error('VALIDATION_FAILED', '参数不合法'));
    }

    // 找到那个「有效」邀请码。
    _FakeInvitation? matched;
    for (final invitation in _invitations.values) {
      if (invitation.code == code && invitation.status == 'active') {
        matched = invitation;
        break;
      }
    }
    if (matched == null) {
      return _FakeResponse(400, _error('INVITATION_INVALID', '邀请码无效'));
    }
    if (_members.containsKey(username) || _owners.containsKey(username)) {
      return _FakeResponse(409, _error('USER_USERNAME_EXISTS', '用户名已存在'));
    }

    final groupId = matched.groupId;
    final userId = _nextUserId++;
    final membershipId = _nextMembershipId++;
    _members[username] = (
      password: password,
      mustChangePassword: true,
      groupId: groupId,
      userId: userId,
    );
    _membersByGroup.putIfAbsent(
      groupId,
      () => <int, _FakeMember>{},
    )[membershipId] = _FakeMember(
      membershipId: membershipId,
      userId: userId,
      username: username,
      displayName: displayName,
      memberType: 'member',
      status: 'active',
      permissionCodes: const <String>{},
      version: 1,
    );
    // 邀请码用掉。
    matched.status = 'used';
    matched.usedByUsername = username;

    return _FakeResponse(
      201,
      _ok(<String, Object?>{
        'user': <String, Object?>{
          'id': userId,
          'username': username,
          'display_name': displayName,
          'account_type': 'member',
        },
        'group': <String, Object?>{
          'id': groupId,
          'name': _groups[groupId]?.name ?? 'Finance',
        },
      }),
    );
  }

  _FakeResponse _changePassword(String? auth, Map<String, Object?> body) {
    // 用 Authorization 头识别当前账号，只对该账号清零改密标记。
    final username = _usernameOfToken(auth);
    if (username == null) {
      return _FakeResponse(401, _error('AUTH_INVALID_CREDENTIALS', '未登录'));
    }
    final owner = _owners[username];
    if (owner != null) {
      _owners[username] = (
        password: owner.password,
        mustChangePassword: false,
        groupId: owner.groupId,
      );
    }
    final member = _members[username];
    if (member != null) {
      _members[username] = (
        password: member.password,
        mustChangePassword: false,
        groupId: member.groupId,
        userId: member.userId,
      );
    }
    final admin = _platformAdmins[username];
    if (admin != null) {
      _platformAdmins[username] = (
        password: admin.password,
        mustChangePassword: false,
      );
    }
    return _FakeResponse(200, _ok(<String, Object?>{'changed': true}));
  }

  /// 根据访问令牌反查 username（主账号 / 业务员 / 平台管理员三张表都查）。
  String? _usernameOfToken(String? token) {
    if (token == null) return null;
    return _tenantTokens[token] ?? _adminTokens[token];
  }

  /// 找某个组里某 username 对应的成员关系行；没有则 null。
  _FakeMember? _memberRowOf(int groupId, String username) {
    for (final member
        in (_membersByGroup[groupId] ?? <int, _FakeMember>{}).values) {
      if (member.username == username) return member;
    }
    return null;
  }

  _FakeResponse _refresh(Map<String, Object?> body) {
    final refreshToken = body['refresh_token'];
    final username = refreshToken is! String
        ? null
        : _refreshTokens[refreshToken];
    if (username == null) {
      return _FakeResponse(401, _error('AUTH_REFRESH_INVALID', '刷新令牌无效'));
    }
    final token = 'tenant-token-$username-${_requestCounter++}';
    _tenantTokens[token] = username;
    return _FakeResponse(
      200,
      _ok(_tokenPayload(token, username, native: true)),
    );
  }

  _FakeResponse _me(String? auth) {
    final username = _usernameOfToken(auth);
    if (username == null) {
      return _FakeResponse(401, _error('AUTH_INVALID_CREDENTIALS', '未登录'));
    }
    return _FakeResponse(200, _ok(_mePayload(username)));
  }

  Map<String, Object?> _mePayload(String username) {
    // 平台管理员。
    final admin = _platformAdmins[username];
    if (admin != null) {
      return <String, Object?>{
        'user': <String, Object?>{
          'id': 1,
          'username': username,
          'display_name': '平台管理员',
          'account_type': 'platform_admin',
        },
        'group': null,
        'member_type': null,
        'must_change_password': admin.mustChangePassword,
        'permission_codes': <Object?>[],
      };
    }
    // 组主账号。
    final owner = _owners[username];
    if (owner != null) {
      final group = _groups[owner.groupId]!;
      return <String, Object?>{
        'user': <String, Object?>{
          'id': _ownerUserId(username),
          'username': username,
          'display_name': group.ownerDisplayName,
          'account_type': 'group_owner',
        },
        'group': <String, Object?>{'id': group.id, 'name': group.name},
        'member_type': 'owner',
        'must_change_password': owner.mustChangePassword,
        'permission_codes': <Object?>[],
      };
    }
    // 业务员。
    final member = _members[username]!;
    final group = _groups[member.groupId]!;
    // 业务员的显示名存在成员关系行里；找不到（理论不会）就用 username 兜底。
    _FakeMember? memberRow;
    for (final row
        in (_membersByGroup[member.groupId] ?? <int, _FakeMember>{}).values) {
      if (row.username == username) {
        memberRow = row;
        break;
      }
    }
    return <String, Object?>{
      'user': <String, Object?>{
        'id': member.userId,
        'username': username,
        'display_name': memberRow?.displayName ?? username,
        'account_type': 'member',
      },
      'group': <String, Object?>{'id': group.id, 'name': group.name},
      'member_type': 'member',
      'must_change_password': member.mustChangePassword,
      'permission_codes': List<Object?>.from(
        memberRow?.permissionCodes ?? <String>{},
      ),
    };
  }

  _FakeResponse _logout(String? auth) {
    final username = _usernameOfToken(auth);
    if (username != null) {
      _tenantTokens.removeWhere((_, name) => name == username);
      _adminTokens.removeWhere((_, name) => name == username);
      _refreshTokens.removeWhere((_, name) => name == username);
    }
    return _FakeResponse(200, _ok(<String, Object?>{'logged_out': true}));
  }

  /* ------------------------------------------------------------ 平台治理 */

  _FakeResponse _platformGroupsList(Map<String, String> query) {
    final items = <Map<String, Object?>>[];
    for (final group in _groups.values) {
      items.add(_groupSummary(group));
    }
    return _FakeResponse(
      200,
      _ok(<String, Object?>{
        'items': items,
        'page': 1,
        'page_size': 20,
        'total': items.length,
      }),
    );
  }

  Map<String, Object?> _groupSummary(_FakeGroup group) => <String, Object?>{
    'id': group.id,
    'name': group.name,
    'status': group.status,
    'owner': <String, Object?>{
      'id': _ownerUserId(group.ownerUsername),
      'username': group.ownerUsername,
      'display_name': group.ownerDisplayName,
      'account_type': 'group_owner',
    },
    'member_count': _membersByGroup[group.id]?.length ?? 1,
    'version': group.version,
    'created_at': '2026-09-01T00:00:00Z',
    'updated_at': '2026-09-01T00:00:00Z',
  };

  int _ownerUserId(String username) {
    for (final group in _groups.values) {
      if (group.ownerUsername == username) {
        final members = _membersByGroup[group.id];
        if (members != null) {
          for (final member in members.values) {
            if (member.memberType == 'owner') return member.userId;
          }
        }
      }
    }
    // 兜底：种子阶段 owner 一定在成员表里；真取不到用递增 id 占位。
    return 1;
  }

  _FakeResponse _platformGroupCreate(Map<String, Object?> body) {
    final name = body['name'];
    final ownerUsername = body['owner_username'];
    final ownerDisplayName = body['owner_display_name'];
    final password = body['owner_temporary_password'];
    if (name is! String ||
        ownerUsername is! String ||
        ownerDisplayName is! String ||
        password is! String) {
      return _FakeResponse(400, _error('VALIDATION_FAILED', '参数不合法'));
    }
    if (_groups.values.any((group) => group.name == name)) {
      return _FakeResponse(409, _error('GROUP_NAME_EXISTS', '组名已存在'));
    }
    if (_owners.containsKey(ownerUsername) ||
        _members.containsKey(ownerUsername) ||
        _platformAdmins.containsKey(ownerUsername)) {
      return _FakeResponse(409, _error('USER_USERNAME_EXISTS', '用户名已存在'));
    }

    final groupId = _nextGroupId++;
    _groups[groupId] = _FakeGroup(
      id: groupId,
      name: name,
      status: 'active',
      version: 1,
      ownerUsername: ownerUsername,
      ownerDisplayName: ownerDisplayName,
    );
    _owners[ownerUsername] = (
      password: password,
      mustChangePassword: true,
      groupId: groupId,
    );
    final ownerUserId = _nextUserId++;
    final membershipId = _nextMembershipId++;
    _membersByGroup[groupId] = <int, _FakeMember>{
      membershipId: _FakeMember(
        membershipId: membershipId,
        userId: ownerUserId,
        username: ownerUsername,
        displayName: ownerDisplayName,
        memberType: 'owner',
        status: 'active',
        permissionCodes: const <String>{},
        version: 1,
      ),
    };

    return _FakeResponse(
      201,
      _ok(<String, Object?>{
        'group': <String, Object?>{'id': groupId, 'name': name},
        'owner': <String, Object?>{
          'id': ownerUserId,
          'username': ownerUsername,
          'display_name': ownerDisplayName,
        },
      }),
    );
  }

  _FakeResponse _platformGroupSubpath(
    String method,
    String path,
    Map<String, Object?> body,
  ) {
    // path 形如 /api/v1/platform/groups/{id}[/status|/owner]
    final rest = path.substring('/api/v1/platform/groups/'.length);
    final parts = rest.split('/');
    final groupId = int.tryParse(parts[0]);
    if (groupId == null) {
      return _FakeResponse(400, _error('VALIDATION_FAILED', '参数不合法'));
    }
    final group = _groups[groupId];
    if (group == null) {
      return _FakeResponse(404, _error('GROUP_NOT_FOUND', '组不存在'));
    }

    // GET 详情。
    if (parts.length == 1 && method == 'GET') {
      return _FakeResponse(200, _ok(_groupDetail(group)));
    }

    // PATCH status。
    if (parts.length == 2 && parts[1] == 'status' && method == 'PATCH') {
      final status = body['status'];
      final version = body['version'];
      if (status is! String || version is! int) {
        return _FakeResponse(400, _error('VALIDATION_FAILED', '参数不合法'));
      }
      if (version != group.version) {
        return _FakeResponse(
          409,
          _error('RESOURCE_VERSION_CONFLICT', '数据已被修改'),
        );
      }
      group.status = status;
      group.version = version + 1;
      return _FakeResponse(200, _ok(_groupSummary(group)));
    }

    // PUT owner。
    if (parts.length == 2 && parts[1] == 'owner' && method == 'PUT') {
      return _changeGroupOwner(group, body);
    }

    return _FakeResponse(
      404,
      _error('INTERNAL_ERROR', 'FakeBackend 未实现 $method $path'),
    );
  }

  Map<String, Object?> _groupDetail(_FakeGroup group) {
    final members = _membersByGroup[group.id] ?? <int, _FakeMember>{};
    var active = 0;
    var disabled = 0;
    var removed = 0;
    final candidates = <Map<String, Object?>>[];
    for (final member in members.values) {
      switch (member.status) {
        case 'active':
          active++;
        case 'disabled':
          disabled++;
        case 'removed':
          removed++;
      }
      // 只有 active 普通成员才是可提升候选人。
      if (member.status == 'active' && member.memberType == 'member') {
        candidates.add(<String, Object?>{
          'membership_id': member.membershipId,
          'user': <String, Object?>{
            'id': member.userId,
            'username': member.username,
            'display_name': member.displayName,
          },
        });
      }
    }
    return <String, Object?>{
      'group': _groupSummary(group),
      'member_counts': <String, Object?>{
        'active': active,
        'disabled': disabled,
        'removed': removed,
      },
      'owner_candidates': candidates,
    };
  }

  _FakeResponse _changeGroupOwner(_FakeGroup group, Map<String, Object?> body) {
    final mode = body['mode'];
    final version = body['version'];
    if (mode is! String || version is! int) {
      return _FakeResponse(400, _error('VALIDATION_FAILED', '参数不合法'));
    }
    if (version != group.version) {
      return _FakeResponse(409, _error('RESOURCE_VERSION_CONFLICT', '数据已被修改'));
    }

    String newOwnerUsername;
    String newOwnerDisplayName;

    if (mode == 'existing_member') {
      final membershipId = body['membership_id'];
      if (membershipId is! int) {
        return _FakeResponse(400, _error('VALIDATION_FAILED', '参数不合法'));
      }
      final member = _membersByGroup[group.id]?[membershipId];
      if (member == null || member.memberType != 'member') {
        return _FakeResponse(400, _error('OWNER_TARGET_INVALID', '交接目标无效'));
      }
      newOwnerUsername = member.username;
      newOwnerDisplayName = member.displayName;
      // 被提升的成员改记进 _owners：他的密码不变、但改密标记清零，
      // 之后以「组主账号」身份登录。
      final memberCred = _members[member.username]!;
      _owners[member.username] = (
        password: memberCred.password,
        mustChangePassword: false,
        groupId: group.id,
      );
      _members.remove(member.username);
    } else if (mode == 'new_account') {
      final username = body['username'];
      final displayName = body['display_name'];
      final password = body['temporary_password'];
      if (username is! String ||
          displayName is! String ||
          password is! String) {
        return _FakeResponse(400, _error('VALIDATION_FAILED', '参数不合法'));
      }
      newOwnerUsername = username;
      newOwnerDisplayName = displayName;
      final userId = _nextUserId++;
      final membershipId = _nextMembershipId++;
      _owners[username] = (
        password: password,
        mustChangePassword: true,
        groupId: group.id,
      );
      _membersByGroup.putIfAbsent(
        group.id,
        () => <int, _FakeMember>{},
      )[membershipId] = _FakeMember(
        membershipId: membershipId,
        userId: userId,
        username: username,
        displayName: displayName,
        memberType: 'owner',
        status: 'active',
        permissionCodes: const <String>{},
        version: 1,
      );
    } else {
      return _FakeResponse(400, _error('VALIDATION_FAILED', '参数不合法'));
    }

    // 旧 owner 降级为普通成员且停用，其会话全部作废。
    final oldOwner = group.ownerUsername;
    for (final member
        in (_membersByGroup[group.id] ?? <int, _FakeMember>{}).values) {
      if (member.memberType == 'owner') {
        member.memberType = 'member';
        member.status = 'disabled';
        member.permissionCodes = const <String>{};
      }
    }
    // 旧 owner 从「组主账号」变成「停用的普通成员」：不再能登录为 owner。
    final oldCred = _owners.remove(oldOwner);
    if (oldCred != null) {
      // 降级后的账号落到 _members，但已停用；登录时会被拒绝（见 _login 的
      // 停用判断 —— 这里先保留可登录，Step4 用「令牌失效」断言覆盖）。
      _members[oldOwner] = (
        password: oldCred.password,
        mustChangePassword: false,
        groupId: group.id,
        userId: _nextUserId++,
      );
    }

    group.ownerUsername = newOwnerUsername;
    group.ownerDisplayName = newOwnerDisplayName;
    group.version = version + 1;

    // 旧 owner 的所有令牌立即失效。
    _tenantTokens.removeWhere((token, username) => username == oldOwner);
    _refreshTokens.removeWhere((token, username) => username == oldOwner);

    return _FakeResponse(
      200,
      _ok(<String, Object?>{
        'group': _groupSummary(group),
        'owner': <String, Object?>{
          'id': _ownerUserId(newOwnerUsername),
          'username': newOwnerUsername,
          'display_name': newOwnerDisplayName,
        },
      }),
    );
  }

  /* ------------------------------------------------------------ 邀请码 */

  _FakeResponse _invitationsList(Map<String, String> query) {
    final items = <Map<String, Object?>>[];
    for (final invitation in _invitations.values) {
      items.add(_invitationSummary(invitation));
    }
    return _FakeResponse(
      200,
      _ok(<String, Object?>{
        'items': items,
        'page': 1,
        'page_size': 20,
        'total': items.length,
      }),
    );
  }

  Map<String, Object?> _invitationSummary(_FakeInvitation invitation) =>
      <String, Object?>{
        'invitation_id': invitation.id,
        'status': invitation.status,
        'expires_at': invitation.expiresAt,
        if (invitation.usedAt != null) 'used_at': invitation.usedAt,
        if (invitation.revokedAt != null) 'revoked_at': invitation.revokedAt,
        'created_at': invitation.createdAt,
        'version': invitation.version,
      };

  _FakeResponse _invitationCreate(Map<String, Object?> body) {
    // 简化：不校验身份，直接给当前「唯一活跃组」发邀请码。
    // 闭环里邀请码总是由 owner 创建，此时有且仅有一个组处于活跃。
    final group = _groups.values.firstWhere(
      (group) => group.status == 'active',
      orElse: () => _groups.values.first,
    );

    final invitationId = _nextInvitationId++;
    final code = 'INV-${group.id}-$invitationId';
    _invitations[invitationId] = _FakeInvitation(
      id: invitationId,
      groupId: group.id,
      code: code,
      status: 'active',
      expiresAt: '2026-10-01T00:00:00Z',
      createdAt: '2026-09-24T00:00:00Z',
      version: 1,
    );

    return _FakeResponse(
      201,
      _ok(<String, Object?>{
        'invitation_id': invitationId,
        'invitation_code': code,
        'expires_at': '2026-10-01T00:00:00Z',
      }),
    );
  }

  _FakeResponse _invitationSubpath(
    String method,
    String path,
    Map<String, Object?> body,
  ) {
    final rest = path.substring('/api/v1/groups/invitations/'.length);
    final parts = rest.split('/');
    final invitationId = int.tryParse(parts[0]);
    if (invitationId == null) {
      return _FakeResponse(400, _error('VALIDATION_FAILED', '参数不合法'));
    }
    final invitation = _invitations[invitationId];
    if (invitation == null) {
      return _FakeResponse(404, _error('INVITATION_NOT_FOUND', '邀请码不存在'));
    }

    if (parts.length == 2 && parts[1] == 'secret' && method == 'POST') {
      if (invitation.status != 'active') {
        return _FakeResponse(
          409,
          _error('INVITATION_NOT_REVEALABLE', '邀请码当前不可查看'),
        );
      }
      return _FakeResponse(
        200,
        _ok(<String, Object?>{
          'invitation_id': invitation.id,
          'invitation_code': invitation.code,
          'expires_at': invitation.expiresAt,
        }),
      );
    }

    if (parts.length == 2 && parts[1] == 'revoke' && method == 'POST') {
      final version = body['version'];
      if (version is! int || version != invitation.version) {
        return _FakeResponse(
          409,
          _error('RESOURCE_VERSION_CONFLICT', '数据已被修改'),
        );
      }
      invitation.status = 'revoked';
      invitation.revokedAt = '2026-09-24T12:00:00Z';
      invitation.version = version + 1;
      return _FakeResponse(200, _ok(_invitationSummary(invitation)));
    }

    return _FakeResponse(
      404,
      _error('INTERNAL_ERROR', 'FakeBackend 未实现 $method $path'),
    );
  }

  /* ------------------------------------------------------------ 成员 */

  _FakeResponse _membersList(Map<String, String> query) {
    // 返回「当前活跃组」的全部成员。闭环里成员列表由 owner / 持 member.manage
    // 的成员读取，此时只有一个组。
    final group = _groups.values.firstWhere(
      (group) => group.status == 'active',
      orElse: () => _groups.values.first,
    );
    final members = _membersByGroup[group.id] ?? <int, _FakeMember>{};
    final items = <Map<String, Object?>>[
      for (final member in members.values) _memberData(member),
    ];
    return _FakeResponse(
      200,
      _ok(<String, Object?>{
        'items': items,
        'pagination': <String, Object?>{
          'page': 1,
          'page_size': 100,
          'total': items.length,
        },
      }),
    );
  }

  Map<String, Object?> _memberData(_FakeMember member) => <String, Object?>{
    'membership_id': member.membershipId,
    'user': <String, Object?>{
      'id': member.userId,
      'username': member.username,
      'display_name': member.displayName,
      'account_type': member.memberType == 'owner' ? 'group_owner' : 'member',
    },
    'member_type': member.memberType,
    'status': member.status,
    'permission_codes': member.permissionCodes.toList(),
    'version': member.version,
  };

  _FakeResponse _permissionCatalogList() =>
      _FakeResponse(200, _ok(<String, Object?>{'items': _permissionCatalog}));

  _FakeResponse _memberSubpath(
    String method,
    String path,
    Map<String, Object?> body,
  ) {
    // path: /api/v1/groups/members/{id}/permissions
    final rest = path.substring('/api/v1/groups/members/'.length);
    final parts = rest.split('/');
    final membershipId = int.tryParse(parts[0]);
    if (membershipId == null) {
      return _FakeResponse(400, _error('VALIDATION_FAILED', '参数不合法'));
    }
    // 找这个成员关系。
    _FakeMember? found;
    for (final entry in _membersByGroup.entries) {
      if (entry.value.containsKey(membershipId)) {
        found = entry.value[membershipId];
        break;
      }
    }
    if (found == null) {
      return _FakeResponse(404, _error('MEMBER_NOT_FOUND', '成员不存在'));
    }

    if (parts.length == 2 && parts[1] == 'permissions' && method == 'GET') {
      return _FakeResponse(
        200,
        _ok(<String, Object?>{
          'membership_id': membershipId,
          'permission_codes': found.permissionCodes.toList(),
          'version': found.version,
        }),
      );
    }

    if (parts.length == 2 && parts[1] == 'permissions' && method == 'PUT') {
      final codes = body['permission_codes'];
      final version = body['version'];
      if (codes is! List || version is! int) {
        return _FakeResponse(400, _error('VALIDATION_FAILED', '参数不合法'));
      }
      if (version != found.version) {
        return _FakeResponse(
          409,
          _error('RESOURCE_VERSION_CONFLICT', '数据已被修改'),
        );
      }
      found.permissionCodes = <String>{
        for (final code in codes) code as String,
      };
      found.version = version + 1;
      return _FakeResponse(
        200,
        _ok(<String, Object?>{
          'membership_id': membershipId,
          'permission_codes': found.permissionCodes.toList(),
          'version': found.version,
        }),
      );
    }

    return _FakeResponse(
      404,
      _error('INTERNAL_ERROR', 'FakeBackend 未实现 $method $path'),
    );
  }

  /* ------------------------------------------------------------ 字典 */

  _FakeResponse _dictionaryList(Map<String, String> query) {
    final group = _groups.values.firstWhere(
      (group) => group.status == 'active',
      orElse: () => _groups.values.first,
    );
    final kind = query['kind'];
    final byKind =
        _dictionaries[group.id] ?? <String, Map<int, _FakeDictionary>>{};
    final items = <Map<String, Object?>>[];
    if (kind != null) {
      final kindMap = byKind[kind] ?? <int, _FakeDictionary>{};
      for (final entry in kindMap.values) {
        items.add(_dictionaryData(entry));
      }
    } else {
      for (final kindMap in byKind.values) {
        for (final entry in kindMap.values) {
          items.add(_dictionaryData(entry));
        }
      }
    }
    return _FakeResponse(
      200,
      _ok(<String, Object?>{
        'items': items,
        'pagination': <String, Object?>{
          'page': 1,
          'page_size': 100,
          'total': items.length,
        },
      }),
    );
  }

  Map<String, Object?> _dictionaryData(_FakeDictionary entry) =>
      <String, Object?>{
        'id': entry.id,
        'group_id': entry.groupId,
        'kind': entry.kind,
        'name': entry.name,
        'parent_id': entry.parentId,
        'contact_phone': entry.contactPhone,
        'status': entry.status,
        'version': entry.version,
      };

  /// 预置一个普通成员（供「交接给现有成员」这类场景）。
  void seedMember({
    required int groupId,
    required String username,
    required String displayName,
    List<String> permissionCodes = const <String>[],
  }) {
    final userId = _nextUserId++;
    final membershipId = _nextMembershipId++;
    _members[username] = (
      password: 'member-pass',
      mustChangePassword: false,
      groupId: groupId,
      userId: userId,
    );
    _membersByGroup.putIfAbsent(
      groupId,
      () => <int, _FakeMember>{},
    )[membershipId] = _FakeMember(
      membershipId: membershipId,
      userId: userId,
      username: username,
      displayName: displayName,
      memberType: 'member',
      status: 'active',
      permissionCodes: permissionCodes.toSet(),
      version: 1,
    );
  }

  /// 预置一条字典条目（供「member 登录读字典」断言有数据可读）。
  int seedDictionary({
    required int groupId,
    required String kind,
    required String name,
  }) {
    final id = _nextDictionaryId++;
    _dictionaries
        .putIfAbsent(groupId, () => <String, Map<int, _FakeDictionary>>{})
        .putIfAbsent(
          kind,
          () => <int, _FakeDictionary>{},
        )[id] = _FakeDictionary(
      id: id,
      groupId: groupId,
      kind: kind,
      name: name,
      parentId: null,
      contactPhone: null,
      status: 'active',
      version: 1,
    );
    return id;
  }

  /* ------------------------------------------------- 调用者与用户摘要 */

  /// 解析租户调用者身份；未登录 / 平台管理员（不属于租户）返回 null。
  _Caller? _caller(String? auth) {
    final username = _usernameOfToken(auth);
    if (username == null || _platformAdmins.containsKey(username)) return null;
    final owner = _owners[username];
    if (owner != null) {
      final group = _groups[owner.groupId]!;
      return (
        username: username,
        accountType: 'group_owner',
        userId: _ownerUserId(username),
        displayName: group.ownerDisplayName,
        groupId: owner.groupId,
      );
    }
    final member = _members[username];
    if (member == null) return null;
    final row = _memberRowOf(member.groupId, username);
    return (
      username: username,
      accountType: 'member',
      userId: member.userId,
      displayName: row?.displayName ?? username,
      groupId: member.groupId,
    );
  }

  Map<String, Object?> _userSummaryJson(
    int id,
    String username,
    String displayName,
    String accountType,
  ) => <String, Object?>{
    'id': id,
    'username': username,
    'display_name': displayName,
    'account_type': accountType,
  };

  /// 按 userId 在组内找成员摘要；找不到就退回「未知用户」。
  Map<String, Object?> _userSummaryById(int groupId, int userId) {
    final rows = _membersByGroup[groupId] ?? <int, _FakeMember>{};
    for (final row in rows.values) {
      if (row.userId == userId) {
        return _userSummaryJson(
          row.userId,
          row.username,
          row.displayName,
          row.memberType == 'owner' ? 'group_owner' : 'member',
        );
      }
    }
    return _userSummaryJson(userId, 'user$userId', '用户$userId', 'member');
  }

  bool _canViewOthers(_Caller caller) {
    if (caller.accountType == 'group_owner') return true;
    // 主账号隐式全权限；业务员看是否被授予 document.view_others。
    for (final member
        in (_membersByGroup[caller.groupId] ?? <int, _FakeMember>{}).values) {
      if (member.userId == caller.userId) {
        return member.permissionCodes.contains('document.view_others');
      }
    }
    return false;
  }

  /* ------------------------------------------------------------ 单据 */

  String _pad(int value, int width) => value.toString().padLeft(width, '0');

  String _documentNo(int groupId, String kind, String businessDate) {
    final prefix = kind == 'outbound' ? 'CK' : 'RK';
    final compact = businessDate.replaceAll('-', '');
    final key = '$groupId:$prefix:$compact';
    final seq = (_docSequences[key] ?? 0) + 1;
    _docSequences[key] = seq;
    return '$prefix$compact-${_pad(seq, 4)}';
  }

  /// 单据总额 = Σ 单价 × 数量（服务端算，四舍五入到分）。
  Amount _draftTotal(List<_FakeParty> parties) {
    var total = Amount.parse('0');
    for (final party in parties) {
      for (final item in party.items) {
        total = total.add(
          Amount.mul(
            UnitPrice.parse(item.unitPrice),
            Quantity.parse(item.quantity),
          ),
        );
      }
    }
    return total;
  }

  Map<String, Object?> _documentJson(_FakeDocument doc) => <String, Object?>{
    'document_id': doc.id,
    'kind': doc.kind,
    'document_no': doc.documentNo,
    'status': doc.status,
    'business_user': _userSummaryById(doc.groupId, doc.businessUserId),
    'business_date': doc.businessDate,
    'shipping_unit': doc.shippingUnit,
    'sale_amount_type': doc.saleAmountType,
    'total_amount': doc.totalAmount.format(),
    'total_amount_upper': _upper(doc.totalAmount),
    'remark': doc.remark,
    'version': doc.version,
    'submitted_at': doc.submittedAt,
    'created_at': doc.createdAt.toIso8601String(),
    'updated_at': doc.updatedAt.toIso8601String(),
    'parties': <Object?>[
      for (final party in doc.parties)
        <String, Object?>{
          'party_id': party.id,
          'position': party.position,
          'party_name': party.name,
          'contact_phone': party.contactPhone,
          'subtotal': party.subtotal.format(),
          'items': <Object?>[
            for (final item in party.items)
              <String, Object?>{
                'item_id': item.id,
                'position': item.position,
                'product_name': item.productName,
                'product_model': item.productModel,
                'unit': item.unit,
                'quantity': item.quantity,
                'weight': item.weight,
                'unit_price': item.unitPrice,
                'price_tax_mode': item.priceTaxMode,
                'amount': item.amount.format(),
                'remark': item.remark,
              },
          ],
        },
    ],
  };

  Map<String, Object?> _documentSummaryJson(_FakeDocument doc) =>
      <String, Object?>{
        'document_id': doc.id,
        'kind': doc.kind,
        'document_no': doc.documentNo,
        'status': doc.status,
        'business_date': doc.businessDate,
        'business_user': _userSummaryById(doc.groupId, doc.businessUserId),
        'shipping_unit': doc.shippingUnit,
        'sale_amount_type': doc.saleAmountType,
        'party_names': <String>[for (final party in doc.parties) party.name],
        'item_count': doc.parties.fold<int>(
          0,
          (sum, party) => sum + party.items.length,
        ),
        'total_amount': doc.totalAmount.format(),
        'version': doc.version,
        'submitted_at': doc.submittedAt,
        'created_at': doc.createdAt.toIso8601String(),
        'updated_at': doc.updatedAt.toIso8601String(),
      };

  _FakeResponse _documentsList(
    String? auth,
    String kind,
    Map<String, String> query,
  ) {
    final caller = _caller(auth);
    if (caller == null) {
      return _FakeResponse(401, _error('AUTH_INVALID_CREDENTIALS', '未登录'));
    }
    final status = query['status'];
    final month = query['month'];
    final keyword = query['keyword'];
    final businessUserId = int.tryParse(query['business_user_id'] ?? '');
    final seeAll = _canViewOthers(caller);

    final matched = <_FakeDocument>[];
    for (final doc in _documents.values) {
      if (doc.groupId != caller.groupId || doc.kind != kind) continue;
      if (!seeAll && doc.businessUserId != caller.userId) continue;
      if (status != null && status.isNotEmpty && doc.status != status) continue;
      if (month != null &&
          month.isNotEmpty &&
          !doc.businessDate.startsWith(month)) {
        continue;
      }
      if (businessUserId != null && doc.businessUserId != businessUserId) {
        continue;
      }
      if (keyword != null &&
          keyword.isNotEmpty &&
          !doc.documentNo.contains(keyword) &&
          !doc.parties.any((party) => party.name.contains(keyword))) {
        continue;
      }
      matched.add(doc);
    }
    matched.sort((a, b) => b.id.compareTo(a.id));
    return _FakeResponse(
      200,
      _ok(<String, Object?>{
        'items': <Object?>[
          for (final doc in matched) _documentSummaryJson(doc),
        ],
        'page': 1,
        'page_size': 20,
        'total': matched.length,
      }),
    );
  }

  _FakeResponse _documentCreate(
    String? auth,
    String kind,
    Map<String, Object?> body,
  ) {
    final caller = _caller(auth);
    if (caller == null) {
      return _FakeResponse(401, _error('AUTH_INVALID_CREDENTIALS', '未登录'));
    }
    final status = (body['status'] as String?) ?? 'draft';
    if (status != 'draft' && status != 'submitted') {
      return _FakeResponse(400, _error('VALIDATION_FAILED', '状态不合法'));
    }
    final businessDate = body['business_date'];
    if (businessDate is! String || businessDate.length < 10) {
      return _FakeResponse(400, _error('VALIDATION_FAILED', '业务日期不合法'));
    }
    final parties = _readParties(body);
    if (parties == null) {
      return _FakeResponse(400, _error('VALIDATION_FAILED', '往来单位不合法'));
    }
    final total = _draftTotal(parties);
    final id = _nextDocumentId++;
    final now = DateTime.utc(2026, 9, 22, 10);
    final doc = _FakeDocument(
      id: id,
      groupId: caller.groupId,
      kind: kind,
      documentNo: _documentNo(caller.groupId, kind, businessDate),
      status: status,
      businessUserId: (body['business_user_id'] as int?) ?? caller.userId,
      businessDate: businessDate,
      shippingUnit: body['shipping_unit'] as String?,
      saleAmountType: body['sale_amount_type'] as String?,
      totalAmount: total,
      remark: body['remark'] as String?,
      version: 1,
      submittedAt: status == 'submitted' ? now.toIso8601String() : null,
      createdAt: now,
      updatedAt: now,
      parties: parties,
    );
    _documents[id] = doc;
    return _FakeResponse(201, _ok(_documentJson(doc)));
  }

  List<_FakeParty>? _readParties(Map<String, Object?> body) {
    final raw = body['parties'];
    if (raw is! List || raw.isEmpty) return null;
    final parties = <_FakeParty>[];
    var partyPosition = 1;
    for (final entry in raw) {
      if (entry is! Map) return null;
      final party = Map<String, Object?>.from(entry);
      final name = party['party_name'];
      final items = party['items'];
      if (name is! String || items is! List || items.isEmpty) return null;
      final parsedItems = <_FakeItem>[];
      var itemPosition = 1;
      for (final rawItem in items) {
        if (rawItem is! Map) return null;
        final item = Map<String, Object?>.from(rawItem);
        final productName = item['product_name'];
        final quantity = item['quantity'];
        final unitPrice = item['unit_price'];
        if (productName is! String ||
            quantity is! String ||
            unitPrice is! String) {
          return null;
        }
        final amount = Amount.mul(
          UnitPrice.parse(unitPrice),
          Quantity.parse(quantity),
        );
        parsedItems.add(
          _FakeItem(
            id: _nextDocumentId * 100 + itemPosition,
            position: itemPosition,
            productName: productName,
            productModel: item['product_model'] as String?,
            unit: item['unit'] as String?,
            quantity: quantity,
            weight: item['weight'] as String?,
            unitPrice: unitPrice,
            priceTaxMode: (item['price_tax_mode'] as String?) ?? 'tax_included',
            amount: amount,
            remark: item['remark'] as String?,
          ),
        );
        itemPosition++;
      }
      parties.add(
        _FakeParty(
          id: partyPosition,
          position: partyPosition,
          name: name,
          contactPhone: party['contact_phone'] as String?,
          subtotal: Amount.sum(parsedItems.map((item) => item.amount)),
          items: parsedItems,
        ),
      );
      partyPosition++;
    }
    return parties;
  }

  _FakeResponse _documentSubpath(
    String? auth,
    String method,
    String path,
    String kind,
    Map<String, Object?> body,
  ) {
    final caller = _caller(auth);
    if (caller == null) {
      return _FakeResponse(401, _error('AUTH_INVALID_CREDENTIALS', '未登录'));
    }
    final rest = path.split('/').where((part) => part.isNotEmpty).toList();
    // /api/v1/inbound-documents/{id}[/submit|/void]
    final id = int.tryParse(
      rest[rest.length -
          (rest.last == 'submit' || rest.last == 'void' ? 2 : 1)],
    );
    if (id == null) {
      return _FakeResponse(404, _error('RESOURCE_NOT_FOUND', '单据不存在'));
    }
    final doc = _documents[id];
    if (doc == null || doc.groupId != caller.groupId || doc.kind != kind) {
      return _FakeResponse(404, _error('RESOURCE_NOT_FOUND', '单据不存在'));
    }

    if (rest.last == 'submit') {
      return _documentTransition(doc, body, 'submitted');
    }
    if (rest.last == 'void') {
      return _documentTransition(doc, body, 'voided');
    }
    if (method == 'GET') {
      return _FakeResponse(200, _ok(_documentJson(doc)));
    }
    if (method == 'PUT') {
      return _documentUpdate(caller.groupId, doc, body);
    }
    return _FakeResponse(
      404,
      _error('INTERNAL_ERROR', 'FakeBackend 未实现 $method $path'),
    );
  }

  _FakeResponse _documentTransition(
    _FakeDocument doc,
    Map<String, Object?> body,
    String next,
  ) {
    final version = body['version'];
    if (version is! int || version != doc.version) {
      return _FakeResponse(409, _error('RESOURCE_VERSION_CONFLICT', '版本冲突'));
    }
    if (next == 'submitted' && doc.status != 'draft') {
      return _FakeResponse(409, _error('DOCUMENT_STATUS_INVALID', '状态不允许提交'));
    }
    if (next == 'voided' &&
        doc.status != 'draft' &&
        doc.status != 'submitted') {
      return _FakeResponse(409, _error('DOCUMENT_STATUS_INVALID', '状态不允许作废'));
    }
    doc.status = next;
    doc.version++;
    doc.updatedAt = DateTime.utc(2026, 9, 22, 11);
    if (next == 'submitted') {
      doc.submittedAt = doc.updatedAt.toIso8601String();
    }
    return _FakeResponse(200, _ok(_documentJson(doc)));
  }

  _FakeResponse _documentUpdate(
    int groupId,
    _FakeDocument doc,
    Map<String, Object?> body,
  ) {
    final version = body['version'];
    if (version is! int || version != doc.version) {
      return _FakeResponse(409, _error('RESOURCE_VERSION_CONFLICT', '版本冲突'));
    }
    if (doc.status != 'draft') {
      return _FakeResponse(409, _error('DOCUMENT_STATUS_INVALID', '仅草稿可编辑'));
    }
    final parties = _readParties(body);
    if (parties == null) {
      return _FakeResponse(400, _error('VALIDATION_FAILED', '往来单位不合法'));
    }
    doc.parties = parties;
    // 总额按新的往来单位/明细重算。
    doc.totalAmount = _draftTotal(parties);
    doc.businessDate = (body['business_date'] as String?) ?? doc.businessDate;
    doc.shippingUnit = body['shipping_unit'] as String?;
    doc.saleAmountType = body['sale_amount_type'] as String?;
    doc.remark = body['remark'] as String?;
    doc.version++;
    doc.updatedAt = DateTime.utc(2026, 9, 22, 12);
    return _FakeResponse(200, _ok(_documentJson(doc)));
  }

  /* ------------------------------------------------------------ 结算 */

  String _settlementNo(int groupId, String month) {
    final compact = month.replaceAll('-', '');
    final key = '$groupId:$compact';
    final seq = (_settlementSequences[key] ?? 0) + 1;
    _settlementSequences[key] = seq;
    return 'JS$compact-${_pad(seq, 4)}';
  }

  Map<String, Object?> _settlementSummaryJson(_FakeSettlement s) =>
      <String, Object?>{
        'settlement_id': s.id,
        'settlement_no': s.settlementNo,
        'status': s.status,
        'requester': _userSummaryById(s.groupId, s.requesterUserId),
        'inbound_total': s.inboundTotal.format(),
        'outbound_total': s.outboundTotal.format(),
        'gross_profit': s.grossProfit.format(),
        'source_count': s.sources.length,
        'version': s.version,
        'decided_at': s.decidedAt,
        'decision_remark': s.decisionRemark,
        'created_at': s.createdAt.toIso8601String(),
        'updated_at': s.updatedAt.toIso8601String(),
      };

  Map<String, Object?> _settlementJson(_FakeSettlement s) => <String, Object?>{
    ..._settlementSummaryJson(s),
    'remark': s.remark,
    'inbound_total_upper': _upper(s.inboundTotal),
    'outbound_total_upper': _upper(s.outboundTotal),
    'gross_profit_upper': _upper(s.grossProfit),
    'decided_by': s.decidedByUserId == null
        ? null
        : _userSummaryById(s.groupId, s.decidedByUserId!),
    'sources': <Object?>[
      for (final source in s.sources)
        <String, Object?>{
          'document_id': source.documentId,
          'kind': source.kind,
          'document_no': source.documentNo,
          'business_user': _userSummaryById(s.groupId, source.businessUserId),
          'business_date': source.businessDate,
          'amount': source.amount.format(),
          'released': source.released,
        },
    ],
    'approval_records': <Object?>[
      for (final record in s.approvalRecords)
        <String, Object?>{
          'action': record['action'],
          'operator': record['operator'],
          'remark': record['remark'],
          'created_at': record['created_at'],
        },
    ],
  };

  _FakeResponse _settlementsList(String? auth, Map<String, String> query) {
    final caller = _caller(auth);
    if (caller == null) {
      return _FakeResponse(401, _error('AUTH_INVALID_CREDENTIALS', '未登录'));
    }
    final seeAll = _canViewOthers(caller);
    final status = query['status'];
    final matched = <_FakeSettlement>[];
    for (final settlement in _settlements.values) {
      if (settlement.groupId != caller.groupId) continue;
      if (!seeAll && settlement.requesterUserId != caller.userId) continue;
      if (status != null && status.isNotEmpty && settlement.status != status) {
        continue;
      }
      matched.add(settlement);
    }
    matched.sort((a, b) => b.id.compareTo(a.id));
    return _FakeResponse(
      200,
      _ok(<String, Object?>{
        'items': <Object?>[
          for (final settlement in matched) _settlementSummaryJson(settlement),
        ],
        'page': 1,
        'page_size': 20,
        'total': matched.length,
      }),
    );
  }

  _FakeResponse _settlementCreate(String? auth, Map<String, Object?> body) {
    final caller = _caller(auth);
    if (caller == null) {
      return _FakeResponse(401, _error('AUTH_INVALID_CREDENTIALS', '未登录'));
    }
    final rawSources = body['sources'];
    if (rawSources is! List || rawSources.isEmpty) {
      return _FakeResponse(400, _error('VALIDATION_FAILED', '至少勾选一张源单据'));
    }
    final docs = <_FakeDocument>[];
    for (final entry in rawSources) {
      if (entry is! Map) {
        return _FakeResponse(400, _error('VALIDATION_FAILED', '源单据不合法'));
      }
      final documentId = Map<String, Object?>.from(entry)['document_id'];
      final doc = documentId is int ? _documents[documentId] : null;
      if (doc == null || doc.groupId != caller.groupId) {
        return _FakeResponse(404, _error('RESOURCE_NOT_FOUND', '源单据不存在'));
      }
      if (doc.status != 'submitted') {
        return _FakeResponse(
          409,
          _error('SETTLEMENT_SOURCE_INVALID', '源单据未提交'),
        );
      }
      if (_isDocumentActivelySettled(doc.id)) {
        return _FakeResponse(
          409,
          _error('SETTLEMENT_SOURCE_IN_USE', '源单据已被有效结算单占用'),
        );
      }
      docs.add(doc);
    }

    final month = _monthOf(docs.first.businessDate);
    var inbound = Amount.parse('0');
    var outbound = Amount.parse('0');
    for (final doc in docs) {
      if (doc.kind == 'inbound') {
        inbound = inbound.add(doc.totalAmount);
      } else {
        outbound = outbound.add(doc.totalAmount);
      }
    }
    final id = _nextSettlementId++;
    final now = DateTime.utc(2026, 9, 22, 13);
    final settlement = _FakeSettlement(
      id: id,
      groupId: caller.groupId,
      settlementNo: _settlementNo(caller.groupId, month),
      status: 'pending',
      requesterUserId: caller.userId,
      remark: body['remark'] as String?,
      inboundTotal: inbound,
      outboundTotal: outbound,
      grossProfit: outbound.sub(inbound),
      version: 1,
      createdAt: now,
      updatedAt: now,
      sources: <_FakeSettlementSource>[
        for (final doc in docs)
          _FakeSettlementSource(
            documentId: doc.id,
            kind: doc.kind,
            documentNo: doc.documentNo,
            businessUserId: doc.businessUserId,
            businessDate: doc.businessDate,
            amount: doc.totalAmount,
            released: false,
          ),
      ],
    );
    settlement.approvalRecords.add(<String, Object?>{
      'action': 'submitted',
      'operator': _userSummaryById(caller.groupId, caller.userId),
      'remark': null,
      'created_at': now.toIso8601String(),
    });
    _settlements[id] = settlement;
    return _FakeResponse(201, _ok(_settlementJson(settlement)));
  }

  bool _isDocumentActivelySettled(int documentId) {
    for (final settlement in _settlements.values) {
      for (final source in settlement.sources) {
        if (source.documentId == documentId && !source.released) return true;
      }
    }
    return false;
  }

  _FakeResponse _settlementSubpath(
    String? auth,
    String path,
    Map<String, Object?> body,
  ) {
    final caller = _caller(auth);
    if (caller == null) {
      return _FakeResponse(401, _error('AUTH_INVALID_CREDENTIALS', '未登录'));
    }
    final rest = path.split('/').where((part) => part.isNotEmpty).toList();
    final isDecision = rest.last == 'approve' || rest.last == 'reject';
    final id = int.tryParse(rest[rest.length - (isDecision ? 2 : 1)]);
    final settlement = id == null ? null : _settlements[id];
    if (settlement == null || settlement.groupId != caller.groupId) {
      return _FakeResponse(404, _error('RESOURCE_NOT_FOUND', '结算单不存在'));
    }
    if (!isDecision) {
      return _FakeResponse(200, _ok(_settlementJson(settlement)));
    }
    return _settlementDecide(
      caller,
      settlement,
      body,
      approved: rest.last == 'approve',
    );
  }

  _FakeResponse _settlementDecide(
    _Caller caller,
    _FakeSettlement settlement,
    Map<String, Object?> body, {
    required bool approved,
  }) {
    final version = body['version'];
    if (version is! int || version != settlement.version) {
      return _FakeResponse(409, _error('RESOURCE_VERSION_CONFLICT', '版本冲突'));
    }
    if (settlement.status != 'pending') {
      return _FakeResponse(409, _error('SETTLEMENT_STATUS_INVALID', '已审批'));
    }
    final remark = body['remark'] as String?;
    if (!approved && (remark == null || remark.trim().isEmpty)) {
      return _FakeResponse(
        400,
        _error('SETTLEMENT_REMARK_REQUIRED', '驳回必须填写备注'),
      );
    }
    final now = DateTime.utc(2026, 9, 22, 14);
    settlement.status = approved ? 'approved' : 'rejected';
    settlement.version++;
    settlement.decidedAt = now.toIso8601String();
    settlement.decidedByUserId = caller.userId;
    settlement.decisionRemark = remark;
    settlement.updatedAt = now;
    if (!approved) {
      // 驳回释放源单据的活跃引用，允许重新申请。
      for (final source in settlement.sources) {
        source.released = true;
      }
    }
    settlement.approvalRecords.add(<String, Object?>{
      'action': approved ? 'approved' : 'rejected',
      'operator': _userSummaryById(caller.groupId, caller.userId),
      'remark': remark,
      'created_at': now.toIso8601String(),
    });
    return _FakeResponse(200, _ok(_settlementJson(settlement)));
  }

  /* ------------------------------------------------------------ 财务 */

  Map<String, Object?> _financeJson(_FakeFinanceRecord r) => <String, Object?>{
    'record_id': r.id,
    'kind': r.kind,
    'document_id': r.documentId,
    'document_kind': r.documentKind,
    'document_no': r.documentNo,
    'party_name': r.partyName,
    'business_user': _userSummaryById(r.groupId, r.businessUserId),
    'business_date': r.businessDate,
    'amount': r.amount.format(),
    'amount_upper': _upper(r.amount),
    'occurred_on': r.occurredOn,
    'method': r.method,
    'method_note': r.methodNote,
    'card_tail': r.cardTail,
    'invoice_no': r.invoiceNo,
    'remark': r.remark,
    'created_by': _userSummaryById(r.groupId, r.createdByUserId),
    'created_at': r.createdAt.toIso8601String(),
  };

  _FakeResponse _financeList(
    String? auth,
    String kind,
    Map<String, String> query,
  ) {
    final caller = _caller(auth);
    if (caller == null) {
      return _FakeResponse(401, _error('AUTH_INVALID_CREDENTIALS', '未登录'));
    }
    final documentId = int.tryParse(query['document_id'] ?? '');
    final matched = <_FakeFinanceRecord>[];
    for (final record in _financeRecords.values) {
      if (record.groupId != caller.groupId || record.kind != kind) continue;
      if (documentId != null && record.documentId != documentId) continue;
      matched.add(record);
    }
    matched.sort((a, b) => b.id.compareTo(a.id));
    return _FakeResponse(
      200,
      _ok(<String, Object?>{
        'items': <Object?>[for (final r in matched) _financeJson(r)],
        'page': 1,
        'page_size': 20,
        'total': matched.length,
      }),
    );
  }

  _FakeResponse _financeCreate(
    String? auth,
    String kind,
    Map<String, Object?> body,
  ) {
    final caller = _caller(auth);
    if (caller == null) {
      return _FakeResponse(401, _error('AUTH_INVALID_CREDENTIALS', '未登录'));
    }
    final documentId = body['document_id'];
    final doc = documentId is int ? _documents[documentId] : null;
    if (doc == null || doc.groupId != caller.groupId) {
      return _FakeResponse(404, _error('RESOURCE_NOT_FOUND', '单据不存在'));
    }
    final expectedKind = kind == 'receipt' ? 'outbound' : 'inbound';
    if (doc.kind != expectedKind) {
      return _FakeResponse(
        400,
        _error('FINANCE_DOCUMENT_KIND_MISMATCH', '单据类型不匹配'),
      );
    }
    final amountRaw = body['amount'];
    if (amountRaw is! String) {
      return _FakeResponse(400, _error('VALIDATION_FAILED', '金额不合法'));
    }
    final amount = Amount.parse(amountRaw);
    // 累计不超过单据总额（对齐后端「锁单据行校验上限」的口径）。
    final already = _sumByKind(doc.id, kind);
    if (already.add(amount).inMinorUnits > doc.totalAmount.inMinorUnits) {
      return _FakeResponse(400, _error('FINANCE_AMOUNT_EXCEEDS', '累计金额超过单据总额'));
    }
    final occurredOn = body['occurred_on'];
    if (occurredOn is! String) {
      return _FakeResponse(400, _error('VALIDATION_FAILED', '发生日期不合法'));
    }
    final id = _nextFinanceId++;
    _financeRecords[id] = _FakeFinanceRecord(
      id: id,
      groupId: caller.groupId,
      kind: kind,
      documentId: doc.id,
      documentKind: doc.kind,
      documentNo: doc.documentNo,
      partyName: doc.parties.isEmpty ? '' : doc.parties.first.name,
      businessUserId: doc.businessUserId,
      businessDate: doc.businessDate,
      amount: amount,
      occurredOn: occurredOn,
      method: body['method'] as String?,
      methodNote: body['method_note'] as String?,
      cardTail: body['card_tail'] as String?,
      invoiceNo: body['invoice_no'] as String?,
      remark: body['remark'] as String?,
      createdByUserId: caller.userId,
      createdAt: DateTime.utc(2026, 9, 22, 15),
    );
    return _FakeResponse(201, _ok(_statementJson(doc)));
  }

  _FakeResponse _financeRevoke(String? auth, String path) {
    final caller = _caller(auth);
    if (caller == null) {
      return _FakeResponse(401, _error('AUTH_INVALID_CREDENTIALS', '未登录'));
    }
    final rest = path.split('/').where((part) => part.isNotEmpty).toList();
    final id = int.tryParse(rest[rest.length - 2]);
    final record = id == null ? null : _financeRecords[id];
    if (record == null || record.groupId != caller.groupId) {
      return _FakeResponse(404, _error('RESOURCE_NOT_FOUND', '财务记录不存在'));
    }
    _financeRecords.remove(record.id);
    final doc = _documents[record.documentId]!;
    return _FakeResponse(200, _ok(_statementJson(doc)));
  }

  Amount _sumByKind(int documentId, String kind) {
    var total = Amount.parse('0');
    for (final record in _financeRecords.values) {
      if (record.documentId == documentId && record.kind == kind) {
        total = total.add(record.amount);
      }
    }
    return total;
  }

  int _countByKind(int documentId, String kind) {
    var count = 0;
    for (final record in _financeRecords.values) {
      if (record.documentId == documentId && record.kind == kind) count++;
    }
    return count;
  }

  Map<String, Object?> _statementJson(_FakeDocument doc) {
    final paid = _sumByKind(doc.id, 'payment');
    final invoiced = _sumByKind(doc.id, 'invoice');
    final received = _sumByKind(doc.id, 'receipt');
    final isInbound = doc.kind == 'inbound';
    final invoicedStatus = !isInbound
        ? 'not_applicable'
        : invoiced.isZero
        ? 'none'
        : invoiced.inMinorUnits < doc.totalAmount.inMinorUnits
        ? 'partial'
        : 'full';
    return <String, Object?>{
      'document_id': doc.id,
      'document_kind': doc.kind,
      'document_no': doc.documentNo,
      'party_name': doc.parties.isEmpty ? '' : doc.parties.first.name,
      'business_user': _userSummaryById(doc.groupId, doc.businessUserId),
      'business_date': doc.businessDate,
      'total_amount': doc.totalAmount.format(),
      'total_amount_upper': _upper(doc.totalAmount),
      'paid_amount': (isInbound ? paid : Amount.parse('0')).format(),
      'unpaid_amount':
          (isInbound ? _outstanding(doc.totalAmount, paid) : Amount.parse('0'))
              .format(),
      'paid_amount_upper': _upper(isInbound ? paid : Amount.parse('0')),
      'unpaid_amount_upper': _upper(
        isInbound ? _outstanding(doc.totalAmount, paid) : Amount.parse('0'),
      ),
      'invoiced_amount': (isInbound ? invoiced : Amount.parse('0')).format(),
      'uninvoiced_amount':
          (isInbound
                  ? _outstanding(doc.totalAmount, invoiced)
                  : Amount.parse('0'))
              .format(),
      'invoiced_amount_upper': _upper(isInbound ? invoiced : Amount.parse('0')),
      'uninvoiced_amount_upper': _upper(
        isInbound ? _outstanding(doc.totalAmount, invoiced) : Amount.parse('0'),
      ),
      'invoice_status': invoicedStatus,
      'received_amount': (isInbound ? Amount.parse('0') : received).format(),
      'unreceived_amount':
          (isInbound
                  ? Amount.parse('0')
                  : _outstanding(doc.totalAmount, received))
              .format(),
      'received_amount_upper': _upper(isInbound ? Amount.parse('0') : received),
      'unreceived_amount_upper': _upper(
        isInbound ? Amount.parse('0') : _outstanding(doc.totalAmount, received),
      ),
      'payment_count': _countByKind(doc.id, 'payment'),
      'receipt_count': _countByKind(doc.id, 'receipt'),
      'invoice_count': _countByKind(doc.id, 'invoice'),
      'records': <Object?>[
        for (final record in _financeRecords.values)
          if (record.documentId == doc.id) _financeJson(record),
      ],
    };
  }

  Amount _outstanding(Amount total, Amount recorded) {
    final remaining = total.sub(recorded);
    return remaining.isNegative ? Amount.parse('0') : remaining;
  }

  /* ------------------------------------------------------------ 报表 */

  String _monthOf(String date) =>
      date.length >= 7 ? date.substring(0, 7) : date;

  _FakeResponse _reportOverview(String? auth, Map<String, String> query) {
    final caller = _caller(auth);
    if (caller == null) {
      return _FakeResponse(401, _error('AUTH_INVALID_CREDENTIALS', '未登录'));
    }
    if (!_hasReportPermission(caller)) {
      return _FakeResponse(403, _error('FORBIDDEN', '无查看报表权限'));
    }
    final period = query['period'] ?? '';
    var inbound = Amount.parse('0');
    var outbound = Amount.parse('0');
    var inboundCount = 0;
    var outboundCount = 0;
    var paid = Amount.parse('0');
    var unpaidCount = 0;
    var invoiced = Amount.parse('0');
    var received = Amount.parse('0');
    final suppliers = <String>{};
    final customers = <String>{};

    for (final doc in _documents.values) {
      if (doc.groupId != caller.groupId || doc.status != 'submitted') continue;
      if (period.isNotEmpty && _monthOf(doc.businessDate) != period) continue;
      if (doc.kind == 'inbound') {
        inbound = inbound.add(doc.totalAmount);
        inboundCount++;
        if (doc.parties.isNotEmpty) suppliers.add(doc.parties.first.name);
        final docPaid = _sumByKind(doc.id, 'payment');
        paid = paid.add(docPaid);
        invoiced = invoiced.add(_sumByKind(doc.id, 'invoice'));
        if (_outstanding(doc.totalAmount, docPaid).inMinorUnits > BigInt.zero) {
          unpaidCount++;
        }
      } else {
        outbound = outbound.add(doc.totalAmount);
        outboundCount++;
        if (doc.parties.isNotEmpty) customers.add(doc.parties.first.name);
        received = received.add(_sumByKind(doc.id, 'receipt'));
      }
    }
    final grossProfit = outbound.sub(inbound);
    final uninvoicedSum = _sumSubmittedOutstanding(
      caller.groupId,
      period,
      'invoice',
    );
    final unreceivedSum = _sumSubmittedOutstanding(
      caller.groupId,
      period,
      'receipt',
    );
    return _FakeResponse(
      200,
      _ok(<String, Object?>{
        'period': period,
        'inbound_document_count': inboundCount,
        'inbound_amount': inbound.format(),
        'inbound_amount_upper': _upper(inbound),
        'outbound_document_count': outboundCount,
        'outbound_amount': outbound.format(),
        'outbound_amount_upper': _upper(outbound),
        'gross_profit': grossProfit.format(),
        'gross_profit_upper': _upper(grossProfit),
        'gross_margin_ppm': 0,
        'gross_margin_percent': '0.00',
        'paid_amount': paid.format(),
        'unpaid_amount': _outstanding(inbound, paid).format(),
        'unpaid_amount_upper': _upper(_outstanding(inbound, paid)),
        'unpaid_document_count': unpaidCount,
        'invoiced_amount': invoiced.format(),
        'uninvoiced_amount': uninvoicedSum.format(),
        'uninvoiced_amount_upper': _upper(uninvoicedSum),
        'uninvoiced_document_count': 0,
        'received_amount': received.format(),
        'unreceived_amount': unreceivedSum.format(),
        'unreceived_amount_upper': _upper(unreceivedSum),
        'unreceived_document_count': 0,
        'supplier_count': suppliers.length,
        'customer_count': customers.length,
        'sale_amount_types': <Object?>[
          for (final type in <String>['Y-1', 'y-N', 'N'])
            <String, Object?>{
              'sale_amount_type': type,
              'amount': '0.00',
              'amount_upper': _upper(Amount.parse('0')),
              'share_ppm': 0,
              'share_percent': '0.00',
            },
        ],
      }),
    );
  }

  Amount _sumSubmittedOutstanding(int groupId, String period, String kind) {
    var total = Amount.parse('0');
    for (final doc in _documents.values) {
      if (doc.groupId != groupId || doc.status != 'submitted') continue;
      if (kind == 'invoice' && doc.kind != 'inbound') continue;
      if (kind == 'receipt' && doc.kind != 'outbound') continue;
      if (period.isNotEmpty && _monthOf(doc.businessDate) != period) continue;
      total = total.add(
        _outstanding(doc.totalAmount, _sumByKind(doc.id, kind)),
      );
    }
    return total;
  }

  bool _hasReportPermission(_Caller caller) {
    if (caller.accountType == 'group_owner') return true;
    for (final member
        in (_membersByGroup[caller.groupId] ?? <int, _FakeMember>{}).values) {
      if (member.userId == caller.userId) {
        return member.permissionCodes.contains('report.view');
      }
    }
    return false;
  }

  _FakeResponse _reportStats(
    String? auth,
    String kind,
    Map<String, String> query,
  ) {
    final caller = _caller(auth);
    if (caller == null) {
      return _FakeResponse(401, _error('AUTH_INVALID_CREDENTIALS', '未登录'));
    }
    if (!_hasReportPermission(caller)) {
      return _FakeResponse(403, _error('FORBIDDEN', '无查看报表权限'));
    }
    final period = query['period'] ?? '';
    var total = Amount.parse('0');
    var count = 0;
    final items = <Map<String, Object?>>[];
    for (final doc in _documents.values) {
      if (doc.groupId != caller.groupId || doc.kind != kind) continue;
      if (doc.status != 'submitted') continue;
      if (period.isNotEmpty && _monthOf(doc.businessDate) != period) continue;
      count++;
      total = total.add(doc.totalAmount);
      for (final party in doc.parties) {
        for (final item in party.items) {
          items.add(<String, Object?>{
            'party_name': party.name,
            'product_name': item.productName,
            'product_model': item.productModel,
            'unit': item.unit,
            'document_count': 1,
            'quantity': item.quantity,
            'amount': item.amount.format(),
            'amount_upper': _upper(item.amount),
          });
        }
      }
    }
    final isInbound = kind == 'inbound';
    final recorded = isInbound
        ? _sumGroupRecords(caller.groupId, 'payment')
        : _sumGroupRecords(caller.groupId, 'receipt');
    return _FakeResponse(
      200,
      _ok(<String, Object?>{
        'period': period,
        'document_count': count,
        'amount_total': total.format(),
        'amount_total_upper': _upper(total),
        if (isInbound) ...<String, Object?>{
          'paid_amount': recorded.format(),
          'unpaid_amount': _outstanding(total, recorded).format(),
          'unpaid_amount_upper': _upper(_outstanding(total, recorded)),
          'unpaid_document_count': 0,
          'invoiced_amount': _sumGroupRecords(
            caller.groupId,
            'invoice',
          ).format(),
          'uninvoiced_amount': _outstanding(
            total,
            _sumGroupRecords(caller.groupId, 'invoice'),
          ).format(),
          'uninvoiced_amount_upper': _upper(
            _outstanding(total, _sumGroupRecords(caller.groupId, 'invoice')),
          ),
          'uninvoiced_document_count': 0,
          'supplier_count': 0,
        } else ...<String, Object?>{
          'received_amount': recorded.format(),
          'unreceived_amount': _outstanding(total, recorded).format(),
          'unreceived_amount_upper': _upper(_outstanding(total, recorded)),
          'unreceived_document_count': 0,
          'customer_count': 0,
          'sale_amount_types': <Object?>[
            for (final type in <String>['Y-1', 'y-N', 'N'])
              <String, Object?>{
                'sale_amount_type': type,
                'amount': '0.00',
                'amount_upper': _upper(Amount.parse('0')),
                'share_ppm': 0,
                'share_percent': '0.00',
              },
          ],
        },
        'items': <Object?>[for (final item in items) item],
        'page': 1,
        'page_size': 20,
        'total': items.length,
      }),
    );
  }

  Amount _sumGroupRecords(int groupId, String kind) {
    var total = Amount.parse('0');
    for (final record in _financeRecords.values) {
      if (record.groupId == groupId && record.kind == kind) {
        total = total.add(record.amount);
      }
    }
    return total;
  }

  _FakeResponse _reportBusinessUsers(String? auth, Map<String, String> query) {
    final caller = _caller(auth);
    if (caller == null) {
      return _FakeResponse(401, _error('AUTH_INVALID_CREDENTIALS', '未登录'));
    }
    if (!_hasReportPermission(caller)) {
      return _FakeResponse(403, _error('FORBIDDEN', '无查看报表权限'));
    }
    final period = query['period'] ?? '';
    final byUser = <int, ({Amount inbound, Amount outbound, int count})>{};
    for (final doc in _documents.values) {
      if (doc.groupId != caller.groupId || doc.status != 'submitted') continue;
      if (period.isNotEmpty && _monthOf(doc.businessDate) != period) continue;
      final existing =
          byUser[doc.businessUserId] ??
          (inbound: Amount.parse('0'), outbound: Amount.parse('0'), count: 0);
      byUser[doc.businessUserId] = (
        inbound: doc.kind == 'inbound'
            ? existing.inbound.add(doc.totalAmount)
            : existing.inbound,
        outbound: doc.kind == 'outbound'
            ? existing.outbound.add(doc.totalAmount)
            : existing.outbound,
        count: existing.count + 1,
      );
    }
    var totalIn = Amount.parse('0');
    var totalOut = Amount.parse('0');
    var totalCount = 0;
    final items = <Map<String, Object?>>[];
    for (final entry in byUser.entries) {
      totalIn = totalIn.add(entry.value.inbound);
      totalOut = totalOut.add(entry.value.outbound);
      totalCount += entry.value.count;
      items.add(<String, Object?>{
        'business_user': _userSummaryById(caller.groupId, entry.key),
        'inbound_amount': entry.value.inbound.format(),
        'outbound_amount': entry.value.outbound.format(),
        'gross_profit': entry.value.outbound.sub(entry.value.inbound).format(),
        'gross_profit_upper': _upper(
          entry.value.outbound.sub(entry.value.inbound),
        ),
        'document_count': entry.value.count,
      });
    }
    final gross = totalOut.sub(totalIn);
    return _FakeResponse(
      200,
      _ok(<String, Object?>{
        'period': period,
        'items': <Object?>[for (final item in items) item],
        'summary': <String, Object?>{
          'inbound_amount': totalIn.format(),
          'outbound_amount': totalOut.format(),
          'gross_profit': gross.format(),
          'gross_profit_upper': _upper(gross),
          'document_count': totalCount,
        },
      }),
    );
  }

  Map<String, Object?> _snapshotJson(
    _FakeSnapshot snapshot,
  ) => <String, Object?>{
    'snapshot_id': snapshot.id,
    'snapshot_no': snapshot.snapshotNo,
    'batch_no': snapshot.batchNo,
    'scope': snapshot.scope,
    'period': snapshot.period,
    // 公司维度回全零值（与后端一致）。
    'business_user': snapshot.businessUserId == null
        ? _userSummaryJson(0, '', '', '')
        : _userSummaryById(snapshot.groupId, snapshot.businessUserId!),
    'inbound_amount': snapshot.inbound.format(),
    'inbound_amount_upper': _upper(snapshot.inbound),
    'outbound_amount': snapshot.outbound.format(),
    'outbound_amount_upper': _upper(snapshot.outbound),
    'gross_profit': snapshot.grossProfit.format(),
    'gross_profit_upper': _upper(snapshot.grossProfit),
    'gross_margin_ppm': 0,
    'gross_margin_percent': '0.00',
    'sale_amount_types': <Object?>[
      for (final type in <String>['Y-1', 'y-N', 'N'])
        <String, Object?>{
          'sale_amount_type': type,
          'amount': '0.00',
          'amount_upper': _upper(Amount.parse('0')),
          'share_ppm': 0,
          'share_percent': '0.00',
        },
    ],
    'document_count': snapshot.documentCount,
    'remark': snapshot.remark,
    'created_by': _userSummaryById(snapshot.groupId, snapshot.createdByUserId),
    'created_at': snapshot.createdAt.toIso8601String(),
  };

  _FakeResponse _snapshotsList(String? auth, Map<String, String> query) {
    final caller = _caller(auth);
    if (caller == null) {
      return _FakeResponse(401, _error('AUTH_INVALID_CREDENTIALS', '未登录'));
    }
    if (!_hasReportPermission(caller)) {
      return _FakeResponse(403, _error('FORBIDDEN', '无查看报表权限'));
    }
    final matched = <_FakeSnapshot>[];
    for (final snapshot in _snapshots.values) {
      if (snapshot.groupId != caller.groupId) continue;
      matched.add(snapshot);
    }
    matched.sort((a, b) => b.id.compareTo(a.id));
    return _FakeResponse(
      200,
      _ok(<String, Object?>{
        'items': <Object?>[for (final s in matched) _snapshotJson(s)],
        'page': 1,
        'page_size': 20,
        'total': matched.length,
      }),
    );
  }

  _FakeResponse _snapshotCreate(String? auth, Map<String, Object?> body) {
    final caller = _caller(auth);
    if (caller == null) {
      return _FakeResponse(401, _error('AUTH_INVALID_CREDENTIALS', '未登录'));
    }
    if (!_hasReportPermission(caller)) {
      return _FakeResponse(403, _error('FORBIDDEN', '无生成权限'));
    }
    final period = body['period'];
    final scope = body['scope'];
    if (period is! String || scope != 'company' && scope != 'business_user') {
      return _FakeResponse(400, _error('VALIDATION_FAILED', '参数不合法'));
    }
    var inbound = Amount.parse('0');
    var outbound = Amount.parse('0');
    var count = 0;
    for (final doc in _documents.values) {
      if (doc.groupId != caller.groupId || doc.status != 'submitted') continue;
      if (_monthOf(doc.businessDate) != period) continue;
      count++;
      if (doc.kind == 'inbound') {
        inbound = inbound.add(doc.totalAmount);
      } else {
        outbound = outbound.add(doc.totalAmount);
      }
    }
    final compact = period.replaceAll('-', '');
    final id = _nextSnapshotId++;
    final snapshotNo = 'ZJS$compact-${_pad(id, 4)}';
    final snapshot = _FakeSnapshot(
      id: id,
      groupId: caller.groupId,
      snapshotNo: snapshotNo,
      batchNo: snapshotNo,
      scope: scope as String,
      period: period,
      businessUserId: scope == 'business_user' ? caller.userId : null,
      inbound: inbound,
      outbound: outbound,
      grossProfit: outbound.sub(inbound),
      documentCount: count,
      remark: body['remark'] as String?,
      createdByUserId: caller.userId,
      createdAt: DateTime.utc(2026, 9, 22, 16),
    );
    _snapshots[id] = snapshot;
    return _FakeResponse(
      201,
      _ok(<String, Object?>{
        'batch_no': snapshot.batchNo,
        'period': period,
        'snapshots': <Object?>[_snapshotJson(snapshot)],
      }),
    );
  }

  /// 结清视图：路径尾段是 document_id。
  _FakeResponse _statementHandler(String? auth, String path) {
    final caller = _caller(auth);
    if (caller == null) {
      return _FakeResponse(401, _error('AUTH_INVALID_CREDENTIALS', '未登录'));
    }
    final rest = path.split('/').where((part) => part.isNotEmpty).toList();
    final documentId = int.tryParse(rest.last);
    final doc = documentId == null ? null : _documents[documentId];
    if (doc == null || doc.groupId != caller.groupId) {
      return _FakeResponse(404, _error('RESOURCE_NOT_FOUND', '单据不存在'));
    }
    return _FakeResponse(200, _ok(_statementJson(doc)));
  }

  /// 单张快照详情。
  _FakeResponse _snapshotDetail(String? auth, String path) {
    final caller = _caller(auth);
    if (caller == null) {
      return _FakeResponse(401, _error('AUTH_INVALID_CREDENTIALS', '未登录'));
    }
    if (!_hasReportPermission(caller)) {
      return _FakeResponse(403, _error('FORBIDDEN', '无查看报表权限'));
    }
    final rest = path.split('/').where((part) => part.isNotEmpty).toList();
    final id = int.tryParse(rest.last);
    final snapshot = id == null ? null : _snapshots[id];
    if (snapshot == null || snapshot.groupId != caller.groupId) {
      return _FakeResponse(404, _error('RESOURCE_NOT_FOUND', '快照不存在'));
    }
    return _FakeResponse(200, _ok(_snapshotJson(snapshot)));
  }

  /// 人民币大写：测试替身只覆盖「整数元 + 角分」的常用场景，避免把 rmb 算法搬进来。
  String _upper(Amount amount) => '人民币${amount.format()}元';

  /// 只暴露「有几类资源」的无害摘要；**绝不打印任何秘密**。
  @override
  String toString() =>
      'FakeBackend(groups: ${_groups.length}, '
      'invitations: ${_invitations.length}, '
      'tenantTokens: ${_tenantTokens.length}, '
      'dictionaries: ${_dictionaries.length})';
}

/* ------------------------------------------------------------ 内部数据类 */

final class _FakeResponse {
  const _FakeResponse(this.status, this.payload);

  final int status;
  final Map<String, Object?> payload;
}

/// 解析出的租户调用者身份（用户名 / 账号类型 / 用户 id / 显示名 / 所属组）。
typedef _Caller = ({
  String username,
  String accountType,
  int userId,
  String displayName,
  int groupId,
});

final class _FakeGroup {
  _FakeGroup({
    required this.id,
    required this.name,
    required this.status,
    required this.version,
    required this.ownerUsername,
    required this.ownerDisplayName,
  });

  final int id;
  final String name;
  String status;
  int version;
  String ownerUsername;
  String ownerDisplayName;
}

final class _FakeInvitation {
  _FakeInvitation({
    required this.id,
    required this.groupId,
    required this.code,
    required this.status,
    required this.expiresAt,
    required this.createdAt,
    required this.version,
  });

  final int id;
  final int groupId;
  final String code;
  String status;
  final String expiresAt;
  final String createdAt;
  int version;
  String? usedAt;
  String? revokedAt;
  String? usedByUsername;
}

final class _FakeMember {
  _FakeMember({
    required this.membershipId,
    required this.userId,
    required this.username,
    required this.displayName,
    required this.memberType,
    required this.status,
    required this.permissionCodes,
    required this.version,
  });

  final int membershipId;
  final int userId;
  final String username;
  final String displayName;
  String memberType;
  String status;
  Set<String> permissionCodes;
  int version;
}

final class _FakeDictionary {
  _FakeDictionary({
    required this.id,
    required this.groupId,
    required this.kind,
    required this.name,
    required this.parentId,
    required this.contactPhone,
    required this.status,
    required this.version,
  });

  final int id;
  final int groupId;
  final String kind;
  final String name;
  final int? parentId;
  final String? contactPhone;
  String status;
  int version;
}

final class _FakeDocument {
  _FakeDocument({
    required this.id,
    required this.groupId,
    required this.kind,
    required this.documentNo,
    required this.status,
    required this.businessUserId,
    required this.businessDate,
    required this.totalAmount,
    required this.version,
    required this.createdAt,
    required this.updatedAt,
    required this.parties,
    this.shippingUnit,
    this.saleAmountType,
    this.remark,
    this.submittedAt,
  });

  final int id;
  final int groupId;
  final String kind;
  final String documentNo;
  String status;
  final int businessUserId;
  String businessDate;
  String? shippingUnit;
  String? saleAmountType;
  Amount totalAmount;
  String? remark;
  int version;
  String? submittedAt;
  DateTime createdAt;
  DateTime updatedAt;
  List<_FakeParty> parties;
}

final class _FakeParty {
  _FakeParty({
    required this.id,
    required this.position,
    required this.name,
    required this.contactPhone,
    required this.subtotal,
    required this.items,
  });

  final int id;
  final int position;
  final String name;
  final String? contactPhone;
  Amount subtotal;
  List<_FakeItem> items;
}

final class _FakeItem {
  _FakeItem({
    required this.id,
    required this.position,
    required this.productName,
    required this.productModel,
    required this.unit,
    required this.quantity,
    required this.weight,
    required this.unitPrice,
    required this.priceTaxMode,
    required this.amount,
    required this.remark,
  });

  final int id;
  final int position;
  final String productName;
  final String? productModel;
  final String? unit;
  final String quantity;
  final String? weight;
  final String unitPrice;
  final String priceTaxMode;
  final Amount amount;
  final String? remark;
}

final class _FakeSettlement {
  _FakeSettlement({
    required this.id,
    required this.groupId,
    required this.settlementNo,
    required this.status,
    required this.requesterUserId,
    required this.inboundTotal,
    required this.outboundTotal,
    required this.grossProfit,
    required this.version,
    required this.createdAt,
    required this.updatedAt,
    required this.sources,
    this.remark,
  });

  final int id;
  final int groupId;
  final String settlementNo;
  String status;
  final int requesterUserId;
  String? remark;
  Amount inboundTotal;
  Amount outboundTotal;
  Amount grossProfit;
  int version;
  String? decidedAt;
  int? decidedByUserId;
  String? decisionRemark;
  DateTime createdAt;
  DateTime updatedAt;
  final List<_FakeSettlementSource> sources;
  final List<Map<String, Object?>> approvalRecords = <Map<String, Object?>>[];
}

final class _FakeSettlementSource {
  _FakeSettlementSource({
    required this.documentId,
    required this.kind,
    required this.documentNo,
    required this.businessUserId,
    required this.businessDate,
    required this.amount,
    required this.released,
  });

  final int documentId;
  final String kind;
  final String documentNo;
  final int businessUserId;
  final String businessDate;
  final Amount amount;
  bool released;
}

final class _FakeFinanceRecord {
  _FakeFinanceRecord({
    required this.id,
    required this.groupId,
    required this.kind,
    required this.documentId,
    required this.documentKind,
    required this.documentNo,
    required this.partyName,
    required this.businessUserId,
    required this.businessDate,
    required this.amount,
    required this.occurredOn,
    required this.method,
    required this.methodNote,
    required this.cardTail,
    required this.invoiceNo,
    required this.remark,
    required this.createdByUserId,
    required this.createdAt,
  });

  final int id;
  final int groupId;
  final String kind;
  final int documentId;
  final String documentKind;
  final String documentNo;
  final String partyName;
  final int businessUserId;
  final String businessDate;
  final Amount amount;
  final String occurredOn;
  final String? method;
  final String? methodNote;
  final String? cardTail;
  final String? invoiceNo;
  final String? remark;
  final int createdByUserId;
  final DateTime createdAt;
}

final class _FakeSnapshot {
  _FakeSnapshot({
    required this.id,
    required this.groupId,
    required this.snapshotNo,
    required this.batchNo,
    required this.scope,
    required this.period,
    required this.businessUserId,
    required this.inbound,
    required this.outbound,
    required this.grossProfit,
    required this.documentCount,
    required this.remark,
    required this.createdByUserId,
    required this.createdAt,
  });

  final int id;
  final int groupId;
  final String snapshotNo;
  final String batchNo;
  final String scope;
  final String period;
  final int? businessUserId;
  final Amount inbound;
  final Amount outbound;
  final Amount grossProfit;
  final int documentCount;
  final String? remark;
  final int createdByUserId;
  final DateTime createdAt;
}
