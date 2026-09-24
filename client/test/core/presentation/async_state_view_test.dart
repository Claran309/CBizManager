import 'package:c_biz_docs_manager/core/error/app_failure.dart';
import 'package:c_biz_docs_manager/core/presentation/async_state_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _host({
  required bool isLoading,
  required AppFailure? failure,
  required bool isEmpty,
  VoidCallback? onRetry,
  String? loadingMessage,
  String? emptyMessage,
}) => MaterialApp(
  home: Scaffold(
    body: AsyncStateView(
      isLoading: isLoading,
      failure: failure,
      isEmpty: isEmpty,
      onRetry: onRetry ?? () {},
      loadingMessage: loadingMessage ?? '正在加载…',
      emptyMessage: emptyMessage ?? '暂无数据',
      child: const Text('真实内容'),
    ),
  ),
);

void main() {
  testWidgets('加载中显示进度条与加载文案，不显示内容', (WidgetTester tester) async {
    // 有 CircularProgressIndicator 时不能 pumpAndSettle：它是无限动画，会超时。
    await tester.pumpWidget(
      _host(isLoading: true, failure: null, isEmpty: false),
    );
    await tester.pump();

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('正在加载…'), findsOneWidget);
    expect(find.text('真实内容'), findsNothing);
  });

  testWidgets('加载文案可以被页面覆盖', (WidgetTester tester) async {
    await tester.pumpWidget(
      _host(
        isLoading: true,
        failure: null,
        isEmpty: false,
        loadingMessage: '正在读取成员',
      ),
    );
    await tester.pump();

    expect(find.text('正在读取成员'), findsOneWidget);
  });

  testWidgets('空态显示页面自己的空文案，且没有进度条', (WidgetTester tester) async {
    await tester.pumpWidget(
      _host(
        isLoading: false,
        failure: null,
        isEmpty: true,
        emptyMessage: '暂无成员',
      ),
    );

    expect(find.text('暂无成员'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('真实内容'), findsNothing);
  });

  testWidgets('有数据时原样渲染内容', (WidgetTester tester) async {
    await tester.pumpWidget(
      _host(isLoading: false, failure: null, isEmpty: false),
    );

    expect(find.text('真实内容'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('失败态优先于加载中：有原因可看，就不要藏在转圈后面', (WidgetTester tester) async {
    await tester.pumpWidget(
      _host(
        isLoading: true,
        failure: const ServerFailure('服务器响应异常', requestId: 'req-9'),
        isEmpty: false,
      ),
    );
    await tester.pump();

    expect(find.text('服务器响应异常'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('真实内容'), findsNothing);
  });

  testWidgets('加载态优先于空态，避免首次加载先闪一下"暂无数据"', (WidgetTester tester) async {
    await tester.pumpWidget(
      _host(isLoading: true, failure: null, isEmpty: true),
    );
    await tester.pump();

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('暂无数据'), findsNothing);
  });

  testWidgets('重试按钮回调到 onRetry', (WidgetTester tester) async {
    var retried = 0;
    await tester.pumpWidget(
      _host(
        isLoading: false,
        failure: const NetworkFailure('网络不可用'),
        isEmpty: false,
        onRetry: () => retried++,
      ),
    );

    expect(find.text('重试'), findsOneWidget);
    await tester.tap(find.text('重试'));
    await tester.pump();

    expect(retried, 1);
  });

  testWidgets('冲突失败把按钮文案换成"重新加载"，并且仍然回调 onRetry', (WidgetTester tester) async {
    var retried = 0;
    await tester.pumpWidget(
      _host(
        isLoading: false,
        failure: const ConflictFailure('版本冲突'),
        isEmpty: false,
        onRetry: () => retried++,
      ),
    );

    expect(find.text('重新加载'), findsOneWidget);
    expect(find.text('重试'), findsNothing);

    await tester.tap(find.text('重新加载'));
    await tester.pump();
    expect(retried, 1);
  });

  testWidgets('服务端失败把 Request ID 渲染成可复制的文本', (WidgetTester tester) async {
    await tester.pumpWidget(
      _host(
        isLoading: false,
        failure: const ServerFailure('服务器响应异常', requestId: 'req-abc'),
        isEmpty: false,
      ),
    );

    // 必须是 SelectableText 才谈得上"可复制"。
    expect(find.byType(SelectableText), findsOneWidget);
    expect(find.text('请求 ID：req-abc'), findsOneWidget);
  });

  testWidgets('没有 requestId 时不渲染空壳复制区', (WidgetTester tester) async {
    await tester.pumpWidget(
      _host(
        isLoading: false,
        failure: const NetworkFailure('网络不可用'),
        isEmpty: false,
      ),
    );

    expect(find.byType(SelectableText), findsNothing);
  });

  testWidgets('校验失败的字段错误由页面负责挂到输入框，本组件只显示摘要', (WidgetTester tester) async {
    await tester.pumpWidget(
      _host(
        isLoading: false,
        failure: const ValidationFailure('提交内容有问题', <String, String>{
          'name': '名称不能为空',
        }),
        isEmpty: false,
      ),
    );

    expect(find.text('提交内容有问题'), findsOneWidget);
  });
}
