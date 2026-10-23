import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:training_app/core/errors/api_error.dart';
import 'package:training_app/features/assessments/data/repositories/assessment_repository.dart';
import 'package:training_app/features/assessments/domain/models/assessment.dart';
import 'package:training_app/features/auth/domain/models/auth_state.dart';
import 'package:training_app/features/auth/presentation/controllers/auth_controller.dart';
import 'package:training_app/features/certificates/presentation/controllers/certificate_controller.dart';
import 'package:training_app/features/learning/presentation/controllers/learning_controller.dart';
import 'package:training_app/features/dashboard/presentation/controllers/dashboard_controller.dart';
import 'package:training_app/features/notifications/presentation/controllers/notification_controller.dart';

typedef AssessmentTarget = ({int assignmentId, int assessmentId});

String? _account(AuthState auth) =>
    auth is AuthAuthenticated ? auth.personalAccount : null;

final assessmentOverviewProvider = AsyncNotifierProvider.autoDispose
    .family<AssessmentOverviewController, AssignmentAssessments?, int>(
      AssessmentOverviewController.new,
      retry: (_, _) => null,
    );

class AssessmentOverviewController
    extends AsyncNotifier<AssignmentAssessments?> {
  final int assignmentId;
  AssessmentOverviewController(this.assignmentId);

  @override
  Future<AssignmentAssessments?> build() async {
    final requestRef = ref;
    final owner = _account(ref.read(authControllerProvider));
    ref.listen(authControllerProvider, (_, next) {
      if (_account(next) != owner) {
        // Loading/error transitions retain previous data. Replace it explicitly.
        state = const AsyncData(null);
        ref.invalidateSelf();
      }
    });
    if (owner == null) {
      throw ApiError(message: 'Sign in to view assessments.', statusCode: 401);
    }
    final requests = CancelToken();
    ref.onDispose(requests.cancel);
    try {
      return await ref
          .watch(assessmentRepositoryProvider)
          .getAssessments(assignmentId, cancelToken: requests);
    } catch (error) {
      if (requestRef.mounted &&
          error is ApiError &&
          (error.statusCode == 401 || error.statusCode == 403)) {
        state = const AsyncData(null);
      }
      rethrow;
    }
  }
}

enum AssessmentPhase {
  idle,
  loading,
  starting,
  ready,
  submitting,
  reconciling,
  uncertain,
  failed,
  unavailable,
}

class AssessmentState {
  final AssessmentPhase phase;
  final AssessmentAttempt? attempt;
  final Map<int, int?> selectedAnswers;
  final ApiError? error;

  AssessmentState({
    this.phase = AssessmentPhase.idle,
    this.attempt,
    Map<int, int?> selectedAnswers = const {},
    this.error,
  }) : selectedAnswers = Map.unmodifiable(selectedAnswers);

  bool get canSubmit =>
      phase == AssessmentPhase.ready &&
      attempt != null &&
      !attempt!.summary.isClosed &&
      const {'ASSIGNED', 'IN_PROGRESS'}.contains(attempt!.assignmentStatus);
}

final assessmentAttemptProvider = NotifierProvider.autoDispose
    .family<AssessmentController, AssessmentState, AssessmentTarget>(
      AssessmentController.new,
    );

class AssessmentController extends Notifier<AssessmentState> {
  final AssessmentTarget target;
  late AssessmentRepository _repository;
  String? _owner;
  int _generation = 0;
  CancelToken _requests = CancelToken();
  Future<void>? _mutation;
  int? _requestedAttemptId;

  AssessmentController(this.target);

