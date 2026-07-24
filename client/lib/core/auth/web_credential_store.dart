import 'package:c_biz_docs_manager/core/auth/credential_store.dart';

/// Web refresh tokens live exclusively in an HttpOnly server cookie. These
/// no-op methods make accidental localStorage/indexedDB persistence impossible
/// while keeping the repository's platform-neutral dependency surface intact.
final class WebCredentialStore implements CredentialStore {
  @override
  Future<void> clear() async {}

  @override
  Future<String?> readRefreshToken() async => null;

  @override
  Future<void> writeRefreshToken(String token) async {}
}
