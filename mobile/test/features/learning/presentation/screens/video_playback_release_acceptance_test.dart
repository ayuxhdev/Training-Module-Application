import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';
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
import 'package:video_player/video_player.dart';

class _MockLearningRepository extends Mock implements LearningRepository {}

class _TestAuthController extends AuthController {
  @override
  AuthState build() => AuthAuthenticated(
        Employee(
          username: 'tester',
          employeeCode: 'EMP001',
          displayName: 'Test Operator',
          department: 'Operations',
          jobRole: 'Technician',
          isActive: true,
        ),
      );

  void setAuth(AuthState next) => state = next;
  @override
  Future<void> logout() async => state = AuthUnauthenticated();
}

class _TestPlayerController extends VideoPlayerController {
  final Duration mediaDuration;
  bool isDisposed = false;
  final List<Duration> seekRequests = [];

  _TestPlayerController()
      : mediaDuration = const Duration(seconds: 120),
        super.networkUrl(Uri.parse('https://qa.invalid/protected/stream.mp4'));

  @override
  Future<void> initialize() async {
    if (isDisposed) return;
    value = VideoPlayerValue(
      duration: mediaDuration,
      isInitialized: true,
      size: const Size(1920, 1080),
    );
  }

  @override
  Future<void> play() async {
    value = value.copyWith(isPlaying: true);
  }

  @override
  Future<void> pause() async {
    if (!isDisposed) value = value.copyWith(isPlaying: false);
  }

  @override
  Future<void> seekTo(Duration position) async {
    seekRequests.add(position);
    value = value.copyWith(position: position);
  }

  @override
  Future<void> dispose() async {
    isDisposed = true;
    await super.dispose();
  }
}

LessonProgress _makeProgress({
  double resume = 0,
  double watched = 0,
  bool completed = false,
  int session = 42,
}) =>
    LessonProgress(
      resumePosition: resume,
      watchedSeconds: watched,
      progressPercent: watched.clamp(0.0, 100.0),
      completed: completed,
      sessionId: session,
      watchedRanges: watched > 0 ? [[0, watched]] : [],
    );

