import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';
import 'package:training_app/core/errors/api_error.dart';
import 'package:training_app/core/network/dio_client.dart';
import 'package:training_app/core/presentation/components/api_error_view.dart';
import 'package:training_app/core/presentation/components/empty_view.dart';
import 'package:training_app/core/presentation/screens/workspace_screen.dart';
import 'package:training_app/core/router/app_router.dart';
import 'package:training_app/core/theme/app_theme.dart';
import 'package:training_app/features/auth/domain/models/auth_state.dart';
import 'package:training_app/features/auth/presentation/controllers/auth_controller.dart';
import 'package:training_app/features/management/data/repositories/management_repository.dart';
import 'package:training_app/features/management/domain/models/management_models.dart';
import 'package:training_app/features/management/presentation/controllers/management_controller.dart';
import 'package:training_app/features/management/presentation/screens/managed_certificate_detail_screen.dart';
import 'package:training_app/features/management/presentation/screens/managed_certificate_list_screen.dart';
import 'package:training_app/features/notifications/presentation/controllers/notification_controller.dart';

import 'management_fixtures.dart';

class MockManagementRepository extends Mock implements ManagementRepository {}

class MockApiClient extends Mock implements ApiClient {}

class MockDio extends Mock implements Dio {}

class ZeroUnread extends NotificationUnreadController {
  @override
  Future<int?> build() async => 0;
}

Map<String, dynamic> sampleManagedCertificateJson({
  int id = 1,
  String certificateNumber = 'CERT-2026-001',
  String trainingTitle = 'Plant Safety Fundamentals',
  int versionNumber = 1,
  String issuedAt = '2026-02-15T10:00:00Z',
  bool isRevoked = false,
  String employeeName = 'Alice Walker',
  String employeeCode = 'EMP001',
  String? revokedAt,
}) => {
  'id': id,
  'certificate_number': certificateNumber,
  'training_title': trainingTitle,
  'version_number': versionNumber,
  'issued_at': issuedAt,
  'is_revoked': isRevoked,
  'employee_name': employeeName,
  'employee_code': employeeCode,
  'revoked_at': revokedAt,
};

Map<String, dynamic> sampleManagedCertificateDetailJson({
  int id = 1,
  String certificateNumber = 'CERT-2026-001',
  String trainingTitle = 'Plant Safety Fundamentals',
  int versionNumber = 1,
  String issuedAt = '2026-02-15T10:00:00Z',
  bool isRevoked = false,
  String employeeName = 'Alice Walker',
  String employeeCode = 'EMP001',
  String? revokedAt,
  String? revocationReason,
}) => {
  ...sampleManagedCertificateJson(
    id: id,
    certificateNumber: certificateNumber,
    trainingTitle: trainingTitle,
    versionNumber: versionNumber,
    issuedAt: issuedAt,
    isRevoked: isRevoked,
    employeeName: employeeName,
    employeeCode: employeeCode,
    revokedAt: revokedAt,
  ),
  'revocation_reason': revocationReason,
};

