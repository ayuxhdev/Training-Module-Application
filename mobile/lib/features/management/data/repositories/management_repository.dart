import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:training_app/core/errors/api_error.dart';
import 'package:training_app/core/network/dio_client.dart';
import 'package:training_app/core/providers/core_providers.dart';
import 'package:training_app/features/management/data/services/video_file_picker.dart';
import 'package:training_app/features/management/domain/models/management_models.dart';

final managementRepositoryProvider = Provider<ManagementRepository>(
  (ref) => ManagementRepository(ref.watch(apiClientProvider)),
);

class ManagementRepository {
  final ApiClient apiClient;
  ManagementRepository(this.apiClient);

  Future<T> _get<T>(
    String path,
    T Function(Map<String, dynamic>) parse, {
    int? page,
    int? pageSize,
    Map<String, dynamic>? additionalQueryParameters,
    CancelToken? cancelToken,
  }) async {
    if (page != null && page <= 0) throw ArgumentError.value(page, 'page');
    if (pageSize != null && (pageSize <= 0 || pageSize > 100)) {
      throw ArgumentError.value(pageSize, 'pageSize');
    }
    final query = <String, dynamic>{
      if (page != null && page > 1) 'page': page,
      'page_size': ?pageSize,
      ...?additionalQueryParameters,
    };
    try {
      final response = await apiClient.dio.get(
        '/management/$path',
        queryParameters: query.isEmpty ? null : query,
        cancelToken: cancelToken,
      );
      if (cancelToken?.cancelError case final error?) throw error;
      return parse(response.data as Map<String, dynamic>);
    } catch (error) {
      throw apiClient.mapExceptionToApiError(error);
    }
  }

  Future<ManagementDashboard> dashboard({CancelToken? cancelToken}) => _get(
    'dashboard/',
    ManagementDashboard.fromJson,
    cancelToken: cancelToken,
  );

  Future<ManagementPage<DirectoryEmployee>> employees({
    int page = 1,
    int? pageSize,
    String? search,
    int? departmentId,
    int? jobRoleId,
    bool? isActive,
    CancelToken? cancelToken,
  }) {
    if (departmentId != null && departmentId <= 0) {
      throw ArgumentError.value(departmentId, 'departmentId');
    }
    if (jobRoleId != null && jobRoleId <= 0) {
      throw ArgumentError.value(jobRoleId, 'jobRoleId');
    }
    final normalizedSearch = search?.trim();
    return _get(
      'employees/',
      (json) => ManagementPage.fromJson(json, DirectoryEmployee.fromJson),
      page: page,
      pageSize: pageSize,
      additionalQueryParameters: {
        'search': ?(normalizedSearch?.isNotEmpty == true
            ? normalizedSearch
            : null),
        'department_id': ?departmentId,
        'job_role_id': ?jobRoleId,
        'is_active': ?isActive,
      },
      cancelToken: cancelToken,
    );
  }

  Future<DirectoryEmployee> employee(int id, {CancelToken? cancelToken}) async {
    if (id <= 0) throw ArgumentError.value(id, 'id');
    return _get('employees/$id/', (json) {
      _validateManagerResponseContract(json);
      final result = DirectoryEmployee.fromJson(json);
      if (result.id != id) {
        throw const FormatException('Employee identity mismatch.');
      }
      return result;
    }, cancelToken: cancelToken);
  }

  Future<ManagementPage<EmployeeAssignmentSummary>> employeeAssignments(
    int employeeId, {
    int page = 1,
    int? pageSize,
    CancelToken? cancelToken,
  }) {
    if (employeeId <= 0) throw ArgumentError.value(employeeId, 'employeeId');
    return _get(
      'employees/$employeeId/assignments/',
      (json) =>
          ManagementPage.fromJson(json, EmployeeAssignmentSummary.fromJson),
      page: page,
      pageSize: pageSize,
      cancelToken: cancelToken,
    );
  }

  Future<ManagementPage<AssignableTrainingVersion>> assignableTrainingVersions({
    int page = 1,
    int? pageSize,
    String? search,
    CancelToken? cancelToken,
  }) {
    final normalizedSearch = search?.trim();
    return _get(
      'training-versions/',
      (json) =>
          ManagementPage.fromJson(json, AssignableTrainingVersion.fromJson),
      page: page,
      pageSize: pageSize,
      additionalQueryParameters: {
        'search': ?(normalizedSearch?.isNotEmpty == true
            ? normalizedSearch
            : null),
      },
      cancelToken: cancelToken,
    );
  }

  Future<ManagementPage<ManagedTraining>> trainings({
    int page = 1,
    int? pageSize,
    String? search,
    CancelToken? cancelToken,
  }) {
    final normalizedSearch = search?.trim();
    return _get(
      'trainings/',
      (json) => ManagementPage.fromJson(json, ManagedTraining.fromJson),
      page: page,
      pageSize: pageSize,
      additionalQueryParameters: {
        'search': ?(normalizedSearch?.isNotEmpty == true
            ? normalizedSearch
            : null),
      },
      cancelToken: cancelToken,
    );
  }

  Future<ManagedTraining> training(int id, {CancelToken? cancelToken}) async {
    if (id <= 0) throw ArgumentError.value(id, 'id');
    return _get(
      'trainings/$id/',
      ManagedTraining.fromJson,
      cancelToken: cancelToken,
    );
  }

  Future<ManagementPage<ManagedTrainingVersionItem>> trainingVersions(
    int trainingId, {
    int page = 1,
    int? pageSize,
    CancelToken? cancelToken,
  }) async {
    if (trainingId <= 0) throw ArgumentError.value(trainingId, 'trainingId');
    return _get(
      'trainings/$trainingId/versions/',
      (json) =>
          ManagementPage.fromJson(json, ManagedTrainingVersionItem.fromJson),
      page: page,
      pageSize: pageSize,
      cancelToken: cancelToken,
    );
  }

  Future<ManagementPage<ManagedTrainingVersionItem>> allTrainingVersions({
    int page = 1,
    int? pageSize,
    CancelToken? cancelToken,
  }) async {
    return _get(
      'versions/',
      (json) =>
          ManagementPage.fromJson(json, ManagedTrainingVersionItem.fromJson),
      page: page,
      pageSize: pageSize,
      cancelToken: cancelToken,
    );
  }

  Future<ManagedVersionDetail> versionDetail(
    int id, {
    CancelToken? cancelToken,
  }) async {
    if (id <= 0) throw ArgumentError.value(id, 'id');
    return _get(
      'versions/$id/',
      ManagedVersionDetail.fromJson,
      cancelToken: cancelToken,
    );
  }

