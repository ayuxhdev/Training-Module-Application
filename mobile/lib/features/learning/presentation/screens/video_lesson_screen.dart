import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:video_player/video_player.dart';
import 'package:training_app/features/auth/domain/models/auth_state.dart';
import 'package:training_app/features/auth/presentation/controllers/auth_controller.dart';
import 'package:training_app/features/learning/domain/models/assignment_detail.dart';
import 'package:training_app/features/learning/domain/models/protected_media_request.dart';
import 'package:training_app/features/learning/presentation/controllers/learning_controller.dart';
import 'package:training_app/features/learning/presentation/controllers/playback_session_controller.dart';
import 'package:training_app/features/learning/presentation/widgets/protected_video_surface.dart';

final protectedVideoControllerProvider =
    Provider<VideoPlayerController Function(ProtectedMediaRequest)>(
      (ref) =>
          (media) => VideoPlayerController.networkUrl(
            media.uri,
            httpHeaders: media.headers,
            videoPlayerOptions: VideoPlayerOptions(
              allowBackgroundPlayback: false,
            ),
          ),
    );

/// The native player displays media position; only session responses update credit.
class VideoLessonScreen extends ConsumerStatefulWidget {
  final int assignmentId, moduleId, lessonId;
  const VideoLessonScreen({
    super.key,
    required this.assignmentId,
    required this.moduleId,
    required this.lessonId,
  });

  @override
  ConsumerState<VideoLessonScreen> createState() => _VideoLessonScreenState();
}