void setTestViewport(WidgetTester tester, [Size size = const Size(800, 2400)]) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Domain models fail-closed validation', () {
    test('ManagedCertificate parses valid JSON', () {
      final cert = ManagedCertificate.fromJson(sampleManagedCertificateJson());
      expect(cert.id, 1);
      expect(cert.certificateNumber, 'CERT-2026-001');
      expect(cert.trainingTitle, 'Plant Safety Fundamentals');
      expect(cert.versionNumber, 1);
      expect(cert.isRevoked, isFalse);
      expect(cert.employeeName, 'Alice Walker');
      expect(cert.employeeCode, 'EMP001');
      expect(cert.revokedAt, isNull);
    });

    test('ManagedCertificate parses revoked certificate with revoked_at', () {
      final cert = ManagedCertificate.fromJson(
        sampleManagedCertificateJson(
          isRevoked: true,
          revokedAt: '2026-03-01T12:00:00Z',
        ),
      );
      expect(cert.isRevoked, isTrue);
      expect(cert.revokedAt, isNotNull);
      expect(cert.revokedAt!.year, 2026);
    });

    test('ManagedCertificate throws on non-positive ID', () {
      expect(
        () => ManagedCertificate.fromJson(sampleManagedCertificateJson(id: 0)),
        throwsFormatException,
      );
      expect(
        () => ManagedCertificate.fromJson(sampleManagedCertificateJson(id: -1)),
        throwsFormatException,
      );
    });

    test('ManagedCertificate throws on empty certificate number', () {
      final data = sampleManagedCertificateJson()..['certificate_number'] = '';
      expect(() => ManagedCertificate.fromJson(data), throwsFormatException);
    });

    test('ManagedCertificate throws on invalid version number', () {
      final data = sampleManagedCertificateJson()..['version_number'] = 0;
      expect(() => ManagedCertificate.fromJson(data), throwsFormatException);
    });

    test('ManagedCertificate throws on invalid issued_at timestamp', () {
      final data = sampleManagedCertificateJson()
        ..['issued_at'] = 'invalid-date';
      expect(() => ManagedCertificate.fromJson(data), throwsFormatException);
    });

    test('ManagedCertificate throws on invalid is_revoked type', () {
      final data = sampleManagedCertificateJson()
        ..['is_revoked'] = 'not-a-bool';
      expect(() => ManagedCertificate.fromJson(data), throwsFormatException);
    });

    test('ManagedCertificate throws on invalid revoked_at timestamp', () {
      final data = sampleManagedCertificateJson()
        ..['revoked_at'] = 'invalid-date';
      expect(() => ManagedCertificate.fromJson(data), throwsFormatException);
    });

    test(
      'ManagedCertificateDetail parses valid JSON with revocation_reason',
      () {
        final detail = ManagedCertificateDetail.fromJson(
          sampleManagedCertificateDetailJson(
            isRevoked: true,
            revokedAt: '2026-03-01T12:00:00Z',
            revocationReason: 'Credential expired due to safety rule change.',
          ),
        );
        expect(detail.id, 1);
        expect(detail.isRevoked, isTrue);
        expect(
          detail.revocationReason,
          'Credential expired due to safety rule change.',
        );
      },
    );

    test(
      'ManagedCertificateDetail parses valid JSON with null revocation_reason',
      () {
        final detail = ManagedCertificateDetail.fromJson(
          sampleManagedCertificateDetailJson(),
        );
        expect(detail.revocationReason, isNull);
      },
    );

    test('ManagedCertificateDetail throws on non-string revocation_reason', () {
      final data = sampleManagedCertificateDetailJson()
        ..['revocation_reason'] = 12345;
      expect(
        () => ManagedCertificateDetail.fromJson(data),
        throwsFormatException,
      );
    });

    test('CertificateRevocationResult parses valid JSON', () {
      final result = CertificateRevocationResult.fromJson({
        'id': 1,
        'is_revoked': true,
        'revoked_at': '2026-03-01T14:30:00Z',
      });
      expect(result.id, 1);
      expect(result.isRevoked, isTrue);
      expect(result.revokedAt.year, 2026);
    });

    test('CertificateRevocationResult throws on non-positive ID', () {
      expect(
        () => CertificateRevocationResult.fromJson({
          'id': 0,
          'is_revoked': true,
          'revoked_at': '2026-03-01T14:30:00Z',
        }),
        throwsFormatException,
      );
    });

    test('CertificateRevocationResult throws on invalid date', () {
      expect(
        () => CertificateRevocationResult.fromJson({
          'id': 1,
          'is_revoked': true,
          'revoked_at': 'not-a-date',
        }),
        throwsFormatException,
      );
    });
  });

  group('ManagementRepository certificate operations', () {
    late MockApiClient mockApiClient;
    late MockDio mockDio;
    late ManagementRepository repository;

    setUp(() {
      mockApiClient = MockApiClient();
      mockDio = MockDio();
      when(() => mockApiClient.dio).thenReturn(mockDio);
      repository = ManagementRepository(mockApiClient);
    });

    test(
      'certificates queries /management/certificates/ with query params',
      () async {
        when(
          () => mockDio.get(
            '/management/certificates/',
            queryParameters: any(named: 'queryParameters'),
            cancelToken: any(named: 'cancelToken'),
          ),
        ).thenAnswer(
          (_) async => Response(
            requestOptions: RequestOptions(path: '/management/certificates/'),
            statusCode: 200,
            data: {
              'count': 1,
              'next': null,
              'previous': null,
              'results': [sampleManagedCertificateJson(id: 10)],
            },
          ),
        );

        final result = await repository.certificates(
          page: 2,
          pageSize: 15,
          search: ' Alice ',
          isRevoked: false,
        );

        expect(result.count, 1);
        expect(result.items.first.id, 10);

        verify(
          () => mockDio.get(
            '/management/certificates/',
            queryParameters: {
              'page': 2,
              'page_size': 15,
              'search': 'Alice',
              'is_revoked': false,
            },
            cancelToken: any(named: 'cancelToken'),
          ),
        ).called(1);
      },
    );

    test('certificateDetail queries /management/certificates/:id/ and parses response', () async {
      when(
        () => mockDio.get(
          '/management/certificates/5/',
          queryParameters: any(named: 'queryParameters'),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer(
        (_) async => Response(
          requestOptions: RequestOptions(path: '/management/certificates/5/'),
          statusCode: 200,
          data: sampleManagedCertificateDetailJson(id: 5),
        ),
      );

      final result = await repository.certificateDetail(5);
      expect(result.id, 5);
      expect(result.certificateNumber, 'CERT-2026-001');

      expect(() => repository.certificateDetail(0), throwsArgumentError);
      expect(() => repository.certificateDetail(-1), throwsArgumentError);
    });

    test(
      'revokeCertificate validates id and reason, posts to /revoke/',
      () async {
        when(
          () => mockDio.post(
            '/management/certificates/5/revoke/',
            data: any(named: 'data'),
            cancelToken: any(named: 'cancelToken'),
          ),
        ).thenAnswer(
          (_) async => Response(
            requestOptions: RequestOptions(
              path: '/management/certificates/5/revoke/',
            ),
            statusCode: 200,
            data: {
              'id': 5,
              'is_revoked': true,
              'revoked_at': '2026-03-01T15:00:00Z',
            },
          ),
        );

        final result = await repository.revokeCertificate(
          5,
          ' Safety violation ',
        );
        expect(result.id, 5);
        expect(result.isRevoked, isTrue);

        verify(
          () => mockDio.post(
            '/management/certificates/5/revoke/',
            data: {'reason': 'Safety violation'},
            cancelToken: any(named: 'cancelToken'),
          ),
        ).called(1);

        // Argument validation
        expect(
          () => repository.revokeCertificate(0, 'reason'),
          throwsArgumentError,
        );
        expect(() => repository.revokeCertificate(5, ''), throwsArgumentError);
        expect(
          () => repository.revokeCertificate(5, '   '),
          throwsArgumentError,
        );
        expect(
          () => repository.revokeCertificate(5, 'a' * 1001),
          throwsArgumentError,
        );
      },
    );
  });

  group('Permissions and controller logic', () {
    test('canViewCertificates checks certifications.view_certificate', () {
      final idWithView = managementIdentity(
        capabilities: {
          'management_workspace',
          'certifications.view_certificate',
        },
      );
      final idWithoutView = managementIdentity(
        capabilities: {'management_workspace'},
      );
      expect(canViewCertificates(idWithView), isTrue);
      expect(canViewCertificates(idWithoutView), isFalse);
    });

    test('canRevokeCertificate checks certifications.change_certificate', () {
      final idWithChange = managementIdentity(
        capabilities: {
          'management_workspace',
          'certifications.change_certificate',
        },
      );
      final idWithoutChange = managementIdentity(
        capabilities: {
          'management_workspace',
          'certifications.view_certificate',
        },
      );
      expect(canRevokeCertificate(idWithChange), isTrue);
      expect(canRevokeCertificate(idWithoutChange), isFalse);
    });

    test(
      'canManageCertificates is true if either view or change is present',
      () {
        final viewOnly = managementIdentity(
          capabilities: {'certifications.view_certificate'},
        );
        final changeOnly = managementIdentity(
          capabilities: {'certifications.change_certificate'},
        );
        final neither = managementIdentity(capabilities: {});
        expect(canManageCertificates(viewOnly), isTrue);
        expect(canManageCertificates(changeOnly), isTrue);
        expect(canManageCertificates(neither), isFalse);
      },
    );

    test('CertificateRevocationMutationController enforces permissions and reason constraints', () async {
      final mockRepo = MockManagementRepository();
      AuthState authState = AuthAuthenticated.identity(
        managementIdentity(capabilities: {'management_workspace'}),
      );

      final controller = CertificateRevocationMutationController(
        repository: mockRepo,
        readAuth: () => authState,
      );

      // Fails when user lacks change permission
      expect(
        () => controller.revoke(certificateId: 1, reason: 'Test reason'),
        throwsA(isA<ApiError>().having((e) => e.statusCode, 'statusCode', 403)),
      );

      // Now grant change permission
      authState = AuthAuthenticated.identity(
        managementIdentity(
          capabilities: {
            'management_workspace',
            'certifications.change_certificate',
          },
        ),
      );

      // Fails on empty reason
      expect(
        () => controller.revoke(certificateId: 1, reason: '  '),
        throwsA(isA<ApiError>().having((e) => e.statusCode, 'statusCode', 400)),
      );

      // Fails on reason > 1000 chars
      expect(
        () => controller.revoke(certificateId: 1, reason: 'a' * 1001),
        throwsA(isA<ApiError>().having((e) => e.statusCode, 'statusCode', 400)),
      );

      // Succeeds with valid input
      when(
        () => mockRepo.revokeCertificate(
          1,
          any(),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer(
        (_) async => CertificateRevocationResult(
          id: 1,
          isRevoked: true,
          revokedAt: DateTime.now(),
        ),
      );

      final res = await controller.revoke(
        certificateId: 1,
        reason: 'Valid reason',
      );
      expect(res.id, 1);
      expect(res.isRevoked, isTrue);
    });

    test('CertificateRevocationMutationController fails closed if account changes mid-flight', () async {
      final mockRepo = MockManagementRepository();
      AuthState currentAuth = AuthAuthenticated.identity(
        managementIdentity(
          username: 'user_a',
          capabilities: {
            'management_workspace',
            'certifications.change_certificate',
          },
        ),
      );

      final controller = CertificateRevocationMutationController(
        repository: mockRepo,
        readAuth: () => currentAuth,
      );

      when(
        () => mockRepo.revokeCertificate(
          1,
          any(),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer((_) async {
        // Switch account while repository call is executing
        currentAuth = AuthAuthenticated.identity(
          managementIdentity(
            username: 'user_b',
            capabilities: {
              'management_workspace',
              'certifications.change_certificate',
            },
          ),
        );
        return CertificateRevocationResult(
          id: 1,
          isRevoked: true,
          revokedAt: DateTime.now(),
        );
      });

      expect(
        () => controller.revoke(certificateId: 1, reason: 'Valid reason'),
        throwsA(isA<ApiError>().having((e) => e.statusCode, 'statusCode', 403)),
      );
    });
  });

  group('WorkspaceScreen navigation card', () {
    late ManagementTestAuth auth;

    testWidgets(
      'shows Certificates card when user has certifications.view_certificate',
      (tester) async {
        setTestViewport(tester);
        auth = ManagementTestAuth(
          managementIdentity(
            capabilities: {
              'management_workspace',
              'certifications.view_certificate',
            },
          ),
        );

        await tester.pumpWidget(
          ProviderScope(
            overrides: [authControllerProvider.overrideWith(() => auth)],
            child: const MaterialApp(home: WorkspaceScreen()),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('Certificates'), findsOneWidget);
        expect(
          find.text('Company-wide issued and revoked certificates.'),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'hides Certificates card when user lacks certifications.view_certificate',
      (tester) async {
        setTestViewport(tester);
        auth = ManagementTestAuth(
          managementIdentity(
            capabilities: {
              'management_workspace',
              // change only or none
              'certifications.change_certificate',
            },
          ),
        );

        await tester.pumpWidget(
          ProviderScope(
            overrides: [authControllerProvider.overrideWith(() => auth)],
            child: const MaterialApp(home: WorkspaceScreen()),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('Certificates'), findsNothing);
      },
    );
  });

  group('Router guards for certificate management', () {
    late MockManagementRepository repository;
    late ManagementTestAuth auth;
    late GoRouter router;

    setUp(() {
      repository = MockManagementRepository();
      when(
        () => repository.certificates(
          page: any(named: 'page'),
          pageSize: any(named: 'pageSize'),
          search: any(named: 'search'),
          isRevoked: any(named: 'isRevoked'),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer(
        (_) async => ManagementPage<ManagedCertificate>(
          count: 0,
          hasMore: false,
          items: [],
        ),
      );
      when(
        () => repository.certificateDetail(
          any(),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer(
        (_) async => ManagedCertificateDetail.fromJson(
          sampleManagedCertificateDetailJson(id: 1),
        ),
      );
    });

    testWidgets(
      'permits /workspace/certificates when user has view_certificate',
      (tester) async {
        setTestViewport(tester);
        auth = ManagementTestAuth(
          managementIdentity(
            capabilities: {
              'management_workspace',
              'certifications.view_certificate',
            },
          ),
        );

        final container = ProviderContainer(
          overrides: [
            authControllerProvider.overrideWith(() => auth),
            managementRepositoryProvider.overrideWithValue(repository),
            notificationUnreadCountProvider.overrideWith(ZeroUnread.new),
          ],
        );
        addTearDown(container.dispose);

        router = container.read(appRouterProvider);
        router.go('/workspace/certificates');

        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp.router(
              routerConfig: router,
              theme: AppTheme.lightTheme,
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('Certificate management'), findsOneWidget);
      },
    );

    testWidgets(
      'redirects /workspace/certificates to homePath when user lacks view_certificate',
      (tester) async {
        setTestViewport(tester);
        // Ordinary employee or manager without certifications.view_certificate
        auth = ManagementTestAuth(
          managementIdentity(
            team: true,
            capabilities: {'personal_learning', 'team_workspace'},
          ),
        );

        final container = ProviderContainer(
          overrides: [
            authControllerProvider.overrideWith(() => auth),
            managementRepositoryProvider.overrideWithValue(repository),
            notificationUnreadCountProvider.overrideWith(ZeroUnread.new),
          ],
        );
        addTearDown(container.dispose);

        router = container.read(appRouterProvider);
        router.go('/workspace/certificates');

        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp.router(
              routerConfig: router,
              theme: AppTheme.lightTheme,
            ),
          ),
        );
        await tester.pumpAndSettle();

        // Redirected to learner home (/dashboard)
        expect(find.text('Certificate management'), findsNothing);
      },
    );

    testWidgets('change-only user is blocked from /workspace/certificates', (
      tester,
    ) async {
      setTestViewport(tester);
      auth = ManagementTestAuth(
        managementIdentity(
          capabilities: {
            'management_workspace',
            'certifications.change_certificate', // change without view
          },
        ),
      );

      final container = ProviderContainer(
        overrides: [
          authControllerProvider.overrideWith(() => auth),
          managementRepositoryProvider.overrideWithValue(repository),
          notificationUnreadCountProvider.overrideWith(ZeroUnread.new),
        ],
      );
      addTearDown(container.dispose);

      router = container.read(appRouterProvider);
      router.go('/workspace/certificates');

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp.router(
            routerConfig: router,
            theme: AppTheme.lightTheme,
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Redirected to /workspace since user has management_workspace
      expect(find.text('Certificate management'), findsNothing);
      expect(find.text('Account access'), findsOneWidget);
    });

    testWidgets(
      'permits /workspace/certificates/1 when user has view_certificate',
      (tester) async {
        setTestViewport(tester);
        auth = ManagementTestAuth(
          managementIdentity(
            capabilities: {
              'management_workspace',
              'certifications.view_certificate',
            },
          ),
        );

        final container = ProviderContainer(
          overrides: [
            authControllerProvider.overrideWith(() => auth),
            managementRepositoryProvider.overrideWithValue(repository),
            notificationUnreadCountProvider.overrideWith(ZeroUnread.new),
          ],
        );
        addTearDown(container.dispose);

        router = container.read(appRouterProvider);
        router.go('/workspace/certificates/1');

        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp.router(
              routerConfig: router,
              theme: AppTheme.lightTheme,
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('Certificate details'), findsOneWidget);
        expect(find.text('CERT-2026-001'), findsOneWidget);
      },
    );
  });

  group('ManagedCertificateListScreen widgets and interaction', () {
    late MockManagementRepository repository;
    late ManagementTestAuth auth;

    setUp(() {
      repository = MockManagementRepository();
      auth = ManagementTestAuth(
        managementIdentity(
          capabilities: {
            'management_workspace',
            'certifications.view_certificate',
            'certifications.change_certificate',
          },
        ),
      );
    });

    testWidgets('renders list with valid and revoked certificates and badges', (
      tester,
    ) async {
      setTestViewport(tester);
      when(
        () => repository.certificates(
          page: any(named: 'page'),
          pageSize: any(named: 'pageSize'),
          search: any(named: 'search'),
          isRevoked: any(named: 'isRevoked'),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer(
        (_) async => ManagementPage<ManagedCertificate>(
          count: 2,
          hasMore: false,
          items: [
            ManagedCertificate.fromJson(
              sampleManagedCertificateJson(
                id: 1,
                certificateNumber: 'CERT-001',
                employeeName: 'Alice Walker',
                employeeCode: 'EMP001',
                trainingTitle: 'Safety 101',
                versionNumber: 2,
                isRevoked: false,
              ),
            ),
            ManagedCertificate.fromJson(
              sampleManagedCertificateJson(
                id: 2,
                certificateNumber: 'CERT-002',
                employeeName: 'Bob Smith',
                employeeCode: 'EMP002',
                trainingTitle: 'Machinery 201',
                versionNumber: 1,
                isRevoked: true,
                revokedAt: '2026-03-01T10:00:00Z',
              ),
            ),
          ],
        ),
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            authControllerProvider.overrideWith(() => auth),
            managementRepositoryProvider.overrideWithValue(repository),
          ],
          child: const MaterialApp(home: ManagedCertificateListScreen()),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('CERT-001'), findsOneWidget);
      expect(find.text('Alice Walker (EMP001)'), findsOneWidget);
      expect(find.text('Safety 101 · v2'), findsOneWidget);
      expect(find.text('Valid'), findsOneWidget);

      expect(find.text('CERT-002'), findsOneWidget);
      expect(find.text('Bob Smith (EMP002)'), findsOneWidget);
      expect(find.text('Machinery 201 · v1'), findsOneWidget);
      expect(find.text('Revoked'), findsOneWidget);
      expect(find.text('Page 1 · 2 total'), findsOneWidget);
    });

    testWidgets('filter chips filter by Valid and Revoked', (tester) async {
      setTestViewport(tester);
      when(
        () => repository.certificates(
          page: any(named: 'page'),
          pageSize: any(named: 'pageSize'),
          search: any(named: 'search'),
          isRevoked: any(named: 'isRevoked'),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer(
        (_) async => ManagementPage<ManagedCertificate>(
          count: 1,
          hasMore: false,
          items: [ManagedCertificate.fromJson(sampleManagedCertificateJson())],
        ),
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            authControllerProvider.overrideWith(() => auth),
            managementRepositoryProvider.overrideWithValue(repository),
          ],
          child: const MaterialApp(home: ManagedCertificateListScreen()),
        ),
      );
      await tester.pumpAndSettle();

      // Tap 'Valid' filter
      await tester.tap(find.text('Valid'));
      await tester.pumpAndSettle();

      verify(
        () => repository.certificates(
          page: 1,
          pageSize: any(named: 'pageSize'),
          search: any(named: 'search'),
          isRevoked: false,
          cancelToken: any(named: 'cancelToken'),
        ),
      ).called(1);

      // Tap 'Revoked' filter
      await tester.tap(find.text('Revoked'));
      await tester.pumpAndSettle();

      verify(
        () => repository.certificates(
          page: 1,
          pageSize: any(named: 'pageSize'),
          search: any(named: 'search'),
          isRevoked: true,
          cancelToken: any(named: 'cancelToken'),
        ),
      ).called(1);
    });

    testWidgets(
      'search text field triggers search re-query and clear button resets',
      (tester) async {
        setTestViewport(tester);
        when(
          () => repository.certificates(
            page: any(named: 'page'),
            pageSize: any(named: 'pageSize'),
            search: any(named: 'search'),
            isRevoked: any(named: 'isRevoked'),
            cancelToken: any(named: 'cancelToken'),
          ),
        ).thenAnswer(
          (_) async => ManagementPage<ManagedCertificate>(
            count: 0,
            hasMore: false,
            items: [],
          ),
        );

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              authControllerProvider.overrideWith(() => auth),
              managementRepositoryProvider.overrideWithValue(repository),
            ],
            child: const MaterialApp(home: ManagedCertificateListScreen()),
          ),
        );
        await tester.pumpAndSettle();

        // Enter search term
        await tester.enterText(find.byType(TextField), 'Alice');
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await tester.pumpAndSettle();

        verify(
          () => repository.certificates(
            page: 1,
            pageSize: any(named: 'pageSize'),
            search: 'Alice',
            isRevoked: any(named: 'isRevoked'),
            cancelToken: any(named: 'cancelToken'),
          ),
        ).called(1);

        // Reset mock before testing clear action
        reset(repository);
        when(
          () => repository.certificates(
            page: any(named: 'page'),
            pageSize: any(named: 'pageSize'),
            search: any(named: 'search'),
            isRevoked: any(named: 'isRevoked'),
            cancelToken: any(named: 'cancelToken'),
          ),
        ).thenAnswer(
          (_) async => ManagementPage<ManagedCertificate>(
            count: 0,
            hasMore: false,
            items: [],
          ),
        );

        // Tap clear icon
        await tester.tap(find.byIcon(Icons.clear));
        await tester.pumpAndSettle();

        verify(
          () => repository.certificates(
            page: 1,
            pageSize: any(named: 'pageSize'),
            search: null,
            isRevoked: any(named: 'isRevoked'),
            cancelToken: any(named: 'cancelToken'),
          ),
        ).called(1);
      },
    );

    testWidgets('shows EmptyView when no certificates found', (tester) async {
      setTestViewport(tester);
      when(
        () => repository.certificates(
          page: any(named: 'page'),
          pageSize: any(named: 'pageSize'),
          search: any(named: 'search'),
          isRevoked: any(named: 'isRevoked'),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer(
        (_) async => ManagementPage<ManagedCertificate>(
          count: 0,
          hasMore: false,
          items: [],
        ),
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            authControllerProvider.overrideWith(() => auth),
            managementRepositoryProvider.overrideWithValue(repository),
          ],
          child: const MaterialApp(home: ManagedCertificateListScreen()),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(EmptyView), findsOneWidget);
      expect(find.text('No certificates found.'), findsOneWidget);
    });

    testWidgets('shows ApiErrorView on error and retries on button press', (
      tester,
    ) async {
      setTestViewport(tester);
      when(
        () => repository.certificates(
          page: any(named: 'page'),
          pageSize: any(named: 'pageSize'),
          search: any(named: 'search'),
          isRevoked: any(named: 'isRevoked'),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenThrow(ApiError.networkFailure());

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            authControllerProvider.overrideWith(() => auth),
            managementRepositoryProvider.overrideWithValue(repository),
          ],
          child: const MaterialApp(home: ManagedCertificateListScreen()),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(ApiErrorView), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);

      // Now set mock to succeed
      when(
        () => repository.certificates(
          page: any(named: 'page'),
          pageSize: any(named: 'pageSize'),
          search: any(named: 'search'),
          isRevoked: any(named: 'isRevoked'),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer(
        (_) async => ManagementPage<ManagedCertificate>(
          count: 1,
          hasMore: false,
          items: [ManagedCertificate.fromJson(sampleManagedCertificateJson())],
        ),
      );

      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();

      expect(find.byType(ApiErrorView), findsNothing);
      expect(find.text('CERT-2026-001'), findsOneWidget);
    });

    testWidgets(
      'pagination: next button increments page and previous decrements',
      (tester) async {
        setTestViewport(tester);
        when(
          () => repository.certificates(
            page: 1,
            pageSize: any(named: 'pageSize'),
            search: any(named: 'search'),
            isRevoked: any(named: 'isRevoked'),
            cancelToken: any(named: 'cancelToken'),
          ),
        ).thenAnswer(
          (_) async => ManagementPage<ManagedCertificate>(
            count: 25,
            hasMore: true,
            items: [
              ManagedCertificate.fromJson(sampleManagedCertificateJson(id: 1)),
            ],
          ),
        );

        when(
          () => repository.certificates(
            page: 2,
            pageSize: any(named: 'pageSize'),
            search: any(named: 'search'),
            isRevoked: any(named: 'isRevoked'),
            cancelToken: any(named: 'cancelToken'),
          ),
        ).thenAnswer(
          (_) async => ManagementPage<ManagedCertificate>(
            count: 25,
            hasMore: false,
            items: [
              ManagedCertificate.fromJson(sampleManagedCertificateJson(id: 2)),
            ],
          ),
        );

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              authControllerProvider.overrideWith(() => auth),
              managementRepositoryProvider.overrideWithValue(repository),
            ],
            child: const MaterialApp(home: ManagedCertificateListScreen()),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('Page 1 · 25 total'), findsOneWidget);

        // Previous button should be disabled
        final prevBtn = tester.widget<TextButton>(
          find.widgetWithText(TextButton, 'Previous'),
        );
        expect(prevBtn.onPressed, isNull);

        // Tap Next
        await tester.tap(find.widgetWithText(TextButton, 'Next'));
        await tester.pumpAndSettle();

        expect(find.text('Page 2 · 25 total'), findsOneWidget);

        // Next button should now be disabled
        final nextBtn = tester.widget<TextButton>(
          find.widgetWithText(TextButton, 'Next'),
        );
        expect(nextBtn.onPressed, isNull);
      },
    );

    testWidgets(
      'responsive pagination does not overflow at 320px width with 200% text scale',
      (tester) async {
        setTestViewport(tester, const Size(320, 2400));
        when(
          () => repository.certificates(
            page: any(named: 'page'),
            pageSize: any(named: 'pageSize'),
            search: any(named: 'search'),
            isRevoked: any(named: 'isRevoked'),
            cancelToken: any(named: 'cancelToken'),
          ),
        ).thenAnswer(
          (_) async => ManagementPage<ManagedCertificate>(
            count: 25,
            hasMore: true,
            items: [
              ManagedCertificate.fromJson(sampleManagedCertificateJson(id: 1)),
            ],
          ),
        );

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              authControllerProvider.overrideWith(() => auth),
              managementRepositoryProvider.overrideWithValue(repository),
            ],
            child: MaterialApp(
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: const TextScaler.linear(2.0)),
                child: child!,
              ),
              home: const ManagedCertificateListScreen(),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);
        expect(find.text('Page 1 · 25 total'), findsOneWidget);
        expect(find.widgetWithText(TextButton, 'Previous'), findsOneWidget);
        expect(find.widgetWithText(TextButton, 'Next'), findsOneWidget);
      },
    );

    testWidgets(
      'recovers to previous valid page when Page 2 is empty after revocation',
      (tester) async {
        setTestViewport(tester);
        // Initial Page 1
        when(
          () => repository.certificates(
            page: 1,
            pageSize: any(named: 'pageSize'),
            search: any(named: 'search'),
            isRevoked: any(named: 'isRevoked'),
            cancelToken: any(named: 'cancelToken'),
          ),
        ).thenAnswer(
          (_) async => ManagementPage<ManagedCertificate>(
            count: 21,
            hasMore: true,
            items: [
              ManagedCertificate.fromJson(sampleManagedCertificateJson(id: 1)),
            ],
          ),
        );

        // Page 2 initial
        when(
          () => repository.certificates(
            page: 2,
            pageSize: any(named: 'pageSize'),
            search: any(named: 'search'),
            isRevoked: any(named: 'isRevoked'),
            cancelToken: any(named: 'cancelToken'),
          ),
        ).thenAnswer(
          (_) async => ManagementPage<ManagedCertificate>(
            count: 21,
            hasMore: false,
            items: [
              ManagedCertificate.fromJson(sampleManagedCertificateJson(id: 21)),
            ],
          ),
        );

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              authControllerProvider.overrideWith(() => auth),
              managementRepositoryProvider.overrideWithValue(repository),
            ],
            child: const MaterialApp(home: ManagedCertificateListScreen()),
          ),
        );
        await tester.pumpAndSettle();

        // Navigate to page 2
        await tester.tap(find.widgetWithText(TextButton, 'Next'));
        await tester.pumpAndSettle();
        expect(find.text('Page 2 · 21 total'), findsOneWidget);

        // Page 2 re-fetch returns empty items with count 20
        when(
          () => repository.certificates(
            page: 2,
            pageSize: any(named: 'pageSize'),
            search: any(named: 'search'),
            isRevoked: any(named: 'isRevoked'),
            cancelToken: any(named: 'cancelToken'),
          ),
        ).thenAnswer(
          (_) async => ManagementPage<ManagedCertificate>(
            count: 20,
            hasMore: false,
            items: [],
          ),
        );

        // Page 1 returns remaining 20 items
        when(
          () => repository.certificates(
            page: 1,
            pageSize: any(named: 'pageSize'),
            search: any(named: 'search'),
            isRevoked: any(named: 'isRevoked'),
            cancelToken: any(named: 'cancelToken'),
          ),
        ).thenAnswer(
          (_) async => ManagementPage<ManagedCertificate>(
            count: 20,
            hasMore: false,
            items: [
              ManagedCertificate.fromJson(sampleManagedCertificateJson(id: 1)),
            ],
          ),
        );

        // Refresh/invalidate
        await tester.tap(find.byTooltip('Refresh'));
        await tester.pump();
        await tester.pump();
        await tester.pumpAndSettle();

        expect(find.text('Page 1 · 20 total'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('recovers to previous valid page when Page 2 returns 404', (
      tester,
    ) async {
      setTestViewport(tester);
      when(
        () => repository.certificates(
          page: 1,
          pageSize: any(named: 'pageSize'),
          search: any(named: 'search'),
          isRevoked: any(named: 'isRevoked'),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer(
        (_) async => ManagementPage<ManagedCertificate>(
          count: 21,
          hasMore: true,
          items: [
            ManagedCertificate.fromJson(sampleManagedCertificateJson(id: 1)),
          ],
        ),
      );

      // Page 2 throws 404
      when(
        () => repository.certificates(
          page: 2,
          pageSize: any(named: 'pageSize'),
          search: any(named: 'search'),
          isRevoked: any(named: 'isRevoked'),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenThrow(ApiError(statusCode: 404, message: 'Invalid page.'));

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            authControllerProvider.overrideWith(() => auth),
            managementRepositoryProvider.overrideWithValue(repository),
          ],
          child: const MaterialApp(home: ManagedCertificateListScreen()),
        ),
      );
      await tester.pumpAndSettle();

      // Tap Next to go to Page 2
      await tester.tap(find.widgetWithText(TextButton, 'Next'));
      await tester.pump();
      await tester.pumpAndSettle();

      expect(find.text('Page 1 · 21 total'), findsOneWidget);
      expect(find.byType(ApiErrorView), findsNothing);
    });
  });

  group('ManagedCertificateDetailScreen widgets and revocation workflow', () {
    late MockManagementRepository repository;
    late ManagementTestAuth auth;

    setUp(() {
      repository = MockManagementRepository();
      auth = ManagementTestAuth(
        managementIdentity(
          capabilities: {
            'management_workspace',
            'certifications.view_certificate',
            'certifications.change_certificate',
          },
        ),
      );
    });

    testWidgets('renders full certificate details and valid notice', (
      tester,
    ) async {
      setTestViewport(tester);
      when(
        () => repository.certificateDetail(
          1,
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer(
        (_) async => ManagedCertificateDetail.fromJson(
          sampleManagedCertificateDetailJson(
            id: 1,
            certificateNumber: 'CERT-999',
            employeeName: 'Sarah Connor',
            employeeCode: 'EMP777',
            trainingTitle: 'Cyber Security',
            versionNumber: 3,
            issuedAt: '2026-01-10T10:00:00Z',
            isRevoked: false,
          ),
        ),
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            authControllerProvider.overrideWith(() => auth),
            managementRepositoryProvider.overrideWithValue(repository),
          ],
          child: const MaterialApp(
            home: ManagedCertificateDetailScreen(certificateId: 1),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('CERT-999'), findsOneWidget);
      expect(find.text('Sarah Connor'), findsOneWidget);
      expect(find.text('EMP777'), findsOneWidget);
      expect(find.text('Cyber Security'), findsOneWidget);
      expect(find.text('Version 3'), findsOneWidget);
      expect(find.text('VALID'), findsOneWidget);
      expect(find.text('Revoke certificate'), findsOneWidget);
    });

    testWidgets(
      'revoked certificate shows revoked date and reason, hides revoke button',
      (tester) async {
        setTestViewport(tester);
        when(
          () => repository.certificateDetail(
            2,
            cancelToken: any(named: 'cancelToken'),
          ),
        ).thenAnswer(
          (_) async => ManagedCertificateDetail.fromJson(
            sampleManagedCertificateDetailJson(
              id: 2,
              isRevoked: true,
              revokedAt: '2026-03-02T12:00:00Z',
              revocationReason: 'Safety certification was falsified.',
            ),
          ),
        );

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              authControllerProvider.overrideWith(() => auth),
              managementRepositoryProvider.overrideWithValue(repository),
            ],
            child: const MaterialApp(
              home: ManagedCertificateDetailScreen(certificateId: 2),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('REVOKED'), findsOneWidget);
        expect(
          find.text('Safety certification was falsified.'),
          findsOneWidget,
        );
        expect(find.text('Revoke certificate'), findsNothing);
      },
    );

    testWidgets('view-only user cannot see Revoke certificate button', (
      tester,
    ) async {
      setTestViewport(tester);
      auth = ManagementTestAuth(
        managementIdentity(
          capabilities: {
            'management_workspace',
            'certifications.view_certificate',
            // NO change_certificate
          },
        ),
      );

      when(
        () => repository.certificateDetail(
          1,
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer(
        (_) async => ManagedCertificateDetail.fromJson(
          sampleManagedCertificateDetailJson(id: 1, isRevoked: false),
        ),
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            authControllerProvider.overrideWith(() => auth),
            managementRepositoryProvider.overrideWithValue(repository),
          ],
          child: const MaterialApp(
            home: ManagedCertificateDetailScreen(certificateId: 1),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('VALID'), findsOneWidget);
      expect(find.text('Revoke certificate'), findsNothing);
    });

    testWidgets(
      'revocation dialog validates required reason, submits successfully, and updates UI to REVOKED',
      (tester) async {
        setTestViewport(tester);
        var detailFetchCount = 0;
        when(
          () => repository.certificateDetail(
            1,
            cancelToken: any(named: 'cancelToken'),
          ),
        ).thenAnswer((_) async {
          detailFetchCount++;
          if (detailFetchCount == 1) {
            return ManagedCertificateDetail.fromJson(
              sampleManagedCertificateDetailJson(id: 1, isRevoked: false),
            );
          }
          return ManagedCertificateDetail.fromJson(
            sampleManagedCertificateDetailJson(
              id: 1,
              isRevoked: true,
              revokedAt: '2026-03-02T12:00:00Z',
              revocationReason:
                  'Employee left company and credential is cancelled.',
            ),
          );
        });

        when(
          () => repository.revokeCertificate(
            1,
            any(),
            cancelToken: any(named: 'cancelToken'),
          ),
        ).thenAnswer(
          (_) async => CertificateRevocationResult(
            id: 1,
            isRevoked: true,
            revokedAt: DateTime.parse('2026-03-02T12:00:00Z'),
          ),
        );

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              authControllerProvider.overrideWith(() => auth),
              managementRepositoryProvider.overrideWithValue(repository),
            ],
            child: const MaterialApp(
              home: ManagedCertificateDetailScreen(certificateId: 1),
            ),
          ),
        );
        await tester.pumpAndSettle();

        // Initial state
        expect(find.text('VALID'), findsOneWidget);
        expect(find.text('Revoke certificate'), findsOneWidget);

        // Tap Revoke certificate
        await tester.tap(find.text('Revoke certificate'));
        await tester.pumpAndSettle();

        // Dialog is open
        expect(find.text('Confirm Revocation'), findsOneWidget);

        // Attempt submit without reason -> validation error
        await tester.tap(find.text('Confirm Revocation'));
        await tester.pumpAndSettle();
        expect(find.text('A revocation reason is required.'), findsOneWidget);

        // Fill in reason
        await tester.enterText(
          find.widgetWithText(TextFormField, 'Revocation reason *'),
          'Employee left company and credential is cancelled.',
        );
        await tester.pumpAndSettle();

        // Submit
        await tester.tap(find.text('Confirm Revocation'));
        await tester.pumpAndSettle();

        verify(
          () => repository.revokeCertificate(
            1,
            'Employee left company and credential is cancelled.',
            cancelToken: any(named: 'cancelToken'),
          ),
        ).called(1);

        expect(find.text('Certificate revoked successfully.'), findsOneWidget);

        // Post-revocation UI update assertions (Finding 5)
        expect(find.text('REVOKED'), findsOneWidget);
        expect(find.text('VALID'), findsNothing);
        expect(
          find.text('Employee left company and credential is cancelled.'),
          findsOneWidget,
        );
        expect(find.text('Revoke certificate'), findsNothing);
      },
    );

    testWidgets(
      'Finding 1: PopScope prevents dismissal while revocation is in-flight',
      (tester) async {
        setTestViewport(tester);
        final completer = Completer<CertificateRevocationResult>();

        when(
          () => repository.certificateDetail(
            1,
            cancelToken: any(named: 'cancelToken'),
          ),
        ).thenAnswer(
          (_) async => ManagedCertificateDetail.fromJson(
            sampleManagedCertificateDetailJson(id: 1, isRevoked: false),
          ),
        );

        when(
          () => repository.revokeCertificate(
            1,
            any(),
            cancelToken: any(named: 'cancelToken'),
          ),
        ).thenAnswer((_) => completer.future);

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              authControllerProvider.overrideWith(() => auth),
              managementRepositoryProvider.overrideWithValue(repository),
            ],
            child: const MaterialApp(
              home: ManagedCertificateDetailScreen(certificateId: 1),
            ),
          ),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.text('Revoke certificate'));
        await tester.pumpAndSettle();

        // Before submit, canPop is true
        var popScope = tester.widget<PopScope>(find.byType(PopScope));
        expect(popScope.canPop, isTrue);

        await tester.enterText(
          find.widgetWithText(TextFormField, 'Revocation reason *'),
          'In-flight revocation check',
        );
        await tester.pumpAndSettle();

        await tester.tap(find.text('Confirm Revocation'));
        await tester.pump(); // starts async call, sets _isRevoking = true

        // During in-flight request, canPop must be false
        popScope = tester.widget<PopScope>(find.byType(PopScope));
        expect(popScope.canPop, isFalse);
        expect(find.byType(CircularProgressIndicator), findsOneWidget);

        // Complete the in-flight request
        completer.complete(
          CertificateRevocationResult(
            id: 1,
            isRevoked: true,
            revokedAt: DateTime.now(),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.byType(AlertDialog), findsNothing);
        expect(find.text('Certificate revoked successfully.'), findsOneWidget);
      },
    );

    testWidgets(
      'Test A: HTTP 409 already revoked by another administrator refreshes detail, shows REVOKED, removes revoke button and shows reason',
      (tester) async {
        setTestViewport(tester);
        var detailFetchCount = 0;
        when(
          () => repository.certificateDetail(
            1,
            cancelToken: any(named: 'cancelToken'),
          ),
        ).thenAnswer((_) async {
          detailFetchCount++;
          if (detailFetchCount == 1) {
            return ManagedCertificateDetail.fromJson(
              sampleManagedCertificateDetailJson(id: 1, isRevoked: false),
            );
          }
          return ManagedCertificateDetail.fromJson(
            sampleManagedCertificateDetailJson(
              id: 1,
              isRevoked: true,
              revokedAt: '2026-03-05T14:30:00Z',
              revocationReason: 'Revoked by admin Sarah for compliance.',
            ),
          );
        });

        when(
          () => repository.revokeCertificate(
            1,
            any(),
            cancelToken: any(named: 'cancelToken'),
          ),
        ).thenThrow(
          ApiError(
            statusCode: 409,
            message: 'This certificate has already been revoked by another administrator.',
          ),
        );

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              authControllerProvider.overrideWith(() => auth),
              managementRepositoryProvider.overrideWithValue(repository),
            ],
            child: const MaterialApp(
              home: ManagedCertificateDetailScreen(certificateId: 1),
            ),
          ),
        );
        await tester.pumpAndSettle();

        // Initially VALID with Revoke button
        expect(find.text('VALID'), findsOneWidget);
        expect(find.text('Revoke certificate'), findsOneWidget);

        await tester.tap(find.text('Revoke certificate'));
        await tester.pumpAndSettle();

        await tester.enterText(
          find.widgetWithText(TextFormField, 'Revocation reason *'),
          'Revocation attempt after Sarah already revoked',
        );
        await tester.pumpAndSettle();

        await tester.tap(find.text('Confirm Revocation'));
        await tester.pumpAndSettle();

        // Detail provider was refreshed (detailFetchCount == 2)
        expect(detailFetchCount, 2);

        // Dialog was safely resolved
        expect(find.byType(AlertDialog), findsNothing);

        // Detail screen shows REVOKED and removes Revoke button
        expect(find.text('REVOKED'), findsOneWidget);
        expect(find.text('VALID'), findsNothing);
        expect(find.text('Revoke certificate'), findsNothing);

        // Authoritative revocation reason and date are displayed
        expect(
          find.text('Revoked by admin Sarah for compliance.'),
          findsOneWidget,
        );

        // Explains that certificate was already revoked without false success message
        expect(
          find.text(
            'This certificate has already been revoked by another administrator.',
          ),
          findsOneWidget,
        );
        expect(find.text('Certificate revoked successfully.'), findsNothing);
      },
    );

    testWidgets(
      'Test B: HTTP 409 locking conflict when certificate is still valid preserves VALID and keeps accessible conflict error in dialog',
      (tester) async {
        setTestViewport(tester);
        var detailFetchCount = 0;
        when(
          () => repository.certificateDetail(
            1,
            cancelToken: any(named: 'cancelToken'),
          ),
        ).thenAnswer((_) async {
          detailFetchCount++;
          // Even on second fetch, certificate remains valid (concurrency/locking conflict)
          return ManagedCertificateDetail.fromJson(
            sampleManagedCertificateDetailJson(id: 1, isRevoked: false),
          );
        });

        when(
          () => repository.revokeCertificate(
            1,
            any(),
            cancelToken: any(named: 'cancelToken'),
          ),
        ).thenThrow(
          ApiError(
            statusCode: 409,
            message: 'Certificate is currently locked by another operation. Please retry.',
          ),
        );

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              authControllerProvider.overrideWith(() => auth),
              managementRepositoryProvider.overrideWithValue(repository),
            ],
            child: const MaterialApp(
              home: ManagedCertificateDetailScreen(certificateId: 1),
            ),
          ),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.text('Revoke certificate'));
        await tester.pumpAndSettle();

        await tester.enterText(
          find.widgetWithText(TextFormField, 'Revocation reason *'),
          'Revocation during concurrent lock',
        );
        await tester.pumpAndSettle();

        await tester.tap(find.text('Confirm Revocation'));
        await tester.pumpAndSettle();

        // Refreshed detail provider was called
        expect(detailFetchCount, 2);

        // Dialog remains open for retry
        expect(find.byType(AlertDialog), findsOneWidget);
        expect(find.text('Confirm Revocation'), findsOneWidget);

        // Accessible conflict explanation inside dialog
        expect(
          find.text(
            'Certificate is currently locked by another operation. Please retry.',
          ),
          findsOneWidget,
        );
        final semantics = tester.widget<Semantics>(
          find.ancestor(
            of: find.text(
              'Certificate is currently locked by another operation. Please retry.',
            ),
            matching: find.byWidgetPredicate(
              (w) => w is Semantics && w.properties.liveRegion == true,
            ),
          ),
        );
        expect(semantics.properties.liveRegion, isTrue);

        // Not marked revoked, no success snackbar
        expect(find.text('Certificate revoked successfully.'), findsNothing);

        // Cancel dialog
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsNothing);

        // Screen behind remains VALID
        expect(find.text('VALID'), findsOneWidget);
        expect(find.text('REVOKED'), findsNothing);
        expect(find.text('Revoke certificate'), findsOneWidget);
      },
    );

    testWidgets(
      'Test C: HTTP 409 when refresh fails does not fabricate status, displays accessible recovery and avoids retry loops',
      (tester) async {
        setTestViewport(tester);
        var detailFetchCount = 0;
        when(
          () => repository.certificateDetail(
            1,
            cancelToken: any(named: 'cancelToken'),
          ),
        ).thenAnswer((_) async {
          detailFetchCount++;
          if (detailFetchCount == 1) {
            return ManagedCertificateDetail.fromJson(
              sampleManagedCertificateDetailJson(id: 1, isRevoked: false),
            );
          }
          throw ApiError.networkFailure();
        });

        when(
          () => repository.revokeCertificate(
            1,
            any(),
            cancelToken: any(named: 'cancelToken'),
          ),
        ).thenThrow(
          ApiError(
            statusCode: 409,
            message: 'Conflict occurred during revocation.',
          ),
        );

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              authControllerProvider.overrideWith(() => auth),
              managementRepositoryProvider.overrideWithValue(repository),
            ],
            child: const MaterialApp(
              home: ManagedCertificateDetailScreen(certificateId: 1),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('VALID'), findsOneWidget);

        await tester.tap(find.text('Revoke certificate'));
        await tester.pumpAndSettle();

        await tester.enterText(
          find.widgetWithText(TextFormField, 'Revocation reason *'),
          'Revoke before network drops',
        );
        await tester.pumpAndSettle();

        await tester.tap(find.text('Confirm Revocation'));
        await tester.pumpAndSettle();

        // Refresh was attempted
        expect(detailFetchCount, 2);

        // Dialog was resolved to avoid trapping user
        expect(find.byType(AlertDialog), findsNothing);

        // No fabricated status: neither VALID nor REVOKED is shown
        expect(find.text('VALID'), findsNothing);
        expect(find.text('REVOKED'), findsNothing);

        // Accessible recovery view is rendered (ApiErrorView with Retry)
        expect(find.byType(ApiErrorView), findsOneWidget);
        expect(find.text('Retry'), findsOneWidget);

        // No infinite loop: tapping Retry calls repository once more
        await tester.tap(find.text('Retry'));
        await tester.pumpAndSettle();
        expect(detailFetchCount, 3);
      },
    );

    testWidgets(
      'Test E: Account switch during asynchronous request prevents stale results from updating new account',
      (tester) async {
        setTestViewport(tester);
        final completer = Completer<CertificateRevocationResult>();

        when(
          () => repository.certificateDetail(
            1,
            cancelToken: any(named: 'cancelToken'),
          ),
        ).thenAnswer(
          (_) async => ManagedCertificateDetail.fromJson(
            sampleManagedCertificateDetailJson(id: 1, isRevoked: false),
          ),
        );

        when(
          () => repository.revokeCertificate(
            1,
            any(),
            cancelToken: any(named: 'cancelToken'),
          ),
        ).thenAnswer((_) => completer.future);

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              authControllerProvider.overrideWith(() => auth),
              managementRepositoryProvider.overrideWithValue(repository),
            ],
            child: const MaterialApp(
              home: ManagedCertificateDetailScreen(certificateId: 1),
            ),
          ),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.text('Revoke certificate'));
        await tester.pumpAndSettle();

        await tester.enterText(
          find.widgetWithText(TextFormField, 'Revocation reason *'),
          'Revoke before account switch',
        );
        await tester.pumpAndSettle();

        await tester.tap(find.text('Confirm Revocation'));
        await tester.pump(); // Request in flight

        // Switch authenticated account to a different user mid-flight
        auth.setAuth(
          AuthAuthenticated.identity(
            managementIdentity(
              username: 'other_admin',
              capabilities: {
                'management_workspace',
                'certifications.view_certificate',
              },
            ),
          ),
        );
        await tester.pump();

        // Complete the in-flight mutation
        completer.complete(
          CertificateRevocationResult(
            id: 1,
            isRevoked: true,
            revokedAt: DateTime.now(),
          ),
        );
        await tester.pumpAndSettle();

        // Stale success must not be shown to other account
        expect(find.text('Certificate revoked successfully.'), findsNothing);
      },
    );

    testWidgets(
      'Test A: HTTP 409 already revoked by another administrator refreshes detail, shows REVOKED, removes revoke button and shows reason',
      (tester) async {
        setTestViewport(tester);
        var detailFetchCount = 0;
        when(
          () => repository.certificateDetail(
            1,
            cancelToken: any(named: 'cancelToken'),
          ),
        ).thenAnswer((_) async {
          detailFetchCount++;
          if (detailFetchCount == 1) {
            return ManagedCertificateDetail.fromJson(
              sampleManagedCertificateDetailJson(id: 1, isRevoked: false),
            );
          }
          return ManagedCertificateDetail.fromJson(
            sampleManagedCertificateDetailJson(
              id: 1,
              isRevoked: true,
              revokedAt: '2026-03-05T14:30:00Z',
              revocationReason: 'Revoked by admin Sarah for compliance.',
            ),
          );
        });

        when(
          () => repository.revokeCertificate(
            1,
            any(),
            cancelToken: any(named: 'cancelToken'),
          ),
        ).thenThrow(
          ApiError(
            statusCode: 409,
            message: 'This certificate has already been revoked by another administrator.',
          ),
        );

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              authControllerProvider.overrideWith(() => auth),
              managementRepositoryProvider.overrideWithValue(repository),
            ],
            child: const MaterialApp(
              home: ManagedCertificateDetailScreen(certificateId: 1),
            ),
          ),
        );
        await tester.pumpAndSettle();

        // Initially VALID with Revoke button
        expect(find.text('VALID'), findsOneWidget);
        expect(find.text('Revoke certificate'), findsOneWidget);

        await tester.tap(find.text('Revoke certificate'));
        await tester.pumpAndSettle();

        await tester.enterText(
          find.widgetWithText(TextFormField, 'Revocation reason *'),
          'Revocation attempt after Sarah already revoked',
        );
        await tester.pumpAndSettle();

        await tester.tap(find.text('Confirm Revocation'));
        await tester.pumpAndSettle();

        // Detail provider was refreshed (detailFetchCount == 2)
        expect(detailFetchCount, 2);

        // Dialog was safely resolved
        expect(find.byType(AlertDialog), findsNothing);

        // Detail screen shows REVOKED and removes Revoke button
        expect(find.text('REVOKED'), findsOneWidget);
        expect(find.text('VALID'), findsNothing);
        expect(find.text('Revoke certificate'), findsNothing);

        // Authoritative revocation reason and date are displayed
        expect(
          find.text('Revoked by admin Sarah for compliance.'),
          findsOneWidget,
        );

        // Explains that certificate was already revoked without false success message
        expect(
          find.text(
            'This certificate has already been revoked by another administrator.',
          ),
          findsOneWidget,
        );
        expect(find.text('Certificate revoked successfully.'), findsNothing);
      },
    );

    testWidgets(
      'Test B: HTTP 409 locking conflict when certificate is still valid preserves VALID and keeps accessible conflict error in dialog',
      (tester) async {
        setTestViewport(tester);
        var detailFetchCount = 0;
        when(
          () => repository.certificateDetail(
            1,
            cancelToken: any(named: 'cancelToken'),
          ),
        ).thenAnswer((_) async {
          detailFetchCount++;
          // Even on second fetch, certificate remains valid (concurrency/locking conflict)
          return ManagedCertificateDetail.fromJson(
            sampleManagedCertificateDetailJson(id: 1, isRevoked: false),
          );
        });

        when(
          () => repository.revokeCertificate(
            1,
            any(),
            cancelToken: any(named: 'cancelToken'),
          ),
        ).thenThrow(
          ApiError(
            statusCode: 409,
            message: 'Certificate is currently locked by another operation. Please retry.',
          ),
        );

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              authControllerProvider.overrideWith(() => auth),
              managementRepositoryProvider.overrideWithValue(repository),
            ],
            child: const MaterialApp(
              home: ManagedCertificateDetailScreen(certificateId: 1),
            ),
          ),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.text('Revoke certificate'));
        await tester.pumpAndSettle();

        await tester.enterText(
          find.widgetWithText(TextFormField, 'Revocation reason *'),
          'Revocation during concurrent lock',
        );
        await tester.pumpAndSettle();

        await tester.tap(find.text('Confirm Revocation'));
        await tester.pumpAndSettle();

        // Refreshed detail provider was called
        expect(detailFetchCount, 2);

        // Dialog remains open for retry
        expect(find.byType(AlertDialog), findsOneWidget);
        expect(find.text('Confirm Revocation'), findsOneWidget);

        // Accessible conflict explanation inside dialog
        expect(
          find.text(
            'Certificate is currently locked by another operation. Please retry.',
          ),
          findsOneWidget,
        );
        final semantics = tester.widget<Semantics>(
          find.ancestor(
            of: find.text(
              'Certificate is currently locked by another operation. Please retry.',
            ),
            matching: find.byWidgetPredicate(
              (w) => w is Semantics && w.properties.liveRegion == true,
            ),
          ),
        );
        expect(semantics.properties.liveRegion, isTrue);

        // Not marked revoked, no success snackbar
        expect(find.text('Certificate revoked successfully.'), findsNothing);

        // Cancel dialog
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsNothing);

        // Screen behind remains VALID
        expect(find.text('VALID'), findsOneWidget);
        expect(find.text('REVOKED'), findsNothing);
        expect(find.text('Revoke certificate'), findsOneWidget);
      },
    );

    testWidgets(
      'Test C: HTTP 409 when refresh fails does not fabricate status, displays accessible recovery and avoids retry loops',
      (tester) async {
        setTestViewport(tester);
        var detailFetchCount = 0;
        when(
          () => repository.certificateDetail(
            1,
            cancelToken: any(named: 'cancelToken'),
          ),
        ).thenAnswer((_) async {
          detailFetchCount++;
          if (detailFetchCount == 1) {
            return ManagedCertificateDetail.fromJson(
              sampleManagedCertificateDetailJson(id: 1, isRevoked: false),
            );
          }
          throw ApiError.networkFailure();
        });

        when(
          () => repository.revokeCertificate(
            1,
            any(),
            cancelToken: any(named: 'cancelToken'),
          ),
        ).thenThrow(
          ApiError(
            statusCode: 409,
            message: 'Conflict occurred during revocation.',
          ),
        );

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              authControllerProvider.overrideWith(() => auth),
              managementRepositoryProvider.overrideWithValue(repository),
            ],
            child: const MaterialApp(
              home: ManagedCertificateDetailScreen(certificateId: 1),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('VALID'), findsOneWidget);

        await tester.tap(find.text('Revoke certificate'));
        await tester.pumpAndSettle();

        await tester.enterText(
          find.widgetWithText(TextFormField, 'Revocation reason *'),
          'Revoke before network drops',
        );
        await tester.pumpAndSettle();

        await tester.tap(find.text('Confirm Revocation'));
        await tester.pumpAndSettle();

        // Refresh was attempted
        expect(detailFetchCount, 2);

        // Dialog was resolved to avoid trapping user
        expect(find.byType(AlertDialog), findsNothing);

        // No fabricated status: neither VALID nor REVOKED is shown
        expect(find.text('VALID'), findsNothing);
        expect(find.text('REVOKED'), findsNothing);

        // Accessible recovery view is rendered (ApiErrorView with Retry)
        expect(find.byType(ApiErrorView), findsOneWidget);
        expect(find.text('Retry'), findsOneWidget);

        // No infinite loop: tapping Retry calls repository once more
        await tester.tap(find.text('Retry'));
        await tester.pumpAndSettle();
        expect(detailFetchCount, 3);
      },
    );

    testWidgets(
      'Test E: Account switch during asynchronous request prevents stale results from updating new account',
      (tester) async {
        setTestViewport(tester);
        final completer = Completer<CertificateRevocationResult>();

        when(
          () => repository.certificateDetail(
            1,
            cancelToken: any(named: 'cancelToken'),
          ),
        ).thenAnswer(
          (_) async => ManagedCertificateDetail.fromJson(
            sampleManagedCertificateDetailJson(id: 1, isRevoked: false),
          ),
        );

        when(
          () => repository.revokeCertificate(
            1,
            any(),
            cancelToken: any(named: 'cancelToken'),
          ),
        ).thenAnswer((_) => completer.future);

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              authControllerProvider.overrideWith(() => auth),
              managementRepositoryProvider.overrideWithValue(repository),
            ],
            child: const MaterialApp(
              home: ManagedCertificateDetailScreen(certificateId: 1),
            ),
          ),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.text('Revoke certificate'));
        await tester.pumpAndSettle();

        await tester.enterText(
          find.widgetWithText(TextFormField, 'Revocation reason *'),
          'Revoke before account switch',
        );
        await tester.pumpAndSettle();

        await tester.tap(find.text('Confirm Revocation'));
        await tester.pump(); // Request in flight

        // Switch authenticated account to a different user mid-flight
        auth.setAuth(
          AuthAuthenticated.identity(
            managementIdentity(
              username: 'other_admin',
              capabilities: {
                'management_workspace',
                'certifications.view_certificate',
              },
            ),
          ),
        );
        await tester.pump();

        // Complete the in-flight mutation
        completer.complete(
          CertificateRevocationResult(
            id: 1,
            isRevoked: true,
            revokedAt: DateTime.now(),
          ),
        );
        await tester.pumpAndSettle();

        // Stale success must not be shown to other account
        expect(find.text('Certificate revoked successfully.'), findsNothing);
      },
    );

    for (final scenario in [
      (
        name: 'HTTP 400 Bad Request',
        error: ApiError(
          statusCode: 400,
          message: 'Reason must be at least 10 characters.',
        ),
        expectedMessage: 'Reason must be at least 10 characters.',
      ),
      (
        name: 'HTTP 403 Permission Denied',
        error: ApiError(
          statusCode: 403,
          message: 'You do not have permission to revoke certificates.',
        ),
        expectedMessage: 'You do not have permission to revoke certificates.',
      ),
      (
        name: 'HTTP 404 Not Found',
        error: ApiError(statusCode: 404, message: 'Certificate was not found.'),
        expectedMessage: 'Certificate was not found.',
      ),
      (
        name: 'Network Failure',
        error: ApiError.networkFailure(),
        expectedMessage:
            'Network connection failed. Please check your internet connection.',
      ),
    ]) {
      testWidgets(
        'Test D: ${scenario.name} displays error inside dialog with live semantics and leaves dialog open',
        (tester) async {
          setTestViewport(tester);
          when(
            () => repository.certificateDetail(
              1,
              cancelToken: any(named: 'cancelToken'),
            ),
          ).thenAnswer(
            (_) async => ManagedCertificateDetail.fromJson(
              sampleManagedCertificateDetailJson(id: 1, isRevoked: false),
            ),
          );

          when(
            () => repository.revokeCertificate(
              1,
              any(),
              cancelToken: any(named: 'cancelToken'),
            ),
          ).thenThrow(scenario.error);

          await tester.pumpWidget(
            ProviderScope(
              overrides: [
                authControllerProvider.overrideWith(() => auth),
                managementRepositoryProvider.overrideWithValue(repository),
              ],
              child: const MaterialApp(
                home: ManagedCertificateDetailScreen(certificateId: 1),
              ),
            ),
          );
          await tester.pumpAndSettle();

          await tester.tap(find.text('Revoke certificate'));
          await tester.pumpAndSettle();

          await tester.enterText(
            find.widgetWithText(TextFormField, 'Revocation reason *'),
            'Some reason to test error handling',
          );
          await tester.pumpAndSettle();

          await tester.tap(find.text('Confirm Revocation'));
          await tester.pumpAndSettle();

          // Dialog remains open for correction
          expect(find.byType(AlertDialog), findsOneWidget);
          expect(find.text('Confirm Revocation'), findsOneWidget);

          // Error displayed inside dialog
          expect(find.text(scenario.expectedMessage), findsOneWidget);

          // Accessible live semantics verified
          final semantics = tester.widget<Semantics>(
            find.ancestor(
              of: find.text(scenario.expectedMessage),
              matching: find.byWidgetPredicate(
                (w) => w is Semantics && w.properties.liveRegion == true,
              ),
            ),
          );
          expect(semantics.properties.liveRegion, isTrue);

          // SnackBar is NOT shown behind dialog
          expect(find.byType(SnackBar), findsNothing);

          // Cancel dialog
          await tester.tap(find.text('Cancel'));
          await tester.pumpAndSettle();
          expect(find.byType(AlertDialog), findsNothing);

          // Certificate remains VALID (never falsely marked revoked on failure)
          expect(find.text('VALID'), findsOneWidget);
          expect(find.text('REVOKED'), findsNothing);
          expect(find.text('Revoke certificate'), findsOneWidget);
        },
      );
    }

    testWidgets('editing reason clears the error banner in revocation dialog', (
      tester,
    ) async {
      setTestViewport(tester);
      when(
        () => repository.certificateDetail(
          1,
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer(
        (_) async => ManagedCertificateDetail.fromJson(
          sampleManagedCertificateDetailJson(id: 1, isRevoked: false),
        ),
      );

      when(
        () => repository.revokeCertificate(
          1,
          any(),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenThrow(
        ApiError(statusCode: 400, message: 'Invalid reason provided.'),
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            authControllerProvider.overrideWith(() => auth),
            managementRepositoryProvider.overrideWithValue(repository),
          ],
          child: const MaterialApp(
            home: ManagedCertificateDetailScreen(certificateId: 1),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Revoke certificate'));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.widgetWithText(TextFormField, 'Revocation reason *'),
        'Initial reason',
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Confirm Revocation'));
      await tester.pumpAndSettle();

      expect(find.text('Invalid reason provided.'), findsOneWidget);

      // Typing more text clears the error
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Revocation reason *'),
        'Initial reason edited',
      );
      await tester.pumpAndSettle();

      expect(find.text('Invalid reason provided.'), findsNothing);
    });
  });
}
