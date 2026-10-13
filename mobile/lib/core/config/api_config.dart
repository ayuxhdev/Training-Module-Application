import 'dart:io';

import 'package:flutter/foundation.dart';

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
  static String resolveUrl(
    String envUrl,
    bool isAndroid, {
    bool debug = kDebugMode,
  }) {
    if (envUrl.isEmpty && !debug) {
      throw StateError('API_BASE_URL must specify an HTTPS origin.');
    }
    if (envUrl.isNotEmpty) {
      final uri = Uri.tryParse(envUrl);
      final localHost = isAndroid ? '10.0.2.2' : '127.0.0.1';
      if (uri == null ||
          !uri.hasAuthority ||
          uri.host.isEmpty ||
          uri.userInfo.isNotEmpty ||
          uri.hasQuery ||
          uri.hasFragment ||
          (uri.scheme != 'https' &&
              !(debug && uri.scheme == 'http' && uri.host == localHost))) {
        throw StateError(
          'API_BASE_URL requires HTTPS or the debug loopback host.',
        );
      }
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
