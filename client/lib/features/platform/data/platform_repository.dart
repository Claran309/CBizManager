import 'package:c_biz_docs_manager/core/error/app_failure.dart';
import 'package:c_biz_docs_manager/core/network/api_envelope.dart';
import 'package:c_biz_docs_manager/core/network/error_mapper.dart';
import 'package:c_biz_docs_manager/core/network/page_result.dart';
import 'package:c_biz_docs_manager/features/platform/domain/platform_group.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 平台治理仓储的装配点。
///
/// 与租户侧仓储不同，它**不持有** `userId` / `groupId`：平台管理员不属于任何组，
/// 看到的是全平台的组，没有可以拿来收敛数据范围的「自己那一份」。
/// 也正因如此，它只能由平台管理员的会话作用域装配；租户读到这里是配置事故，
/// 所以默认实现直接抛 [StateError] 而不是给个能读到数据的兜底。
final platformRepositoryProvider = Provider<PlatformRepository>((Ref ref) {
  throw StateError('PlatformRepository has not been configured');
});

/// 平台治理的数据入口。
///
/// 只暴露契约里存在的那五个动作，不多不少。特别地，这里**没有**任何
/// 「按关键字搜组」「导出组」之类的扩展方法 —— 平台管理员能看的组是全量，
/// 每多一个入口就多一处需要单独复核权限的地方。
abstract interface class PlatformRepository {
  /// 分页查询业务组。返回的是**一页**，翻页由调用方决定，本层不自动聚合。
  Future<PageResult<PlatformGroup>> listGroups(PlatformGroupQuery query);

  /// 查询单个组的治理详情（含成员聚合与可提升候选人）。
  Future<PlatformGroupDetail> getGroup(int groupId);

  /// 创建组及其主账号。
  Future<CreateGroupResult> createGroup(CreateGroupDraft draft);

  /// 停用或启用组；[version] 为乐观锁凭据。
  Future<PlatformGroup> changeStatus(
    int groupId,
    GroupStatus status,
    int version,
  );

  /// 交接组主账号；返回交接后的最新详情。
  Future<PlatformGroupDetail> changeOwner(int groupId, OwnerChangeDraft draft);
}

/// 走 HTTP 的平台治理仓储。
///
/// 只依赖一个 [Dio]，**不接受** `AppDatabase` 或 Outbox。这条约束不是随手定的：
///
/// - 平台数据是跨租户的，本地的缓存表都以 `(user_id, group_id)` 为键，
///   而平台管理员根本没有 group，缓存键取不出来 —— 强行落盘只能落到
///   `group_id = 0` 这种垃圾桶里，日后谁读到都不清楚它属于谁。
/// - 停用整个组、交接主账号这类操作具有全局破坏性，离线排队等网络恢复再偷偷
///   执行，比当场失败危险得多。所以宁可在断网时直接报「需要联网」。
///
/// 该约束有测试守着（跑完全部方法后本地库与 Outbox 仍为空）。
final class DioPlatformRepository implements PlatformRepository {
  DioPlatformRepository(this._dio);

  final Dio _dio;

  /// 契约里的固定前缀，五个动作都挂在它下面。
  static const _path = '/api/v1/platform/groups';

  @override
  Future<PageResult<PlatformGroup>> listGroups(PlatformGroupQuery query) =>
      _guard(() async {
        final response = await _dio.get<Object?>(
          _path,
          queryParameters: <String, Object?>{
            'page': query.page,
            'page_size': query.pageSize,
            // 可选筛选项用「有才带」的写法：显式传 status=null 会被序列化成
            // 空串，服务端按非法枚举拒绝，于是「不筛状态」反而报错。
            if (query.status != null) 'status': query.status!.wireValue,
            if (query.keyword != null && query.keyword!.isNotEmpty)
              'keyword': query.keyword,
          },
        );
        return PageResult<PlatformGroup>.fromJson(
          _readData(response.data),
          PlatformGroup.fromJson,
        );
      });

