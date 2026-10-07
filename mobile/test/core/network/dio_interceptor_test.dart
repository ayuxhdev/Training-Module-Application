import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:training_app/core/network/dio_interceptor.dart';
import 'package:training_app/core/storage/secure_token_storage.dart';

class MockSecureTokenStorage extends Mock implements SecureTokenStorage {}
class MockRequestInterceptorHandler extends Mock implements RequestInterceptorHandler {}

void main() {
  late MockSecureTokenStorage mockStorage;
  late MockRequestInterceptorHandler mockHandler;
  late AuthInterceptor interceptor;

  setUp(() {
    mockStorage = MockSecureTokenStorage();
    mockHandler = MockRequestInterceptorHandler();
    interceptor = AuthInterceptor(tokenStorage: mockStorage);
    registerFallbackValue(RequestOptions(path: ''));
  });

  test('Adds Authorization header if token exists', () async {
    when(() => mockStorage.readAccessToken()).thenAnswer((_) async => 'test_token');
    
    final options = RequestOptions(path: '/test');
    await interceptor.onRequest(options, mockHandler);

    expect(options.headers['Authorization'], 'Bearer test_token');
    verify(() => mockHandler.next(options)).called(1);
  });

  test('Does not add Authorization header if token is null', () async {
    when(() => mockStorage.readAccessToken()).thenAnswer((_) async => null);
    
    final options = RequestOptions(path: '/test');
    await interceptor.onRequest(options, mockHandler);

    expect(options.headers.containsKey('Authorization'), isFalse);
    verify(() => mockHandler.next(options)).called(1);
  });
}

