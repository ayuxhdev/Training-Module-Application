import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player/video_player.dart';
import 'package:training_app/features/learning/presentation/widgets/protected_video_surface.dart';

import '../video_player_preview.dart';

class SurfacePlayer extends VideoPlayerController {
  SurfacePlayer()
    : super.networkUrl(Uri.parse('https://qa.invalid/protected')) {
    value = const VideoPlayerValue(
      duration: Duration(seconds: 100),
      position: Duration(seconds: 20),
      size: Size(900, 1600),
      isInitialized: true,
    );
  }
}

void main() {
  late SurfacePlayer player;
  int toggles = 0;
  int reveals = 0;
  final seeks = <double>[];
  final scrubbing = <bool>[];
  final playbackRequests = <bool>[];

  setUp(() {
    player = SurfacePlayer();
    toggles = 0;
    reveals = 0;
    seeks.clear();
    scrubbing.clear();
    playbackRequests.clear();
  });
  tearDown(() => player.dispose());

  Future<void> show(
    WidgetTester tester, {
    bool visible = true,
    bool busy = false,
    bool fullscreen = false,
    bool reducedMotion = false,
    double textScale = 1,
    double coverage = 0,
    List<List<double>> ranges = const [],
    String? message,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: MediaQuery(
          data: MediaQueryData(
            size: tester.view.physicalSize / tester.view.devicePixelRatio,
            disableAnimations: reducedMotion,
            textScaler: TextScaler.linear(textScale),
          ),
          child: Scaffold(
            body: Align(
              alignment: Alignment.topCenter,
              child: SizedBox(
                height: fullscreen
                    ? tester.view.physicalSize.height /
                          tester.view.devicePixelRatio
                    : 260,
                child: RepaintBoundary(
                  key: const ValueKey('player-preview'),
                  child: ProtectedVideoSurface(
                    controller: player,
                    busy: busy,
                    controlsVisible: visible,
                    canPlay: true,
                    canSeek: true,
                    fullscreen: fullscreen,
                    coveragePercent: coverage,
                    watchedRanges: ranges,
                    message: message,
                    title: fullscreen ? 'Safe sprayer calibration' : null,
                    onToggleControls: () => toggles++,
                    onRevealControls: () => reveals++,
                    onPlaybackRequested: (playing) {
                      playbackRequests.add(playing);
                      player.value = player.value.copyWith(isPlaying: playing);
                    },
                    onSeek: seeks.add,
                    onScrubbingChanged: scrubbing.add,
                    onFullscreen: () {},
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  for (final playing in [true, false]) {
    testWidgets(
      'playback action follows rendered intent when native state changes ($playing)',
      (tester) async {
        player.value = player.value.copyWith(isPlaying: playing);
        await show(tester);
        final action = tester.widget<IconButton>(
          find.byKey(const ValueKey('video-playback-action')),
        );
        expect(action.tooltip, playing ? 'Pause' : 'Resume video');
        player.value = player.value.copyWith(isPlaying: !playing);
        action.onPressed!();
        expect(playbackRequests, hasLength(1));
        expect(playbackRequests.single, !playing);
        expect(player.value.isPlaying, !playing);
      },
    );
  }

  testWidgets(
    'blocking feedback survives hidden controls and clears when resolved',
    (tester) async {
      final semantics = tester.ensureSemantics();
      const message = 'Playback session expired. Start again to resume.';
      await show(tester, message: message);
      await show(tester, visible: false, message: message);
      await tester.pump(const Duration(seconds: 5));
      expect(find.text(message), findsOneWidget);
      expect(find.bySemanticsLabel(message), findsOneWidget);
      final hiddenAncestors = find.ancestor(
        of: find.text(message),
        matching: find.byType(ExcludeSemantics),
      );
      for (final widget in tester.widgetList<ExcludeSemantics>(
        hiddenAncestors,
      )) {
        expect(widget.excluding, isFalse);
      }
      await show(tester);
      expect(find.text(message), findsNothing);
      expect(
        find.byKey(const ValueKey('video-playback-action')),
        findsOneWidget,
      );
      semantics.dispose();
    },
  );

  testWidgets(
    'play and pause use the existing callback and actual media state',
    (tester) async {
      await show(tester);
      expect(find.text('Paused'), findsOneWidget);
      expect(find.textContaining('0:20'), findsOneWidget);
      expect(find.textContaining('1:40'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('video-playback-action')));
      await tester.pumpAndSettle();
      expect(find.text('Playing'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('video-playback-action')));
      await tester.pumpAndSettle();
      expect(find.text('Paused'), findsOneWidget);
      expect(seeks, isEmpty);
    },
  );

  testWidgets('scrubbing previews time and commits only through onSeek', (
    tester,
  ) async {
    await show(tester);
    final slider = tester.widget<Slider>(find.byType(Slider));
    slider.onChangeStart!(35);
    slider.onChanged!(35);
    await tester.pump();
    expect(find.textContaining('0:35'), findsOneWidget);
    expect(player.value.position, const Duration(seconds: 20));
    expect(seeks, isEmpty);
    tester.widget<Slider>(find.byType(Slider)).onChangeEnd!(35);
    await tester.pump();
    expect(scrubbing, [true, false]);
    expect(seeks, [35]);
    expect(find.textContaining('0:20'), findsOneWidget);
  });

  testWidgets(
    'busy and buffering states announce loading and disable busy actions',
    (tester) async {
      await show(tester, busy: true);
      expect(find.text('Preparing video'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(
        tester
            .widget<IconButton>(
              find.byKey(const ValueKey('video-playback-action')),
            )
            .onPressed,
        isNull,
      );
      expect(tester.widget<Slider>(find.byType(Slider)).onChanged, isNull);
      player.value = player.value.copyWith(isPlaying: true, isBuffering: true);
      await show(tester);
      expect(find.text('Buffering'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    },
  );

  testWidgets('hidden controls cannot intercept input or appear in semantics', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    try {
      await show(tester, visible: false);
      expect(find.bySemanticsLabel('Playback position'), findsNothing);
      expect(find.bySemanticsLabel('Fullscreen'), findsNothing);
      await tester.tapAt(tester.getCenter(find.byType(Slider)));
      await tester.pump();
      expect(toggles, 1);
      expect(seeks, isEmpty);
      expect(player.value.isPlaying, isFalse);
    } finally {
      semantics.dispose();
    }
  });

  testWidgets(
    'timeline semantics, touch targets and reduced motion are preserved',
    (tester) async {
      final semantics = tester.ensureSemantics();
      try {
        await show(tester, reducedMotion: true);
        expect(find.bySemanticsLabel('Playback position'), findsOneWidget);
        final slider = tester.widget<Slider>(find.byType(Slider));
        expect(slider.semanticFormatterCallback!(20), '0:20 of 1:40');
        expect(
          tester
              .getSize(find.byKey(const ValueKey('video-playback-action')))
              .height,
          greaterThanOrEqualTo(48),
        );
        expect(
          tester.getSize(find.byTooltip('Fullscreen')).height,
          greaterThanOrEqualTo(48),
        );
        expect(
          tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity)).duration,
          Duration.zero,
        );
        expect(
          tester
              .widget<AnimatedSwitcher>(find.byType(AnimatedSwitcher))
              .duration,
          Duration.zero,
        );
        expect(find.byTooltip('Fullscreen'), findsOneWidget);
        await show(tester, fullscreen: true);
        expect(find.byTooltip('Exit fullscreen'), findsOneWidget);
      } finally {
        semantics.dispose();
      }
    },
  );

  testWidgets('keyboard traversal can reveal hidden controls', (tester) async {
    final previous = FocusManager.instance.highlightStrategy;
    FocusManager.instance.highlightStrategy =
        FocusHighlightStrategy.alwaysTraditional;
    addTearDown(() => FocusManager.instance.highlightStrategy = previous);
    await show(tester, visible: false);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(reveals, greaterThan(0));
    expect(seeks, isEmpty);
    expect(player.value.isPlaying, isFalse);
  });

  testWidgets(
    'portrait video retains its ratio on small and fullscreen landscapes',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      for (final size in [const Size(320, 568), const Size(844, 390)]) {
        tester.view.physicalSize = size;
        await show(
          tester,
          fullscreen: size.width > size.height,
          textScale: 1.6,
        );
        final videoSize = tester.getSize(find.byType(VideoPlayer));
        expect(videoSize.width / videoSize.height, closeTo(9 / 16, .001));
        expect(videoSize.width, lessThanOrEqualTo(size.width));
        expect(videoSize.height, lessThanOrEqualTo(size.height));
        expect(tester.getSize(find.byType(Slider)).width, lessThan(size.width));
        expect(tester.takeException(), isNull);
      }
    },
  );

  testWidgets(
    'one stable playback action moves from center to the floating deck',
    (tester) async {
      final previous = FocusManager.instance.highlightStrategy;
      FocusManager.instance.highlightStrategy =
          FocusHighlightStrategy.alwaysTraditional;
      addTearDown(() => FocusManager.instance.highlightStrategy = previous);
      await show(tester);
      final action = find.byKey(const ValueKey('video-playback-action'));
      final frame = find.byKey(const ValueKey('cinematic-video-stage'));
      final deck = find.byKey(const ValueKey('floating-control-deck'));
      expect(action, findsOneWidget);
      expect(
        tester.getCenter(action).dx,
        closeTo(tester.getCenter(frame).dx, 1),
      );
      expect(
        tester.getRect(frame).contains(tester.getRect(deck).topLeft),
        isTrue,
      );
      expect(
        tester.getRect(deck).bottom,
        lessThan(tester.getRect(frame).bottom),
      );
      expect(tester.getRect(action).bottom, lessThan(tester.getRect(deck).top));
      final focus = tester.widget<IconButton>(action).focusNode!;
      focus.requestFocus();
      await tester.pump();
      await tester.tap(action);
      await tester.pumpAndSettle();
      expect(action, findsOneWidget);
      expect(focus.hasFocus, isTrue);
      expect(tester.widget<IconButton>(action).focusNode, same(focus));
      expect(tester.getRect(deck).contains(tester.getCenter(action)), isTrue);
      expect(find.byTooltip('Pause'), findsOneWidget);
    },
  );

  testWidgets(
    'coverage rail preserves unwatched gaps independently of the playhead',
    (tester) async {
      await show(
        tester,
        coverage: 20,
        ranges: [
          [0, 10],
          [40, 50],
        ],
      );
      final painter = tester
          .widget<CustomPaint>(find.byKey(const ValueKey('watched-ranges')))
          .painter!;
      final recorder = ui.PictureRecorder();
      painter.paint(Canvas(recorder), const Size(100, 3));
      final picture = recorder.endRecording();
      final result = await tester.runAsync(() async {
        final image = await picture.toImage(100, 3);
        final bytes = await image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        );
        image.dispose();
        return bytes!;
      });
      picture.dispose();
      int alpha(int x) => result!.getUint8((100 + x) * 4 + 3);
      expect(alpha(5), greaterThan(0));
      expect(alpha(20), 0);
      expect(alpha(45), greaterThan(0));
      expect(alpha(90), 0);
      expect(find.text('20% watched'), findsOneWidget);
      expect(player.value.position, const Duration(seconds: 20));
    },
  );

  testWidgets(
    'short landscape with enlarged text keeps functional controls and errors usable',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(640, 240);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      await show(
        tester,
        fullscreen: true,
        textScale: 2,
        message: 'Playback session expired. Start again to resume.',
      );
      final action = find.byKey(const ValueKey('video-playback-action'));
      final deck = find.byKey(const ValueKey('floating-control-deck'));
      expect(tester.getRect(deck).contains(tester.getCenter(action)), isTrue);
      expect(
        find.text('Playback session expired. Start again to resume.'),
        findsOneWidget,
      );
      expect(find.byTooltip('Exit fullscreen'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  for (final fullscreen in [false, true]) {
    for (final playing in [false, true]) {
      testWidgets(
        'cinematic ${fullscreen ? 'landscape' : 'portrait'} ${playing ? 'playing' : 'paused'} composition',
        (tester) async {
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = fullscreen
              ? const Size(915, 412)
              : const Size(412, 915);
          addTearDown(tester.view.resetDevicePixelRatio);
          addTearDown(tester.view.resetPhysicalSize);
          player.value = player.value.copyWith(
            size: const Size(1600, 900),
            duration: const Duration(seconds: 545),
            position: const Duration(seconds: 402),
            isPlaying: playing,
          );
          await loadPlayerPreviewFonts(tester);
          await show(
            tester,
            fullscreen: fullscreen,
            coverage: 74,
            ranges: [
              [0, 300],
              [320, 423.3],
            ],
          );
          await tester.pumpAndSettle();
          final frame = find.byKey(const ValueKey('cinematic-video-stage'));
          final action = find.byKey(const ValueKey('video-playback-action'));
          final deck = find.byKey(const ValueKey('floating-control-deck'));
          expect(action, findsOneWidget);
          expect(
            tester.getRect(frame).contains(tester.getRect(deck).bottomRight),
            isTrue,
          );
          expect(find.text('74% watched'), findsOneWidget);
          expect(find.textContaining('6:42'), findsOneWidget);
          expect(find.textContaining('9:05'), findsOneWidget);
          expect(tester.takeException(), isNull);
          await capturePlayerPreview(
            tester,
            const ValueKey('player-preview'),
            '${fullscreen ? 'landscape' : 'portrait'}_${playing ? 'playing' : 'paused'}',
          );
        },
      );
    }
  }
}
