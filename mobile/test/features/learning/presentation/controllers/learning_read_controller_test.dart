import 'dart:async';

import 'package:dio/dio.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:training_app/core/errors/api_error.dart';
import 'package:training_app/features/auth/domain/models/auth_state.dart';
import 'package:training_app/features/auth/domain/models/employee.dart';
import 'package:training_app/features/auth/presentation/controllers/auth_controller.dart';
import 'package:training_app/features/learning/data/repositories/learning_repository.dart';
import 'package:training_app/features/learning/domain/models/assignment.dart';
import 'package:training_app/features/learning/domain/models/assignment_detail.dart';
import 'package:training_app/features/learning/presentation/controllers/learning_controller.dart';

class _Repository extends Mock implements LearningRepository {}

class _Auth extends AuthController {
  @override
  AuthState build() => AuthAuthenticated(employee('A'));
  void change(AuthState value) => state = value;
}

Employee employee(String name, {bool active = true}) => Employee(
  username: name,
  employeeCode: name,
  displayName: name,
  department: 'QA',
  jobRole: 'Learner',
  isActive: active,
);
AssignmentDetail detail(String title) => AssignmentDetail(
  id: 1,
  trainingId: 1,
  trainingTitle: title,
  versionNumber: 1,
  status: 'ASSIGNED',
  isOverdue: false,
  modules: [],
);

