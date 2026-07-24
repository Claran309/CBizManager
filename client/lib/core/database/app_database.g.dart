// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'app_database.dart';

// ignore_for_file: type=lint
class $CachedMembersTable extends CachedMembers
    with TableInfo<$CachedMembersTable, CachedMember> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $CachedMembersTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _userIdMeta = const VerificationMeta('userId');
  @override
  late final GeneratedColumn<int> userId = GeneratedColumn<int>(
    'user_id',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _groupIdMeta = const VerificationMeta(
    'groupId',
  );
  @override
  late final GeneratedColumn<int> groupId = GeneratedColumn<int>(
    'group_id',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _membershipIdMeta = const VerificationMeta(
    'membershipId',
  );
  @override
  late final GeneratedColumn<int> membershipId = GeneratedColumn<int>(
    'membership_id',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _usernameMeta = const VerificationMeta(
    'username',
  );
  @override
  late final GeneratedColumn<String> username = GeneratedColumn<String>(
    'username',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _displayNameMeta = const VerificationMeta(
    'displayName',
  );
  @override
  late final GeneratedColumn<String> displayName = GeneratedColumn<String>(
    'display_name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _memberTypeMeta = const VerificationMeta(
    'memberType',
  );
  @override
  late final GeneratedColumn<String> memberType = GeneratedColumn<String>(
    'member_type',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _statusMeta = const VerificationMeta('status');
  @override
  late final GeneratedColumn<String> status = GeneratedColumn<String>(
    'status',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _versionMeta = const VerificationMeta(
    'version',
  );
  @override
  late final GeneratedColumn<int> version = GeneratedColumn<int>(
    'version',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    userId,
    groupId,
    membershipId,
    username,
    displayName,
    memberType,
    status,
    version,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'cached_members';
  @override
  VerificationContext validateIntegrity(
    Insertable<CachedMember> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('user_id')) {
      context.handle(
        _userIdMeta,
        userId.isAcceptableOrUnknown(data['user_id']!, _userIdMeta),
      );
    } else if (isInserting) {
      context.missing(_userIdMeta);
    }
    if (data.containsKey('group_id')) {
      context.handle(
        _groupIdMeta,
        groupId.isAcceptableOrUnknown(data['group_id']!, _groupIdMeta),
      );
    } else if (isInserting) {
      context.missing(_groupIdMeta);
    }
    if (data.containsKey('membership_id')) {
      context.handle(
        _membershipIdMeta,
        membershipId.isAcceptableOrUnknown(
          data['membership_id']!,
          _membershipIdMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_membershipIdMeta);
    }
    if (data.containsKey('username')) {
      context.handle(
        _usernameMeta,
        username.isAcceptableOrUnknown(data['username']!, _usernameMeta),
      );
    } else if (isInserting) {
      context.missing(_usernameMeta);
    }
    if (data.containsKey('display_name')) {
      context.handle(
        _displayNameMeta,
        displayName.isAcceptableOrUnknown(
          data['display_name']!,
          _displayNameMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_displayNameMeta);
    }
    if (data.containsKey('member_type')) {
      context.handle(
        _memberTypeMeta,
        memberType.isAcceptableOrUnknown(data['member_type']!, _memberTypeMeta),
      );
    } else if (isInserting) {
      context.missing(_memberTypeMeta);
    }
    if (data.containsKey('status')) {
      context.handle(
        _statusMeta,
        status.isAcceptableOrUnknown(data['status']!, _statusMeta),
      );
    } else if (isInserting) {
      context.missing(_statusMeta);
    }
    if (data.containsKey('version')) {
      context.handle(
        _versionMeta,
        version.isAcceptableOrUnknown(data['version']!, _versionMeta),
      );
    } else if (isInserting) {
      context.missing(_versionMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {userId, groupId, membershipId};
  @override
  CachedMember map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return CachedMember(
      userId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}user_id'],
      )!,
      groupId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}group_id'],
      )!,
      membershipId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}membership_id'],
      )!,
      username: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}username'],
      )!,
      displayName: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}display_name'],
      )!,
      memberType: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}member_type'],
      )!,
      status: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}status'],
      )!,
      version: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}version'],
      )!,
    );
  }

  @override
  $CachedMembersTable createAlias(String alias) {
    return $CachedMembersTable(attachedDatabase, alias);
  }
}

