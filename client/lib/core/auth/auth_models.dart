/// Identifies the authentication transport selected for the current client.
enum AuthPlatform { native, web }

/// 服务端 `account_type` 的强类型映射。
///
/// 客户端一律从 `/auth/me` 读取该字段，**绝不本地解码 JWT 声明去猜身份**：
/// 令牌载荷是客户端可读可改的，用它做角色路由等于把权限交给攻击者。
enum AccountType {
  platformAdmin('platform_admin'),
  groupOwner('group_owner'),
  member('member');

  const AccountType(this.wireValue);

  final String wireValue;

  static AccountType fromWireValue(String value) => values.firstWhere(
    (item) => item.wireValue == value,
    orElse: () => throw FormatException('Unknown account type: $value'),
  );
}

/// 成员在组内的角色，仅对租户身份（group_owner / member）有意义。
enum MemberType {
  owner('owner'),
  member('member');

  const MemberType(this.wireValue);

  final String wireValue;

  static MemberType fromWireValue(String value) => values.firstWhere(
    (item) => item.wireValue == value,
    orElse: () => throw FormatException('Unknown member type: $value'),
  );
}

/// 用户摘要（对应契约 `UserSummary`）。
///
/// 既是 `/auth/me` 返回的当前用户，也是结算 / 财务 / 报表里 `requester` /
/// `business_user` / `operator` / `created_by` 等**被引用的其他用户**的类型 ——
/// 后端这几处用的是同一个 `identity.UserSummary`，客户端也复用同一个类型，
/// 不再各建一套重复的解析。
///
/// 解析是**严格**的：`id` 必须是正整数、`username` / `display_name` 非空、
/// `account_type` 必须是合法枚举值。这与单据列表行的 `DocumentBusinessUser`
/// （只回填 id + display_name 的宽松解析）有意不同。
final class AuthUser {
  const AuthUser({
    required this.id,
    required this.username,
    required this.displayName,
    required this.accountType,
  });

  final int id;
  final String username;
  final String displayName;
  final AccountType accountType;

  factory AuthUser.fromJson(Map<String, Object?> json) => AuthUser(
    id: _requireId(json, 'id'),
    username: _requireNonEmptyString(json, 'username'),
    displayName: _requireNonEmptyString(json, 'display_name'),
    accountType: AccountType.fromWireValue(
      _requireNonEmptyString(json, 'account_type'),
    ),
  );
}

/// `/auth/me` 返回的组摘要（对应契约 `GroupSummary`），平台管理员恒为 null。
final class AuthGroup {
  const AuthGroup({required this.id, required this.name});

  final int id;
  final String name;

  factory AuthGroup.fromJson(Map<String, Object?> json) => AuthGroup(
    id: _requireId(json, 'id'),
    name: _requireNonEmptyString(json, 'name'),
  );
}

/// 当前会话的完整服务端身份快照（对应契约 `MeData`）。
///
/// 解析是**严格**的：任何字段缺失、类型不符或身份组合自相矛盾都抛
/// [FormatException]，而不是静默降级成一个"权限更宽"的对象。
/// 宁可让会话建立失败，也不能让守卫拿到一个不完整的身份。
final class AuthProfile {
  const AuthProfile({
    required this.user,
    required this.group,
    required this.memberType,
    required this.mustChangePassword,
    required this.permissionCodes,
  });

  final AuthUser user;

  /// 平台管理员不属于任何组，此处为 null。
  final AuthGroup? group;

  /// 平台管理员没有组内角色，此处为 null。
  final MemberType? memberType;

  final bool mustChangePassword;

  /// 服务端下发的组内权限码；平台管理员与主账号固定为空数组。
  final Set<String> permissionCodes;

  AccountType get accountType => user.accountType;

  /// 主账号隐式持有组内全部权限，因此只看 [permissionCodes] 会漏判。
  bool hasPermission(String code) =>
      accountType == AccountType.groupOwner || permissionCodes.contains(code);

  factory AuthProfile.fromJson(Map<String, Object?> json) {
    final user = AuthUser.fromJson(_requireObject(json, 'user'));

    // group 与 member_type 是契约里的 required 字段（值可为 null）。
    // 用 containsKey 区分「服务端明确给了 null」和「服务端漏了字段」，
    // 后者说明契约被破坏，必须报错而不是当成平台管理员。
    if (!json.containsKey('group')) {
      throw const FormatException('group is required (it may be null)');
    }
    if (!json.containsKey('member_type')) {
      throw const FormatException('member_type is required (it may be null)');
    }

    final rawGroup = json['group'];
    final group = rawGroup == null
        ? null
        : AuthGroup.fromJson(_asObject(rawGroup, 'group'));

    final rawMemberType = json['member_type'];
    final memberType = rawMemberType == null
        ? null
        : MemberType.fromWireValue(_requireNonEmptyString(json, 'member_type'));

    final profile = AuthProfile(
      user: user,
      group: group,
      memberType: memberType,
      mustChangePassword: _requireBool(json, 'must_change_password'),
      permissionCodes: _requirePermissionCodes(json),
    );
    profile._validateIdentityCombination();
    return profile;
  }