void main() {
  late _Repository repository;
  late _Auth auth;
  late ProviderContainer container;
  setUpAll(() => registerFallbackValue(CancelToken()));
  setUp(() {
    repository = _Repository();
    auth = _Auth();
    container = ProviderContainer(
      overrides: [
        authControllerProvider.overrideWith(() => auth),
        learningRepositoryProvider.overrideWithValue(repository),
      ],
    );
    addTearDown(container.dispose);
    container.read(authControllerProvider);
  });

  test('assignment detail refetches when account changes and ignores the previous response', () async {
    final old = Completer<AssignmentDetail>();
    final next = Completer<AssignmentDetail>();
    var calls = 0;
    when(
      () => repository.getAssignmentDetail(
        1,
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenAnswer((_) => ++calls == 1 ? old.future : next.future);
    final provider = assignmentDetailProvider(1);
    container.listen(provider, (_, _) {});
    await Future<void>.delayed(Duration.zero);
    auth.change(AuthAuthenticated(employee('B')));
    await Future<void>.delayed(Duration.zero);
    expect(calls, 2);
    old.complete(detail('Private A'));
    await Future<void>.delayed(Duration.zero);
    expect(container.read(provider).asData, isNull);
    next.complete(detail('Owned by B'));
    expect((await container.read(provider.future)).trainingTitle, 'Owned by B');
  });

  test('unauthenticated assignment reads do not make requests', () async {
    auth.change(AuthUnauthenticated());
    when(
      () => repository.getAssignments(cancelToken: any(named: 'cancelToken')),
    ).thenAnswer((_) async => <Assignment>[]);
    container.listen(assignmentListProvider, (_, _) {});
    await expectLater(
      container.read(assignmentListProvider.future),
      throwsA(isA<ApiError>()),
    );
    verifyNever(
      () => repository.getAssignments(cancelToken: any(named: 'cancelToken')),
    );
  });

  test('inactive employees cannot fetch list or detail', () async {
    auth.change(AuthAuthenticated(employee('A', active: false)));
    container.listen(assignmentListProvider, (_, _) {});
    container.listen(assignmentDetailProvider(1), (_, _) {});
    await expectLater(
      container.read(assignmentListProvider.future),
      throwsA(isA<ApiError>()),
    );
    await expectLater(
      container.read(assignmentDetailProvider(1).future),
      throwsA(isA<ApiError>()),
    );
    verifyNever(
      () => repository.getAssignments(cancelToken: any(named: 'cancelToken')),
    );
    verifyNever(
      () => repository.getAssignmentDetail(
        any(),
        cancelToken: any(named: 'cancelToken'),
      ),
    );
  });

  test('logout cancels pending list and detail and late results cannot become current', () async {
    final list = Completer<List<Assignment>>();
    final item = Completer<AssignmentDetail>();
    final tokens = <CancelToken>[];
    when(
      () => repository.getAssignments(cancelToken: any(named: 'cancelToken')),
    ).thenAnswer((call) {
      tokens.add(call.namedArguments[#cancelToken] as CancelToken);
      return list.future;
    });
    when(
      () => repository.getAssignmentDetail(
        1,
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenAnswer((call) {
      tokens.add(call.namedArguments[#cancelToken] as CancelToken);
      return item.future;
    });
    container.listen(assignmentListProvider, (_, _) {});
    container.listen(assignmentDetailProvider(1), (_, _) {});
    await Future<void>.delayed(Duration.zero);
    auth.change(AuthUnauthenticated());
    await expectLater(
      container.read(assignmentListProvider.future),
      throwsA(isA<ApiError>()),
    );
    await expectLater(
      container.read(assignmentDetailProvider(1).future),
      throwsA(isA<ApiError>()),
    );
    expect(tokens.every((token) => token.isCancelled), isTrue);
    list.complete([]);
    item.complete(detail('Private A'));
    await Future<void>.delayed(Duration.zero);
    expect(container.read(assignmentListProvider).asData, isNull);
    expect(container.read(assignmentDetailProvider(1)).asData, isNull);
  });

  test('A to B to A switching rejects an older success after the latest request fails', () async {
    final old = Completer<AssignmentDetail>();
    var calls = 0;
    when(
      () => repository.getAssignmentDetail(
        1,
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenAnswer((_) {
      calls++;
      if (calls == 1) return old.future;
      return Future.error(ApiError(message: 'Not available.', statusCode: 404));
    });
    final provider = assignmentDetailProvider(1);
    container.listen(provider, (_, _) {});
    await Future<void>.delayed(Duration.zero);
    auth.change(AuthAuthenticated(employee('B')));
    await expectLater(
      container.read(provider.future),
      throwsA(isA<ApiError>()),
    );
    auth.change(AuthAuthenticated(employee('A')));
    await expectLater(
      container.read(provider.future),
      throwsA(isA<ApiError>()),
    );
    old.complete(detail('Obsolete A'));
    await Future<void>.delayed(Duration.zero);
    expect(container.read(provider).hasError, isTrue);
    expect(container.read(provider).asData, isNull);
    expect(calls, 3);
  });

  for (final failure in [
    ApiError.networkFailure(),
    ApiError.timeout(),
    ApiError(message: 'Expired.', statusCode: 401),
    ApiError(message: 'Denied.', statusCode: 403),
    ApiError(message: 'Not found.', statusCode: 404),
    ApiError(message: 'Unavailable.', statusCode: 503),
  ]) {
    testWidgets(
      'read failure ${failure.code ?? failure.statusCode} waits for an explicit retry',
      (tester) async {
        when(
          () =>
              repository.getAssignments(cancelToken: any(named: 'cancelToken')),
        ).thenThrow(failure);
        container.listen(assignmentListProvider, (_, _) {});
        await expectLater(
          container.read(assignmentListProvider.future),
          throwsA(same(failure)),
        );
        await tester.pump(const Duration(seconds: 20));
        verify(
          () =>
              repository.getAssignments(cancelToken: any(named: 'cancelToken')),
        ).called(1);
        when(
          () =>
              repository.getAssignments(cancelToken: any(named: 'cancelToken')),
        ).thenAnswer((_) async => []);
        container.invalidate(assignmentListProvider);
        expect(await container.read(assignmentListProvider.future), isEmpty);
        await tester.pump();
        verify(
          () =>
              repository.getAssignments(cancelToken: any(named: 'cancelToken')),
        ).called(1);
        container.dispose();
        await tester.pump();
      },
    );
  }

  test('textLessonCompletionProvider invalidates all completion-dependent caches on completion', () async {
    when(() => repository.completeTextLesson(1, 2)).thenAnswer(
      (_) async => LessonProgress(
        resumePosition: 0,
        watchedSeconds: 0,
        progressPercent: 100,
        completed: true,
        completedAt: DateTime.now(),
      ),
    );

    var detailFetches = 0;
    var listFetches = 0;
    when(
      () => repository.getAssignmentDetail(
        1,
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenAnswer((_) async {
      detailFetches++;
      return detail('Safety');
    });
    when(
      () => repository.getAssignments(cancelToken: any(named: 'cancelToken')),
    ).thenAnswer((_) async {
      listFetches++;
      return <Assignment>[];
    });

    container.listen(assignmentDetailProvider(1), (_, _) {});
    container.listen(assignmentListProvider, (_, _) {});
    await Future<void>.delayed(Duration.zero);
    expect(detailFetches, 1);
    expect(listFetches, 1);

    final progress = await container.read(
      textLessonCompletionProvider((
        account: 'A:A',
        assignmentId: 1,
        lessonId: 2,
      )).future,
    );
    expect(progress.completed, isTrue);

    await Future<void>.delayed(Duration.zero);
    expect(detailFetches, 2);
    expect(listFetches, 2);
  });

  test('textLessonCompletionProvider discards response and does not invalidate after account switch', () async {
    final completer = Completer<LessonProgress>();
    when(() => repository.completeTextLesson(1, 2))
        .thenAnswer((_) => completer.future);

    var detailFetches = 0;
    when(
      () => repository.getAssignmentDetail(
        1,
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenAnswer((_) async {
      detailFetches++;
      return detail('Safety');
    });

    container.listen(assignmentDetailProvider(1), (_, _) {});
    await Future<void>.delayed(Duration.zero);
    expect(detailFetches, 1);

    final future = container.read(
      textLessonCompletionProvider((
        account: 'A:A',
        assignmentId: 1,
        lessonId: 2,
      )).future,
    );

    auth.change(AuthAuthenticated(employee('B')));
    await Future<void>.delayed(Duration.zero);
    final countAfterSwitch = detailFetches;

    completer.complete(
      LessonProgress(
        resumePosition: 0,
        watchedSeconds: 0,
        progressPercent: 100,
        completed: true,
        completedAt: DateTime.now(),
      ),
    );
    await future;
    await Future<void>.delayed(Duration.zero);

    expect(detailFetches, countAfterSwitch);
  });

  test('textLessonCompletionProvider separates requests across different accounts for the same assignment and lesson', () async {
    final completerA = Completer<LessonProgress>();
    final completerB = Completer<LessonProgress>();
    var callCount = 0;
    when(() => repository.completeTextLesson(1, 2)).thenAnswer((_) {
      callCount++;
      return callCount == 1 ? completerA.future : completerB.future;
    });

    auth.change(AuthAuthenticated(employee('A')));
    final futureA = container.read(
      textLessonCompletionProvider((
        account: 'A:A',
        assignmentId: 1,
        lessonId: 2,
      )).future,
    );

    // Account B starts completion for the same assignment and lesson while Account A is in flight
    auth.change(AuthAuthenticated(employee('B')));
    final futureB = container.read(
      textLessonCompletionProvider((
        account: 'B:B',
        assignmentId: 1,
        lessonId: 2,
      )).future,
    );

    // Verify that two distinct requests were initiated
    expect(callCount, 2);
    expect(identical(futureA, futureB), isFalse);

    // Complete A with incomplete result and B with completed result
    completerA.complete(
      LessonProgress(
        resumePosition: 0,
        watchedSeconds: 0,
        progressPercent: 50,
        completed: false,
      ),
    );
    completerB.complete(
      LessonProgress(
        resumePosition: 0,
        watchedSeconds: 0,
        progressPercent: 100,
        completed: true,
        completedAt: DateTime.now(),
      ),
    );

    final resultA = await futureA;
    final resultB = await futureB;

    expect(resultA.completed, isFalse);
    expect(resultB.completed, isTrue);
  });
}
