import 'package:c_biz_docs_manager/core/error/app_failure.dart';
import 'package:c_biz_docs_manager/core/network/error_mapper.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  DioException responseError(int status, String code, {Object? fieldErrors}) {
    final request = RequestOptions(path: '/test');
    final data = <String, Object?>{
      'code': code,
      'message': 'message',
      'data': null,
      'request_id': 'request-1',
    };
    if (fieldErrors != null) {
      data['field_errors'] = fieldErrors;
    }
    return DioException(
      requestOptions: request,
      response: Response<Object?>(
        requestOptions: request,
        statusCode: status,
        data: data,
      ),
      type: DioExceptionType.badResponse,
    );
  }

  test('maps stable API errors to domain failures', () {
    expect(
      mapDioFailure(responseError(401, 'AUTH_TOKEN_EXPIRED')),
      isA<UnauthenticatedFailure>(),
    );
    expect(
      mapDioFailure(responseError(403, 'FORBIDDEN')),
      isA<ForbiddenFailure>(),
    );
    expect(
      mapDioFailure(responseError(409, 'RESOURCE_VERSION_CONFLICT')),
      isA<ConflictFailure>(),
    );
    final validation = mapDioFailure(
      responseError(
        400,
        'VALIDATION_FAILED',
        fieldErrors: <Object?>[
          <String, Object?>{'field': 'name', 'message': 'required'},
        ],
      ),
    );
    expect(validation, isA<ValidationFailure>());
    expect((validation as ValidationFailure).fields, <String, String>{
      'name': 'required',
    });
  });

  test('maps transport and unknown response failures safely', () {
    final request = RequestOptions(path: '/test');
    expect(
      mapDioFailure(
        DioException(
          requestOptions: request,
          type: DioExceptionType.connectionTimeout,
        ),
      ),
      isA<NetworkFailure>(),
    );
    final unknown = mapDioFailure(responseError(500, 'SOMETHING_NEW'));
    expect(unknown, isA<ServerFailure>());
    expect(unknown.message, 'message');
    expect(unknown.requestId, 'request-1');
  });
}
