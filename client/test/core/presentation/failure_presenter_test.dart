import 'package:c_biz_docs_manager/core/error/app_failure.dart';
import 'package:c_biz_docs_manager/core/presentation/failure_presenter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('FailurePresenter.present', () {
    test('校验失败：保留服务端摘要，并把字段错误原样交出去', () {
      final presentation = FailurePresenter.present(
        const ValidationFailure('提交内容有 2 处问题', <String, String>{
          'name': '名称不能为空',
          'owner_username': '用户名已被占用',
        }, requestId: 'req-1'),
      );

      expect(presentation.message, '提交内容有 2 处问题');
      // 字段错误要能被表单直接拿去挂到对应输入框，所以键必须原样保留，
      // 不能在这里做任何"友好化"改名。
      expect(presentation.fieldErrors, <String, String>{
        'name': '名称不能为空',
        'owner_username': '用户名已被占用',
      });
      expect(presentation.hasFieldErrors, isTrue);
      expect(presentation.requestId, 'req-1');
      expect(presentation.shouldLeavePage, isFalse);
      expect(presentation.shouldRefresh, isFalse);
    });

    test('校验失败但无字段明细时 hasFieldErrors 为 false', () {
      final presentation = FailurePresenter.present(
        const ValidationFailure('参数不合法', <String, String>{}),
      );

      expect(presentation.hasFieldErrors, isFalse);
    });

    test('冲突失败：换成固定文案并要求刷新，且丢弃底层细节', () {
      final presentation = FailurePresenter.present(
        const ConflictFailure('version 不匹配（期望 3，实际 5）', requestId: 'req-2'),
      );

      // 底层版本号对业务员没有可操作性，只告诉他"先刷新再决定"。
      expect(presentation.message, contains('数据已被其他操作修改'));
      expect(presentation.message, isNot(contains('version')));
      expect(presentation.shouldRefresh, isTrue);
      expect(presentation.shouldLeavePage, isFalse);
      expect(presentation.requestId, 'req-2');
    });

    test('权限失败：要求页面离开，交由守卫接手', () {
      final presentation = FailurePresenter.present(
        const ForbiddenFailure('无权访问该组', requestId: 'req-3'),
      );

      expect(presentation.message, '无权访问该组');
      expect(presentation.shouldLeavePage, isTrue);
      expect(presentation.shouldRefresh, isFalse);
    });

    test('会话失效：两个动作标记都不设，避免和全局守卫抢跑', () {
      final presentation = FailurePresenter.present(
        const UnauthenticatedFailure('登录状态已失效', requestId: 'req-4'),
      );

      // 会话失效由 401 单飞刷新 + AuthSessionInvalidator + 路由守卫统一处理；
      // 页面若同时自己跳转，就会出现两次导航。
      expect(presentation.shouldLeavePage, isFalse);
      expect(presentation.shouldRefresh, isFalse);
      expect(presentation.message, '登录状态已失效');
    });

    test('网络失败：文案必须点明"需要联网"', () {
      final presentation = FailurePresenter.present(
        const NetworkFailure('网络不可用，请稍后重试'),
      );

      expect(presentation.message, contains('需要联网'));
      // 传输层失败没有 requestId 可给。
      expect(presentation.requestId, isNull);
      expect(presentation.shouldRefresh, isFalse);
    });

    test('服务端失败：通用文案 + 可复制的 requestId', () {
      final presentation = FailurePresenter.present(
        const ServerFailure('服务器响应异常', requestId: 'req-5'),
      );

      expect(presentation.message, '服务器响应异常');
      expect(presentation.requestId, 'req-5');
      expect(presentation.shouldLeavePage, isFalse);
      expect(presentation.shouldRefresh, isFalse);
    });

    test('覆盖全部失败类型，新增子类时必须同步补分支', () {
      // 用一组「每种失败各来一个」的样本跑一遍，确保 presenter 的输出
      // 始终是非空文案：将来 sealed 层级新增成员时，编译器会先在 switch 处报错，
      // 这条用例则保证新分支不会悄悄返回空字符串。
      const failures = <AppFailure>[
        UnauthenticatedFailure('未登录'),
        ForbiddenFailure('无权'),
        ValidationFailure('校验', <String, String>{'x': 'y'}),
        ConflictFailure('冲突'),
        NetworkFailure('网络'),
        ServerFailure('服务端'),
      ];

      for (final failure in failures) {
        final presentation = FailurePresenter.present(failure);
        expect(
          presentation.message.trim(),
          isNotEmpty,
          reason: '${failure.runtimeType} 没有可展示的文案',
        );
      }
    });
  });
}
