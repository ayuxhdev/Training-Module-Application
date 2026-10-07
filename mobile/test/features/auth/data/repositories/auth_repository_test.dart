import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:training_app/core/network/dio_client.dart';
import 'package:training_app/core/storage/secure_token_storage.dart';
import 'package:training_app/features/auth/data/repositories/auth_repository.dart';

class MockApiClient extends Mock implements ApiClient {}
class MockSecureTokenStorage extends Mock implements SecureTokenStorage {}
class MockDio extends Mock implements Dio {}

void main() {
  late AuthRepository repository;
  late MockApiClient mockApiClient;
  late MockSecureTokenStorage mockTokenStorage;
  late MockDio mockDio;

  setUp(() {
    mockApiClient = MockApiClient();
    mockTokenStorage = MockSecureTokenStorage();
    mockDio = MockDio();

    when(() => mockApiClient.dio).thenReturn(mockDio);

    repository = AuthRepository(
      apiClient: mockApiClient,
      tokenStorage: mockTokenStorage,
    );
  });

  group('AuthRepository', () {
    test('login successfully stores tokens and returns employee', () async {
      when(() => mockDio.post('/auth/login/', data: {'username': 'EMP001', 'password': 'password'})).thenAnswer(
        (_) async => Response(
          requestOptions: RequestOptions(path: '/'),
          data: {'access': 'access_token', 'refresh': 'refresh_token'},
          statusCode: 200,
        ),
      );

      when(() => mockDio.get('/auth/me/')).thenAnswer(
        (_) async => Response(
          requestOptions: RequestOptions(path: '/'),
          data: {
            'username': 'EMP001',
            'employee_code': 'EMP001',
            'display_name': 'Test User',
            'department': 'Engineering',
            'job_role': 'Engineer',
            'is_active': true,
          },
          statusCode: 200,
        ),
      );

      when(() => mockTokenStorage.saveAccessToken('access_token')).thenAnswer((_) async {});
      when(() => mockTokenStorage.saveRefreshToken('refresh_token')).thenAnswer((_) async {});

      final employee = await repository.login('EMP001', 'password');

      expect(employee.employeeCode, 'EMP001');
      expect(employee.displayName, 'Test User');
      verify(() => mockTokenStorage.saveAccessToken('access_token')).called(1);
      verify(() => mockTokenStorage.saveRefreshToken('refresh_token')).called(1);
    });

    test('logout successfully clears local storage even on network error', () async {
      when(() => mockTokenStorage.readRefreshToken()).thenAnswer((_) async => 'refresh_token');
      when(() => mockDio.post('/auth/logout/', data: {'refresh': 'refresh_token'})).thenThrow(DioException(
        requestOptions: RequestOptions(path: '/'),
      ));
      when(() => mockTokenStorage.clearAuthenticationState()).thenAnswer((_) async {});

      await repository.logout();

      verify(() => mockDio.post('/auth/logout/', data: {'refresh': 'refresh_token'})).called(1);
      verify(() => mockTokenStorage.clearAuthenticationState()).called(1);
    });
  });
}
