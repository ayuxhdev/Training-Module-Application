import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';
import 'package:video_player/video_player.dart';
import 'package:training_app/core/errors/api_error.dart';
import 'package:training_app/features/auth/domain/models/auth_state.dart';
import 'package:training_app/features/auth/domain/models/employee.dart';
import 'package:training_app/features/auth/presentation/controllers/auth_controller.dart';
import 'package:training_app/features/learning/data/repositories/learning_repository.dart';
import 'package:training_app/features/learning/domain/models/assignment_detail.dart';
import 'package:training_app/features/learning/domain/models/protected_media_request.dart';
import 'package:training_app/features/learning/presentation/controllers/learning_controller.dart';
import 'package:training_app/features/learning/presentation/screens/video_lesson_screen.dart';

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
}

class Player extends VideoPlayerController {
  final Completer<void>? initialization;
  bool disposed = false;
  Player({this.initialization})
    : super.networkUrl(Uri.parse('https://qa.invalid/protected'));
  @override
  Future<void> initialize() async {
    await initialization?.future;
    value = const VideoPlayerValue(
      duration: Duration(seconds: 100),
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
  Future<void> seekTo(Duration position) async =>
      value = value.copyWith(position: position);
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
}) => LessonProgress(
  resumePosition: resume,
  watchedSeconds: watched,
  progressPercent: watched,
  completed: completed,
  sessionId: 7,
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
  String lessonType = 'VIDEO';
  AssignmentDetail detail() => AssignmentDetail(
    id: 1,
    trainingId: 1,
    trainingTitle: 'QA',
    versionNumber: 1,
    status: 'IN_PROGRESS',
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
            body: '',
            progress: progress(),
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
    lessonType = 'VIDEO';
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
    container = ProviderContainer(
      overrides: [
        authControllerProvider.overrideWith(() => auth),
        learningRepositoryProvider.overrideWithValue(repository),
        assignmentDetailProvider(1).overrideWith((_) async => detail()),
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
          final player = Player(initialization: initialization);
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
  Future<void> show(WidgetTester tester) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> play(WidgetTester tester) async {
    await tester.tap(find.text('Play'));
    await tester.pump();
    await tester.pump();
  }

  Future<void> remove(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    debugDefaultTargetPlatformOverride = null;
  }

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
      expect(find.text('Unique video coverage: 0%'), findsOneWidget);
      expect(find.textContaining('Completed ·'), findsNothing);
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
      await tester.tap(find.text('Pause'));
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
      expect(find.text('Unique video coverage: 0%'), findsOneWidget);
      await remove(tester);
    },
  );

  testWidgets(
    'player layout fits phone, tablet and desktop widths in the light app theme',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      await show(tester);
      for (final size in [
        const Size(390, 844),
        const Size(768, 1024),
        const Size(1440, 900),
      ]) {
        tester.view.physicalSize = size;
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(
          Theme.of(tester.element(find.text('Play'))).brightness,
          Brightness.dark,
        );
        expect(tester.getSize(find.byType(Slider)).width, lessThan(size.width));
      }
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
      expect(find.text('Unique video coverage: 50%'), findsOneWidget);
      expect(find.textContaining('Completed ·'), findsNothing);
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
    expect(find.text('Unique video coverage: 0%'), findsOneWidget);
    await tester.tap(find.byTooltip('Fullscreen'));
    await tester.pump();
    expect(calls.last.arguments, {'lease': 9, 'enabled': true});
    expect(find.text('Unique video coverage: 0%'), findsNothing);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(calls.last.arguments, {'lease': 9, 'enabled': false});
    expect(find.text('Unique video coverage: 0%'), findsOneWidget);
    await tester.tap(find.byTooltip('Back to lessons'));
    await tester.pumpAndSettle();
    expect(calls.where((c) => c.method == 'release').single.arguments, 9);
    await remove(tester);
  });
}
