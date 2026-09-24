import 'dart:convert';

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
