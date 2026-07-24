enum MemberStatus {
  active('active'),
  disabled('disabled'),
  removed('removed');

  const MemberStatus(this.wireValue);

  final String wireValue;

  static MemberStatus fromWireValue(String value) => values.firstWhere(
    (status) => status.wireValue == value,
    orElse: () => throw FormatException('Unknown member status: $value'),
  );
}

final class Member {
  const Member({
    required this.membershipId,
    required this.username,
    required this.displayName,
    required this.memberType,
    required this.status,
    required this.permissionCodes,
    required this.version,
  });

  final int membershipId;
  final String username;
  final String displayName;
  final String memberType;
  final MemberStatus status;
  final Set<String> permissionCodes;
  final int version;

  factory Member.fromJson(Map<String, Object?> json) {
    final user = json['user'];
    final permissions = json['permission_codes'];
    if (user is! Map || permissions is! List) {
      throw const FormatException('Invalid member payload');
    }
    final userMap = Map<String, Object?>.from(user);
    return Member(
      membershipId: json['membership_id'] as int,
      username: userMap['username'] as String,
      displayName: userMap['display_name'] as String,
      memberType: json['member_type'] as String,
      status: MemberStatus.fromWireValue(json['status'] as String),
      permissionCodes: <String>{for (final code in permissions) code as String},
      version: json['version'] as int,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is Member &&
      membershipId == other.membershipId &&
      username == other.username &&
      displayName == other.displayName &&
      memberType == other.memberType &&
      status == other.status &&
      _setsEqual(permissionCodes, other.permissionCodes) &&
      version == other.version;

  @override
  int get hashCode => Object.hash(
    membershipId,
    username,
    displayName,
    memberType,
    status,
    Object.hashAllUnordered(permissionCodes),
    version,
  );
}

final class MemberPermissions {
  const MemberPermissions({
    required this.membershipId,
    required this.permissionCodes,
    required this.version,
  });

  final int membershipId;
  final Set<String> permissionCodes;
  final int version;

  factory MemberPermissions.fromJson(Map<String, Object?> json) {
    final permissions = json['permission_codes'];
    if (permissions is! List) {
      throw const FormatException('Invalid member permissions payload');
    }
    return MemberPermissions(
      membershipId: json['membership_id'] as int,
      permissionCodes: <String>{for (final code in permissions) code as String},
      version: json['version'] as int,
    );
  }
}

bool _setsEqual(Set<String> left, Set<String> right) =>
    left.length == right.length && left.containsAll(right);
