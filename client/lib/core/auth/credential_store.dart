/// Persists only a native refresh token. Implementations must never substitute
/// plaintext files or preferences when the platform secure store is unavailable.
abstract interface class CredentialStore {
  Future<String?> readRefreshToken();

  Future<void> writeRefreshToken(String token);

  Future<void> clear();
}
