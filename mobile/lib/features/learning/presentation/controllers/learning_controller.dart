import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:training_app/features/learning/data/repositories/learning_repository.dart';
import 'package:training_app/features/learning/domain/models/assignment.dart';
import 'package:training_app/features/learning/domain/models/assignment_detail.dart';

final assignmentListProvider = FutureProvider.autoDispose<List<Assignment>>((ref) async {
  final repository = ref.watch(learningRepositoryProvider);
  return repository.getAssignments();
});

final assignmentDetailProvider = FutureProvider.autoDispose.family<AssignmentDetail, int>((ref, assignmentId) async {
  final repository = ref.watch(learningRepositoryProvider);
  return repository.getAssignmentDetail(assignmentId);
});

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

