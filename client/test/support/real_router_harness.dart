import 'package:c_biz_docs_manager/app/router.dart';
import 'package:c_biz_docs_manager/core/auth/auth_controller.dart';
import 'package:c_biz_docs_manager/core/auth/auth_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
// `Override` 在 Riverpod 3 里由 misc.dart 导出，主入口只给常用的那一组。
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

/// 搭起**真实路由** + 假认证仓储的租户侧应用，并推进到守卫决定的落点。
///
/// 这里刻意用真实的 `routerProvider` 而不是几条手搭的 GoRoute：认证与角色首页
/// 这一块的核心要求就是「落点由守卫算出来」（登录 → 角色首页、待改密 → 改密页、
/// 普通成员 → 进不了成员页），手搭路由会把这段逻辑整个测没，
/// 剩下的只是一个自己导航给自己看的假流程。
///
/// 落点由 `repository.restore()` 的结果决定，所以调用方**不需要自己 go**：
/// - `restoreFailure` 非空 ⇒ 未登录 ⇒ 停在 `/login`；
/// - 会话是待改密的 ⇒ 停在 `/change-password`；
/// - 其余 ⇒ 停在 `/home`。
///
/// 返回的 container 供断言「状态层面发生了什么」（例如某个 Controller 的入参），
/// 页面层面的断言一律走 `find`。
Future<ProviderContainer> pumpRealApp(
  WidgetTester tester, {
  required AuthRepository repository,
}) async {
  final container = ProviderContainer(
    overrides: <Override>[authRepositoryProvider.overrideWithValue(repository)],
  );
  addTearDown(container.dispose);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(routerConfig: container.read(routerProvider)),
    ),
  );
  // 真实应用外壳在启动时也是在这一步恢复会话，守卫随即决定地址。
  await container.read(authControllerProvider.notifier).restore();
  await tester.pumpAndSettle();
  return container;
}

/// 断言当前停在租户首页。
///
/// 不能直接 `find.text('首页')`：租户功能壳的侧边导航项也叫「首页」，
/// 全树搜索会同时命中导航标签，`findsOneWidget` 会因为「找到两个」而红 ——
/// 而用例真正想表达的只是「页面落在首页」。限定在 AppBar 标题里找。
void expectTenantHome() =>
    expect(find.widgetWithText(AppBar, '首页'), findsOneWidget);

/// 断言某个导航项在壳里（宽屏走 `NavigationRail`，窄屏走 `NavigationBar`）。
///
/// 两处都查，是为了让断言不依赖测试窗口的宽度：真正的规则是「身份决定看到几项」，
/// 而不是「宽屏才看得到」。
void expectDestination(String label, {required bool visible}) {
  final matches =
      find
          .descendant(
            of: find.byType(NavigationRail),
            matching: find.text(label),
          )
          .evaluate()
          .length +
      find
          .descendant(
            of: find.byType(NavigationBar),
            matching: find.text(label),
          )
          .evaluate()
          .length;
  expect(matches, visible ? 1 : 0, reason: '导航项「$label」的可见性不符合预期');
}
