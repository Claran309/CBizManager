import 'package:flutter/material.dart';

/// 报表页默认的统计周期：当前月，形如 `2026-09`。
String currentPeriod() {
  final now = DateTime.now();
  return '${now.year}-${now.month.toString().padLeft(2, '0')}';
}

/// 看板与统计页共用的指标卡片。
///
/// 金额与大写都来自服务端，这里只负责排版；比率同时展示 `*_percent` 文本与 ppm 原值。
class ReportMetricCard extends StatelessWidget {
  const ReportMetricCard({
    required this.title,
    required this.primary,
    required this.secondary,
    this.extra,
    super.key,
  });

  final String title;
  final String primary;
  final String secondary;
  final String? extra;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(title, style: theme.textTheme.labelLarge),
            const SizedBox(height: 4),
            Text(primary, style: theme.textTheme.titleMedium),
            Text(secondary, style: theme.textTheme.bodySmall),
            if (extra != null) Text(extra!, style: theme.textTheme.bodySmall),
          ],
        ),
      ),
    );
  }
}
