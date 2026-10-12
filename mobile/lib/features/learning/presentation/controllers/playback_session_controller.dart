import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:training_app/core/errors/api_error.dart';
import 'package:training_app/features/auth/domain/models/auth_state.dart';
import 'package:training_app/features/auth/presentation/controllers/auth_controller.dart';
import 'package:training_app/features/learning/data/repositories/learning_repository.dart';
import 'package:training_app/features/learning/domain/models/assignment_detail.dart';
import 'package:training_app/features/learning/domain/models/protected_media_request.dart';

typedef PlaybackLesson = ({int assignmentId, int lessonId});

enum PlaybackPhase {
  idle,
  starting,
  active,
  closing,
  ended,
  failed,
  unavailable,
}

class PlaybackSessionState {
  final PlaybackPhase phase;
  final LessonProgress? progress;
  final int? sessionId;
  final ApiError? error;

  const PlaybackSessionState({
    this.phase = PlaybackPhase.idle,
    this.progress,
    this.sessionId,
    this.error,
  });
}

final playbackSessionProvider = NotifierProvider.autoDispose
    .family<PlaybackSessionController, PlaybackSessionState, PlaybackLesson>(
      PlaybackSessionController.new,
    );

class PlaybackSessionController extends Notifier<PlaybackSessionState> {
  final PlaybackLesson lesson;
  late LearningRepository _repository;
  String? _owner;
  int _generation = 0;
  int? _sessionId;
  CancelToken _requests = CancelToken();
  Future<void> _queue = Future.value();
  Future<void>? _starting;
  Future<void>? _closing;
  Timer? _expiry;

  PlaybackSessionController(this.lesson);

  String? _account(AuthState auth) =>
      auth is AuthAuthenticated && auth.employee.isActive
      ? auth.employee.username
      : null;

  @override
  PlaybackSessionState build() {
    if (lesson.assignmentId <= 0 || lesson.lessonId <= 0) {
      throw ArgumentError(
        'Playback requires positive assignment and lesson IDs.',
      );
    }
    _repository = ref.read(learningRepositoryProvider);
    _owner = _account(ref.read(authControllerProvider));
    ref.listen(authControllerProvider, (_, auth) {
      final account = _account(auth);
      if (account == _owner) return;
      _cancelRequests();
      _owner = account;
      _sessionId = null;
      state = PlaybackSessionState(
        phase: account == null ? PlaybackPhase.unavailable : PlaybackPhase.idle,
      );
    });
    ref.onDispose(_cancelRequests);
    return PlaybackSessionState(
      phase: _owner == null ? PlaybackPhase.unavailable : PlaybackPhase.idle,
    );
  }

  void _cancelRequests() {
    _generation++;
    _expiry?.cancel();
    _requests.cancel();
    _requests = CancelToken();
    _queue = Future.value();
    _starting = null;
    _closing = null;
  }

  bool _current(int generation) =>
      ref.mounted && generation == _generation && _owner != null;

  Future<void> _enqueue(Future<void> Function(int, CancelToken) operation) {
    final generation = _generation;
    final requests = _requests;
    final work = _queue.then((_) async {
      if (_current(generation)) await operation(generation, requests);
    });
    _queue = work.catchError((Object _) {});
    return work;
  }

  ApiError _error(Object error) =>
      error is ApiError ? error : ApiError.unexpected();

  void _accept(LessonProgress progress, int sessionId, Stopwatch observed) {
    if (progress.sessionId != sessionId) {
      throw const FormatException(
        'Playback response has a mismatched session.',
      );
    }
    state = PlaybackSessionState(
      phase: _closing == null ? PlaybackPhase.active : PlaybackPhase.closing,
      progress: progress,
      sessionId: sessionId,
    );
    _expiry?.cancel();
    if (_closing != null) return;
    // Count from request dispatch, not response receipt. This is conservative
    // relative to the backend's 30-second media freshness check.
    final remaining = const Duration(seconds: 30) - observed.elapsed;
    _expiry = Timer(remaining.isNegative ? Duration.zero : remaining, () {
      _cancelRequests();
      unawaited(
        _enqueue(
          (generation, requests) => _fail(
            ApiError(
              message: 'Playback session expired. Start again to resume.',
              code: 'session_expired',
            ),
            generation,
            requests,
          ),
        ),
      );
    });
  }

  Future<void> loadProgress() => _enqueue((generation, requests) async {
    if (_sessionId != null) return;
    try {
      final progress = await _repository.getLessonProgress(
        lesson.assignmentId,
        lesson.lessonId,
        cancelToken: requests,
      );
      if (_current(generation)) {
        state = PlaybackSessionState(progress: progress);
      }
    } catch (error) {
      if (_current(generation)) {
        await _fail(_error(error), generation, requests);
      }
    }
  });

