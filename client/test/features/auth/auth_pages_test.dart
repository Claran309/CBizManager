import 'dart:async';

import 'package:c_biz_docs_manager/core/auth/auth_models.dart';
import 'package:c_biz_docs_manager/core/error/app_failure.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/auth_fixtures.dart';
import '../../support/fake_auth_repository.dart';
import '../../support/real_router_harness.dart';

/// 未登录态的仓储：`restore` 必然失败，用户停在登录页。
FakeAuthRepository _signedOut() =>
    FakeAuthRepository()..restoreFailure = const UnauthenticatedFailure('未登录');

void main() {
  /* ------------------------------------------------------------ 登录 */

  group('登录页', () {
    testWidgets('登录成功后由守卫送到租户首页', (WidgetTester tester) async {
      final repository = _signedOut();
      await pumpRealApp(tester, repository: repository);

      await tester.enterText(
        find.widgetWithText(TextFormField, '登录账号'),
        'owner',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, '密码'),
        'password123',
      );
      await tester.tap(find.widgetWithText(FilledButton, '登录'));
      await tester.pumpAndSettle();

      // 只提交 username/password，一个多余字段都不带。
      expect(repository.loginCalls.single, (
        username: 'owner',
        password: 'password123',
      ));
      // 页面自己**不导航**：去向由守卫算出来，所以这里断言的是「到了首页」，
      // 而不是「页面调用了 go('/home')」。
      expectTenantHome();
    });

    testWidgets('注册入口通向注册页', (WidgetTester tester) async {
      await pumpRealApp(tester, repository: _signedOut());

      await tester.tap(find.widgetWithText(TextButton, '注册新账号'));
      await tester.pumpAndSettle();

      expect(find.widgetWithText(AppBar, '注册新账号'), findsOneWidget);
    });

    testWidgets('字段类失败挂到输入框下方，不再另弹提示条', (WidgetTester tester) async {
      final repository = _signedOut();
      await pumpRealApp(tester, repository: repository);

      repository.nextLoginFailure = const ValidationFailure(
        '请求参数有误',
        <String, String>{'password': '密码不正确'},
      );

      await tester.enterText(
        find.widgetWithText(TextFormField, '登录账号'),
        'owner',
      );
      await tester.enterText(find.widgetWithText(TextFormField, '密码'), 'wrong');
      await tester.tap(find.widgetWithText(FilledButton, '登录'));
      await tester.pumpAndSettle();

      expect(find.text('密码不正确'), findsOneWidget);
      // 同一条错误不说两遍：已经挂到输入框下方，就不该再飘提示条。
      expect(find.byType(SnackBar), findsNothing);
      expect(find.text('请求参数有误'), findsNothing);
      // 失败后仍停在登录页（守卫只在会话建立后才放人进去）。
      expect(find.widgetWithText(FilledButton, '登录'), findsOneWidget);
    });

    testWidgets('非字段类失败只弹一条提示，且提示里不含密码', (WidgetTester tester) async {
      final repository = _signedOut();
      await pumpRealApp(tester, repository: repository);

      repository.nextLoginFailure = const UnauthenticatedFailure('账号或密码不正确');

      await tester.enterText(
        find.widgetWithText(TextFormField, '登录账号'),
        'owner',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, '密码'),
        'sup3r-s3cret',
      );
      await tester.tap(find.widgetWithText(FilledButton, '登录'));
      await tester.pumpAndSettle();

      expect(find.text('账号或密码不正确'), findsOneWidget);
      // 密码是凭据，绝不能被拼进任何提示文案里。
      expect(
        find.descendant(
          of: find.byType(SnackBar),
          matching: find.text('sup3r-s3cret'),
        ),
        findsNothing,
      );
      // 整棵树里也不该有任何 Text 拿着它。
      //
      // 这里不能用 `find.text(...)`：它连 `EditableText` 的内容一起匹配，
      // 而输入框本来就应该装着用户刚敲的密码 —— 那样断言必红，且红得莫名其妙。
      expect(find.widgetWithText(Text, 'sup3r-s3cret'), findsNothing);
    });

    testWidgets('提交中按钮禁用，失败后恢复可点', (WidgetTester tester) async {
      final repository = _signedOut();
      await pumpRealApp(tester, repository: repository);

      // 把请求挂在一个永不完成的 Future 上，就能停在「提交中」这一帧。
      final pending = Completer<AuthSession>();
      repository.queuedLogins.add(pending.future);

      await tester.enterText(
        find.widgetWithText(TextFormField, '登录账号'),
        'owner',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, '密码'),
        'password123',
      );
      await tester.tap(find.widgetWithText(FilledButton, '登录'));
      // 只 pump 一帧：按钮此刻已换成 spinner（无限动画），
      // 用 pumpAndSettle 会直接超时。
      await tester.pump();

      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull,
      );

      pending.completeError(const UnauthenticatedFailure('账号或密码不正确'));
      await tester.pumpAndSettle();

      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNotNull,
      );
    });

    testWidgets('从注册页回来时用户名已预填', (WidgetTester tester) async {
      final repository = _signedOut();
      await pumpRealApp(tester, repository: repository);

      await tester.tap(find.widgetWithText(TextButton, '注册新账号'));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.widgetWithText(TextFormField, '邀请码'),
        'INV-0001',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, '登录账号'),
        'sales',
      );
      await tester.enterText(find.widgetWithText(TextFormField, '姓名'), '李四');
      await tester.enterText(
        find.widgetWithText(TextFormField, '密码'),
        'password123',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, '确认密码'),
        'password123',
      );
      await tester.tap(find.widgetWithText(FilledButton, '注册'));
      await tester.pumpAndSettle();

      // 注册不建立会话 ⇒ 回到登录页，而不是直接进业务区。
      expect(find.widgetWithText(FilledButton, '登录'), findsOneWidget);
      // 用户名已经预填：不该让人刚设完账号又手打一遍。
      final usernameField = tester.widget<TextFormField>(
        find.widgetWithText(TextFormField, '登录账号'),
      );
      expect(usernameField.controller?.text, 'sales');
    });
  });

  /* ------------------------------------------------------------ 注册 */

  group('注册页', () {
    Future<FakeAuthRepository> openRegister(WidgetTester tester) async {
      final repository = _signedOut();
      await pumpRealApp(tester, repository: repository);
      await tester.tap(find.widgetWithText(TextButton, '注册新账号'));
      await tester.pumpAndSettle();
      return repository;
    }

    Future<void> fillForm(
      WidgetTester tester, {
      String confirm = 'password123',
    }) async {
      await tester.enterText(
        find.widgetWithText(TextFormField, '邀请码'),
        'INV-0001',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, '登录账号'),
        'sales',
      );
      await tester.enterText(find.widgetWithText(TextFormField, '姓名'), '李四');
      await tester.enterText(
        find.widgetWithText(TextFormField, '密码'),
        'password123',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, '确认密码'),
        confirm,
      );
    }

    testWidgets('只提交契约里的四个字段，确认密码不进请求', (WidgetTester tester) async {
      final repository = await openRegister(tester);
      await fillForm(tester);

      await tester.tap(find.widgetWithText(FilledButton, '注册'));
      await tester.pumpAndSettle();

      final draft = repository.registerCalls.single;
      expect(draft.invitationCode, 'INV-0001');
      expect(draft.username, 'sales');
      expect(draft.displayName, '李四');
      expect(draft.password, 'password123');
      // `RegistrationDraft` 只有这四个字段 —— 确认密码没有地方可以塞进去，
      // 这正是「它只用于本地相等校验」在类型上的保证。
    });

    testWidgets('两次密码不一致：本地拦住，一个请求都不发', (WidgetTester tester) async {
      final repository = await openRegister(tester);
      await fillForm(tester, confirm: 'password124');

      await tester.tap(find.widgetWithText(FilledButton, '注册'));
      await tester.pumpAndSettle();

      expect(find.text('两次输入的密码不一致'), findsOneWidget);
      expect(repository.registerCalls, isEmpty);
      // 还停在注册页。
      expect(find.widgetWithText(AppBar, '注册新账号'), findsOneWidget);
    });

    testWidgets('密码短于 8 位：本地拦住，一个请求都不发', (WidgetTester tester) async {
      final repository = await openRegister(tester);
      await tester.enterText(
        find.widgetWithText(TextFormField, '邀请码'),
        'INV-0001',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, '登录账号'),
        'sales',
      );
      await tester.enterText(find.widgetWithText(TextFormField, '姓名'), '李四');
      await tester.enterText(find.widgetWithText(TextFormField, '密码'), 'short');
      await tester.enterText(
        find.widgetWithText(TextFormField, '确认密码'),
        'short',
      );

      await tester.tap(find.widgetWithText(FilledButton, '注册'));
      await tester.pumpAndSettle();

      expect(find.text('密码不少于 8 位'), findsOneWidget);
      expect(repository.registerCalls, isEmpty);
    });

    testWidgets('邀请码无效时错误挂在邀请码输入框下方', (WidgetTester tester) async {
      final repository = await openRegister(tester);
      repository.nextRegisterFailure = const ValidationFailure(
        '请求参数有误',
        <String, String>{'invitation_code': '邀请码无效或已使用'},
      );
      await fillForm(tester);

      await tester.tap(find.widgetWithText(FilledButton, '注册'));
      await tester.pumpAndSettle();

      expect(find.text('邀请码无效或已使用'), findsOneWidget);
      expect(find.byType(SnackBar), findsNothing);
    });

    testWidgets('邀请码改一个字，上一条服务端错误立刻消失', (WidgetTester tester) async {
      final repository = await openRegister(tester);
      repository.nextRegisterFailure = const ValidationFailure(
        '请求参数有误',
        <String, String>{'invitation_code': '邀请码无效或已使用'},
      );
      await fillForm(tester);
      await tester.tap(find.widgetWithText(FilledButton, '注册'));
      await tester.pumpAndSettle();
      expect(find.text('邀请码无效或已使用'), findsOneWidget);

      await tester.enterText(
        find.widgetWithText(TextFormField, '邀请码'),
        'INV-0002',
      );
      await tester.pumpAndSettle();

      // 服务端错误是针对「那一次提交内容」的判断，内容一变就不再成立；
      // 挂着不放会让人以为改完还是错的。
      expect(find.text('邀请码无效或已使用'), findsNothing);
    });
  });

  /* -------------------------------------------------------- 强制改密 */

  group('修改密码页', () {
    testWidgets('待改密时用户被锁在改密页，且没有任何业务入口', (WidgetTester tester) async {
      final repository = FakeAuthRepository(
        session: ownerSession(mustChangePassword: true),
      );
      await pumpRealApp(tester, repository: repository);

      expect(find.widgetWithText(AppBar, '修改密码'), findsOneWidget);
      expect(find.text('当前密码是初始密码或已被重置，请先修改后再使用系统。'), findsOneWidget);
      // 强制改密期间所有业务地址都会被守卫弹回来，所以一个导航项都不给 ——
      // 摆一排点了就回来的按钮，只会让用户以为功能坏了。
      expect(find.text('首页'), findsNothing);
      expect(find.text('字典'), findsNothing);
      expect(find.text('成员'), findsNothing);
      expect(find.text('邀请码'), findsNothing);
      // 但**必须**留一条退路：拿不到旧密码的人不该被永久锁在这一页。
      expect(find.byTooltip('退出登录'), findsOneWidget);
    });

    testWidgets('改密成功后由守卫送到租户首页', (WidgetTester tester) async {
      final repository = FakeAuthRepository(
        session: ownerSession(mustChangePassword: true),
      );
      await pumpRealApp(tester, repository: repository);

      // 改密成功会用同一个令牌重读身份，`must_change_password` 随之清零。
      repository.session = ownerSession();

      await tester.enterText(
        find.widgetWithText(TextFormField, '当前密码'),
        'old-password',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, '新密码'),
        'new-password',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, '确认新密码'),
        'new-password',
      );
      await tester.tap(find.widgetWithText(FilledButton, '保存'));
      await tester.pumpAndSettle();

      expect(repository.changePasswordCalls.single, (
        currentPassword: 'old-password',
        newPassword: 'new-password',
      ));
      expectTenantHome();
    });

    testWidgets('当前密码错误：错误挂在输入框，且人仍是登录态', (WidgetTester tester) async {
      final repository = FakeAuthRepository(
        session: ownerSession(mustChangePassword: true),
      );
      await pumpRealApp(tester, repository: repository);
      repository.nextChangePasswordFailure = const ValidationFailure(
        '请求参数有误',
        <String, String>{'current_password': '当前密码不正确'},
      );

      await tester.enterText(
        find.widgetWithText(TextFormField, '当前密码'),
        'wrong-password',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, '新密码'),
        'new-password',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, '确认新密码'),
        'new-password',
      );
      await tester.tap(find.widgetWithText(FilledButton, '保存'));
      await tester.pumpAndSettle();

      expect(find.text('当前密码不正确'), findsOneWidget);
      // 改密失败**不能**把人踢回登录页：他依旧是合法登录态，只是这次没改成。
      // 被弹回登录页会让人以为自己被登出了。
      expect(find.widgetWithText(AppBar, '修改密码'), findsOneWidget);
    });

    testWidgets('两次新密码不一致：本地拦住，一个请求都不发', (WidgetTester tester) async {
      final repository = FakeAuthRepository(
        session: ownerSession(mustChangePassword: true),
      );
      await pumpRealApp(tester, repository: repository);

      await tester.enterText(
        find.widgetWithText(TextFormField, '当前密码'),
        'old-password',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, '新密码'),
        'new-password',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, '确认新密码'),
        'new-password2',
      );
      await tester.tap(find.widgetWithText(FilledButton, '保存'));
      await tester.pumpAndSettle();

      expect(find.text('两次输入的新密码不一致'), findsOneWidget);
      expect(repository.changePasswordCalls, isEmpty);
    });

    testWidgets('确认退出后调一次登出，并由守卫送回登录页', (WidgetTester tester) async {
      final repository = FakeAuthRepository(
        session: ownerSession(mustChangePassword: true),
      );
      await pumpRealApp(tester, repository: repository);

      await tester.tap(find.byTooltip('退出登录'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '退出'));
      await tester.pumpAndSettle();

      expect(repository.logoutCalls, 1);
      expect(find.widgetWithText(FilledButton, '登录'), findsOneWidget);
    });
  });
}
