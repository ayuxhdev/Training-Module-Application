import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:training_app/core/errors/api_error.dart';
import 'package:training_app/core/storage/secure_token_storage.dart';
import 'package:training_app/core/network/dio_client.dart';
import 'package:training_app/core/providers/core_providers.dart';
import 'package:training_app/features/learning/domain/models/assignment.dart';
import 'package:training_app/features/learning/domain/models/assignment_detail.dart';
import 'package:training_app/features/learning/domain/models/protected_media_request.dart';

final learningRepositoryProvider = Provider<LearningRepository>((ref) {
  final apiClient = ref.watch(apiClientProvider);
  return LearningRepository(
    apiClient: apiClient,
    tokenStorage: ref.watch(secureTokenStorageProvider),
  );
});

class LearningRepository {
  final ApiClient apiClient;
  final SecureTokenStorage tokenStorage;

  LearningRepository({required this.apiClient, required this.tokenStorage});

  String _lessonPath(int assignmentId, int lessonId) {
    if (assignmentId <= 0 || lessonId <= 0) {
      throw ArgumentError('Assignment and lesson IDs must be positive.');
    }
    return '/assignments/$assignmentId/lessons/$lessonId';
  }

  String _sessionPath(int assignmentId, int lessonId, int sessionId) {
    if (sessionId <= 0) throw ArgumentError('Session ID must be positive.');
    return '${_lessonPath(assignmentId, lessonId)}/sessions/$sessionId';
  }

  Future<LessonProgress> _playbackRequest(
    String path, {
    Map<String, dynamic>? data,
    CancelToken? cancelToken,
  }) async {
    try {
      final response = data == null
          ? await apiClient.dio.get(path, cancelToken: cancelToken)
          : await apiClient.dio.post(path, data: data, cancelToken: cancelToken);
      return LessonProgress.fromJson(response.data as Map<String, dynamic>);
    } catch (error) {
      throw apiClient.mapExceptionToApiError(error);
    }
  }

  Future<LessonProgress> getLessonProgress(
    int assignmentId, int lessonId, {CancelToken? cancelToken}
  ) => _playbackRequest(
    '${_lessonPath(assignmentId, lessonId)}/progress/', cancelToken: cancelToken,
  );

  Future<LessonProgress> startPlaybackSession(
    int assignmentId, int lessonId, {CancelToken? cancelToken}
  ) => _playbackRequest(
    '${_lessonPath(assignmentId, lessonId)}/sessions/',
    data: const {}, cancelToken: cancelToken,
  );

  Future<LessonProgress> submitPlaybackHeartbeat(
    int assignmentId, int lessonId, int sessionId, double position,
    {CancelToken? cancelToken}
  ) => _playbackRequest(
    '${_lessonPath(assignmentId, lessonId)}/progress/',
    data: _positionData(sessionId, position), cancelToken: cancelToken,
  );

  Map<String, dynamic> _positionData(int sessionId, double position) {
    if (sessionId <= 0 || !position.isFinite || position < 0) {
      throw ArgumentError('Invalid playback session or position.');
    }
    return {'session_id': sessionId, 'position': position};
  }

  Future<LessonProgress> endPlaybackSession(
    int assignmentId, int lessonId, int sessionId, double position,
    {bool completedNormally = false, CancelToken? cancelToken}
  ) => _playbackRequest(
    '${_sessionPath(assignmentId, lessonId, sessionId)}/end/',
    data: {'position': _positionData(sessionId, position)['position'],
           'completed_normally': completedNormally},
    cancelToken: cancelToken,
  );

  Future<ProtectedMediaRequest> protectedMediaRequest(
    int assignmentId, int lessonId, int sessionId,
  ) async {
    final path = '${_sessionPath(assignmentId, lessonId, sessionId)}/media/';
    final base = Uri.parse(apiClient.dio.options.baseUrl);
    if (!base.hasAuthority || base.userInfo.isNotEmpty || base.hasQuery ||
        base.hasFragment || !['http', 'https'].contains(base.scheme) ||
        (kReleaseMode && base.scheme != 'https')) {
      throw StateError('Invalid protected media API origin.');
    }
    final basePath = base.path.replaceFirst(RegExp(r'/+$'), '');
    if (!basePath.endsWith('/api/v1')) {
      throw StateError('Protected media requires the versioned API base URL.');
    }
    final token = await tokenStorage.readAccessToken();
    if (token == null || token.isEmpty) {
      throw ApiError(message: 'Sign in to play this lesson.', statusCode: 401);
    }
    return ProtectedMediaRequest(
      uri: base.replace(path: '$basePath$path'),
      headers: {'Authorization': 'Bearer $token'},
    );
  }

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

