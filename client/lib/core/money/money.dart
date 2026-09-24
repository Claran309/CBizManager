/// 定点十进制数值，用于在客户端全程避免二进制浮点误差。
///
/// 数量级约定（对齐后端 `pkg/money`）：
///
/// - [Amount]   金额，内部单位「分」（1 元 = 100 分），数据库 DECIMAL(18,2)。
/// - [UnitPrice] 单价，内部单位「万分之一元」，数据库 DECIMAL(18,4)。
/// - [Quantity] 数量，内部单位「千分之一」，数据库 DECIMAL(18,3)。
///
/// 三者的线上表示统一为十进制字符串（如 `"146982.33"`），因为 Dart 的 `double`
/// 是 IEEE-754 双精度，直接用数字传输/运算会产生精度截断。**这里只用 [BigInt]
/// 表示定点整数，任何运算都不经过 `double`/`num`。**
///
/// 三个类型彼此不可互换：虽然实现共享同一套解析/格式化核心，但它们是三个
/// 不同的类，编译器能拦住「把数量当金额」「把单价当数量」这类错位——
/// 与后端三个独立的 int64 类型保持一致。
library;

/// 以「分」为单位的金额（scale = 2）。
final class Amount {
  const Amount._(this._value);

  /// 定点整数值（分）。
  final BigInt _value;

  /// 金额的小数位数。
  static const int scale = 2;

  /// 从十进制字符串解析。拒绝科学计数法、超精度非零尾数、非法字符。
  factory Amount.parse(String raw) => Amount._(_parseFixed(raw, scale));

  /// 从「分」的整数值直接构造（仅代码内常量与测试）。
  factory Amount.fromMinorUnits(BigInt minorUnits) => Amount._(minorUnits);

  /// 定点整数值（分），供测试与少数需要精确比较的场景使用。
  BigInt get inMinorUnits => _value;

  /// 十进制字符串，补零到 scale 位，如 `"146982.33"`。
  String format() => _formatFixed(_value, scale);

  /// 去掉尾零的金额文本（用于展示），如 `100.00` → `100`。
  String yuan() => _trimTrailingZeros(_formatFixed(_value, scale));

  Amount add(Amount other) => Amount._(_value + other._value);

  Amount sub(Amount other) => Amount._(_value - other._value);

  bool get isZero => _value == BigInt.zero;

  bool get isNegative => _value.isNegative;

  /// 累加一组金额（禁止用浮点累加）。
  static Amount sum(Iterable<Amount> values) {
    var total = BigInt.zero;
    for (final value in values) {
      total += value._value;
    }
    return Amount._(total);
  }

  /// 单价 × 数量 → 金额（四舍五入到分）。
  ///
  /// 单价单位是 10^-4 元、数量单位是 10^-3，乘积单位是 10^-7 元；
  /// 换算成「分」（10^-2 元）需除以 10^5。用 [BigInt] 完成，不会因大数溢出。
  /// 四舍五入规则对齐后端 `money.Mul`：余数绝对值 × 2 >= 除数时进位，
  /// 负数向负方向（远离零）进位。
  static Amount mul(UnitPrice price, Quantity quantity) {
    final product = price._value * quantity._value;
    final divisor = BigInt.from(100000);
    var quotient = product ~/ divisor;
    final remainder = product.remainder(divisor);
    if (remainder.abs() * BigInt.two >= divisor) {
      quotient += product.isNegative ? -BigInt.one : BigInt.one;
    }
    return Amount._(quotient);
  }

  @override
  bool operator ==(Object other) => other is Amount && other._value == _value;

  @override
  int get hashCode => _value.hashCode;

  @override
  String toString() => 'Amount(${format()})';
}

/// 以「万分之一元」为单位的单价（scale = 4）。
final class UnitPrice {
  const UnitPrice._(this._value);

  final BigInt _value;

  static const int scale = 4;

  factory UnitPrice.parse(String raw) => UnitPrice._(_parseFixed(raw, scale));

