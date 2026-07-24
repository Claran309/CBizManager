import 'dart:convert';

import 'package:c_biz_docs_manager/core/database/database_connection.dart';
import 'package:c_biz_docs_manager/core/sync/outbox.dart';
import 'package:drift/drift.dart';

part 'app_database.g.dart';

class CachedMembers extends Table {
  IntColumn get userId => integer()();
  IntColumn get groupId => integer()();
  IntColumn get membershipId => integer()();
  TextColumn get username => text()();
  TextColumn get displayName => text()();
  TextColumn get memberType => text()();
  TextColumn get status => text()();
  IntColumn get version => integer()();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{
    userId,
    groupId,
    membershipId,
  };
}

class CachedMemberPermissions extends Table {
  IntColumn get userId => integer()();
  IntColumn get groupId => integer()();
  IntColumn get membershipId => integer()();
  TextColumn get permissionCodes => text()();
  IntColumn get version => integer()();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{
    userId,
    groupId,
    membershipId,
  };
}

class CachedDictionaryEntries extends Table {
  IntColumn get userId => integer()();
  IntColumn get groupId => integer()();
  IntColumn get dictionaryId => integer()();
  TextColumn get kind => text()();
  TextColumn get name => text()();
  IntColumn get parentId => integer().nullable()();
  TextColumn get contact => text().nullable()();
  TextColumn get status => text()();
  IntColumn get version => integer()();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{
    userId,
    groupId,
    dictionaryId,
  };
}

class DraftRecords extends Table {
  IntColumn get userId => integer()();
  IntColumn get groupId => integer()();
  TextColumn get draftId => text()();
  TextColumn get resourceType => text()();
  TextColumn get payload => text()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{
    userId,
    groupId,
    draftId,
  };
}

class OutboxOperations extends Table {
  IntColumn get userId => integer()();
  IntColumn get groupId => integer()();
  TextColumn get clientRequestId => text()();
  TextColumn get resourceType => text()();
  TextColumn get operationType => text()();
  TextColumn get payload => text()();
  IntColumn get attemptCount => integer().withDefault(const Constant<int>(0))();
  DateTimeColumn get nextRetryAt => dateTime().nullable()();
  TextColumn get errorSummary => text().nullable()();
  TextColumn get status =>
      text().withDefault(const Constant<String>('pending'))();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{
    userId,
    groupId,
    clientRequestId,
  };
}

final class CachedMemberWrite {
  const CachedMemberWrite({
    required this.membershipId,
    required this.username,
    required this.displayName,
    required this.memberType,
    required this.status,
    required this.version,
  });

  final int membershipId;
  final String username;
  final String displayName;
  final String memberType;
  final String status;
  final int version;
}

final class CachedDictionaryWrite {
  const CachedDictionaryWrite({
    required this.dictionaryId,
    required this.name,
    this.parentId,
    this.contact,
    required this.status,
    required this.version,
  });

  final int dictionaryId;
  final String name;
  final int? parentId;
  final String? contact;
  final String status;
  final int version;
}

final class CachedPermissionSnapshot {
  const CachedPermissionSnapshot({
    required this.permissionCodes,
    required this.version,
  });

  final Set<String> permissionCodes;
  final int version;
}

@DriftDatabase(
  tables: <Type>[
    CachedMembers,
    CachedMemberPermissions,
    CachedDictionaryEntries,
    DraftRecords,
    OutboxOperations,
  ],
)
final class AppDatabase extends _$AppDatabase {
  AppDatabase(super.executor);

  AppDatabase.forTesting(super.executor);

  static Future<AppDatabase> open() async {
    return AppDatabase(await openDatabaseConnection());
  }

  @override
  int get schemaVersion => 1;

  Future<void> replaceCachedMembers({
    required int userId,
    required int groupId,
    required List<CachedMemberWrite> entries,
  }) {
    return transaction(() async {
      await (delete(cachedMembers)..where(
            (row) => row.userId.equals(userId) & row.groupId.equals(groupId),
          ))
          .go();
      for (final entry in entries) {
        await into(cachedMembers).insert(
          CachedMembersCompanion.insert(
            userId: userId,
            groupId: groupId,
            membershipId: entry.membershipId,
            username: entry.username,
            displayName: entry.displayName,
            memberType: entry.memberType,
            status: entry.status,
            version: entry.version,
          ),
        );
      }
    });
  }

  Future<List<CachedMember>> listCachedMembers({
    required int userId,
    required int groupId,
  }) {
    return (select(cachedMembers)..where(
          (row) => row.userId.equals(userId) & row.groupId.equals(groupId),
        ))
        .get();
  }