class _VideoLessonScreenState extends ConsumerState<VideoLessonScreen>
    with WidgetsBindingObserver {
  static const _window = MethodChannel('gardensneed/protected_video');
  VideoPlayerController? _video;
  PlaybackSessionController? _session;
  Timer? _heartbeat, _fade;
  int _generation = 0;
  int? _windowLease;
  Future<void>? _windowReady;
  bool _busy = false, _observing = false, _controls = true, _scrubbing = false;
  bool _foreground = true, _fullscreen = false, _leaving = false;
  double _origin = 0;
  bool _accountChanged = false;
  String? _message;

  PlaybackLesson get _lesson =>
      (assignmentId: widget.assignmentId, lessonId: widget.lessonId);
  bool get _android =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
  bool _current(int generation) =>
      mounted && generation == _generation && !_leaving;
  double get _position => (_video?.value.position.inMilliseconds ?? 0) / 1000;
  // Match the web client's conservative observation clock, not a credit calculation.
  double get _reported =>
      math.max(0, _position - math.max(0, _position - _origin) * .01);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (_android) {
      _windowReady = _secureWindow();
    }
  }

  Future<void> _secureWindow() async {
    try {
      _windowLease = await _window.invokeMethod<int>('acquire');
    } on PlatformException {
      if (mounted) {
        setState(() => _message = 'Protected display is unavailable.');
      }
    } on MissingPluginException {
      if (mounted) {
        setState(() => _message = 'Protected display is unavailable.');
      }
    }
  }

  @override
  void didUpdateWidget(VideoLessonScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.assignmentId == widget.assignmentId &&
        oldWidget.moduleId == widget.moduleId &&
        oldWidget.lessonId == widget.lessonId) {
      return;
    }
    final oldSession = _session;
    final position = _video?.value.isInitialized == true ? _reported : null;
    ++_generation;
    _cancelTimers();
    final video = _video;
    _video = null;
    video?.removeListener(_onVideo);
    unawaited(video?.dispose());
    // Keep the old family alive until closure finishes, even after this route changes.
    final hold = ref.listenManual(
      playbackSessionProvider((
        assignmentId: oldWidget.assignmentId,
        lessonId: oldWidget.lessonId,
      )),
      (_, _) {},
    );
    unawaited(
      (oldSession?.close(position: position) ?? Future<void>.value())
          .whenComplete(hold.close),
    );
    _session = null;
    _busy = false;
    _controls = true;
    _origin = 0;
    _message = null;
  }

  Future<void> _restoreWindow() async {
    await _windowReady;
    final lease = _windowLease;
    _windowLease = null;
    if (lease != null) await _window.invokeMethod<void>('release', lease);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (!_foreground) unawaited(_pause());
  }

  void _cancelTimers() {
    _heartbeat?.cancel();
    _heartbeat = null;
    _fade?.cancel();
  }

  void _reveal() {
    if (!mounted) return;
    setState(() => _controls = true);
    _fade?.cancel();
    if (_video?.value.isPlaying == true && !_scrubbing) {
      _fade = Timer(const Duration(seconds: 4), () {
        if (mounted && !_busy && !_scrubbing) {
          setState(() => _controls = false);
        }
      });
    }
  }

  void _onVideo() {
    final value = _video?.value;
    if (value == null || !mounted) return;
    if (value.isPlaying &&
        (!_foreground ||
            ref.read(playbackSessionProvider(_lesson)).phase !=
                PlaybackPhase.active)) {
      unawaited(_video?.pause());
      return;
    }
    if (value.hasError && !_busy) {
      unawaited(_pause(approvedOnly: true));
      setState(
        () => _message = 'Video is unavailable. Try again or contact your training coordinator.',
      );
    } else if (value.isCompleted && !_busy) {
      unawaited(_pause(ended: true));
    } else if (!value.isPlaying &&
        !value.isBuffering &&
        !_busy &&
        ref.read(playbackSessionProvider(_lesson)).phase ==
            PlaybackPhase.active) {
      unawaited(_pause()); // Includes native/audio-focus pauses.
    }
    // Buffering never counts as playing and never generates keep-alive credit.
    if (value.isPlaying && !value.isBuffering && _foreground && !_busy) {
      _heartbeat ??= Timer.periodic(
        const Duration(seconds: 10),
        (_) => _observe(),
      );
    } else {
      _heartbeat?.cancel();
      _heartbeat = null;
    }
  }

  Future<void> _observe() async {
    if (_observing ||
        _busy ||
        !_foreground ||
        _video?.value.isPlaying != true ||
        _video?.value.isBuffering == true) {
      return;
    }
    _observing = true;
    try {
      await _session?.heartbeat(_reported);
    } finally {
      _observing = false;
    }
  }

  Future<void> _play() async {
    if (_busy || !_foreground || _leaving || _accountChanged) return;
    final auth = ref.read(authControllerProvider);
    if (auth is! AuthAuthenticated || !auth.employee.isActive) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    final generation = ++_generation;
    final session = _session!;
    try {
      await _windowReady;
      if (_android && _windowLease == null) {
        throw StateError('Protected display unavailable');
      }
      // A failed close must be resolved before starting another session.
      await session.close();
      if (!_current(generation) || !_foreground) return;
      await session.start();
      if (!_current(generation) || !_foreground) {
        await session.close();
        return;
      }
      final media = await session.mediaRequest();
      if (!_current(generation) || media == null) return;
      final previous = _video;
      _video = null;
      previous?.removeListener(_onVideo);
      await previous?.dispose();
      if (!_current(generation)) return;
      final video = ref.read(protectedVideoControllerProvider)(media);
      _video = video;
      await video.initialize();
      if (!_current(generation) ||
          !_foreground ||
          ref.read(playbackSessionProvider(_lesson)).phase !=
              PlaybackPhase.active) {
        await session.close();
        return;
      }
      _origin = ref
          .read(playbackSessionProvider(_lesson))
          .progress!
          .resumePosition;
      await video.seekTo(Duration(milliseconds: (_origin * 1000).floor()));
      if (!_current(generation) || !_foreground) return;
      video.addListener(_onVideo);
      await video.play();
    } catch (_) {
      if (_current(generation)) {
        await session.close(); // Close at the last server-approved point on load failure.
        _message = 'Video is unavailable. Try again or contact your training coordinator.';
      }
    } finally {
      if (_current(generation)) {
        setState(() => _busy = false);
        _onVideo();
        _reveal();
      }
    }
  }

  Future<void> _pause({bool ended = false, bool approvedOnly = false}) async {
    _cancelTimers();
    final position = _reported;
    final generation = ++_generation; // Invalidates initialization and in-flight seek callbacks.
    final assignmentId = widget.assignmentId;
    final session = _session;
    _busy = true;
    _video?.removeListener(_onVideo);
    await _video?.pause();
    await session?.close(
      position: approvedOnly || _video?.value.isInitialized != true
          ? null
          : position,
      completedNormally: ended,
    );
    if (mounted && generation == _generation) {
      setState(() {
        _busy = false;
        _controls = true;
      });
      ref.invalidate(assignmentDetailProvider(assignmentId));
    }
  }

  Future<void> _seek(double target) async {
    if (_busy ||
        _video == null ||
        ref.read(playbackSessionProvider(_lesson)).phase !=
            PlaybackPhase.active) {
      return;
    }
    final video = _video!;
    final playing = video.value.isPlaying;
    final generation = _generation;
    setState(() => _busy = true);
    _cancelTimers();
    await video.pause();
    await _session!.heartbeat(
      _reported,
    ); // Save real playback before moving its baseline.
    if (!_current(generation)) return;
    final state = ref.read(playbackSessionProvider(_lesson));
    final progress = state.progress;
    final allowed =
        progress != null &&
        (target <= progress.resumePosition ||
            progress.watchedRanges.any(
              (range) => target >= range[0] && target <= range[1],
            ));
    if (state.phase == PlaybackPhase.active && allowed) {
      await video.seekTo(Duration(milliseconds: (target * 1000).floor()));
      if (!_current(generation)) return;
      await _session!.heartbeat(
        target,
      ); // Backend validates the new observation baseline.
      _origin = target;
    } else if (state.phase == PlaybackPhase.active) {
      _message = 'Move through unwatched video by playing it.';
    }
    if (!_current(generation)) return;
    setState(() => _busy = false);
    if (playing &&
        _foreground &&
        ref.read(playbackSessionProvider(_lesson)).phase ==
            PlaybackPhase.active) {
      await video.play();
    }
    _onVideo();
    _reveal();
  }

  Future<void> _toggleFullscreen() async {
    if (!_android || _windowLease == null) return;
    final fullscreen = !_fullscreen;
    await _window.invokeMethod<void>('fullscreen', {
      'lease': _windowLease,
      'enabled': fullscreen,
    });
    if (mounted) setState(() => _fullscreen = fullscreen);
    _reveal();
  }

  Future<void> _exit() async {
    if (_leaving) return;
    if (_fullscreen) {
      await _toggleFullscreen();
      return;
    }
    _leaving = true;
    await _pause();
    await _restoreWindow();
    if (!mounted) return;
    final router = GoRouter.of(context);
    if (router.canPop()) {
      router.pop();
    } else {
      router.go(
        '/learning/assignments/${widget.assignmentId}/modules/${widget.moduleId}/lessons',
      );
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    ++_generation;
    _cancelTimers();
    _video?.removeListener(_onVideo);
    unawaited(_video?.dispose());
    unawaited(
      _session?.close(),
    ); // Fallback; normal exit awaits closure before popping.
    unawaited(_restoreWindow());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authControllerProvider);
    ref.listen(authControllerProvider, (previous, next) {
      final oldOwner = previous is AuthAuthenticated
          ? previous.employee.username
          : null;
      final owner = next is AuthAuthenticated && next.employee.isActive
          ? next.employee.username
          : null;
      if (owner != oldOwner) {
        _accountChanged = true;
        ++_generation;
        _cancelTimers();
        final video = _video;
        _video = null;
        video?.removeListener(_onVideo);
        unawaited(video?.dispose());
        setState(() {
          _busy = false;
          _message = 'Sign in again to resume this lesson.';
        });
      }
    });
    final session = ref.watch(playbackSessionProvider(_lesson));
    _session = ref.read(playbackSessionProvider(_lesson).notifier);
    ref.listen(playbackSessionProvider(_lesson), (_, next) {
      if (next.phase == PlaybackPhase.failed ||
          next.phase == PlaybackPhase.unavailable) {
        ++_generation;
        _cancelTimers();
        unawaited(_video?.pause());
        setState(() {
          _busy = false;
          _controls = true;
        });
      }
    });
    final detail = ref.watch(assignmentDetailProvider(widget.assignmentId));
    LessonLearning? lesson;
    if (!_accountChanged &&
        auth is AuthAuthenticated &&
        auth.employee.isActive) {
      for (final module in detail.asData?.value.modules ?? <ModuleLearning>[]) {
        if (module.id != widget.moduleId) continue;
        for (final entry in module.lessons) {
          if (entry.id == widget.lessonId &&
              entry.type.toUpperCase() == 'VIDEO') {
            lesson = entry;
          }
        }
      }
    }
    final progress = _accountChanged
        ? null
        : session.progress ?? lesson?.progress;
    final error =
        session.error?.message ??
        _message ??
        (detail.hasError || (detail.hasValue && lesson == null)
            ? 'Lesson is unavailable.'
            : null);
    return Theme(
      data: ThemeData.dark(useMaterial3: true).copyWith(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xff92dac5),
          brightness: Brightness.dark,
        ),
        scaffoldBackgroundColor: const Color(0xff0c121b),
      ),
      child: PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) unawaited(_exit());
        },
        child: Scaffold(
          body: SafeArea(
            child: Column(
              children: [
                if (!_fullscreen)
                  ListTile(
                    leading: IconButton(
                      tooltip: 'Back to lessons',
                      onPressed: _exit,
                      icon: const Icon(Icons.arrow_back),
                    ),
                    title: Text(lesson?.title ?? 'Protected video'),
                    subtitle: const Text(
                      'Secure streaming · Progress saved by the server',
                    ),
                  ),
                Expanded(
                  child: ProtectedVideoSurface(
                    controller: _video,
                    busy: _busy || detail.isLoading,
                    controlsVisible: _controls,
                    canPlay: lesson != null,
                    canSeek: session.phase == PlaybackPhase.active,
                    fullscreen: _fullscreen,
                    onToggleControls: () {
                      if (_controls &&
                          !_scrubbing &&
                          _video?.value.isPlaying == true) {
                        setState(() => _controls = false);
                      } else {
                        _reveal();
                      }
                    },
                    onTogglePlayback: () => unawaited(
                      _video?.value.isPlaying == true ? _pause() : _play(),
                    ),
                    onSeek: (position) => unawaited(_seek(position)),
                    onScrubbingChanged: (scrubbing) {
                      _scrubbing = scrubbing;
                      _reveal();
                    },
                    onFullscreen: _android ? _toggleFullscreen : null,
                  ),
                ),
                if (error != null)
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: Semantics(
                      liveRegion: true,
                      child: Text(error, textAlign: TextAlign.center),
                    ),
                  ),
                if (!_fullscreen)
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          progress?.completed == true
                              ? 'Completed · Confirmed by the server'
                              : 'Unique video coverage: ${(progress?.progressPercent ?? 0).toStringAsFixed(0)}%',
                        ),
                        const SizedBox(height: 8),
                        LinearProgressIndicator(
                          value: (progress?.progressPercent ?? 0) / 100,
                          semanticsLabel: 'Server-confirmed video coverage',
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
