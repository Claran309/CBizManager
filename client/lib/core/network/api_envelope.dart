final class ApiFieldError {
  const ApiFieldError({required this.field, required this.message});

  final String field;
  final String message;

  factory ApiFieldError.fromJson(Map<String, Object?> json) {
    final field = json['field'];
    final message = json['message'];
    if (field is! String || message is! String) {
      throw const FormatException('Invalid API field error');
    }
    return ApiFieldError(field: field, message: message);
  }
}

final class ApiEnvelope<T> {
  const ApiEnvelope({
    required this.code,
    required this.message,
    required this.data,
    required this.requestId,
    this.fieldErrors = const <ApiFieldError>[],
  });

  final String code;
  final String message;
  final T? data;
  final String requestId;
  final List<ApiFieldError> fieldErrors;

  factory ApiEnvelope.fromJson(
    Map<String, Object?> json,
    T Function(Object? value) decodeData,
  ) {
    if (!json.containsKey('code') ||
        !json.containsKey('message') ||
        !json.containsKey('data') ||
        !json.containsKey('request_id')) {
      throw const FormatException('API envelope is missing required fields');
    }
    final code = json['code'];
    final message = json['message'];
    final requestId = json['request_id'];
    if (code is! String || message is! String || requestId is! String) {
      throw const FormatException('API envelope has invalid field types');
    }
    final rawErrors = json['field_errors'];
    final errors = <ApiFieldError>[];
    if (rawErrors != null) {
      if (rawErrors is! List<Object?>) {
        throw const FormatException('API field_errors must be an array');
      }
      for (final value in rawErrors) {
        if (value is! Map) {
          throw const FormatException('API field error must be an object');
        }
        errors.add(ApiFieldError.fromJson(Map<String, Object?>.from(value)));
      }
    }
    final rawData = json['data'];
    return ApiEnvelope<T>(
      code: code,
      message: message,
      data: rawData == null ? null : decodeData(rawData),
      requestId: requestId,
      fieldErrors: List<ApiFieldError>.unmodifiable(errors),
    );
  }
}