  Future<void> replaceCachedMemberPermissions({
    required int userId,
    required int groupId,
    required int membershipId,
    required Set<String> permissionCodes,
    required int version,
  }) {
    final sortedCodes = permissionCodes.toList()..sort();
    return into(cachedMemberPermissions).insertOnConflictUpdate(
      CachedMemberPermissionsCompanion.insert(
        userId: userId,
        groupId: groupId,
        membershipId: membershipId,
        permissionCodes: jsonEncode(sortedCodes),
        version: version,
      ),
    );
  }

  Future<Set<String>> listCachedMemberPermissions({
    required int userId,
    required int groupId,
    required int membershipId,
  }) async {
    final snapshot = await getCachedMemberPermissions(
      userId: userId,
      groupId: groupId,
      membershipId: membershipId,
    );
    return snapshot?.permissionCodes ?? <String>{};
  }

  Future<CachedPermissionSnapshot?> getCachedMemberPermissions({
    required int userId,
    required int groupId,
    required int membershipId,
  }) async {
    final row =
        await (select(cachedMemberPermissions)..where(
              (row) =>
                  row.userId.equals(userId) &
                  row.groupId.equals(groupId) &
                  row.membershipId.equals(membershipId),
            ))
            .getSingleOrNull();
    if (row == null) {
      return null;
    }
    final decoded = jsonDecode(row.permissionCodes);
    if (decoded is! List) {
      throw const FormatException('Cached permission codes must be an array');
    }
    return CachedPermissionSnapshot(
      permissionCodes: <String>{for (final value in decoded) value as String},
      version: row.version,
    );
  }

  Future<void> replaceCachedDictionaryEntries({
    required int userId,
    required int groupId,
    required String kind,
    required List<CachedDictionaryWrite> entries,
  }) {
    return transaction(() async {
      await (delete(cachedDictionaryEntries)..where(
            (row) =>
                row.userId.equals(userId) &
                row.groupId.equals(groupId) &
                row.kind.equals(kind),
          ))
          .go();
      for (final entry in entries) {
        await into(cachedDictionaryEntries).insert(
          CachedDictionaryEntriesCompanion.insert(
            userId: userId,
            groupId: groupId,
            dictionaryId: entry.dictionaryId,
            kind: kind,
            name: entry.name,
            parentId: Value<int?>(entry.parentId),
            contact: Value<String?>(entry.contact),
            status: entry.status,
            version: entry.version,
          ),
        );
      }
    });
  }

  Future<List<CachedDictionaryEntry>> listCachedDictionaryEntries({
    required int userId,
    required int groupId,
    required String kind,
  }) {
    return (select(cachedDictionaryEntries)..where(
          (row) =>
              row.userId.equals(userId) &
              row.groupId.equals(groupId) &
              row.kind.equals(kind),
        ))
        .get();
  }

  Future<void> saveDraft({
    required int userId,
    required int groupId,
    required String draftId,
    required String resourceType,
    required String payload,
    required DateTime updatedAt,
  }) {
    return into(draftRecords).insertOnConflictUpdate(
      DraftRecordsCompanion.insert(
        userId: userId,
        groupId: groupId,
        draftId: draftId,
        resourceType: resourceType,
        payload: payload,
        updatedAt: updatedAt,
      ),
    );
  }

  Future<DraftRecord?> getDraft({
    required int userId,
    required int groupId,
    required String draftId,
  }) {
    return (select(draftRecords)..where(
          (row) =>
              row.userId.equals(userId) &
              row.groupId.equals(groupId) &
              row.draftId.equals(draftId),
        ))
        .getSingleOrNull();
  }

  Future<int> deleteDraft({
    required int userId,
    required int groupId,
    required String draftId,
  }) {
    return (delete(draftRecords)..where(
          (row) =>
              row.userId.equals(userId) &
              row.groupId.equals(groupId) &
              row.draftId.equals(draftId),
        ))
        .go();
  }

  Future<void> enqueueOutboxOperation({
    required int userId,
    required int groupId,
    required String clientRequestId,
    required String resourceType,
    required String operationType,
    required String payload,
  }) async {
    await into(outboxOperations).insert(
      OutboxOperationsCompanion.insert(
        userId: userId,
        groupId: groupId,
        clientRequestId: clientRequestId,
        resourceType: resourceType,
        operationType: operationType,
        payload: payload,
        status: Value<String>(OutboxStatus.pending.wireValue),
      ),
    );
  }

  Future<List<OutboxOperation>> listOutboxOperations({
    required int userId,
    required int groupId,
  }) {
    return (select(outboxOperations)..where(
          (row) => row.userId.equals(userId) & row.groupId.equals(groupId),
        ))
        .get();
  }
}