  @override
  AssessmentState build() {
    if (target.assignmentId <= 0 || target.assessmentId <= 0) {
      throw ArgumentError('Assessment identifiers must be positive.');
    }
    _repository = ref.read(assessmentRepositoryProvider);
    _owner = _account(ref.read(authControllerProvider));
    ref.listen(authControllerProvider, (_, next) {
      final owner = _account(next);
      if (owner == _owner) return;
      _cancel();
      _requestedAttemptId = null;
      _owner = owner;
      state = AssessmentState(
        phase: owner == null
            ? AssessmentPhase.unavailable
            : AssessmentPhase.idle,
      );
    });
    ref.onDispose(_cancel);
    return AssessmentState(
      phase: _owner == null
          ? AssessmentPhase.unavailable
          : AssessmentPhase.idle,
    );
  }

  void _cancel() {
    _generation++;
    _requests.cancel();
    _requests = CancelToken();
    _mutation = null;
  }

  bool _current(int generation) =>
      ref.mounted &&
      generation == _generation &&
      _owner != null &&
      _owner == _account(ref.read(authControllerProvider));

  ApiError _error(Object error) =>
      error is ApiError ? error : ApiError.unexpected();

  void _fail(ApiError error, int generation, {bool uncertain = false}) {
    if (!_current(generation)) return;
    final denied = error.statusCode == 401 || error.statusCode == 403;
    state = AssessmentState(
      phase: denied
          ? AssessmentPhase.unavailable
          : uncertain
          ? AssessmentPhase.uncertain
          : AssessmentPhase.failed,
      attempt: denied ? null : state.attempt,
      selectedAnswers: denied ? const {} : state.selectedAnswers,
      error: error,
    );
  }

  void _accept(
    AssessmentAttempt result,
    int generation, {
    int? attemptId,
    ApiError? error,
  }) {
    if (!_current(generation)) return;
    if (result.assignmentId != target.assignmentId ||
        result.assessmentId != target.assessmentId ||
        (attemptId != null && result.summary.id != attemptId)) {
      throw const FormatException('Mismatched assessment attempt response.');
    }
    final keepSelection =
        !result.summary.isClosed &&
        state.attempt?.summary.id == result.summary.id;
    _requestedAttemptId = result.summary.id;
    state = AssessmentState(
      phase: AssessmentPhase.ready,
      attempt: result,
      selectedAnswers: keepSelection ? state.selectedAnswers : const {},
      error: result.summary.isClosed ? null : error,
    );
    ref.invalidate(assessmentOverviewProvider(target.assignmentId));
    if (result.summary.isClosed) {
      ref.invalidate(assignmentDetailProvider(target.assignmentId));
      ref.invalidate(assignmentListProvider);
      ref.invalidate(certificateListProvider);
      if (result.certificateId != null) {
        ref.invalidate(certificateDetailProvider(result.certificateId!));
      }
      ref.invalidate(dashboardDataProvider);
      ref.invalidate(notificationUnreadCountProvider);
      ref.invalidate(notificationListProvider);
    }
  }

  Future<void> _run(
    AssessmentPhase phase,
    Future<void> Function(int, CancelToken) operation, {
    bool clearAttempt = false,
  }) async {
    if (!ref.mounted || _owner == null) return;
    _cancel();
    final generation = _generation;
    state = AssessmentState(
      phase: phase,
      attempt: clearAttempt ? null : state.attempt,
      selectedAnswers: clearAttempt ? const {} : state.selectedAnswers,
    );
    try {
      await operation(generation, _requests);
    } catch (error) {
      _fail(_error(error), generation);
    }
  }

  Future<void> _mutate(
    AssessmentPhase phase,
    Future<void> Function(int, CancelToken) operation,
  ) {
    if (_mutation != null) return _mutation!;
    // Finish/reconcile a dispatched mutation even if its screen navigates away.
    final pending = ref.keepAlive();
    final work = _run(phase, operation);
    _mutation = work;
    return work.whenComplete(() {
      if (identical(_mutation, work)) _mutation = null;
      pending.close();
    });
  }

