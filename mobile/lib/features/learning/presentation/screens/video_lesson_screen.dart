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
import 'package:training_app/features/learning/data/repositories/learning_repository.dart';
import 'package:training_app/features/learning/domain/models/protected_media_request.dart';
import 'package:training_app/features/learning/presentation/controllers/learning_controller.dart';
import 'package:training_app/features/learning/presentation/controllers/playback_session_controller.dart';
import 'package:training_app/features/learning/presentation/widgets/protected_video_surface.dart';
import 'package:training_app/core/errors/api_error.dart';
import 'package:training_app/core/presentation/components/api_error_view.dart';

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
  Timer? _fade, _warningExpiry;
  int _generation = 0;
  int? _windowLease;
  Future<void>? _windowReady;
  bool _busy = false, _observing = false, _controls = true, _scrubbing = false;
  bool _controlsFocused = false;
  bool _foreground = true, _fullscreen = false, _leaving = false;
  double _origin = 0;
  bool _accountChanged = false;
  bool _readOnlyReplay = false;
  bool _recoveringFromBuffering = false;
  String? _message;
  ApiError? _mediaAccessError;

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

  bool _nearEnd(double position, double duration) =>
      position > 0 && duration > 0 && position >= duration - 1;

  LessonLearning? _currentLesson() {
    final detail = ref.read(assignmentDetailProvider(widget.assignmentId));
    for (final module in detail.asData?.value.modules ?? <ModuleLearning>[]) {
      if (module.id != widget.moduleId) continue;
      for (final lesson in module.lessons) {
        if (lesson.id == widget.lessonId &&
            lesson.type.toUpperCase() == 'VIDEO') {
          return lesson;
        }
      }
    }
    return null;
  }

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
    _readOnlyReplay = false;
    _message = null;
    _mediaAccessError = null;
    _warningExpiry?.cancel();
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
    _fade?.cancel();
  }

  bool get _holdControls =>
      _scrubbing ||
      MediaQuery.accessibleNavigationOf(context) ||
      (_controlsFocused &&
          FocusManager.instance.highlightMode ==
              FocusHighlightMode.traditional);

  void _reveal() {
    if (!mounted) return;
    setState(() => _controls = true);
    _fade?.cancel();
    if (_video?.value.isPlaying == true && !_holdControls) {
      _fade = Timer(const Duration(seconds: 4), () {
        if (mounted && !_busy && !_holdControls) {
          setState(() => _controls = false);
        }
      });
    }
  }

  void _onVideo() {
    final value = _video?.value;
    if (value == null || !mounted) return;
    if (_readOnlyReplay) {
      if (!_foreground && value.isPlaying) unawaited(_pause());
      if (value.hasError && !_busy) {
        unawaited(_pause());
        setState(
          () => _message = 'Replay is unavailable. Reload the lesson or contact your training coordinator.',
        );
      } else if (value.isCompleted && !_busy) {
        unawaited(_pause(ended: true));
      }
      return; // Read-only media never starts a heartbeat or writes watch credit.
    }
    // Native buffering-end and playing updates arrive separately. Wait for
    // playback to resume before interpreting a stopped value as a native pause.
    if (value.isBuffering) {
      _recoveringFromBuffering = true;
    } else if (value.isPlaying) {
      _recoveringFromBuffering = false;
    }
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
        !_recoveringFromBuffering &&
        !_busy &&
        ref.read(playbackSessionProvider(_lesson)).phase ==
            PlaybackPhase.active) {
      unawaited(_pause()); // Includes native/audio-focus pauses.
    }
    unawaited(_observe());
  }

  Future<void> _observe() async {
    if (!mounted ||
        _readOnlyReplay ||
        _observing ||
        _busy ||
        !_foreground ||
        _video?.value.isPlaying != true ||
        _video?.value.isBuffering == true) {
      return;
    }
    final state = ref.read(playbackSessionProvider(_lesson));
    final position = _reported;
    // A due observation survives buffering, but only real forward playback
    // may dispatch it. Initialization/stalls never become keep-alives or credit.
    if (state.phase != PlaybackPhase.active ||
        !state.observationDue ||
        position <= (state.lastObservationPosition ?? _origin)) {
      return;
    }
    _observing = true;
    try {
      await _session?.heartbeat(position);
    } finally {
      _observing = false;
    }
  }

  Future<VideoPlayerController?> _loadSessionMedia(
    PlaybackSessionController session,
    int generation,
  ) async {
    final media = await session.mediaRequest();
    if (!_current(generation) || media == null) return null;
    final video = await _loadMedia(media, generation);
    if (!_current(generation)) return null;
    if (video == null ||
        ref.read(playbackSessionProvider(_lesson)).phase !=
            PlaybackPhase.active) {
      await session.close();
      return null;
    }
    return video;
  }

  Future<VideoPlayerController?> _loadMedia(
    ProtectedMediaRequest media,
    int generation,
  ) async {
    final previous = _video;
    _video = null;
    _recoveringFromBuffering = false;
    previous?.removeListener(_onVideo);
    await previous?.dispose();
    if (!_current(generation)) return null;
    final video = ref.read(protectedVideoControllerProvider)(media);
    _video = video;
    await video.initialize();
    if (!_current(generation) || !_foreground) return null;
    return video;
  }

  Future<void> _play() async {
    if (_busy || !_foreground || _leaving || _accountChanged) return;
    final auth = ref.read(authControllerProvider);
    if (auth is! AuthAuthenticated || !auth.canLearn) return;
    final lesson = _currentLesson();
    if (lesson == null ||
        !['tracked', 'read_only_replay'].contains(lesson.playbackMode)) {
      return;
    }
    _readOnlyReplay = lesson.playbackMode == 'read_only_replay';
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
      if (_readOnlyReplay) {
        // Only an in-memory replay position is retained; saved learning is immutable.
        final position =
            _video?.value.isCompleted == true ||
                _nearEnd(
                  _position,
                  (_video?.value.duration.inMilliseconds ?? 0) / 1000,
                )
            ? 0.0
            : _position;
        final media = await ref
            .read(learningRepositoryProvider)
            .protectedReplayMediaRequest(widget.assignmentId, widget.lessonId);
        if (!_current(generation) || !_foreground) return;
        final video = await _loadMedia(media, generation);
        if (video == null) return;
        await video.seekTo(Duration(milliseconds: (position * 1000).floor()));
        if (!_current(generation) || !_foreground) return;
        video.addListener(_onVideo);
        await video.play();
        return;
      }
      // A failed close must be resolved before starting another session.
      await session.close();
      if (!_current(generation) || !_foreground) return;
      final previousProgress =
          ref.read(playbackSessionProvider(_lesson)).progress ??
          _currentLesson()?.progress;
      final knownDuration = _video?.value.isInitialized == true
          ? _video!.value.duration.inMilliseconds / 1000
          : (_currentLesson()?.videoDurationSeconds ?? 0).toDouble();
      final replay =
          _video?.value.isCompleted == true ||
          _nearEnd(previousProgress?.resumePosition ?? 0, knownDuration);
      await session.start(position: replay ? 0 : null);
      if (!_current(generation) || !_foreground) {
        await session.close();
        return;
      }
      var video = await _loadSessionMedia(session, generation);
      if (video == null) return;
      var approvedPosition = ref
          .read(playbackSessionProvider(_lesson))
          .progress!
          .resumePosition;
      // Stored duration is rounded; native metadata can reveal an earlier end.
      // Close the first session before opening a replay session at zero.
      if (!replay &&
          _nearEnd(
            approvedPosition,
            video.value.duration.inMilliseconds / 1000,
          )) {
        await session.close();
        if (!_current(generation) || !_foreground) return;
        if (ref.read(playbackSessionProvider(_lesson)).phase !=
            PlaybackPhase.ended) {
          throw StateError('Playback session could not be closed for replay.');
        }
        await session.start(position: 0);
        if (!_current(generation) || !_foreground) {
          await session.close();
          return;
        }
        video = await _loadSessionMedia(session, generation);
        if (video == null) return;
        approvedPosition = ref
            .read(playbackSessionProvider(_lesson))
            .progress!
            .resumePosition;
      }
      if (_nearEnd(
        approvedPosition,
        video.value.duration.inMilliseconds / 1000,
      )) {
        throw StateError('Playback session resumed at the video endpoint.');
      }
      _origin = approvedPosition;
      await video.seekTo(Duration(milliseconds: (_origin * 1000).floor()));
      if (!_current(generation) || !_foreground) return;
      video.addListener(_onVideo);
      await video.play();
    } catch (error) {
      if (_current(generation)) {
        if (!_readOnlyReplay) {
          await session.close(); // Close at the last approved point.
        }
        if (error is ApiError && [401, 403].contains(error.statusCode)) {
          _mediaAccessError = error;
        }
        _message = _readOnlyReplay
            ? 'Replay is unavailable. Reload the lesson or contact your training coordinator.'
            : 'Video is unavailable. Try again or contact your training coordinator.';
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
    _recoveringFromBuffering = false;
    final position = _reported;
    final generation = ++_generation; // Invalidates initialization and in-flight seek callbacks.
    final assignmentId = widget.assignmentId;
    final session = _session;
    _busy = true;
    _video?.removeListener(_onVideo);
    await _video?.pause();
    if (!_readOnlyReplay) {
      await session?.close(
        position: approvedOnly || _video?.value.isInitialized != true
            ? null
            : position,
        completedNormally: ended,
      );
    }
    if (mounted && generation == _generation) {
      setState(() {
        _busy = false;
        _controls = true;
      });
      final readError = ref.read(assignmentDetailProvider(assignmentId)).error;
      // Cleanup must not retry a denied read or briefly restore protected content.
      if (!_readOnlyReplay &&
          !(readError is ApiError &&
              [401, 403].contains(readError.statusCode))) {
        ref.invalidate(assignmentDetailProvider(assignmentId));
      }
    }
  }

  Future<void> _seek(double target) async {
    if (_busy || _video == null) return;
    if (_readOnlyReplay) {
      final video = _video!;
      if (!target.isFinite ||
          target < 0 ||
          target > video.value.duration.inMilliseconds / 1000) {
        return;
      }
      final playing = video.value.isPlaying;
      final generation = _generation;
      setState(() => _busy = true);
      try {
        await video.pause();
        await video.seekTo(Duration(milliseconds: (target * 1000).floor()));
        if (_current(generation) && _foreground && playing) await video.play();
      } catch (_) {
        if (_current(generation)) {
          _message = 'Replay is unavailable. Reload the lesson or contact your training coordinator.';
        }
      } finally {
        if (_current(generation)) {
          setState(() => _busy = false);
          _onVideo();
          _reveal();
        }
      }
      return;
    }
    if (ref.read(playbackSessionProvider(_lesson)).phase !=
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
      _warningExpiry?.cancel();
      late final Timer warningExpiry;
      warningExpiry = Timer(const Duration(seconds: 5), () {
        if (mounted &&
            identical(_warningExpiry, warningExpiry) &&
            _message == 'Move through unwatched video by playing it.') {
          setState(() => _message = null);
        }
      });
      _warningExpiry = warningExpiry;
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
    _warningExpiry?.cancel();
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
          ? previous.personalAccount
          : null;
      final owner = next is AuthAuthenticated
          ? next.personalAccount
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
      if (next.observationDue) unawaited(_observe());
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
    ref.listen(assignmentDetailProvider(widget.assignmentId), (_, next) {
      final error = next.error;
      if (error is ApiError &&
          [401, 403].contains(error.statusCode) &&
          (_busy || _video?.value.isPlaying == true)) {
        unawaited(_pause(approvedOnly: true));
      }
    });
    final readError = detail.error;
    final authorizationError =
        [session.error, _mediaAccessError, if (readError is ApiError) readError]
            .whereType<ApiError>()
            .where((error) => [401, 403].contains(error.statusCode))
            .firstOrNull;
    LessonLearning? lesson;
    String? moduleTitle;
    if (!_accountChanged &&
        auth is AuthAuthenticated &&
        auth.canLearn) {
      for (final module in detail.asData?.value.modules ?? <ModuleLearning>[]) {
        if (module.id != widget.moduleId) continue;
        for (final entry in module.lessons) {
          if (entry.id == widget.lessonId &&
              entry.type.toUpperCase() == 'VIDEO') {
            lesson = entry;
            moduleTitle = module.title;
          }
        }
      }
    }
    final readOnlyReplay = lesson?.playbackMode == 'read_only_replay';
    final progress = _accountChanged
        ? null
        : readOnlyReplay
        ? lesson?.progress
        : session.progress ?? lesson?.progress;
    final error =
        (readOnlyReplay ? null : session.error?.message) ??
        _message ??
        (detail.hasError || (detail.hasValue && lesson == null)
            ? 'Lesson is unavailable.'
            : null);
    final player = ProtectedVideoSurface(
      controller: _video,
      busy: _busy || detail.isLoading,
      controlsVisible: _controls,
      loadingLabel: detail.isLoading
          ? 'Loading lesson'
          : session.phase == PlaybackPhase.closing
          ? 'Saving progress'
          : 'Preparing video',
      statusLabel:
          !readOnlyReplay &&
              (session.phase == PlaybackPhase.failed ||
                  session.phase == PlaybackPhase.unavailable)
          ? 'Playback unavailable'
          : null,
      message: error,
      title: lesson?.title,
      coveragePercent: progress?.progressPercent ?? 0,
      watchedRanges: progress?.watchedRanges ?? const [],
      completed: progress?.completed ?? false,
      resumePosition: lesson?.playbackMode == 'read_only_replay'
          ? 0
          : progress?.resumePosition ?? 0,
      videoDurationSeconds: lesson?.videoDurationSeconds,
      canPlay:
          lesson != null &&
          ['tracked', 'read_only_replay'].contains(lesson.playbackMode),
      canSeek: lesson?.playbackMode == 'read_only_replay'
          ? _video?.value.isInitialized == true
          : session.phase == PlaybackPhase.active,
      fullscreen: _fullscreen,
      onToggleControls: () {
        if (_controls && !_holdControls && _video?.value.isPlaying == true) {
          setState(() => _controls = false);
        } else {
          _reveal();
        }
      },
      onTogglePlayback: () =>
          unawaited(_video?.value.isPlaying == true ? _pause() : _play()),
      onSeek: (position) => unawaited(_seek(position)),
      onScrubbingChanged: (scrubbing) {
        _scrubbing = scrubbing;
        _reveal();
      },
      onRevealControls: _reveal,
      onControlsFocusChanged: (focused) {
        _controlsFocused = focused;
        _reveal();
      },
      onFullscreen: _android ? _toggleFullscreen : null,
      onBack: _exit,
    );
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final playerTheme = ThemeData.dark(useMaterial3: true).copyWith(
      colorScheme:
          ColorScheme.fromSeed(
            seedColor: const Color(0xff10b981),
            brightness: Brightness.dark,
          ).copyWith(
            primary: const Color(0xff2dd4bf),
            onPrimary: const Color(0xff04070a),
            surface: const Color(0xff0d1520),
            onSurface: const Color(0xfff8fafc),
            onSurfaceVariant: const Color(0xff94a3b8),
            outline: const Color(0xff64748b),
            outlineVariant: const Color(0xff24303d),
          ),
      scaffoldBackgroundColor: const Color(0xff04070a),
    );
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_exit());
      },
      child: Scaffold(
        appBar: authorizationError == null
            ? null
            : AppBar(
                title: const Text('Video lesson'),
                leading: IconButton(
                  tooltip: 'Back to lessons',
                  onPressed: _exit,
                  icon: const Icon(Icons.arrow_back),
                ),
              ),
        backgroundColor: _fullscreen
            ? playerTheme.scaffoldBackgroundColor
            : theme.scaffoldBackgroundColor,
        body: authorizationError != null
            ? ApiErrorView(error: authorizationError)
            : SafeArea(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final minimumHeight =
                        260.0 +
                        math.max(
                              0,
                              MediaQuery.textScalerOf(context).scale(12) - 12,
                            ) *
                            4;
                    final aspect = _video?.value.isInitialized == true
                        ? _video!.value.aspectRatio
                        : 16 / 9;
                    final stageHeight = _fullscreen
                        ? constraints.maxHeight
                        : math.max(
                            minimumHeight,
                            math.min(
                              (constraints.maxWidth - 24) / aspect,
                              math.max(
                                minimumHeight,
                                constraints.maxHeight - 220,
                              ),
                            ),
                          );
                    return SingleChildScrollView(
                      physics: _fullscreen
                          ? const NeverScrollableScrollPhysics()
                          : null,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (!_fullscreen)
                            ListTile(
                              leading: IconButton(
                                tooltip: 'Back to lessons',
                                onPressed: _exit,
                                icon: const Icon(Icons.arrow_back),
                              ),
                              title: const Text(
                                'Video lesson',
                                style: TextStyle(fontWeight: FontWeight.w600),
                              ),
                              subtitle: moduleTitle == null
                                  ? null
                                  : Text(
                                      moduleTitle,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                            ),
                          SizedBox(
                            key: const ValueKey('video-stage-layout'),
                            height: stageHeight,
                            child: Padding(
                              padding: EdgeInsets.symmetric(
                                horizontal: _fullscreen ? 0 : 12,
                              ),
                              child: Theme(data: playerTheme, child: player),
                            ),
                          ),
                          if (!_fullscreen)
                            Padding(
                              padding: const EdgeInsets.fromLTRB(
                                20,
                                20,
                                20,
                                24,
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  if (lesson?.playbackMode ==
                                      'read_only_replay') ...[
                                    const Text(
                                      'Read-only replay. Recorded completion and watched coverage will not change.',
                                    ),
                                    const SizedBox(height: 12),
                                  ],
                                  Text(
                                    lesson?.title ?? 'Protected video',
                                    style: theme.textTheme.titleLarge?.copyWith(
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                  if (lesson != null) ...[
                                    const SizedBox(height: 4),
                                    Text(
                                      detail.asData!.value.trainingTitle,
                                      style: theme.textTheme.bodyMedium
                                          ?.copyWith(
                                            color: colors.onSurfaceVariant,
                                          ),
                                    ),
                                  ],
                                  const SizedBox(height: 16),
                                  Container(
                                    key: const ValueKey('video-coverage-panel'),
                                    padding: const EdgeInsets.all(16),
                                    decoration: BoxDecoration(
                                      color: colors.surfaceContainerLow,
                                      borderRadius: BorderRadius.circular(14),
                                      border: Border.all(
                                        color: colors.outlineVariant,
                                      ),
                                    ),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.stretch,
                                      children: [
                                        Text(
                                          progress?.completed == true
                                              ? 'Lesson completed'
                                              : 'Watched coverage: ${(progress?.progressPercent ?? 0).floor()}%',
                                          style: const TextStyle(
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                        const SizedBox(height: 10),
                                        LinearProgressIndicator(
                                          value:
                                              (progress?.progressPercent ?? 0) /
                                              100,
                                          borderRadius: BorderRadius.circular(
                                            4,
                                          ),
                                          minHeight: 5,
                                          semanticsLabel:
                                              'Confirmed watched coverage',
                                          semanticsValue:
                                              '${(progress?.progressPercent ?? 0).floor()}%',
                                        ),
                                        if (progress?.completed != true &&
                                            lesson?.minimumWatchPercent !=
                                                null) ...[
                                          const SizedBox(height: 8),
                                          Text(
                                            'Watch ${lesson!.minimumWatchPercent!.toString().replaceFirst(RegExp(r'\.0$'), '')}% to complete this lesson.',
                                          ),
                                        ],
                                        if (session.phase ==
                                                PlaybackPhase.ended &&
                                            session.error == null) ...[
                                          const SizedBox(height: 8),
                                          Text(
                                            'Progress saved',
                                            style: TextStyle(
                                              color: colors.primary,
                                            ),
                                          ),
                                        ],
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                        ],
                      ),
                    );
                  },
                ),
              ),
      ),
    );
  }
}
