/// 邀请码相关的测试夹具。
///
/// 上半部分是**严格照抄契约字段名**的 JSON（`InvitationSummaryData` /
/// `InvitationSecretData` / `InvitationPageData`），供仓储解析测试与领域解析测试
/// 共用；下半部分是按领域对象构造的夹具，供 Controller 测试用（那些用例关心的是
/// 时序与明文生命周期，构造一堆 JSON 再解析只会把注意力引开）。
library;

import 'package:c_biz_docs_manager/core/network/page_result.dart';
import 'package:c_biz_docs_manager/features/invitations/domain/invitation.dart';

/* ------------------------------------------------------------- JSON 夹具 */

/// `InvitationSummaryData`。
///
/// [includeOptionalTimes] 用来区分服务的两种真实形态：Go 侧给 `used_at` /
/// `revoked_at` 加了 `omitempty`，未使用 / 未撤销时**字段根本不出现**；
/// 而契约把它们标成 `nullable: true`，读起来像是会显式给 null。
/// 解析必须两种都吃下，所以夹具也要能造出两种。
Map<String, Object?> invitationSummaryJson({
  Object? invitationId = 9,
  Object? status = 'active',
  Object? expiresAt = '2026-03-01T00:00:00Z',
  Object? usedAt,
  Object? revokedAt,
  Object? createdAt = '2026-02-01T00:00:00Z',
  Object? version = 1,
  bool includeOptionalTimes = false,
}) {
  final json = <String, Object?>{
    'invitation_id': invitationId,
    'status': status,
    'expires_at': expiresAt,
    'created_at': createdAt,
    'version': version,
  };
  if (includeOptionalTimes) {
    json['used_at'] = usedAt;
    json['revoked_at'] = revokedAt;
  } else {
    if (usedAt != null) json['used_at'] = usedAt;
    if (revokedAt != null) json['revoked_at'] = revokedAt;
  }
  return json;
}

/// `InvitationSecretData`。
Map<String, Object?> invitationSecretJson({
  Object? invitationId = 9,
  Object? invitationCode = 'INV-ABCD-EFGH',
  Object? expiresAt = '2026-03-01T00:00:00Z',
}) => <String, Object?>{
  'invitation_id': invitationId,
  'invitation_code': invitationCode,
  'expires_at': expiresAt,
};

/// `InvitationPageData`。
Map<String, Object?> invitationPageJson({
  Object? items,
  Object? page = 1,
  Object? pageSize = 20,
  Object? total = 1,
}) => <String, Object?>{
  'items': items ?? <Object?>[invitationSummaryJson()],
  'page': page,
  'page_size': pageSize,
  'total': total,
};

/* -------------------------------------------------- 领域对象夹具（Controller 用） */

InvitationSummary domainInvitation({
  int id = 9,
  InvitationStatus status = InvitationStatus.active,
  DateTime? expiresAt,
  DateTime? usedAt,
  DateTime? revokedAt,
  int version = 1,
}) => InvitationSummary(
  id: id,
  status: status,
  expiresAt: expiresAt ?? DateTime.utc(2026, 3, 1),
  usedAt: usedAt,
  revokedAt: revokedAt,
  createdAt: DateTime.utc(2026, 2, 1),
  version: version,
);

InvitationSecret domainSecret({
  int invitationId = 9,
  String code = 'INV-ABCD-EFGH',
  DateTime? expiresAt,
}) => InvitationSecret(
  invitationId: invitationId,
  code: code,
  expiresAt: expiresAt ?? DateTime.utc(2026, 3, 1),
);

PageResult<InvitationSummary> domainInvitationPage({
  List<InvitationSummary>? items,
  int page = 1,
  int pageSize = 20,
  int total = 1,
}) => PageResult<InvitationSummary>(
  items: items ?? <InvitationSummary>[domainInvitation()],
  page: page,
  pageSize: pageSize,
  total: total,
);
