import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:training_app/features/learning/presentation/widgets/protected_video_surface.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';
import 'package:video_player/video_player.dart';
import 'package:training_app/core/errors/api_error.dart';
import 'package:training_app/core/theme/app_theme.dart';
import 'package:training_app/features/auth/domain/models/auth_state.dart';
import 'package:training_app/features/auth/domain/models/employee.dart';
import 'package:training_app/features/auth/presentation/controllers/auth_controller.dart';
import 'package:training_app/features/learning/data/repositories/learning_repository.dart';
import 'package:training_app/features/learning/domain/models/assignment_detail.dart';
import 'package:training_app/features/learning/domain/models/protected_media_request.dart';
import 'package:training_app/features/learning/presentation/controllers/learning_controller.dart';
import 'package:training_app/features/learning/presentation/screens/video_lesson_screen.dart';

import '../video_player_preview.dart';

class Repository extends Mock implements LearningRepository {}

Employee employee(String name) => Employee(
  username: name,
  employeeCode: name,
  displayName: name,
  department: 'QA',
  jobRole: 'Learner',
  isActive: true,
);

class Auth extends AuthController {
  @override
  AuthState build() => AuthAuthenticated(employee('A'));
  void change(AuthState auth) => state = auth;
  @override
  Future<void> logout() async => state = AuthUnauthenticated();
}

class Player extends VideoPlayerController {
  final Completer<void>? initialization;
  final Duration mediaDuration;
  bool disposed = false;
  bool rejectSeeks = false;
  Player({
    this.initialization,
    this.mediaDuration = const Duration(seconds: 100),
  }) : super.networkUrl(Uri.parse('https://qa.invalid/protected'));
  @override
  Future<void> initialize() async {
    await initialization?.future;
    if (disposed) return;
    value = VideoPlayerValue(
      duration: mediaDuration,
      isInitialized: true,
      size: Size(1600, 900),
    );
  }

  @override
  Future<void> play() async => value = value.copyWith(isPlaying: true);
  @override
  Future<void> pause() async {
    if (!disposed) value = value.copyWith(isPlaying: false);
  }

  @override
  Future<void> seekTo(Duration position) async {
    if (rejectSeeks) throw StateError('Native seek failed');
    value = value.copyWith(position: position);
  }

  @override
  Future<void> dispose() async {
    disposed = true;
    await super.dispose();
  }
}

LessonProgress progress({
  double resume = 0,
  double watched = 0,
  bool completed = false,
  int session = 7,
}) => LessonProgress(
  resumePosition: resume,
  watchedSeconds: watched,
  progressPercent: watched,
  completed: completed,
  sessionId: session,
  watchedRanges: watched > 0
      ? [
          [0, watched],
        ]
      : [],
);

