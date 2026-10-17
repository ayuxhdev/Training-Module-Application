import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:training_app/core/errors/api_error.dart';
import 'package:training_app/core/presentation/components/api_error_view.dart';
import 'package:training_app/core/presentation/components/error_view.dart';
import 'package:training_app/core/theme/app_theme.dart';
import 'package:training_app/features/auth/domain/models/auth_state.dart';
import 'package:training_app/features/auth/domain/models/employee.dart';
import 'package:training_app/features/auth/presentation/controllers/auth_controller.dart';
import 'package:training_app/features/learning/data/repositories/learning_repository.dart';
import 'package:training_app/features/learning/domain/models/assignment.dart';
import 'package:training_app/features/learning/presentation/screens/learning_screen.dart';

class _Repository extends Mock implements LearningRepository {}

Employee _employee(String name) => Employee(
  username: name,
  employeeCode: name,
  displayName: name,
  department: 'QA',
  jobRole: 'Learner',
  isActive: true,
);

class _Auth extends AuthController {
  int logouts = 0;
  @override
  AuthState build() => AuthAuthenticated(_employee('A'));
  void change(AuthState value) => state = value;
  @override
  Future<void> logout() async {
    logouts++;
    state = AuthUnauthenticated();
  }
}

Assignment _assignment(String title) => Assignment(
  id: 1,
  trainingId: 1,
  trainingTitle: title,
  versionNumber: 1,
  status: 'ASSIGNED',
  isOverdue: false,
  progressSummary: ProgressSummary(
    requiredLessonsCompleted: 0,
    requiredLessonsTotal: 1,
  ),
);

void main() {
  late _Auth auth;
  late _Repository repository;
  late ProviderContainer container;
  setUpAll(() => registerFallbackValue(CancelToken()));
  setUp(() {
    auth = _Auth();
    repository = _Repository();
    container = ProviderContainer(
      overrides: [
        authControllerProvider.overrideWith(() => auth),
        learningRepositoryProvider.overrideWithValue(repository),
      ],
    );
    addTearDown(container.dispose);
  });
  Future<void> show(
    WidgetTester tester,
    Widget child, {
    bool dark = false,
    double scale = 1,
  }) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: dark ? AppTheme.darkTheme : AppTheme.lightTheme,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: TextScaler.linear(scale),
              disableAnimations: true,
            ),
            child: child!,
          ),
          home: Scaffold(body: child),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'network failure shows an explicit retry and recovers to server data',
    (tester) async {
      when(
        () => repository.getAssignments(cancelToken: any(named: 'cancelToken')),
      ).thenThrow(ApiError.networkFailure());
      await show(tester, const LearningScreen());
      expect(find.text('Connection unavailable'), findsOneWidget);
      expect(find.text(ApiError.networkFailure().message), findsOneWidget);
      verify(
        () => repository.getAssignments(cancelToken: any(named: 'cancelToken')),
      ).called(1);
      when(
        () => repository.getAssignments(cancelToken: any(named: 'cancelToken')),
      ).thenAnswer((_) async => [_assignment('Server training')]);
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(find.text('Server training'), findsOneWidget);
    },
  );

  testWidgets(
    'pull refresh failure is rendered without an unhandled async exception',
    (tester) async {
      when(
        () => repository.getAssignments(cancelToken: any(named: 'cancelToken')),
      ).thenAnswer((_) async => [_assignment('Old training')]);
      await show(tester, const LearningScreen());
      when(
        () => repository.getAssignments(cancelToken: any(named: 'cancelToken')),
      ).thenThrow(ApiError.timeout());
      await tester
          .widget<RefreshIndicator>(find.byType(RefreshIndicator))
          .onRefresh();
      await tester.pumpAndSettle();
      expect(find.text('Request timed out'), findsOneWidget);
      expect(find.text('Old training'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'account switch hides old training while pending and on permission denial',
    (tester) async {
      when(
        () => repository.getAssignments(cancelToken: any(named: 'cancelToken')),
      ).thenAnswer((_) async => [_assignment('Private A')]);
      await show(tester, const LearningScreen());
      final next = Completer<List<Assignment>>();
      when(
        () => repository.getAssignments(cancelToken: any(named: 'cancelToken')),
      ).thenAnswer((_) => next.future);
      auth.change(AuthAuthenticated(_employee('B')));
      await tester.pump();
      expect(find.text('Private A'), findsNothing);
      next.completeError(ApiError(message: 'Not allowed.', statusCode: 403));
      await tester.pumpAndSettle();
      expect(find.text('Private A'), findsNothing);
      expect(find.text('Sign in required'), findsOneWidget);
    },
  );

  for (final status in [401, 403]) {
    testWidgets('$status recovery signs out only after explicit user action', (
      tester,
    ) async {
      await show(
        tester,
        ApiErrorView(
          error: ApiError(message: 'Access denied.', statusCode: status),
          onRetry: () => fail('A denied request must not be replayed.'),
        ),
      );
      expect(auth.logouts, 0);
      expect(find.text('Retry'), findsNothing);
      await tester.tap(find.text('Sign in again'));
      await tester.pumpAndSettle();
      expect(auth.logouts, 1);
      expect(
        container.read(authControllerProvider),
        isA<AuthUnauthenticated>(),
      );
    });
  }

  testWidgets(
    'permanent read error has no retry loop and unexpected errors reveal no debug details',
    (tester) async {
      await show(
        tester,
        ApiErrorView(
          error: ApiError(message: 'Unavailable.', statusCode: 404),
          onRetry: () {},
        ),
      );
      expect(find.text('Retry'), findsNothing);
      await show(
        tester,
        ApiErrorView(error: StateError('private diagnostic'), onRetry: () {}),
      );
      expect(find.textContaining('private diagnostic'), findsNothing);
      expect(find.text(ApiError.unexpected().message), findsOneWidget);
    },
  );

  for (final dark in [false, true]) {
    testWidgets(
      'recovery fits 320px landscape and large text in ${dark ? 'dark' : 'light'} mode',
      (tester) async {
        tester.view.physicalSize = const Size(320, 240);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await show(
          tester,
          ApiErrorView(error: ApiError.timeout(), onRetry: () {}),
          dark: dark,
          scale: 2,
        );
        expect(tester.takeException(), isNull);
        expect(
          tester
              .widgetList<Semantics>(find.byType(Semantics))
              .any((s) => s.properties.liveRegion == true),
          isTrue,
        );
        await tester.ensureVisible(find.text('Retry'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Retry'));
        await tester.pumpAndSettle();
        expect(find.byType(ErrorView), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
