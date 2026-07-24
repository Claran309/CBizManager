import 'package:flutter/foundation.dart';

final class AppConfig {
  const AppConfig({required this.apiBaseUrl});

  final String apiBaseUrl;

  factory AppConfig.fromEnvironment() {
    const configured = String.fromEnvironment('API_BASE_URL');
    if (configured.trim().isNotEmpty) {
      return const AppConfig(apiBaseUrl: configured);
    }
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      return const AppConfig(apiBaseUrl: 'http://10.0.2.2:8080');
    }
    return const AppConfig(apiBaseUrl: 'http://127.0.0.1:8080');
  }
}
