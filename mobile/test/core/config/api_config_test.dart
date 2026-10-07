import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:training_app/core/config/api_config.dart';
import 'dart:io';

void main() {
  group('ApiConfig', () {
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
      expect(
        ApiConfig.resolveUrl('', true),
        'http://10.0.2.2:8000/api/v1',
      );
      expect(
        ApiConfig.resolveUrl('', false),
        'http://127.0.0.1:8000/api/v1',
      );
    });
  });
}