  Future<void> start() {
    if (_starting != null) return _starting!;
    if (_sessionId != null || _closing != null) return Future.value();
    final work = _enqueue((generation, requests) async {
      state = PlaybackSessionState(
        phase: PlaybackPhase.starting,
        progress: state.progress,
      );
      try {
        final observed = Stopwatch()..start();
        final progress = await _repository.startPlaybackSession(
          lesson.assignmentId,
          lesson.lessonId,
          cancelToken: requests,
        );
        if (!_current(generation)) return;
        final sessionId = progress.sessionId;
        if (sessionId == null) {
          throw const FormatException('Missing playback session.');
        }
        _sessionId = sessionId;
        _accept(progress, sessionId, observed);
      } catch (error) {
        if (_current(generation)) {
          await _fail(_error(error), generation, requests);
        }
      }
    });
    _starting = work;
    return work.whenComplete(() {
      if (identical(_starting, work)) _starting = null;
    });
  }

  Future<ProtectedMediaRequest?> mediaRequest() async {
    final generation = _generation;
    final sessionId = _sessionId;
    if (sessionId == null || state.phase != PlaybackPhase.active) return null;
    try {
      final request = await _repository.protectedMediaRequest(
        lesson.assignmentId,
        lesson.lessonId,
        sessionId,
      );
      return _current(generation) &&
              _sessionId == sessionId &&
              state.phase == PlaybackPhase.active
          ? request
          : null;
    } catch (error) {
      if (_current(generation)) {
        await _enqueue(
          (generation, requests) => _fail(_error(error), generation, requests),
        );
      }
      return null;
    }
  }

  void _validatePosition(double position) {
    if (!position.isFinite || position < 0) {
      throw ArgumentError('Invalid playback position.');
    }
  }

  Future<void> heartbeat(double position) {
    _validatePosition(position);
    final sessionId = _sessionId;
    if (sessionId == null ||
        state.phase != PlaybackPhase.active ||
        _closing != null) {
      return Future.value();
    }
    return _enqueue((generation, requests) async {
      if (_sessionId != sessionId) return;
      try {
        final observed = Stopwatch()..start();
        final progress = await _repository.submitPlaybackHeartbeat(
          lesson.assignmentId,
          lesson.lessonId,
          sessionId,
          position,
          cancelToken: requests,
        );
        if (_current(generation)) _accept(progress, sessionId, observed);
      } catch (error) {
        if (_current(generation)) {
          await _fail(_error(error), generation, requests);
        }
      }
    });
  }

  Future<void> close({double? position, bool completedNormally = false}) {
    if (position != null) _validatePosition(position);
    if (_closing != null) return _closing!;
    _expiry?.cancel();
    final work = _enqueue((generation, requests) async {
      await _closeSession(
        position ?? state.progress?.resumePosition ?? 0,
        completedNormally,
        generation,
        requests,
      );
    });
    _closing = work;
    return work.whenComplete(() {
      if (identical(_closing, work)) _closing = null;
    });
  }

  Future<void> _closeSession(
    double position,
    bool normal,
    int generation,
    CancelToken requests,
  ) async {
    final sessionId = _sessionId;
    if (sessionId == null) return;
    _expiry?.cancel();
    state = PlaybackSessionState(
      phase: PlaybackPhase.closing,
      progress: state.progress,
      sessionId: sessionId,
    );
    try {
      final progress = await _repository.endPlaybackSession(
        lesson.assignmentId,
        lesson.lessonId,
        sessionId,
        position,
        completedNormally: normal,
        cancelToken: requests,
      );
      if (!_current(generation)) return;
      if (progress.sessionId != sessionId) {
        throw const FormatException('Mismatched closed session.');
      }
      _sessionId = null;
      state = PlaybackSessionState(
        phase: PlaybackPhase.ended,
        progress: progress,
      );
    } catch (error) {
      if (!_current(generation)) return;
      final failure = _error(error);
      // A lost close response may be followed by 404 because the session is
      // already closed. Never restore it or automatically retry mutations.
      if ([401, 403, 404, 409].contains(failure.statusCode)) _sessionId = null;
      state = PlaybackSessionState(
        phase: PlaybackPhase.failed,
        progress: [401, 403].contains(failure.statusCode)
            ? null
            : state.progress,
        sessionId: _sessionId,
        error: failure,
      );
    }
  }

  Future<void> _fail(
    ApiError error,
    int generation,
    CancelToken requests,
  ) async {
    _expiry?.cancel();
    if ([401, 403, 404, 409].contains(error.statusCode)) {
      _sessionId = null;
    } else if (_sessionId != null) {
      // A failed heartbeat is not evidence that its reported position was watched.
      await _closeSession(
        state.progress?.resumePosition ?? 0,
        false,
        generation,
        requests,
      );
    }
    if (!_current(generation)) return;
    state = PlaybackSessionState(
      phase: PlaybackPhase.failed,
      progress: [401, 403].contains(error.statusCode) ? null : state.progress,
      sessionId: _sessionId,
      error: error,
    );
    // Queued observations belong to the failed session and cannot recover it.
    _cancelRequests();
  }
}
