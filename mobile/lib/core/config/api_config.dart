import 'dart:io';

class ApiConfig {
  /// Base URL for the Django API.
  /// 
  /// In a production environment, this can be overridden using:
  /// --dart-define=API_BASE_URL=https://api.yourdomain.com
  /// 
  /// For local Android emulator development,
  /// 10.0.2.2 maps to the host's loopback interface (localhost).
  static const String _envBaseUrl = String.fromEnvironment('API_BASE_URL');

  /// Helper to resolve the URL, exposed for testing trailing slash logic.
  static String resolveUrl(String envUrl, bool isAndroid) {
    if (envUrl.isNotEmpty) {
      String normalizedUrl = envUrl;
      while (normalizedUrl.endsWith('/')) {
        normalizedUrl = normalizedUrl.substring(0, normalizedUrl.length - 1);
      }
      return '$normalizedUrl/api/v1';
    }

    if (isAndroid) {
      return 'http://10.0.2.2:8000/api/v1';
    }
    return 'http://127.0.0.1:8000/api/v1';
  }

  static String get baseUrl {
    bool isAndroid = false;
    try {
      isAndroid = Platform.isAndroid;
    } catch (_) {
      // In web or unsupported platforms, this will throw.
    }
    return resolveUrl(_envBaseUrl, isAndroid);
  }
}