  Future<ManagedTraining> createTraining({
    required String code,
    required String catalogTitle,
    String description = '',
    bool isActive = true,
    CancelToken? cancelToken,
  }) async {
    final normalizedCode = code.trim();
    if (normalizedCode.isEmpty || normalizedCode.length > 40) {
      throw ArgumentError.value(code, 'code');
    }
    final normalizedTitle = catalogTitle.trim();
    if (normalizedTitle.isEmpty || normalizedTitle.length > 200) {
      throw ArgumentError.value(catalogTitle, 'catalogTitle');
    }
    final data = <String, Object?>{
      'code': normalizedCode,
      'catalog_title': normalizedTitle,
      'description': description.trim(),
      'is_active': isActive,
    };
    try {
      final response = await apiClient.dio.post(
        '/management/trainings/',
        data: data,
        cancelToken: cancelToken,
      );
      if (cancelToken?.cancelError case final error?) throw error;
      if (response.statusCode != 201) {
        throw const FormatException(
          'Course creation returned an unexpected status.',
        );
      }
      return ManagedTraining.fromJson(response.data as Map<String, dynamic>);
    } catch (error) {
      throw apiClient.mapExceptionToApiError(error);
    }
  }

  Future<ManagedTraining> updateTraining(
    int id, {
    String? code,
    String? catalogTitle,
    String? description,
    bool? isActive,
    CancelToken? cancelToken,
  }) async {
    if (id <= 0) throw ArgumentError.value(id, 'id');
    if (code != null && (code.trim().isEmpty || code.trim().length > 40)) {
      throw ArgumentError.value(code, 'code');
    }
    if (catalogTitle != null &&
        (catalogTitle.trim().isEmpty || catalogTitle.trim().length > 200)) {
      throw ArgumentError.value(catalogTitle, 'catalogTitle');
    }
    final data = <String, Object?>{
      if (code != null) 'code': code.trim(),
      if (catalogTitle != null) 'catalog_title': catalogTitle.trim(),
      if (description != null) 'description': description.trim(),
      'is_active': ?isActive,
    };
    if (data.isEmpty) {
      throw ArgumentError('No training fields changed.');
    }
    try {
      final response = await apiClient.dio.patch(
        '/management/trainings/$id/',
        data: data,
        cancelToken: cancelToken,
      );
      if (cancelToken?.cancelError case final error?) throw error;
      if (response.statusCode != 200) {
        throw const FormatException(
          'Course update returned an unexpected status.',
        );
      }
      return ManagedTraining.fromJson(response.data as Map<String, dynamic>);
    } catch (error) {
      throw apiClient.mapExceptionToApiError(error);
    }
  }

  Future<ManagedVersionDetail> createDraftVersion(
    int trainingId, {
    required String title,
    String description = '',
    String learningObjectives = '',
    String changeSummary = '',
    CancelToken? cancelToken,
  }) async {
    if (trainingId <= 0) throw ArgumentError.value(trainingId, 'trainingId');
    final normalizedTitle = title.trim();
    if (normalizedTitle.isEmpty || normalizedTitle.length > 200) {
      throw ArgumentError.value(title, 'title');
    }
    final data = <String, Object?>{
      'title': normalizedTitle,
      'description': description.trim(),
      'learning_objectives': learningObjectives.trim(),
      'change_summary': changeSummary.trim(),
    };
    try {
      final response = await apiClient.dio.post(
        '/management/trainings/$trainingId/versions/',
        data: data,
        cancelToken: cancelToken,
      );
      if (cancelToken?.cancelError case final error?) throw error;
      if (response.statusCode != 201) {
        throw const FormatException(
          'Draft version creation returned an unexpected status.',
        );
      }
      return ManagedVersionDetail.fromJson(
        response.data as Map<String, dynamic>,
      );
    } catch (error) {
      throw apiClient.mapExceptionToApiError(error);
    }
  }

  Future<ManagedTrainingVersionItem> publishVersion(
    int versionId, {
    CancelToken? cancelToken,
  }) => _transitionVersion(versionId, 'publish', cancelToken: cancelToken);

  Future<ManagedTrainingVersionItem> retireVersion(
    int versionId, {
    CancelToken? cancelToken,
  }) => _transitionVersion(versionId, 'retire', cancelToken: cancelToken);

  Future<ManagedTrainingVersionItem> _transitionVersion(
    int versionId,
    String action, {
    CancelToken? cancelToken,
  }) async {
    if (versionId <= 0) throw ArgumentError.value(versionId, 'versionId');
    try {
      // A lifecycle POST is never automatically replayed by ApiClient.
      final response = await apiClient.dio.post(
        '/management/versions/$versionId/$action/',
        data: <String, Object?>{},
        cancelToken: cancelToken,
      );
      if (cancelToken?.cancelError case final error?) throw error;
      if (response.statusCode != 200) {
        throw const FormatException(
          'Version lifecycle returned an unexpected status.',
        );
      }
      return ManagedTrainingVersionItem.fromJson(
        response.data as Map<String, dynamic>,
      );
    } catch (error) {
      throw apiClient.mapExceptionToApiError(error);
    }
  }

  Future<ManagedModuleDetail> createModule(
    int versionId, {
    required String title,
    String description = '',
    required int position,
    CancelToken? cancelToken,
  }) async {
    if (versionId <= 0) throw ArgumentError.value(versionId, 'versionId');
    final normalizedTitle = title.trim();
    if (normalizedTitle.isEmpty || normalizedTitle.length > 200) {
      throw ArgumentError.value(title, 'title');
    }
    if (position < 1 || position > 2147483647) {
      throw ArgumentError.value(position, 'position');
    }
    final data = <String, Object?>{
      'title': normalizedTitle,
      'description': description.trim(),
      'position': position,
    };
    try {
      final response = await apiClient.dio.post(
        '/management/versions/$versionId/modules/',
        data: data,
        cancelToken: cancelToken,
      );
      if (cancelToken?.cancelError case final error?) throw error;
      if (response.statusCode != 201) {
        throw const FormatException(
          'Module creation returned an unexpected status.',
        );
      }
      return ManagedModuleDetail.fromJson(
        response.data as Map<String, dynamic>,
      );
    } catch (error) {
      throw apiClient.mapExceptionToApiError(error);
    }
  }

  Future<ManagedModuleDetail> moduleDetail(
    int versionId,
    int moduleId, {
    CancelToken? cancelToken,
  }) async {
    if (versionId <= 0) throw ArgumentError.value(versionId, 'versionId');
    if (moduleId <= 0) throw ArgumentError.value(moduleId, 'moduleId');
    return _get(
      'versions/$versionId/modules/$moduleId/',
      ManagedModuleDetail.fromJson,
      cancelToken: cancelToken,
    );
  }

