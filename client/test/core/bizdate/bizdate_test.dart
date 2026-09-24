import 'package:c_biz_docs_manager/core/bizdate/bizdate.dart';
import 'package:flutter_test/flutter_test.dart';

/// 业务日期工具的契约测试。
///
/// 语义逐条对齐后端 `pkg/bizdate`：`parseDate` 兼容 5 种写法并回读校验、
/// `parseMonth` 只收 YYYY-MM、`formatMonth` 带横线、`formatMonthCompact` 紧凑。
void main() {
  group('parseDate', () {
    test('五种写法都解析成同一天', () {
      final expected = DateTime.utc(2026, 9, 22);
      for (final raw in <String>[
        '2026-09-22',
        '2026/9/22',
        '2026 9 22',
        '2026年9月22日',
        '20260922',
      ]) {
        expect(parseDate(raw), expected, reason: '「$raw」应解析成 2026-09-22');
      }
    });

    test('回读校验拒绝 2026-02-31', () {
      expect(() => parseDate('2026-02-31'), throwsFormatException);
      expect(() => parseDate('20260231'), throwsFormatException);
    });

    test('拒绝空串、非法格式、越界', () {
      expect(() => parseDate(''), throwsFormatException);
      expect(() => parseDate('   '), throwsFormatException);
      expect(() => parseDate('2026-9'), throwsFormatException); // 只有两段
      expect(() => parseDate('1999-01-01'), throwsFormatException); // 年 < 2000
      expect(() => parseDate('2101-01-01'), throwsFormatException); // 年 > 2100
      expect(() => parseDate('2026-13-01'), throwsFormatException); // 月越界
      expect(() => parseDate('2026-00-10'), throwsFormatException);
      expect(() => parseDate('2026-01-00'), throwsFormatException);
      expect(() => parseDate('2026-01-32'), throwsFormatException);
      expect(() => parseDate('abcdefgh'), throwsFormatException);
    });

    test('紧凑写法必须正好 8 位', () {
      expect(() => parseDate('2026092'), throwsFormatException);
      expect(() => parseDate('202609222'), throwsFormatException);
    });

    test('首尾空白容忍', () {
      expect(parseDate('  2026-09-22  '), DateTime.utc(2026, 9, 22));
    });
  });

  group('parseMonth', () {
    test('只收 YYYY-MM', () {
      final (start, end) = parseMonth('2026-09');
      expect(start, DateTime.utc(2026, 9, 1));
      expect(end, DateTime.utc(2026, 10, 1)); // 左闭右开
    });

    test('拒绝无横线、多余字段、越界', () {
      expect(() => parseMonth('202609'), throwsFormatException); // 紧凑无分隔
      expect(() => parseMonth('2026'), throwsFormatException); // 只有年
      expect(() => parseMonth('2026-09-01'), throwsFormatException); // 多一段
      expect(() => parseMonth('1999-12'), throwsFormatException);
      expect(() => parseMonth('2026-13'), throwsFormatException);
    });

    test('月份不强制补零（对齐后端）', () {
      final (start, end) = parseMonth('2026-9');
      expect(start, DateTime.utc(2026, 9, 1));
      expect(end, DateTime.utc(2026, 10, 1));
    });
  });

  group('formatMonth / formatMonthCompact', () {
    test('带横线 vs 紧凑', () {
      final month = DateTime.utc(2026, 9, 15);
      expect(formatMonth(month), '2026-09');
      expect(formatMonthCompact(month), '202609');
    });
  });
}
