import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:training_app/core/errors/api_error.dart';
import 'package:training_app/features/auth/data/repositories/auth_repository.dart';
import 'package:training_app/features/auth/domain/models/auth_state.dart';
import 'package:training_app/features/auth/domain/models/employee.dart';
import 'package:training_app/core/storage/secure_token_storage.dart';
import 'package:training_app/features/auth/presentation/controllers/auth_controller.dart';

class MockAuthRepository extends Mock implements AuthRepository {}
class MockSecureTokenStorage extends Mock implements SecureTokenStorage {}

void main() {
  late MockAuthRepository mockRepository;
  late MockSecureTokenStorage storage;

  final tEmployee = Employee(
    username: 'EMP001',
    employeeCode: 'EMP001',
    displayName: 'Test User',
    department: 'Engineering',
    jobRole: 'Engineer',
    isActive: true,
  );

  setUp(() {
    mockRepository = MockAuthRepository();
    storage = MockSecureTokenStorage();
    when(() => mockRepository.tokenStorage).thenReturn(storage);
    when(() => storage.clearAuthenticationState()).thenAnswer((_) async {});
    when(() => mockRepository.logout()).thenAnswer((_) async {});
  });

  ProviderContainer makeContainer() {
    final container = ProviderContainer(
      overrides: [
        authRepositoryProvider.overrideWithValue(mockRepository),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  group('AuthController startup', () {
    test('initializes as unauthenticated when no tokens', () async {
      when(() => mockRepository.hasStoredCredentials()).thenAnswer((_) async => false);

      final container = makeContainer();
      final sub = container.listen(authControllerProvider, (_, _) {});

      expect(container.read(authControllerProvider), isA<AuthInitial>());

      await Future.delayed(Duration.zero);
      expect(container.read(authControllerProvider), isA<AuthUnauthenticated>());
      sub.close();
    });

    test('initializes as authenticated when tokens exist and /me succeeds', () async {
      when(() => mockRepository.hasStoredCredentials()).thenAnswer((_) async => true);
      when(() => mockRepository.getCurrentEmployee()).thenAnswer((_) async => tEmployee);

      final container = makeContainer();
      final sub = container.listen(authControllerProvider, (_, _) {});

      await Future.delayed(Duration.zero);
      expect(container.read(authControllerProvider), isA<AuthAuthenticated>());
      sub.close();
    });

    test('sets error and preserves tokens when /me has transient network failure', () async {
      when(() => mockRepository.hasStoredCredentials()).thenAnswer((_) async => true);
      when(() => mockRepository.getCurrentEmployee()).thenThrow(ApiError.networkFailure());

      final container = makeContainer();
      final sub = container.listen(authControllerProvider, (_, _) {});

      await Future.delayed(Duration.zero);
      expect(container.read(authControllerProvider), isA<AuthError>());
      verifyNever(() => mockRepository.logout());
      sub.close();
    });

    test('clears tokens and is unauthenticated when /me fails with 401, even if logout throws', () async {
      final mockTokenStorage = MockSecureTokenStorage();
      when(() => mockRepository.tokenStorage).thenReturn(mockTokenStorage);
      when(() => mockTokenStorage.clearAuthenticationState()).thenAnswer((_) async {});

      when(() => mockRepository.hasStoredCredentials()).thenAnswer((_) async => true);
      when(() => mockRepository.getCurrentEmployee()).thenThrow(
        ApiError(message: 'Unauthorized', statusCode: 401),
      );
      // Simulate logout throwing an exception
      when(() => mockRepository.logout()).thenThrow(Exception('Network down'));

      final container = makeContainer();
      final sub = container.listen(authControllerProvider, (_, _) {});

      await Future.delayed(Duration.zero);

      expect(container.read(authControllerProvider), isA<AuthUnauthenticated>());
      verify(() => mockRepository.logout()).called(1);
      verify(() => mockTokenStorage.clearAuthenticationState()).called(1);

      sub.close();
    });
  });

  group('Profile refresh and account races', () {
    Future<ProviderContainer> authenticatedContainer() async {
      when(() => mockRepository.hasStoredCredentials())
          .thenAnswer((_) async => true);
      when(() => mockRepository.getCurrentEmployee())
          .thenAnswer((_) async => tEmployee);
      final container = makeContainer();
      container.read(authControllerProvider);
      await Future<void>.delayed(Duration.zero);
      return container;
    }

    final otherEmployee = Employee(
      username: 'EMP002',
      employeeCode: 'EMP002',
      displayName: 'Other User',
      department: 'Sales',
      jobRole: 'Salesperson',
      isActive: true,
    );

    test('refresh preserves displayed profile while pending and updates on success', () async {
      final container = await authenticatedContainer();
      final response = Completer<Employee>();
      when(() => mockRepository.getCurrentEmployee())
          .thenAnswer((_) => response.future);
      final refresh = container
          .read(authControllerProvider.notifier)
          .refreshProfile();
      expect(
        (container.read(authControllerProvider) as AuthAuthenticated).employee,
        tEmployee,
      );
      response.complete(otherEmployee);
      await refresh;
      expect(
        (container.read(authControllerProvider) as AuthAuthenticated).employee,
        otherEmployee,
      );
    });

    test(
      'recoverable refresh failure preserves profile and credentials',
      () async {
        final container = await authenticatedContainer();
        when(() => mockRepository.getCurrentEmployee())
            .thenThrow(ApiError.networkFailure());
        await expectLater(
          container.read(authControllerProvider.notifier).refreshProfile(),
          throwsA(isA<ApiError>()),
        );
        expect(
          (container.read(
            authControllerProvider,
          ) as AuthAuthenticated).employee,
          tEmployee,
        );
        verifyNever(() => mockRepository.logout());
      },
    );

    test('401 and 403 refresh failures remove authenticated state', () async {
      for (final status in [401, 403]) {
        final container = await authenticatedContainer();
        when(() => mockRepository.getCurrentEmployee())
            .thenThrow(ApiError(message: 'Access denied.', statusCode: status));
        await expectLater(
          container.read(authControllerProvider.notifier).refreshProfile(),
          throwsA(isA<ApiError>()),
        );
        expect(
          container.read(authControllerProvider),
          isA<AuthUnauthenticated>(),
        );
      }
    });

    test(
      'late profile success or failure cannot affect a new account',
      () async {
        for (final fail in [false, true]) {
          final container = await authenticatedContainer();
          final controller = container.read(authControllerProvider.notifier);
          final response = Completer<Employee>();
          when(() => mockRepository.getCurrentEmployee())
              .thenAnswer((_) => response.future);
          final refresh = controller.refreshProfile();
          await controller.logout();
          when(() => mockRepository.login('EMP002', 'password'))
              .thenAnswer((_) async => otherEmployee);
          await controller.login('EMP002', 'password');
          if (fail) {
            response.completeError(
              ApiError(message: 'Old session denied.', statusCode: 401),
            );
          } else {
            response.complete(tEmployee);
          }
          await refresh;
          expect(
            (container.read(
              authControllerProvider,
            ) as AuthAuthenticated).employee,
            otherEmployee,
          );
        }
      },
    );

    test(
      'logout waits for pending credential writes and never restores old login',
      () async {
        when(() => mockRepository.hasStoredCredentials())
            .thenAnswer((_) async => false);
        final container = makeContainer();
        final controller = container.read(authControllerProvider.notifier);
        await Future<void>.delayed(Duration.zero);
        final response = Completer<Employee>();
        when(() => mockRepository.login('EMP001', 'password'))
            .thenAnswer((_) => response.future);
        final login = controller.login('EMP001', 'password');
        await Future<void>.delayed(Duration.zero);
        final logout = controller.logout();
        expect(container.read(authControllerProvider), isA<AuthLoading>());
        verifyNever(() => mockRepository.logout());
        response.complete(tEmployee);
        await Future.wait([login, logout]);
        expect(
          container.read(authControllerProvider),
          isA<AuthUnauthenticated>(),
        );
        verify(() => mockRepository.tokenStorage.clearAuthenticationState())
            .called(1);
      },
    );

    test(
      'delayed failed-login reset cannot sign out a subsequent login',
      () async {
        when(() => mockRepository.hasStoredCredentials())
            .thenAnswer((_) async => false);
        final container = makeContainer();
        final controller = container.read(authControllerProvider.notifier);
        await Future<void>.delayed(Duration.zero);
        when(() => mockRepository.login('EMP001', 'bad'))
            .thenThrow(ApiError.networkFailure());
        await controller.login('EMP001', 'bad');
        when(() => mockRepository.login('EMP002', 'password'))
            .thenAnswer((_) async => otherEmployee);
        await controller.login('EMP002', 'password');
        await Future<void>.delayed(const Duration(milliseconds: 150));
        expect(
          (container.read(
            authControllerProvider,
          ) as AuthAuthenticated).employee,
          otherEmployee,
        );
      },
    );
  });

  group('Credential cleanup failures', () {
    Future<ProviderContainer> authenticatedContainer() async {
      when(() => mockRepository.hasStoredCredentials())
          .thenAnswer((_) async => true);
      when(() => mockRepository.getCurrentEmployee())
          .thenAnswer((_) async => tEmployee);
      final container = makeContainer();
      container.read(authControllerProvider);
      await Future<void>.delayed(Duration.zero);
      when(() => storage.clearAuthenticationState())
          .thenThrow(StateError('Storage unavailable'));
      return container;
    }

    test('logout leaves loading and retry cannot restore undeleted tokens', () async {
      final container = await authenticatedContainer();
      final controller = container.read(authControllerProvider.notifier);
      await controller.logout();
      final state = container.read(authControllerProvider) as AuthError;
      expect(state.error.code, 'credential_cleanup_failed');

      await controller.retryAuthentication();
      expect(container.read(authControllerProvider), isA<AuthUnauthenticated>());
      verify(() => mockRepository.hasStoredCredentials()).called(1);
      verify(() => mockRepository.getCurrentEmployee()).called(1);
      verify(() => mockRepository.logout()).called(1);
      verify(() => storage.clearAuthenticationState()).called(1);

      when(() => mockRepository.login('EMP001', 'new-password'))
          .thenAnswer((_) async => tEmployee);
      await controller.login('EMP001', 'new-password');
      expect(container.read(authControllerProvider), isA<AuthAuthenticated>());
    });

    test('startup 401 with failed cleanup does not loop or restore credentials', () async {
      when(() => mockRepository.hasStoredCredentials())
          .thenAnswer((_) async => true);
      when(() => mockRepository.getCurrentEmployee())
          .thenThrow(ApiError(message: 'Expired', statusCode: 401));
      when(() => mockRepository.logout())
          .thenThrow(StateError('Repository cleanup failed'));
      when(() => storage.clearAuthenticationState())
          .thenThrow(StateError('Storage unavailable'));
      final container = makeContainer();
      final controller = container.read(authControllerProvider.notifier);
      await Future<void>.delayed(Duration.zero);
      expect(container.read(authControllerProvider), isA<AuthError>());

      await controller.retryAuthentication();
      await controller.retryAuthentication();
      expect(container.read(authControllerProvider), isA<AuthUnauthenticated>());
      verify(() => mockRepository.logout()).called(1);
      verify(() => mockRepository.getCurrentEmployee()).called(1);
      verify(() => storage.clearAuthenticationState()).called(1);
    });

    test('profile 401 preserves the rejection and surfaces cleanup failure', () async {
      final container = await authenticatedContainer();
      final error = ApiError(message: 'Expired', statusCode: 401);
      when(() => mockRepository.getCurrentEmployee()).thenThrow(error);
      await expectLater(
        container.read(authControllerProvider.notifier).refreshProfile(),
        throwsA(same(error)),
      );
      expect(container.read(authControllerProvider), isA<AuthError>());
      await container.read(authControllerProvider.notifier).retryAuthentication();
      expect(container.read(authControllerProvider), isA<AuthUnauthenticated>());
    });

    test('late cleanup failure cannot overwrite a queued fresh login', () async {
      final container = await authenticatedContainer();
      final controller = container.read(authControllerProvider.notifier);
      final cleanup = Completer<void>();
      final cleanupStarted = Completer<void>();
      when(() => storage.clearAuthenticationState())
          .thenAnswer((_) async {
            cleanupStarted.complete();
            await cleanup.future;
            throw StateError('Storage unavailable');
          });
      when(() => mockRepository.login('EMP001', 'new-password'))
          .thenAnswer((_) async => tEmployee);
      final logout = controller.logout();
      await cleanupStarted.future;
      final login = controller.login('EMP001', 'new-password');
      cleanup.complete();
      await Future.wait([logout, login]);
      expect(container.read(authControllerProvider), isA<AuthAuthenticated>());
    });
  });

  group('AuthController login/logout', () {
    test('login success sets authenticated state', () async {
      when(() => mockRepository.hasStoredCredentials()).thenAnswer((_) async => false);
      when(() => mockRepository.login('EMP001', 'password')).thenAnswer((_) async => tEmployee);

      final container = makeContainer();
      final controller = container.read(authControllerProvider.notifier);
      await Future.delayed(Duration.zero);

      await controller.login('EMP001', 'password');

      expect(container.read(authControllerProvider), isA<AuthAuthenticated>());
    });

    test('login failure sets error then unauthenticated', () async {
      when(() => mockRepository.hasStoredCredentials()).thenAnswer((_) async => false);
      when(() => mockRepository.login('EMP001', 'password')).thenThrow(ApiError.networkFailure());

      final container = makeContainer();
      final controller = container.read(authControllerProvider.notifier);
      await Future.delayed(Duration.zero);

      await controller.login('EMP001', 'password');
      expect(container.read(authControllerProvider), isA<AuthError>());

      // Wait for the delayed revert
      await Future.delayed(const Duration(milliseconds: 150));
      expect(container.read(authControllerProvider), isA<AuthUnauthenticated>());
    });

    test('logout sets unauthenticated', () async {
      final mockTokenStorage = MockSecureTokenStorage();
      when(() => mockRepository.tokenStorage).thenReturn(mockTokenStorage);
      when(() => mockTokenStorage.clearAuthenticationState()).thenAnswer((_) async {});

      when(() => mockRepository.hasStoredCredentials()).thenAnswer((_) async => false);
      when(() => mockRepository.logout()).thenAnswer((_) async {});

      final container = makeContainer();
      final controller = container.read(authControllerProvider.notifier);
      await Future.delayed(Duration.zero);

      await controller.logout();

      expect(container.read(authControllerProvider), isA<AuthUnauthenticated>());
      verify(() => mockRepository.logout()).called(1);
      verify(() => mockTokenStorage.clearAuthenticationState()).called(1);
    });
  });
}