  Future<ManagedModuleDetail> updateModule(
    int versionId,
    int moduleId, {
    String? title,
    String? description,
    int? position,
    CancelToken? cancelToken,
  }) async {
    if (versionId <= 0) throw ArgumentError.value(versionId, 'versionId');
    if (moduleId <= 0) throw ArgumentError.value(moduleId, 'moduleId');
    final data = <String, Object?>{};
    if (title != null) {
      final normalizedTitle = title.trim();
      if (normalizedTitle.isEmpty || normalizedTitle.length > 200) {
        throw ArgumentError.value(title, 'title');
      }
      data['title'] = normalizedTitle;
    }
    if (description != null) {
      data['description'] = description.trim();
    }
    if (position != null) {
      if (position < 1 || position > 2147483647) {
        throw ArgumentError.value(position, 'position');
      }
      data['position'] = position;
    }
    if (data.isEmpty) {
      throw ArgumentError('At least one field must be provided for update.');
    }
    try {
      final response = await apiClient.dio.patch(
        '/management/versions/$versionId/modules/$moduleId/',
        data: data,
        cancelToken: cancelToken,
      );
      if (cancelToken?.cancelError case final error?) throw error;
      if (response.statusCode != 200) {
        throw const FormatException(
          'Module update returned an unexpected status.',
        );
      }
      return ManagedModuleDetail.fromJson(
        response.data as Map<String, dynamic>,
      );
    } catch (error) {
      throw apiClient.mapExceptionToApiError(error);
    }
  }

  Future<ManagedTextLessonDetail> createTextLesson(
    int versionId,
    int moduleId, {
    required String title,
    required String body,
    required int position,
    bool isRequired = true,
    CancelToken? cancelToken,
  }) async {
    if (versionId <= 0) throw ArgumentError.value(versionId, 'versionId');
    if (moduleId <= 0) throw ArgumentError.value(moduleId, 'moduleId');
    final normalizedTitle = title.trim();
    if (normalizedTitle.isEmpty || normalizedTitle.length > 200) {
      throw ArgumentError.value(title, 'title');
    }
    final normalizedBody = body.trim();
    if (normalizedBody.isEmpty) {
      throw ArgumentError.value(body, 'body');
    }
    if (position < 1 || position > 2147483647) {
      throw ArgumentError.value(position, 'position');
    }
    final data = <String, Object?>{
      'title': normalizedTitle,
      'body': body,
      'position': position,
      'is_required': isRequired,
      'content_type': 'TEXT',
    };
    try {
      final response = await apiClient.dio.post(
        '/management/versions/$versionId/modules/$moduleId/text-lessons/',
        data: data,
        cancelToken: cancelToken,
      );
      if (cancelToken?.cancelError case final error?) throw error;
      if (response.statusCode != 201) {
        throw const FormatException(
          'Text lesson creation returned an unexpected status.',
        );
      }
      return ManagedTextLessonDetail.fromJson(
        response.data as Map<String, dynamic>,
      );
    } catch (error) {
      throw apiClient.mapExceptionToApiError(error);
    }
  }

  Future<ManagedTextLessonDetail> textLessonDetail(
    int versionId,
    int moduleId,
    int lessonId, {
    CancelToken? cancelToken,
  }) async {
    if (versionId <= 0) throw ArgumentError.value(versionId, 'versionId');
    if (moduleId <= 0) throw ArgumentError.value(moduleId, 'moduleId');
    if (lessonId <= 0) throw ArgumentError.value(lessonId, 'lessonId');
    return _get(
      'versions/$versionId/modules/$moduleId/text-lessons/$lessonId/',
      ManagedTextLessonDetail.fromJson,
      cancelToken: cancelToken,
    );
  }

  Future<ManagedTextLessonDetail> updateTextLesson(
    int versionId,
    int moduleId,
    int lessonId, {
    String? title,
    String? body,
    int? position,
    bool? isRequired,
    CancelToken? cancelToken,
  }) async {
    if (versionId <= 0) throw ArgumentError.value(versionId, 'versionId');
    if (moduleId <= 0) throw ArgumentError.value(moduleId, 'moduleId');
    if (lessonId <= 0) throw ArgumentError.value(lessonId, 'lessonId');
    final data = <String, Object?>{};
    if (title != null) {
      final normalizedTitle = title.trim();
      if (normalizedTitle.isEmpty || normalizedTitle.length > 200) {
        throw ArgumentError.value(title, 'title');
      }
      data['title'] = normalizedTitle;
    }
    if (body != null) {
      final normalizedBody = body.trim();
      if (normalizedBody.isEmpty) {
        throw ArgumentError.value(body, 'body');
      }
      data['body'] = body;
    }
    if (position != null) {
      if (position < 1 || position > 2147483647) {
        throw ArgumentError.value(position, 'position');
      }
      data['position'] = position;
    }
    if (isRequired != null) {
      data['is_required'] = isRequired;
    }
    if (data.isEmpty) {
      throw ArgumentError('At least one field must be provided for update.');
    }
    try {
      final response = await apiClient.dio.patch(
        '/management/versions/$versionId/modules/$moduleId/text-lessons/$lessonId/',
        data: data,
        cancelToken: cancelToken,
      );
      if (cancelToken?.cancelError case final error?) throw error;
      if (response.statusCode != 200) {
        throw const FormatException(
          'Text lesson update returned an unexpected status.',
        );
      }
      return ManagedTextLessonDetail.fromJson(
        response.data as Map<String, dynamic>,
      );
    } catch (error) {
      throw apiClient.mapExceptionToApiError(error);
    }
  }

  Future<ManagedVideoLessonDetail> createVideoLesson(
    int versionId,
    int moduleId, {
    required String title,
    required int position,
    required SelectedVideoFile videoFile,
    bool isRequired = true,
    double? minimumWatchPercent,
    ProgressCallback? onSendProgress,
    CancelToken? cancelToken,
  }) async {
    if (versionId <= 0) throw ArgumentError.value(versionId, 'versionId');
    if (moduleId <= 0) throw ArgumentError.value(moduleId, 'moduleId');
    final normalizedTitle = title.trim();
    if (normalizedTitle.isEmpty || normalizedTitle.length > 200) {
      throw ArgumentError.value(title, 'title');
    }
    if (position < 1 || position > 2147483647) {
      throw ArgumentError.value(position, 'position');
    }
    if (minimumWatchPercent != null &&
        (minimumWatchPercent < 0 || minimumWatchPercent > 100)) {
      throw ArgumentError.value(minimumWatchPercent, 'minimumWatchPercent');
    }

    await apiClient.prepareUpload(cancelToken: cancelToken);
    final multipart = await videoFile.toMultipartFile();
    final formData = FormData.fromMap({
      'title': normalizedTitle,
      'position': position.toString(),
      'is_required': isRequired.toString(),
      'content_type': 'VIDEO',
      if (minimumWatchPercent != null)
        'minimum_watch_percent': minimumWatchPercent.toStringAsFixed(2),
      'video_file': multipart,
    });

    try {
      final response = await apiClient.dio.post(
        '/management/versions/$versionId/modules/$moduleId/video-lessons/',
        data: formData,
        options: ApiClient.uploadOptions,
        onSendProgress: onSendProgress,
        cancelToken: cancelToken,
      );
      if (cancelToken?.cancelError case final error?) throw error;
      if (response.statusCode != 201) {
        throw const FormatException(
          'Video lesson creation returned an unexpected status.',
        );
      }
      return ManagedVideoLessonDetail.fromJson(
        response.data as Map<String, dynamic>,
      );
    } catch (error) {
      throw apiClient.mapExceptionToApiError(error);
    }
  }

