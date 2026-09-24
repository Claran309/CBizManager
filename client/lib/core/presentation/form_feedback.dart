import 'package:c_biz_docs_manager/core/presentation/failure_presenter.dart';
import 'package:flutter/material.dart';

/// 表单页共用的一段状态：服务端下发的**逐字段错误**，以及「内联还是弹条」的判定。
///
/// 为什么值得抽出来：登录、注册、改密，再加上平台侧的「新建业务组」，四个表单页
/// 都要做同样的四件事 —— 接住 `ValidationFailure.fields`、把它们挂到对应输入框、
/// 用户改动某个字段就清掉那一条、以及「有字段错误挂不下时退回统一提示条」。
/// 抄四遍的必然结果是有三份会漏掉「用户一改就清」，于是「账号已存在」会一直
/// 挂在输入框下面，哪怕用户已经把账号名改成了别的。
///
/// 用法：`class _MyPageState extends State<MyPage> with ServerFieldErrorsMixin<MyPage>`，
/// 然后实现 [formFieldNames] 与 [formKey] 两个成员。
mixin ServerFieldErrorsMixin<T extends StatefulWidget> on State<T> {
  /// 本页**真正渲染了输入框**的字段名（与契约字段名一致，snake_case）。
  ///
  /// 这份集合同时充当「这条字段错误我能不能展示」的判据：服务端可能返回
  /// 本页无处安放的键（例如请求体级的 `body`），那种情况必须退回统一提示条，
  /// 否则用户会看到「提交失败」却在整个页面上找不到任何一处红字。
  Set<String> get formFieldNames;

  /// 本页 `Form` 的 key。写入服务端错误后要靠它立刻重跑一次校验，
  /// 不然红字要等到用户下一次点提交才会出现。
  GlobalKey<FormState> get formKey;

  Map<String, String> _serverFieldErrors = const <String, String>{};

  /// 只读视图，供测试与调试使用。
  Map<String, String> get serverFieldErrors => _serverFieldErrors;

  /// 某个字段当前挂着的服务端错误；没有则为 null。
  String? serverErrorOf(String field) => _serverFieldErrors[field];

  /// 用户改动了某个字段 —— 该字段上的服务端错误立刻作废。
  ///
  /// 服务端错误是「针对那一次提交内容」的判断，内容一变就不再成立。
  void clearServerError(String field) {
    if (!_serverFieldErrors.containsKey(field)) {
      return;
    }
    setState(() {
      // 复制一份再删，避免直接改动上一份状态里的 Map（状态应当是不可变的）。
      _serverFieldErrors = Map<String, String>.of(_serverFieldErrors)
        ..remove(field);
    });
  }

  /// 本次提交前把上一轮的服务端错误整体作废。
  void clearAllServerErrors() {
    if (_serverFieldErrors.isEmpty) {
      return;
    }
    setState(() => _serverFieldErrors = const <String, String>{});
  }

  /// 每条错误是否都能挂到本页的输入框上。
  bool canPlaceAllErrors(Map<String, String> errors) =>
      errors.isNotEmpty && errors.keys.every(formFieldNames.contains);

  /// 尝试把失败**内联**呈现。
  ///
  /// 返回 true 表示已经挂到输入框下方（调用方别再弹提示条，同一条错误不说两遍）；
  /// 返回 false 表示本页放不下，调用方应改用 [showMessage]。
  bool presentFieldErrors(FailurePresentation presentation) {
    if (!canPlaceAllErrors(presentation.fieldErrors)) {
      return false;
    }
    setState(() => _serverFieldErrors = presentation.fieldErrors);
    formKey.currentState?.validate();
    return true;
  }

  /// 统一的顶部提示条。
  void showMessage(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  /// 必填校验：**服务端错误优先**，其次才是本地规则。
  ///
  /// 服务端优先是因为它知道得更多（比如「该账号已被占用」本地根本判断不了）；
  /// 本地规则只是为了让用户不必为一个明确可知的错误白等一次往返。
  String? validateRequired(String field, String? value, String message) {
    final serverError = _serverFieldErrors[field];
    if (serverError != null) {
      return serverError;
    }
    if (value == null || value.trim().isEmpty) {
      return message;
    }
    return null;
  }

  /// 最短长度校验，同样服务端错误优先。
  String? validateMinLength(
    String field,
    String? value,
    int minLength,
    String message,
  ) {
    final serverError = _serverFieldErrors[field];
    if (serverError != null) {
      return serverError;
    }
    if ((value ?? '').length < minLength) {
      return message;
    }
    return null;
  }
}
