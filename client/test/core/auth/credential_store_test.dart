import 'package:c_biz_docs_manager/core/auth/native_credential_store.dart';
import 'package:c_biz_docs_manager/core/auth/web_credential_store.dart';
import 'package:flutter_test/flutter_test.dart';

final class FakeSecureStorageDriver implements SecureStorageDriver {
  String? value;

  @override
  Future<void> delete(String key) async => value = null;

  @override
  Future<String?> read(String key) async => value;

  @override
  Future<void> write(String key, String value) async => this.value = value;
}

void main() {
  test('native credential store delegates to secure storage only', () async {
    final driver = FakeSecureStorageDriver();
    final store = NativeCredentialStore(driver: driver);
    await store.writeRefreshToken('refresh');
    expect(await store.readRefreshToken(), 'refresh');
    await store.clear();
    expect(await store.readRefreshToken(), isNull);
  });

  test('web credential store never retains a refresh token', () async {
    final store = WebCredentialStore();
    await store.writeRefreshToken('must-not-be-stored');
    expect(await store.readRefreshToken(), isNull);
    await store.clear();
  });
}