  Future<ManagedVideoLessonDetail> videoLessonDetail(
    int versionId,
    int moduleId,
    int lessonId, {
    CancelToken? cancelToken,
  }) async {
    if (versionId <= 0) throw ArgumentError.value(versionId, 'versionId');
    if (moduleId <= 0) throw ArgumentError.value(moduleId, 'moduleId');
    if (lessonId <= 0) throw ArgumentError.value(lessonId, 'lessonId');
    return _get(
      'versions/$versionId/modules/$moduleId/video-lessons/$lessonId/',
      ManagedVideoLessonDetail.fromJson,
      cancelToken: cancelToken,
    );
  }

  Future<ManagedVideoLessonDetail> updateVideoLesson(
    int versionId,
    int moduleId,
    int lessonId, {
    String? title,
    int? position,
    bool? isRequired,
    double? minimumWatchPercent,
    SelectedVideoFile? videoFile,
    ProgressCallback? onSendProgress,
    CancelToken? cancelToken,
  }) async {
    if (versionId <= 0) throw ArgumentError.value(versionId, 'versionId');
    if (moduleId <= 0) throw ArgumentError.value(moduleId, 'moduleId');
    if (lessonId <= 0) throw ArgumentError.value(lessonId, 'lessonId');

    final hasFile = videoFile != null;
    String? normalizedTitle;
    if (title != null) {
      normalizedTitle = title.trim();
      if (normalizedTitle.isEmpty || normalizedTitle.length > 200) {
        throw ArgumentError.value(title, 'title');
      }
    }
    if (position != null && (position < 1 || position > 2147483647)) {
      throw ArgumentError.value(position, 'position');
    }
    if (minimumWatchPercent != null &&
        (minimumWatchPercent < 0 || minimumWatchPercent > 100)) {
      throw ArgumentError.value(minimumWatchPercent, 'minimumWatchPercent');
    }

    if (!hasFile &&
        title == null &&
        position == null &&
        isRequired == null &&
        minimumWatchPercent == null) {
      throw ArgumentError(
        'At least one field or video replacement must be provided for update.',
      );
    }

    dynamic requestData;
    if (hasFile) {
      await apiClient.prepareUpload(cancelToken: cancelToken);
      final multipart = await videoFile.toMultipartFile();
      final formData = FormData();
      if (normalizedTitle != null) {
        formData.fields.add(MapEntry('title', normalizedTitle));
      }
      if (position != null) {
        formData.fields.add(MapEntry('position', position.toString()));
      }
      if (isRequired != null) {
        formData.fields.add(MapEntry('is_required', isRequired.toString()));
      }
      if (minimumWatchPercent != null) {
        formData.fields.add(
          MapEntry(
            'minimum_watch_percent',
            minimumWatchPercent.toStringAsFixed(2),
          ),
        );
      }
      formData.files.add(MapEntry('video_file', multipart));
      requestData = formData;
    } else {
      final map = <String, Object?>{};
      if (normalizedTitle != null) map['title'] = normalizedTitle;
      if (position != null) map['position'] = position;
      if (isRequired != null) map['is_required'] = isRequired;
      if (minimumWatchPercent != null) {
        map['minimum_watch_percent'] = minimumWatchPercent.toStringAsFixed(2);
      }
      requestData = map;
    }

    try {
      final response = await apiClient.dio.patch(
        '/management/versions/$versionId/modules/$moduleId/video-lessons/$lessonId/',
        data: requestData,
        options: hasFile ? ApiClient.uploadOptions : null,
        onSendProgress: onSendProgress,
        cancelToken: cancelToken,
      );
      if (cancelToken?.cancelError case final error?) throw error;
      if (response.statusCode != 200) {
        throw const FormatException(
          'Video lesson update returned an unexpected status.',
        );
      }
      return ManagedVideoLessonDetail.fromJson(
        response.data as Map<String, dynamic>,
      );
    } catch (error) {
      throw apiClient.mapExceptionToApiError(error);
    }
  }

  Future<ManagementPage<ManagedAssessment>> assessments(
    int versionId, {
    int? page,
    int? pageSize,
    CancelToken? cancelToken,
  }) async {
    if (versionId <= 0) throw ArgumentError.value(versionId, 'versionId');
    return _get(
      'versions/$versionId/assessments/',
      (json) => ManagementPage.fromJson(json, ManagedAssessment.fromJson),
      page: page,
      pageSize: pageSize,
      cancelToken: cancelToken,
    );
  }

  Future<ManagedAssessment> assessmentDetail(
    int versionId,
    int assessmentId, {
    CancelToken? cancelToken,
  }) async {
    if (versionId <= 0) throw ArgumentError.value(versionId, 'versionId');
    if (assessmentId <= 0) {
      throw ArgumentError.value(assessmentId, 'assessmentId');
    }
    return _get(
      'versions/$versionId/assessments/$assessmentId/',
      ManagedAssessment.fromJson,
      cancelToken: cancelToken,
    );
  }

  Future<ManagedAssessment> createAssessment(
    int versionId, {
    required String kind,
    required String title,
    int? moduleId,
    int? sequence,
    double? passPercentage,
    int? maxAttempts,
    int? timeLimitMinutes,
    bool? isRequired,
    CancelToken? cancelToken,
  }) async {
    if (versionId <= 0) throw ArgumentError.value(versionId, 'versionId');
    final normalizedTitle = title.trim();
    if (normalizedTitle.isEmpty || normalizedTitle.length > 200) {
      throw ArgumentError.value(title, 'title');
    }
    final normalizedKind = kind.toUpperCase();
    if (normalizedKind != 'QUIZ' && normalizedKind != 'FINAL') {
      throw ArgumentError.value(kind, 'kind');
    }
    final data = <String, dynamic>{
      'kind': normalizedKind,
      'title': normalizedTitle,
      'module_id': ?moduleId,
      'sequence': ?sequence,
      if (passPercentage != null)
        'pass_percentage': passPercentage.toStringAsFixed(2),
      'max_attempts': ?maxAttempts,
      'time_limit_minutes': ?timeLimitMinutes,
      'is_required': ?isRequired,
    };
    try {
      final response = await apiClient.dio.post(
        '/management/versions/$versionId/assessments/',
        data: data,
        cancelToken: cancelToken,
      );
      if (cancelToken?.cancelError case final error?) throw error;
      if (response.statusCode != 201) {
        throw const FormatException(
          'Assessment creation returned an unexpected status.',
        );
      }
      return ManagedAssessment.fromJson(response.data as Map<String, dynamic>);
    } catch (error) {
      throw apiClient.mapExceptionToApiError(error);
    }
  }

