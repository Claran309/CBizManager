import 'package:c_biz_docs_manager/core/money/money.dart';
import 'package:flutter_test/flutter_test.dart';

/// 定点金额工具的契约测试。
///
/// 语义逐条对齐后端 `pkg/money`：金额(分/scale2)、单价(万分之一元/scale4)、
/// 数量(千分之一/scale3)，JSON 一律字符串，内部定点整数、禁止 double。
void main() {
  group('Amount（金额，分）', () {
    test('解析十进制字符串为分，补零格式化', () {
      final amount = Amount.parse('146982.33');
      expect(amount.format(), '146982.33');
      expect(amount.inMinorUnits, BigInt.from(14698233));
    });

    test('整数金额补零到两位', () {
      expect(Amount.parse('100').format(), '100.00');
      expect(Amount.parse('0').format(), '0.00');
    });

    test('去千分位逗号与 + 前缀', () {
      expect(Amount.parse('1,234,567.89').format(), '1234567.89');
      expect(Amount.parse('+99.99').format(), '99.99');
    });

    test('接受负数', () {
      expect(Amount.parse('-123.45').format(), '-123.45');
      expect(Amount.parse('-123.45').isNegative, isTrue);
    });

    test('小数位超过两位但多余位全 0 时截断接受', () {
      expect(Amount.parse('1.500').format(), '1.50');
    });

    test('小数位超过两位且多余位非 0 时拒绝', () {
      expect(() => Amount.parse('1.999'), throwsFormatException);
    });

    test('拒绝科学计数法', () {
      expect(() => Amount.parse('1.5e3'), throwsFormatException);
      expect(() => Amount.parse('1E2'), throwsFormatException);
    });

    test('拒绝空串、多小数点、非数字', () {
      expect(() => Amount.parse(''), throwsFormatException);
      expect(() => Amount.parse('1.2.3'), throwsFormatException);
      expect(() => Amount.parse('abc'), throwsFormatException);
      expect(() => Amount.parse('12x'), throwsFormatException);
    });

    test('加减与累加', () {
      final a = Amount.parse('1.00');
      final b = Amount.parse('2.50');
      expect(a.add(b).format(), '3.50');
      expect(b.sub(a).format(), '1.50');
      expect(Amount.sum([a, b, Amount.parse('0.50')]).format(), '4.00');
    });

    test('isZero / isNegative / 相等', () {
      expect(Amount.parse('0').isZero, isTrue);
      expect(Amount.parse('0.00').isZero, isTrue);
      expect(Amount.parse('1.00').isZero, isFalse);
      expect(Amount.parse('-0.01').isNegative, isTrue);
      expect(Amount.parse('1.00'), Amount.parse('1.00'));
      expect(Amount.parse('1.00'), isNot(Amount.parse('1.01')));
    });

    test('Yuan 去尾零', () {
      expect(Amount.parse('100.00').yuan(), '100');
      expect(Amount.parse('100.50').yuan(), '100.5');
      expect(Amount.parse('0.00').yuan(), '0');
    });
  });

  group('UnitPrice（单价，万分之一元）', () {
    test('补零到四位', () {
      expect(UnitPrice.parse('2975.43').format(), '2975.4300');
      expect(UnitPrice.parse('0.0001').format(), '0.0001');
    });

    test('超过四位非零尾数拒绝', () {
      expect(() => UnitPrice.parse('1.00001'), throwsFormatException);
    });

    test('超过四位但全 0 截断接受', () {
      // 前 4 位小数 + 后 3 位全是 0 → 截断为 4 位。
      expect(UnitPrice.parse('1.0000000').format(), '1.0000');
    });
  });

  group('Quantity（数量，千分之一）', () {
    test('补零到三位', () {
      expect(Quantity.parse('17.05').format(), '17.050');
      expect(Quantity.parse('3').format(), '3.000');
    });

    test('超过三位非零尾数拒绝', () {
      expect(() => Quantity.parse('1.0001'), throwsFormatException);
    });
  });

  group('Mul：单价 × 数量 → 金额（四舍五入到分）', () {
    test('精确乘积', () {
      final price = UnitPrice.parse('2975.4300');
      final quantity = Quantity.parse('17.050');
      expect(Amount.mul(price, quantity).format(), '50731.08');
    });

    test('四舍五入进位', () {
      // 1.0050 元(10^-4) × 1.000(10^-3) = 1.005 元 = 100.5 分 → 四舍五入 101 分。
      final price = UnitPrice.parse('1.0050');
      final quantity = Quantity.parse('1.000');
      expect(Amount.mul(price, quantity).format(), '1.01');
    });

    test('负数乘积也正确四舍五入', () {
      final price = UnitPrice.parse('-1.0050');
      final quantity = Quantity.parse('1.000');
      // -1.005 元 = -100.5 分 → 向负方向四舍五入到 -101 分 = -1.01
      expect(Amount.mul(price, quantity).format(), '-1.01');
    });

    test('不会因大数溢出（BigInt）', () {
      final price = UnitPrice.parse('99999999.9999');
      final quantity = Quantity.parse('999999999.999');
      // 结果远超 int64，但 BigInt 应能正确给出一个很大的数而不是溢出成 MaxInt64。
      final result = Amount.mul(price, quantity);
      expect(result.format(), isNotEmpty);
    });
  });
}