  /// 校验 account_type 与 group / member_type 的组合是否自洽。
  void _validateIdentityCombination() {
    switch (accountType) {
      case AccountType.platformAdmin:
        if (group != null) {
          throw const FormatException(
            'A platform admin must not belong to a group',
          );
        }
        if (memberType != null) {
          throw const FormatException(
            'A platform admin must not carry a member type',
          );
        }
      case AccountType.groupOwner:
        if (group == null) {
          throw const FormatException('A group owner must belong to a group');
        }
        if (memberType != MemberType.owner) {
          throw const FormatException(
            'A group owner must be the owner of its group',
          );
        }
      case AccountType.member:
        if (group == null) {
          throw const FormatException('A member must belong to a group');
        }
        if (memberType != MemberType.member) {
          throw const FormatException('A member must have member_type=member');
        }
    }
  }
}

/// A response received from one of the authentication endpoints.
///
/// Web endpoints intentionally omit [refreshToken] because it is held in an
/// HttpOnly cookie. Native endpoints provide it so the app can put it in the
/// operating system's encrypted credential store.
final class TokenResponse {
  const TokenResponse({
    required this.accessToken,
    this.refreshToken,
    this.accessExpiresAt,
    this.refreshExpiresAt,
  });

  final String accessToken;
  final String? refreshToken;
  final DateTime? accessExpiresAt;
  final DateTime? refreshExpiresAt;
}

/// 当前活跃会话：短期访问令牌 + 服务端身份快照。
final class AuthSession {
  const AuthSession({
    required this.accessToken,
    required this.profile,
    this.accessExpiresAt,
  });

  final String accessToken;
  final AuthProfile profile;
  final DateTime? accessExpiresAt;

  bool get mustChangePassword => profile.mustChangePassword;

  /// 会话级依赖的装配键。
  ///
  /// 账号、所属组、角色、改密态或权限集合**任一变化**都会得到不同的 key，
  /// 供 Riverpod 据此整体销毁并重建会话级 Provider/Controller，
  /// 避免切换账号后残留上一个人的列表数据。
  String get scopeKey {
    final permissions = profile.permissionCodes.toList()..sort();
    return '${profile.user.id}:${profile.group?.id ?? 0}:'
        '${profile.accountType.wireValue}:${profile.memberType?.wireValue ?? '-'}:'
        '${profile.mustChangePassword}:${permissions.join(',')}';
  }
}

/// 邀请码注册的请求草稿（对应契约 `RegisterRequest`）。
///
/// 密码在这里只作为一次性的请求参数存在：既不写入本地存储，也不进日志。
final class RegistrationDraft {
  const RegistrationDraft({
    required this.invitationCode,
    required this.username,
    required this.displayName,
    required this.password,
  });

  final String invitationCode;
  final String username;
  final String displayName;
  final String password;
}

/// 注册成功后服务端回传的摘要（对应契约 `RegisterData`）。
///
/// 注册**不签发令牌**，所以这里没有 [AuthSession]：客户端只拿到「账号建好了、
/// 叫什么名字」这一点信息，用来把用户名预填回登录页。
final class RegistrationResult {
  const RegistrationResult({required this.username, required this.groupName});

  final String username;
  final String groupName;

  /// 复用 [AuthUser] / [AuthGroup] 的解析，注册响应里的身份也走同一套严格校验。
  factory RegistrationResult.fromJson(Map<String, Object?> json) {
    final user = AuthUser.fromJson(_requireObject(json, 'user'));
    final group = AuthGroup.fromJson(_requireObject(json, 'group'));
    return RegistrationResult(username: user.username, groupName: group.name);
  }
}

/// Keeps the access token out of durable storage and makes it replaceable in
/// tests without coupling network code to a repository implementation.
abstract interface class AccessTokenStore {
  String? get accessToken;

  set accessToken(String? value);

  void clear();
}

/// The only production access-token store. Its state disappears on process
/// exit, so a stolen browser profile or desktop cache cannot reveal an access
/// token after the session ends.
final class InMemoryAccessTokenStore implements AccessTokenStore {
  String? _accessToken;

  @override
  String? get accessToken => _accessToken;

  @override
  set accessToken(String? value) => _accessToken = value;

  @override
  void clear() => _accessToken = null;
}

/* --------------------------------------------------------- 私有解析辅助 */

Map<String, Object?> _requireObject(Map<String, Object?> json, String field) =>
    _asObject(json[field], field);

Map<String, Object?> _asObject(Object? value, String field) {
  if (value is! Map) {
    throw FormatException('$field must be an object');
  }
  return Map<String, Object?>.from(value);
}

int _requireId(Map<String, Object?> json, String field) {
  final value = json[field];
  if (value is! int || value < 1) {
    throw FormatException('$field must be a positive integer');
  }
  return value;
}

String _requireNonEmptyString(Map<String, Object?> json, String field) {
  final value = json[field];
  if (value is! String || value.isEmpty) {
    throw FormatException('$field must be a non-empty string');
  }
  return value;
}

bool _requireBool(Map<String, Object?> json, String field) {
  final value = json[field];
  if (value is! bool) {
    throw FormatException('$field must be a boolean');
  }
  return value;
}

Set<String> _requirePermissionCodes(Map<String, Object?> json) {
  final value = json['permission_codes'];
  if (value is! List) {
    throw const FormatException('permission_codes must be an array');
  }
  final codes = <String>{};
  for (final item in value) {
    if (item is! String) {
      throw const FormatException('permission_codes must contain only strings');
    }
    codes.add(item);
  }
  return codes;
}
