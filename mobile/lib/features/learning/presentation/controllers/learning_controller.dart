import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:dio/dio.dart';
import 'package:training_app/core/errors/api_error.dart';
import 'package:training_app/features/auth/domain/models/auth_state.dart';
import 'package:training_app/features/auth/presentation/controllers/auth_controller.dart';
import 'package:training_app/features/learning/data/repositories/learning_repository.dart';
import 'package:training_app/features/learning/domain/models/assignment.dart';
import 'package:training_app/features/learning/domain/models/assignment_detail.dart';

CancelToken _employeeRequest(Ref ref) {
  final account = ref.watch(
    authControllerProvider.select(
      (auth) => auth is AuthAuthenticated
          ? auth.personalAccount
          : null,
    ),
  );
  if (account == null) {
    throw ApiError(message: 'Sign in to view your training.', statusCode: 401);
  }
  final requests = CancelToken();
  ref.onDispose(requests.cancel);
  return requests;
}

final assignmentListProvider = FutureProvider.autoDispose<List<Assignment>>((
  ref,
) async {
  final requests = _employeeRequest(ref);
  final repository = ref.watch(learningRepositoryProvider);
  return repository.getAssignments(cancelToken: requests);
}, retry: (_, _) => null);

final assignmentDetailProvider = FutureProvider.autoDispose
    .family<AssignmentDetail, int>((ref, assignmentId) async {
      final requests = _employeeRequest(ref);
      final repository = ref.watch(learningRepositoryProvider);
      return repository.getAssignmentDetail(
        assignmentId,
        cancelToken: requests,
      );
    }, retry: (_, _) => null);

final textLessonCompletionProvider = FutureProvider.autoDispose.family<
    LessonProgress, ({int assignmentId, int lessonId})>((ref, lesson) async {
  // Share pending requests and refresh caches even after the screen is gone.
  final pending = ref.keepAlive();
  try {
    final repository = ref.watch(learningRepositoryProvider);
    final progress = await repository.completeTextLesson(
      lesson.assignmentId,
      lesson.lessonId,
    );
    if (ref.mounted && progress.completed) {
      ref.invalidate(assignmentDetailProvider(lesson.assignmentId));
      ref.invalidate(assignmentListProvider);
    }
    return progress;
  } finally {
    pending.close();
  }
}, retry: (_, _) => null);

