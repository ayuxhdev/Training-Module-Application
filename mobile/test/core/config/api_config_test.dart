import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:training_app/core/config/api_config.dart';

import 'dart:io';

void main() {
  group('ApiConfig', () {
    test('non-debug builds require explicit HTTPS configuration', () {
      for (final url in [
        '',
        'http://10.0.2.2:8000',
        'http://localhost:8000',
        'http://example.com',
      ]) {
        expect(
          () => ApiConfig.resolveUrl(url, true, debug: false),
          throwsStateError,
        );
      }
      expect(
        ApiConfig.resolveUrl('https://api.example.com', true, debug: false),
        'https://api.example.com/api/v1',
      );
    });

    test('Android debug HTTP allows emulator and ADB reverse hosts only', () {
      expect(
        ApiConfig.resolveUrl('http://10.0.2.2:8000', true),
        'http://10.0.2.2:8000/api/v1',
      );
      expect(
        ApiConfig.resolveUrl('http://localhost:8000', true),
        'http://localhost:8000/api/v1',
      );
      expect(
        () => ApiConfig.resolveUrl('http://localhost:8000', false),
        throwsStateError,
      );
      for (final url in [
        'http://example.com',
        'http://10.0.2.2.example.com',
        'http://127.0.0.1:8000',
        'http://localhost:8001',
        'http://localhost.example:8000',
        'https://user:password@example.com',
        'https://example.com?token=secret',
        'https://example.com#fragment',
      ]) {
        expect(() => ApiConfig.resolveUrl(url, true), throwsStateError);
      }
    });
    test('baseUrl returns a valid URL string', () {
      final baseUrl = ApiConfig.baseUrl;
      expect(baseUrl, isNotEmpty);
      expect(baseUrl.endsWith('/api/v1'), isTrue);
      expect(baseUrl.startsWith('http://'), isTrue);
    });

    test('baseUrl correctly maps based on platform', () {
      final baseUrl = ApiConfig.baseUrl;

      bool isAndroid = false;
      if (!kIsWeb) {
        try {
          isAndroid = Platform.isAndroid;
        } catch (_) {}
      }

      if (isAndroid) {
        expect(baseUrl, 'http://10.0.2.2:8000/api/v1');
      } else {
        expect(baseUrl, 'http://127.0.0.1:8000/api/v1');
      }
    });
    test('resolveUrl normalizes trailing slash', () {
      // With single trailing slash
      expect(
        ApiConfig.resolveUrl('https://example.com/', false),
        'https://example.com/api/v1',
      );

      // With multiple trailing slashes
      expect(
        ApiConfig.resolveUrl('https://example.com////', false),
        'https://example.com/api/v1',
      );

      // Without trailing slash
      expect(
        ApiConfig.resolveUrl('https://example.com', false),
        'https://example.com/api/v1',
      );
    });

    test('resolveUrl falls back to local host if env is empty', () {
      expect(ApiConfig.resolveUrl('', true), 'http://10.0.2.2:8000/api/v1');
      expect(ApiConfig.resolveUrl('', false), 'http://127.0.0.1:8000/api/v1');
    });
  });
}
