import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:training_app/core/network/dio_client.dart';
import 'package:training_app/core/providers/core_providers.dart';
import 'package:training_app/features/learning/domain/models/assignment.dart';
import 'package:training_app/features/learning/domain/models/assignment_detail.dart';

final learningRepositoryProvider = Provider<LearningRepository>((ref) {
  final apiClient = ref.watch(apiClientProvider);
  return LearningRepository(apiClient: apiClient);
});

class LearningRepository {
  final ApiClient apiClient;

  LearningRepository({required this.apiClient});

  Future<List<Assignment>> getAssignments() async {
    try {
      final assignments = <Assignment>[];
      var page = 1;
      while (true) {
        // Keep every request on the scoped endpoint; never follow arbitrary URLs.
        final response = page == 1
            ? await apiClient.dio.get('/assignments/')
            : await apiClient.dio.get('/assignments/', queryParameters: {'page': page});
        final data = response.data as Map<String, dynamic>;
        final results = data['results'] as List<dynamic>;
        assignments.addAll(results.map((item) => Assignment.fromJson(item as Map<String, dynamic>)));
        if (data['next'] == null) return assignments;
        if (results.isEmpty || data['next'] is! String) {
          throw const FormatException('Invalid assignment pagination.');
        }
        page++;
      }
    } catch (e) {
      throw apiClient.mapExceptionToApiError(e);
    }
  }

  Future<AssignmentDetail> getAssignmentDetail(int assignmentId) async {
    try {
      final response = await apiClient.dio.get('/assignments/$assignmentId/');
      return AssignmentDetail.fromJson(response.data as Map<String, dynamic>);
    } catch (e) {
      throw apiClient.mapExceptionToApiError(e);
    }
  }

  Future<LessonProgress> completeTextLesson(int assignmentId, int lessonId) async {
    try {
      final response = await apiClient.dio.post('/assignments/$assignmentId/lessons/$lessonId/complete/');
      return LessonProgress.fromJson(response.data as Map<String, dynamic>);
    } catch (e) {
      throw apiClient.mapExceptionToApiError(e);
    }
  }
}

