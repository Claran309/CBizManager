import 'package:c_biz_docs_manager/core/error/app_failure.dart';
import 'package:c_biz_docs_manager/core/network/api_envelope.dart';
import 'package:dio/dio.dart';

AppFailure mapDioFailure(DioException error) {
  if (_isTransportFailure(error)) {
    return const NetworkFailure('网络不可用，请稍后重试');
  }

  final status = error.response?.statusCode;
  final envelope = _readErrorEnvelope(error.response?.data);
  final message = envelope?.message ?? '服务器响应异常';
  final requestId = envelope?.requestId;
  if (status == 401) {
    return UnauthenticatedFailure(message, requestId: requestId);
  }
  if (status == 403) {
    return ForbiddenFailure(message, requestId: requestId);
  }
  if (status == 400 && envelope?.code == 'VALIDATION_FAILED') {
    return ValidationFailure(message, <String, String>{
      for (final fieldError in envelope!.fieldErrors)
        fieldError.field: fieldError.message,
    }, requestId: requestId);
  }
  if (status == 409) {
    return ConflictFailure(message, requestId: requestId);
  }
  return ServerFailure(message, requestId: requestId);
}

bool _isTransportFailure(DioException error) {
  return switch (error.type) {
    DioExceptionType.connectionTimeout ||
    DioExceptionType.transformTimeout ||
    DioExceptionType.sendTimeout ||
    DioExceptionType.receiveTimeout ||
    DioExceptionType.connectionError ||
    DioExceptionType.cancel => true,
    DioExceptionType.unknown => error.response == null,
    DioExceptionType.badCertificate || DioExceptionType.badResponse => false,
  };
}

ApiEnvelope<void>? _readErrorEnvelope(Object? value) {
  if (value is! Map) {
    return null;
  }
  try {
    return ApiEnvelope<void>.fromJson(Map<String, Object?>.from(value), (_) {});
  } on FormatException {
    return null;
  }
}
