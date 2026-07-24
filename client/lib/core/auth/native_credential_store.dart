import 'package:c_biz_docs_manager/core/auth/credential_store.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Small abstraction around the plugin so storage behaviour is unit-testable
/// without loading a platform channel. Plugin errors deliberately propagate.
abstract interface class SecureStorageDriver {
  Future<String?> read(String key);

  Future<void> write(String key, String value);

  Future<void> delete(String key);
}

final class FlutterSecureStorageDriver implements SecureStorageDriver {
  FlutterSecureStorageDriver({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  @override
  Future<void> delete(String key) => _storage.delete(key: key);

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);
}

/// Uses Android/Windows platform encryption through `flutter_secure_storage`.
/// There is intentionally no error recovery path to a weaker persistence layer.
final class NativeCredentialStore implements CredentialStore {
  NativeCredentialStore({SecureStorageDriver? driver})
    : _driver = driver ?? FlutterSecureStorageDriver();

  static const _refreshTokenKey = 'cbiz_docs_manager.refresh_token';

  final SecureStorageDriver _driver;

  @override
  Future<void> clear() => _driver.delete(_refreshTokenKey);

  @override
  Future<String?> readRefreshToken() => _driver.read(_refreshTokenKey);

  @override
  Future<void> writeRefreshToken(String token) =>
      _driver.write(_refreshTokenKey, token);
}