  BigInt get inMinorUnits => _value;

  String format() => _formatFixed(_value, scale);

  @override
  bool operator ==(Object other) =>
      other is UnitPrice && other._value == _value;

  @override
  int get hashCode => _value.hashCode;

  @override
  String toString() => 'UnitPrice(${format()})';
}

/// 以「千分之一」为单位的数量/重量（scale = 3）。
final class Quantity {
  const Quantity._(this._value);

  final BigInt _value;

  static const int scale = 3;

  factory Quantity.parse(String raw) => Quantity._(_parseFixed(raw, scale));

  BigInt get inMinorUnits => _value;

  String format() => _formatFixed(_value, scale);

  @override
  bool operator ==(Object other) => other is Quantity && other._value == _value;

  @override
  int get hashCode => _value.hashCode;

  @override
  String toString() => 'Quantity(${format()})';
}

/* ---------------------------------------------------------------- 内部实现 */

/// 10 的 n 次方（BigInt）。
BigInt _pow10(int n) => BigInt.from(10).pow(n);

/// 把十进制字符串解析成定点整数（单位 = 10^-scale）。
///
/// 规则逐条对齐后端 `parseFixed`：去千分位逗号与首尾空白、拒绝科学计数法、
/// 拒绝多小数点、小数位超过 scale 时多余位必须全 0 否则拒绝。
BigInt _parseFixed(String raw, int scale) {
  var text = raw.replaceAll(',', '').trim();
  if (text.isEmpty) {
    throw FormatException('定点数值不能为空');
  }
  if (text.contains('e') || text.contains('E')) {
    throw FormatException('不接受科学计数法：$raw');
  }
  text = text.startsWith('+') ? text.substring(1) : text;
  final negative = text.startsWith('-');
  if (negative) {
    text = text.substring(1);
  }

  final parts = text.split('.');
  if (parts.length > 2) {
    throw FormatException('小数点数量不合法：$raw');
  }
  var intPart = parts[0];
  var fracPart = parts.length == 2 ? parts[1] : '';
  if (intPart.isEmpty && fracPart.isEmpty) {
    throw FormatException('没有数字位：$raw');
  }
  if (!_isDigits(intPart) || !_isDigits(fracPart)) {
    throw FormatException('含非数字字符：$raw');
  }
  // 小数位超过精度时，多余位必须全 0，否则拒绝（防止静默截断金额）。
  if (fracPart.length > scale) {
    for (var i = scale; i < fracPart.length; i++) {
      if (fracPart[i] != '0') {
        throw FormatException('超过 $scale 位小数：$raw');
      }
    }
    fracPart = fracPart.substring(0, scale);
  }
  fracPart = fracPart.padRight(scale, '0');

  final intValue = intPart.isEmpty ? BigInt.zero : BigInt.parse(intPart);
  final fracValue = fracPart.isEmpty ? BigInt.zero : BigInt.parse(fracPart);
  var total = intValue * _pow10(scale) + fracValue;
  if (negative) {
    total = -total;
  }
  return total;
}

/// 把定点整数格式化成十进制字符串，补零到 scale 位。
String _formatFixed(BigInt value, int scale) {
  final negative = value.isNegative;
  final abs = value.abs();
  final unit = _pow10(scale);
  final intPart = abs ~/ unit;
  final fracPart = abs.remainder(unit);
  var text = intPart.toString();
  if (scale > 0) {
    final frac = fracPart.toString().padLeft(scale, '0');
    text = '$text.$frac';
  }
  if (negative) {
    text = '-$text';
  }
  return text;
}

/// 去掉小数部分末尾的 0，并在小数部分为空时去掉小数点。
String _trimTrailingZeros(String text) {
  if (!text.contains('.')) {
    return text;
  }
  return text.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
}

bool _isDigits(String text) {
  for (final char in text.codeUnits) {
    if (char < 0x30 || char > 0x39) {
      return false;
    }
  }
  return true;
}
