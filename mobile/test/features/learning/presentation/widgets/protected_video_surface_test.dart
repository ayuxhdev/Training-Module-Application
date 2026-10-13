import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player/video_player.dart';
import 'package:training_app/features/learning/presentation/widgets/protected_video_surface.dart';

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

  setUp(() {
    player = SurfacePlayer();
    toggles = 0;
    reveals = 0;
    seeks.clear();
    scrubbing.clear();
  });
  tearDown(() => player.dispose());

  Future<void> show(
    WidgetTester tester, {
    bool visible = true,
    bool busy = false,
    bool fullscreen = false,
    bool reducedMotion = false,
    double textScale = 1,
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
            body: ProtectedVideoSurface(
              controller: player,
              busy: busy,
              controlsVisible: visible,
              canPlay: true,
              canSeek: true,
              fullscreen: fullscreen,
              onToggleControls: () => toggles++,
              onRevealControls: () => reveals++,
              onTogglePlayback: () {
                player.value = player.value.copyWith(
                  isPlaying: !player.value.isPlaying,
                );
              },
              onSeek: seeks.add,
              onScrubbingChanged: scrubbing.add,
              onFullscreen: () {},
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets(
    'play and pause use the existing callback and actual media state',
    (tester) async {
      await show(tester);
      expect(find.text('Paused'), findsOneWidget);
      expect(find.text('0:20'), findsOneWidget);
      expect(find.text('1:40'), findsOneWidget);
      await tester.tap(find.text('Play'));
      await tester.pumpAndSettle();
      expect(find.text('Playing'), findsOneWidget);
      await tester.tap(find.text('Pause'));
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
    expect(find.text('0:35'), findsOneWidget);
    expect(player.value.position, const Duration(seconds: 20));
    expect(seeks, isEmpty);
    tester.widget<Slider>(find.byType(Slider)).onChangeEnd!(35);
    await tester.pump();
    expect(scrubbing, [true, false]);
    expect(seeks, [35]);
    expect(find.text('0:20'), findsOneWidget);
  });

  testWidgets(
    'busy and buffering states announce loading and disable busy actions',
    (tester) async {
      await show(tester, busy: true);
      expect(find.text('Preparing video'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
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
          tester.getSize(find.byType(FilledButton)).height,
          greaterThanOrEqualTo(48),
        );
        expect(
          tester.getSize(find.byType(IconButton)).height,
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
}