  Future<void> startOrResume() {
    if (state.attempt?.summary.isClosed == true) return Future.value();
    return _mutate(AssessmentPhase.starting, (generation, requests) async {
      final attempt = await _repository.startOrResume(
        target.assignmentId,
        target.assessmentId,
        cancelToken: requests,
      );
      _accept(attempt, generation);
      if (_current(generation) && !attempt.summary.isClosed) {
        ref.invalidate(assignmentDetailProvider(target.assignmentId));
        ref.invalidate(assignmentListProvider);
        ref.invalidate(dashboardDataProvider);
      }
    });
  }

  Future<void> loadAttempt(int attemptId) {
    if (_mutation != null) return _mutation!;
    _requestedAttemptId = attemptId;
    return _run(AssessmentPhase.loading, (generation, requests) async {
      final attempt = await _repository.getAttempt(
        attemptId,
        cancelToken: requests,
      );
      _accept(attempt, generation, attemptId: attemptId);
    }, clearAttempt: state.attempt?.summary.id != attemptId);
  }

  void selectAnswer(int questionId, int? optionId) {
    if (!state.canSubmit) return;
    final questions = state.attempt!.questions.where(
      (item) => item.id == questionId,
    );
    if (questions.length != 1 ||
        (optionId != null &&
            !questions.single.options.any((option) => option.id == optionId))) {
      throw ArgumentError('The answer must belong to a presented question.');
    }
    state = AssessmentState(
      phase: AssessmentPhase.ready,
      attempt: state.attempt,
      selectedAnswers: {...state.selectedAnswers, questionId: optionId},
    );
  }

  Future<void> _reconcile(
    int attemptId,
    int generation,
    CancelToken requests, {
    ApiError? submissionError,
  }) async {
    if (!_current(generation)) return;
    state = AssessmentState(
      phase: AssessmentPhase.reconciling,
      attempt: state.attempt,
      selectedAnswers: state.selectedAnswers,
    );
    try {
      final result = await _repository.getAttempt(
        attemptId,
        cancelToken: requests,
      );
      _accept(result, generation, attemptId: attemptId, error: submissionError);
    } catch (error) {
      _fail(_error(error), generation, uncertain: true);
    }
  }

  Future<void> reconcile() {
    if (_mutation != null) return _mutation!;
    final id = state.attempt?.summary.id;
    if (id == null) return Future.value();
    return _run(
      AssessmentPhase.reconciling,
      (generation, requests) => _reconcile(id, generation, requests),
    );
  }

  Future<void> submit() {
    if (_mutation != null) return _mutation!;
    if (!state.canSubmit) return Future.value();
    final attemptId = state.attempt!.summary.id;
    final answers = Map<int, int?>.of(state.selectedAnswers);
    return _mutate(AssessmentPhase.submitting, (generation, requests) async {
      try {
        final result = await _repository.submitAttempt(
          attemptId,
          answers,
          cancelToken: requests,
        );
        if (!_current(generation)) return;
        if (!result.summary.isClosed) {
          throw ApiError(
            message: 'Submission is not confirmed. Reload its result.',
            code: 'unexpected',
          );
        }
        _accept(result, generation, attemptId: attemptId);
      } catch (error) {
        if (!_current(generation)) return;
        final failure = _error(error);
        final uncertain =
            const {
              'timeout',
              'network_failure',
              'unexpected',
            }.contains(failure.code) ||
            failure.statusCode == 409 ||
            (failure.statusCode ?? 0) >= 500;
        if (uncertain) {
          await _reconcile(
            attemptId,
            generation,
            requests,
            submissionError: failure,
          );
        } else {
          _fail(failure, generation);
        }
      }
    });
  }

  /// Retries reads after an uncertain submission, never silently reposts answers.
  Future<void> retry() {
    final requested = _requestedAttemptId;
    if (requested != null && state.attempt?.summary.id != requested) {
      return loadAttempt(requested);
    }
    return state.attempt == null ? startOrResume() : reconcile();
  }
}
