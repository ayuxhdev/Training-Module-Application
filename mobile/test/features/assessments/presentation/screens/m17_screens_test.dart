import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';
import 'package:training_app/core/errors/api_error.dart';
import 'package:training_app/core/presentation/components/status_badge.dart';
import 'package:training_app/core/router/app_router.dart';
import 'package:training_app/main.dart';
import 'package:training_app/features/assessments/data/repositories/assessment_repository.dart';
import 'package:training_app/features/assessments/domain/models/assessment.dart';
import 'package:training_app/features/assessments/presentation/controllers/assessment_controller.dart';
import 'package:training_app/features/assessments/presentation/screens/assessment_attempt_screen.dart';
import 'package:training_app/features/assessments/presentation/screens/assessment_overview_screen.dart';
import 'package:training_app/features/auth/domain/models/auth_state.dart';
import 'package:training_app/features/auth/domain/models/employee.dart';
import 'package:training_app/features/auth/presentation/controllers/auth_controller.dart';
import 'package:training_app/features/auth/presentation/screens/login_screen.dart';
import 'package:training_app/features/certificates/data/repositories/certificate_repository.dart';
import 'package:training_app/features/certificates/domain/models/certificate.dart';
import 'package:training_app/features/certificates/domain/models/certificate_detail.dart';
import 'package:training_app/features/certificates/presentation/screens/certificate_detail_screen.dart';
import 'package:training_app/features/certificates/presentation/screens/certificate_list_screen.dart';
import 'package:training_app/features/certificates/presentation/controllers/certificate_controller.dart';
import 'package:training_app/features/dashboard/domain/models/dashboard_data.dart';
import 'package:training_app/features/dashboard/presentation/controllers/dashboard_controller.dart';
import 'package:training_app/features/learning/domain/models/assignment_detail.dart';
import 'package:training_app/features/learning/presentation/controllers/learning_controller.dart';
import 'package:training_app/features/notifications/presentation/controllers/notification_controller.dart';

import '../../assessment_fixtures.dart';
import '../../../notifications/notification_fixtures.dart';

class _Assessments extends Mock implements AssessmentRepository {}

class _Certificates extends Mock implements CertificateRepository {}

class _Auth extends AuthController {
  @override
  AuthState build() => AuthAuthenticated(_employee('A'));
  void change(AuthState value) => state = value;
}

Employee _employee(String name) => Employee(
  username: name,
  employeeCode: name,
  displayName: name,
  department: 'QA',
  jobRole: 'Learner',
  isActive: true,
);