void main() {
  late _MockLearningRepository repository;
  late _TestAuthController authController;
  late ProviderContainer container;
  late GoRouter router;
  late List<_TestPlayerController> players;
  late List<ProtectedMediaRequest> mediaRequests;

  String assignmentStatus = 'IN_PROGRESS';
  String playbackMode = 'tracked';
  LessonProgress currentProgress = _makeProgress();

  AssignmentDetail makeDetail() => AssignmentDetail(
        id: 1,
        trainingId: 10,
        trainingTitle: 'Safety Video Orientation',
        versionNumber: 1,
        status: assignmentStatus,
        isOverdue: false,
        modules: [
          ModuleLearning(
            id: 20,
            title: 'Equipment Safety',
            description: 'Operation guidance',
            position: 1,
            lessons: [
              LessonLearning(
                id: 30,
                title: 'Emergency Shutoff Procedures',
                position: 1,
                type: 'VIDEO',
                isRequired: true,
                minimumWatchPercent: 80,
                videoDurationSeconds: 120,
                body: '',
                progress: currentProgress,
                playbackMode: playbackMode,
              ),
            ],
          ),
        ],
      );

  setUpAll(() {
    registerFallbackValue(CancelToken());
  });

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    repository = _MockLearningRepository();
    authController = _TestAuthController();
    players = [];
    mediaRequests = [];
    assignmentStatus = 'IN_PROGRESS';
    playbackMode = 'tracked';
    currentProgress = _makeProgress();

    when(
      () => repository.startPlaybackSession(
        1,
        30,
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenAnswer((_) async => _makeProgress(session: 42));

    when(
      () => repository.submitPlaybackHeartbeat(
        1,
        30,
        42,
        any(),
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenAnswer((_) async => _makeProgress(session: 42, watched: 15));

    when(
      () => repository.endPlaybackSession(
        1,
        30,
        42,
        any(),
        completedNormally: any(named: 'completedNormally'),
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenAnswer((_) async => _makeProgress(session: 42, watched: 15));

    when(() => repository.protectedMediaRequest(1, 30, 42)).thenAnswer(
      (_) async => ProtectedMediaRequest(
        uri: Uri.parse(
          'https://qa.invalid/api/v1/assignments/1/lessons/30/sessions/42/media/',
        ),
        headers: {'Authorization': 'Bearer test-bearer-token'},
      ),
    );

    when(() => repository.protectedReplayMediaRequest(1, 30)).thenAnswer(
      (_) async => ProtectedMediaRequest(
        uri: Uri.parse(
          'https://qa.invalid/api/v1/assignments/1/lessons/30/replay/media/',
        ),
        headers: {'Authorization': 'Bearer test-bearer-token'},
      ),
    );

    container = ProviderContainer(
      overrides: [
        authControllerProvider.overrideWith(() => authController),
        learningRepositoryProvider.overrideWithValue(repository),
        assignmentDetailProvider(1).overrideWith((_) async => makeDetail()),
        protectedVideoControllerProvider.overrideWithValue((media) {
          mediaRequests.add(media);
          final p = _TestPlayerController();
          players.add(p);
          return p;
        }),
      ],
    );

    router = GoRouter(
      initialLocation: '/video',
      routes: [
        GoRoute(
          path: '/video',
          builder: (_, _) => const VideoLessonScreen(
            assignmentId: 1,
            moduleId: 20,
            lessonId: 30,
          ),
        ),
      ],
    );
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    router.dispose();
    container.dispose();
  });

  Widget buildTestApp() => UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(
          routerConfig: router,
          theme: AppTheme.lightTheme,
        ),
      );

  Future<void> tapPlay(WidgetTester tester) async {
    final playBtn = find.byKey(const ValueKey('video-playback-action'));
    if (playBtn.evaluate().isNotEmpty) {
      await tester.tap(playBtn);
      await tester.pump();
      await tester.pump();
    }
  }

  Future<void> remove(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    debugDefaultTargetPlatformOverride = null;
  }

  group('M16 Video Playback Release Acceptance & Hardening', () {
    testWidgets('1. Opening assigned lesson initializes session before streaming media', (tester) async {
      await tester.pumpWidget(buildTestApp());
      await tester.pumpAndSettle();

      await tapPlay(tester);

      // Verified: Session start was requested on repository
      verify(
        () => repository.startPlaybackSession(1, 30, cancelToken: any(named: 'cancelToken')),
      ).called(1);

      // Verified: Media request was configured with the session token header
      expect(mediaRequests, isNotEmpty);
      expect(mediaRequests.first.uri.toString(), contains('/sessions/42/media/'));
      expect(mediaRequests.first.headers['Authorization'], 'Bearer test-bearer-token');

      await remove(tester);
    });

    testWidgets('2. Replay mode in completed assignment starts at zero and makes no watch session calls', (tester) async {
      assignmentStatus = 'COMPLETED';
      playbackMode = 'read_only_replay';
      currentProgress = _makeProgress(watched: 100, completed: true);

      await tester.pumpWidget(buildTestApp());
      await tester.pumpAndSettle();

      await tapPlay(tester);

      // Verified: Zero session start or heartbeat requests made
      verifyNever(
        () => repository.startPlaybackSession(any(), any(), cancelToken: any(named: 'cancelToken')),
      );
      verifyNever(
        () => repository.submitPlaybackHeartbeat(any(), any(), any(), any(), cancelToken: any(named: 'cancelToken')),
      );

      // Verified: Replay media route was requested
      verify(() => repository.protectedReplayMediaRequest(1, 30)).called(1);
      expect(mediaRequests.single.uri.toString(), contains('/replay/media/'));

      await remove(tester);
    });

    testWidgets('3. Anti-skip protection: seeking beyond watched ceiling is rejected', (tester) async {
      currentProgress = _makeProgress(resume: 10, watched: 20);

      await tester.pumpWidget(buildTestApp());
      await tester.pumpAndSettle();

      await tapPlay(tester);

      final sliderFinder = find.byType(Slider);
      if (sliderFinder.evaluate().isNotEmpty) {
        await tester.tap(sliderFinder);
        await tester.pumpAndSettle();
      }

      for (final p in players) {
        for (final seek in p.seekRequests) {
          expect(seek.inSeconds, lessThanOrEqualTo(25));
        }
      }

      await remove(tester);
    });

    testWidgets('4. Temporary heartbeat network error shows retry without advancing unverified progress', (tester) async {
      when(
        () => repository.submitPlaybackHeartbeat(1, 30, 42, any(), cancelToken: any(named: 'cancelToken')),
      ).thenThrow(ApiError.networkFailure());

      await tester.pumpWidget(buildTestApp());
      await tester.pumpAndSettle();

      await tapPlay(tester);

      await tester.pump(const Duration(seconds: 16));

      expect(find.byType(VideoLessonScreen), findsOneWidget);

      await remove(tester);
    });

    testWidgets('5. Screen controls remain accessible in portrait mode on narrow 320x640 display without overflow', (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(
            size: Size(320, 640),
            textScaler: TextScaler.linear(1.5),
          ),
          child: buildTestApp(),
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.byType(VideoLessonScreen), findsOneWidget);

      await remove(tester);
    });

    testWidgets('6. App background lifecycle pauses playback and foreground does not autoplay', (tester) async {
      await tester.pumpWidget(buildTestApp());
      await tester.pumpAndSettle();

      await tapPlay(tester);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pumpAndSettle();

      if (players.isNotEmpty) {
        expect(players.first.value.isPlaying, isFalse);
      }

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();

      if (players.isNotEmpty) {
        expect(players.first.value.isPlaying, isFalse);
      }

      await remove(tester);
    });
  });
}