  @override
  Future<PlatformGroupDetail> getGroup(int groupId) => _guard(() async {
    final response = await _dio.get<Object?>('$_path/$groupId');
    return PlatformGroupDetail.fromJson(_readData(response.data));
  });

  @override
  Future<CreateGroupResult> createGroup(CreateGroupDraft draft) =>
      _guard(() async {
        final response = await _dio.post<Object?>(
          _path,
          data: <String, Object?>{
            'name': draft.name,
            'owner_username': draft.ownerUsername,
            'owner_display_name': draft.ownerDisplayName,
            'owner_temporary_password': draft.ownerTemporaryPassword,
          },
        );
        return CreateGroupResult.fromJson(_readData(response.data));
      });

  @override
  Future<PlatformGroup> changeStatus(
    int groupId,
    GroupStatus status,
    int version,
  ) => _guard(() async {
    final response = await _dio.patch<Object?>(
      '$_path/$groupId/status',
      data: <String, Object?>{'status': status.wireValue, 'version': version},
    );
    return PlatformGroup.fromJson(_readData(response.data));
  });

  @override
  Future<PlatformGroupDetail> changeOwner(
    int groupId,
    OwnerChangeDraft draft,
  ) => _guard(() async {
    await _dio.put<Object?>('$_path/$groupId/owner', data: _ownerBody(draft));
    // 交接的响应（`OwnerChangedData`）只回 group 与 owner 两个字段，没有成员聚合
    // 和候选列表。而调用方要的是一份**自洽**的详情 —— 被提升的人必须从候选人
    // 里消失、成员计数要跟着变。所以写完立刻重读一次，代价是 1 次额外请求，
    // 换来的是界面不会出现「主账号已经换了、候选列表还挂着旧人」这种短暂不一致。
    return getGroup(groupId);
  });

  /// 按模式拼装互斥的请求体。
  ///
  /// [OwnerChangeDraft] 是 sealed 的，`switch` 因此是**穷尽**的：将来若新增一种
  /// 交接模式，这里会直接编译不过，而不是悄悄沿用旧字段发一个语义错误的请求。
  /// 这正是把两种模式做成两个子类、而不是「一个大对象 + 可空字段」的意义。
  Map<String, Object?> _ownerBody(OwnerChangeDraft draft) => switch (draft) {
    ExistingMemberOwnerDraft(:final membershipId, :final version) =>
      <String, Object?>{
        'mode': draft.mode.wireValue,
        'membership_id': membershipId,
        'version': version,
      },
    NewAccountOwnerDraft(
      :final username,
      :final displayName,
      :final temporaryPassword,
      :final version,
    ) =>
      <String, Object?>{
        'mode': draft.mode.wireValue,
        'username': username,
        'display_name': displayName,
        'temporary_password': temporaryPassword,
        'version': version,
      },
  };
}

/// 把传输层与契约解析的异常统一收敛成 [AppFailure]。
///
/// 与 dictionaries / members 仓储里的同名辅助保持一致：只有变成 [AppFailure]，
/// 上层控制器的 `on AppFailure catch` 才接得住。否则一次 409（组被别处改过）
/// 会以原始 [DioException] 逃逸出状态机，页面既拿不到「请刷新后重试」的语义，
/// 也拿不到服务端的 request id。
Future<T> _guard<T>(Future<T> Function() operation) async {
  try {
    return await operation();
  } on DioException catch (error) {
    throw mapDioFailure(error);
  } on FormatException {
    throw const ServerFailure('Invalid server response');
  } on TypeError {
    throw const ServerFailure('Invalid server response');
  }
}

/// 拆开统一响应信封，取出 `data` 对象。
Map<String, Object?> _readData(Object? raw) {
  if (raw is! Map) {
    throw const FormatException('API response must be an object');
  }
  final envelope = ApiEnvelope<Map<String, Object?>>.fromJson(
    Map<String, Object?>.from(raw),
    (value) => Map<String, Object?>.from(value as Map),
  );
  final data = envelope.data;
  if (data == null) {
    throw const FormatException('API response data is required');
  }
  return data;
}
