import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';
import 'package:training_app/core/errors/api_error.dart';
import 'package:training_app/core/presentation/components/api_error_view.dart';
import 'package:training_app/core/presentation/components/loading_view.dart';
import 'package:training_app/core/theme/app_theme.dart';
import 'package:training_app/features/auth/domain/models/auth_state.dart';
import 'package:training_app/features/auth/domain/models/employee.dart';
import 'package:training_app/features/auth/presentation/controllers/auth_controller.dart';
import 'package:training_app/features/certificates/data/repositories/certificate_repository.dart';
import 'package:training_app/features/certificates/domain/models/certificate_detail.dart';
import 'package:training_app/features/certificates/presentation/screens/certificate_detail_screen.dart';
import 'package:training_app/features/learning/data/repositories/learning_repository.dart';
import 'package:training_app/features/learning/domain/models/assignment_detail.dart';

class _MockCertificates extends Mock implements CertificateRepository {}

class _MockLearning extends Mock implements LearningRepository {}

class _TestAuthController extends AuthController {
  @override
  AuthState build() => AuthAuthenticated(
        Employee(
          username: 'tester',
          employeeCode: 'EMP-001',
          displayName: 'Test Operator',
          department: 'Operations',
          jobRole: 'Learner',
          isActive: true,
        ),
      );

  void setAuth(AuthState next) => state = next;
}

CertificateDetail _sampleCertificate({
  int id = 8,
  bool isRevoked = false,
  bool hasDocument = true,
  String? longName,
}) =>
    CertificateDetail(
      id: id,
      certificateNumber: 'GN-2026-CERT-008',
      employeeName: longName ?? 'Test Operator',
      employeeCode: 'EMP-001',
      trainingTitle: 'Workplace Health & Chemical Safety Procedures',
      versionNumber: 2,
      issuedAt: DateTime.utc(2026, 11, 15, 10, 30),
      isRevoked: isRevoked,
      revokedAt: isRevoked ? DateTime.utc(2026, 11, 20, 14, 00) : null,
      assignmentId: 1,
      hasDocument: hasDocument,
    );

