/// Identifies the authentication transport selected for the current client.
enum AuthPlatform { native, web }

/// A response received from one of the authentication endpoints.
///
/// Web endpoints intentionally omit [refreshToken] because it is held in an
/// HttpOnly cookie. Native endpoints provide it so the app can put it in the
/// operating system's encrypted credential store.
final class TokenResponse {
  const TokenResponse({
    required this.accessToken,
    this.refreshToken,
    this.accessExpiresAt,
    this.refreshExpiresAt,
  });

  final String accessToken;
  final String? refreshToken;
  final DateTime? accessExpiresAt;
  final DateTime? refreshExpiresAt;
}

/// The short-lived credential retained only while this process is alive.
final class AuthSession {
  const AuthSession({
    required this.accessToken,
    this.accessExpiresAt,
    this.mustChangePassword = false,
  });

  final String accessToken;
  final DateTime? accessExpiresAt;
  final bool mustChangePassword;
}

/// Keeps the access token out of durable storage and makes it replaceable in
/// tests without coupling network code to a repository implementation.
abstract interface class AccessTokenStore {
  String? get accessToken;

  set accessToken(String? value);

  void clear();
}

/// The only production access-token store. Its state disappears on process
/// exit, so a stolen browser profile or desktop cache cannot reveal an access
/// token after the session ends.
final class InMemoryAccessTokenStore implements AccessTokenStore {
  String? _accessToken;

  @override
  String? get accessToken => _accessToken;

  @override
  set accessToken(String? value) => _accessToken = value;

  @override
  void clear() => _accessToken = null;
}
