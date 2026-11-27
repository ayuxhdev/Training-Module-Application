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
import 'package:training_app/core/presentation/formatters/date_labels.dart';
import 'package:training_app/features/assessments/data/repositories/assessment_repository.dart';
import 'package:training_app/features/assessments/domain/models/assessment.dart';
import 'package:training_app/features/assessments/presentation/controllers/assessment_controller.dart';
import 'package:training_app/features/assessments/presentation/screens/assessment_attempt_screen.dart';
import 'package:training_app/features/assessments/presentation/screens/assessment_overview_screen.dart';
import 'package:training_app/features/auth/domain/models/auth_state.dart';
import 'package:training_app/features/auth/domain/models/employee.dart';
import 'package:training_app/features/auth/presentation/controllers/auth_controller.dart';

import '../../assessment_fixtures.dart';

class _MockAssessmentRepository extends Mock implements AssessmentRepository {}

class _TestAuthController extends AuthController {
  @override
  AuthState build() => AuthAuthenticated(_testEmployee('Tester'));

  void setAuth(AuthState next) => state = next;
}

Employee _testEmployee(String code) => Employee(
  username: code,
  employeeCode: code,
  displayName: 'Employee $code',
  department: 'Safety',
  jobRole: 'Technician',
  isActive: true,
);

