import 'package:flutter_test/flutter_test.dart';
import 'package:dio/dio.dart';
import 'package:mocktail/mocktail.dart';
import 'package:training_app/core/network/dio_client.dart';
import 'package:training_app/core/storage/secure_token_storage.dart';

class MockSecureTokenStorage extends Mock implements SecureTokenStorage {}

void main() {
  group('ApiClient Error Mapping', () {
    late ApiClient apiClient;
    late MockSecureTokenStorage mockTokenStorage;

    setUp(() {
      mockTokenStorage = MockSecureTokenStorage();
      apiClient = ApiClient(tokenStorage: mockTokenStorage);
    });

    test('maps connection timeout to ApiError.timeout', () {
      final exception = DioException(
        requestOptions: RequestOptions(path: ''),
        type: DioExceptionType.connectionTimeout,
      );

      final result = apiClient.mapExceptionToApiError(exception);
      expect(result.message, 'The connection timed out. Please try again.');
    });

    test('maps connection error to ApiError.networkFailure', () {
      final exception = DioException(
        requestOptions: RequestOptions(path: ''),
        type: DioExceptionType.connectionError,
      );

      final result = apiClient.mapExceptionToApiError(exception);
      expect(result.message, 'Network connection failed. Please check your internet connection.');
    });

    test('maps badResponse to ApiError.fromBackend if map data present', () {
      final exception = DioException(
        requestOptions: RequestOptions(path: ''),
        type: DioExceptionType.badResponse,
        response: Response(
          requestOptions: RequestOptions(path: ''),
          statusCode: 400,
          data: {'detail': 'Invalid credentials'},
        ),
      );

      final result = apiClient.mapExceptionToApiError(exception);
      expect(result.statusCode, 400);
      expect(result.message, 'Invalid credentials');
    });

    test('maps unknown exception to ApiError.unexpected', () {
      final exception = Exception('Unknown error');
      final result = apiClient.mapExceptionToApiError(exception);
      expect(result.message, 'An unexpected error occurred. Please try again later.');
    });
  });
}
