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
      final response = await apiClient.dio.get('/assignments/');
      final data = response.data as List<dynamic>;
      return data.map((e) => Assignment.fromJson(e as Map<String, dynamic>)).toList();
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
}

