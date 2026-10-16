import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:training_app/core/errors/api_error.dart';
import 'package:training_app/features/assessments/data/repositories/assessment_repository.dart';
import 'package:training_app/features/assessments/domain/models/assessment.dart';
import 'package:training_app/features/assessments/presentation/controllers/assessment_controller.dart';
import 'package:training_app/features/auth/domain/models/auth_state.dart';
import 'package:training_app/features/auth/domain/models/employee.dart';
import 'package:training_app/features/auth/presentation/controllers/auth_controller.dart';

import '../../assessment_fixtures.dart';

class MockRepository extends Mock implements AssessmentRepository {}

class TestAuth extends AuthController {
  @override
  AuthState build() => AuthAuthenticated(employee('A'));
  void change(AuthState auth) => state = auth;
}

Employee employee(String name) => Employee(
  username: name,
  employeeCode: name,
  displayName: name,
  department: 'QA',
  jobRole: 'Learner',
  isActive: true,
);

Future<void> tick() => Future<void>.delayed(Duration.zero);

void main() {
  const target = (assignmentId: 1, assessmentId: 2);
  final provider = assessmentAttemptProvider(target);
  late MockRepository repository;
  late TestAuth auth;
  late ProviderContainer container;
  late AssessmentController controller;
  late ProviderSubscription<AssessmentState> subscription;

  setUpAll(() => registerFallbackValue(CancelToken()));
  setUp(() {
    repository = MockRepository();
    auth = TestAuth();
    when(
      () =>
          repository.getAssessments(1, cancelToken: any(named: 'cancelToken')),
    ).thenAnswer((_) async => AssignmentAssessments.fromJson(catalogJson()));
    when(
      () => repository.startOrResume(
        1,
        2,
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenAnswer((_) async => attempt());
    when(
      () =>
          repository.getAttempt(any(), cancelToken: any(named: 'cancelToken')),
    ).thenAnswer(
      (call) async => attempt(id: call.positionalArguments.first as int),
    );
    when(
      () => repository.submitAttempt(
        7,
        any(),
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenAnswer((_) async => attempt(status: 'SUBMITTED'));
    container = ProviderContainer(
      overrides: [
        assessmentRepositoryProvider.overrideWithValue(repository),
        authControllerProvider.overrideWith(() => auth),
      ],
    );
    addTearDown(container.dispose);
    subscription = container.listen(provider, (_, _) {});
    controller = container.read(provider.notifier);
  });

  test(
    'overview loads, exposes failures and supports explicit read retry',
    () async {
      final overview = assessmentOverviewProvider(1);
      container.listen(overview, (_, _) {});
      expect(
        (await container.read(overview.future))!
            .assessments
            .single
            .eligibility
            .canResume,
        isTrue,
      );
      when(
        () => repository.getAssessments(
          1,
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenThrow(ApiError.networkFailure());
      container.invalidate(overview);
      await expectLater(
        container.read(overview.future),
        throwsA(isA<ApiError>()),
      );
      when(
        () => repository.getAssessments(
          1,
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer((_) async => AssignmentAssessments.fromJson(catalogJson()));
      container.invalidate(overview);
      expect((await container.read(overview.future))!.assignmentId, 1);
    },
  );

  test(
    'start/resume is deduplicated and selection stays local and immutable',
    () async {
      final pending = Completer<AssessmentAttempt>();
      when(
        () => repository.startOrResume(
          1,
          2,
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer((_) => pending.future);
      final first = controller.startOrResume();
      final duplicate = controller.startOrResume();
      expect(container.read(provider).phase, AssessmentPhase.starting);
      pending.complete(attempt());
      await Future.wait([first, duplicate]);
      verify(
        () => repository.startOrResume(
          1,
          2,
          cancelToken: any(named: 'cancelToken'),
        ),
      ).called(1);
      controller.selectAnswer(11, 21);
      expect(container.read(provider).selectedAnswers, {11: 21});
      expect(container.read(provider).attempt!.answers, isEmpty);
      expect(
        () => container.read(provider).selectedAnswers.clear(),
        throwsUnsupportedError,
      );
      expect(() => controller.selectAnswer(99, 21), throwsArgumentError);
      expect(() => controller.selectAnswer(11, 999), throwsArgumentError);
      verifyNever(
        () => repository.submitAttempt(
          any(),
          any(),
          cancelToken: any(named: 'cancelToken'),
        ),
      );
    },
  );

  test('submission snapshots answers, prevents duplicate actions and uses only server result', () async {
    await controller.startOrResume();
    controller.selectAnswer(11, 22);
    final pending = Completer<AssessmentAttempt>();
    when(
      () => repository.submitAttempt(
        7,
        any(),
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenAnswer((_) => pending.future);
    final first = controller.submit();
    final duplicate = controller.submit();
    controller.selectAnswer(11, 21);
    expect(container.read(provider).selectedAnswers, {11: 22});
    expect(container.read(provider).attempt!.summary.passed, isNull);
    pending.complete(attempt(status: 'SUBMITTED', passed: false));
    await Future.wait([first, duplicate]);
    expect(container.read(provider).attempt!.summary.passed, isFalse);
    expect(container.read(provider).selectedAnswers, isEmpty);
    expect(container.read(provider).canSubmit, isFalse);
    await controller.submit();
    await controller.startOrResume();
    verify(
      () => repository.submitAttempt(7, {
        11: 22,
      }, cancelToken: any(named: 'cancelToken')),
    ).called(1);
  });

  for (final error in [
    ApiError.timeout(),
    ApiError.networkFailure(),
    ApiError(message: 'Already submitted', statusCode: 409),
    ApiError(message: 'Server unavailable', statusCode: 503),
  ]) {
    test(
      'uncertain submission ${error.code ?? error.statusCode} reconciles by GET without reposting',
      () async {
        await controller.startOrResume();
        controller.selectAnswer(11, 21);
        when(
          () => repository.submitAttempt(
            7,
            any(),
            cancelToken: any(named: 'cancelToken'),
          ),
        ).thenThrow(error);
        when(
          () =>
              repository.getAttempt(7, cancelToken: any(named: 'cancelToken')),
        ).thenAnswer((_) async => attempt(status: 'SUBMITTED'));
        await controller.submit();
        expect(container.read(provider).attempt!.summary.passed, isTrue);
        verify(
          () => repository.submitAttempt(7, {
            11: 21,
          }, cancelToken: any(named: 'cancelToken')),
        ).called(1);
        verify(
          () =>
              repository.getAttempt(7, cancelToken: any(named: 'cancelToken')),
        ).called(1);
      },
    );
  }

  test(
    'failed reconciliation blocks duplicate posting; retry reads server status',
    () async {
      await controller.startOrResume();
      controller.selectAnswer(11, 21);
      when(
        () => repository.submitAttempt(
          7,
          any(),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenThrow(ApiError.timeout());
      when(
        () => repository.getAttempt(7, cancelToken: any(named: 'cancelToken')),
      ).thenThrow(ApiError.networkFailure());
      await controller.submit();
      expect(container.read(provider).phase, AssessmentPhase.uncertain);
      expect(container.read(provider).canSubmit, isFalse);
      await controller.submit();
      when(
        () => repository.getAttempt(7, cancelToken: any(named: 'cancelToken')),
      ).thenAnswer((_) async => attempt(status: 'EXPIRED', passed: false));
      await controller.retry();
      expect(
        container.read(provider).attempt!.summary.status,
        AttemptStatus.expired,
      );
      verify(
        () => repository.submitAttempt(
          7,
          any(),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).called(1);
    },
  );

  test(
    'HTTP success with ongoing status never becomes a completed result',
    () async {
      await controller.startOrResume();
      when(
        () => repository.submitAttempt(
          7,
          any(),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer((_) async => attempt());
      await controller.submit();
      expect(container.read(provider).attempt!.summary.isClosed, isFalse);
      expect(container.read(provider).attempt!.summary.passed, isNull);
      expect(container.read(provider).error, isA<ApiError>());
    },
  );

  for (final code in [400, 401, 403]) {
    test(
      'submission $code preserves structured errors without automatic repost or reconciliation',
      () async {
        await controller.startOrResume();
        when(
          () => repository.submitAttempt(
            7,
            any(),
            cancelToken: any(named: 'cancelToken'),
          ),
        ).thenThrow(
          ApiError(
            message: 'Denied',
            statusCode: code,
            code: 'controlled',
            details: {
              'answers': ['Invalid'],
            },
          ),
        );
        await controller.submit();
        expect(container.read(provider).error!.statusCode, code);
        if (code != 400) {
          expect(container.read(provider).attempt, isNull);
          expect(container.read(provider).phase, AssessmentPhase.unavailable);
        }
        verifyNever(
          () => repository.getAttempt(
            any(),
            cancelToken: any(named: 'cancelToken'),
          ),
        );
      },
    );
  }

  test(
    'newer loads win even if the older success arrives after a newer failure',
    () async {
      final old = Completer<AssessmentAttempt>();
      when(
        () => repository.getAttempt(7, cancelToken: any(named: 'cancelToken')),
      ).thenAnswer((_) => old.future);
      when(
        () => repository.getAttempt(8, cancelToken: any(named: 'cancelToken')),
      ).thenThrow(ApiError.networkFailure());
      final first = controller.loadAttempt(7);
      await controller.loadAttempt(8);
      old.complete(attempt());
      await first;
      expect(container.read(provider).phase, AssessmentPhase.failed);
      expect(container.read(provider).attempt, isNull);
    },
  );

  test('a mismatched assignment or attempt ID is never accepted', () async {
    when(() => repository.getAttempt(7, cancelToken: any(named: 'cancelToken')))
        .thenAnswer((_) async => attempt(assignmentId: 99));
    await controller.loadAttempt(7);
    expect(container.read(provider).attempt, isNull);
    expect(container.read(provider).phase, AssessmentPhase.failed);
    when(() => repository.getAttempt(7, cancelToken: any(named: 'cancelToken')))
        .thenAnswer((_) async => attempt(id: 8));
    await controller.loadAttempt(7);
    expect(container.read(provider).attempt, isNull);
  });

  test(
    'logout and A to B to A switching cancel requests and clear drafts/results',
    () async {
      await controller.startOrResume();
      controller.selectAnswer(11, 21);
      final pending = Completer<AssessmentAttempt>();
      CancelToken? token;
      when(
        () => repository.submitAttempt(
          7,
          any(),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer((call) {
        token = call.namedArguments[#cancelToken] as CancelToken;
        return pending.future;
      });
      final work = controller.submit();
      auth.change(AuthLoading());
      expect(container.read(provider).attempt, isNull);
      expect(container.read(provider).selectedAnswers, isEmpty);
      expect(token!.isCancelled, isTrue);
      auth.change(AuthAuthenticated(employee('B')));
      auth.change(AuthAuthenticated(employee('A')));
      pending.complete(attempt(status: 'SUBMITTED'));
      await work;
      expect(container.read(provider).attempt, isNull);
      expect(container.read(provider).phase, AssessmentPhase.idle);
      auth.change(AuthUnauthenticated());
      await controller.startOrResume();
      expect(container.read(provider).phase, AssessmentPhase.unavailable);
    },
  );

  test(
    'overview clears cached and in-flight data on account switching and logout',
    () async {
      final overview = assessmentOverviewProvider(1);
      final old = Completer<AssignmentAssessments>();
      final next = Completer<AssignmentAssessments>();
      var calls = 0;
      when(
        () => repository.getAssessments(
          1,
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer((_) => ++calls == 1 ? old.future : next.future);
      container.listen(overview, (_, _) {});
      await tick();
      auth.change(AuthAuthenticated(employee('B')));
      expect(container.read(overview).value, isNull);
      await tick();
      old.complete(AssignmentAssessments.fromJson(catalogJson()));
      await tick();
      expect(container.read(overview).value, isNull);
      next.complete(AssignmentAssessments.fromJson(catalogJson()));
      await container.read(overview.future);
      auth.change(AuthUnauthenticated());
      expect(container.read(overview).value, isNull);
      await expectLater(
        container.read(overview.future),
        throwsA(isA<ApiError>()),
      );
    },
  );

  test(
    'disposal cancels in-flight work and ignores its later response',
    () async {
      final pending = Completer<AssessmentAttempt>();
      CancelToken? token;
      when(
        () => repository.startOrResume(
          1,
          2,
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer((call) {
        token = call.namedArguments[#cancelToken] as CancelToken;
        return pending.future;
      });
      final work = controller.startOrResume();
      container.dispose();
      expect(token!.isCancelled, isTrue);
      pending.complete(attempt());
      await work;
    },
  );

  test('start timeout permits explicit resume retry without automatic duplicate starts', () async {
    when(
      () => repository.startOrResume(
        1,
        2,
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenThrow(ApiError.timeout());
    await controller.startOrResume();
    expect(container.read(provider).phase, AssessmentPhase.failed);
    verify(
      () => repository.startOrResume(
        1,
        2,
        cancelToken: any(named: 'cancelToken'),
      ),
    ).called(1);
    when(
      () => repository.startOrResume(
        1,
        2,
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenAnswer((_) async => attempt());
    await controller.retry();
    expect(container.read(provider).attempt!.summary.id, 7);
  });

  test('navigation during submission still reconciles and refreshes overview cache', () async {
    final overview = assessmentOverviewProvider(1);
    container.listen(overview, (_, _) {});
    await container.read(overview.future);
    await controller.startOrResume();
    await container.read(overview.future);
    final pending = Completer<AssessmentAttempt>();
    CancelToken? token;
    when(
      () => repository.submitAttempt(
        7,
        any(),
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenAnswer((call) {
      token = call.namedArguments[#cancelToken] as CancelToken;
      return pending.future;
    });
    final work = controller.submit();
    subscription.close();
    await tick();
    expect(token!.isCancelled, isFalse);
    pending.complete(attempt(status: 'SUBMITTED'));
    await work;
    await container.read(overview.future);
    verify(
      () =>
          repository.getAssessments(1, cancelToken: any(named: 'cancelToken')),
    ).called(3);
  });

  test(
    'switching history attempts clears old drafts and retries the requested ID',
    () async {
      await controller.loadAttempt(7);
      controller.selectAnswer(11, 21);
      when(
        () => repository.getAttempt(8, cancelToken: any(named: 'cancelToken')),
      ).thenThrow(ApiError.networkFailure());
      await controller.loadAttempt(8);
      expect(container.read(provider).attempt, isNull);
      expect(container.read(provider).selectedAnswers, isEmpty);
      when(
        () => repository.getAttempt(8, cancelToken: any(named: 'cancelToken')),
      ).thenAnswer((_) async => attempt(id: 8, status: 'SUBMITTED'));
      await controller.retry();
      expect(container.read(provider).attempt!.summary.id, 8);
      verifyNever(
        () => repository.startOrResume(
          any(),
          any(),
          cancelToken: any(named: 'cancelToken'),
        ),
      );
    },
  );

  test(
    'permission denial during overview refresh clears previous account data',
    () async {
      final overview = assessmentOverviewProvider(1);
      container.listen(overview, (_, _) {});
      await container.read(overview.future);
      when(
        () => repository.getAssessments(
          1,
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenThrow(ApiError(message: 'Employee inactive', statusCode: 403));
      container.invalidate(overview);
      // Access clearing can settle a pending nullable future before its error
      // notification. Verify that the failure remains observable afterward.
      await container.read(overview.future);
      await tick();
      expect(
        container.read(overview).error,
        isA<ApiError>().having((error) => error.statusCode, 'status', 403),
      );
      await expectLater(
        container.read(overview.future),
        throwsA(isA<ApiError>()),
      );
      expect(container.read(overview).value, isNull);
    },
  );
}
