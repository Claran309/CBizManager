import 'package:c_biz_docs_manager/core/network/page_result.dart';
import 'package:flutter_test/flutter_test.dart';

/// 一个最小的分页响应，字段名与 OpenAPI 的 `GroupPageData` 一致。
Map<String, Object?> _page({
  Object? items = const <Object?>[],
  Object? page = 1,
  Object? pageSize = 20,
  Object? total = 0,
}) => <String, Object?>{
  'items': items,
  'page': page,
  'page_size': pageSize,
  'total': total,
};

int _readId(Map<String, Object?> item) => item['id']! as int;

void main() {
  test('解析条目、页码、每页条数与总数', () {
    final result = PageResult<int>.fromJson(
      _page(
        items: <Object?>[
          <String, Object?>{'id': 11},
          <String, Object?>{'id': 12},
        ],
        page: 2,
        pageSize: 2,
        total: 5,
      ),
      _readId,
    );

    expect(result.items, <int>[11, 12]);
    expect(result.page, 2);
    expect(result.pageSize, 2);
    expect(result.total, 5);
    // 2 * 2 = 4 < 5，后面还有一页。
    expect(result.hasMore, isTrue);
  });

  test('最后一页的 hasMore 为 false', () {
    final result = PageResult<int>.fromJson(
      _page(
        items: <Object?>[
          <String, Object?>{'id': 5},
        ],
        page: 3,
        pageSize: 2,
        total: 5,
      ),
      _readId,
    );

    // 3 * 2 = 6 已越过总数 5：即使这一页只回 1 条，也不该再翻。
    expect(result.hasMore, isFalse);
  });

  test('items 会被包成不可修改列表', () {
    final result = PageResult<int>.fromJson(
      _page(
        items: <Object?>[
          <String, Object?>{'id': 1},
        ],
      ),
      _readId,
    );

    // 控制器把结果直接交给界面渲染；若这里是可变列表，任何一处就地排序或删除
    // 都会悄悄篡改「上一次请求的结果」，让刷新逻辑变得不可推理。
    expect(() => result.items.add(2), throwsUnsupportedError);
  });

  group('结构非法时抛 FormatException', () {
    test('items 缺失', () {
      expect(
        () => PageResult<int>.fromJson(_page()..remove('items'), _readId),
        throwsFormatException,
      );
    });

    test('items 不是数组', () {
      expect(
        () => PageResult<int>.fromJson(
          _page(items: <String, Object?>{'id': 1}),
          _readId,
        ),
        throwsFormatException,
      );
    });

    test('items 中的元素不是对象', () {
      expect(
        () => PageResult<int>.fromJson(_page(items: <Object?>[1]), _readId),
        throwsFormatException,
      );
    });

    test('页码小于 1', () {
      expect(
        () => PageResult<int>.fromJson(_page(page: 0), _readId),
        throwsFormatException,
      );
    });

    test('每页条数小于 1', () {
      expect(
        () => PageResult<int>.fromJson(_page(pageSize: 0), _readId),
        throwsFormatException,
      );
    });

    test('总数为负数', () {
      expect(
        () => PageResult<int>.fromJson(_page(total: -1), _readId),
        throwsFormatException,
      );
    });

    test('总数字段缺失', () {
      final json = _page()..remove('total');
      expect(
        () => PageResult<int>.fromJson(json, _readId),
        throwsFormatException,
      );
    });

    test('整数字段收到了字符串', () {
      // 服务端若把大整数序列化成字符串（int64 在部分 JSON 库里的常见行为），
      // 这里必须立刻失败，而不是被 `as int` 静默放过或退化成 0。
      expect(
        () => PageResult<int>.fromJson(_page(total: '5'), _readId),
        throwsFormatException,
      );
    });
  });
}
