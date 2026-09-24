/// 服务端分页响应的通用容器。
///
/// 本项目所有列表接口都把 `items / page / page_size / total` **平铺**在 `data`
/// 里（见 OpenAPI 的 `GroupPageData`、`GroupSummaryData` 系列），而不是嵌一层
/// `pagination`。本类只负责把这一组字段严格地解析出来，省掉每个仓储各写一遍
/// 「取 items、取 total」的样板代码。
///
/// 为什么解码要传 [decodeItem] 回调、而不是在类里自己调 `T.fromJson`：
/// Dart 的泛型参数在运行期不带构造器信息，拿不到 `T` 的静态工厂。
/// 把「怎么把一条 JSON 变成一个 T」交给调用方注入，是这里最直接的做法。
final class PageResult<T> {
  const PageResult({
    required this.items,
    required this.page,
    required this.pageSize,
    required this.total,
  });

  /// 当前页的数据。
  final List<T> items;

  /// 当前页码，从 1 开始。
  final int page;

  /// 每页条数。这是**服务端回显**的值，可能与请求时给的不同（服务端有权收敛）。
  final int pageSize;

  /// 满足条件的总条数，不是当前页的条数 —— 后者用 `items.length`。
  final int total;

  /// 本页之后是否还有数据。
  ///
  /// 判定基于 `page * pageSize < total`：只有当服务端确实按每页 `pageSize` 条
  /// 返回时这个式子才成立，所以它依赖服务端回显的 `page` / `page_size` 准确。
  /// 若某天服务端改成不固定每页条数，这里要跟着换成「已取条数 < total」的累计口径。
  bool get hasMore => page * pageSize < total;

  /// 从分页响应的 `data` 对象解析出一页结果。
  ///
  /// 解析是**严格**的：`items` 必须是数组、每项必须是对象，三个整数字段必须存在
  /// 且落在合法区间。宁可在这里抛 [FormatException]（调用方的 `_guard` 会把它
  /// 收敛成 `ServerFailure`），也不要放行一个「页码是 0、总数是 -1」的结果 ——
  /// 那种结果会被分页控件渲染成翻不到头的空列表，比直接报错更难排查。
  factory PageResult.fromJson(
    Map<String, Object?> json,
    T Function(Map<String, Object?> item) decodeItem,
  ) {
    final rawItems = json['items'];
    if (rawItems is! List) {
      throw const FormatException('PageResult items must be an array');
    }
    return PageResult<T>(
      items: List<T>.unmodifiable(<T>[
        for (final item in rawItems) decodeItem(_asObject(item, 'items')),
      ]),
      page: _readCount(json, 'page', minimum: 1),
      pageSize: _readCount(json, 'page_size', minimum: 1),
      total: _readCount(json, 'total', minimum: 0),
    );
  }
}

/// 取出一个必填的整数字段，并校验下界。
int _readCount(
  Map<String, Object?> json,
  String key, {
  required int minimum,
}) {
  final value = json[key];
  if (value is! int || value < minimum) {
    throw FormatException('Field "$key" must be an integer >= $minimum');
  }
  return value;
}

/// 把任意值收窄成一个 JSON 对象，失败时抛出带字段名的 [FormatException]。
Map<String, Object?> _asObject(Object? value, String key) {
  if (value is! Map) {
    throw FormatException('Every "$key" item must be an object');
  }
  return Map<String, Object?>.from(value);
}