  Future<ManagedAssessment> updateAssessment(
    int versionId,
    int assessmentId, {
    String? kind,
    String? title,
    int? moduleId,
    bool clearModuleId = false,
    int? sequence,
    double? passPercentage,
    int? maxAttempts,
    int? timeLimitMinutes,
    bool clearTimeLimit = false,
    bool? isRequired,
    CancelToken? cancelToken,
  }) async {
    if (versionId <= 0) throw ArgumentError.value(versionId, 'versionId');
    if (assessmentId <= 0) {
      throw ArgumentError.value(assessmentId, 'assessmentId');
    }
    final data = <String, dynamic>{};
    if (kind != null) {
      data['kind'] = kind.toUpperCase();
    }
    if (title != null) {
      final normalizedTitle = title.trim();
      if (normalizedTitle.isEmpty || normalizedTitle.length > 200) {
        throw ArgumentError.value(title, 'title');
      }
      data['title'] = normalizedTitle;
    }
    if (clearModuleId) {
      data['module_id'] = null;
    } else if (moduleId != null) {
      data['module_id'] = moduleId;
    }
    if (sequence != null) {
      data['sequence'] = sequence;
    }
    if (passPercentage != null) {
      data['pass_percentage'] = passPercentage.toStringAsFixed(2);
    }
    if (maxAttempts != null) {
      data['max_attempts'] = maxAttempts;
    }
    if (clearTimeLimit) {
      data['time_limit_minutes'] = null;
    } else if (timeLimitMinutes != null) {
      data['time_limit_minutes'] = timeLimitMinutes;
    }
    if (isRequired != null) {
      data['is_required'] = isRequired;
    }
    if (data.isEmpty) {
      throw ArgumentError('At least one field must be provided for update.');
    }
    try {
      final response = await apiClient.dio.patch(
        '/management/versions/$versionId/assessments/$assessmentId/',
        data: data,
        cancelToken: cancelToken,
      );
      if (cancelToken?.cancelError case final error?) throw error;
      if (response.statusCode != 200) {
        throw const FormatException(
          'Assessment update returned an unexpected status.',
        );
      }
      return ManagedAssessment.fromJson(response.data as Map<String, dynamic>);
    } catch (error) {
      throw apiClient.mapExceptionToApiError(error);
    }
  }

  Future<ManagementPage<ManagedAssessmentQuestion>> assessmentQuestions(
    int versionId,
    int assessmentId, {
    int? page,
    int? pageSize,
    CancelToken? cancelToken,
  }) async {
    if (versionId <= 0) throw ArgumentError.value(versionId, 'versionId');
    if (assessmentId <= 0) {
      throw ArgumentError.value(assessmentId, 'assessmentId');
    }
    return _get(
      'versions/$versionId/assessments/$assessmentId/questions/',
      (json) =>
          ManagementPage.fromJson(json, ManagedAssessmentQuestion.fromJson),
      page: page,
      pageSize: pageSize,
      cancelToken: cancelToken,
    );
  }

  Future<ManagedAssessmentQuestion> assessmentQuestionDetail(
    int versionId,
    int assessmentId,
    int itemId, {
    CancelToken? cancelToken,
  }) async {
    if (versionId <= 0) throw ArgumentError.value(versionId, 'versionId');
    if (assessmentId <= 0) {
      throw ArgumentError.value(assessmentId, 'assessmentId');
    }
    if (itemId <= 0) throw ArgumentError.value(itemId, 'itemId');
    return _get(
      'versions/$versionId/assessments/$assessmentId/questions/$itemId/',
      ManagedAssessmentQuestion.fromJson,
      cancelToken: cancelToken,
    );
  }

  Future<ManagedAssessmentQuestion> createAssessmentQuestion(
    int versionId,
    int assessmentId, {
    required int questionRevisionId,
    required int position,
    double? points,
    CancelToken? cancelToken,
  }) async {
    if (versionId <= 0) throw ArgumentError.value(versionId, 'versionId');
    if (assessmentId <= 0) {
      throw ArgumentError.value(assessmentId, 'assessmentId');
    }
    if (questionRevisionId <= 0) {
      throw ArgumentError.value(questionRevisionId, 'questionRevisionId');
    }
    if (position <= 0) throw ArgumentError.value(position, 'position');
    final data = <String, dynamic>{
      'question_revision_id': questionRevisionId,
      'position': position,
      if (points != null) 'points': points.toStringAsFixed(2),
    };
    try {
      final response = await apiClient.dio.post(
        '/management/versions/$versionId/assessments/$assessmentId/questions/',
        data: data,
        cancelToken: cancelToken,
      );
      if (cancelToken?.cancelError case final error?) throw error;
      if (response.statusCode != 201) {
        throw const FormatException(
          'Assessment question creation returned an unexpected status.',
        );
      }
      return ManagedAssessmentQuestion.fromJson(
        response.data as Map<String, dynamic>,
      );
    } catch (error) {
      throw apiClient.mapExceptionToApiError(error);
    }
  }

  Future<ManagedAssessmentQuestion> updateAssessmentQuestion(
    int versionId,
    int assessmentId,
    int itemId, {
    int? questionRevisionId,
    int? position,
    double? points,
    CancelToken? cancelToken,
  }) async {
    if (versionId <= 0) throw ArgumentError.value(versionId, 'versionId');
    if (assessmentId <= 0) {
      throw ArgumentError.value(assessmentId, 'assessmentId');
    }
    if (itemId <= 0) throw ArgumentError.value(itemId, 'itemId');
    final data = <String, dynamic>{};
    if (questionRevisionId != null) {
      if (questionRevisionId <= 0) {
        throw ArgumentError.value(questionRevisionId, 'questionRevisionId');
      }
      data['question_revision_id'] = questionRevisionId;
    }
    if (position != null) {
      if (position <= 0) throw ArgumentError.value(position, 'position');
      data['position'] = position;
    }
    if (points != null) {
      data['points'] = points.toStringAsFixed(2);
    }
    if (data.isEmpty) {
      throw ArgumentError('At least one field must be provided for update.');
    }
    try {
      final response = await apiClient.dio.patch(
        '/management/versions/$versionId/assessments/$assessmentId/questions/$itemId/',
        data: data,
        cancelToken: cancelToken,
      );
      if (cancelToken?.cancelError case final error?) throw error;
      if (response.statusCode != 200) {
        throw const FormatException(
          'Assessment question update returned an unexpected status.',
        );
      }
      return ManagedAssessmentQuestion.fromJson(
        response.data as Map<String, dynamic>,
      );
    } catch (error) {
      throw apiClient.mapExceptionToApiError(error);
    }
  }

