import 'package:c_biz_docs_manager/core/error/app_failure.dart';
import 'package:c_biz_docs_manager/core/presentation/failure_presenter.dart';
import 'package:flutter/material.dart';

/// 「加载中 / 失败 / 空 / 有数据」四态的统一视图。
///
/// 每个列表页都要处理这四种状态，各写一遍的结果必然是四种样子、四种文案、
/// 有的能重试有的不能。这里把它收敛成一处：页面只负责把状态翻译成四个入参，
/// 剩下的呈现由本组件决定。
///
/// 说明：计划里写作 `AsyncStateView<T>`，但 `T` 在这套 API 里不出现于任何位置
/// （入参全是布尔、回调与 `Widget`），保留它只会逼每个调用点写一个不携带信息的
/// 类型实参，所以这里不带类型参数。
final class AsyncStateView extends StatelessWidget {
  const AsyncStateView({
    required this.isLoading,
    required this.failure,
    required this.isEmpty,
    required this.onRetry,
    required this.child,
    this.loadingMessage = '正在加载…',
    this.emptyMessage = '暂无数据',
    super.key,
  });

  final bool isLoading;

  /// 最近一次失败。为 null 表示当前没有失败。
  final AppFailure? failure;

  /// 成功拿到数据、但数据是空集合。
  final bool isEmpty;

  /// 重试入口。通常直接指向 Controller 的 `load` / `refresh`。
  final VoidCallback onRetry;

  /// 四态都正常时的真正内容。
  final Widget child;

  final String loadingMessage;

  /// 空态文案。不同页面语义差别很大（「暂无成员」/「本月没有单据」），
  /// 所以必须能覆盖，不能写死。
  final String emptyMessage;

  /// 判定顺序：**失败 > 加载中 > 空 > 内容**。
  ///
  /// 失败优先是刻意的：有失败就一定有原因可看，把原因藏在一个转圈后面
  /// 会让用户以为「它还在努力」。加载优先于空态，是为了避免首次加载时
  /// 先闪一下「暂无数据」再跳成列表。
  ///
  /// 如果页面希望「刷新时保留旧列表」（不要一刷新就白屏），
  /// 调用方传 `isLoading: state.isLoading && state.items.isEmpty` 即可：
  /// 那时已有数据，[child] 会继续显示，转圈交给页面自己在别处表达。
  @override
  Widget build(BuildContext context) {
    final currentFailure = failure;
    if (currentFailure != null) {
      return _FailureView(failure: currentFailure, onRetry: onRetry);
    }
    if (isLoading) {
      return _CenteredMessage(message: loadingMessage, showSpinner: true);
    }
    if (isEmpty) {
      return _CenteredMessage(message: emptyMessage);
    }
    return child;
  }
}

/// 失败态：文案 + 可选 Request ID + 重试/刷新按钮。
final class _FailureView extends StatelessWidget {
  const _FailureView({required this.failure, required this.onRetry});

  final AppFailure failure;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final presentation = FailurePresenter.present(failure);
    final theme = Theme.of(context);
    final requestId = presentation.requestId;

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.error_outline, size: 40, color: theme.colorScheme.error),
            const SizedBox(height: 12),
            Text(
              presentation.message,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium,
            ),
            if (requestId != null) ...<Widget>[
              const SizedBox(height: 8),
              // 用 SelectableText 而不是 Text：Request ID 的唯一用途就是被复制走，
              // 普通 Text 在移动端连选中都做不到。
              SelectableText(
                '请求 ID：$requestId',
                style: theme.textTheme.bodySmall,
              ),
            ],
            const SizedBox(height: 16),
            TextButton(
              // 冲突类失败按设计要「刷新后让用户重新决定」，
              // 所以按钮文案也从「重试」换成「重新加载」——
              // 两者调的是同一个回调，但告诉用户的是不同的心智模型。
              onPressed: onRetry,
              child: Text(presentation.shouldRefresh ? '重新加载' : '重试'),
            ),
          ],
        ),
      ),
    );
  }
}

/// 加载态与空态共用的居中提示。
final class _CenteredMessage extends StatelessWidget {
  const _CenteredMessage({required this.message, this.showSpinner = false});

  final String message;
  final bool showSpinner;

  @override
  Widget build(BuildContext context) {
    // liveRegion 让读屏软件在状态切换时主动播报（而不是等用户去摸屏幕），
    // 这是「加载中 / 空 / 失败都有独立反馈」在无障碍层面的落地。
    return Semantics(
      liveRegion: true,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            if (showSpinner) ...<Widget>[
              const CircularProgressIndicator(),
              const SizedBox(height: 16),
            ],
            Text(message, textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }
}
