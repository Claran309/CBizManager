/// 业务日期与月份的解析口径。
///
/// 单据、结算、财务、报表四个模块都要处理用户手写的日期，如果各写一套解析，
/// 很容易出现「入库单接受 2026年9月22日、结算列表却不接受」这类口径漂移。
/// 因此把解析规则集中在这里（对齐后端 `pkg/bizdate`），各模块只调用不复制。
library;

/// 日期分隔符折叠表：把用户可能输入的分隔符统一折叠成 `-`。
///
/// 覆盖 FR-ASSIST-05「用户可输入由空格分隔的日期」；`年`/`月` 折叠成 `-`、
/// `日` 折叠成空，`.` / `/` / 空格 / `\t` / `\` 也都折叠成 `-`。
const List<String> _dateSeparators = <String>[
  '年',
  '月',
  '日',
  '/',
  '.',
  ' ',
  '\t',
  r'\',
];

/// 把日期字符串折叠分隔符后按 `-` 切分、过滤空段。
List<String> _foldDate(String raw) {
  var text = raw.trim();
  for (final separator in _dateSeparators) {
    text = text.replaceAll(separator, '-');
  }
  // 连续 `-` 折叠后会产生空段，过滤掉。
  return <String>[
    for (final part in text.split('-'))
      if (part.trim().isNotEmpty) part.trim(),
  ];
}

/// 解析业务日期并统一成 UTC 零点。
///
/// 兼容「2026-09-22」「2026/9/22」「2026 9 22」「2026年9月22日」「20260922」
/// 五种写法，并回读校验 [DateTime.utc] 的规范化结果，避免 2026-02-31 被悄悄
/// 变成 2026-03-03 后提交。
///
/// 年份范围 `[2000, 2100]`。非法输入抛 [FormatException]。
DateTime parseDate(String raw) {
  final parts = _foldDate(raw);
  if (parts.isEmpty) {
    throw const FormatException('业务日期格式无效');
  }

  late final int year;
  late final int month;
  late final int day;
  if (parts.length == 1) {
    // 紧凑写法 20260922。
    final compact = parts[0];
    if (compact.length != 8) {
      throw const FormatException('业务日期格式无效');
    }
    year = int.tryParse(compact.substring(0, 4)) ?? 0;
    month = int.tryParse(compact.substring(4, 6)) ?? 0;
    day = int.tryParse(compact.substring(6, 8)) ?? 0;
  } else if (parts.length == 3) {
    year = int.tryParse(parts[0]) ?? 0;
    month = int.tryParse(parts[1]) ?? 0;
    day = int.tryParse(parts[2]) ?? 0;
  } else {
    throw const FormatException('业务日期格式无效');
  }

  if (year < 2000 ||
      year > 2100 ||
      month < 1 ||
      month > 12 ||
      day < 1 ||
      day > 31) {
    throw const FormatException('业务日期格式无效');
  }

  final date = DateTime.utc(year, month, day);
  // 回读校验：拦截 2026-02-31 被 DateTime 悄悄进位成 2026-03-03。
  if (date.year != year || date.month != month || date.day != day) {
    throw const FormatException('业务日期格式无效');
  }
  return date;
}

/// 解析「YYYY-MM」，返回 `(当月起点, 次月起点)`（左闭右开）。
///
/// 只接受「YYYY-MM」这种粒度（带横线）；年份范围 `[2000, 2100]`。
(DateTime, DateTime) parseMonth(String raw) {
  var text = raw.trim();
  // 月份折叠表：只把 `/`、`年`、`.`、空格折叠成 `-`，`月` 折叠成空。
  for (final separator in <String>['/', '年', '.', ' ', '\t']) {
    text = text.replaceAll(separator, '-');
  }
  text = text.replaceAll('月', '');

  final parts = text.split('-');
  if (parts.length != 2) {
    throw const FormatException('业务月份格式无效');
  }
  final year = int.tryParse(parts[0].trim()) ?? 0;
  final month = int.tryParse(parts[1].trim()) ?? 0;
  if (year < 2000 || year > 2100 || month < 1 || month > 12) {
    throw const FormatException('业务月份格式无效');
  }
  final start = DateTime.utc(year, month, 1);
  return (start, DateTime.utc(year, month + 1, 1));
}

/// 把时刻格式化成「YYYY-MM」（带横线）。
String formatMonth(DateTime at) {
  final year = at.year.toString().padLeft(4, '0');
  final month = at.month.toString().padLeft(2, '0');
  return '$year-$month';
}

/// 把时刻格式化成紧凑的「YYYYMM」（无横线，用于拼单号）。
///
/// 结算单号是「JS202609-0003」这种不带分隔符的形式，用它拼接月份才不会在
/// 单号里混进 `-`。
String formatMonthCompact(DateTime at) {
  final year = at.year.toString().padLeft(4, '0');
  final month = at.month.toString().padLeft(2, '0');
  return '$year$month';
}