  Future<ManagementPage<ManagedQuestion>> questions({
    int? page,
    int? pageSize,
    String? search,
    bool? isActive,
    CancelToken? cancelToken,
  }) async {
    return _get(
      'questions/',
      (json) => ManagementPage.fromJson(json, ManagedQuestion.fromJson),
      page: page,
      pageSize: pageSize,
      additionalQueryParameters: {
        if (search != null && search.trim().isNotEmpty) 'search': search.trim(),
        'is_active': ?isActive,
      },
      cancelToken: cancelToken,
    );
  }

  Future<ManagedQuestion> questionDetail(
    int questionId, {
    CancelToken? cancelToken,
  }) async {
    if (questionId <= 0) throw ArgumentError.value(questionId, 'questionId');
    return _get(
      'questions/$questionId/',
      ManagedQuestion.fromJson,
      cancelToken: cancelToken,
    );
  }

  Future<ManagedQuestion> createQuestion({
    required String code,
    String? topic,
    bool? isActive,
    CancelToken? cancelToken,
  }) async {
    final normalizedCode = code.trim();
    if (normalizedCode.isEmpty || normalizedCode.length > 40) {
      throw ArgumentError.value(code, 'code');
    }
    final data = <String, dynamic>{
      'code': normalizedCode,
      if (topic != null) 'topic': topic.trim(),
      'is_active': ?isActive,
    };
    try {
      final response = await apiClient.dio.post(
        '/management/questions/',
        data: data,
        cancelToken: cancelToken,
      );
      if (cancelToken?.cancelError case final error?) throw error;
      if (response.statusCode != 201) {
        throw const FormatException(
          'Question creation returned an unexpected status.',
        );
      }
      return ManagedQuestion.fromJson(response.data as Map<String, dynamic>);
    } catch (error) {
      throw apiClient.mapExceptionToApiError(error);
    }
  }

  Future<ManagedQuestion> updateQuestion(
    int questionId, {
    String? code,
    String? topic,
    bool? isActive,
    CancelToken? cancelToken,
  }) async {
    if (questionId <= 0) throw ArgumentError.value(questionId, 'questionId');
    final data = <String, dynamic>{};
    if (code != null) {
      final normalizedCode = code.trim();
      if (normalizedCode.isEmpty || normalizedCode.length > 40) {
        throw ArgumentError.value(code, 'code');
      }
      data['code'] = normalizedCode;
    }
    if (topic != null) {
      data['topic'] = topic.trim();
    }
    if (isActive != null) {
      data['is_active'] = isActive;
    }
    if (data.isEmpty) {
      throw ArgumentError('At least one field must be provided for update.');
    }
    try {
      final response = await apiClient.dio.patch(
        '/management/questions/$questionId/',
        data: data,
        cancelToken: cancelToken,
      );
      if (cancelToken?.cancelError case final error?) throw error;
      if (response.statusCode != 200) {
        throw const FormatException(
          'Question update returned an unexpected status.',
        );
      }
      return ManagedQuestion.fromJson(response.data as Map<String, dynamic>);
    } catch (error) {
      throw apiClient.mapExceptionToApiError(error);
    }
  }

  Future<ManagementPage<ManagedQuestionRevisionSummary>> questionRevisions(
    int questionId, {
    int? page,
    int? pageSize,
    CancelToken? cancelToken,
  }) async {
    if (questionId <= 0) throw ArgumentError.value(questionId, 'questionId');
    return _get(
      'questions/$questionId/revisions/',
      (json) => ManagementPage.fromJson(
        json,
        ManagedQuestionRevisionSummary.fromJson,
      ),
      page: page,
      pageSize: pageSize,
      cancelToken: cancelToken,
    );
  }

  Future<ManagedQuestionRevisionDetail> questionRevisionDetail(
    int questionId,
    int revisionId, {
    CancelToken? cancelToken,
  }) async {
    if (questionId <= 0) throw ArgumentError.value(questionId, 'questionId');
    if (revisionId <= 0) throw ArgumentError.value(revisionId, 'revisionId');
    return _get(
      'questions/$questionId/revisions/$revisionId/',
      ManagedQuestionRevisionDetail.fromJson,
      cancelToken: cancelToken,
    );
  }

  Future<ManagedQuestionRevisionSummary> createQuestionRevision(
    int questionId, {
    required String prompt,
    String? questionType,
    String? explanation,
    CancelToken? cancelToken,
  }) async {
    if (questionId <= 0) throw ArgumentError.value(questionId, 'questionId');
    final normalizedPrompt = prompt.trim();
    if (normalizedPrompt.isEmpty) throw ArgumentError.value(prompt, 'prompt');
    final data = <String, dynamic>{
      'prompt': normalizedPrompt,
      'question_type': ?questionType,
      if (explanation != null) 'explanation': explanation.trim(),
    };
    try {
      final response = await apiClient.dio.post(
        '/management/questions/$questionId/revisions/',
        data: data,
        cancelToken: cancelToken,
      );
      if (cancelToken?.cancelError case final error?) throw error;
      if (response.statusCode != 201) {
        throw const FormatException(
          'Question revision creation returned an unexpected status.',
        );
      }
      return ManagedQuestionRevisionSummary.fromJson(
        response.data as Map<String, dynamic>,
      );
    } catch (error) {
      throw apiClient.mapExceptionToApiError(error);
    }
  }

  Future<ManagedQuestionRevisionDetail> updateQuestionRevision(
    int questionId,
    int revisionId, {
    String? questionType,
    String? prompt,
    String? explanation,
    List<Map<String, dynamic>>? options,
    CancelToken? cancelToken,
  }) async {
    if (questionId <= 0) throw ArgumentError.value(questionId, 'questionId');
    if (revisionId <= 0) throw ArgumentError.value(revisionId, 'revisionId');
    final data = <String, dynamic>{};
    if (questionType != null) {
      final normalizedType = questionType.trim().toUpperCase();
      if (normalizedType.isEmpty) {
        throw ArgumentError.value(questionType, 'questionType');
      }
      data['question_type'] = normalizedType;
    }
    if (prompt != null) {
      final normalizedPrompt = prompt.trim();
      if (normalizedPrompt.isEmpty) throw ArgumentError.value(prompt, 'prompt');
      data['prompt'] = normalizedPrompt;
    }
    if (explanation != null) {
      data['explanation'] = explanation.trim();
    }
    if (options != null) {
      data['options'] = options;
    }
    if (data.isEmpty) {
      throw ArgumentError('At least one field must be provided for update.');
    }
    try {
      final response = await apiClient.dio.patch(
        '/management/questions/$questionId/revisions/$revisionId/',
        data: data,
        cancelToken: cancelToken,
      );
      if (cancelToken?.cancelError case final error?) throw error;
      if (response.statusCode != 200) {
        throw const FormatException(
          'Question revision update returned an unexpected status.',
        );
      }
      return ManagedQuestionRevisionDetail.fromJson(
        response.data as Map<String, dynamic>,
      );
    } catch (error) {
      throw apiClient.mapExceptionToApiError(error);
    }
  }

