import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';
import 'package:pdf/pdf.dart';
import 'package:training_app/core/errors/api_error.dart';
import 'package:training_app/core/theme/app_theme.dart';
import 'package:training_app/features/auth/domain/models/auth_state.dart';
import 'package:training_app/features/auth/domain/models/employee.dart';
import 'package:training_app/features/auth/presentation/controllers/auth_controller.dart';
import 'package:training_app/features/certificates/data/repositories/certificate_repository.dart';
import 'package:training_app/features/certificates/data/services/certificate_print_service.dart';
import 'package:training_app/features/certificates/domain/models/certificate_detail.dart';
import 'package:training_app/features/certificates/domain/models/certificate_print_data.dart';
import 'package:training_app/features/certificates/presentation/screens/certificate_detail_screen.dart';
import 'package:training_app/features/learning/data/repositories/learning_repository.dart';

class _MockCertificateRepository extends Mock
    implements CertificateRepository {}

class _MockLearningRepository extends Mock implements LearningRepository {}

class _MockPrintService extends Mock implements CertificatePrintService {}

class _TestAuthController extends AuthController {
  @override
  AuthState build() => AuthAuthenticated(_employee('current_user'));

  void switchUser(String username) {
    state = AuthAuthenticated(_employee(username));
  }
}

Employee _employee(String username) => Employee(
  username: username,
  employeeCode: 'EMP-$username',
  displayName: 'Employee $username',
  department: 'Horticulture',
  jobRole: 'Lead Specialist',
  isActive: true,
);

CertificateDetail _sampleCertificate({
  int id = 42,
  String certNum = 'GN-CERT-00042',
  bool isRevoked = false,
  DateTime? revokedAt,
}) => CertificateDetail(
  id: id,
  certificateNumber: certNum,
  trainingTitle: 'Crop Protection & Safety Protocols',
  versionNumber: 2,
  employeeName: 'Morgan Vance',
  employeeCode: 'EMP-MV01',
  issuedAt: DateTime.utc(2026, 5, 20, 11, 0),
  isRevoked: isRevoked,
  revokedAt: revokedAt,
  assignmentId: 99,
  hasDocument: false,
);