void main() {
  late Repository repository;
  late Auth auth;
  late ProviderContainer container;
  late GoRouter router;
  late List<Player> players;
  late List<ProtectedMediaRequest> requests;
  Completer<void>? initialization;
  Duration mediaDuration = const Duration(seconds: 100);
  LessonProgress lessonProgress = progress();
  String lessonType = 'VIDEO';
  String playbackMode = 'tracked';
  String assignmentStatus = 'IN_PROGRESS';
  double minimumWatchPercent = 80;
  ApiError? detailError;
  int detailReads = 0;
  AssignmentDetail detail() => AssignmentDetail(
    id: 1,
    trainingId: 1,
    trainingTitle: 'QA',
    versionNumber: 1,
    status: assignmentStatus,
    isOverdue: false,
    modules: [
      ModuleLearning(
        id: 3,
        title: 'QA',
        description: '',
        position: 1,
        lessons: [
          LessonLearning(
            id: 2,
            title: 'Protected lesson',
            position: 1,
            type: lessonType,
            isRequired: true,
            minimumWatchPercent: minimumWatchPercent,
            videoDurationSeconds: 100,
            body: '',
            progress: lessonProgress,
            playbackMode: playbackMode,
          ),
        ],
      ),
    ],
  );
  setUpAll(() => registerFallbackValue(CancelToken()));
  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    repository = Repository();
    auth = Auth();
    players = [];
    requests = [];
    initialization = null;
    mediaDuration = const Duration(seconds: 100);
    lessonProgress = progress();
    lessonType = 'VIDEO';
    playbackMode = 'tracked';
    assignmentStatus = 'IN_PROGRESS';
    minimumWatchPercent = 80;
    detailError = null;
    detailReads = 0;
    when(
      () => repository.startPlaybackSession(
        1,
        2,
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenAnswer((_) async => progress());
    when(
      () => repository.submitPlaybackHeartbeat(
        1,
        2,
        7,
        any(),
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
    when(() => repository.protectedMediaRequest(1, 2, 7)).thenAnswer(
      (_) async => ProtectedMediaRequest(
        uri: Uri.parse(
          'https://qa.invalid/api/v1/assignments/1/lessons/2/sessions/7/media/',
        ),
        headers: {'Authorization': 'Bearer qa-token'},
      ),
    );
    when(() => repository.protectedReplayMediaRequest(1, 2)).thenAnswer(
      (_) async => ProtectedMediaRequest(
        uri: Uri.parse(
          'https://qa.invalid/api/v1/assignments/1/lessons/2/replay/media/',
        ),
        headers: {'Authorization': 'Bearer qa-token'},
      ),
    );
    container = ProviderContainer(
      overrides: [
        authControllerProvider.overrideWith(() => auth),
        learningRepositoryProvider.overrideWithValue(repository),
        assignmentDetailProvider(1).overrideWith((_) async {
          detailReads++;
          if (detailError case final error?) throw error;
          return detail();
        }),
        assignmentDetailProvider(2).overrideWith(
          (_) async => AssignmentDetail(
            id: 2,
            trainingId: 1,
            trainingTitle: 'Other QA',
            versionNumber: 1,
            status: 'IN_PROGRESS',
            isOverdue: false,
            modules: [
              ModuleLearning(
                id: 3,
                title: 'Module',
                description: '',
                position: 1,
                lessons: [
                  LessonLearning(
                    id: 4,
                    title: 'Other video',
                    position: 1,
                    type: 'VIDEO',
                    isRequired: true,
                    body: '',
                    progress: progress(),
                  ),
                ],
              ),
            ],
          ),
        ),
        protectedVideoControllerProvider.overrideWithValue((media) {
          requests.add(media);
          final player = Player(
            initialization: initialization,
            mediaDuration: mediaDuration,
          );
          players.add(player);
          return player;
        }),
      ],
    );
    router = GoRouter(
      initialLocation: '/video',
      routes: [
        GoRoute(
          path: '/video',
          builder: (_, state) => VideoLessonScreen(
            assignmentId: state.uri.queryParameters['assignment'] == '2'
                ? 2
                : 1,
            moduleId: 3,
            lessonId: state.uri.queryParameters['assignment'] == '2' ? 4 : 2,
          ),
        ),
        GoRoute(
          path: '/learning/assignments/1/modules/3/lessons',
          builder: (_, _) => const Scaffold(body: Text('Lessons')),
        ),
      ],
    );
  });
  tearDown(() {
    router.dispose();
    container.dispose();
    debugDefaultTargetPlatformOverride = null;
  });
  Future<void> show(
    WidgetTester tester, {
    ThemeMode mode = ThemeMode.light,
  }) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: RepaintBoundary(
          key: const ValueKey('learner-page-preview'),
          child: MaterialApp.router(
            routerConfig: router,
            theme: AppTheme.lightTheme,
            darkTheme: AppTheme.darkTheme,
            themeMode: mode,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> play(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('video-playback-action')));
    await tester.pump();
    await tester.pump();
  }

  Future<void> remove(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    debugDefaultTargetPlatformOverride = null;
  }

  testWidgets(
    'expired playback offers explicit sign-in and no further playback action',
    (tester) async {
      when(
        () => repository.startPlaybackSession(
          1,
          2,
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenThrow(
        ApiError(message: 'Your session has expired.', statusCode: 401),
      );
      await show(tester);
      await play(tester);
      expect(players, isEmpty);
      expect(find.byKey(const ValueKey('video-playback-action')), findsNothing);
      await tester.tap(find.text('Sign in again'));
      await tester.pumpAndSettle();
      expect(
        container.read(authControllerProvider),
        isA<AuthUnauthenticated>(),
      );
      verify(
        () => repository.startPlaybackSession(
          1,
          2,
          cancelToken: any(named: 'cancelToken'),
        ),
      ).called(1);
      await remove(tester);
    },
  );

  testWidgets(
    'authorization loss on a lesson refresh stops media and exposes sign-in recovery',
    (tester) async {
      await show(tester);
      await play(tester);
      detailError = ApiError(
        message: 'Your session has expired.',
        statusCode: 401,
      );
      container.invalidate(assignmentDetailProvider(1));
      await tester.pumpAndSettle();
      expect(players.single.value.isPlaying, isFalse);
      expect(find.byType(ProtectedVideoSurface), findsNothing);
      expect(find.text('Sign in again'), findsOneWidget);
      expect(detailReads, 2); // Cleanup does not retry the denied lesson read.
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
      await remove(tester);
    },
  );

  testWidgets(
    'replay media authorization failure offers sign-in without opening a watch session',
    (tester) async {
      assignmentStatus = 'COMPLETED';
      playbackMode = 'read_only_replay';
      lessonProgress = progress(watched: 80, completed: true);
      when(() => repository.protectedReplayMediaRequest(1, 2)).thenThrow(
        ApiError(message: 'Sign in to play this lesson.', statusCode: 401),
      );
      await show(tester);
      await play(tester);
      expect(find.text('Sign in again'), findsOneWidget);
      expect(players, isEmpty);
      verifyNever(
        () => repository.startPlaybackSession(
          any(),
          any(),
          cancelToken: any(named: 'cancelToken'),
        ),
      );
      await remove(tester);
    },
  );

  for (final percent in [79.6, 79.99, 80.0]) {
    testWidgets(
      'confirmed $percent percent never rounds up or invents completion',
      (tester) async {
        lessonProgress = progress(watched: percent);
        await show(tester);
        expect(
          find.text('Watched coverage: ${percent.floor()}%'),
          findsOneWidget,
        );
        expect(find.text('${percent.floor()}% watched'), findsOneWidget);
        expect(find.text('Lesson completed'), findsNothing);
        final indicator = tester.widget<LinearProgressIndicator>(
          find.byType(LinearProgressIndicator),
        );
        expect(indicator.value, percent / 100);
        await remove(tester);
      },
    );
  }

  testWidgets(
    'fractional watch requirement is not rounded down to a met threshold',
    (tester) async {
      minimumWatchPercent = 80.5;
      lessonProgress = progress(watched: 80.49);
      await show(tester);
      expect(find.text('Watched coverage: 80%'), findsOneWidget);
      expect(find.text('Watch 80.5% to complete this lesson.'), findsOneWidget);
      expect(find.text('Lesson completed'), findsNothing);
      await remove(tester);
    },
  );

  for (final type in ['video', 'ViDeO']) {
    testWidgets('plays video lesson with $type type', (tester) async {
      lessonType = type;
      try {
        await show(tester);
        expect(find.text('Protected lesson'), findsOneWidget);
        await play(tester);
        expect(players.single.value.isPlaying, isTrue);
        verify(
          () => repository.startPlaybackSession(
            1,
            2,
            cancelToken: any(named: 'cancelToken'),
          ),
        ).called(1);
      } finally {
        await remove(tester);
      }
    });
  }

  testWidgets(
    'starts paused; session precedes authenticated media; heartbeats credit only server values',
    (tester) async {
      await show(tester);
      expect(players, isEmpty);
      verifyNever(
        () => repository.startPlaybackSession(
          1,
          2,
          cancelToken: any(named: 'cancelToken'),
        ),
      );
      await play(tester);
      expect(players.single.value.isPlaying, isTrue);
      expect(requests.single.headers['Authorization'], 'Bearer qa-token');
      players.single.value = players.single.value.copyWith(
        position: const Duration(seconds: 10),
      );
      await tester.pump(const Duration(seconds: 10));
      await tester.pump();
      verify(
        () => repository.submitPlaybackHeartbeat(
          1,
          2,
          7,
          9.9,
          cancelToken: any(named: 'cancelToken'),
        ),
      ).called(1);
      expect(find.text('Watched coverage: 0%'), findsOneWidget);
      expect(find.text('Lesson completed'), findsNothing);
      await remove(tester);
    },
  );

  testWidgets(
    'pause cancels heartbeats and resume creates fresh media at server resume',
    (tester) async {
      await show(tester);
      await play(tester);
      players.first.value = players.first.value.copyWith(
        position: const Duration(seconds: 12),
      );
      await tester.tap(find.byKey(const ValueKey('video-playback-action')));
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(seconds: 20));
      verifyNever(
        () => repository.submitPlaybackHeartbeat(
          1,
          2,
          7,
          any(),
          cancelToken: any(named: 'cancelToken'),
        ),
      );
      when(
        () => repository.startPlaybackSession(
          1,
          2,
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer((_) async => progress(resume: 11, watched: 11));
      await play(tester);
      expect(players.first.disposed, isTrue);
      expect(players.last.value.position, const Duration(seconds: 11));
      await remove(tester);
    },
  );

  testWidgets(
    'completed endpoint replay starts at zero and keeps server credit',
    (tester) async {
      lessonProgress = progress(resume: 99.6, watched: 80, completed: true);
      when(
        () => repository.startPlaybackSession(
          1,
          2,
          position: 0,
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer(
        (_) async => progress(resume: 0, watched: 80, completed: true),
      );
      when(
        () => repository.endPlaybackSession(
          1,
          2,
          7,
          any(),
          completedNormally: true,
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer(
        (_) async => progress(resume: 100, watched: 80, completed: true),
      );
      await show(tester);
      await play(tester);
      verify(
        () => repository.startPlaybackSession(
          1,
          2,
          position: 0,
          cancelToken: any(named: 'cancelToken'),
        ),
      ).called(1);
      verifyNever(
        () => repository.startPlaybackSession(
          1,
          2,
          cancelToken: any(named: 'cancelToken'),
        ),
      );
      expect(players.single.value.position, Duration.zero);
      expect(players.single.value.isPlaying, isTrue);
      expect(find.text('Lesson completed'), findsOneWidget);
      players.single.value = players.single.value.copyWith(
        position: const Duration(seconds: 100),
        isPlaying: false,
        isCompleted: true,
      );
      await tester.pump();
      await tester.pump();
      verify(
        () => repository.endPlaybackSession(
          1,
          2,
          7,
          any(),
          completedNormally: true,
          cancelToken: any(named: 'cancelToken'),
        ),
      ).called(1);
      expect(find.text('Lesson completed'), findsOneWidget);
      await remove(tester);
    },
  );

  testWidgets(
    'native duration reveals endpoint and restarts only after close',
    (tester) async {
      lessonProgress = progress(resume: 68.624, watched: 55, completed: true);
      mediaDuration = const Duration(milliseconds: 68650);
      when(
        () => repository.startPlaybackSession(
          1,
          2,
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer(
        (_) async => progress(resume: 68.624, watched: 55, completed: true),
      );
      when(
        () => repository.endPlaybackSession(
          1,
          2,
          7,
          any(),
          completedNormally: false,
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer(
        (_) async => progress(resume: 68.624, watched: 55, completed: true),
      );
      when(
        () => repository.startPlaybackSession(
          1,
          2,
          position: 0,
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer(
        (_) async =>
            progress(session: 8, resume: 0, watched: 55, completed: true),
      );
      when(() => repository.protectedMediaRequest(1, 2, 8)).thenAnswer(
        (_) async => ProtectedMediaRequest(
          uri: Uri.parse('https://qa.invalid/sessions/8/media/'),
          headers: {'Authorization': 'Bearer qa-token'},
        ),
      );
      when(
        () => repository.endPlaybackSession(
          1,
          2,
          8,
          any(),
          completedNormally: false,
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer(
        (_) async =>
            progress(session: 8, resume: 0, watched: 55, completed: true),
      );
      await show(tester);
      await play(tester);
      expect(players.length, 2);
      expect(players.first.disposed, isTrue);
      expect(players.last.value.position, Duration.zero);
      expect(players.last.value.isPlaying, isTrue);
      verifyInOrder([
        () => repository.startPlaybackSession(
          1,
          2,
          cancelToken: any(named: 'cancelToken'),
        ),
        () => repository.endPlaybackSession(
          1,
          2,
          7,
          any(),
          completedNormally: false,
          cancelToken: any(named: 'cancelToken'),
        ),
        () => repository.startPlaybackSession(
          1,
          2,
          position: 0,
          cancelToken: any(named: 'cancelToken'),
        ),
      ]);
      expect(find.text('Lesson completed'), findsOneWidget);
      await remove(tester);
    },
  );

  testWidgets('failed metadata replay cleanup never opens another session', (
    tester,
  ) async {
    lessonProgress = progress(resume: 68.624, watched: 55, completed: true);
    mediaDuration = const Duration(milliseconds: 68650);
    when(
      () => repository.startPlaybackSession(
        1,
        2,
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenAnswer(
      (_) async => progress(resume: 68.624, watched: 55, completed: true),
    );
    when(
      () => repository.endPlaybackSession(
        1,
        2,
        7,
        any(),
        completedNormally: false,
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenThrow(ApiError.timeout());
    await show(tester);
    await play(tester);
    verifyNever(
      () => repository.startPlaybackSession(
        1,
        2,
        position: 0,
        cancelToken: any(named: 'cancelToken'),
      ),
    );
    expect(players.single.value.isPlaying, isFalse);
    expect(find.textContaining('connection timed out'), findsWidgets);
    await remove(tester);
  });

  testWidgets('backgrounding closes; foreground does not autoplay', (
    tester,
  ) async {
    await show(tester);
    await play(tester);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    await tester.pump();
    expect(players.single.value.isPlaying, isFalse);
    verify(
      () => repository.endPlaybackSession(
        1,
        2,
        7,
        any(),
        completedNormally: false,
        cancelToken: any(named: 'cancelToken'),
      ),
    ).called(1);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(players.single.value.isPlaying, isFalse);
    await remove(tester);
  });

  testWidgets(
    'completed assignment replay has no sessions, heartbeat or credit writes',
    (tester) async {
      assignmentStatus = 'COMPLETED';
      playbackMode = 'read_only_replay';
      lessonProgress = progress(resume: 99.6, watched: 80, completed: true);
      await show(tester);
      expect(find.textContaining('Read-only replay.'), findsOneWidget);
      await play(tester);
      expect(players.single.value.position, Duration.zero);
      expect(players.single.value.isPlaying, isTrue);
      expect(requests.single.uri.path, endsWith('/replay/media/'));
      players.single.value = players.single.value.copyWith(
        position: const Duration(seconds: 9),
      );
      await tester.pump(const Duration(seconds: 11));
      await tester.tap(find.byKey(const ValueKey('cinematic-video-stage')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('video-playback-action')));
      await tester.pumpAndSettle();
      await play(tester);
      expect(players.last.value.position, const Duration(seconds: 9));
      tester.widget<Slider>(find.byType(Slider)).onChangeEnd!(4);
      await tester.pump();
      await tester.pump();
      expect(players.last.value.position, const Duration(seconds: 4));
      expect(players.last.value.isPlaying, isTrue);
      final surface = tester.widget<ProtectedVideoSurface>(
        find.byType(ProtectedVideoSurface),
      );
      expect(surface.coveragePercent, 80);
      expect(surface.completed, isTrue);
      players.last.value = players.last.value.copyWith(
        position: const Duration(seconds: 100),
        isPlaying: false,
        isCompleted: true,
      );
      await tester.pumpAndSettle();
      await play(tester);
      expect(players.last.value.position, Duration.zero);
      expect(find.text('Lesson completed'), findsOneWidget);
      await remove(tester);
      verify(() => repository.protectedReplayMediaRequest(1, 2)).called(3);
      verifyNoMoreInteractions(repository);
    },
  );

  testWidgets(
    'replay errors and account changes stop media without progress writes',
    (tester) async {
      assignmentStatus = 'COMPLETED';
      playbackMode = 'read_only_replay';
      lessonProgress = progress(resume: 99.6, watched: 80, completed: true);
      await show(tester);
      await play(tester);
      players.single.value = players.single.value.copyWith(
        errorDescription: 'HTTP 403',
      );
      await tester.pumpAndSettle();
      expect(players.single.value.isPlaying, isFalse);
      expect(find.textContaining('Replay is unavailable'), findsWidgets);
      auth.change(AuthUnauthenticated());
      await tester.pumpAndSettle();
      expect(players.single.disposed, isTrue);
      expect(find.text('Protected lesson'), findsNothing);
      await remove(tester);
      verify(() => repository.protectedReplayMediaRequest(1, 2)).called(1);
      verifyNoMoreInteractions(repository);
    },
  );

  testWidgets('unavailable playback mode never loads media', (tester) async {
    assignmentStatus = 'COMPLETED';
    playbackMode = 'unavailable';
    await show(tester);
    final button = tester.widget<IconButton>(
      find.byKey(const ValueKey('video-playback-action')),
    );
    expect(button.onPressed, isNull);
    expect(players, isEmpty);
    await remove(tester);
    verifyNoMoreInteractions(repository);
  });

  testWidgets(
    'native replay seek failure is controlled and never writes progress',
    (tester) async {
      assignmentStatus = 'COMPLETED';
      playbackMode = 'read_only_replay';
      lessonProgress = progress(resume: 99.6, watched: 80, completed: true);
      await show(tester);
      await play(tester);
      players.single.rejectSeeks = true;
      tester.widget<Slider>(find.byType(Slider)).onChangeEnd!(4);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(players.single.value.isPlaying, isFalse);
      expect(find.textContaining('Replay is unavailable'), findsWidgets);
      await remove(tester);
      verify(() => repository.protectedReplayMediaRequest(1, 2)).called(1);
      verifyNoMoreInteractions(repository);
    },
  );

  testWidgets('exit waits for session closure before navigation', (
    tester,
  ) async {
    final ended = Completer<LessonProgress>();
    when(
      () => repository.endPlaybackSession(
        1,
        2,
        7,
        any(),
        completedNormally: false,
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenAnswer((_) => ended.future);
    await show(tester);
    await play(tester);
    await tester.tap(find.byTooltip('Back to lessons'));
    await tester.pump();
    expect(find.text('Lessons'), findsNothing);
    ended.complete(progress());
    await tester.pumpAndSettle();
    expect(find.text('Lessons'), findsOneWidget);
    await remove(tester);
  });

  testWidgets(
    'rejects unwatched forward seek and allows confirmed watched backward seek',
    (tester) async {
      when(
        () => repository.submitPlaybackHeartbeat(
          1,
          2,
          7,
          any(),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer((_) async => progress(resume: 20, watched: 20));
      await show(tester);
      await play(tester);
      players.single.value = players.single.value.copyWith(
        position: const Duration(seconds: 20),
      );
      tester.widget<Slider>(find.byType(Slider)).onChangeEnd!(80);
      await tester.pump();
      await tester.pump();
      expect(players.single.value.position, const Duration(seconds: 20));
      verifyNever(
        () => repository.submitPlaybackHeartbeat(
          1,
          2,
          7,
          80,
          cancelToken: any(named: 'cancelToken'),
        ),
      );
      expect(
        find.text('Move through unwatched video by playing it.'),
        findsOneWidget,
      );
      await tester.pump(const Duration(seconds: 4));
      await tester.pump(const Duration(milliseconds: 220));
      expect(
        tester
            .widget<ProtectedVideoSurface>(find.byType(ProtectedVideoSurface))
            .controlsVisible,
        isFalse,
      );
      expect(
        find.text('Move through unwatched video by playing it.'),
        findsOneWidget,
      );
      await tester.pump(const Duration(seconds: 1));
      expect(
        find.text('Move through unwatched video by playing it.'),
        findsNothing,
      );
      await tester.tap(find.byKey(const ValueKey('cinematic-video-stage')));
      await tester.pump();
      expect(
        find.text('Move through unwatched video by playing it.'),
        findsNothing,
      );
      tester.widget<Slider>(find.byType(Slider)).onChangeEnd!(10);
      await tester.pump();
      await tester.pump();
      expect(players.single.value.position, const Duration(seconds: 10));
      verify(
        () => repository.submitPlaybackHeartbeat(
          1,
          2,
          7,
          10,
          cancelToken: any(named: 'cancelToken'),
        ),
      ).called(1);
      await remove(tester);
    },
  );

  Future<void> rejectSeek(WidgetTester tester) async {
    tester.widget<Slider>(find.byType(Slider)).onChangeEnd!(80);
    await tester.pump();
    await tester.pump();
    expect(
      find.text('Move through unwatched video by playing it.'),
      findsOneWidget,
    );
  }

  testWidgets('seek warning expires after pause changes playback generation', (
    tester,
  ) async {
    await show(tester);
    await play(tester);
    await rejectSeek(tester);
    await tester.pump(const Duration(seconds: 2));
    await tester.tap(find.byKey(const ValueKey('video-playback-action')));
    await tester.pumpAndSettle();
    expect(players.single.value.isPlaying, isFalse);
    await tester.pump(const Duration(seconds: 3));
    expect(
      find.text('Move through unwatched video by playing it.'),
      findsNothing,
    );
    await remove(tester);
  });

  testWidgets('new seek warning receives its own full expiry interval', (
    tester,
  ) async {
    await show(tester);
    await play(tester);
    await rejectSeek(tester);
    await tester.pump(const Duration(seconds: 3));
    await rejectSeek(tester);
    await tester.pump(const Duration(seconds: 2));
    expect(
      find.text('Move through unwatched video by playing it.'),
      findsOneWidget,
    );
    await tester.pump(const Duration(seconds: 3));
    expect(
      find.text('Move through unwatched video by playing it.'),
      findsNothing,
    );
    await remove(tester);
  });

  testWidgets('seek warning expiry cannot clear a replacement blocking error', (
    tester,
  ) async {
    await show(tester);
    await play(tester);
    await rejectSeek(tester);
    players.single.value = players.single.value.copyWith(
      errorDescription: 'Decoder failed',
    );
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 6));
    expect(
      find.text(
        'Video is unavailable. Try again or contact your training coordinator.',
      ),
      findsOneWidget,
    );
    await remove(tester);
  });

  for (final navigate in [false, true]) {
    testWidgets(
      'pending seek warning is safe on ${navigate ? 'navigation' : 'disposal'}',
      (tester) async {
        await show(tester);
        await play(tester);
        await rejectSeek(tester);
        if (navigate) {
          await tester.tap(find.byTooltip('Back to lessons'));
          await tester.pumpAndSettle();
          expect(find.text('Lessons'), findsOneWidget);
        } else {
          await remove(tester);
        }
        await tester.pump(const Duration(seconds: 6));
        expect(tester.takeException(), isNull);
        if (navigate) await remove(tester);
      },
    );
  }

  for (final status in [401, 403, 404, 409]) {
    testWidgets('denied session $status never initializes media', (
      tester,
    ) async {
      when(
        () => repository.startPlaybackSession(
          1,
          2,
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenThrow(
        ApiError(message: 'Playback access denied', statusCode: status),
      );
      await show(tester);
      await play(tester);
      expect(players, isEmpty);
      expect(find.text('Playback access denied'), findsOneWidget);
      await remove(tester);
    });
  }

  testWidgets(
    'network failure stops player and uses approved cleanup, not unsaved position',
    (tester) async {
      when(
        () => repository.submitPlaybackHeartbeat(
          1,
          2,
          7,
          any(),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenThrow(ApiError(message: 'Network unavailable'));
      await show(tester);
      await play(tester);
      players.single.value = players.single.value.copyWith(
        position: const Duration(seconds: 10),
      );
      await tester.pump(const Duration(seconds: 10));
      await tester.pump();
      expect(players.single.value.isPlaying, isFalse);
      expect(find.text('Network unavailable'), findsOneWidget);
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
      await remove(tester);
    },
  );

  testWidgets(
    'slow initialization leaves observations due when playback advances',
    (tester) async {
      initialization = Completer<void>();
      await show(tester);
      await play(tester);
      await tester.pump(const Duration(seconds: 27));
      verifyNever(
        () => repository.submitPlaybackHeartbeat(
          1,
          2,
          7,
          any(),
          cancelToken: any(named: 'cancelToken'),
        ),
      );
      initialization!.complete();
      await tester.pump();
      await tester.pump();
      final player = players.single;
      expect(player.value.isPlaying, isTrue);
      player.value = player.value.copyWith(
        position: const Duration(seconds: 1),
      );
      await tester.pump();
      await tester.pump();
      verify(
        () => repository.submitPlaybackHeartbeat(
          1,
          2,
          7,
          .99,
          cancelToken: any(named: 'cancelToken'),
        ),
      ).called(1);
      await tester.pump(const Duration(seconds: 4));
      expect(player.value.isPlaying, isTrue);
      expect(
        find.text('Playback session expired. Start again to resume.'),
        findsNothing,
      );
      expect(find.text('Watched coverage: 0%'), findsOneWidget);
      await remove(tester);
    },
  );

  testWidgets(
    'short playback intervals do not postpone observations after buffering',
    (tester) async {
      final observations = <double>[];
      when(
        () => repository.submitPlaybackHeartbeat(
          1,
          2,
          7,
          any(),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer((call) async {
        observations.add(call.positionalArguments[3] as double);
        return progress();
      });
      await show(tester);
      await play(tester);
      final player = players.single;
      for (var cycle = 1; cycle <= 4; cycle++) {
        player.value = player.value.copyWith(
          position: Duration(seconds: cycle * 3),
        );
        await tester.pump(const Duration(seconds: 3));
        player.value = player.value.copyWith(isBuffering: true);
        player.value = player.value.copyWith(isPlaying: false);
        final count = observations.length;
        await tester.pump(const Duration(seconds: 5));
        expect(observations, hasLength(count));
        player.value = player.value.copyWith(isBuffering: false);
        player.value = player.value.copyWith(isPlaying: true);
        await tester.pump();
        await tester.pump();
      }
      expect(player.value.isPlaying, isTrue);
      expect(observations, isNotEmpty);
      expect(observations.every((position) => position > 0), isTrue);
      expect(find.text('Watched coverage: 0%'), findsOneWidget);
      verify(
        () => repository.startPlaybackSession(
          1,
          2,
          cancelToken: any(named: 'cancelToken'),
        ),
      ).called(1);
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
      await remove(tester);
    },
  );

  for (final retryWhileInitializing in [false, true]) {
    testWidgets(
      'initialization expiry and fresh retry (old initialization pending: $retryWhileInitializing)',
      (tester) async {
        final oldInitialization = Completer<void>();
        initialization = oldInitialization;
        await show(tester);
        await play(tester);
        await tester.pump(const Duration(seconds: 31));
        await tester.pump();
        expect(
          find.text('Playback session expired. Start again to resume.'),
          findsOneWidget,
        );
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
        if (!retryWhileInitializing) {
          oldInitialization.complete();
          await tester.pump();
          await tester.pump();
        }
        expect(players.single.value.isPlaying, isFalse);
        verifyNever(
          () => repository.submitPlaybackHeartbeat(
            1,
            2,
            7,
            any(),
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
        verify(
          () => repository.startPlaybackSession(
            1,
            2,
            cancelToken: any(named: 'cancelToken'),
          ),
        ).called(1);
        initialization = null;
        when(
          () => repository.startPlaybackSession(
            1,
            2,
            cancelToken: any(named: 'cancelToken'),
          ),
        ).thenAnswer((_) async => progress(session: 8));
        when(() => repository.protectedMediaRequest(1, 2, 8)).thenAnswer(
          (_) async => ProtectedMediaRequest(
            uri: Uri.parse(
              'https://qa.invalid/api/v1/assignments/1/lessons/2/sessions/8/media/',
            ),
            headers: {'Authorization': 'Bearer qa-token'},
          ),
        );
        when(
          () => repository.endPlaybackSession(
            1,
            2,
            8,
            any(),
            completedNormally: any(named: 'completedNormally'),
            cancelToken: any(named: 'cancelToken'),
          ),
        ).thenAnswer((_) async => progress(session: 8));
        await play(tester);
        if (retryWhileInitializing) {
          oldInitialization.complete();
          await tester.pump();
          await tester.pump();
        }
        expect(players, hasLength(2));
        expect(players.first.disposed, isTrue);
        expect(players.last.value.isPlaying, isTrue);
        expect(requests.last.uri.path, endsWith('/sessions/8/media/'));
        verifyNever(
          () => repository.endPlaybackSession(
            1,
            2,
            8,
            any(),
            completedNormally: any(named: 'completedNormally'),
            cancelToken: any(named: 'cancelToken'),
          ),
        );
        verify(
          () => repository.startPlaybackSession(
            1,
            2,
            cancelToken: any(named: 'cancelToken'),
          ),
        ).called(1);
        await remove(tester);
      },
    );
  }

  testWidgets('a stalled native playing state cannot keep a session alive', (
    tester,
  ) async {
    await show(tester);
    await play(tester);
    await tester.pump(const Duration(seconds: 10));
    await tester.pump();
    await tester.pump(const Duration(seconds: 10));
    await tester.pump();
    await tester.pump(const Duration(seconds: 11));
    await tester.pump();
    verifyNever(
      () => repository.submitPlaybackHeartbeat(
        1,
        2,
        7,
        any(),
        cancelToken: any(named: 'cancelToken'),
      ),
    );
    expect(
      find.text('Playback session expired. Start again to resume.'),
      findsOneWidget,
    );
    expect(find.text('Watched coverage: 0%'), findsOneWidget);
    await remove(tester);
  });

  testWidgets('buffering recovery keeps the session until playback resumes', (
    tester,
  ) async {
    await show(tester);
    await play(tester);
    final player = players.single;
    player.value = player.value.copyWith(isBuffering: true);
    player.value = player.value.copyWith(isPlaying: false);
    await tester.pump(const Duration(seconds: 12));
    verifyNever(
      () => repository.submitPlaybackHeartbeat(
        1,
        2,
        7,
        any(),
        cancelToken: any(named: 'cancelToken'),
      ),
    );

    // Native buffering-end and playing events arrive separately.
    player.value = player.value.copyWith(isBuffering: false);
    await tester.pump(const Duration(seconds: 1));
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
    player.value = player.value.copyWith(isPlaying: true);
    await tester.pump();
    expect(player.value.isPlaying, isTrue);
    expect(find.text('Watched coverage: 0%'), findsOneWidget);
    player.value = player.value.copyWith(position: const Duration(seconds: 9));
    await tester.pump(const Duration(seconds: 10));
    await tester.pump();
    verify(
      () => repository.submitPlaybackHeartbeat(
        1,
        2,
        7,
        8.91,
        cancelToken: any(named: 'cancelToken'),
      ),
    ).called(1);
    verify(
      () => repository.startPlaybackSession(
        1,
        2,
        cancelToken: any(named: 'cancelToken'),
      ),
    ).called(1);
    expect(players, hasLength(1));
    expect(find.text('Watched coverage: 0%'), findsOneWidget);
    // Once recovery finishes, a genuine native pause must still close normally.
    player.value = player.value.copyWith(isPlaying: false);
    await tester.pump();
    await tester.pump();
    verify(
      () => repository.endPlaybackSession(
        1,
        2,
        7,
        any(),
        completedNormally: false,
        cancelToken: any(named: 'cancelToken'),
      ),
    ).called(1);
    await remove(tester);
  });

  for (final interruption in ['explicit pause', 'background', 'error']) {
    testWidgets('$interruption still closes during buffering recovery', (
      tester,
    ) async {
      await show(tester);
      await play(tester);
      final player = players.single;
      player.value = player.value.copyWith(isBuffering: true);
      if (interruption != 'explicit pause') {
        player.value = player.value.copyWith(isPlaying: false);
        player.value = player.value.copyWith(isBuffering: false);
      }
      await tester.pump();
      switch (interruption) {
        case 'explicit pause':
          await tester.tap(find.byKey(const ValueKey('video-playback-action')));
        case 'background':
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.paused,
          );
        case 'error':
          player.value = player.value.copyWith(
            errorDescription: 'Decoder failed',
          );
      }
      await tester.pump();
      await tester.pump();
      expect(player.value.isPlaying, isFalse);
      verify(
        () => repository.endPlaybackSession(
          1,
          2,
          7,
          any(),
          completedNormally: false,
          cancelToken: any(named: 'cancelToken'),
        ),
      ).called(1);
      verifyNever(
        () => repository.submitPlaybackHeartbeat(
          1,
          2,
          7,
          any(),
          cancelToken: any(named: 'cancelToken'),
        ),
      );
      if (interruption == 'background') {
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pump();
        expect(player.value.isPlaying, isFalse);
      }
      await remove(tester);
    });
  }

  testWidgets('buffering cancels heartbeat; expired session stops playback', (
    tester,
  ) async {
    await show(tester);
    await play(tester);
    players.single.value = players.single.value.copyWith(isBuffering: true);
    await tester.pump(const Duration(seconds: 31));
    await tester.pump();
    verifyNever(
      () => repository.submitPlaybackHeartbeat(
        1,
        2,
        7,
        any(),
        cancelToken: any(named: 'cancelToken'),
      ),
    );
    expect(players.single.value.isPlaying, isFalse);
    expect(
      find.text('Playback session expired. Start again to resume.'),
      findsOneWidget,
    );
    await remove(tester);
  });

  testWidgets(
    'account switch discards delayed media initialization and hides previous lesson',
    (tester) async {
      initialization = Completer<void>();
      await show(tester);
      await play(tester);
      auth.change(AuthAuthenticated(employee('B')));
      await tester.pump();
      initialization!.complete();
      await tester.pump();
      await tester.pump();
      expect(find.text('Protected lesson'), findsNothing);
      expect(players.single.disposed, isTrue);
      expect(find.byType(VideoPlayer), findsNothing);
      await remove(tester);
    },
  );

  testWidgets('logout stops active video and removes protected content', (
    tester,
  ) async {
    await show(tester);
    await play(tester);
    auth.change(AuthUnauthenticated());
    await tester.pump();
    await tester.pump();
    expect(players.single.disposed, isTrue);
    expect(find.byType(VideoPlayer), findsNothing);
    expect(find.text('Protected lesson'), findsNothing);
    await remove(tester);
  });

  testWidgets(
    'route identity change closes old session and never reuses its media or credit',
    (tester) async {
      final ended = Completer<LessonProgress>();
      when(
        () => repository.endPlaybackSession(
          1,
          2,
          7,
          any(),
          completedNormally: false,
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer((_) => ended.future);
      await show(tester);
      await play(tester);
      router.go('/video?assignment=2');
      await tester.pump();
      await tester.pump();
      expect(players.single.disposed, isTrue);
      expect(find.byType(VideoPlayer), findsNothing);
      expect(find.text('Other video'), findsOneWidget);
      ended.complete(progress());
      await tester.pump();
      await tester.pump();
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
      expect(find.text('Watched coverage: 0%'), findsOneWidget);
      await remove(tester);
    },
  );

  for (final mode in [ThemeMode.light, ThemeMode.dark]) {
    testWidgets(
      'player stays dark with ${mode.name} surroundings across viewport sizes',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        tester.platformDispatcher.textScaleFactorTestValue = 1.6;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        await show(tester, mode: mode);
        for (final size in [
          const Size(320, 568),
          const Size(390, 844),
          const Size(844, 390),
          const Size(768, 1024),
          const Size(1440, 900),
        ]) {
          tester.view.physicalSize = size;
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          final surroundings = Theme.of(
            tester.element(find.text('Protected lesson')),
          );
          expect(
            surroundings.brightness,
            mode == ThemeMode.light ? Brightness.light : Brightness.dark,
          );
          final panel = tester.widget<Container>(
            find.byKey(const ValueKey('video-coverage-panel')),
          );
          expect(
            (panel.decoration! as BoxDecoration).color,
            surroundings.colorScheme.surfaceContainerLow,
          );
          expect(
            tester.widget<Scaffold>(find.byType(Scaffold)).backgroundColor,
            surroundings.scaffoldBackgroundColor,
          );
          expect(
            Theme.of(tester.element(find.byTooltip('Back to lessons')))
                .brightness,
            surroundings.brightness,
          );
          expect(
            Theme.of(
              tester.element(
                find.byKey(const ValueKey('video-playback-action')),
              ),
            ).brightness,
            Brightness.dark,
          );
          expect(
            tester.getSize(find.byType(Slider)).width,
            lessThan(size.width),
          );
          expect(
            find.text('Watch 80% to complete this lesson.'),
            findsOneWidget,
          );
          final colors = Theme.of(
            tester.element(find.byKey(const ValueKey('video-playback-action'))),
          ).colorScheme;
          double contrast(Color a, Color b) {
            final light = a.computeLuminance();
            final dark = b.computeLuminance();
            return (light + .05) / (dark + .05);
          }

          expect(
            contrast(colors.onSurface, colors.surface),
            greaterThanOrEqualTo(4.5),
          );
          expect(
            contrast(colors.primary, colors.onPrimary),
            greaterThanOrEqualTo(4.5),
          );
        }
        await remove(tester);
      },
    );
  }

  testWidgets(
    'changing app appearance preserves the active dark player and session',
    (tester) async {
      await show(tester);
      await play(tester);
      final player = players.single;
      await show(tester, mode: ThemeMode.dark);
      await show(tester, mode: ThemeMode.light);
      expect(players.single, same(player));
      expect(player.value.isPlaying, isTrue);
      expect(
        Theme.of(tester.element(find.text('Protected lesson'))).brightness,
        Brightness.light,
      );
      expect(
        Theme.of(tester.element(find.byType(ProtectedVideoSurface))).brightness,
        Brightness.dark,
      );
      verify(
        () => repository.startPlaybackSession(
          1,
          2,
          cancelToken: any(named: 'cancelToken'),
        ),
      ).called(1);
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
      await remove(tester);
    },
  );

  testWidgets(
    'background during delayed start closes the returned session without loading media',
    (tester) async {
      final started = Completer<LessonProgress>();
      when(
        () => repository.startPlaybackSession(
          1,
          2,
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer((_) => started.future);
      await show(tester);
      await play(tester);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      started.complete(progress(resume: 15, watched: 15));
      await tester.pump();
      await tester.pump();
      expect(players, isEmpty);
      verify(
        () => repository.endPlaybackSession(
          1,
          2,
          7,
          15,
          completedNormally: false,
          cancelToken: any(named: 'cancelToken'),
        ),
      ).called(1);
      verifyNever(() => repository.protectedMediaRequest(1, 2, 7));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await remove(tester);
    },
  );

  testWidgets(
    'native end reports closure but never awards completion locally',
    (tester) async {
      when(
        () => repository.endPlaybackSession(
          1,
          2,
          7,
          any(),
          completedNormally: true,
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer((_) async => progress(watched: 50));
      await show(tester);
      await play(tester);
      players.single.value = players.single.value.copyWith(
        position: const Duration(seconds: 100),
        isPlaying: false,
        isCompleted: true,
      );
      await tester.pump();
      await tester.pump();
      verify(
        () => repository.endPlaybackSession(
          1,
          2,
          7,
          99,
          completedNormally: true,
          cancelToken: any(named: 'cancelToken'),
        ),
      ).called(1);
      expect(find.text('Watched coverage: 50%'), findsOneWidget);
      expect(find.text('Lesson completed'), findsNothing);
      await remove(tester);
    },
  );

  testWidgets('timeline drag suspends fade until interaction ends', (
    tester,
  ) async {
    await show(tester);
    await play(tester);
    final slider = find.byType(Slider);
    final opacity = find.ancestor(
      of: slider,
      matching: find.byType(AnimatedOpacity),
    );
    final drag = await tester.startGesture(tester.getCenter(slider));
    await tester.pump(const Duration(seconds: 5));
    expect(tester.widget<AnimatedOpacity>(opacity).opacity, 1);
    await drag.up();
    await tester.pumpAndSettle();
    expect(tester.widget<AnimatedOpacity>(opacity).opacity, 1);
    await tester.pump(const Duration(seconds: 4));
    expect(tester.widget<AnimatedOpacity>(opacity).opacity, 0);
    await remove(tester);
  });

  testWidgets('preparation and paused status reflect the actual player state', (
    tester,
  ) async {
    initialization = Completer<void>();
    await show(tester);
    expect(find.text('Ready to play'), findsOneWidget);
    await play(tester);
    expect(find.text('Preparing video'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    initialization!.complete();
    await tester.pump();
    await tester.pump();
    expect(find.text('Playing'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('video-playback-action')));
    await tester.pump();
    await tester.pump();
    expect(find.text('Playing'), findsNothing);
    expect(find.text('Paused'), findsOneWidget);
    expect(find.text('Watched coverage: 0%'), findsOneWidget);
    await remove(tester);
  });

  testWidgets(
    'keyboard focus keeps controls visible and shows a focus outline',
    (tester) async {
      final previous = FocusManager.instance.highlightStrategy;
      FocusManager.instance.highlightStrategy =
          FocusHighlightStrategy.alwaysTraditional;
      addTearDown(() => FocusManager.instance.highlightStrategy = previous);
      await show(tester);
      await play(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      final button = tester.widget<IconButton>(
        find.byKey(const ValueKey('video-playback-action')),
      );
      expect(button.style!.side!.resolve({WidgetState.focused})!.width, 2);
      await tester.pump(const Duration(seconds: 5));
      expect(
        tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity)).opacity,
        1,
      );
      await remove(tester);
    },
  );

  testWidgets('accessibility navigation keeps playback controls visible', (
    tester,
  ) async {
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        FakeAccessibilityFeatures(accessibleNavigation: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    await show(tester);
    await play(tester);
    await tester.pump(const Duration(seconds: 5));
    expect(
      tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity)).opacity,
      1,
    );
    await remove(tester);
  });

  for (final leaveGroup in [false, true]) {
    testWidgets(
      leaveGroup
          ? 'slider and button traversal retains focus then restores auto-hide outside'
          : 'focused pause button remains visible beyond the auto-hide timeout',
      (tester) async {
        final previous = FocusManager.instance.highlightStrategy;
        FocusManager.instance.highlightStrategy =
            FocusHighlightStrategy.alwaysTraditional;
        addTearDown(() => FocusManager.instance.highlightStrategy = previous);
        await show(tester);
        await play(tester);
        final playerFocus = find
            .ancestor(
              of: find.byType(VideoPlayer),
              matching: find.byType(FocusableActionDetector),
            )
            .first;
        final group = tester
            .element(playerFocus)
            .findAncestorWidgetOfExactType<Focus>()!;
        expect(group.canRequestFocus, isFalse);
        expect(group.skipTraversal, isTrue);
        final frame = find
            .descendant(of: playerFocus, matching: find.byType(Container))
            .first;
        Focus.of(tester.element(frame)).requestFocus();
        await tester.pump();

        bool focusedWithin(Finder control) => find
            .descendant(
              of: control,
              matching: find.byElementPredicate(
                (element) =>
                    element == FocusManager.instance.primaryFocus?.context,
              ),
              matchRoot: true,
            )
            .evaluate()
            .isNotEmpty;

        Future<void> tab({bool backwards = false}) async {
          if (backwards) {
            await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
          }
          await tester.sendKeyEvent(LogicalKeyboardKey.tab);
          if (backwards) {
            await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
          }
          await tester.pump();
        }

        final slider = find.byType(Slider);
        final button = find.byKey(const ValueKey('video-playback-action'));
        await tab();
        expect(focusedWithin(slider), isTrue);
        await tab();
        expect(focusedWithin(button), isTrue);
        await tester.pump(const Duration(seconds: 5));
        expect(
          tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity)).opacity,
          1,
        );
        expect(focusedWithin(button), isTrue);

        if (leaveGroup) {
          await tab(backwards: true);
          expect(focusedWithin(slider), isTrue);
          await tester.pump(const Duration(seconds: 5));
          expect(
            tester
                .widget<AnimatedOpacity>(find.byType(AnimatedOpacity))
                .opacity,
            1,
          );
          expect(focusedWithin(slider), isTrue);
          await tab();
          expect(focusedWithin(button), isTrue);
          await tab();
          expect(focusedWithin(find.byTooltip('Back to lessons')), isTrue);
          await tester.pump(const Duration(seconds: 5));
          expect(
            tester
                .widget<AnimatedOpacity>(find.byType(AnimatedOpacity))
                .opacity,
            0,
          );
          expect(focusedWithin(find.byTooltip('Back to lessons')), isTrue);
        }
        await remove(tester);
      },
    );
  }

  testWidgets(
    'completed presentation comes only from confirmed server progress',
    (tester) async {
      when(
        () => repository.endPlaybackSession(
          1,
          2,
          7,
          any(),
          completedNormally: false,
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer((_) async => progress(watched: 80, completed: true));
      await show(tester);
      await play(tester);
      expect(find.text('Lesson completed'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('video-playback-action')));
      await tester.pump();
      await tester.pump();
      expect(find.text('Lesson completed'), findsOneWidget);
      expect(
        tester
            .widget<LinearProgressIndicator>(
              find.byType(LinearProgressIndicator),
            )
            .value,
        .8,
      );
      await remove(tester);
    },
  );

  for (final playing in [false, true]) {
    testWidgets(
      'cinematic learner page ${playing ? 'playing' : 'paused'} preview',
      (tester) async {
        await loadPlayerPreviewFonts(tester);
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(412, 915);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        when(
          () => repository.startPlaybackSession(
            1,
            2,
            cancelToken: any(named: 'cancelToken'),
          ),
        ).thenAnswer((_) async => progress(resume: 55, watched: 74));
        when(
          () => repository.endPlaybackSession(
            1,
            2,
            7,
            any(),
            completedNormally: false,
            cancelToken: any(named: 'cancelToken'),
          ),
        ).thenAnswer((_) async => progress(resume: 55, watched: 74));
        await show(tester);
        await play(tester);
        if (!playing) {
          await tester.tap(find.byKey(const ValueKey('video-playback-action')));
        }
        await tester.pumpAndSettle();
        expect(find.text('Watched coverage: 74%'), findsOneWidget);
        expect(
          find.byKey(const ValueKey('video-playback-action')),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
        await capturePlayerPreview(
          tester,
          const ValueKey('learner-page-preview'),
          'screen_portrait_${playing ? 'playing' : 'paused'}',
        );
        await remove(tester);
      },
    );
  }

  testWidgets('Android fullscreen and secure lease are restored on exit', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final calls = <MethodCall>[];
    const channel = MethodChannel('gardensneed/protected_video');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      calls.add(call);
      return call.method == 'acquire' ? 9 : null;
    });
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      ),
    );
    await show(tester);
    await play(tester);
    expect(find.text('Watched coverage: 0%'), findsOneWidget);
    await tester.tap(find.byTooltip('Fullscreen'));
    await tester.pump();
    expect(calls.last.arguments, {'lease': 9, 'enabled': true});
    expect(find.text('Watched coverage: 0%'), findsNothing);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(calls.last.arguments, {'lease': 9, 'enabled': false});
    expect(find.text('Watched coverage: 0%'), findsOneWidget);
    await tester.tap(find.byTooltip('Back to lessons'));
    await tester.pumpAndSettle();
    expect(calls.where((c) => c.method == 'release').single.arguments, 9);
    await remove(tester);
  });
}
