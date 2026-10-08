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

