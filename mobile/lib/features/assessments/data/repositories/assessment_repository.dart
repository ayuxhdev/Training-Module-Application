import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:training_app/core/network/dio_client.dart';
import 'package:training_app/core/providers/core_providers.dart';
import 'package:training_app/features/assessments/domain/models/assessment.dart';

final assessmentRepositoryProvider = Provider<AssessmentRepository>(
  (ref) => AssessmentRepository(apiClient: ref.watch(apiClientProvider)),
);

class AssessmentRepository {
  final ApiClient apiClient;
  AssessmentRepository({required this.apiClient});

  void _id(int value) {
    if (value <= 0) {
      throw ArgumentError('Assessment identifiers must be positive.');
    }
  }

  Future<T> _request<T>(
    String path,
    T Function(Map<String, dynamic>) parse, {
    Map<String, dynamic>? data,
    CancelToken? cancelToken,
  }) async {
    try {
      final response = data == null
          ? await apiClient.dio.get(path, cancelToken: cancelToken)
          : await apiClient.dio.post(
              path,
              data: data,
              cancelToken: cancelToken,
            );
      return parse(response.data as Map<String, dynamic>);
    } catch (error) {
      throw apiClient.mapExceptionToApiError(error);
    }
  }

  Future<AssignmentAssessments> getAssessments(
    int assignmentId, {
    CancelToken? cancelToken,
  }) async {
    _id(assignmentId);
    return _request('/assignments/$assignmentId/assessments/', (json) {
      final result = AssignmentAssessments.fromJson(json);
      if (result.assignmentId != assignmentId) {
        throw const FormatException('Mismatched assignment response.');
      }
      return result;
    }, cancelToken: cancelToken);
  }

  Future<AssessmentAttempt> startOrResume(
    int assignmentId,
    int assessmentId, {
    CancelToken? cancelToken,
  }) {
    _id(assignmentId);
    _id(assessmentId);
    return _request(
      '/assignments/$assignmentId/assessments/$assessmentId/attempts/',
      AssessmentAttempt.fromJson,
      data: const {},
      cancelToken: cancelToken,
    );
  }

  Future<AssessmentAttempt> getAttempt(
    int attemptId, {
    CancelToken? cancelToken,
  }) {
    _id(attemptId);
    return _request(
      '/assessment-attempts/$attemptId/',
      AssessmentAttempt.fromJson,
      cancelToken: cancelToken,
    );
  }

  Future<AssessmentAttempt> submitAttempt(
    int attemptId,
    Map<int, int?> answers, {
    CancelToken? cancelToken,
  }) {
    _id(attemptId);
    for (final entry in answers.entries) {
      _id(entry.key);
      if (entry.value != null) _id(entry.value!);
    }
    return _request(
      '/assessment-attempts/$attemptId/submit/',
      AssessmentAttempt.fromJson,
      data: {
        'answers': {
          for (final entry in answers.entries) '${entry.key}': entry.value,
        },
      },
      cancelToken: cancelToken,
    );
  }
}