  Future<ManagedQuestionRevisionDetail> freezeQuestionRevision(
    int questionId,
    int revisionId, {
    CancelToken? cancelToken,
  }) async {
    if (questionId <= 0) throw ArgumentError.value(questionId, 'questionId');
    if (revisionId <= 0) throw ArgumentError.value(revisionId, 'revisionId');
    try {
      final response = await apiClient.dio.post(
        '/management/questions/$questionId/revisions/$revisionId/freeze/',
        data: const <String, dynamic>{},
        cancelToken: cancelToken,
      );
      if (cancelToken?.cancelError case final error?) throw error;
      if (response.statusCode != 200) {
        throw const FormatException(
          'Question revision freeze returned an unexpected status.',
        );
      }
      return ManagedQuestionRevisionDetail.fromJson(
        response.data as Map<String, dynamic>,
      );
    } catch (error) {
      throw apiClient.mapExceptionToApiError(error);
    }
  }

  Future<CreatedAssignment> assignTraining({
    required int employeeId,
    required int trainingVersionId,
    String? dueDate,
    CancelToken? cancelToken,
  }) async {
    if (employeeId <= 0) throw ArgumentError.value(employeeId, 'employeeId');
    if (trainingVersionId <= 0) {
      throw ArgumentError.value(trainingVersionId, 'trainingVersionId');
    }
    final data = <String, Object?>{
      'employee_id': employeeId,
      'training_version_id': trainingVersionId,
      if (dueDate != null && dueDate.isNotEmpty) 'due_date': dueDate,
    };
    try {
      final response = await apiClient.dio.post(
        '/management/assignments/',
        data: data,
        cancelToken: cancelToken,
      );
      if (cancelToken?.cancelError case final error?) throw error;
      if (response.statusCode != 201 && response.statusCode != 200) {
        throw const FormatException(
          'Assignment creation returned an unexpected status.',
        );
      }
      final json = response.data as Map<String, dynamic>;
      return CreatedAssignment.fromJson(json);
    } catch (error) {
      throw apiClient.mapExceptionToApiError(error);
    }
  }

  Future<ManagementPage<OrganizationReference>> references(
    ReferenceKind kind, {
    int page = 1,
    int? pageSize,
    CancelToken? cancelToken,
  }) => _get(
    '${kind.path}/',
    (json) => ManagementPage.fromJson(json, OrganizationReference.fromJson),
    page: page,
    pageSize: pageSize,
    cancelToken: cancelToken,
  );

  Future<List<OrganizationReference>> allReferences(
    ReferenceKind kind, {
    CancelToken? cancelToken,
  }) => _allReferencePages(kind, cancelToken);

  Future<OrganizationReference> saveReference(
    ReferenceKind kind, {
    int? id,
    OrganizationReference? original,
    required String code,
    required String name,
    required String description,
    required bool isActive,
    CancelToken? cancelToken,
  }) async {
    if (id != null && id <= 0) throw ArgumentError.value(id, 'id');
    final path = '/management/${kind.path}/${id == null ? '' : '$id/'}';
    final Map<String, Object> data;
    if (id == null) {
      data = {
        'code': code,
        'name': name,
        'description': description,
        'is_active': isActive,
      };
    } else {
      if (original == null || original.id != id) {
        throw ArgumentError.value(original, 'original');
      }
      data = {
        if (code != original.code) 'code': code,
        if (name != original.name) 'name': name,
        if (description != original.description) 'description': description,
        if (isActive != original.isActive) 'is_active': isActive,
      };
      if (data.isEmpty) {
        throw ArgumentError('No organization reference fields changed.');
      }
    }
    try {
      final response = id == null
          ? await apiClient.dio.post(path, data: data, cancelToken: cancelToken)
          : await apiClient.dio.patch(
              path,
              data: data,
              cancelToken: cancelToken,
            );
      if (cancelToken?.cancelError case final error?) throw error;
      final saved = OrganizationReference.fromJson(
        response.data as Map<String, dynamic>,
      );
      if (id != null && saved.id != id) {
        throw const FormatException(
          'Organization reference identity mismatch.',
        );
      }
      return saved;
    } catch (error) {
      throw apiClient.mapExceptionToApiError(error);
    }
  }

  Future<EmployeeEditChoices> employeeEditChoices({
    required int employeeId,
    int pageSize = 100,
    CancelToken? cancelToken,
  }) async {
    if (employeeId <= 0) {
      throw ArgumentError.value(employeeId, 'employeeId');
    }
    return _employeeFormChoices(
      excludeEmployeeId: employeeId,
      pageSize: pageSize,
      cancelToken: cancelToken,
    );
  }

  Future<EmployeeEditChoices> employeeCreationChoices({
    int pageSize = 100,
    bool includeReportingManagers = true,
    CancelToken? cancelToken,
  }) => _employeeFormChoices(
    pageSize: pageSize,
    includeReportingManagers: includeReportingManagers,
    cancelToken: cancelToken,
  );

  Future<EmployeeEditChoices> _employeeFormChoices({
    int? excludeEmployeeId,
    required int pageSize,
    bool includeReportingManagers = true,
    CancelToken? cancelToken,
  }) async {
    if (pageSize <= 0 || pageSize > 100) {
      throw ArgumentError.value(pageSize, 'pageSize');
    }
    final referencePages = await Future.wait([
      _allReferencePages(
        ReferenceKind.departments,
        cancelToken,
        pageSize: pageSize,
      ),
      _allReferencePages(
        ReferenceKind.jobRoles,
        cancelToken,
        pageSize: pageSize,
      ),
    ]);
    final managers = includeReportingManagers
        ? await _allEmployeePages(cancelToken, pageSize: pageSize)
        : <DirectoryEmployee>[];
    return EmployeeEditChoices(
      departments: referencePages[0],
      jobRoles: referencePages[1],
      reportingManagers: managers
          .where((employee) => employee.id != excludeEmployeeId)
          .toList(),
    );
  }

  Future<List<OrganizationReference>> _allReferencePages(
    ReferenceKind kind,
    CancelToken? cancelToken, {
    int pageSize = 100,
    int maxPages = 50,
  }) async {
    final items = <OrganizationReference>[];
    final seenIds = <int>{};
    var pageNumber = 1;
    var hasMore = true;
    var expectedCount = 0;
    while (hasMore && pageNumber <= maxPages) {
      final page = await references(
        kind,
        page: pageNumber,
        pageSize: pageSize,
        cancelToken: cancelToken,
      );
      expectedCount = page.count;
      hasMore = page.hasMore;
      if (page.items.isEmpty) {
        if (hasMore) {
          throw _incompleteChoicesError('organization references');
        }
        break;
      }
      var newCount = 0;
      for (final item in page.items) {
        if (seenIds.add(item.id)) {
          items.add(item);
          newCount++;
        }
      }
      if (newCount == 0) {
        if (hasMore) {
          throw _incompleteChoicesError('organization references');
        }
        break;
      }
      pageNumber++;
    }
    if (hasMore || items.length < expectedCount) {
      throw _incompleteChoicesError('organization references');
    }
    return items;
  }

