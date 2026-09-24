import 'package:c_biz_docs_manager/features/platform/domain/platform_group.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/platform_fixtures.dart';

void main() {
  group('GroupStatus', () {
    test('线上取值可反查回枚举', () {
      // 显式钉住字面量：枚举名可以改，契约里的字符串不能改。
      expect(GroupStatus.active.wireValue, 'active');
      expect(GroupStatus.disabled.wireValue, 'disabled');
      expect(GroupStatus.fromWireValue('disabled'), GroupStatus.disabled);
    });

    test('未知取值抛 FormatException 而不是静默降级', () {
      expect(() => GroupStatus.fromWireValue('archived'), throwsFormatException);
    });
  });

  group('PlatformGroup', () {
    test('解析完整摘要并把时间归一到 UTC', () {
      final group = PlatformGroup.fromJson(platformGroupJson());

      expect(group.id, 7);
      expect(group.name, '钢材一组');
      expect(group.status, GroupStatus.active);
      expect(group.owner.username, 'owner');
      expect(group.owner.displayName, '张三');
      expect(group.memberCount, 5);
      expect(group.version, 3);
      expect(group.createdAt, DateTime.utc(2026, 1, 2, 3, 4, 5));
      expect(group.updatedAt, DateTime.utc(2026, 2, 3, 4, 5, 6));
    });

    test('带时区偏移的时间会被换算成同一个 UTC 瞬间', () {
      final group = PlatformGroup.fromJson(
        platformGroupJson(
          createdAt: '2026-01-02T11:04:05+08:00',
          updatedAt: '2026-01-02T11:04:05+08:00',
        ),
      );

      // 东八区 11:04 就是 UTC 03:04 —— 领域对象里只留一种时间基准，
      // 免得「两个时间是否相等」的判定取决于服务端这次用的什么时区。
      expect(group.createdAt, DateTime.utc(2026, 1, 2, 3, 4, 5));
      expect(group.createdAt.isUtc, isTrue);
    });

    test('相同内容相等且哈希一致', () {
      final first = PlatformGroup.fromJson(platformGroupJson());
      final second = PlatformGroup.fromJson(platformGroupJson());

      expect(first, second);
      expect(first.hashCode, second.hashCode);
      expect(first, isNot(PlatformGroup.fromJson(platformGroupJson(version: 4))));
    });

    test('缺字段或字段类型不符时抛 FormatException', () {
      expect(
        () => PlatformGroup.fromJson(platformGroupJson()..remove('owner')),
        throwsFormatException,
      );
      expect(
        () => PlatformGroup.fromJson(platformGroupJson(memberCount: '5')),
        throwsFormatException,
      );
      expect(
        () => PlatformGroup.fromJson(platformGroupJson(version: null)),
        throwsFormatException,
      );
      expect(
        () => PlatformGroup.fromJson(platformGroupJson(createdAt: 12345)),
        throwsFormatException,
      );
      expect(
        () => PlatformGroup.fromJson(platformGroupJson(status: 'archived')),
        throwsFormatException,
      );
    });

    test('时间字符串非法时同样抛 FormatException', () {
      expect(
        () => PlatformGroup.fromJson(platformGroupJson(createdAt: 'not-a-date')),
        throwsFormatException,
      );
    });
  });

  group('GroupMemberCounts', () {
    test('三个状态的人数都会被解析', () {
      final counts = GroupMemberCounts.fromJson(const <String, Object?>{
        'active': 3,
        'disabled': 1,
        'removed': 2,
      });

      expect((counts.active, counts.disabled, counts.removed), (3, 1, 2));
    });

    test('缺少任一状态键就解析失败，不静默当成 0', () {
      // 「活跃成员 0 人」是个会让人以为组被清空的假数字；
      // 缺键多半意味着服务端改了字段名，此时宁可报错。
      expect(
        () => GroupMemberCounts.fromJson(
          const <String, Object?>{'active': 3, 'disabled': 1},
        ),
        throwsFormatException,
      );
    });

    test('人数为负会被拒绝', () {
      // 契约里每个值都标了 minimum: 0；负数说明聚合算错了，不该放行到界面。
      expect(
        () => GroupMemberCounts.fromJson(const <String, Object?>{
          'active': -1,
          'disabled': 0,
          'removed': 0,
        }),
        throwsFormatException,
      );
    });
  });

  group('PlatformGroupDetail', () {
    test('解析摘要、成员聚合与候选人', () {
      final detail = PlatformGroupDetail.fromJson(
        platformGroupDetailJson(
          ownerCandidates: <Object?>[platformCandidateJson()],
        ),
      );

      expect(detail.group.id, 7);
      expect(
        detail.memberCounts,
        const GroupMemberCounts(active: 3, disabled: 1, removed: 0),
      );
      expect(detail.ownerCandidates, hasLength(1));
      expect(detail.ownerCandidates.single.membershipId, 9);
      expect(detail.ownerCandidates.single.user.displayName, '李四');
    });

    test('候选人可以为空数组', () {
      final detail = PlatformGroupDetail.fromJson(platformGroupDetailJson());

      expect(detail.ownerCandidates, isEmpty);
    });

    test('候选人列表不可修改', () {
      final detail = PlatformGroupDetail.fromJson(
        platformGroupDetailJson(
          ownerCandidates: <Object?>[platformCandidateJson()],
        ),
      );

      // 列表会直接被渲染进候选人选择器；可变列表意味着任何一处就地排序
      // 都在篡改「服务端给的这一份」，让后续比较与刷新变得不可推理。
      expect(
        () => detail.ownerCandidates.add(
          OwnerCandidate(
            membershipId: 10,
            user: PlatformOwner.fromJson(
              platformOwnerJson(id: 23, username: 'wang', displayName: '王五'),
            ),
          ),
        ),
        throwsUnsupportedError,
      );
    });

    test('候选人缺少 membership_id 时解析失败', () {
      expect(
        () => PlatformGroupDetail.fromJson(
          platformGroupDetailJson(
            ownerCandidates: <Object?>[
              <String, Object?>{'user': platformOwnerJson()},
            ],
          ),
        ),
        throwsFormatException,
      );
    });
  });

  group('PlatformGroupQuery', () {
    test('默认值对应契约里的 page=1 / page_size=20', () {
      const query = PlatformGroupQuery();

      expect(query.page, 1);
      expect(query.pageSize, 20);
      expect(query.keyword, isNull);
      expect(query.status, isNull);
    });

    test('条件相同的两个查询相等', () {
      // 控制器要靠它判断「这次筛选与上次是不是同一套」，避免原地重复请求。
      expect(
        const PlatformGroupQuery(
          keyword: '钢材',
          status: GroupStatus.disabled,
          page: 2,
        ),
        const PlatformGroupQuery(
          keyword: '钢材',
          status: GroupStatus.disabled,
          page: 2,
        ),
      );
      expect(
        const PlatformGroupQuery(page: 2),
        isNot(const PlatformGroupQuery(page: 3)),
      );
    });
  });

  group('CreateGroupResult', () {
    test('从精简的 group 与 owner 里取出创建结果', () {
      final result = CreateGroupResult.fromJson(platformGroupCreatedJson());

      expect(result.groupId, 7);
      expect(result.groupName, '钢材一组');
      expect(result.owner.username, 'owner');
    });

    test('缺少 group 时解析失败', () {
      expect(
        () => CreateGroupResult.fromJson(
          platformGroupCreatedJson()..remove('group'),
        ),
        throwsFormatException,
      );
    });
  });

  group('OwnerChangeDraft', () {
    test('既有成员模式只承载 membership_id', () {
      const draft = ExistingMemberOwnerDraft(membershipId: 9, version: 3);

      expect(draft.mode, OwnerChangeMode.existingMember);
      expect(draft.version, 3);
      expect(draft.membershipId, 9);
    });

    test('新建账号模式只承载账号三件套', () {
      const draft = NewAccountOwnerDraft(
        username: 'lisi',
        displayName: '李四',
        temporaryPassword: 'secret123',
        version: 4,
      );

      expect(draft.mode, OwnerChangeMode.newAccount);
      expect(draft.version, 4);
      expect(draft.username, 'lisi');
    });

    test('模式串与契约一致', () {
      expect(OwnerChangeMode.existingMember.wireValue, 'existing_member');
      expect(OwnerChangeMode.newAccount.wireValue, 'new_account');
    });
  });
}
