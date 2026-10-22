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
import 'package:training_app/features/learning/domain/models/assignment_detail.dart';
import 'package:training_app/features/learning/domain/models/assignment.dart';
import 'package:training_app/features/learning/domain/models/protected_media_request.dart';
import 'package:training_app/features/learning/presentation/controllers/playback_session_controller.dart';
import 'package:training_app/features/learning/presentation/controllers/learning_controller.dart';

class MockRepository extends Mock implements LearningRepository {}

class TestAuth extends AuthController {
  @override
  AuthState build() => AuthAuthenticated(employee('A'));
  void change(AuthState auth) => state = auth;
}

Employee employee(String username) => Employee(
  username: username,
  employeeCode: username,
  displayName: username,
  department: 'QA',
  jobRole: 'Learner',
  isActive: true,
);

LessonProgress progress({
  int? session = 7,
  double watched = 0,
  double resume = 0,
  bool completed = false,
}) => LessonProgress(
  resumePosition: resume,
  watchedSeconds: watched,
  progressPercent: watched,
  completed: completed,
  sessionId: session,
  watchedRanges: watched == 0
      ? []
      : [
          [0, watched],
        ],
);

void main() {
  const lesson = (assignmentId: 1, lessonId: 2);
  final provider = playbackSessionProvider(lesson);
  late MockRepository repository;
  late TestAuth auth;
  late ProviderContainer container;
  late PlaybackSessionController controller;

  setUpAll(() => registerFallbackValue(CancelToken()));
  setUp(() {
    repository = MockRepository();
    auth = TestAuth();
    when(
      () => repository.getLessonProgress(
        1,
        2,
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenAnswer((_) async => progress(session: null));
    when(
      () => repository.startPlaybackSession(
        1,
        2,
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenAnswer((_) async => progress());
    when(
      () => repository.endPlaybackSession(
        1,
        2,
        7,
        any(),
        completedNormally: any(named: 'completedNormally'),
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenAnswer((_) async => progress());
    container = ProviderContainer(
      overrides: [
        learningRepositoryProvider.overrideWithValue(repository),
        authControllerProvider.overrideWith(() => auth),
      ],
    );
    addTearDown(container.dispose);
    container.listen(provider, (_, _) {});
    controller = container.read(provider.notifier);
  });

  test('accepted session closure refreshes a retained assignment list from the server', () async {
    var reads = 0;
    var serverCompleted = false;
    when(
      () => repository.getAssignments(cancelToken: any(named: 'cancelToken')),
    ).thenAnswer((_) async {
      reads++;
      return [
        Assignment.fromJson({
          'id': 1,
          'status': 'IN_PROGRESS',
          'progress_summary': {
            'required_lessons_completed': serverCompleted ? 1 : 0,
            'required_lessons_total': 1,
          },
        }),
      ];
    });
    container.listen(assignmentListProvider, (_, _) {});
    await container.read(assignmentListProvider.future);
    expect(reads, 1);
    await controller.start();
    when(
      () => repository.endPlaybackSession(
        1,
        2,
        7,
        80,
        completedNormally: true,
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenAnswer((_) async {
      serverCompleted = true;
      return progress(watched: 80, completed: true);
    });
    await controller.close(position: 80, completedNormally: true);
    final assignments = await container.read(assignmentListProvider.future);
    expect(reads, 2);
    expect(assignments.single.progressSummary.requiredLessonsCompleted, 1);
    expect(container.read(provider).progress!.completed, isTrue);
  });

  test(
    'failed closure does not claim refreshed or completed assignment progress',
    () async {
      var reads = 0;
      when(
        () => repository.getAssignments(cancelToken: any(named: 'cancelToken')),
      ).thenAnswer((_) async {
        reads++;
        return [];
      });
      container.listen(assignmentListProvider, (_, _) {});
      await container.read(assignmentListProvider.future);
      await controller.start();
      when(
        () => repository.endPlaybackSession(
          1,
          2,
          7,
          80,
          completedNormally: true,
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenThrow(ApiError.timeout());
      await controller.close(position: 80, completedNormally: true);
      await container.read(assignmentListProvider.future);
      expect(reads, 1);
      expect(container.read(provider).progress!.completed, isFalse);
    },
  );

  test(
    'loads server state and deduplicates concurrent start and close requests',
    () async {
      await controller.loadProgress();
      expect(container.read(provider).progress!.sessionId, isNull);
      final started = Completer<LessonProgress>();
      when(
        () => repository.startPlaybackSession(
          1,
          2,
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer((_) => started.future);
      final first = controller.start();
      final duplicate = controller.start();
      await Future<void>.delayed(Duration.zero);
      final close = controller.close(position: 0);
      final duplicateClose = controller.close(position: 99);
      started.complete(progress());
      await Future.wait([first, duplicate, close, duplicateClose]);
      expect(container.read(provider).phase, PlaybackPhase.ended);
      expect(container.read(provider).sessionId, isNull);
      verify(
        () => repository.startPlaybackSession(
          1,
          2,
          cancelToken: any(named: 'cancelToken'),
        ),
      ).called(1);
      verify(
        () => repository.endPlaybackSession(
          1,
          2,
          7,
          0,
          completedNormally: false,
          cancelToken: any(named: 'cancelToken'),
        ),
      ).called(1);
      await controller.close();
      verify(
        () => repository.getLessonProgress(
          1,
          2,
          cancelToken: any(named: 'cancelToken'),
        ),
      ).called(1);
      verifyNoMoreInteractions(repository);
    },
  );

  test(
    'heartbeats execute in order and never award local watch credit',
    () async {
      await controller.start();
      final firstResponse = Completer<LessonProgress>();
      when(
        () => repository.submitPlaybackHeartbeat(
          1,
          2,
          7,
          10,
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer((_) => firstResponse.future);
      when(
        () => repository.submitPlaybackHeartbeat(
          1,
          2,
          7,
          90,
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer((_) async => progress(watched: 10, resume: 10));
      final first = controller.heartbeat(10);
      final second = controller.heartbeat(90);
      await Future<void>.delayed(Duration.zero);
      verifyNever(
        () => repository.submitPlaybackHeartbeat(
          1,
          2,
          7,
          90,
          cancelToken: any(named: 'cancelToken'),
        ),
      );
      expect(container.read(provider).progress!.watchedSeconds, 0);
      firstResponse.complete(progress(watched: 10, resume: 10));
      await Future.wait([first, second]);
      final state = container.read(provider);
      expect(state.progress!.watchedSeconds, 10);
      expect(state.progress!.resumePosition, 10);
      expect(state.progress!.progressPercent, 10);
      expect(state.progress!.completed, isFalse);
    },
  );

  test(
    'normal end uses server completion, and resume starts a new session',
    () async {
      await controller.start();
      await controller.close(position: 100, completedNormally: true);
      expect(container.read(provider).progress!.completed, isFalse);
      when(
        () => repository.startPlaybackSession(
          1,
          2,
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer(
        (_) async =>
            progress(session: 8, watched: 80, resume: 80, completed: true),
      );
      await controller.start();
      expect(container.read(provider).sessionId, 8);
      expect(container.read(provider).progress!.completed, isTrue);
    },
  );

  test(
    'explicit replay starts at zero without changing confirmed coverage',
    () async {
      when(
        () => repository.startPlaybackSession(
          1,
          2,
          position: 0,
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer(
        (_) async => progress(watched: 80, resume: 0, completed: true),
      );
      await controller.start(position: 0);
      verify(
        () => repository.startPlaybackSession(
          1,
          2,
          position: 0,
          cancelToken: any(named: 'cancelToken'),
        ),
      ).called(1);
      expect(container.read(provider).phase, PlaybackPhase.active);
      expect(container.read(provider).progress!.resumePosition, 0);
      expect(container.read(provider).progress!.watchedSeconds, 80);
      expect(container.read(provider).progress!.completed, isTrue);
      await controller.close();
    },
  );

  test('heartbeat failure closes at approved position and cancels queued observations', () async {
    when(
      () => repository.startPlaybackSession(
        1,
        2,
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenAnswer((_) async => progress(watched: 5, resume: 5));
    await controller.start();
    when(
      () => repository.submitPlaybackHeartbeat(
        1,
        2,
        7,
        90,
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenThrow(ApiError.networkFailure());
    when(
      () => repository.endPlaybackSession(
        1,
        2,
        7,
        5,
        completedNormally: false,
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenAnswer((_) async => progress(watched: 5, resume: 5));
    await Future.wait([controller.heartbeat(90), controller.heartbeat(99)]);
    final state = container.read(provider);
    expect(state.phase, PlaybackPhase.failed);
    expect(state.error!.code, 'network_failure');
    expect(state.progress!.watchedSeconds, 5);
    expect(state.sessionId, isNull);
    verify(
      () => repository.endPlaybackSession(
        1,
        2,
        7,
        5,
        completedNormally: false,
        cancelToken: any(named: 'cancelToken'),
      ),
    ).called(1);
    verifyNever(
      () => repository.submitPlaybackHeartbeat(
        1,
        2,
        7,
        99,
        cancelToken: any(named: 'cancelToken'),
      ),
    );
  });

  test('lost close response blocks restart until explicit cleanup resolves the session', () async {
    await controller.start();
    when(
      () => repository.endPlaybackSession(
        1,
        2,
        7,
        0,
        completedNormally: false,
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenThrow(ApiError.timeout());
    await controller.close();
    expect(container.read(provider).sessionId, 7);
    expect(await controller.mediaRequest(), isNull);
    await controller.start();
    verify(
      () => repository.startPlaybackSession(
        1,
        2,
        cancelToken: any(named: 'cancelToken'),
      ),
    ).called(1);
    when(
      () => repository.endPlaybackSession(
        1,
        2,
        7,
        0,
        completedNormally: false,
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenThrow(ApiError(message: 'Closed session.', statusCode: 404));
    await controller.close();
    expect(container.read(provider).sessionId, isNull);
    expect(container.read(provider).phase, PlaybackPhase.failed);
    verify(
      () => repository.endPlaybackSession(
        1,
        2,
        7,
        0,
        completedNormally: false,
        cancelToken: any(named: 'cancelToken'),
      ),
    ).called(2);
  });

  test(
    'denied, stale and conflicting sessions stop without automatic retries',
    () async {
      for (final status in [401, 403, 404, 409]) {
        await controller.start();
        when(
          () => repository.submitPlaybackHeartbeat(
            1,
            2,
            7,
            10,
            cancelToken: any(named: 'cancelToken'),
          ),
        ).thenThrow(ApiError(message: 'Unavailable.', statusCode: status));
        await controller.heartbeat(10);
        expect(container.read(provider).phase, PlaybackPhase.failed);
        expect(container.read(provider).sessionId, isNull);
        expect(await controller.mediaRequest(), isNull);
        if (status == 401 || status == 403) {
          expect(container.read(provider).progress, isNull);
        }
      }
      verifyNever(
        () => repository.endPlaybackSession(
          1,
          2,
          7,
          any(),
          completedNormally: any(named: 'completedNormally'),
          cancelToken: any(named: 'cancelToken'),
        ),
      );
    },
  );

  test(
    'mismatched response session never changes the media session identity',
    () async {
      await controller.start();
      when(
        () => repository.submitPlaybackHeartbeat(
          1,
          2,
          7,
          10,
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer(
        (_) async => progress(session: 999, watched: 100, completed: true),
      );
      await controller.heartbeat(10);
      expect(container.read(provider).phase, PlaybackPhase.failed);
      expect(container.read(provider).progress!.completed, isFalse);
      verify(
        () => repository.endPlaybackSession(
          1,
          2,
          7,
          0,
          completedNormally: false,
          cancelToken: any(named: 'cancelToken'),
        ),
      ).called(1);
    },
  );

  test(
    'observation deadline resets only after an accepted server response',
    () async {
      final scheduled =
          <({Duration delay, Timer timer, void Function() fire})>[];
      await runZoned(
        () async {
          await controller.start();
          expect(scheduled, hasLength(2));
          expect(
            scheduled.first.delay,
            lessThanOrEqualTo(const Duration(seconds: 10)),
          );
          scheduled.first.fire();
          expect(container.read(provider).observationDue, isTrue);

          final response = Completer<LessonProgress>();
          when(
            () => repository.submitPlaybackHeartbeat(
              1,
              2,
              7,
              1,
              cancelToken: any(named: 'cancelToken'),
            ),
          ).thenAnswer((_) => response.future);
          final request = controller.heartbeat(1);
          await Future<void>.value();
          expect(container.read(provider).observationDue, isTrue);
          expect(scheduled, hasLength(2));
          expect(container.read(provider).progress!.watchedSeconds, 0);
          response.complete(progress());
          await request;
          expect(container.read(provider).observationDue, isFalse);
          expect(container.read(provider).lastObservationPosition, 1);
          expect(container.read(provider).progress!.watchedSeconds, 0);
          expect(scheduled, hasLength(4));
          expect(
            scheduled.take(2).every((entry) => !entry.timer.isActive),
            isTrue,
          );
          expect(
            scheduled[2].delay,
            lessThanOrEqualTo(const Duration(seconds: 10)),
          );
          expect(
            scheduled[3].delay,
            lessThanOrEqualTo(const Duration(seconds: 30)),
          );
          scheduled[2].fire();
          expect(container.read(provider).observationDue, isTrue);
          await controller.close();
          expect(scheduled.every((entry) => !entry.timer.isActive), isTrue);
        },
        zoneSpecification: ZoneSpecification(
          createTimer: (self, parent, zone, delay, callback) {
            final timer = parent.createTimer(
              zone,
              const Duration(days: 1),
              () {},
            );
            scheduled.add((delay: delay, timer: timer, fire: callback));
            return timer;
          },
        ),
      );
    },
  );

  test('idle expiry closes conservatively without adding coverage', () async {
    late void Function() expire;
    late Duration delay;
    await runZoned(
      () => controller.start(),
      zoneSpecification: ZoneSpecification(
        createTimer: (self, parent, zone, duration, callback) {
          delay = duration;
          expire = callback;
          return parent.createTimer(zone, const Duration(days: 1), () {});
        },
      ),
    );
    expect(delay, lessThanOrEqualTo(const Duration(seconds: 30)));
    expire();
    await Future<void>.delayed(Duration.zero);
    expect(container.read(provider).phase, PlaybackPhase.failed);
    expect(container.read(provider).error!.code, 'session_expired');
    expect(container.read(provider).progress!.watchedSeconds, 0);
    verify(
      () => repository.endPlaybackSession(
        1,
        2,
        7,
        0,
        completedNormally: false,
        cancelToken: any(named: 'cancelToken'),
      ),
    ).called(1);
  });

  test('late session creation cannot affect another account', () async {
    final response = Completer<LessonProgress>();
    CancelToken? oldRequests;
    when(
      () => repository.startPlaybackSession(
        1,
        2,
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenAnswer((invocation) {
      oldRequests = invocation.namedArguments[#cancelToken] as CancelToken;
      return response.future;
    });
    final oldStart = controller.start();
    await Future<void>.delayed(Duration.zero);
    auth.change(AuthLoading());
    expect(oldRequests!.isCancelled, isTrue);
    expect(container.read(provider).progress, isNull);
    auth.change(AuthAuthenticated(employee('B')));
    when(
      () => repository.startPlaybackSession(
        1,
        2,
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenAnswer((_) async => progress(session: 8));
    await controller.start();
    response.complete(progress(session: 7, watched: 100, completed: true));
    await oldStart;
    expect(container.read(provider).sessionId, 8);
    expect(container.read(provider).progress!.watchedSeconds, 0);
  });

  test('logout discards in-flight and queued heartbeats even after same-user login', () async {
    await controller.start();
    final response = Completer<LessonProgress>();
    when(
      () => repository.submitPlaybackHeartbeat(
        1,
        2,
        7,
        10,
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenAnswer((_) => response.future);
    final heartbeat = controller.heartbeat(10);
    final queued = controller.heartbeat(20);
    await Future<void>.delayed(Duration.zero);
    auth.change(AuthUnauthenticated());
    expect(container.read(provider).phase, PlaybackPhase.unavailable);
    await controller.start();
    auth.change(AuthAuthenticated(employee('A')));
    response.complete(progress(watched: 100, completed: true));
    await Future.wait([heartbeat, queued]);
    expect(container.read(provider).phase, PlaybackPhase.idle);
    expect(container.read(provider).progress, isNull);
    verifyNever(
      () => repository.submitPlaybackHeartbeat(
        1,
        2,
        7,
        20,
        cancelToken: any(named: 'cancelToken'),
      ),
    );
    verifyNever(
      () => repository.endPlaybackSession(
        1,
        2,
        7,
        any(),
        completedNormally: any(named: 'completedNormally'),
        cancelToken: any(named: 'cancelToken'),
      ),
    );
  });

  test(
    'media headers are discarded if account changes while storage is pending',
    () async {
      await controller.start();
      final response = Completer<ProtectedMediaRequest>();
      when(() => repository.protectedMediaRequest(1, 2, 7))
          .thenAnswer((_) => response.future);
      final media = controller.mediaRequest();
      auth.change(AuthAuthenticated(employee('B')));
      response.complete(
        ProtectedMediaRequest(
          uri: Uri.parse('https://qa.example/media'),
          headers: {'Authorization': 'Bearer old-token'},
        ),
      );
      expect(await media, isNull);
      expect(container.read(provider).progress, isNull);
    },
  );

  test(
    'profile refresh does not invalidate an active account session',
    () async {
      await controller.start();
      auth.change(AuthAuthenticated(employee('A')));
      expect(container.read(provider).phase, PlaybackPhase.active);
      expect(container.read(provider).sessionId, 7);
      expect(() => controller.heartbeat(double.infinity), throwsArgumentError);
    },
  );

  test(
    'disposal cancels outstanding work and ignores late responses',
    () async {
      final response = Completer<LessonProgress>();
      CancelToken? requests;
      when(
        () => repository.startPlaybackSession(
          1,
          2,
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer((invocation) {
        requests = invocation.namedArguments[#cancelToken] as CancelToken;
        return response.future;
      });
      final start = controller.start();
      await Future<void>.delayed(Duration.zero);
      container.invalidate(provider);
      expect(requests!.isCancelled, isTrue);
      response.complete(progress());
      await start;
      expect(container.read(provider).phase, PlaybackPhase.idle);
    },
  );
}
