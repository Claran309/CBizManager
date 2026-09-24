import 'package:c_biz_docs_manager/core/error/app_failure.dart';
import 'package:c_biz_docs_manager/core/network/api_envelope.dart';
import 'package:c_biz_docs_manager/core/network/error_mapper.dart';
import 'package:c_biz_docs_manager/core/network/page_result.dart';
import 'package:c_biz_docs_manager/features/invitations/domain/invitation.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 邀请码仓储的装配点。
///
/// 与平台治理仓储一样**不持有** `userId` / `groupId`：数据范围由服务端按令牌里的
/// 身份收敛，客户端能做的只是「别把它装配给不该看的人」。所以默认实现直接抛
/// [StateError]，只能由组主账号的会话作用域覆盖。
final invitationRepositoryProvider = Provider<InvitationRepository>((Ref ref) {
  throw StateError('InvitationRepository has not been configured');
});

/// 邀请码的数据入口。
///
/// 只有契约里的四个动作，不多不少。特别地，这里**没有**「按状态/时间本地过滤」
/// 之类的扩展：邀请码的状态投影（active + 已过期 → expired）是服务端的职责，
/// 客户端再算一遍只会产出第二个真相。
abstract interface class InvitationRepository {
  /// 分页查询邀请码。列表**永不**返回邀请码明文或密文。
  Future<PageResult<InvitationSummary>> list({
    InvitationStatus? status,
    int page = 1,
    int pageSize = 20,
  });

  /// 创建一个新邀请码，返回**明文**（仅此一次机会拿到）。
  ///
  /// [expiresInDays] 省略时由服务端取默认值 7 天（契约 `default: 7`）。
  Future<InvitationSecret> create({int? expiresInDays});

  /// 查看仍有效（active 且未过期）的邀请码明文。
  Future<InvitationSecret> revealSecret(int invitationId);

  /// 撤销邀请码；[version] 为乐观锁凭据。
  Future<InvitationSummary> revoke(int invitationId, int version);
}

/// 走 HTTP 的邀请码仓储。
///
/// 只依赖一个 [Dio]，**不接受** `AppDatabase` / `CredentialStore` / Outbox。
/// 这条约束不是随手定的：
///
/// - 邀请码明文一旦落盘就等于长期有效凭证泄漏 —— 磁盘镜像、备份、甚至
///   别的进程读一下沙箱目录都能拿到。所以它只允许存在于内存里。
/// - 撤销是与服务端状态强交互的操作（乐观锁 + 状态机），离线排队等网络恢复再
///   偷偷执行的话，用户以为撤销了、其实邀请码在等待期间一直有效。
///
/// 服务端对「查看明文」的响应固定带 `Cache-Control: no-store`。本层**不去读
/// 也不去校验**那个头：客户端本来就不缓存任何响应，把安全建立在「我们从不落盘」
/// 上，比建立在「某个响应头恰好存在」上要可靠 —— 后者一旦被人改掉，
/// 这里不会有任何提示。
final class DioInvitationRepository implements InvitationRepository {
  DioInvitationRepository(this._dio);

  final Dio _dio;

  /// 契约里的固定前缀，四个动作都挂在它下面。
  static const _path = '/api/v1/groups/invitations';

  @override
  Future<PageResult<InvitationSummary>> list({
    InvitationStatus? status,
    int page = 1,
    int pageSize = 20,
  }) => _guard(() async {
    final response = await _dio.get<Object?>(
      _path,
      queryParameters: <String, Object?>{
        'page': page,
        'page_size': pageSize,
        // 可选筛选用「有才带」的写法：显式传 status=null 会被序列化成空串，
        // 服务端按非法枚举拒绝，于是「不筛状态」反而报 400。
        if (status != null) 'status': status.wireValue,
      },
    );
    return PageResult<InvitationSummary>.fromJson(
      _readData(response.data),
      InvitationSummary.fromJson,
    );
  });

  @override
  Future<InvitationSecret> create({int? expiresInDays}) => _guard(() async {
    final response = await _dio.post<Object?>(
      _path,
      // 即使一个字段都不带也要发 `{}`：服务端的 `ShouldBindJSON` 在空 body 上
      // 会直接报 EOF 并回 400，而契约里 `expires_in_days` 是**可选**的
      // （缺省即 7 天），所以「不指定有效期」必须是合法请求。
      // 这里用 null-aware 元素（`key: ?value`）：值为 null 时整条 entry 被省略，
      // 于是「不指定有效期」发出去的就是一个合法的空对象。
      data: <String, Object?>{'expires_in_days': ?expiresInDays},
    );
    return InvitationSecret.fromJson(_readData(response.data));
  });

  @override
  Future<InvitationSecret> revealSecret(int invitationId) => _guard(() async {
    final response = await _dio.post<Object?>('$_path/$invitationId/secret');
    // 只把明文留在返回的内存对象里：这里不写任何本地状态、不打日志。
    return InvitationSecret.fromJson(_readData(response.data));
  });

  @override
  Future<InvitationSummary> revoke(int invitationId, int version) =>
      _guard(() async {
        final response = await _dio.post<Object?>(
          '$_path/$invitationId/revoke',
          data: <String, Object?>{'version': version},
        );
        return InvitationSummary.fromJson(_readData(response.data));
      });
}

/// 把传输层与契约解析的异常统一收敛成 [AppFailure]。
///
/// 与其它仓储的同名辅助保持一致：只有变成 [AppFailure]，上层控制器的
/// `on AppFailure catch` 才接得住；否则一次 409（邀请码已被别处撤销）
/// 会以原始 [DioException] 逃逸出状态机。
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