class CachedMember extends DataClass implements Insertable<CachedMember> {
  final int userId;
  final int groupId;
  final int membershipId;
  final String username;
  final String displayName;
  final String memberType;
  final String status;
  final int version;
  const CachedMember({
    required this.userId,
    required this.groupId,
    required this.membershipId,
    required this.username,
    required this.displayName,
    required this.memberType,
    required this.status,
    required this.version,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['user_id'] = Variable<int>(userId);
    map['group_id'] = Variable<int>(groupId);
    map['membership_id'] = Variable<int>(membershipId);
    map['username'] = Variable<String>(username);
    map['display_name'] = Variable<String>(displayName);
    map['member_type'] = Variable<String>(memberType);
    map['status'] = Variable<String>(status);
    map['version'] = Variable<int>(version);
    return map;
  }

  CachedMembersCompanion toCompanion(bool nullToAbsent) {
    return CachedMembersCompanion(
      userId: Value(userId),
      groupId: Value(groupId),
      membershipId: Value(membershipId),
      username: Value(username),
      displayName: Value(displayName),
      memberType: Value(memberType),
      status: Value(status),
      version: Value(version),
    );
  }

  factory CachedMember.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return CachedMember(
      userId: serializer.fromJson<int>(json['userId']),
      groupId: serializer.fromJson<int>(json['groupId']),
      membershipId: serializer.fromJson<int>(json['membershipId']),
      username: serializer.fromJson<String>(json['username']),
      displayName: serializer.fromJson<String>(json['displayName']),
      memberType: serializer.fromJson<String>(json['memberType']),
      status: serializer.fromJson<String>(json['status']),
      version: serializer.fromJson<int>(json['version']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'userId': serializer.toJson<int>(userId),
      'groupId': serializer.toJson<int>(groupId),
      'membershipId': serializer.toJson<int>(membershipId),
      'username': serializer.toJson<String>(username),
      'displayName': serializer.toJson<String>(displayName),
      'memberType': serializer.toJson<String>(memberType),
      'status': serializer.toJson<String>(status),
      'version': serializer.toJson<int>(version),
    };
  }

  CachedMember copyWith({
    int? userId,
    int? groupId,
    int? membershipId,
    String? username,
    String? displayName,
    String? memberType,
    String? status,
    int? version,
  }) => CachedMember(
    userId: userId ?? this.userId,
    groupId: groupId ?? this.groupId,
    membershipId: membershipId ?? this.membershipId,
    username: username ?? this.username,
    displayName: displayName ?? this.displayName,
    memberType: memberType ?? this.memberType,
    status: status ?? this.status,
    version: version ?? this.version,
  );
  CachedMember copyWithCompanion(CachedMembersCompanion data) {
    return CachedMember(
      userId: data.userId.present ? data.userId.value : this.userId,
      groupId: data.groupId.present ? data.groupId.value : this.groupId,
      membershipId: data.membershipId.present
          ? data.membershipId.value
          : this.membershipId,
      username: data.username.present ? data.username.value : this.username,
      displayName: data.displayName.present
          ? data.displayName.value
          : this.displayName,
      memberType: data.memberType.present
          ? data.memberType.value
          : this.memberType,
      status: data.status.present ? data.status.value : this.status,
      version: data.version.present ? data.version.value : this.version,
    );
  }

  @override
  String toString() {
    return (StringBuffer('CachedMember(')
          ..write('userId: $userId, ')
          ..write('groupId: $groupId, ')
          ..write('membershipId: $membershipId, ')
          ..write('username: $username, ')
          ..write('displayName: $displayName, ')
          ..write('memberType: $memberType, ')
          ..write('status: $status, ')
          ..write('version: $version')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    userId,
    groupId,
    membershipId,
    username,
    displayName,
    memberType,
    status,
    version,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is CachedMember &&
          other.userId == this.userId &&
          other.groupId == this.groupId &&
          other.membershipId == this.membershipId &&
          other.username == this.username &&
          other.displayName == this.displayName &&
          other.memberType == this.memberType &&
          other.status == this.status &&
          other.version == this.version);
}

class CachedMembersCompanion extends UpdateCompanion<CachedMember> {
  final Value<int> userId;
  final Value<int> groupId;
  final Value<int> membershipId;
  final Value<String> username;
  final Value<String> displayName;
  final Value<String> memberType;
  final Value<String> status;
  final Value<int> version;
  final Value<int> rowid;
  const CachedMembersCompanion({
    this.userId = const Value.absent(),
    this.groupId = const Value.absent(),
    this.membershipId = const Value.absent(),
    this.username = const Value.absent(),
    this.displayName = const Value.absent(),
    this.memberType = const Value.absent(),
    this.status = const Value.absent(),
    this.version = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  CachedMembersCompanion.insert({
    required int userId,
    required int groupId,
    required int membershipId,
    required String username,
    required String displayName,
    required String memberType,
    required String status,
    required int version,
    this.rowid = const Value.absent(),
  }) : userId = Value(userId),
       groupId = Value(groupId),
       membershipId = Value(membershipId),
       username = Value(username),
       displayName = Value(displayName),
       memberType = Value(memberType),
       status = Value(status),
       version = Value(version);
  static Insertable<CachedMember> custom({
    Expression<int>? userId,
    Expression<int>? groupId,
    Expression<int>? membershipId,
    Expression<String>? username,
    Expression<String>? displayName,
    Expression<String>? memberType,
    Expression<String>? status,
    Expression<int>? version,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (userId != null) 'user_id': userId,
      if (groupId != null) 'group_id': groupId,
      if (membershipId != null) 'membership_id': membershipId,
      if (username != null) 'username': username,
      if (displayName != null) 'display_name': displayName,
      if (memberType != null) 'member_type': memberType,
      if (status != null) 'status': status,
      if (version != null) 'version': version,
      if (rowid != null) 'rowid': rowid,
    });
  }

  CachedMembersCompanion copyWith({
    Value<int>? userId,
    Value<int>? groupId,
    Value<int>? membershipId,
    Value<String>? username,
    Value<String>? displayName,
    Value<String>? memberType,
    Value<String>? status,
    Value<int>? version,
    Value<int>? rowid,
  }) {
    return CachedMembersCompanion(
      userId: userId ?? this.userId,
      groupId: groupId ?? this.groupId,
      membershipId: membershipId ?? this.membershipId,
      username: username ?? this.username,
      displayName: displayName ?? this.displayName,
      memberType: memberType ?? this.memberType,
      status: status ?? this.status,
      version: version ?? this.version,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (userId.present) {
      map['user_id'] = Variable<int>(userId.value);
    }
    if (groupId.present) {
      map['group_id'] = Variable<int>(groupId.value);
    }
    if (membershipId.present) {
      map['membership_id'] = Variable<int>(membershipId.value);
    }
    if (username.present) {
      map['username'] = Variable<String>(username.value);
    }
    if (displayName.present) {
      map['display_name'] = Variable<String>(displayName.value);
    }
    if (memberType.present) {
      map['member_type'] = Variable<String>(memberType.value);
    }
    if (status.present) {
      map['status'] = Variable<String>(status.value);
    }
    if (version.present) {
      map['version'] = Variable<int>(version.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('CachedMembersCompanion(')
          ..write('userId: $userId, ')
          ..write('groupId: $groupId, ')
          ..write('membershipId: $membershipId, ')
          ..write('username: $username, ')
          ..write('displayName: $displayName, ')
          ..write('memberType: $memberType, ')
          ..write('status: $status, ')
          ..write('version: $version, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $CachedMemberPermissionsTable extends CachedMemberPermissions
    with TableInfo<$CachedMemberPermissionsTable, CachedMemberPermission> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $CachedMemberPermissionsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _userIdMeta = const VerificationMeta('userId');
  @override
  late final GeneratedColumn<int> userId = GeneratedColumn<int>(
    'user_id',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _groupIdMeta = const VerificationMeta(
    'groupId',
  );
  @override
  late final GeneratedColumn<int> groupId = GeneratedColumn<int>(
    'group_id',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _membershipIdMeta = const VerificationMeta(
    'membershipId',
  );
  @override
  late final GeneratedColumn<int> membershipId = GeneratedColumn<int>(
    'membership_id',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _permissionCodesMeta = const VerificationMeta(
    'permissionCodes',
  );
  @override
  late final GeneratedColumn<String> permissionCodes = GeneratedColumn<String>(
    'permission_codes',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _versionMeta = const VerificationMeta(
    'version',
  );
  @override
  late final GeneratedColumn<int> version = GeneratedColumn<int>(
    'version',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    userId,
    groupId,
    membershipId,
    permissionCodes,
    version,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'cached_member_permissions';
  @override
  VerificationContext validateIntegrity(
    Insertable<CachedMemberPermission> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('user_id')) {
      context.handle(
        _userIdMeta,
        userId.isAcceptableOrUnknown(data['user_id']!, _userIdMeta),
      );
    } else if (isInserting) {
      context.missing(_userIdMeta);
    }
    if (data.containsKey('group_id')) {
      context.handle(
        _groupIdMeta,
        groupId.isAcceptableOrUnknown(data['group_id']!, _groupIdMeta),
      );
    } else if (isInserting) {
      context.missing(_groupIdMeta);
    }
    if (data.containsKey('membership_id')) {
      context.handle(
        _membershipIdMeta,
        membershipId.isAcceptableOrUnknown(
          data['membership_id']!,
          _membershipIdMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_membershipIdMeta);
    }
    if (data.containsKey('permission_codes')) {
      context.handle(
        _permissionCodesMeta,
        permissionCodes.isAcceptableOrUnknown(
          data['permission_codes']!,
          _permissionCodesMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_permissionCodesMeta);
    }
    if (data.containsKey('version')) {
      context.handle(
        _versionMeta,
        version.isAcceptableOrUnknown(data['version']!, _versionMeta),
      );
    } else if (isInserting) {
      context.missing(_versionMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {userId, groupId, membershipId};
  @override
  CachedMemberPermission map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return CachedMemberPermission(
      userId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}user_id'],
      )!,
      groupId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}group_id'],
      )!,
      membershipId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}membership_id'],
      )!,
      permissionCodes: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}permission_codes'],
      )!,
      version: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}version'],
      )!,
    );
  }

  @override
  $CachedMemberPermissionsTable createAlias(String alias) {
    return $CachedMemberPermissionsTable(attachedDatabase, alias);
  }
}

class CachedMemberPermission extends DataClass
    implements Insertable<CachedMemberPermission> {
  final int userId;
  final int groupId;
  final int membershipId;
  final String permissionCodes;
  final int version;
  const CachedMemberPermission({
    required this.userId,
    required this.groupId,
    required this.membershipId,
    required this.permissionCodes,
    required this.version,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['user_id'] = Variable<int>(userId);
    map['group_id'] = Variable<int>(groupId);
    map['membership_id'] = Variable<int>(membershipId);
    map['permission_codes'] = Variable<String>(permissionCodes);
    map['version'] = Variable<int>(version);
    return map;
  }

  CachedMemberPermissionsCompanion toCompanion(bool nullToAbsent) {
    return CachedMemberPermissionsCompanion(
      userId: Value(userId),
      groupId: Value(groupId),
      membershipId: Value(membershipId),
      permissionCodes: Value(permissionCodes),
      version: Value(version),
    );
  }

  factory CachedMemberPermission.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return CachedMemberPermission(
      userId: serializer.fromJson<int>(json['userId']),
      groupId: serializer.fromJson<int>(json['groupId']),
      membershipId: serializer.fromJson<int>(json['membershipId']),
      permissionCodes: serializer.fromJson<String>(json['permissionCodes']),
      version: serializer.fromJson<int>(json['version']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'userId': serializer.toJson<int>(userId),
      'groupId': serializer.toJson<int>(groupId),
      'membershipId': serializer.toJson<int>(membershipId),
      'permissionCodes': serializer.toJson<String>(permissionCodes),
      'version': serializer.toJson<int>(version),
    };
  }

  CachedMemberPermission copyWith({
    int? userId,
    int? groupId,
    int? membershipId,
    String? permissionCodes,
    int? version,
  }) => CachedMemberPermission(
    userId: userId ?? this.userId,
    groupId: groupId ?? this.groupId,
    membershipId: membershipId ?? this.membershipId,
    permissionCodes: permissionCodes ?? this.permissionCodes,
    version: version ?? this.version,
  );
  CachedMemberPermission copyWithCompanion(
    CachedMemberPermissionsCompanion data,
  ) {
    return CachedMemberPermission(
      userId: data.userId.present ? data.userId.value : this.userId,
      groupId: data.groupId.present ? data.groupId.value : this.groupId,
      membershipId: data.membershipId.present
          ? data.membershipId.value
          : this.membershipId,
      permissionCodes: data.permissionCodes.present
          ? data.permissionCodes.value
          : this.permissionCodes,
      version: data.version.present ? data.version.value : this.version,
    );
  }

  @override
  String toString() {
    return (StringBuffer('CachedMemberPermission(')
          ..write('userId: $userId, ')
          ..write('groupId: $groupId, ')
          ..write('membershipId: $membershipId, ')
          ..write('permissionCodes: $permissionCodes, ')
          ..write('version: $version')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode =>
      Object.hash(userId, groupId, membershipId, permissionCodes, version);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is CachedMemberPermission &&
          other.userId == this.userId &&
          other.groupId == this.groupId &&
          other.membershipId == this.membershipId &&
          other.permissionCodes == this.permissionCodes &&
          other.version == this.version);
}

class CachedMemberPermissionsCompanion
    extends UpdateCompanion<CachedMemberPermission> {
  final Value<int> userId;
  final Value<int> groupId;
  final Value<int> membershipId;
  final Value<String> permissionCodes;
  final Value<int> version;
  final Value<int> rowid;
  const CachedMemberPermissionsCompanion({
    this.userId = const Value.absent(),
    this.groupId = const Value.absent(),
    this.membershipId = const Value.absent(),
    this.permissionCodes = const Value.absent(),
    this.version = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  CachedMemberPermissionsCompanion.insert({
    required int userId,
    required int groupId,
    required int membershipId,
    required String permissionCodes,
    required int version,
    this.rowid = const Value.absent(),
  }) : userId = Value(userId),
       groupId = Value(groupId),
       membershipId = Value(membershipId),
       permissionCodes = Value(permissionCodes),
       version = Value(version);
  static Insertable<CachedMemberPermission> custom({
    Expression<int>? userId,
    Expression<int>? groupId,
    Expression<int>? membershipId,
    Expression<String>? permissionCodes,
    Expression<int>? version,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (userId != null) 'user_id': userId,
      if (groupId != null) 'group_id': groupId,
      if (membershipId != null) 'membership_id': membershipId,
      if (permissionCodes != null) 'permission_codes': permissionCodes,
      if (version != null) 'version': version,
      if (rowid != null) 'rowid': rowid,
    });
  }

  CachedMemberPermissionsCompanion copyWith({
    Value<int>? userId,
    Value<int>? groupId,
    Value<int>? membershipId,
    Value<String>? permissionCodes,
    Value<int>? version,
    Value<int>? rowid,
  }) {
    return CachedMemberPermissionsCompanion(
      userId: userId ?? this.userId,
      groupId: groupId ?? this.groupId,
      membershipId: membershipId ?? this.membershipId,
      permissionCodes: permissionCodes ?? this.permissionCodes,
      version: version ?? this.version,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (userId.present) {
      map['user_id'] = Variable<int>(userId.value);
    }
    if (groupId.present) {
      map['group_id'] = Variable<int>(groupId.value);
    }
    if (membershipId.present) {
      map['membership_id'] = Variable<int>(membershipId.value);
    }
    if (permissionCodes.present) {
      map['permission_codes'] = Variable<String>(permissionCodes.value);
    }
    if (version.present) {
      map['version'] = Variable<int>(version.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('CachedMemberPermissionsCompanion(')
          ..write('userId: $userId, ')
          ..write('groupId: $groupId, ')
          ..write('membershipId: $membershipId, ')
          ..write('permissionCodes: $permissionCodes, ')
          ..write('version: $version, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $CachedDictionaryEntriesTable extends CachedDictionaryEntries
    with TableInfo<$CachedDictionaryEntriesTable, CachedDictionaryEntry> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $CachedDictionaryEntriesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _userIdMeta = const VerificationMeta('userId');
  @override
  late final GeneratedColumn<int> userId = GeneratedColumn<int>(
    'user_id',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _groupIdMeta = const VerificationMeta(
    'groupId',
  );
  @override
  late final GeneratedColumn<int> groupId = GeneratedColumn<int>(
    'group_id',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _dictionaryIdMeta = const VerificationMeta(
    'dictionaryId',
  );
  @override
  late final GeneratedColumn<int> dictionaryId = GeneratedColumn<int>(
    'dictionary_id',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _kindMeta = const VerificationMeta('kind');
  @override
  late final GeneratedColumn<String> kind = GeneratedColumn<String>(
    'kind',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _nameMeta = const VerificationMeta('name');
  @override
  late final GeneratedColumn<String> name = GeneratedColumn<String>(
    'name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _parentIdMeta = const VerificationMeta(
    'parentId',
  );
  @override
  late final GeneratedColumn<int> parentId = GeneratedColumn<int>(
    'parent_id',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _contactMeta = const VerificationMeta(
    'contact',
  );
  @override
  late final GeneratedColumn<String> contact = GeneratedColumn<String>(
    'contact',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _statusMeta = const VerificationMeta('status');
  @override
  late final GeneratedColumn<String> status = GeneratedColumn<String>(
    'status',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _versionMeta = const VerificationMeta(
    'version',
  );
  @override
  late final GeneratedColumn<int> version = GeneratedColumn<int>(
    'version',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    userId,
    groupId,
    dictionaryId,
    kind,
    name,
    parentId,
    contact,
    status,
    version,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'cached_dictionary_entries';
  @override
  VerificationContext validateIntegrity(
    Insertable<CachedDictionaryEntry> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('user_id')) {
      context.handle(
        _userIdMeta,
        userId.isAcceptableOrUnknown(data['user_id']!, _userIdMeta),
      );
    } else if (isInserting) {
      context.missing(_userIdMeta);
    }
    if (data.containsKey('group_id')) {
      context.handle(
        _groupIdMeta,
        groupId.isAcceptableOrUnknown(data['group_id']!, _groupIdMeta),
      );
    } else if (isInserting) {
      context.missing(_groupIdMeta);
    }
    if (data.containsKey('dictionary_id')) {
      context.handle(
        _dictionaryIdMeta,
        dictionaryId.isAcceptableOrUnknown(
          data['dictionary_id']!,
          _dictionaryIdMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_dictionaryIdMeta);
    }
    if (data.containsKey('kind')) {
      context.handle(
        _kindMeta,
        kind.isAcceptableOrUnknown(data['kind']!, _kindMeta),
      );
    } else if (isInserting) {
      context.missing(_kindMeta);
    }
    if (data.containsKey('name')) {
      context.handle(
        _nameMeta,
        name.isAcceptableOrUnknown(data['name']!, _nameMeta),
      );
    } else if (isInserting) {
      context.missing(_nameMeta);
    }
    if (data.containsKey('parent_id')) {
      context.handle(
        _parentIdMeta,
        parentId.isAcceptableOrUnknown(data['parent_id']!, _parentIdMeta),
      );
    }
    if (data.containsKey('contact')) {
      context.handle(
        _contactMeta,
        contact.isAcceptableOrUnknown(data['contact']!, _contactMeta),
      );
    }
    if (data.containsKey('status')) {
      context.handle(
        _statusMeta,
        status.isAcceptableOrUnknown(data['status']!, _statusMeta),
      );
    } else if (isInserting) {
      context.missing(_statusMeta);
    }
    if (data.containsKey('version')) {
      context.handle(
        _versionMeta,
        version.isAcceptableOrUnknown(data['version']!, _versionMeta),
      );
    } else if (isInserting) {
      context.missing(_versionMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {userId, groupId, dictionaryId};
  @override
  CachedDictionaryEntry map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return CachedDictionaryEntry(
      userId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}user_id'],
      )!,
      groupId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}group_id'],
      )!,
      dictionaryId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}dictionary_id'],
      )!,
      kind: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}kind'],
      )!,
      name: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}name'],
      )!,
      parentId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}parent_id'],
      ),
      contact: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}contact'],
      ),
      status: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}status'],
      )!,
      version: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}version'],
      )!,
    );
  }

  @override
  $CachedDictionaryEntriesTable createAlias(String alias) {
    return $CachedDictionaryEntriesTable(attachedDatabase, alias);
  }
}

class CachedDictionaryEntry extends DataClass
    implements Insertable<CachedDictionaryEntry> {
  final int userId;
  final int groupId;
  final int dictionaryId;
  final String kind;
  final String name;
  final int? parentId;
  final String? contact;
  final String status;
  final int version;
  const CachedDictionaryEntry({
    required this.userId,
    required this.groupId,
    required this.dictionaryId,
    required this.kind,
    required this.name,
    this.parentId,
    this.contact,
    required this.status,
    required this.version,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['user_id'] = Variable<int>(userId);
    map['group_id'] = Variable<int>(groupId);
    map['dictionary_id'] = Variable<int>(dictionaryId);
    map['kind'] = Variable<String>(kind);
    map['name'] = Variable<String>(name);
    if (!nullToAbsent || parentId != null) {
      map['parent_id'] = Variable<int>(parentId);
    }
    if (!nullToAbsent || contact != null) {
      map['contact'] = Variable<String>(contact);
    }
    map['status'] = Variable<String>(status);
    map['version'] = Variable<int>(version);
    return map;
  }

  CachedDictionaryEntriesCompanion toCompanion(bool nullToAbsent) {
    return CachedDictionaryEntriesCompanion(
      userId: Value(userId),
      groupId: Value(groupId),
      dictionaryId: Value(dictionaryId),
      kind: Value(kind),
      name: Value(name),
      parentId: parentId == null && nullToAbsent
          ? const Value.absent()
          : Value(parentId),
      contact: contact == null && nullToAbsent
          ? const Value.absent()
          : Value(contact),
      status: Value(status),
      version: Value(version),
    );
  }

  factory CachedDictionaryEntry.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return CachedDictionaryEntry(
      userId: serializer.fromJson<int>(json['userId']),
      groupId: serializer.fromJson<int>(json['groupId']),
      dictionaryId: serializer.fromJson<int>(json['dictionaryId']),
      kind: serializer.fromJson<String>(json['kind']),
      name: serializer.fromJson<String>(json['name']),
      parentId: serializer.fromJson<int?>(json['parentId']),
      contact: serializer.fromJson<String?>(json['contact']),
      status: serializer.fromJson<String>(json['status']),
      version: serializer.fromJson<int>(json['version']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'userId': serializer.toJson<int>(userId),
      'groupId': serializer.toJson<int>(groupId),
      'dictionaryId': serializer.toJson<int>(dictionaryId),
      'kind': serializer.toJson<String>(kind),
      'name': serializer.toJson<String>(name),
      'parentId': serializer.toJson<int?>(parentId),
      'contact': serializer.toJson<String?>(contact),
      'status': serializer.toJson<String>(status),
      'version': serializer.toJson<int>(version),
    };
  }

  CachedDictionaryEntry copyWith({
    int? userId,
    int? groupId,
    int? dictionaryId,
    String? kind,
    String? name,
    Value<int?> parentId = const Value.absent(),
    Value<String?> contact = const Value.absent(),
    String? status,
    int? version,
  }) => CachedDictionaryEntry(
    userId: userId ?? this.userId,
    groupId: groupId ?? this.groupId,
    dictionaryId: dictionaryId ?? this.dictionaryId,
    kind: kind ?? this.kind,
    name: name ?? this.name,
    parentId: parentId.present ? parentId.value : this.parentId,
    contact: contact.present ? contact.value : this.contact,
    status: status ?? this.status,
    version: version ?? this.version,
  );
  CachedDictionaryEntry copyWithCompanion(
    CachedDictionaryEntriesCompanion data,
  ) {
    return CachedDictionaryEntry(
      userId: data.userId.present ? data.userId.value : this.userId,
      groupId: data.groupId.present ? data.groupId.value : this.groupId,
      dictionaryId: data.dictionaryId.present
          ? data.dictionaryId.value
          : this.dictionaryId,
      kind: data.kind.present ? data.kind.value : this.kind,
      name: data.name.present ? data.name.value : this.name,
      parentId: data.parentId.present ? data.parentId.value : this.parentId,
      contact: data.contact.present ? data.contact.value : this.contact,
      status: data.status.present ? data.status.value : this.status,
      version: data.version.present ? data.version.value : this.version,
    );
  }

  @override
  String toString() {
    return (StringBuffer('CachedDictionaryEntry(')
          ..write('userId: $userId, ')
          ..write('groupId: $groupId, ')
          ..write('dictionaryId: $dictionaryId, ')
          ..write('kind: $kind, ')
          ..write('name: $name, ')
          ..write('parentId: $parentId, ')
          ..write('contact: $contact, ')
          ..write('status: $status, ')
          ..write('version: $version')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    userId,
    groupId,
    dictionaryId,
    kind,
    name,
    parentId,
    contact,
    status,
    version,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is CachedDictionaryEntry &&
          other.userId == this.userId &&
          other.groupId == this.groupId &&
          other.dictionaryId == this.dictionaryId &&
          other.kind == this.kind &&
          other.name == this.name &&
          other.parentId == this.parentId &&
          other.contact == this.contact &&
          other.status == this.status &&
          other.version == this.version);
}

class CachedDictionaryEntriesCompanion
    extends UpdateCompanion<CachedDictionaryEntry> {
  final Value<int> userId;
  final Value<int> groupId;
  final Value<int> dictionaryId;
  final Value<String> kind;
  final Value<String> name;
  final Value<int?> parentId;
  final Value<String?> contact;
  final Value<String> status;
  final Value<int> version;
  final Value<int> rowid;
  const CachedDictionaryEntriesCompanion({
    this.userId = const Value.absent(),
    this.groupId = const Value.absent(),
    this.dictionaryId = const Value.absent(),
    this.kind = const Value.absent(),
    this.name = const Value.absent(),
    this.parentId = const Value.absent(),
    this.contact = const Value.absent(),
    this.status = const Value.absent(),
    this.version = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  CachedDictionaryEntriesCompanion.insert({
    required int userId,
    required int groupId,
    required int dictionaryId,
    required String kind,
    required String name,
    this.parentId = const Value.absent(),
    this.contact = const Value.absent(),
    required String status,
    required int version,
    this.rowid = const Value.absent(),
  }) : userId = Value(userId),
       groupId = Value(groupId),
       dictionaryId = Value(dictionaryId),
       kind = Value(kind),
       name = Value(name),
       status = Value(status),
       version = Value(version);
  static Insertable<CachedDictionaryEntry> custom({
    Expression<int>? userId,
    Expression<int>? groupId,
    Expression<int>? dictionaryId,
    Expression<String>? kind,
    Expression<String>? name,
    Expression<int>? parentId,
    Expression<String>? contact,
    Expression<String>? status,
    Expression<int>? version,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (userId != null) 'user_id': userId,
      if (groupId != null) 'group_id': groupId,
      if (dictionaryId != null) 'dictionary_id': dictionaryId,
      if (kind != null) 'kind': kind,
      if (name != null) 'name': name,
      if (parentId != null) 'parent_id': parentId,
      if (contact != null) 'contact': contact,
      if (status != null) 'status': status,
      if (version != null) 'version': version,
      if (rowid != null) 'rowid': rowid,
    });
  }

  CachedDictionaryEntriesCompanion copyWith({
    Value<int>? userId,
    Value<int>? groupId,
    Value<int>? dictionaryId,
    Value<String>? kind,
    Value<String>? name,
    Value<int?>? parentId,
    Value<String?>? contact,
    Value<String>? status,
    Value<int>? version,
    Value<int>? rowid,
  }) {
    return CachedDictionaryEntriesCompanion(
      userId: userId ?? this.userId,
      groupId: groupId ?? this.groupId,
      dictionaryId: dictionaryId ?? this.dictionaryId,
      kind: kind ?? this.kind,
      name: name ?? this.name,
      parentId: parentId ?? this.parentId,
      contact: contact ?? this.contact,
      status: status ?? this.status,
      version: version ?? this.version,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (userId.present) {
      map['user_id'] = Variable<int>(userId.value);
    }
    if (groupId.present) {
      map['group_id'] = Variable<int>(groupId.value);
    }
    if (dictionaryId.present) {
      map['dictionary_id'] = Variable<int>(dictionaryId.value);
    }
    if (kind.present) {
      map['kind'] = Variable<String>(kind.value);
    }
    if (name.present) {
      map['name'] = Variable<String>(name.value);
    }
    if (parentId.present) {
      map['parent_id'] = Variable<int>(parentId.value);
    }
    if (contact.present) {
      map['contact'] = Variable<String>(contact.value);
    }
    if (status.present) {
      map['status'] = Variable<String>(status.value);
    }
    if (version.present) {
      map['version'] = Variable<int>(version.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('CachedDictionaryEntriesCompanion(')
          ..write('userId: $userId, ')
          ..write('groupId: $groupId, ')
          ..write('dictionaryId: $dictionaryId, ')
          ..write('kind: $kind, ')
          ..write('name: $name, ')
          ..write('parentId: $parentId, ')
          ..write('contact: $contact, ')
          ..write('status: $status, ')
          ..write('version: $version, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $DraftRecordsTable extends DraftRecords
    with TableInfo<$DraftRecordsTable, DraftRecord> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $DraftRecordsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _userIdMeta = const VerificationMeta('userId');
  @override
  late final GeneratedColumn<int> userId = GeneratedColumn<int>(
    'user_id',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _groupIdMeta = const VerificationMeta(
    'groupId',
  );
  @override
  late final GeneratedColumn<int> groupId = GeneratedColumn<int>(
    'group_id',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _draftIdMeta = const VerificationMeta(
    'draftId',
  );
  @override
  late final GeneratedColumn<String> draftId = GeneratedColumn<String>(
    'draft_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _resourceTypeMeta = const VerificationMeta(
    'resourceType',
  );
  @override
  late final GeneratedColumn<String> resourceType = GeneratedColumn<String>(
    'resource_type',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _payloadMeta = const VerificationMeta(
    'payload',
  );
  @override
  late final GeneratedColumn<String> payload = GeneratedColumn<String>(
    'payload',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _updatedAtMeta = const VerificationMeta(
    'updatedAt',
  );
  @override
  late final GeneratedColumn<DateTime> updatedAt = GeneratedColumn<DateTime>(
    'updated_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    userId,
    groupId,
    draftId,
    resourceType,
    payload,
    updatedAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'draft_records';
  @override
  VerificationContext validateIntegrity(
    Insertable<DraftRecord> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('user_id')) {
      context.handle(
        _userIdMeta,
        userId.isAcceptableOrUnknown(data['user_id']!, _userIdMeta),
      );
    } else if (isInserting) {
      context.missing(_userIdMeta);
    }
    if (data.containsKey('group_id')) {
      context.handle(
        _groupIdMeta,
        groupId.isAcceptableOrUnknown(data['group_id']!, _groupIdMeta),
      );
    } else if (isInserting) {
      context.missing(_groupIdMeta);
    }
    if (data.containsKey('draft_id')) {
      context.handle(
        _draftIdMeta,
        draftId.isAcceptableOrUnknown(data['draft_id']!, _draftIdMeta),
      );
    } else if (isInserting) {
      context.missing(_draftIdMeta);
    }
    if (data.containsKey('resource_type')) {
      context.handle(
        _resourceTypeMeta,
        resourceType.isAcceptableOrUnknown(
          data['resource_type']!,
          _resourceTypeMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_resourceTypeMeta);
    }
    if (data.containsKey('payload')) {
      context.handle(
        _payloadMeta,
        payload.isAcceptableOrUnknown(data['payload']!, _payloadMeta),
      );
    } else if (isInserting) {
      context.missing(_payloadMeta);
    }
    if (data.containsKey('updated_at')) {
      context.handle(
        _updatedAtMeta,
        updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_updatedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {userId, groupId, draftId};
  @override
  DraftRecord map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return DraftRecord(
      userId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}user_id'],
      )!,
      groupId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}group_id'],
      )!,
      draftId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}draft_id'],
      )!,
      resourceType: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}resource_type'],
      )!,
      payload: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}payload'],
      )!,
      updatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}updated_at'],
      )!,
    );
  }

  @override
  $DraftRecordsTable createAlias(String alias) {
    return $DraftRecordsTable(attachedDatabase, alias);
  }
}

class DraftRecord extends DataClass implements Insertable<DraftRecord> {
  final int userId;
  final int groupId;
  final String draftId;
  final String resourceType;
  final String payload;
  final DateTime updatedAt;
  const DraftRecord({
    required this.userId,
    required this.groupId,
    required this.draftId,
    required this.resourceType,
    required this.payload,
    required this.updatedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['user_id'] = Variable<int>(userId);
    map['group_id'] = Variable<int>(groupId);
    map['draft_id'] = Variable<String>(draftId);
    map['resource_type'] = Variable<String>(resourceType);
    map['payload'] = Variable<String>(payload);
    map['updated_at'] = Variable<DateTime>(updatedAt);
    return map;
  }

  DraftRecordsCompanion toCompanion(bool nullToAbsent) {
    return DraftRecordsCompanion(
      userId: Value(userId),
      groupId: Value(groupId),
      draftId: Value(draftId),
      resourceType: Value(resourceType),
      payload: Value(payload),
      updatedAt: Value(updatedAt),
    );
  }

  factory DraftRecord.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return DraftRecord(
      userId: serializer.fromJson<int>(json['userId']),
      groupId: serializer.fromJson<int>(json['groupId']),
      draftId: serializer.fromJson<String>(json['draftId']),
      resourceType: serializer.fromJson<String>(json['resourceType']),
      payload: serializer.fromJson<String>(json['payload']),
      updatedAt: serializer.fromJson<DateTime>(json['updatedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'userId': serializer.toJson<int>(userId),
      'groupId': serializer.toJson<int>(groupId),
      'draftId': serializer.toJson<String>(draftId),
      'resourceType': serializer.toJson<String>(resourceType),
      'payload': serializer.toJson<String>(payload),
      'updatedAt': serializer.toJson<DateTime>(updatedAt),
    };
  }

  DraftRecord copyWith({
    int? userId,
    int? groupId,
    String? draftId,
    String? resourceType,
    String? payload,
    DateTime? updatedAt,
  }) => DraftRecord(
    userId: userId ?? this.userId,
    groupId: groupId ?? this.groupId,
    draftId: draftId ?? this.draftId,
    resourceType: resourceType ?? this.resourceType,
    payload: payload ?? this.payload,
    updatedAt: updatedAt ?? this.updatedAt,
  );
  DraftRecord copyWithCompanion(DraftRecordsCompanion data) {
    return DraftRecord(
      userId: data.userId.present ? data.userId.value : this.userId,
      groupId: data.groupId.present ? data.groupId.value : this.groupId,
      draftId: data.draftId.present ? data.draftId.value : this.draftId,
      resourceType: data.resourceType.present
          ? data.resourceType.value
          : this.resourceType,
      payload: data.payload.present ? data.payload.value : this.payload,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('DraftRecord(')
          ..write('userId: $userId, ')
          ..write('groupId: $groupId, ')
          ..write('draftId: $draftId, ')
          ..write('resourceType: $resourceType, ')
          ..write('payload: $payload, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode =>
      Object.hash(userId, groupId, draftId, resourceType, payload, updatedAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is DraftRecord &&
          other.userId == this.userId &&
          other.groupId == this.groupId &&
          other.draftId == this.draftId &&
          other.resourceType == this.resourceType &&
          other.payload == this.payload &&
          other.updatedAt == this.updatedAt);
}

class DraftRecordsCompanion extends UpdateCompanion<DraftRecord> {
  final Value<int> userId;
  final Value<int> groupId;
  final Value<String> draftId;
  final Value<String> resourceType;
  final Value<String> payload;
  final Value<DateTime> updatedAt;
  final Value<int> rowid;
  const DraftRecordsCompanion({
    this.userId = const Value.absent(),
    this.groupId = const Value.absent(),
    this.draftId = const Value.absent(),
    this.resourceType = const Value.absent(),
    this.payload = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  DraftRecordsCompanion.insert({
    required int userId,
    required int groupId,
    required String draftId,
    required String resourceType,
    required String payload,
    required DateTime updatedAt,
    this.rowid = const Value.absent(),
  }) : userId = Value(userId),
       groupId = Value(groupId),
       draftId = Value(draftId),
       resourceType = Value(resourceType),
       payload = Value(payload),
       updatedAt = Value(updatedAt);
  static Insertable<DraftRecord> custom({
    Expression<int>? userId,
    Expression<int>? groupId,
    Expression<String>? draftId,
    Expression<String>? resourceType,
    Expression<String>? payload,
    Expression<DateTime>? updatedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (userId != null) 'user_id': userId,
      if (groupId != null) 'group_id': groupId,
      if (draftId != null) 'draft_id': draftId,
      if (resourceType != null) 'resource_type': resourceType,
      if (payload != null) 'payload': payload,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  DraftRecordsCompanion copyWith({
    Value<int>? userId,
    Value<int>? groupId,
    Value<String>? draftId,
    Value<String>? resourceType,
    Value<String>? payload,
    Value<DateTime>? updatedAt,
    Value<int>? rowid,
  }) {
    return DraftRecordsCompanion(
      userId: userId ?? this.userId,
      groupId: groupId ?? this.groupId,
      draftId: draftId ?? this.draftId,
      resourceType: resourceType ?? this.resourceType,
      payload: payload ?? this.payload,
      updatedAt: updatedAt ?? this.updatedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (userId.present) {
      map['user_id'] = Variable<int>(userId.value);
    }
    if (groupId.present) {
      map['group_id'] = Variable<int>(groupId.value);
    }
    if (draftId.present) {
      map['draft_id'] = Variable<String>(draftId.value);
    }
    if (resourceType.present) {
      map['resource_type'] = Variable<String>(resourceType.value);
    }
    if (payload.present) {
      map['payload'] = Variable<String>(payload.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<DateTime>(updatedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('DraftRecordsCompanion(')
          ..write('userId: $userId, ')
          ..write('groupId: $groupId, ')
          ..write('draftId: $draftId, ')
          ..write('resourceType: $resourceType, ')
          ..write('payload: $payload, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $OutboxOperationsTable extends OutboxOperations
    with TableInfo<$OutboxOperationsTable, OutboxOperation> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $OutboxOperationsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _userIdMeta = const VerificationMeta('userId');
  @override
  late final GeneratedColumn<int> userId = GeneratedColumn<int>(
    'user_id',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _groupIdMeta = const VerificationMeta(
    'groupId',
  );
  @override
  late final GeneratedColumn<int> groupId = GeneratedColumn<int>(
    'group_id',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _clientRequestIdMeta = const VerificationMeta(
    'clientRequestId',
  );
  @override
  late final GeneratedColumn<String> clientRequestId = GeneratedColumn<String>(
    'client_request_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _resourceTypeMeta = const VerificationMeta(
    'resourceType',
  );
  @override
  late final GeneratedColumn<String> resourceType = GeneratedColumn<String>(
    'resource_type',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _operationTypeMeta = const VerificationMeta(
    'operationType',
  );
  @override
  late final GeneratedColumn<String> operationType = GeneratedColumn<String>(
    'operation_type',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _payloadMeta = const VerificationMeta(
    'payload',
  );
  @override
  late final GeneratedColumn<String> payload = GeneratedColumn<String>(
    'payload',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _attemptCountMeta = const VerificationMeta(
    'attemptCount',
  );
  @override
  late final GeneratedColumn<int> attemptCount = GeneratedColumn<int>(
    'attempt_count',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant<int>(0),
  );
  static const VerificationMeta _nextRetryAtMeta = const VerificationMeta(
    'nextRetryAt',
  );
  @override
  late final GeneratedColumn<DateTime> nextRetryAt = GeneratedColumn<DateTime>(
    'next_retry_at',
    aliasedName,
    true,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _errorSummaryMeta = const VerificationMeta(
    'errorSummary',
  );
  @override
  late final GeneratedColumn<String> errorSummary = GeneratedColumn<String>(
    'error_summary',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _statusMeta = const VerificationMeta('status');
  @override
  late final GeneratedColumn<String> status = GeneratedColumn<String>(
    'status',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant<String>('pending'),
  );
  @override
  List<GeneratedColumn> get $columns => [
    userId,
    groupId,
    clientRequestId,
    resourceType,
    operationType,
    payload,
    attemptCount,
    nextRetryAt,
    errorSummary,
    status,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'outbox_operations';
  @override
  VerificationContext validateIntegrity(
    Insertable<OutboxOperation> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('user_id')) {
      context.handle(
        _userIdMeta,
        userId.isAcceptableOrUnknown(data['user_id']!, _userIdMeta),
      );
    } else if (isInserting) {
      context.missing(_userIdMeta);
    }
    if (data.containsKey('group_id')) {
      context.handle(
        _groupIdMeta,
        groupId.isAcceptableOrUnknown(data['group_id']!, _groupIdMeta),
      );
    } else if (isInserting) {
      context.missing(_groupIdMeta);
    }
    if (data.containsKey('client_request_id')) {
      context.handle(
        _clientRequestIdMeta,
        clientRequestId.isAcceptableOrUnknown(
          data['client_request_id']!,
          _clientRequestIdMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_clientRequestIdMeta);
    }
    if (data.containsKey('resource_type')) {
      context.handle(
        _resourceTypeMeta,
        resourceType.isAcceptableOrUnknown(
          data['resource_type']!,
          _resourceTypeMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_resourceTypeMeta);
    }
    if (data.containsKey('operation_type')) {
      context.handle(
        _operationTypeMeta,
        operationType.isAcceptableOrUnknown(
          data['operation_type']!,
          _operationTypeMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_operationTypeMeta);
    }
    if (data.containsKey('payload')) {
      context.handle(
        _payloadMeta,
        payload.isAcceptableOrUnknown(data['payload']!, _payloadMeta),
      );
    } else if (isInserting) {
      context.missing(_payloadMeta);
    }
    if (data.containsKey('attempt_count')) {
      context.handle(
        _attemptCountMeta,
        attemptCount.isAcceptableOrUnknown(
          data['attempt_count']!,
          _attemptCountMeta,
        ),
      );
    }
    if (data.containsKey('next_retry_at')) {
      context.handle(
        _nextRetryAtMeta,
        nextRetryAt.isAcceptableOrUnknown(
          data['next_retry_at']!,
          _nextRetryAtMeta,
        ),
      );
    }
    if (data.containsKey('error_summary')) {
      context.handle(
        _errorSummaryMeta,
        errorSummary.isAcceptableOrUnknown(
          data['error_summary']!,
          _errorSummaryMeta,
        ),
      );
    }
    if (data.containsKey('status')) {
      context.handle(
        _statusMeta,
        status.isAcceptableOrUnknown(data['status']!, _statusMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {userId, groupId, clientRequestId};
  @override
  OutboxOperation map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return OutboxOperation(
      userId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}user_id'],
      )!,
      groupId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}group_id'],
      )!,
      clientRequestId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}client_request_id'],
      )!,
      resourceType: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}resource_type'],
      )!,
      operationType: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}operation_type'],
      )!,
      payload: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}payload'],
      )!,
      attemptCount: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}attempt_count'],
      )!,
      nextRetryAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}next_retry_at'],
      ),
      errorSummary: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}error_summary'],
      ),
      status: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}status'],
      )!,
    );
  }

  @override
  $OutboxOperationsTable createAlias(String alias) {
    return $OutboxOperationsTable(attachedDatabase, alias);
  }
}

class OutboxOperation extends DataClass implements Insertable<OutboxOperation> {
  final int userId;
  final int groupId;
  final String clientRequestId;
  final String resourceType;
  final String operationType;
  final String payload;
  final int attemptCount;
  final DateTime? nextRetryAt;
  final String? errorSummary;
  final String status;
  const OutboxOperation({
    required this.userId,
    required this.groupId,
    required this.clientRequestId,
    required this.resourceType,
    required this.operationType,
    required this.payload,
    required this.attemptCount,
    this.nextRetryAt,
    this.errorSummary,
    required this.status,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['user_id'] = Variable<int>(userId);
    map['group_id'] = Variable<int>(groupId);
    map['client_request_id'] = Variable<String>(clientRequestId);
    map['resource_type'] = Variable<String>(resourceType);
    map['operation_type'] = Variable<String>(operationType);
    map['payload'] = Variable<String>(payload);
    map['attempt_count'] = Variable<int>(attemptCount);
    if (!nullToAbsent || nextRetryAt != null) {
      map['next_retry_at'] = Variable<DateTime>(nextRetryAt);
    }
    if (!nullToAbsent || errorSummary != null) {
      map['error_summary'] = Variable<String>(errorSummary);
    }
    map['status'] = Variable<String>(status);
    return map;
  }

  OutboxOperationsCompanion toCompanion(bool nullToAbsent) {
    return OutboxOperationsCompanion(
      userId: Value(userId),
      groupId: Value(groupId),
      clientRequestId: Value(clientRequestId),
      resourceType: Value(resourceType),
      operationType: Value(operationType),
      payload: Value(payload),
      attemptCount: Value(attemptCount),
      nextRetryAt: nextRetryAt == null && nullToAbsent
          ? const Value.absent()
          : Value(nextRetryAt),
      errorSummary: errorSummary == null && nullToAbsent
          ? const Value.absent()
          : Value(errorSummary),
      status: Value(status),
    );
  }

  factory OutboxOperation.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return OutboxOperation(
      userId: serializer.fromJson<int>(json['userId']),
      groupId: serializer.fromJson<int>(json['groupId']),
      clientRequestId: serializer.fromJson<String>(json['clientRequestId']),
      resourceType: serializer.fromJson<String>(json['resourceType']),
      operationType: serializer.fromJson<String>(json['operationType']),
      payload: serializer.fromJson<String>(json['payload']),
      attemptCount: serializer.fromJson<int>(json['attemptCount']),
      nextRetryAt: serializer.fromJson<DateTime?>(json['nextRetryAt']),
      errorSummary: serializer.fromJson<String?>(json['errorSummary']),
      status: serializer.fromJson<String>(json['status']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'userId': serializer.toJson<int>(userId),
      'groupId': serializer.toJson<int>(groupId),
      'clientRequestId': serializer.toJson<String>(clientRequestId),
      'resourceType': serializer.toJson<String>(resourceType),
      'operationType': serializer.toJson<String>(operationType),
      'payload': serializer.toJson<String>(payload),
      'attemptCount': serializer.toJson<int>(attemptCount),
      'nextRetryAt': serializer.toJson<DateTime?>(nextRetryAt),
      'errorSummary': serializer.toJson<String?>(errorSummary),
      'status': serializer.toJson<String>(status),
    };
  }

  OutboxOperation copyWith({
    int? userId,
    int? groupId,
    String? clientRequestId,
    String? resourceType,
    String? operationType,
    String? payload,
    int? attemptCount,
    Value<DateTime?> nextRetryAt = const Value.absent(),
    Value<String?> errorSummary = const Value.absent(),
    String? status,
  }) => OutboxOperation(
    userId: userId ?? this.userId,
    groupId: groupId ?? this.groupId,
    clientRequestId: clientRequestId ?? this.clientRequestId,
    resourceType: resourceType ?? this.resourceType,
    operationType: operationType ?? this.operationType,
    payload: payload ?? this.payload,
    attemptCount: attemptCount ?? this.attemptCount,
    nextRetryAt: nextRetryAt.present ? nextRetryAt.value : this.nextRetryAt,
    errorSummary: errorSummary.present ? errorSummary.value : this.errorSummary,
    status: status ?? this.status,
  );
  OutboxOperation copyWithCompanion(OutboxOperationsCompanion data) {
    return OutboxOperation(
      userId: data.userId.present ? data.userId.value : this.userId,
      groupId: data.groupId.present ? data.groupId.value : this.groupId,
      clientRequestId: data.clientRequestId.present
          ? data.clientRequestId.value
          : this.clientRequestId,
      resourceType: data.resourceType.present
          ? data.resourceType.value
          : this.resourceType,
      operationType: data.operationType.present
          ? data.operationType.value
          : this.operationType,
      payload: data.payload.present ? data.payload.value : this.payload,
      attemptCount: data.attemptCount.present
          ? data.attemptCount.value
          : this.attemptCount,
      nextRetryAt: data.nextRetryAt.present
          ? data.nextRetryAt.value
          : this.nextRetryAt,
      errorSummary: data.errorSummary.present
          ? data.errorSummary.value
          : this.errorSummary,
      status: data.status.present ? data.status.value : this.status,
    );
  }

  @override
  String toString() {
    return (StringBuffer('OutboxOperation(')
          ..write('userId: $userId, ')
          ..write('groupId: $groupId, ')
          ..write('clientRequestId: $clientRequestId, ')
          ..write('resourceType: $resourceType, ')
          ..write('operationType: $operationType, ')
          ..write('payload: $payload, ')
          ..write('attemptCount: $attemptCount, ')
          ..write('nextRetryAt: $nextRetryAt, ')
          ..write('errorSummary: $errorSummary, ')
          ..write('status: $status')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    userId,
    groupId,
    clientRequestId,
    resourceType,
    operationType,
    payload,
    attemptCount,
    nextRetryAt,
    errorSummary,
    status,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is OutboxOperation &&
          other.userId == this.userId &&
          other.groupId == this.groupId &&
          other.clientRequestId == this.clientRequestId &&
          other.resourceType == this.resourceType &&
          other.operationType == this.operationType &&
          other.payload == this.payload &&
          other.attemptCount == this.attemptCount &&
          other.nextRetryAt == this.nextRetryAt &&
          other.errorSummary == this.errorSummary &&
          other.status == this.status);
}

class OutboxOperationsCompanion extends UpdateCompanion<OutboxOperation> {
  final Value<int> userId;
  final Value<int> groupId;
  final Value<String> clientRequestId;
  final Value<String> resourceType;
  final Value<String> operationType;
  final Value<String> payload;
  final Value<int> attemptCount;
  final Value<DateTime?> nextRetryAt;
  final Value<String?> errorSummary;
  final Value<String> status;
  final Value<int> rowid;
  const OutboxOperationsCompanion({
    this.userId = const Value.absent(),
    this.groupId = const Value.absent(),
    this.clientRequestId = const Value.absent(),
    this.resourceType = const Value.absent(),
    this.operationType = const Value.absent(),
    this.payload = const Value.absent(),
    this.attemptCount = const Value.absent(),
    this.nextRetryAt = const Value.absent(),
    this.errorSummary = const Value.absent(),
    this.status = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  OutboxOperationsCompanion.insert({
    required int userId,
    required int groupId,
    required String clientRequestId,
    required String resourceType,
    required String operationType,
    required String payload,
    this.attemptCount = const Value.absent(),
    this.nextRetryAt = const Value.absent(),
    this.errorSummary = const Value.absent(),
    this.status = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : userId = Value(userId),
       groupId = Value(groupId),
       clientRequestId = Value(clientRequestId),
       resourceType = Value(resourceType),
       operationType = Value(operationType),
       payload = Value(payload);
  static Insertable<OutboxOperation> custom({
    Expression<int>? userId,
    Expression<int>? groupId,
    Expression<String>? clientRequestId,
    Expression<String>? resourceType,
    Expression<String>? operationType,
    Expression<String>? payload,
    Expression<int>? attemptCount,
    Expression<DateTime>? nextRetryAt,
    Expression<String>? errorSummary,
    Expression<String>? status,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (userId != null) 'user_id': userId,
      if (groupId != null) 'group_id': groupId,
      if (clientRequestId != null) 'client_request_id': clientRequestId,
      if (resourceType != null) 'resource_type': resourceType,
      if (operationType != null) 'operation_type': operationType,
      if (payload != null) 'payload': payload,
      if (attemptCount != null) 'attempt_count': attemptCount,
      if (nextRetryAt != null) 'next_retry_at': nextRetryAt,
      if (errorSummary != null) 'error_summary': errorSummary,
      if (status != null) 'status': status,
      if (rowid != null) 'rowid': rowid,
    });
  }

  OutboxOperationsCompanion copyWith({
    Value<int>? userId,
    Value<int>? groupId,
    Value<String>? clientRequestId,
    Value<String>? resourceType,
    Value<String>? operationType,
    Value<String>? payload,
    Value<int>? attemptCount,
    Value<DateTime?>? nextRetryAt,
    Value<String?>? errorSummary,
    Value<String>? status,
    Value<int>? rowid,
  }) {
    return OutboxOperationsCompanion(
      userId: userId ?? this.userId,
      groupId: groupId ?? this.groupId,
      clientRequestId: clientRequestId ?? this.clientRequestId,
      resourceType: resourceType ?? this.resourceType,
      operationType: operationType ?? this.operationType,
      payload: payload ?? this.payload,
      attemptCount: attemptCount ?? this.attemptCount,
      nextRetryAt: nextRetryAt ?? this.nextRetryAt,
      errorSummary: errorSummary ?? this.errorSummary,
      status: status ?? this.status,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (userId.present) {
      map['user_id'] = Variable<int>(userId.value);
    }
    if (groupId.present) {
      map['group_id'] = Variable<int>(groupId.value);
    }
    if (clientRequestId.present) {
      map['client_request_id'] = Variable<String>(clientRequestId.value);
    }
    if (resourceType.present) {
      map['resource_type'] = Variable<String>(resourceType.value);
    }
    if (operationType.present) {
      map['operation_type'] = Variable<String>(operationType.value);
    }
    if (payload.present) {
      map['payload'] = Variable<String>(payload.value);
    }
    if (attemptCount.present) {
      map['attempt_count'] = Variable<int>(attemptCount.value);
    }
    if (nextRetryAt.present) {
      map['next_retry_at'] = Variable<DateTime>(nextRetryAt.value);
    }
    if (errorSummary.present) {
      map['error_summary'] = Variable<String>(errorSummary.value);
    }
    if (status.present) {
      map['status'] = Variable<String>(status.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('OutboxOperationsCompanion(')
          ..write('userId: $userId, ')
          ..write('groupId: $groupId, ')
          ..write('clientRequestId: $clientRequestId, ')
          ..write('resourceType: $resourceType, ')
          ..write('operationType: $operationType, ')
          ..write('payload: $payload, ')
          ..write('attemptCount: $attemptCount, ')
          ..write('nextRetryAt: $nextRetryAt, ')
          ..write('errorSummary: $errorSummary, ')
          ..write('status: $status, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

abstract class _$AppDatabase extends GeneratedDatabase {
  _$AppDatabase(QueryExecutor e) : super(e);
  $AppDatabaseManager get managers => $AppDatabaseManager(this);
  late final $CachedMembersTable cachedMembers = $CachedMembersTable(this);
  late final $CachedMemberPermissionsTable cachedMemberPermissions =
      $CachedMemberPermissionsTable(this);
  late final $CachedDictionaryEntriesTable cachedDictionaryEntries =
      $CachedDictionaryEntriesTable(this);
  late final $DraftRecordsTable draftRecords = $DraftRecordsTable(this);
  late final $OutboxOperationsTable outboxOperations = $OutboxOperationsTable(
    this,
  );
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [
    cachedMembers,
    cachedMemberPermissions,
    cachedDictionaryEntries,
    draftRecords,
    outboxOperations,
  ];
}

typedef $$CachedMembersTableCreateCompanionBuilder =
    CachedMembersCompanion Function({
      required int userId,
      required int groupId,
      required int membershipId,
      required String username,
      required String displayName,
      required String memberType,
      required String status,
      required int version,
      Value<int> rowid,
    });
typedef $$CachedMembersTableUpdateCompanionBuilder =
    CachedMembersCompanion Function({
      Value<int> userId,
      Value<int> groupId,
      Value<int> membershipId,
      Value<String> username,
      Value<String> displayName,
      Value<String> memberType,
      Value<String> status,
      Value<int> version,
      Value<int> rowid,
    });

class $$CachedMembersTableFilterComposer
    extends Composer<_$AppDatabase, $CachedMembersTable> {
  $$CachedMembersTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get userId => $composableBuilder(
    column: $table.userId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get groupId => $composableBuilder(
    column: $table.groupId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get membershipId => $composableBuilder(
    column: $table.membershipId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get username => $composableBuilder(
    column: $table.username,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get displayName => $composableBuilder(
    column: $table.displayName,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get memberType => $composableBuilder(
    column: $table.memberType,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get status => $composableBuilder(
    column: $table.status,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get version => $composableBuilder(
    column: $table.version,
    builder: (column) => ColumnFilters(column),
  );
}

class $$CachedMembersTableOrderingComposer
    extends Composer<_$AppDatabase, $CachedMembersTable> {
  $$CachedMembersTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get userId => $composableBuilder(
    column: $table.userId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get groupId => $composableBuilder(
    column: $table.groupId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get membershipId => $composableBuilder(
    column: $table.membershipId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get username => $composableBuilder(
    column: $table.username,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get displayName => $composableBuilder(
    column: $table.displayName,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get memberType => $composableBuilder(
    column: $table.memberType,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get status => $composableBuilder(
    column: $table.status,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get version => $composableBuilder(
    column: $table.version,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$CachedMembersTableAnnotationComposer
    extends Composer<_$AppDatabase, $CachedMembersTable> {
  $$CachedMembersTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get userId =>
      $composableBuilder(column: $table.userId, builder: (column) => column);

  GeneratedColumn<int> get groupId =>
      $composableBuilder(column: $table.groupId, builder: (column) => column);

  GeneratedColumn<int> get membershipId => $composableBuilder(
    column: $table.membershipId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get username =>
      $composableBuilder(column: $table.username, builder: (column) => column);

  GeneratedColumn<String> get displayName => $composableBuilder(
    column: $table.displayName,
    builder: (column) => column,
  );

  GeneratedColumn<String> get memberType => $composableBuilder(
    column: $table.memberType,
    builder: (column) => column,
  );

  GeneratedColumn<String> get status =>
      $composableBuilder(column: $table.status, builder: (column) => column);

  GeneratedColumn<int> get version =>
      $composableBuilder(column: $table.version, builder: (column) => column);
}

class $$CachedMembersTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $CachedMembersTable,
          CachedMember,
          $$CachedMembersTableFilterComposer,
          $$CachedMembersTableOrderingComposer,
          $$CachedMembersTableAnnotationComposer,
          $$CachedMembersTableCreateCompanionBuilder,
          $$CachedMembersTableUpdateCompanionBuilder,
          (
            CachedMember,
            BaseReferences<_$AppDatabase, $CachedMembersTable, CachedMember>,
          ),
          CachedMember,
          PrefetchHooks Function()
        > {
  $$CachedMembersTableTableManager(_$AppDatabase db, $CachedMembersTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$CachedMembersTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$CachedMembersTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$CachedMembersTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<int> userId = const Value.absent(),
                Value<int> groupId = const Value.absent(),
                Value<int> membershipId = const Value.absent(),
                Value<String> username = const Value.absent(),
                Value<String> displayName = const Value.absent(),
                Value<String> memberType = const Value.absent(),
                Value<String> status = const Value.absent(),
                Value<int> version = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => CachedMembersCompanion(
                userId: userId,
                groupId: groupId,
                membershipId: membershipId,
                username: username,
                displayName: displayName,
                memberType: memberType,
                status: status,
                version: version,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required int userId,
                required int groupId,
                required int membershipId,
                required String username,
                required String displayName,
                required String memberType,
                required String status,
                required int version,
                Value<int> rowid = const Value.absent(),
              }) => CachedMembersCompanion.insert(
                userId: userId,
                groupId: groupId,
                membershipId: membershipId,
                username: username,
                displayName: displayName,
                memberType: memberType,
                status: status,
                version: version,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$CachedMembersTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $CachedMembersTable,
      CachedMember,
      $$CachedMembersTableFilterComposer,
      $$CachedMembersTableOrderingComposer,
      $$CachedMembersTableAnnotationComposer,
      $$CachedMembersTableCreateCompanionBuilder,
      $$CachedMembersTableUpdateCompanionBuilder,
      (
        CachedMember,
        BaseReferences<_$AppDatabase, $CachedMembersTable, CachedMember>,
      ),
      CachedMember,
      PrefetchHooks Function()
    >;
typedef $$CachedMemberPermissionsTableCreateCompanionBuilder =
    CachedMemberPermissionsCompanion Function({
      required int userId,
      required int groupId,
      required int membershipId,
      required String permissionCodes,
      required int version,
      Value<int> rowid,
    });
typedef $$CachedMemberPermissionsTableUpdateCompanionBuilder =
    CachedMemberPermissionsCompanion Function({
      Value<int> userId,
      Value<int> groupId,
      Value<int> membershipId,
      Value<String> permissionCodes,
      Value<int> version,
      Value<int> rowid,
    });

class $$CachedMemberPermissionsTableFilterComposer
    extends Composer<_$AppDatabase, $CachedMemberPermissionsTable> {
  $$CachedMemberPermissionsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get userId => $composableBuilder(
    column: $table.userId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get groupId => $composableBuilder(
    column: $table.groupId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get membershipId => $composableBuilder(
    column: $table.membershipId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get permissionCodes => $composableBuilder(
    column: $table.permissionCodes,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get version => $composableBuilder(
    column: $table.version,
    builder: (column) => ColumnFilters(column),
  );
}

class $$CachedMemberPermissionsTableOrderingComposer
    extends Composer<_$AppDatabase, $CachedMemberPermissionsTable> {
  $$CachedMemberPermissionsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get userId => $composableBuilder(
    column: $table.userId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get groupId => $composableBuilder(
    column: $table.groupId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get membershipId => $composableBuilder(
    column: $table.membershipId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get permissionCodes => $composableBuilder(
    column: $table.permissionCodes,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get version => $composableBuilder(
    column: $table.version,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$CachedMemberPermissionsTableAnnotationComposer
    extends Composer<_$AppDatabase, $CachedMemberPermissionsTable> {
  $$CachedMemberPermissionsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get userId =>
      $composableBuilder(column: $table.userId, builder: (column) => column);

  GeneratedColumn<int> get groupId =>
      $composableBuilder(column: $table.groupId, builder: (column) => column);

  GeneratedColumn<int> get membershipId => $composableBuilder(
    column: $table.membershipId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get permissionCodes => $composableBuilder(
    column: $table.permissionCodes,
    builder: (column) => column,
  );

  GeneratedColumn<int> get version =>
      $composableBuilder(column: $table.version, builder: (column) => column);
}

class $$CachedMemberPermissionsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $CachedMemberPermissionsTable,
          CachedMemberPermission,
          $$CachedMemberPermissionsTableFilterComposer,
          $$CachedMemberPermissionsTableOrderingComposer,
          $$CachedMemberPermissionsTableAnnotationComposer,
          $$CachedMemberPermissionsTableCreateCompanionBuilder,
          $$CachedMemberPermissionsTableUpdateCompanionBuilder,
          (
            CachedMemberPermission,
            BaseReferences<
              _$AppDatabase,
              $CachedMemberPermissionsTable,
              CachedMemberPermission
            >,
          ),
          CachedMemberPermission,
          PrefetchHooks Function()
        > {
  $$CachedMemberPermissionsTableTableManager(
    _$AppDatabase db,
    $CachedMemberPermissionsTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$CachedMemberPermissionsTableFilterComposer(
                $db: db,
                $table: table,
              ),
          createOrderingComposer: () =>
              $$CachedMemberPermissionsTableOrderingComposer(
                $db: db,
                $table: table,
              ),
          createComputedFieldComposer: () =>
              $$CachedMemberPermissionsTableAnnotationComposer(
                $db: db,
                $table: table,
              ),
          updateCompanionCallback:
              ({
                Value<int> userId = const Value.absent(),
                Value<int> groupId = const Value.absent(),
                Value<int> membershipId = const Value.absent(),
                Value<String> permissionCodes = const Value.absent(),
                Value<int> version = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => CachedMemberPermissionsCompanion(
                userId: userId,
                groupId: groupId,
                membershipId: membershipId,
                permissionCodes: permissionCodes,
                version: version,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required int userId,
                required int groupId,
                required int membershipId,
                required String permissionCodes,
                required int version,
                Value<int> rowid = const Value.absent(),
              }) => CachedMemberPermissionsCompanion.insert(
                userId: userId,
                groupId: groupId,
                membershipId: membershipId,
                permissionCodes: permissionCodes,
                version: version,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$CachedMemberPermissionsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $CachedMemberPermissionsTable,
      CachedMemberPermission,
      $$CachedMemberPermissionsTableFilterComposer,
      $$CachedMemberPermissionsTableOrderingComposer,
      $$CachedMemberPermissionsTableAnnotationComposer,
      $$CachedMemberPermissionsTableCreateCompanionBuilder,
      $$CachedMemberPermissionsTableUpdateCompanionBuilder,
      (
        CachedMemberPermission,
        BaseReferences<
          _$AppDatabase,
          $CachedMemberPermissionsTable,
          CachedMemberPermission
        >,
      ),
      CachedMemberPermission,
      PrefetchHooks Function()
    >;
typedef $$CachedDictionaryEntriesTableCreateCompanionBuilder =
    CachedDictionaryEntriesCompanion Function({
      required int userId,
      required int groupId,
      required int dictionaryId,
      required String kind,
      required String name,
      Value<int?> parentId,
      Value<String?> contact,
      required String status,
      required int version,
      Value<int> rowid,
    });
typedef $$CachedDictionaryEntriesTableUpdateCompanionBuilder =
    CachedDictionaryEntriesCompanion Function({
      Value<int> userId,
      Value<int> groupId,
      Value<int> dictionaryId,
      Value<String> kind,
      Value<String> name,
      Value<int?> parentId,
      Value<String?> contact,
      Value<String> status,
      Value<int> version,
      Value<int> rowid,
    });

class $$CachedDictionaryEntriesTableFilterComposer
    extends Composer<_$AppDatabase, $CachedDictionaryEntriesTable> {
  $$CachedDictionaryEntriesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get userId => $composableBuilder(
    column: $table.userId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get groupId => $composableBuilder(
    column: $table.groupId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get dictionaryId => $composableBuilder(
    column: $table.dictionaryId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get kind => $composableBuilder(
    column: $table.kind,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get parentId => $composableBuilder(
    column: $table.parentId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get contact => $composableBuilder(
    column: $table.contact,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get status => $composableBuilder(
    column: $table.status,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get version => $composableBuilder(
    column: $table.version,
    builder: (column) => ColumnFilters(column),
  );
}

class $$CachedDictionaryEntriesTableOrderingComposer
    extends Composer<_$AppDatabase, $CachedDictionaryEntriesTable> {
  $$CachedDictionaryEntriesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get userId => $composableBuilder(
    column: $table.userId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get groupId => $composableBuilder(
    column: $table.groupId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get dictionaryId => $composableBuilder(
    column: $table.dictionaryId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get kind => $composableBuilder(
    column: $table.kind,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get parentId => $composableBuilder(
    column: $table.parentId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get contact => $composableBuilder(
    column: $table.contact,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get status => $composableBuilder(
    column: $table.status,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get version => $composableBuilder(
    column: $table.version,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$CachedDictionaryEntriesTableAnnotationComposer
    extends Composer<_$AppDatabase, $CachedDictionaryEntriesTable> {
  $$CachedDictionaryEntriesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get userId =>
      $composableBuilder(column: $table.userId, builder: (column) => column);

  GeneratedColumn<int> get groupId =>
      $composableBuilder(column: $table.groupId, builder: (column) => column);

  GeneratedColumn<int> get dictionaryId => $composableBuilder(
    column: $table.dictionaryId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get kind =>
      $composableBuilder(column: $table.kind, builder: (column) => column);

  GeneratedColumn<String> get name =>
      $composableBuilder(column: $table.name, builder: (column) => column);

  GeneratedColumn<int> get parentId =>
      $composableBuilder(column: $table.parentId, builder: (column) => column);

  GeneratedColumn<String> get contact =>
      $composableBuilder(column: $table.contact, builder: (column) => column);

  GeneratedColumn<String> get status =>
      $composableBuilder(column: $table.status, builder: (column) => column);

  GeneratedColumn<int> get version =>
      $composableBuilder(column: $table.version, builder: (column) => column);
}

class $$CachedDictionaryEntriesTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $CachedDictionaryEntriesTable,
          CachedDictionaryEntry,
          $$CachedDictionaryEntriesTableFilterComposer,
          $$CachedDictionaryEntriesTableOrderingComposer,
          $$CachedDictionaryEntriesTableAnnotationComposer,
          $$CachedDictionaryEntriesTableCreateCompanionBuilder,
          $$CachedDictionaryEntriesTableUpdateCompanionBuilder,
          (
            CachedDictionaryEntry,
            BaseReferences<
              _$AppDatabase,
              $CachedDictionaryEntriesTable,
              CachedDictionaryEntry
            >,
          ),
          CachedDictionaryEntry,
          PrefetchHooks Function()
        > {
  $$CachedDictionaryEntriesTableTableManager(
    _$AppDatabase db,
    $CachedDictionaryEntriesTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$CachedDictionaryEntriesTableFilterComposer(
                $db: db,
                $table: table,
              ),
          createOrderingComposer: () =>
              $$CachedDictionaryEntriesTableOrderingComposer(
                $db: db,
                $table: table,
              ),
          createComputedFieldComposer: () =>
              $$CachedDictionaryEntriesTableAnnotationComposer(
                $db: db,
                $table: table,
              ),
          updateCompanionCallback:
              ({
                Value<int> userId = const Value.absent(),
                Value<int> groupId = const Value.absent(),
                Value<int> dictionaryId = const Value.absent(),
                Value<String> kind = const Value.absent(),
                Value<String> name = const Value.absent(),
                Value<int?> parentId = const Value.absent(),
                Value<String?> contact = const Value.absent(),
                Value<String> status = const Value.absent(),
                Value<int> version = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => CachedDictionaryEntriesCompanion(
                userId: userId,
                groupId: groupId,
                dictionaryId: dictionaryId,
                kind: kind,
                name: name,
                parentId: parentId,
                contact: contact,
                status: status,
                version: version,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required int userId,
                required int groupId,
                required int dictionaryId,
                required String kind,
                required String name,
                Value<int?> parentId = const Value.absent(),
                Value<String?> contact = const Value.absent(),
                required String status,
                required int version,
                Value<int> rowid = const Value.absent(),
              }) => CachedDictionaryEntriesCompanion.insert(
                userId: userId,
                groupId: groupId,
                dictionaryId: dictionaryId,
                kind: kind,
                name: name,
                parentId: parentId,
                contact: contact,
                status: status,
                version: version,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$CachedDictionaryEntriesTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $CachedDictionaryEntriesTable,
      CachedDictionaryEntry,
      $$CachedDictionaryEntriesTableFilterComposer,
      $$CachedDictionaryEntriesTableOrderingComposer,
      $$CachedDictionaryEntriesTableAnnotationComposer,
      $$CachedDictionaryEntriesTableCreateCompanionBuilder,
      $$CachedDictionaryEntriesTableUpdateCompanionBuilder,
      (
        CachedDictionaryEntry,
        BaseReferences<
          _$AppDatabase,
          $CachedDictionaryEntriesTable,
          CachedDictionaryEntry
        >,
      ),
      CachedDictionaryEntry,
      PrefetchHooks Function()
    >;
typedef $$DraftRecordsTableCreateCompanionBuilder =
    DraftRecordsCompanion Function({
      required int userId,
      required int groupId,
      required String draftId,
      required String resourceType,
      required String payload,
      required DateTime updatedAt,
      Value<int> rowid,
    });
typedef $$DraftRecordsTableUpdateCompanionBuilder =
    DraftRecordsCompanion Function({
      Value<int> userId,
      Value<int> groupId,
      Value<String> draftId,
      Value<String> resourceType,
      Value<String> payload,
      Value<DateTime> updatedAt,
      Value<int> rowid,
    });

class $$DraftRecordsTableFilterComposer
    extends Composer<_$AppDatabase, $DraftRecordsTable> {
  $$DraftRecordsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get userId => $composableBuilder(
    column: $table.userId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get groupId => $composableBuilder(
    column: $table.groupId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get draftId => $composableBuilder(
    column: $table.draftId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get resourceType => $composableBuilder(
    column: $table.resourceType,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get payload => $composableBuilder(
    column: $table.payload,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$DraftRecordsTableOrderingComposer
    extends Composer<_$AppDatabase, $DraftRecordsTable> {
  $$DraftRecordsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get userId => $composableBuilder(
    column: $table.userId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get groupId => $composableBuilder(
    column: $table.groupId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get draftId => $composableBuilder(
    column: $table.draftId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get resourceType => $composableBuilder(
    column: $table.resourceType,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get payload => $composableBuilder(
    column: $table.payload,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$DraftRecordsTableAnnotationComposer
    extends Composer<_$AppDatabase, $DraftRecordsTable> {
  $$DraftRecordsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get userId =>
      $composableBuilder(column: $table.userId, builder: (column) => column);

  GeneratedColumn<int> get groupId =>
      $composableBuilder(column: $table.groupId, builder: (column) => column);

  GeneratedColumn<String> get draftId =>
      $composableBuilder(column: $table.draftId, builder: (column) => column);

  GeneratedColumn<String> get resourceType => $composableBuilder(
    column: $table.resourceType,
    builder: (column) => column,
  );

  GeneratedColumn<String> get payload =>
      $composableBuilder(column: $table.payload, builder: (column) => column);

  GeneratedColumn<DateTime> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);
}

class $$DraftRecordsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $DraftRecordsTable,
          DraftRecord,
          $$DraftRecordsTableFilterComposer,
          $$DraftRecordsTableOrderingComposer,
          $$DraftRecordsTableAnnotationComposer,
          $$DraftRecordsTableCreateCompanionBuilder,
          $$DraftRecordsTableUpdateCompanionBuilder,
          (
            DraftRecord,
            BaseReferences<_$AppDatabase, $DraftRecordsTable, DraftRecord>,
          ),
          DraftRecord,
          PrefetchHooks Function()
        > {
  $$DraftRecordsTableTableManager(_$AppDatabase db, $DraftRecordsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$DraftRecordsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$DraftRecordsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$DraftRecordsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<int> userId = const Value.absent(),
                Value<int> groupId = const Value.absent(),
                Value<String> draftId = const Value.absent(),
                Value<String> resourceType = const Value.absent(),
                Value<String> payload = const Value.absent(),
                Value<DateTime> updatedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => DraftRecordsCompanion(
                userId: userId,
                groupId: groupId,
                draftId: draftId,
                resourceType: resourceType,
                payload: payload,
                updatedAt: updatedAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required int userId,
                required int groupId,
                required String draftId,
                required String resourceType,
                required String payload,
                required DateTime updatedAt,
                Value<int> rowid = const Value.absent(),
              }) => DraftRecordsCompanion.insert(
                userId: userId,
                groupId: groupId,
                draftId: draftId,
                resourceType: resourceType,
                payload: payload,
                updatedAt: updatedAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$DraftRecordsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $DraftRecordsTable,
      DraftRecord,
      $$DraftRecordsTableFilterComposer,
      $$DraftRecordsTableOrderingComposer,
      $$DraftRecordsTableAnnotationComposer,
      $$DraftRecordsTableCreateCompanionBuilder,
      $$DraftRecordsTableUpdateCompanionBuilder,
      (
        DraftRecord,
        BaseReferences<_$AppDatabase, $DraftRecordsTable, DraftRecord>,
      ),
      DraftRecord,
      PrefetchHooks Function()
    >;
typedef $$OutboxOperationsTableCreateCompanionBuilder =
    OutboxOperationsCompanion Function({
      required int userId,
      required int groupId,
      required String clientRequestId,
      required String resourceType,
      required String operationType,
      required String payload,
      Value<int> attemptCount,
      Value<DateTime?> nextRetryAt,
      Value<String?> errorSummary,
      Value<String> status,
      Value<int> rowid,
    });
typedef $$OutboxOperationsTableUpdateCompanionBuilder =
    OutboxOperationsCompanion Function({
      Value<int> userId,
      Value<int> groupId,
      Value<String> clientRequestId,
      Value<String> resourceType,
      Value<String> operationType,
      Value<String> payload,
      Value<int> attemptCount,
      Value<DateTime?> nextRetryAt,
      Value<String?> errorSummary,
      Value<String> status,
      Value<int> rowid,
    });

class $$OutboxOperationsTableFilterComposer
    extends Composer<_$AppDatabase, $OutboxOperationsTable> {
  $$OutboxOperationsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get userId => $composableBuilder(
    column: $table.userId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get groupId => $composableBuilder(
    column: $table.groupId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get clientRequestId => $composableBuilder(
    column: $table.clientRequestId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get resourceType => $composableBuilder(
    column: $table.resourceType,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get operationType => $composableBuilder(
    column: $table.operationType,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get payload => $composableBuilder(
    column: $table.payload,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get attemptCount => $composableBuilder(
    column: $table.attemptCount,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get nextRetryAt => $composableBuilder(
    column: $table.nextRetryAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get errorSummary => $composableBuilder(
    column: $table.errorSummary,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get status => $composableBuilder(
    column: $table.status,
    builder: (column) => ColumnFilters(column),
  );
}

class $$OutboxOperationsTableOrderingComposer
    extends Composer<_$AppDatabase, $OutboxOperationsTable> {
  $$OutboxOperationsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get userId => $composableBuilder(
    column: $table.userId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get groupId => $composableBuilder(
    column: $table.groupId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get clientRequestId => $composableBuilder(
    column: $table.clientRequestId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get resourceType => $composableBuilder(
    column: $table.resourceType,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get operationType => $composableBuilder(
    column: $table.operationType,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get payload => $composableBuilder(
    column: $table.payload,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get attemptCount => $composableBuilder(
    column: $table.attemptCount,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get nextRetryAt => $composableBuilder(
    column: $table.nextRetryAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get errorSummary => $composableBuilder(
    column: $table.errorSummary,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get status => $composableBuilder(
    column: $table.status,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$OutboxOperationsTableAnnotationComposer
    extends Composer<_$AppDatabase, $OutboxOperationsTable> {
  $$OutboxOperationsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get userId =>
      $composableBuilder(column: $table.userId, builder: (column) => column);

  GeneratedColumn<int> get groupId =>
      $composableBuilder(column: $table.groupId, builder: (column) => column);

  GeneratedColumn<String> get clientRequestId => $composableBuilder(
    column: $table.clientRequestId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get resourceType => $composableBuilder(
    column: $table.resourceType,
    builder: (column) => column,
  );

  GeneratedColumn<String> get operationType => $composableBuilder(
    column: $table.operationType,
    builder: (column) => column,
  );

  GeneratedColumn<String> get payload =>
      $composableBuilder(column: $table.payload, builder: (column) => column);

  GeneratedColumn<int> get attemptCount => $composableBuilder(
    column: $table.attemptCount,
    builder: (column) => column,
  );

  GeneratedColumn<DateTime> get nextRetryAt => $composableBuilder(
    column: $table.nextRetryAt,
    builder: (column) => column,
  );

  GeneratedColumn<String> get errorSummary => $composableBuilder(
    column: $table.errorSummary,
    builder: (column) => column,
  );

  GeneratedColumn<String> get status =>
      $composableBuilder(column: $table.status, builder: (column) => column);
}

class $$OutboxOperationsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $OutboxOperationsTable,
          OutboxOperation,
          $$OutboxOperationsTableFilterComposer,
          $$OutboxOperationsTableOrderingComposer,
          $$OutboxOperationsTableAnnotationComposer,
          $$OutboxOperationsTableCreateCompanionBuilder,
          $$OutboxOperationsTableUpdateCompanionBuilder,
          (
            OutboxOperation,
            BaseReferences<
              _$AppDatabase,
              $OutboxOperationsTable,
              OutboxOperation
            >,
          ),
          OutboxOperation,
          PrefetchHooks Function()
        > {
  $$OutboxOperationsTableTableManager(
    _$AppDatabase db,
    $OutboxOperationsTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$OutboxOperationsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$OutboxOperationsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$OutboxOperationsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<int> userId = const Value.absent(),
                Value<int> groupId = const Value.absent(),
                Value<String> clientRequestId = const Value.absent(),
                Value<String> resourceType = const Value.absent(),
                Value<String> operationType = const Value.absent(),
                Value<String> payload = const Value.absent(),
                Value<int> attemptCount = const Value.absent(),
                Value<DateTime?> nextRetryAt = const Value.absent(),
                Value<String?> errorSummary = const Value.absent(),
                Value<String> status = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => OutboxOperationsCompanion(
                userId: userId,
                groupId: groupId,
                clientRequestId: clientRequestId,
                resourceType: resourceType,
                operationType: operationType,
                payload: payload,
                attemptCount: attemptCount,
                nextRetryAt: nextRetryAt,
                errorSummary: errorSummary,
                status: status,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required int userId,
                required int groupId,
                required String clientRequestId,
                required String resourceType,
                required String operationType,
                required String payload,
                Value<int> attemptCount = const Value.absent(),
                Value<DateTime?> nextRetryAt = const Value.absent(),
                Value<String?> errorSummary = const Value.absent(),
                Value<String> status = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => OutboxOperationsCompanion.insert(
                userId: userId,
                groupId: groupId,
                clientRequestId: clientRequestId,
                resourceType: resourceType,
                operationType: operationType,
                payload: payload,
                attemptCount: attemptCount,
                nextRetryAt: nextRetryAt,
                errorSummary: errorSummary,
                status: status,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$OutboxOperationsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $OutboxOperationsTable,
      OutboxOperation,
      $$OutboxOperationsTableFilterComposer,
      $$OutboxOperationsTableOrderingComposer,
      $$OutboxOperationsTableAnnotationComposer,
      $$OutboxOperationsTableCreateCompanionBuilder,
      $$OutboxOperationsTableUpdateCompanionBuilder,
      (
        OutboxOperation,
        BaseReferences<_$AppDatabase, $OutboxOperationsTable, OutboxOperation>,
      ),
      OutboxOperation,
      PrefetchHooks Function()
    >;

class $AppDatabaseManager {
  final _$AppDatabase _db;
  $AppDatabaseManager(this._db);
  $$CachedMembersTableTableManager get cachedMembers =>
      $$CachedMembersTableTableManager(_db, _db.cachedMembers);
  $$CachedMemberPermissionsTableTableManager get cachedMemberPermissions =>
      $$CachedMemberPermissionsTableTableManager(
        _db,
        _db.cachedMemberPermissions,
      );
  $$CachedDictionaryEntriesTableTableManager get cachedDictionaryEntries =>
      $$CachedDictionaryEntriesTableTableManager(
        _db,
        _db.cachedDictionaryEntries,
      );
  $$DraftRecordsTableTableManager get draftRecords =>
      $$DraftRecordsTableTableManager(_db, _db.draftRecords);
  $$OutboxOperationsTableTableManager get outboxOperations =>
      $$OutboxOperationsTableTableManager(_db, _db.outboxOperations);
}
