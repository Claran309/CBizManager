/// 邀请码的对外展示状态（对应契约 `InvitationDisplayStatus`）。
///
/// 四个取值里 `expired` 是服务端**投影**出来的：库里只有 active / used /
/// revoked 三种，服务端把「active 但已过期」投影成 `expired` 再下发。
/// 客户端因此永远不需要自己拿 `expiresAt` 和当前时间比较 —— 本地时钟偏一小时
/// 就会把有效的邀请码显示成「已过期」，而真正说了算的是服务端。
enum InvitationStatus {
  active('active'),
  expired('expired'),
  used('used'),
  revoked('revoked');

  const InvitationStatus(this.wireValue);

  /// 与契约一致的线上取值。
  final String wireValue;

  /// 该状态下是否还能「查看明文 / 撤销」。
  ///
  /// 只有 active 可以：used 说明已经建过账号、revoked 是主动回收、
  /// expired 是过了有效期后服务端投影出来的。三者的共同点是明文都被清空了
  /// （查看会得到 `INVITATION_NOT_REVEALABLE`），所以界面上也不该给出按钮。
  bool get isOpen => this == InvitationStatus.active;

  /// 由线上取值反查枚举，未知取值直接抛错。
  ///
  /// 不做「未知状态当成 active」这类降级：那会让一个已经被撤销的邀请码在界面上
  /// 重新长出「查看 / 撤销」按钮，用户点下去只会收到一个莫名其妙的错误码。
  static InvitationStatus fromWireValue(String value) => values.firstWhere(
    (status) => status.wireValue == value,
    orElse: () => throw FormatException('Unknown invitation status: $value'),
  );
}

/// 邀请码列表里的一行（对应契约 `InvitationSummaryData`）。
///
/// 刻意**不含** `created_by` / `used_by`：契约里根本没有这两个字段，
/// 而列表接口明确「永不返回邀请码明文与密文」——多解析一个字段就多一处
/// 可能与服务端不一致的地方，真需要展示「谁用了」时应当由服务端补字段。
final class InvitationSummary {
  const InvitationSummary({
    required this.id,
    required this.status,
    required this.expiresAt,
    this.usedAt,
    this.revokedAt,
    required this.createdAt,
    required this.version,
  });

  /// 邀请码 ID（契约里的 `invitation_id`）。
  final int id;

  final InvitationStatus status;
  final DateTime expiresAt;

  /// 被使用的时间；未使用时为 null。
  ///
  /// 服务端的 Go 结构体给这两个可空时间加了 `omitempty`，所以「字段不存在」
  /// 和「字段为 null」都会出现，解析必须两者都容忍。
  final DateTime? usedAt;
  final DateTime? revokedAt;
  final DateTime createdAt;

  /// 乐观锁版本号，撤销时必须原样回传。
  final int version;

  factory InvitationSummary.fromJson(Map<String, Object?> json) =>
      InvitationSummary(
        id: _readId(json, 'invitation_id'),
        status: InvitationStatus.fromWireValue(_readString(json, 'status')),
        expiresAt: _readDate(json, 'expires_at'),
        usedAt: _readOptionalDate(json, 'used_at'),
        revokedAt: _readOptionalDate(json, 'revoked_at'),
        createdAt: _readDate(json, 'created_at'),
        version: _readInt(json, 'version'),
      );

  @override
  bool operator ==(Object other) =>
      other is InvitationSummary &&
      id == other.id &&
      status == other.status &&
      expiresAt == other.expiresAt &&
      usedAt == other.usedAt &&
      revokedAt == other.revokedAt &&
      createdAt == other.createdAt &&
      version == other.version;

  @override
  int get hashCode =>
      Object.hash(id, status, expiresAt, usedAt, revokedAt, createdAt, version);

  /// 有意只打印 id 与状态：`toString` 常被塞进断言消息、日志和异常里，
  /// 这里没有任何秘密，但保持「摘要就是摘要」的习惯。
  @override
  String toString() =>
      'InvitationSummary(id: $id, status: ${status.wireValue}, '
      'version: $version)';
}

/// 邀请码明文（对应契约 `InvitationSecretData`）。
///
/// 这是全项目**唯一**会承载明文秘密的领域对象，规则也因此格外严：
///
/// - 只在内存里存在。不进任何本地存储、不进 Outbox、不进日志。
/// - 服务端的响应固定带 `Cache-Control: no-store`，但因为客户端本来就不缓存
///   任何响应，所以这里**不去读也不用去校验那个头** —— 把安全建立在
///   「我们从不落盘」上，而不是建立在「某个响应头恰好存在」上。
/// - [toString] 刻意隐藏 [code]：它必然会出现在断言失败信息、调试打印和
///   异常堆栈里，那是明文泄漏最常见的途径。
final class InvitationSecret {
  const InvitationSecret({
    required this.invitationId,
    required this.code,
    required this.expiresAt,
  });

  /// 所属邀请码 ID，用来判断「展示中的明文是不是列表里这一行」。
  final int invitationId;

  /// 邀请码明文。
  final String code;

  final DateTime expiresAt;

  factory InvitationSecret.fromJson(Map<String, Object?> json) =>
      InvitationSecret(
        invitationId: _readId(json, 'invitation_id'),
        code: _readString(json, 'invitation_code'),
        expiresAt: _readDate(json, 'expires_at'),
      );

  @override
  bool operator ==(Object other) =>
      other is InvitationSecret &&
      invitationId == other.invitationId &&
      code == other.code &&
      expiresAt == other.expiresAt;

  @override
  int get hashCode => Object.hash(invitationId, code, expiresAt);

  @override
  String toString() =>
      'InvitationSecret(invitationId: $invitationId, code: <隐藏>, '
      'expiresAt: ${expiresAt.toIso8601String()})';
}

/* --------------------------------------------------------- 严格解析辅助 */

int _readId(Map<String, Object?> json, String key) {
  final value = json[key];
  // 上界判 1：契约给 invitation_id 标了 minimum: 1。
  if (value is! int || value < 1) {
    throw FormatException('Field "$key" must be a positive integer');
  }
  return value;
}

int _readInt(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! int) {
    throw FormatException('Field "$key" must be an integer');
  }
  return value;
}

String _readString(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! String) {
    throw FormatException('Field "$key" must be a string');
  }
  return value;
}

DateTime _readDate(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! String) {
    throw FormatException('Field "$key" must be an ISO-8601 string');
  }
  return DateTime.parse(value).toUtc();
}

/// 读一个「可为 null、也可能整个字段缺失」的时间。
///
/// 服务端用 Go 的 `*time.Time` + `omitempty` 序列化这两个字段，所以未使用 /
/// 未撤销时它们**根本不会出现在 JSON 里**。契约把它们标成 `nullable: true`
/// 又暗示会显式给 null —— 两种都得接受，缺一种就会在真实响应上解析失败。
DateTime? _readOptionalDate(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value == null) return null;
  if (value is! String) {
    throw FormatException('Field "$key" must be an ISO-8601 string or null');
  }
  return DateTime.parse(value).toUtc();
}
