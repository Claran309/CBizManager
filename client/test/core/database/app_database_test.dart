import 'package:c_biz_docs_manager/core/database/app_database.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppDatabase database;

  setUp(() {
    database = AppDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() => database.close());

  test('schema contains all five offline tables', () {
    expect(
      database.allTables.map((table) => table.actualTableName),
      containsAll(<String>[
        'cached_members',
        'cached_member_permissions',
        'cached_dictionary_entries',
        'draft_records',
        'outbox_operations',
      ]),
    );
  });

  test(
    'member cache replaces one user and group without leaking scope',
    () async {
      await database.replaceCachedMembers(
        userId: 1,
        groupId: 10,
        entries: const <CachedMemberWrite>[
          CachedMemberWrite(
            membershipId: 100,
            username: 'alice',
            displayName: 'Alice',
            memberType: 'member',
            status: 'active',
            version: 1,
          ),
        ],
      );
      await database.replaceCachedMembers(
        userId: 1,
        groupId: 10,
        entries: const <CachedMemberWrite>[
          CachedMemberWrite(
            membershipId: 100,
            username: 'alice',
            displayName: 'Alice Updated',
            memberType: 'member',
            status: 'inactive',
            version: 2,
          ),
        ],
      );
      await database.replaceCachedMembers(
        userId: 2,
        groupId: 10,
        entries: const <CachedMemberWrite>[
          CachedMemberWrite(
            membershipId: 200,
            username: 'bob',
            displayName: 'Bob',
            memberType: 'member',
            status: 'active',
            version: 1,
          ),
        ],
      );

      final alice = await database.listCachedMembers(userId: 1, groupId: 10);
      expect(alice, hasLength(1));
      expect(alice.single.displayName, 'Alice Updated');
      expect(alice.single.version, 2);
      expect(await database.listCachedMembers(userId: 1, groupId: 11), isEmpty);
      expect(
        await database.listCachedMembers(userId: 2, groupId: 10),
        hasLength(1),
      );
    },
  );

  test(
    'permission and dictionary caches keep user and group in every key',
    () async {
      await database.replaceCachedMemberPermissions(
        userId: 1,
        groupId: 10,
        membershipId: 100,
        permissionCodes: const <String>{'member.manage'},
        version: 3,
      );
      await database.replaceCachedDictionaryEntries(
        userId: 1,
        groupId: 10,
        kind: 'product',
        entries: const <CachedDictionaryWrite>[
          CachedDictionaryWrite(
            dictionaryId: 7,
            name: 'Paper',
            contact: 'Alice',
            status: 'active',
            version: 1,
          ),
        ],
      );

      expect(
        await database.listCachedMemberPermissions(
          userId: 1,
          groupId: 10,
          membershipId: 100,
        ),
        <String>{'member.manage'},
      );
      expect(
        await database.listCachedMemberPermissions(
          userId: 2,
          groupId: 10,
          membershipId: 100,
        ),
        isEmpty,
      );
      await database.replaceCachedMemberPermissions(
        userId: 1,
        groupId: 10,
        membershipId: 100,
        permissionCodes: const <String>{},
        version: 4,
      );
      final emptySnapshot = await database.getCachedMemberPermissions(
        userId: 1,
        groupId: 10,
        membershipId: 100,
      );
      expect(emptySnapshot?.permissionCodes, isEmpty);
      expect(emptySnapshot?.version, 4);
      final entries = await database.listCachedDictionaryEntries(
        userId: 1,
        groupId: 10,
        kind: 'product',
      );
      expect(entries.single.contact, 'Alice');
      expect(
        await database.listCachedDictionaryEntries(
          userId: 1,
          groupId: 11,
          kind: 'product',
        ),
        isEmpty,
      );
    },
  );

  test('draft CRUD is isolated by user and group', () async {
    await database.saveDraft(
      userId: 1,
      groupId: 10,
      draftId: 'draft-1',
      resourceType: 'document',
      payload: '{"value":1}',
      updatedAt: DateTime.utc(2026, 7, 24),
    );

    expect(
      (await database.getDraft(
        userId: 1,
        groupId: 10,
        draftId: 'draft-1',
      ))?.payload,
      '{"value":1}',
    );
    expect(
      await database.getDraft(userId: 2, groupId: 10, draftId: 'draft-1'),
      isNull,
    );

    await database.deleteDraft(userId: 1, groupId: 10, draftId: 'draft-1');
    expect(
      await database.getDraft(userId: 1, groupId: 10, draftId: 'draft-1'),
      isNull,
    );
  });

  test('outbox permits the same request id in separate user scopes', () async {
    for (final userId in <int>[1, 2]) {
      await database.enqueueOutboxOperation(
        userId: userId,
        groupId: 10,
        clientRequestId: 'request-1',
        resourceType: 'document',
        operationType: 'create',
        payload: '{"owner":$userId}',
      );
    }

    final firstUser = await database.listOutboxOperations(
      userId: 1,
      groupId: 10,
    );
    expect(firstUser, hasLength(1));
    expect(firstUser.single.payload, '{"owner":1}');
    expect(
      await database.listOutboxOperations(userId: 1, groupId: 11),
      isEmpty,
    );
    expect(
      await database.listOutboxOperations(userId: 2, groupId: 10),
      hasLength(1),
    );
  });
}
