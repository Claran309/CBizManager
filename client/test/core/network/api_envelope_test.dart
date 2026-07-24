import 'package:c_biz_docs_manager/core/network/api_envelope.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('parses a successful generic envelope', () {
    final envelope = ApiEnvelope<Map<String, Object?>>.fromJson(
      <String, Object?>{
        'code': 'OK',
        'message': 'success',
        'data': <String, Object?>{'id': 7},
        'request_id': 'request-1',
      },
      (value) => value! as Map<String, Object?>,
    );

    expect(envelope.code, 'OK');
    expect(envelope.data?['id'], 7);
    expect(envelope.requestId, 'request-1');
    expect(envelope.fieldErrors, isEmpty);
  });

  test('parses field errors and rejects malformed required fields', () {
    final envelope = ApiEnvelope<void>.fromJson(<String, Object?>{
      'code': 'VALIDATION_FAILED',
      'message': 'invalid',
      'data': null,
      'request_id': 'request-2',
      'field_errors': <Object?>[
        <String, Object?>{'field': 'name', 'message': 'required'},
      ],
    }, (_) {});
    expect(envelope.fieldErrors.single.field, 'name');
    expect(
      () => ApiEnvelope<void>.fromJson(<String, Object?>{
        'code': 'OK',
        'message': 'success',
      }, (_) {}),
      throwsFormatException,
    );
  });
}