void main() {
  late _MockCertificates certificateRepository;
  late _MockLearning learningRepository;
  late _TestAuthController authController;
  late ProviderContainer container;

  setUpAll(() => registerFallbackValue(CancelToken()));

  setUp(() {
    certificateRepository = _MockCertificates();
    learningRepository = _MockLearning();
    authController = _TestAuthController();

    when(() => learningRepository.getAssignmentDetail(any(), cancelToken: any(named: 'cancelToken')))
        .thenAnswer((_) async => AssignmentDetail(
              id: 1,
              trainingId: 10,
              trainingTitle: 'Workplace Health & Chemical Safety Procedures',
              versionNumber: 2,
              status: 'COMPLETED',
              isOverdue: false,
              completedAt: DateTime.utc(2026, 11, 15, 10, 00),
              modules: [],
            ));
  });

  Widget buildTestApp({required Widget child}) {
    container = ProviderContainer(
      overrides: [
        certificateRepositoryProvider.overrideWithValue(certificateRepository),
        learningRepositoryProvider.overrideWithValue(learningRepository),
        authControllerProvider.overrideWith(() => authController),
      ],
    );

    final router = GoRouter(
      initialLocation: '/',
      routes: [
        GoRoute(path: '/', builder: (context, state) => child),
        GoRoute(path: '/certificates', builder: (context, state) => const Scaffold(body: Text('Certificate List'))),
      ],
    );

    return UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        routerConfig: router,
        theme: AppTheme.lightTheme,
      ),
    );
  }

  group('M17 Certificate Release Acceptance & Robustness', () {
    testWidgets('1. Certificate not found (404) renders clear error and hides print controls', (tester) async {
      when(
        () => certificateRepository.getCertificateDetail(999, cancelToken: any(named: 'cancelToken')),
      ).thenThrow(ApiError.fromBackend(404, {'detail': 'Certificate not found.'}));

      await tester.pumpWidget(buildTestApp(
        child: const CertificateDetailScreen(certificateId: 999),
      ));
      await tester.pumpAndSettle();

      expect(find.byType(ApiErrorView), findsOneWidget);
      expect(find.text('Certificate not found.'), findsOneWidget);
      expect(find.text('Print / Save as PDF'), findsNothing);
    });

    testWidgets('2. Unauthorized / foreign certificate access (403) masks details safely', (tester) async {
      when(
        () => certificateRepository.getCertificateDetail(8, cancelToken: any(named: 'cancelToken')),
      ).thenThrow(ApiError.fromBackend(403, {'detail': 'You do not have permission to view this certificate.'}));

      await tester.pumpWidget(buildTestApp(
        child: const CertificateDetailScreen(certificateId: 8),
      ));
      await tester.pumpAndSettle();

      expect(find.byType(ApiErrorView), findsOneWidget);
      expect(find.text('GN-2026-CERT-008'), findsNothing);
      expect(find.text('Print / Save as PDF'), findsNothing);
    });

    testWidgets('3. Revoked certificate clearly presents revocation notice and warning badge', (tester) async {
      when(
        () => certificateRepository.getCertificateDetail(8, cancelToken: any(named: 'cancelToken')),
      ).thenAnswer((_) async => _sampleCertificate(isRevoked: true));

      await tester.pumpWidget(buildTestApp(
        child: const CertificateDetailScreen(certificateId: 8),
      ));
      await tester.pumpAndSettle();

      expect(find.text('GN-2026-CERT-008'), findsOneWidget);
      expect(find.textContaining('Revoked'), findsWidgets);
    });

    testWidgets('4. Loading failure offers functional retry that recovers on success', (tester) async {
      var callCount = 0;
      when(
        () => certificateRepository.getCertificateDetail(8, cancelToken: any(named: 'cancelToken')),
      ).thenAnswer((_) async {
        callCount++;
        if (callCount == 1) {
          throw ApiError.networkFailure();
        }
        return _sampleCertificate();
      });

      await tester.pumpWidget(buildTestApp(
        child: const CertificateDetailScreen(certificateId: 8),
      ));
      await tester.pumpAndSettle();

      expect(find.byType(ApiErrorView), findsOneWidget);
      final retryBtn = find.text('Retry');
      expect(retryBtn, findsOneWidget);

      await tester.tap(retryBtn);
      await tester.pumpAndSettle();

      expect(find.text('GN-2026-CERT-008'), findsOneWidget);
      expect(find.byType(ApiErrorView), findsNothing);
    });

    testWidgets('5. Long employee name and narrow screen (320x640, 1.8x text) does not overflow', (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      when(
        () => certificateRepository.getCertificateDetail(8, cancelToken: any(named: 'cancelToken')),
      ).thenAnswer((_) async => _sampleCertificate(
            longName: 'Dr. Alexander Montgomery-Cunningham III of the Industrial Safety Board',
          ));

      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(
            size: Size(320, 640),
            textScaler: TextScaler.linear(1.8),
          ),
          child: buildTestApp(child: const CertificateDetailScreen(certificateId: 8)),
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('GN-2026-CERT-008'), findsOneWidget);
    });

    testWidgets('6. Loading state displays indicator without showing false issued certificate', (tester) async {
      final completer = Completer<CertificateDetail>();
      when(
        () => certificateRepository.getCertificateDetail(8, cancelToken: any(named: 'cancelToken')),
      ).thenAnswer((_) => completer.future);

      await tester.pumpWidget(buildTestApp(
        child: const CertificateDetailScreen(certificateId: 8),
      ));
      await tester.pump();

      expect(find.byType(LoadingView), findsOneWidget);
      expect(find.text('GN-2026-CERT-008'), findsNothing);

      completer.complete(_sampleCertificate());
      await tester.pumpAndSettle();
      expect(find.text('GN-2026-CERT-008'), findsOneWidget);
    });
  });
}