void main() {
  late _MockAssessmentRepository repository;
  late _TestAuthController authController;
  late ProviderContainer container;

  const target = (assignmentId: 1, assessmentId: 2);

  setUpAll(() => registerFallbackValue(CancelToken()));

  setUp(() {
    repository = _MockAssessmentRepository();
    authController = _TestAuthController();
  });

  Widget buildTestApp({
    required Widget child,
    List<RouteBase> routes = const [],
    String initialLocation = '/',
  }) {
    container = ProviderContainer(
      overrides: [
        assessmentRepositoryProvider.overrideWithValue(repository),
        authControllerProvider.overrideWith(() => authController),
      ],
    );

    final router = GoRouter(
      initialLocation: initialLocation,
      routes: [
        GoRoute(path: '/', builder: (context, state) => child),
        ...routes,
      ],
    );

    return UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(routerConfig: router),
    );
  }

  Future<void> scrollAndTap(WidgetTester tester, Finder finder) async {
    if (finder.evaluate().isEmpty) {
      await tester.scrollUntilVisible(
        finder,
        200,
        scrollable: find.byType(Scrollable).first,
      );
    }
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  group('Assessment workflow hardening & negative regressions', () {
    testWidgets(
      'displays "Submitting your assessment…" loading message during submission phase',
      (tester) async {
        tester.view.physicalSize = const Size(800, 2000);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final submissionCompleter = Completer<AssessmentAttempt>();
        when(
          () => repository.startOrResume(
            1,
            2,
            cancelToken: any(named: 'cancelToken'),
          ),
        ).thenAnswer((_) async => attempt(id: 7));
        when(
          () => repository.submitAttempt(
            7,
            any(),
            cancelToken: any(named: 'cancelToken'),
          ),
        ).thenAnswer((_) => submissionCompleter.future);

        await tester.pumpWidget(
          buildTestApp(child: const AssessmentAttemptScreen(target: target)),
        );
        await tester.pumpAndSettle();

        // Select an option to enable submission
        await tester.tap(find.text('Yes'));
        await tester.pumpAndSettle();

        // Tap submit assessment
        await scrollAndTap(tester, find.text('Submit assessment'));

        // Tap confirm in dialog
        await tester.tap(find.text('Confirm submission'));
        await tester
            .pump(); // Start submission mutation without completing future

        expect(find.byType(LoadingView), findsOneWidget);
        expect(find.text('Submitting your assessment…'), findsOneWidget);

        submissionCompleter.complete(attempt(id: 7, status: 'SUBMITTED'));
        await tester.pumpAndSettle();

        expect(find.text('Assessment result'), findsOneWidget);
      },
    );

    testWidgets(
      'displays "Checking submission with the server…" loading message during reconciliation phase',
      (tester) async {
        tester.view.physicalSize = const Size(800, 2000);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final reconcileCompleter = Completer<AssessmentAttempt>();
        when(
          () => repository.startOrResume(
            1,
            2,
            cancelToken: any(named: 'cancelToken'),
          ),
        ).thenAnswer((_) async => attempt(id: 7));
        when(
          () => repository.submitAttempt(
            7,
            any(),
            cancelToken: any(named: 'cancelToken'),
          ),
        ).thenThrow(ApiError.timeout());
        when(
          () =>
              repository.getAttempt(7, cancelToken: any(named: 'cancelToken')),
        ).thenAnswer((_) => reconcileCompleter.future);

        await tester.pumpWidget(
          buildTestApp(child: const AssessmentAttemptScreen(target: target)),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.text('Yes'));
        await tester.pumpAndSettle();

        await scrollAndTap(tester, find.text('Submit assessment'));

        await tester.tap(find.text('Confirm submission'));
        await tester
            .pump(); // Enter submitting -> catch timeout -> enter reconciling

        expect(find.byType(LoadingView), findsOneWidget);
        expect(
          find.text('Checking submission with the server…'),
          findsOneWidget,
        );

        reconcileCompleter.complete(attempt(id: 7, status: 'SUBMITTED'));
        await tester.pumpAndSettle();

        expect(find.text('Assessment result'), findsOneWidget);
      },
    );

    testWidgets(
      'result view formats submitted date with localDateLabel and does not leak raw microseconds',
      (tester) async {
        tester.view.physicalSize = const Size(800, 2000);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final submittedDate = DateTime.utc(2026, 11, 16, 14, 30, 45, 123, 456);
        final closedAttempt = AssessmentAttempt.fromJson(
          attemptJson(status: 'SUBMITTED', passed: true)
            ..['submitted_at'] = submittedDate.toIso8601String(),
        );

        when(
          () =>
              repository.getAttempt(7, cancelToken: any(named: 'cancelToken')),
        ).thenAnswer((_) async => closedAttempt);

        await tester.pumpWidget(
          buildTestApp(
            child: const AssessmentAttemptScreen(target: target, attemptId: 7),
          ),
        );
        await tester.pumpAndSettle();

        final expectedDateStr = 'Submitted: ${localDateLabel(submittedDate)}';
        expect(find.text(expectedDateStr), findsOneWidget);
        // Ensure raw microsecond string is not printed
        expect(find.textContaining('123456'), findsNothing);
      },
    );

    testWidgets(
      'zero attempts remaining displays clear notice when no blocking reason is provided',
      (tester) async {
        tester.view.physicalSize = const Size(800, 2000);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final zeroAttemptsCatalog = {
          'assignment_id': 1,
          'training_version_id': 3,
          'assessments': [
            {
              'id': 2,
              'kind': 'QUIZ',
              'module_id': 4,
              'title': 'Safety Quiz',
              'sequence': 1,
              'is_required': true,
              'pass_percentage': '80.00',
              'time_limit_minutes': 15,
              'max_attempts': 3,
              'attempts_used': 3,
              'attempts_remaining': 0,
              'ongoing_attempt_id': null,
              'passed': false,
              'completed': false,
              'can_start': false,
              'can_resume': false,
              'blocking_reason': null,
              'attempts': [
                summaryJson(id: 1, status: 'SUBMITTED', passed: false),
                summaryJson(id: 2, status: 'SUBMITTED', passed: false),
                summaryJson(id: 3, status: 'SUBMITTED', passed: false),
              ],
            },
          ],
        };

        when(
          () => repository.getAssessments(
            1,
            cancelToken: any(named: 'cancelToken'),
          ),
        ).thenAnswer(
          (_) async => AssignmentAssessments.fromJson(zeroAttemptsCatalog),
        );

        await tester.pumpWidget(
          buildTestApp(child: const AssessmentOverviewScreen(assignmentId: 1)),
        );
        await tester.pumpAndSettle();

        expect(find.text('NO ATTEMPTS LEFT'), findsOneWidget);
        expect(
          find.text(
            'You have reached the maximum attempt limit for this assessment.',
          ),
          findsOneWidget,
        );
        expect(find.text('Start assessment'), findsNothing);
        expect(find.text('Resume assessment'), findsNothing);
      },
    );

    testWidgets(
      'canceling submission dialog preserves user choice selections',
      (tester) async {
        tester.view.physicalSize = const Size(800, 2000);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        when(
          () => repository.startOrResume(
            1,
            2,
            cancelToken: any(named: 'cancelToken'),
          ),
        ).thenAnswer((_) async => attempt(id: 7));

        await tester.pumpWidget(
          buildTestApp(child: const AssessmentAttemptScreen(target: target)),
        );
        await tester.pumpAndSettle();

        // Select 'Yes'
        await tester.tap(find.text('Yes'));
        await tester.pumpAndSettle();

        // Open submission dialog
        await scrollAndTap(tester, find.text('Submit assessment'));

        expect(find.text('Submit assessment?'), findsOneWidget);

        // Tap 'Keep working'
        await tester.tap(find.text('Keep working'));
        await tester.pumpAndSettle();

        // Dialog should be dismissed and selection retained
        expect(find.text('Submit assessment?'), findsNothing);
        expect(find.text('1 of 1 answered'), findsOneWidget);
        verifyNever(
          () => repository.submitAttempt(
            any(),
            any(),
            cancelToken: any(named: 'cancelToken'),
          ),
        );
      },
    );

    testWidgets(
      'unauthorized 401 on attempt start displays ApiErrorView and clears attempt state',
      (tester) async {
        tester.view.physicalSize = const Size(800, 2000);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        when(
          () => repository.startOrResume(
            1,
            2,
            cancelToken: any(named: 'cancelToken'),
          ),
        ).thenThrow(ApiError(message: 'Session expired', statusCode: 401));

        await tester.pumpWidget(
          buildTestApp(child: const AssessmentAttemptScreen(target: target)),
        );
        await tester.pumpAndSettle();

        expect(find.byType(ApiErrorView), findsOneWidget);
        expect(find.text('Session expired'), findsOneWidget);
        // Questions or options should not be displayed
        expect(find.text('Question 1 of 1'), findsNothing);
      },
    );

    testWidgets(
      'forbidden 403 on attempt load displays ApiErrorView and masks questions',
      (tester) async {
        tester.view.physicalSize = const Size(800, 2000);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        when(
          () =>
              repository.getAttempt(7, cancelToken: any(named: 'cancelToken')),
        ).thenThrow(ApiError(message: 'Access restricted', statusCode: 403));

        await tester.pumpWidget(
          buildTestApp(
            child: const AssessmentAttemptScreen(target: target, attemptId: 7),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.byType(ApiErrorView), findsOneWidget);
        expect(find.text('Access restricted'), findsOneWidget);
        expect(find.text('Question 1 of 1'), findsNothing);
      },
    );

    testWidgets('switching to a different attempt resets question index to 0', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(800, 2000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final multiQuestionAttempt = AssessmentAttempt.fromJson(
        attemptJson(id: 7)
          ..['questions'] = [
            {
              'id': 11,
              'position': 1,
              'points': '1.00',
              'prompt': 'First question',
              'type': 'SINGLE_CHOICE',
              'options': [
                {'id': 21, 'position': 1, 'text': 'Option A'},
                {'id': 22, 'position': 2, 'text': 'Option B'},
              ],
            },
            {
              'id': 12,
              'position': 2,
              'points': '1.00',
              'prompt': 'Second question',
              'type': 'SINGLE_CHOICE',
              'options': [
                {'id': 23, 'position': 1, 'text': 'Option C'},
                {'id': 24, 'position': 2, 'text': 'Option D'},
              ],
            },
          ],
      );

      final secondAttempt = AssessmentAttempt.fromJson(
        attemptJson(id: 8)
          ..['questions'] = [
            {
              'id': 13,
              'position': 1,
              'points': '1.00',
              'prompt': 'New attempt first question',
              'type': 'SINGLE_CHOICE',
              'options': [
                {'id': 25, 'position': 1, 'text': 'Option X'},
                {'id': 26, 'position': 2, 'text': 'Option Y'},
              ],
            },
          ],
      );

      when(
        () => repository.getAttempt(7, cancelToken: any(named: 'cancelToken')),
      ).thenAnswer((_) async => multiQuestionAttempt);

      when(
        () => repository.getAttempt(8, cancelToken: any(named: 'cancelToken')),
      ).thenAnswer((_) async => secondAttempt);

      await tester.pumpWidget(
        buildTestApp(
          child: const AssessmentAttemptScreen(target: target, attemptId: 7),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Question 1 of 2'), findsOneWidget);
      expect(find.text('First question'), findsOneWidget);

      // Navigate to question 2
      await tester.tap(find.text('Next'));
      await tester.pumpAndSettle();

      expect(find.text('Question 2 of 2'), findsOneWidget);
      expect(find.text('Second question'), findsOneWidget);

      // Load new attempt 8 via controller
      final controller = container.read(
        assessmentAttemptProvider(target).notifier,
      );
      await controller.loadAttempt(8);
      await tester.pumpAndSettle();

      // Verify question index was reset to 0
      expect(find.text('Question 1 of 1'), findsOneWidget);
      expect(find.text('New attempt first question'), findsOneWidget);
    });
  });
}