void main() {
  setUpAll(() {
    registerFallbackValue(CancelToken());
    registerFallbackValue(
      CertificatePrintData(
        certificateId: 1,
        certificateNumber: 'fallback',
        employeeName: 'fallback',
        employeeCode: 'fallback',
        trainingTitle: 'fallback',
        versionNumber: 1,
        issuedAt: DateTime.now(),
        isRevoked: false,
      ),
    );
    registerFallbackValue(PdfPageFormat.a4);
  });

  group('Certificate Print & PDF Export Flow', () {
    late _MockCertificateRepository certificateRepo;
    late _MockLearningRepository learningRepo;
    late _MockPrintService printService;
    late _TestAuthController authController;
    late ProviderContainer container;
    late GoRouter router;

    setUp(() {
      certificateRepo = _MockCertificateRepository();
      learningRepo = _MockLearningRepository();
      printService = _MockPrintService();
      authController = _TestAuthController();

      when(
        () => printService.generatePdf(any(), format: any(named: 'format')),
      ).thenAnswer((_) async => Uint8List.fromList([0x25, 0x50, 0x44, 0x46]));

      when(
        () => printService.printCertificate(
          any(),
          format: any(named: 'format'),
          canPrint: any(named: 'canPrint'),
        ),
      ).thenAnswer((_) async => true);

      container = ProviderContainer(
        overrides: [
          authControllerProvider.overrideWith(() => authController),
          certificateRepositoryProvider.overrideWithValue(certificateRepo),
          learningRepositoryProvider.overrideWithValue(learningRepo),
          certificatePrintServiceProvider.overrideWithValue(printService),
        ],
      );

      router = GoRouter(
        initialLocation: '/profile/certificates/42',
        routes: [
          GoRoute(
            path: '/profile/certificates/:id',
            builder: (context, state) => CertificateDetailScreen(
              certificateId: int.parse(state.pathParameters['id']!),
            ),
          ),
        ],
      );
    });

    tearDown(() {
      router.dispose();
      container.dispose();
    });

    Future<void> pumpScreen(WidgetTester tester) async {
      tester.view.physicalSize = const Size(800, 1800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
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
    }

    testWidgets(
      'print action is visible and invokes printService with authoritative data',
      (tester) async {
        final cert = _sampleCertificate();
        when(
          () => certificateRepo.getCertificateDetail(
            42,
            cancelToken: any(named: 'cancelToken'),
          ),
        ).thenAnswer((_) async => cert);

        await pumpScreen(tester);

        // Verify print section exists
        expect(find.text('Print & PDF Export'), findsOneWidget);
        final printBtn = find.widgetWithText(
          FilledButton,
          'Print / Save as PDF',
        );
        expect(printBtn, findsOneWidget);

        // Tap print button
        await tester.ensureVisible(printBtn);
        await tester.pumpAndSettle();
        await tester.tap(printBtn);
        await tester.pumpAndSettle();

        // Verify printService called with exact authoritative server data
        final captured = verify(
          () => printService.printCertificate(
            captureAny(),
            format: any(named: 'format'),
            canPrint: any(named: 'canPrint'),
          ),
        ).captured;

        expect(captured.length, equals(1));
        final printData = captured.first as CertificatePrintData;
        expect(printData.certificateId, equals(42));
        expect(printData.certificateNumber, equals('GN-CERT-00042'));
        expect(printData.employeeName, equals('Morgan Vance'));
        expect(printData.employeeCode, equals('EMP-MV01'));
        expect(
          printData.trainingTitle,
          equals('Crop Protection & Safety Protocols'),
        );
        expect(printData.versionNumber, equals(2));
        expect(printData.isRevoked, isFalse);
        verify(
          () => certificateRepo.getCertificateDetail(
            42,
            cancelToken: any(named: 'cancelToken'),
          ),
        ).called(2); // Initial display plus fresh read before printing.
      },
    );

    testWidgets(
      'loading indicator is displayed while print generation is in progress',
      (tester) async {
        final cert = _sampleCertificate();
        when(
          () => certificateRepo.getCertificateDetail(
            42,
            cancelToken: any(named: 'cancelToken'),
          ),
        ).thenAnswer((_) async => cert);

        final completer = Completer<bool>();
        when(
          () => printService.printCertificate(
            any(),
            format: any(named: 'format'),
            canPrint: any(named: 'canPrint'),
          ),
        ).thenAnswer((_) => completer.future);

        await pumpScreen(tester);

        final printBtn = find.widgetWithText(
          FilledButton,
          'Print / Save as PDF',
        );
        await tester.ensureVisible(printBtn);
        await tester.pumpAndSettle();
        await tester.tap(printBtn);
        await tester.pump(); // Start execution

        // Button should now show loading state
        expect(find.text('Preparing document...'), findsOneWidget);
        expect(find.byType(CircularProgressIndicator), findsOneWidget);

        // Complete print
        completer.complete(true);
        await tester.pumpAndSettle();

        // Restores standard label
        expect(find.text('Print / Save as PDF'), findsOneWidget);
        expect(find.byType(CircularProgressIndicator), findsNothing);
      },
    );

    testWidgets('platform print cancellation completes cleanly without error', (
      tester,
    ) async {
      final cert = _sampleCertificate();
      when(
        () => certificateRepo.getCertificateDetail(
          42,
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer((_) async => cert);

      // Platform returns false when user dismisses/cancels print dialog
      when(
        () => printService.printCertificate(
          any(),
          format: any(named: 'format'),
          canPrint: any(named: 'canPrint'),
        ),
      ).thenAnswer((_) async => false);

      await pumpScreen(tester);

      final printBtn = find.widgetWithText(FilledButton, 'Print / Save as PDF');
      await tester.ensureVisible(printBtn);
      await tester.pumpAndSettle();
      await tester.tap(printBtn);
      await tester.pumpAndSettle();

      // No error snackbar should be displayed on clean cancellation
      expect(find.byType(SnackBar), findsNothing);
      expect(find.text('Print / Save as PDF'), findsOneWidget);
    });

    testWidgets(
      'print failure shows error SnackBar with functional Retry button',
      (tester) async {
        final cert = _sampleCertificate();
        when(
          () => certificateRepo.getCertificateDetail(
            42,
            cancelToken: any(named: 'cancelToken'),
          ),
        ).thenAnswer((_) async => cert);

        // First call throws error
        when(
          () => printService.printCertificate(
            any(),
            format: any(named: 'format'),
            canPrint: any(named: 'canPrint'),
          ),
        ).thenThrow(Exception('Android print spooler unavailable'));

        await pumpScreen(tester);

        final printBtn = find.widgetWithText(
          FilledButton,
          'Print / Save as PDF',
        );
        await tester.ensureVisible(printBtn);
        await tester.pumpAndSettle();
        await tester.tap(printBtn);
        await tester.pumpAndSettle();

        // Error SnackBar with Retry action
        expect(
          find.text(
            'Unable to prepare certificate for printing. Please try again.',
          ),
          findsOneWidget,
        );
        expect(find.text('Retry'), findsOneWidget);

        // Setup successful response for retry
        when(
          () => printService.printCertificate(
            any(),
            format: any(named: 'format'),
            canPrint: any(named: 'canPrint'),
          ),
        ).thenAnswer((_) async => true);

        // Tap Retry
        await tester.tap(find.text('Retry'));
        await tester.pumpAndSettle();

        // Verify called twice
        verify(
          () => printService.printCertificate(
            any(),
            format: any(named: 'format'),
            canPrint: any(named: 'canPrint'),
          ),
        ).called(2);
      },
    );

    testWidgets(
      'revoked certificate displays revocation notice and passes revoked status to print',
      (tester) async {
        final revokedAt = DateTime.utc(2026, 7, 10, 15, 30);
        final cert = _sampleCertificate(isRevoked: true, revokedAt: revokedAt);
        when(
          () => certificateRepo.getCertificateDetail(
            42,
            cancelToken: any(named: 'cancelToken'),
          ),
        ).thenAnswer((_) async => cert);

        await pumpScreen(tester);

        // Notice clearly states it is revoked
        expect(
          find.textContaining(
            'The generated document will clearly indicate that this credential has been REVOKED.',
          ),
          findsOneWidget,
        );

        final printBtn = find.widgetWithText(
          FilledButton,
          'Print / Save as PDF',
        );
        await tester.ensureVisible(printBtn);
        await tester.pumpAndSettle();
        await tester.tap(printBtn);
        await tester.pumpAndSettle();

        final captured = verify(
          () => printService.printCertificate(
            captureAny(),
            format: any(named: 'format'),
            canPrint: any(named: 'canPrint'),
          ),
        ).captured;

        final printData = captured.first as CertificatePrintData;
        expect(printData.isRevoked, isTrue);
        expect(printData.revokedAt, equals(revokedAt));
      },
    );

    testWidgets('missing or 404 certificate does not render print controls', (
      tester,
    ) async {
      when(
        () => certificateRepo.getCertificateDetail(
          42,
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenThrow(ApiError(message: 'Certificate not found.', statusCode: 404));

      await pumpScreen(tester);

      expect(find.text('Certificate not found.'), findsOneWidget);
      expect(find.text('Print & PDF Export'), findsNothing);
      expect(find.text('Print / Save as PDF'), findsNothing);
    });

    testWidgets(
      'account switch during in-flight print ignores late failure for prior user',
      (tester) async {
        final cert = _sampleCertificate();
        when(
          () => certificateRepo.getCertificateDetail(
            42,
            cancelToken: any(named: 'cancelToken'),
          ),
        ).thenAnswer((_) async => cert);

        final completer = Completer<bool>();
        when(
          () => printService.printCertificate(
            any(),
            format: any(named: 'format'),
            canPrint: any(named: 'canPrint'),
          ),
        ).thenAnswer((_) => completer.future);

        await pumpScreen(tester);

        final printBtn = find.widgetWithText(
          FilledButton,
          'Print / Save as PDF',
        );
        await tester.ensureVisible(printBtn);
        await tester.pumpAndSettle();
        await tester.tap(printBtn);
        await tester.pump();

        // Account changes mid-flight
        authController.switchUser('new_user');
        await tester.pump();

        // Previous print completes with error
        completer.completeError(Exception('Late print error for old user'));
        await tester.pumpAndSettle();

        // No SnackBar error shown because user context changed
        expect(find.byType(SnackBar), findsNothing);
      },
    );
  });
}
