import 'package:c_biz_docs_manager/features/members/domain/member.dart';

/// 成员模块的测试夹具。
///
/// 分两类：
/// - 下面那几个 **const 实体**是「固定场景」的常用默认值，直接当常量用，
///   写起来最短（`const <Member>[memberFixture]`）。
/// - [buildMember] 是「需要微调某几个字段」时的构造器，它走真实的
///   [Member.fromJson]，所以夹具与 `UserSummary` / `MemberData` 契约始终保持同构 ——
///   契约一旦调整，全部用例会一起失败，而不是悄悄用着一份过期的手搓结构。
///
/// 身份类字段（userId / memberType）刻意留出参数：界面「这一行是不是我自己」、
/// 「这一行是不是组主账号」两处判定全靠它们，用例必须能精确控制。

/// 一个普通业务员成员：组内编号 7、账号 101、启用中、无任何权限。
const memberFixture = Member(
  membershipId: 7,
  userId: 101,
  username: 'alice',
  displayName: 'Alice',
  memberType: 'member',
  status: MemberStatus.active,
  permissionCodes: <String>{},
  version: 1,
);

/// 与 [memberFixture] 同一个人，只是已停用、版本 +1。
const disabledMemberFixture = Member(
  membershipId: 7,
  userId: 101,
  username: 'alice',
  displayName: 'Alice',
  memberType: 'member',
  status: MemberStatus.disabled,
  permissionCodes: <String>{},
  version: 2,
);

/// 与 [memberFixture] 同一个人，启用中、版本 3：用来证明写操作拿的是**服务端回的新版本**。
const newerMemberFixture = Member(
  membershipId: 7,
  userId: 101,
  username: 'alice',
  displayName: 'Alice',
  memberType: 'member',
  status: MemberStatus.active,
  permissionCodes: <String>{},
  version: 3,
);

/// 一份两项目的权限目录。
///
/// 只给两项是刻意的：权限页的复选框数量、全选与「整体替换」的载荷断言
/// 都直接读它，项目少才看得清「有没有多传/漏传」。
const catalogFixture = <PermissionCatalogItem>[
  PermissionCatalogItem(
    code: 'document.view_others',
    name: '查看他人单据',
    description: '可以查看同组其他业务员的单据',
  ),
  PermissionCatalogItem(
    code: 'member.manage',
    name: '成员管理',
    description: '可以新增、停用成员并调整权限',
  ),
];

/// 按字段构造一个成员夹具（走真实 [Member.fromJson]）。
///
/// 默认值就是 [memberFixture]，所以用例只需要写出「与默认不同的那几项」。
Member buildMember({
  int membershipId = 7,
  int userId = 101,
  String username = 'alice',
  String displayName = 'Alice',
  String memberType = 'member',
  MemberStatus status = MemberStatus.active,
  Set<String> permissionCodes = const <String>{},
  int version = 1,
}) => Member.fromJson(<String, Object?>{
  'membership_id': membershipId,
  'user': <String, Object?>{
    'id': userId,
    'username': username,
    'display_name': displayName,
  },
  'member_type': memberType,
  'status': status.wireValue,
  'permission_codes': List<Object?>.from(permissionCodes),
  'version': version,
});