  Future<List<DirectoryEmployee>> _allEmployeePages(
    CancelToken? cancelToken, {
    int pageSize = 100,
    int maxPages = 50,
  }) async {
    final items = <DirectoryEmployee>[];
    final seenIds = <int>{};
    var pageNumber = 1;
    var hasMore = true;
    var expectedCount = 0;
    while (hasMore && pageNumber <= maxPages) {
      final page = await employees(
        page: pageNumber,
        pageSize: pageSize,
        cancelToken: cancelToken,
      );
      expectedCount = page.count;
      hasMore = page.hasMore;
      if (page.items.isEmpty) {
        if (hasMore) {
          throw _incompleteChoicesError('employee choices');
        }
        break;
      }
      var newCount = 0;
      for (final item in page.items) {
        if (seenIds.add(item.id)) {
          items.add(item);
          newCount++;
        }
      }
      if (newCount == 0) {
        if (hasMore) {
          throw _incompleteChoicesError('employee choices');
        }
        break;
      }
      pageNumber++;
    }
    if (hasMore || items.length < expectedCount) {
      throw _incompleteChoicesError('employee choices');
    }
    return items;
  }

  ApiError _incompleteChoicesError(String choices) => ApiError(
    message: 'Could not load all $choices. Refresh and try again.',
    code: 'incomplete_pagination',
  );

  Future<DirectoryEmployee> updateEmployeeProfile(
    DirectoryEmployee original, {
    required String displayName,
    required int departmentId,
    required int jobRoleId,
    required String dateJoined,
    required bool updateReportingManager,
    int? reportingManagerId,
    CancelToken? cancelToken,
  }) async {
    if (original.id <= 0) throw ArgumentError.value(original.id, 'employeeId');
    if (departmentId <= 0) {
      throw ArgumentError.value(departmentId, 'departmentId');
    }
    if (jobRoleId <= 0) throw ArgumentError.value(jobRoleId, 'jobRoleId');
    if (updateReportingManager &&
        reportingManagerId != null &&
        reportingManagerId <= 0) {
      throw ArgumentError.value(reportingManagerId, 'reportingManagerId');
    }
    final data = <String, Object?>{
      if (displayName != original.displayName) 'display_name': displayName,
      if (departmentId != original.department.id) 'department': departmentId,
      if (jobRoleId != original.jobRole.id) 'job_role': jobRoleId,
      if (dateJoined != original.dateJoined) 'date_joined': dateJoined,
      if (updateReportingManager) 'reporting_manager': reportingManagerId,
    };
    if (data.isEmpty) {
      throw ArgumentError('No employee profile fields changed.');
    }
    final path = '/management/employees/${original.id}/';
    try {
      final response = await apiClient.dio.patch(
        path,
        data: data,
        cancelToken: cancelToken,
      );
      if (cancelToken?.cancelError case final error?) throw error;
      final json = response.data as Map<String, dynamic>;
      _validateManagerResponseContract(json);
      final saved = DirectoryEmployee.fromJson(json);
      if (saved.id != original.id) {
        throw const FormatException('Employee identity mismatch.');
      }
      return saved;
    } catch (error) {
      throw apiClient.mapExceptionToApiError(error);
    }
  }

  Future<DirectoryEmployee> createEmployee({
    required String employeeCode,
    required String displayName,
    required int departmentId,
    required int jobRoleId,
    required String dateJoined,
    int? reportingManagerId,
    CancelToken? cancelToken,
  }) async {
    if (departmentId <= 0) {
      throw ArgumentError.value(departmentId, 'departmentId');
    }
    if (jobRoleId <= 0) throw ArgumentError.value(jobRoleId, 'jobRoleId');
    if (reportingManagerId != null && reportingManagerId <= 0) {
      throw ArgumentError.value(reportingManagerId, 'reportingManagerId');
    }
    final data = <String, Object?>{
      'employee_code': employeeCode.trim(),
      'display_name': displayName.trim(),
      'department': departmentId,
      'job_role': jobRoleId,
      'date_joined': dateJoined,
      'reporting_manager': reportingManagerId,
    };
    try {
      final response = await apiClient.dio.post(
        '/management/employees/',
        data: data,
        cancelToken: cancelToken,
      );
      if (cancelToken?.cancelError case final error?) throw error;
      if (response.statusCode != 201) {
        throw const FormatException(
          'Employee creation returned an unexpected status.',
        );
      }
      final json = response.data as Map<String, dynamic>;
      _validateManagerResponseContract(json);
      final created = DirectoryEmployee.fromJson(json);
      if (created.id <= 0) {
        throw const FormatException('Invalid created employee identity.');
      }
      return created;
    } catch (error) {
      throw apiClient.mapExceptionToApiError(error);
    }
  }

  Future<DirectoryEmployee> deactivateEmployee(
    int employeeId, {
    required String reason,
    CancelToken? cancelToken,
  }) async {
    if (employeeId <= 0) throw ArgumentError.value(employeeId, 'employeeId');
    final normalizedReason = reason.trim();
    if (normalizedReason.isEmpty || normalizedReason.length > 1000) {
      throw ArgumentError.value(reason, 'reason');
    }
    final path = '/management/employees/$employeeId/deactivate/';
    try {
      final response = await apiClient.dio.post(
        path,
        data: {'reason': normalizedReason},
        cancelToken: cancelToken,
      );
      if (cancelToken?.cancelError case final error?) throw error;
      if (response.statusCode != 200) {
        throw const FormatException(
          'Employee deactivation returned an unexpected status.',
        );
      }
      final json = response.data as Map<String, dynamic>;
      _validateManagerResponseContract(json);
      final deactivated = DirectoryEmployee.fromJson(json);
      if (deactivated.id != employeeId || deactivated.isActive) {
        throw const FormatException(
          'Employee deactivation response did not confirm the requested employee.',
        );
      }
      return deactivated;
    } catch (error) {
      throw apiClient.mapExceptionToApiError(error);
    }
  }

  void _validateManagerResponseContract(Map<String, dynamic> json) {
    if (!json.containsKey('reporting_manager_id') ||
        !json.containsKey('reporting_manager')) {
      throw const FormatException(
        'Employee response is missing reporting manager data.',
      );
    }
    final managerId = json['reporting_manager_id'];
    final managerName = json['reporting_manager'];
    if ((managerId != null && (managerId is! int || managerId <= 0)) ||
        (managerName != null && managerName is! String)) {
      throw const FormatException(
        'Employee response has invalid reporting manager data.',
      );
    }
  }
}