void main() {
  late _Assessments assessments;
  late _Certificates certificates;
  late _Auth auth;
  late Map<String, dynamic> catalog;
  late ProviderContainer container;
  late GoRouter router;
  int dashboardReads = 0;
  const overviewPath = '/learning/assignments/1/assessments';
  const attemptPath = '$overviewPath/2/attempt';
  final certificate = Certificate(
    id: 8,
    certificateNumber: 'GN-008',
    trainingTitle: 'Safety award',
    versionNumber: 3,
    issuedAt: DateTime(2026, 1, 2),
    isRevoked: false,
  );
  CertificateDetail detail({bool revoked = false}) => CertificateDetail(
    id: 8,
    certificateNumber: 'GN-008',
    trainingTitle: 'Safety award',
    versionNumber: 3,
    employeeName: 'Historical name',
    employeeCode: 'H-001',
    issuedAt: DateTime(2026, 1, 2),
    isRevoked: revoked,
    revokedAt: revoked ? DateTime(2026, 2, 3) : null,
    assignmentId: 1,
    hasDocument: true,
  );

  setUpAll(() => registerFallbackValue(CancelToken()));
  setUp(() {
    assessments = _Assessments();
    certificates = _Certificates();
    auth = _Auth();
    catalog = catalogJson();
    dashboardReads = 0;
    when(
      () =>
          assessments.getAssessments(1, cancelToken: any(named: 'cancelToken')),
    ).thenAnswer((_) async => AssignmentAssessments.fromJson(catalog));
    when(
      () => assessments.startOrResume(
        1,
        2,
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenAnswer((_) async => attempt());
    when(
      () =>
          assessments.getAttempt(any(), cancelToken: any(named: 'cancelToken')),
    ).thenAnswer(
      (call) async => attempt(id: call.positionalArguments.first as int),
    );
    when(
      () => assessments.submitAttempt(
        7,
        any(),
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenAnswer((_) async => attempt(status: 'SUBMITTED'));
    when(
      () =>
          certificates.getCertificates(cancelToken: any(named: 'cancelToken')),
    ).thenAnswer((_) async => [certificate]);
    when(
      () => certificates.getCertificateDetail(
        8,
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenAnswer((_) async => detail());
  });

  Future<void> open(
    WidgetTester tester,
    String path, {
    bool dark = false,
    double scale = 1,
    bool reducedMotion = false,
  }) async {
    tester.platformDispatcher.platformBrightnessTestValue = dark
        ? Brightness.dark
        : Brightness.light;
    tester.platformDispatcher.textScaleFactorTestValue = scale;
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        FakeAccessibilityFeatures(disableAnimations: reducedMotion);
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    container = ProviderContainer(
      overrides: [
        notificationUnreadCountProvider.overrideWith(ZeroUnreadController.new),
        authControllerProvider.overrideWith(() => auth),
        assessmentRepositoryProvider.overrideWithValue(assessments),
        certificateRepositoryProvider.overrideWithValue(certificates),
        dashboardDataProvider.overrideWith((_) async {
          dashboardReads++;
          return DashboardData(
            metrics: DashboardMetrics(
              total: 1,
              assigned: 0,
              inProgress: 1,
              completed: 0,
              cancelled: 0,
              overdue: 0,
              completionPercent: 0,
              certificatesCount: 1,
            ),
            actionRequired: [],
            recentCertificates: [
              DashboardCertificate(
                id: 8,
                certificateNumber: 'GN-008',
                trainingTitle: 'Safety award',
                versionNumber: 3,
              ),
            ],
          );
        }),
        assignmentListProvider.overrideWith((_) async => []),
        assignmentDetailProvider(1).overrideWith(
          (_) async => AssignmentDetail(
            id: 1,
            trainingId: 1,
            trainingTitle: 'Safety course',
            versionNumber: 3,
            status: 'COMPLETED',
            isOverdue: false,
            modules: [
              ModuleLearning(
                id: 4,
                title: 'Safety module',
                description: '',
                position: 1,
                lessons: [],
              ),
            ],
          ),
        ),
      ],
    );
    router = container.read(appRouterProvider);
    router.go(path);
    addTearDown(container.dispose);
    addTearDown(router.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: const MyApp()),
    );
    await tester.pumpAndSettle();
  }

  Future<void> tap(WidgetTester tester, String text) async {
    if (find.text(text).evaluate().isEmpty) {
      await tester.scrollUntilVisible(
        find.text(text),
        180,
        scrollable: find.byType(Scrollable).first,
      );
    }
    await tester.ensureVisible(find.text(text).last);
    await tester.pumpAndSettle();
    await tester.tap(find.text(text).last);
    await tester.pumpAndSettle();
  }

  Future<void> confirm(WidgetTester tester) async {
    await tap(tester, 'Submit assessment');
    await tap(tester, 'Confirm submission');
  }

  testWidgets(
    'overview renders server eligibility, limits and history; resume reads existing attempt',
    (tester) async {
      await open(tester, overviewPath);
      expect(find.text('Passing score: 80.00%'), findsOneWidget);
      expect(find.text('Attempts remaining: 2 of 3'), findsOneWidget);
      expect(find.text('An attempt is already in progress.'), findsOneWidget);
      await tap(tester, 'Resume assessment');
      expect(find.text('Wear PPE?'), findsOneWidget);
      verify(
        () => assessments.getAttempt(7, cancelToken: any(named: 'cancelToken')),
      ).called(1);
      verifyNever(
        () => assessments.startOrResume(
          any(),
          any(),
          cancelToken: any(named: 'cancelToken'),
        ),
      );
    },
  );

  testWidgets('start creates an attempt only after the start action', (
    tester,
  ) async {
    catalog['assessments'][0]['can_start'] = true;
    catalog['assessments'][0]['can_resume'] = false;
    await open(tester, overviewPath);
    verifyNever(
      () => assessments.startOrResume(
        any(),
        any(),
        cancelToken: any(named: 'cancelToken'),
      ),
    );
    await tap(tester, 'Start assessment');
    expect(find.byType(AssessmentAttemptScreen), findsOneWidget);
    verify(
      () => assessments.startOrResume(
        1,
        2,
        cancelToken: any(named: 'cancelToken'),
      ),
    ).called(1);
  });

  testWidgets(
    'blocked/exhausted assessment offers no start and history shows persisted result',
    (tester) async {
      catalog['assessments'][0].addAll({
        'can_resume': false,
        'attempts_remaining': 0,
        'blocking_reason': 'Maximum attempts reached.',
        'attempts': [summaryJson(status: 'SUBMITTED', passed: false)],
      });
      when(
        () => assessments.getAttempt(7, cancelToken: any(named: 'cancelToken')),
      ).thenAnswer((_) async => attempt(status: 'SUBMITTED', passed: false));
      await open(tester, overviewPath);
      expect(find.text('Maximum attempts reached.'), findsOneWidget);
      expect(find.text('Resume assessment'), findsNothing);
      expect(find.text('Start assessment'), findsNothing);
      await tap(tester, 'Attempt 1');
      expect(find.text('Score: 0.00 / 2.00'), findsOneWidget);
      expect(find.text('Submit assessment'), findsNothing);
    },
  );

  testWidgets(
    'ordered single-choice and true/false selections survive question navigation',
    (tester) async {
      final json = attemptJson();
      json['questions'].add({
        'id': 12,
        'position': 2,
        'points': '1.00',
        'prompt': 'Report hazards?',
        'type': 'TRUE_FALSE',
        'options': [
          {'id': 31, 'position': 1, 'text': 'True'},
          {'id': 32, 'position': 2, 'text': 'False'},
        ],
      });
      when(
        () => assessments.startOrResume(
          1,
          2,
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer((_) async => AssessmentAttempt.fromJson(json));
      await open(tester, attemptPath);
      await tap(tester, 'Yes');
      await tap(tester, 'Next');
      expect(find.text('Report hazards?'), findsOneWidget);
      await tap(tester, 'True');
      await tap(tester, 'Previous');
      expect(find.text('2 of 2 answered'), findsOneWidget);
      final selected = tester.widgetList<Semantics>(
        find.ancestor(of: find.text('Yes'), matching: find.byType(Semantics)),
      );
      expect(
        selected.any((widget) => widget.properties.selected == true),
        isTrue,
      );
      await tap(tester, 'Clear answer');
      expect(find.text('1 of 2 answered'), findsOneWidget);
    },
  );

  testWidgets('unanswered confirmation can cancel without submitting', (
    tester,
  ) async {
    await open(tester, attemptPath);
    await tap(tester, 'Submit assessment');
    expect(find.textContaining('1 unanswered question'), findsOneWidget);
    await tap(tester, 'Keep working');
    verifyNever(
      () => assessments.submitAttempt(
        any(),
        any(),
        cancelToken: any(named: 'cancelToken'),
      ),
    );
    expect(find.text('Wear PPE?'), findsOneWidget);
  });

  testWidgets(
    'confirmed submission is deduplicated and renders server result and certificate link',
    (tester) async {
      final pending = Completer<AssessmentAttempt>();
      when(
        () => assessments.submitAttempt(
          7,
          any(),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer((_) => pending.future);
      await open(tester, attemptPath);
      await tap(tester, 'Yes');
      await tap(tester, 'Submit assessment');
      await tester.tap(find.text('Confirm submission'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Submit assessment'), findsNothing);
      pending.complete(attempt(status: 'SUBMITTED'));
      await tester.pumpAndSettle();
      expect(find.text('Passed'), findsOneWidget);
      expect(find.text('Score: 2.00 / 2.00'), findsOneWidget);
      verify(
        () => assessments.submitAttempt(7, {
          11: 21,
        }, cancelToken: any(named: 'cancelToken')),
      ).called(1);
      await tap(tester, 'View certificate');
      expect(find.byType(CertificateDetailScreen), findsOneWidget);
    },
  );

  testWidgets('timeout reconciles the result with GET and never resubmits', (
    tester,
  ) async {
    when(
      () => assessments.submitAttempt(
        7,
        any(),
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenThrow(ApiError.timeout());
    when(
      () => assessments.getAttempt(7, cancelToken: any(named: 'cancelToken')),
    ).thenAnswer((_) async => attempt(status: 'SUBMITTED'));
    await open(tester, attemptPath);
    await confirm(tester);
    expect(find.text('Passed'), findsOneWidget);
    verify(
      () => assessments.submitAttempt(
        7,
        any(),
        cancelToken: any(named: 'cancelToken'),
      ),
    ).called(1);
    verify(
      () => assessments.getAttempt(7, cancelToken: any(named: 'cancelToken')),
    ).called(1);
  });

  testWidgets(
    'uncertain submission disables submit until read reconciliation succeeds',
    (tester) async {
      when(
        () => assessments.submitAttempt(
          7,
          any(),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenThrow(ApiError.timeout());
      when(
        () => assessments.getAttempt(7, cancelToken: any(named: 'cancelToken')),
      ).thenThrow(ApiError.networkFailure());
      await open(tester, attemptPath);
      await confirm(tester);
      expect(
        find.textContaining('Submission is not confirmed.'),
        findsOneWidget,
      );
      await tester.scrollUntilVisible(
        find.text('Submit assessment'),
        180,
        scrollable: find.byType(Scrollable).first,
      );
      final submit = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Submit assessment'),
      );
      expect(submit.onPressed, isNull);
      when(
        () => assessments.getAttempt(7, cancelToken: any(named: 'cancelToken')),
      ).thenAnswer((_) async => attempt(status: 'SUBMITTED'));
      await tap(tester, 'Check attempt status');
      expect(find.text('Passed'), findsOneWidget);
    },
  );

  testWidgets(
    'expired deadline remains server-controlled and renders server expiry',
    (tester) async {
      final json = attemptJson()..['deadline_at'] = '2000-01-01T00:00:00Z';
      when(
        () => assessments.startOrResume(
          1,
          2,
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer((_) async => AssessmentAttempt.fromJson(json));
      when(
        () => assessments.submitAttempt(
          7,
          any(),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer((_) async => attempt(status: 'EXPIRED', passed: false));
      await open(tester, attemptPath);
      expect(find.textContaining('Deadline reached.'), findsOneWidget);
      await confirm(tester);
      expect(find.text('Expired'), findsOneWidget);
    },
  );

  testWidgets(
    'overview filters module quizzes without inventing prerequisite state',
    (tester) async {
      await open(tester, '$overviewPath?module=99');
      expect(find.text('No assessments available here.'), findsOneWidget);
      verifyNever(
        () => assessments.startOrResume(
          any(),
          any(),
          cancelToken: any(named: 'cancelToken'),
        ),
      );
    },
  );

  testWidgets(
    'assessment read errors show backend message and explicit retry',
    (tester) async {
      when(
        () => assessments.getAssessments(
          1,
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenThrow(ApiError.networkFailure());
      await open(tester, overviewPath);
      expect(find.text(ApiError.networkFailure().message), findsOneWidget);
      when(
        () => assessments.getAssessments(
          1,
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer((_) async => AssignmentAssessments.fromJson(catalog));
      await tap(tester, 'Retry');
      expect(find.text('Module quiz').first, findsOneWidget);
    },
  );

  testWidgets(
    'certificate list opens historical detail, with no unsupported document actions',
    (tester) async {
      await open(tester, '/profile/certificates');
      expect(find.textContaining('GN-008'), findsOneWidget);
      await tap(tester, 'Safety award');
      expect(find.text('Historical name'), findsOneWidget);
      expect(find.text('H-001'), findsOneWidget);
      expect(find.text('Download'), findsNothing);
      await tap(tester, 'All certificates');
      expect(
        GoRouterState.of(tester.element(find.byType(CertificateListScreen)))
            .uri
            .path,
        '/profile/certificates',
      );
    },
  );

  testWidgets('revoked certificate remains viewable and clearly marked', (
    tester,
  ) async {
    when(
      () => certificates.getCertificateDetail(
        8,
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenAnswer((_) async => detail(revoked: true));
    await open(tester, '/profile/certificates/8');
    expect(find.text('Revoked'), findsOneWidget);
    expect(find.text('Revoked on'), findsOneWidget);
  });

  testWidgets('empty certificate list and network recovery are usable', (
    tester,
  ) async {
    when(
      () =>
          certificates.getCertificates(cancelToken: any(named: 'cancelToken')),
    ).thenThrow(ApiError.networkFailure());
    await open(tester, '/profile/certificates');
    expect(find.text(ApiError.networkFailure().message), findsOneWidget);
    when(
      () =>
          certificates.getCertificates(cancelToken: any(named: 'cancelToken')),
    ).thenAnswer((_) async => []);
    await tap(tester, 'Retry');
    expect(find.textContaining('No certificates earned yet.'), findsOneWidget);
  });

  testWidgets(
    'certificate 403 renders a controlled permission error without historical data',
    (tester) async {
      when(
        () => certificates.getCertificateDetail(
          8,
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenThrow(ApiError(message: 'Not permitted.', statusCode: 403));
      await open(tester, '/profile/certificates/8');
      expect(find.text('Not permitted.'), findsOneWidget);
      expect(find.text('Historical name'), findsNothing);
    },
  );

  testWidgets(
    'Profile entry, Dashboard summary and completed assignment navigate to certificates',
    (tester) async {
      await open(tester, '/profile');
      await tap(tester, 'My Certificates');
      expect(
        GoRouterState.of(tester.element(find.byType(CertificateListScreen)))
            .uri
            .path,
        '/profile/certificates',
      );
      router.go('/dashboard');
      await tester.pumpAndSettle();
      await tap(tester, 'Safety award');
      expect(
        GoRouterState.of(tester.element(find.byType(CertificateDetailScreen)))
            .uri
            .path,
        '/profile/certificates/8',
      );
      router.go('/learning/assignments/1');
      await tester.pumpAndSettle();
      await tap(tester, 'My Certificates');
      expect(
        GoRouterState.of(tester.element(find.byType(CertificateListScreen)))
            .uri
            .path,
        '/profile/certificates',
      );
    },
  );

  testWidgets('assignment and module learning expose assessment navigation', (
    tester,
  ) async {
    await open(tester, '/learning/assignments/1');
    await tap(tester, 'Assessments and attempts');
    expect(find.byType(AssessmentOverviewScreen), findsOneWidget);
    router.go('/learning/assignments/1/modules/4/lessons');
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Module assessments'));
    await tester.pumpAndSettle();
    expect(
      GoRouterState.of(tester.element(find.byType(AssessmentOverviewScreen)))
          .uri
          .queryParameters['module'],
      '4',
    );
  });

  for (final path in [
    '/profile/certificates/0',
    '$overviewPath/0/attempt',
    '$overviewPath/2/attempts/nope',
  ]) {
    testWidgets('malformed route is controlled: $path', (tester) async {
      await open(tester, path);
      expect(find.text('Invalid ID'), findsOneWidget);
      verifyNever(
        () => assessments.startOrResume(
          any(),
          any(),
          cancelToken: any(named: 'cancelToken'),
        ),
      );
    });
  }

  testWidgets(
    'logout during a pending request hides data and late results cannot reopen it',
    (tester) async {
      final pending = Completer<AssessmentAttempt>();
      when(
        () => assessments.startOrResume(
          1,
          2,
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer((_) => pending.future);
      // Loading indicators animate continuously, so do not pumpAndSettle here.
      final setup = open(tester, overviewPath);
      await setup;
      router.go(attemptPath);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      auth.change(AuthUnauthenticated());
      await tester.pumpAndSettle();
      pending.complete(attempt());
      await tester.pumpAndSettle();
      expect(find.byType(LoginScreen), findsOneWidget);
      expect(find.text('Wear PPE?'), findsNothing);
    },
  );

  testWidgets(
    'account switching replaces certificate data and ignores old in-flight response',
    (tester) async {
      final oldRequest = Completer<CertificateDetail>();
      await open(tester, '/profile/certificates');
      when(
        () => certificates.getCertificateDetail(
          8,
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer((_) => oldRequest.future);
      router.go('/profile/certificates/8');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      when(
        () => certificates.getCertificateDetail(
          8,
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenThrow(
        ApiError(message: 'Not found for this employee.', statusCode: 404),
      );
      auth.change(AuthAuthenticated(_employee('B')));
      await tester.pumpAndSettle();
      oldRequest.complete(detail());
      await tester.pumpAndSettle();
      expect(find.text('Historical name'), findsNothing);
      expect(find.text('Not found for this employee.'), findsOneWidget);
    },
  );

  testWidgets(
    'failed result badge retains readable contrast over the cinematic hero',
    (tester) async {
      final result = attemptJson(status: 'SUBMITTED', passed: false)
        ..['certificate_id'] = null;
      when(
        () => assessments.getAttempt(7, cancelToken: any(named: 'cancelToken')),
      ).thenAnswer((_) async => AssessmentAttempt.fromJson(result));
      await open(tester, '$overviewPath/2/attempts/7');
      final badge = find.byType(StatusBadge);
      final label = tester.widget<Text>(
        find.descendant(of: badge, matching: find.byType(Text)),
      );
      final tint =
          (tester
                      .widget<Container>(
                        find.descendant(
                          of: badge,
                          matching: find.byType(Container),
                        ),
                      )
                      .decoration!
                  as BoxDecoration)
              .color!;
      final backing =
          tester
                  .widgetList<DecoratedBox>(
                    find.ancestor(
                      of: badge,
                      matching: find.byType(DecoratedBox),
                    ),
                  )
                  .first
                  .decoration
              as BoxDecoration;
      // A badge must remain legible across the full hero gradient, including its
      // darkest stop, rather than assuming the page background shows through.
      final background = Color.alphaBlend(
        tint,
        backing.color ?? (backing.gradient! as LinearGradient).colors.first,
      );
      final values = [
        label.style!.color!.computeLuminance(),
        background.computeLuminance(),
      ]..sort();
      expect(
        (values.last + .05) / (values.first + .05),
        greaterThanOrEqualTo(4.5),
      );
    },
  );

  for (final dark in [false, true]) {
    testWidgets(
      '${dark ? 'dark' : 'light'} pages fit small width/large text with reduced motion',
      (tester) async {
        tester.view.physicalSize = const Size(360, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await open(
          tester,
          overviewPath,
          dark: dark,
          scale: 1.8,
          reducedMotion: true,
        );
        expect(
          Theme.of(tester.element(find.byType(AssessmentOverviewScreen)))
              .brightness,
          dark ? Brightness.dark : Brightness.light,
        );
        final media = MediaQuery.of(
          tester.element(find.byType(AssessmentOverviewScreen)),
        );
        expect(media.disableAnimations, isTrue);
        expect(media.textScaler.scale(10), 18);
        expect(tester.takeException(), isNull);
        router.go(attemptPath);
        await tester.pumpAndSettle();
        expect(find.text('Wear PPE?'), findsOneWidget);
        expect(
          Theme.of(tester.element(find.byType(AssessmentAttemptScreen)))
              .brightness,
          dark ? Brightness.dark : Brightness.light,
        );
        expect(tester.takeException(), isNull);
        router.go('/profile/certificates/8');
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(
          find.text('Historical name'),
          180,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pumpAndSettle();
        expect(find.text('Historical name'), findsOneWidget);
        expect(
          Theme.of(tester.element(find.byType(CertificateDetailScreen)))
              .brightness,
          dark ? Brightness.dark : Brightness.light,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'MyApp follows live system theme changes without resetting answers or refetching identity data',
    (tester) async {
      await open(tester, attemptPath);
      final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
      expect(app.themeMode, ThemeMode.system);
      expect(app.darkTheme?.brightness, Brightness.dark);
      await tap(tester, 'Yes');
      final provider = assessmentAttemptProvider((
        assignmentId: 1,
        assessmentId: 2,
      ));
      final selectedState = container.read(provider);
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
      await tester.pumpAndSettle();
      final context = tester.element(find.byType(AssessmentAttemptScreen));
      expect(Theme.of(context).brightness, Brightness.dark);
      final selected = tester.widget<OutlinedButton>(
        find.widgetWithText(OutlinedButton, 'Yes'),
      );
      expect(
        selected.style!.backgroundColor!.resolve({}),
        Theme.of(context).colorScheme.primaryContainer,
      );
      expect(
        selected.style!.foregroundColor!.resolve({}),
        Theme.of(context).colorScheme.onPrimaryContainer,
      );
      expect(identical(container.read(provider), selectedState), isTrue);
      verify(
        () => assessments.startOrResume(
          1,
          2,
          cancelToken: any(named: 'cancelToken'),
        ),
      ).called(1);

      router.go('/profile/certificates/8');
      await tester.pumpAndSettle();
      final certificateState = container
          .read(certificateDetailProvider(8))
          .asData!
          .value;
      expect(
        Theme.of(tester.element(find.byType(CertificateDetailScreen)))
            .brightness,
        Brightness.dark,
      );
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
      await tester.pumpAndSettle();
      expect(
        Theme.of(tester.element(find.byType(CertificateDetailScreen)))
            .brightness,
        Brightness.light,
      );
      expect(
        identical(
          container.read(certificateDetailProvider(8)).asData!.value,
          certificateState,
        ),
        isTrue,
      );
      expect(find.text('Historical name'), findsOneWidget);
      verify(
        () => certificates.getCertificateDetail(
          8,
          cancelToken: any(named: 'cancelToken'),
        ),
      ).called(1);
    },
  );

  for (final dark in [false, true]) {
    testWidgets(
      'MyApp ${dark ? 'dark' : 'light'} mode renders issued, revoked and error states',
      (tester) async {
        await open(tester, '/profile/certificates', dark: dark);
        final brightness = dark ? Brightness.dark : Brightness.light;
        expect(
          Theme.of(tester.element(find.byType(CertificateListScreen)))
              .brightness,
          brightness,
        );
        expect(find.textContaining('Issued'), findsOneWidget);
        when(
          () => certificates.getCertificateDetail(
            8,
            cancelToken: any(named: 'cancelToken'),
          ),
        ).thenAnswer((_) async => detail(revoked: true));
        await tap(tester, 'Safety award');
        expect(find.text('Revoked'), findsOneWidget);
        expect(
          Theme.of(tester.element(find.byType(CertificateDetailScreen)))
              .brightness,
          brightness,
        );
        when(
          () => assessments.getAssessments(
            1,
            cancelToken: any(named: 'cancelToken'),
          ),
        ).thenThrow(ApiError.networkFailure());
        router.go(overviewPath);
        await tester.pumpAndSettle();
        expect(find.text(ApiError.networkFailure().message), findsOneWidget);
        expect(
          Theme.of(tester.element(find.byType(AssessmentOverviewScreen)))
              .brightness,
          brightness,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'retry is offered only through freshly loaded server eligibility',
    (tester) async {
      catalog['assessments'][0].addAll({
        'can_start': true,
        'can_resume': false,
        'ongoing_attempt_id': null,
        'attempts': [summaryJson(status: 'SUBMITTED', passed: false)],
      });
      when(
        () => assessments.getAttempt(7, cancelToken: any(named: 'cancelToken')),
      ).thenAnswer((_) async => attempt(status: 'SUBMITTED', passed: false));
      await open(tester, '$overviewPath/2/attempts/7');
      expect(find.text('Not passed'), findsOneWidget);
      await tap(tester, 'Review eligibility and attempts');
      await tap(tester, 'Start assessment');
      expect(find.text('Wear PPE?'), findsOneWidget);
      verify(
        () => assessments.startOrResume(
          1,
          2,
          cancelToken: any(named: 'cancelToken'),
        ),
      ).called(1);
    },
  );

  testWidgets('empty assessment catalog does not create an attempt', (
    tester,
  ) async {
    catalog['assessments'] = [];
    await open(tester, overviewPath);
    expect(find.text('No assessments available here.'), findsOneWidget);
    verifyNever(
      () => assessments.startOrResume(
        any(),
        any(),
        cancelToken: any(named: 'cancelToken'),
      ),
    );
  });

  testWidgets(
    'server-confirmed submission refreshes dashboard, training and certificates',
    (tester) async {
      await open(tester, attemptPath);
      container.listen(dashboardDataProvider, (_, _) {});
      container.listen(assignmentDetailProvider(1), (_, _) {});
      container.listen(assignmentListProvider, (_, _) {});
      container.listen(certificateListProvider, (_, _) {});
      await container.read(dashboardDataProvider.future);
      await container.read(certificateListProvider.future);
      final before = dashboardReads;
      await confirm(tester);
      await container.read(dashboardDataProvider.future);
      await container.read(certificateListProvider.future);
      expect(dashboardReads, greaterThan(before));
      verify(
        () => certificates.getCertificates(
          cancelToken: any(named: 'cancelToken'),
        ),
      ).called(2);
    },
  );

  testWidgets(
    'confirmation cannot submit after the authenticated employee changes',
    (tester) async {
      await open(tester, attemptPath);
      await tap(tester, 'Submit assessment');
      auth.change(AuthAuthenticated(_employee('B')));
      await tester.pumpAndSettle();
      await tap(tester, 'Confirm submission');
      verifyNever(
        () => assessments.submitAttempt(
          any(),
          any(),
          cancelToken: any(named: 'cancelToken'),
        ),
      );
      expect(find.text('Wear PPE?'), findsNothing);
    },
  );

  testWidgets(
    'certificate pages refresh the complete paginated repository result',
    (tester) async {
      final many = List.generate(
        25,
        (i) => Certificate(
          id: i + 10,
          certificateNumber: 'GN-${i + 10}',
          trainingTitle: 'Award $i',
          versionNumber: 1,
          issuedAt: DateTime(2026),
          isRevoked: i == 24,
        ),
      );
      when(
        () => certificates.getCertificates(
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer((_) async => many);
      await open(tester, '/profile/certificates');
      await tester.scrollUntilVisible(
        find.text('Award 24'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      expect(find.text('REVOKED'), findsOneWidget);
    },
  );

  testWidgets('question controls have labeled accessible touch targets', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await open(tester, attemptPath);
    try {
      await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
    } finally {
      semantics.dispose();
    }
  });

  testWidgets(
    'assessment and certificate states fit landscape including network errors',
    (tester) async {
      tester.view.physicalSize = const Size(800, 360);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await open(tester, attemptPath);
      expect(tester.takeException(), isNull);
      when(
        () => certificates.getCertificateDetail(
          8,
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenThrow(ApiError.networkFailure());
      router.go('/profile/certificates/8');
      await tester.pumpAndSettle();
      expect(find.text(ApiError.networkFailure().message), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  for (final dark in [false, true]) {
    for (final (size, scale) in [
      (const Size(320, 640), 2.0),
      (const Size(390, 844), 1.0),
      (const Size(844, 390), 1.4),
    ]) {
      testWidgets(
        'cinematic ${dark ? 'dark' : 'light'} Batch 2 fits $size at ${scale}x',
        (tester) async {
          tester.view.physicalSize = size;
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final json = attemptJson();
          json['questions'][0]['prompt'] = 'Before operating equipment, how should you respond to a newly identified hazard in your working area?';
          json['questions'][0]['options'][0]['text'] =
              'Stop and report the hazard before continuing with the task.';
          when(
            () => assessments.startOrResume(
              1,
              2,
              cancelToken: any(named: 'cancelToken'),
            ),
          ).thenAnswer((_) async => AssessmentAttempt.fromJson(json));

          Future<void> sweep() async {
            expect(tester.takeException(), isNull);
            final scroll = find.byType(Scrollable).first;
            for (var step = 0; step < 30; step++) {
              final position = tester.state<ScrollableState>(scroll).position;
              if (position.pixels >= position.maxScrollExtent) break;
              await tester.drag(scroll, const Offset(0, -400));
              await tester.pumpAndSettle();
              expect(tester.takeException(), isNull);
            }
          }

          await open(
            tester,
            attemptPath,
            dark: dark,
            scale: scale,
            reducedMotion: true,
          );
          await sweep();
          await tap(
            tester,
            json['questions'][0]['options'][0]['text'] as String,
          );
          expect(find.text('1 of 1 answered'), findsOneWidget);
          await tap(tester, 'Submit assessment');
          expect(find.text('Submit assessment?'), findsOneWidget);
          expect(tester.takeException(), isNull);
          await tap(tester, 'Keep working');
          verifyNever(
            () => assessments.submitAttempt(
              any(),
              any(),
              cancelToken: any(named: 'cancelToken'),
            ),
          );

          for (final passed in [false, true]) {
            router.go(overviewPath);
            await tester.pumpAndSettle();
            final result = attemptJson(status: 'SUBMITTED', passed: passed);
            if (!passed) {
              result['certificate_id'] = null;
              result['assignment_status'] = 'IN_PROGRESS';
            }
            when(
              () => assessments.getAttempt(
                7,
                cancelToken: any(named: 'cancelToken'),
              ),
            ).thenAnswer((_) async => AssessmentAttempt.fromJson(result));
            router.go('$overviewPath/2/attempts/7');
            await tester.pumpAndSettle();
            expect(find.text(passed ? 'Passed' : 'Not passed'), findsOneWidget);
            expect(
              find.text(passed ? 'Score: 2.00 / 2.00' : 'Score: 0.00 / 2.00'),
              findsOneWidget,
            );
            await sweep();
            expect(find.text('Submit assessment'), findsNothing);
          }

          final item = catalog['assessments'][0];
          item['can_resume'] = false;
          item['ongoing_attempt_id'] = null;
          item['attempts_remaining'] = 0;
          item['attempts_used'] = 3;
          item['blocking_reason'] = 'Maximum attempts reached.';
          container.invalidate(assessmentOverviewProvider(1));
          router.go(overviewPath);
          await tester.pumpAndSettle();
          await sweep();
          expect(find.text('NO ATTEMPTS LEFT'), findsOneWidget);
          expect(find.text('Start assessment'), findsNothing);
          expect(find.text('Resume assessment'), findsNothing);

          router.go('/profile/certificates');
          await tester.pumpAndSettle();
          await sweep();
          await tap(tester, 'Safety award');
          await sweep();
          expect(find.text('Historical name'), findsOneWidget);
          when(
            () => certificates.getCertificateDetail(
              8,
              cancelToken: any(named: 'cancelToken'),
            ),
          ).thenAnswer((_) async => detail(revoked: true));
          container.invalidate(certificateDetailProvider(8));
          await tester.pumpAndSettle();
          await sweep();
          expect(find.text('Revoked on'), findsOneWidget);
          expect(find.text('Download'), findsNothing);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
}
