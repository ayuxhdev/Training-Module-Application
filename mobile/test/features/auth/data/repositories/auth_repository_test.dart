import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:training_app/core/network/dio_client.dart';
import 'package:training_app/core/errors/api_error.dart';
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
    for (final type in [
      DioExceptionType.connectionError,
      DioExceptionType.receiveTimeout,
      DioExceptionType.badResponse,
    ]) {
      test(
        'partial login preserves $type and a later explicit login recovers',
        () async {
          when(() => mockDio.interceptors).thenReturn(Interceptors());
          repository = AuthRepository(
            apiClient: ApiClient(
              tokenStorage: mockTokenStorage,
              dioOverride: mockDio,
            ),
            tokenStorage: mockTokenStorage,
          );
          when(
            () => mockDio.post(
              '/auth/login/',
              data: {'username': 'EMP001', 'password': 'password'},
            ),
          ).thenAnswer(
            (_) async => Response(
              requestOptions: RequestOptions(path: '/auth/login/'),
              data: {'access': 'access_token', 'refresh': 'refresh_token'},
            ),
          );
          when(() => mockTokenStorage.saveAccessToken('access_token'))
              .thenAnswer((_) async {});
          when(() => mockTokenStorage.saveRefreshToken('refresh_token'))
              .thenAnswer((_) async {});
          final request = RequestOptions(path: '/auth/me/');
          when(() => mockDio.get('/auth/me/')).thenThrow(
            DioException(
              requestOptions: request,
              type: type,
              response: type == DioExceptionType.badResponse
                  ? Response(
                      requestOptions: request,
                      statusCode: 401,
                      data: {
                        'error': {
                          'message': 'Sign in again.',
                          'code': 'token_not_valid',
                          'fields': {'detail': 'Expired'},
                        },
                      },
                    )
                  : null,
            ),
          );
          final expected = switch (type) {
            DioExceptionType.connectionError => ApiError.networkFailure(),
            DioExceptionType.receiveTimeout => ApiError.timeout(),
            _ => ApiError(
              message: 'Sign in again.',
              code: 'token_not_valid',
              statusCode: 401,
            ),
          };
          await expectLater(
            repository.login('EMP001', 'password'),
            throwsA(
              isA<ApiError>()
                  .having((e) => e.message, 'message', expected.message)
                  .having((e) => e.code, 'code', expected.code)
                  .having((e) => e.statusCode, 'status', expected.statusCode),
            ),
          );
          verify(
            () => mockDio.post(
              '/auth/login/',
              data: {'username': 'EMP001', 'password': 'password'},
            ),
          ).called(1);
          when(() => mockDio.get('/auth/me/')).thenAnswer(
            (_) async => Response(
              requestOptions: request,
              data: {
                'username': 'EMP001',
                'employee_code': 'EMP001',
                'display_name': 'Learner',
                'department': 'QA',
                'job_role': 'Learner',
                'is_active': true,
              },
            ),
          );
          expect(
            (await repository.login('EMP001', 'password')).employee!.employeeCode,
            'EMP001',
          );
        },
      );
    }

    test('management login and restoration parse identity without a fabricated Employee', () async {
      when(() => mockDio.post('/auth/login/', data: {'username': 'administrator', 'password': 'password'}))
          .thenAnswer((_) async => Response(requestOptions: RequestOptions(path: '/'),
            data: {'access': 'access_token', 'refresh': 'refresh_token'}));
      when(() => mockTokenStorage.saveAccessToken('access_token')).thenAnswer((_) async {});
      when(() => mockTokenStorage.saveRefreshToken('refresh_token')).thenAnswer((_) async {});
      when(() => mockDio.get('/auth/me/')).thenAnswer((_) async => Response(
        requestOptions: RequestOptions(path: '/'), data: {
          'user': {'id': 20, 'username': 'administrator', 'display_name': 'Administrator'},
          'employee': null, 'capabilities': ['management_workspace'],
        }));
      final identity = await repository.login('administrator', 'password');
      expect(identity.employee, isNull);
      expect(identity.canManage, isTrue);
      expect(identity.canLearn, isFalse);
      expect((await repository.getCurrentIdentity()).username, 'administrator');
      verifyNever(() => mockDio.get('/dashboard/'));
      verifyNever(() => mockDio.get('/assignments/'));
    });

    test('login successfully stores tokens and returns employee', () async {
      when(
        () => mockDio.post(
          '/auth/login/',
          data: {'username': 'EMP001', 'password': 'password'},
        ),
      ).thenAnswer(
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

      when(() => mockTokenStorage.saveAccessToken('access_token'))
          .thenAnswer((_) async {});
      when(() => mockTokenStorage.saveRefreshToken('refresh_token'))
          .thenAnswer((_) async {});

      final employee = await repository.login('EMP001', 'password');

      expect(employee.employee!.employeeCode, 'EMP001');
      expect(employee.displayName, 'Test User');
      verify(() => mockTokenStorage.saveAccessToken('access_token')).called(1);
      verify(() => mockTokenStorage.saveRefreshToken('refresh_token'))
          .called(1);
    });

    test(
      'logout successfully clears local storage even on network error',
      () async {
        when(() => mockTokenStorage.readRefreshToken())
            .thenAnswer((_) async => 'refresh_token');
        when(
          () =>
              mockDio.post('/auth/logout/', data: {'refresh': 'refresh_token'}),
        ).thenThrow(DioException(requestOptions: RequestOptions(path: '/')));
        when(() => mockTokenStorage.clearAuthenticationState())
            .thenAnswer((_) async {});

        await repository.logout();

        verify(
          () =>
              mockDio.post('/auth/logout/', data: {'refresh': 'refresh_token'}),
        ).called(1);
        verify(() => mockTokenStorage.clearAuthenticationState()).called(1);
      },
    );
  });
}
