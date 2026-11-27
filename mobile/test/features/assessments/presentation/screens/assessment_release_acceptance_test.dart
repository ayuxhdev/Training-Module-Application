import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';
import 'package:training_app/core/errors/api_error.dart';
import 'package:training_app/features/assessments/data/repositories/assessment_repository.dart';
import 'package:training_app/features/assessments/domain/models/assessment.dart';
import 'package:training_app/features/assessments/presentation/screens/assessment_attempt_screen.dart';
import 'package:training_app/features/auth/domain/models/auth_state.dart';
import 'package:training_app/features/auth/domain/models/employee.dart';
import 'package:training_app/features/auth/presentation/controllers/auth_controller.dart';

import '../../assessment_fixtures.dart';

class _MockAssessmentRepository extends Mock implements AssessmentRepository {}

class _TestAuthController extends AuthController {
  @override
  AuthState build() => AuthAuthenticated(
        Employee(
          username: 'tester',
          employeeCode: 'EMP001',
          displayName: 'Test Operator',
          department: 'Safety',
          jobRole: 'Technician',
          isActive: true,
        ),
      );

  void setAuth(AuthState next) => state = next;
}

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

  group('M17 Assessment Release Acceptance & Reconciliation', () {
    testWidgets('1. HTTP 409 Conflict on submission reconciles via GET and displays server result', (tester) async {
      tester.view.physicalSize = const Size(800, 2000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      when(
        () => repository.startOrResume(1, 2, cancelToken: any(named: 'cancelToken')),
      ).thenAnswer((_) async => attempt(id: 7));

      // Simulate 409 Conflict during submit
      when(
        () => repository.submitAttempt(7, any(), cancelToken: any(named: 'cancelToken')),
      ).thenThrow(ApiError.fromBackend(409, {'detail': 'Conflict: already submitted'}));

      // Reconciliation GET returns graded attempt
      when(
        () => repository.getAttempt(7, cancelToken: any(named: 'cancelToken')),
      ).thenAnswer((_) async => attempt(id: 7, status: 'SUBMITTED', passed: true));

      await tester.pumpWidget(
        buildTestApp(child: const AssessmentAttemptScreen(target: target)),
      );
      await tester.pumpAndSettle();

      // Answer question
      await tester.tap(find.text('Yes'));
      await tester.pumpAndSettle();

      // Submit
      await scrollAndTap(tester, find.text('Submit assessment'));
      await tester.tap(find.text('Confirm submission'));
      await tester.pumpAndSettle();

      // Verified: Attempt reconciled and result displayed
      expect(find.text('Assessment result'), findsOneWidget);
      verify(() => repository.getAttempt(7, cancelToken: any(named: 'cancelToken'))).called(1);
    });

    testWidgets('2. HTTP 500 on submit and failed reconciliation enters uncertain phase without re-submitting', (tester) async {
      tester.view.physicalSize = const Size(800, 2000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      when(
        () => repository.startOrResume(1, 2, cancelToken: any(named: 'cancelToken')),
      ).thenAnswer((_) async => attempt(id: 7));

      when(
        () => repository.submitAttempt(7, any(), cancelToken: any(named: 'cancelToken')),
      ).thenThrow(ApiError.fromBackend(500, {'detail': 'Internal Server Error'}));

      when(
        () => repository.getAttempt(7, cancelToken: any(named: 'cancelToken')),
      ).thenThrow(ApiError.timeout());

      await tester.pumpWidget(
        buildTestApp(child: const AssessmentAttemptScreen(target: target)),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Yes'));
      await tester.pumpAndSettle();

      await scrollAndTap(tester, find.text('Submit assessment'));
      await tester.tap(find.text('Confirm submission'));
      await tester.pumpAndSettle();

      // Verified: Uncertain phase reached with Check attempt status button
      expect(find.text('Check attempt status'), findsOneWidget);
      expect(find.text('Submission is not confirmed. Check its status before trying again.'), findsOneWidget);

      // When user taps "Check attempt status", it executes GET reconciliation, not duplicate submit
      when(
        () => repository.getAttempt(7, cancelToken: any(named: 'cancelToken')),
      ).thenAnswer((_) async => attempt(id: 7, status: 'SUBMITTED', passed: true));

      await tester.tap(find.text('Check attempt status'));
      await tester.pumpAndSettle();

      expect(find.text('Assessment result'), findsOneWidget);
      // Verified: submitAttempt was called exactly once; reconciliation did NOT re-submit answers
      verify(() => repository.submitAttempt(7, any(), cancelToken: any(named: 'cancelToken'))).called(1);
    });

    testWidgets('3. Rapid duplicate submit taps are debounced to a single network mutation', (tester) async {
      tester.view.physicalSize = const Size(800, 2000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final submitCompleter = Completer<AssessmentAttempt>();

      when(
        () => repository.startOrResume(1, 2, cancelToken: any(named: 'cancelToken')),
      ).thenAnswer((_) async => attempt(id: 7));

      when(
        () => repository.submitAttempt(7, any(), cancelToken: any(named: 'cancelToken')),
      ).thenAnswer((_) => submitCompleter.future);

      await tester.pumpWidget(
        buildTestApp(child: const AssessmentAttemptScreen(target: target)),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Yes'));
      await tester.pumpAndSettle();

      await scrollAndTap(tester, find.text('Submit assessment'));

      // Tap confirm twice quickly
      await tester.tap(find.text('Confirm submission'));
      await tester.pump(const Duration(milliseconds: 50));

      // Attempt to tap again if still hit-testable
      final confirmFinder = find.text('Confirm submission');
      if (confirmFinder.evaluate().isNotEmpty) {
        await tester.tap(confirmFinder, warnIfMissed: false);
      }
      await tester.pump();

      // Only one submit request was dispatched
      verify(() => repository.submitAttempt(7, any(), cancelToken: any(named: 'cancelToken'))).called(1);

      submitCompleter.complete(attempt(id: 7, status: 'SUBMITTED'));
      await tester.pumpAndSettle();
      expect(find.text('Assessment result'), findsOneWidget);
    });

    testWidgets('4. Assessment options and prompts render cleanly in portrait 320x640 with large text', (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      when(
        () => repository.startOrResume(1, 2, cancelToken: any(named: 'cancelToken')),
      ).thenAnswer((_) async => attempt(id: 7));

      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(
            size: Size(320, 640),
            textScaler: TextScaler.linear(1.5),
          ),
          child: buildTestApp(child: const AssessmentAttemptScreen(target: target)),
        ),
      );
      await tester.pumpAndSettle();

      // RenderFlex overflow must be null
      expect(tester.takeException(), isNull);
      expect(find.text('Wear PPE?'), findsOneWidget);
      expect(find.text('Yes'), findsOneWidget);
      expect(find.text('No'), findsOneWidget);
    });
  });
}
