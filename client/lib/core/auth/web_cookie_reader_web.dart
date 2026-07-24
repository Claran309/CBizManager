import 'package:web/web.dart' as web;

/// Reads one non-HttpOnly cookie for the Web double-submit CSRF flow.
///
/// The refresh cookie cannot be observed here by design; the browser attaches
/// it only because the corresponding Dio request enables `withCredentials`.
String? readBrowserCookie(String name) {
  final prefix = '$name=';
  for (final segment in web.document.cookie.split(';')) {
    final cookie = segment.trim();
    if (cookie.startsWith(prefix)) {
      return Uri.decodeComponent(cookie.substring(prefix.length));
    }
  }
  return null;
}
