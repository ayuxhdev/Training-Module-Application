import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:training_app/core/errors/api_error.dart';
import 'package:training_app/core/network/dio_client.dart';
import 'package:training_app/core/providers/core_providers.dart';
import 'package:training_app/features/management/data/services/video_file_picker.dart';
import 'package:training_app/features/management/domain/models/management_models.dart';
import 'package:training_app/features/management/presentation/models/assignment_report_view_data.dart';
import 'package:training_app/features/management/presentation/models/audit_log_view_data.dart';

final managementRepositoryProvider = Provider<ManagementRepository>(
  (ref) => ManagementRepository(ref.watch(apiClientProvider)),
);

/// Keeps fully enumerated choices usable when other collections fail to load.
/// The failure remains explicit; truncated collections are never exposed.
class FilterOptionsLoadFailure<T> extends ApiError {
  final T completeOptions;
  final Map<String, ApiError> failures;

  Set<String> get unavailableCollections => failures.keys.toSet();

  FilterOptionsLoadFailure({
    required this.completeOptions,
    required Map<String, ApiError> failures,
    required ApiError cause,
  }) : failures = Map.unmodifiable(failures),
       super(
         message: cause.message,
         code: cause.code,
         statusCode: cause.statusCode,
       );
}

/// Server-rendered CSV; bytes are handed to the saver without reserialization.
class AssignmentReportCsvDownload {
  final Uint8List bytes;
  final String filename;
  final int itemCount;

  AssignmentReportCsvDownload({
    required this.bytes,
    required this.filename,
    required this.itemCount,
  });

  static const _header =
      'Employee,Department,Job role,Training,Version,Assigned,Deadline,Status,Overdue,Completed,Certificate';

  factory AssignmentReportCsvDownload.fromResponse(
    Response<List<int>> response,
  ) {
    final types = response.headers[Headers.contentTypeHeader];
    final contentType = types != null && types.length == 1
        ? types.single.toLowerCase()
        : '';
    final bytes = response.data;
    if (response.statusCode != 200 ||
        contentType.split(';').first.trim() != 'text/csv' ||
        (RegExp(r'\bcharset\s*=').hasMatch(contentType) &&
            !RegExp(r'charset\s*=\s*"?utf-8"?\s*(;|$)')
                .hasMatch(contentType)) ||
        bytes == null ||
        bytes.isEmpty) {
      throw const FormatException('Expected a non-empty UTF-8 CSV download.');
    }
    var csv = utf8.decode(bytes);
    if (csv.startsWith('\uFEFF')) csv = csv.substring(1);
    if (csv != _header &&
        !csv.startsWith('$_header\r\n') &&
        !csv.startsWith('$_header\n')) {
      throw const FormatException('The CSV report header is invalid.');
    }
    final dispositions = response.headers['content-disposition'];
    return AssignmentReportCsvDownload(
      bytes: Uint8List.fromList(bytes),
      filename: _filename(
        dispositions != null && dispositions.length == 1
            ? dispositions.single
            : null,
      ),
      itemCount: _recordCount(csv) - 1,
    );
  }

  static String _filename(String? disposition) {
    String? candidate;
    if (disposition != null) {
      final extended = RegExp(
        r"(?:^|;)\s*filename\*\s*=\s*UTF-8''([^;]+)",
        caseSensitive: false,
      ).firstMatch(disposition);
      if (extended != null) {
        try {
          candidate = Uri.decodeComponent(extended.group(1)!.trim());
        } on ArgumentError {
          // Invalid percent escapes are not necessarily FormatExceptions.
          candidate = null;
        } on FormatException {
          candidate = null;
        }
      } else {
        final plain = RegExp(
          r'(?:^|;)\s*filename\s*=\s*(?:"([^"]*)"|([^;]+))',
          caseSensitive: false,
        ).firstMatch(disposition);
        candidate = (plain?.group(1) ?? plain?.group(2))?.trim();
      }
    }
    // Accept only a short ASCII basename; reject traversal, controls, Unicode
    // direction overrides and Windows device names rather than repairing them.
    if (candidate != null &&
        RegExp(
          r'^[A-Za-z0-9][A-Za-z0-9._-]{0,110}\.csv$',
          caseSensitive: false,
        ).hasMatch(candidate) &&
        !candidate.contains('..') &&
        !RegExp(
          r'^(con|prn|aux|nul|com[1-9]|lpt[1-9])\.',
          caseSensitive: false,
        ).hasMatch(candidate)) {
      return candidate;
    }
    final now = DateTime.now();
    final date =
        '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    return 'assignment-report-$date.csv';
  }

  // Validate quoting/column boundaries and count records, including quoted
  // newlines, without creating report models or changing server cell values.
  static int _recordCount(String csv) {
    var records = 0;
    var fields = 1;
    var quoted = false;
    var afterQuote = false;
    var fieldStart = true;
    var rowStarted = false;
    for (var index = 0; index < csv.length; index++) {
      final char = csv[index];
      if (quoted) {
        if (char == '"') {
          if (index + 1 < csv.length && csv[index + 1] == '"') {
            index++;
          } else {
            quoted = false;
            afterQuote = true;
          }
        }
        continue;
      }
      if (afterQuote && char != ',' && char != '\r' && char != '\n') {
        throw const FormatException('Invalid CSV quoting.');
      }
      if (char == '"') {
        if (!fieldStart) throw const FormatException('Invalid CSV quoting.');
        quoted = true;
        fieldStart = false;
        rowStarted = true;
      } else if (char == ',') {
        fields++;
        fieldStart = true;
        afterQuote = false;
        rowStarted = true;
      } else if (char == '\r' || char == '\n') {
        if (fields != 11) {
          throw const FormatException('Invalid CSV column count.');
        }
        records++;
        if (char == '\r' && index + 1 < csv.length && csv[index + 1] == '\n') {
          index++;
        }
        fields = 1;
        fieldStart = true;
        afterQuote = false;
        rowStarted = false;
      } else {
        fieldStart = false;
        rowStarted = true;
      }
    }
    if (quoted) throw const FormatException('Unterminated CSV field.');
    if (rowStarted) {
      if (fields != 11) {
        throw const FormatException('Invalid CSV column count.');
      }
      records++;
    }
    return records;
  }
}

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

  Future<ManagementPage<RoleTrainingRequirement>> roleRequirements({
    int page = 1,
    int? pageSize,
    String? search,
    int? jobRoleId,
    int? trainingVersionId,
    bool? isActive,
    CancelToken? cancelToken,
  }) {
    if (jobRoleId != null && jobRoleId <= 0) {
      throw ArgumentError.value(jobRoleId, 'jobRoleId');
    }
    if (trainingVersionId != null && trainingVersionId <= 0) {
      throw ArgumentError.value(trainingVersionId, 'trainingVersionId');
    }
    final normalizedSearch = search?.trim();
    return _get(
      'role-requirements/',
      (json) => ManagementPage.fromJson(json, RoleTrainingRequirement.fromJson),
      page: page,
      pageSize: pageSize,
      additionalQueryParameters: {
        'search': ?(normalizedSearch?.isNotEmpty == true
            ? normalizedSearch
            : null),
        'job_role_id': ?jobRoleId,
        'training_version_id': ?trainingVersionId,
        'is_active': ?isActive,
      },
      cancelToken: cancelToken,
    );
  }

  Future<RoleTrainingRequirement> roleRequirement(
    int id, {
    CancelToken? cancelToken,
  }) async {
    if (id <= 0) throw ArgumentError.value(id, 'id');
    return _get(
      'role-requirements/$id/',
      RoleTrainingRequirement.fromJson,
      cancelToken: cancelToken,
    );
  }

  Future<RoleTrainingRequirement> createRoleRequirement({
    required int jobRoleId,
    required int trainingVersionId,
    int dueInDays = 30,
    bool isActive = true,
    CancelToken? cancelToken,
  }) async {
    if (jobRoleId <= 0) throw ArgumentError.value(jobRoleId, 'jobRoleId');
    if (trainingVersionId <= 0) {
      throw ArgumentError.value(trainingVersionId, 'trainingVersionId');
    }
    if (dueInDays < 0) throw ArgumentError.value(dueInDays, 'dueInDays');
    final path = '/management/role-requirements/';
    try {
      final response = await apiClient.dio.post(
        path,
        data: {
          'job_role_id': jobRoleId,
          'training_version_id': trainingVersionId,
          'due_in_days': dueInDays,
          'is_active': isActive,
        },
        cancelToken: cancelToken,
      );
      if (cancelToken?.cancelError case final error?) throw error;
      return RoleTrainingRequirement.fromJson(
        response.data as Map<String, dynamic>,
      );
    } catch (error) {
      throw apiClient.mapExceptionToApiError(error);
    }
  }

  Future<RoleTrainingRequirement> updateRoleRequirement({
    required int id,
    int? dueInDays,
    bool? isActive,
    CancelToken? cancelToken,
  }) async {
    if (id <= 0) throw ArgumentError.value(id, 'id');
    if (dueInDays != null && dueInDays < 0) {
      throw ArgumentError.value(dueInDays, 'dueInDays');
    }
    if (dueInDays == null && isActive == null) {
      throw ArgumentError(
        'At least one field (dueInDays or isActive) must be provided.',
      );
    }
    final path = '/management/role-requirements/$id/';
    final payload = <String, dynamic>{
      'due_in_days': ?dueInDays,
      'is_active': ?isActive,
    };
    try {
      final response = await apiClient.dio.patch(
        path,
        data: payload,
        cancelToken: cancelToken,
      );
      if (cancelToken?.cancelError case final error?) throw error;
      return RoleTrainingRequirement.fromJson(
        response.data as Map<String, dynamic>,
      );
    } catch (error) {
      throw apiClient.mapExceptionToApiError(error);
    }
  }

  Future<RoleBatchResult> executeRoleBatchAssignment(
    int id, {
    CancelToken? cancelToken,
  }) async {
    if (id <= 0) throw ArgumentError.value(id, 'id');
    final path = '/management/role-requirements/$id/assignments/';
    try {
      final response = await apiClient.dio.post(
        path,
        data: <String, dynamic>{},
        cancelToken: cancelToken,
      );
      if (cancelToken?.cancelError case final error?) throw error;
      return RoleBatchResult.fromJson(response.data as Map<String, dynamic>);
    } catch (error) {
      throw apiClient.mapExceptionToApiError(error);
    }
  }

  Future<List<AssignableTrainingVersion>> allAssignableTrainingVersions({
    CancelToken? cancelToken,
    int pageSize = 50,
    int maxPages = 50,
  }) async {
    final items = <AssignableTrainingVersion>[];
    final seenIds = <int>{};
    var pageNumber = 1;
    var hasMore = true;
    var expectedCount = 0;
    while (hasMore && pageNumber <= maxPages) {
      final page = await assignableTrainingVersions(
        page: pageNumber,
        pageSize: pageSize,
        cancelToken: cancelToken,
      );
      expectedCount = page.count;
      hasMore = page.hasMore;
      if (page.items.isEmpty) {
        if (hasMore) {
          throw _incompleteChoicesError('published training versions');
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
          throw _incompleteChoicesError('published training versions');
        }
        break;
      }
      pageNumber++;
    }
    if (hasMore || items.length < expectedCount) {
      throw _incompleteChoicesError('published training versions');
    }
    return items;
  }

  Future<List<AssignableTrainingVersion>> allPublishedVersionsFromDiscovery({
    CancelToken? cancelToken,
    int pageSize = 50,
    int maxPages = 50,
  }) async {
    final items = <AssignableTrainingVersion>[];
    final seenRawIds = <int>{};
    var pageNumber = 1;
    var hasMore = true;
    var expectedCount = 0;
    while (hasMore && pageNumber <= maxPages) {
      final page = await allTrainingVersions(
        page: pageNumber,
        pageSize: pageSize,
        cancelToken: cancelToken,
      );
      expectedCount = page.count;
      hasMore = page.hasMore;
      if (page.items.isEmpty) {
        if (hasMore) {
          throw _incompleteChoicesError('published training versions');
        }
        break;
      }
      var newRawCount = 0;
      for (final item in page.items) {
        if (seenRawIds.add(item.id)) {
          newRawCount++;
          if (item.status.toUpperCase() == 'PUBLISHED') {
            items.add(
              AssignableTrainingVersion(
                id: item.id,
                trainingId: item.trainingId,
                trainingCode: '',
                trainingTitle: item.trainingTitle ?? '',
                versionNumber: item.versionNumber,
                title: item.title,
                status: item.status,
              ),
            );
          }
        }
      }
      if (newRawCount == 0) {
        if (hasMore) {
          throw _incompleteChoicesError('published training versions');
        }
        break;
      }
      pageNumber++;
    }
    if (hasMore || seenRawIds.length < expectedCount) {
      throw _incompleteChoicesError('published training versions');
    }
    return items;
  }

  Future<List<AssignableTrainingVersion>> allPublishedTrainingVersions({
    required bool canViewVersionsPermission,
    required bool canAssignTrainingPermission,
    CancelToken? cancelToken,
  }) async {
    if (canViewVersionsPermission) {
      return allPublishedVersionsFromDiscovery(cancelToken: cancelToken);
    }
    if (canAssignTrainingPermission) {
      return allAssignableTrainingVersions(cancelToken: cancelToken);
    }
    throw ApiError(
      message: 'Viewing published training versions requires training version view permissions (training.view_trainingversion) or assignment authority.',
      statusCode: 403,
    );
  }

  Future<ManagementPage<RoleRequirementOption>> roleRequirementCreationOptions({
    required RoleRequirementOptionKind kind,
    int page = 1,
    int? pageSize,
    CancelToken? cancelToken,
  }) {
    if (page <= 0) throw ArgumentError.value(page, 'page');
    if (pageSize != null && (pageSize <= 0 || pageSize > 100)) {
      throw ArgumentError.value(pageSize, 'pageSize');
    }
    return _get(
      'role-requirements/creation-options/',
      (json) => ManagementPage.fromJson(json, RoleRequirementOption.fromJson),
      page: page,
      pageSize: pageSize,
      additionalQueryParameters: {'kind': kind.queryParam},
      cancelToken: cancelToken,
    );
  }

  Future<List<RoleRequirementOption>> allRoleRequirementCreationOptions({
    required RoleRequirementOptionKind kind,
    CancelToken? cancelToken,
    int pageSize = 50,
    int maxPages = 50,
  }) async {
    final items = <RoleRequirementOption>[];
    final seenIds = <int>{};
    var pageNumber = 1;
    var hasMore = true;
    var expectedCount = 0;
    while (hasMore && pageNumber <= maxPages) {
      final page = await roleRequirementCreationOptions(
        kind: kind,
        page: pageNumber,
        pageSize: pageSize,
        cancelToken: cancelToken,
      );
      expectedCount = page.count;
      hasMore = page.hasMore;
      if (page.items.isEmpty) {
        if (hasMore) {
          throw _incompleteChoicesError('${kind.label} options');
        }
        break;
      }
      for (final item in page.items) {
        if (!seenIds.add(item.id)) {
          throw _incompleteChoicesError('${kind.label} options');
        }
        items.add(item);
      }
      pageNumber++;
    }
    if (hasMore || items.length < expectedCount) {
      throw _incompleteChoicesError('${kind.label} options');
    }
    return items;
  }

  Future<ManagementPage<ManagedCertificate>> certificates({
    int page = 1,
    int? pageSize,
    String? search,
    bool? isRevoked,
    CancelToken? cancelToken,
  }) {
    final normalizedSearch = search?.trim();
    return _get(
      'certificates/',
      (json) => ManagementPage.fromJson(json, ManagedCertificate.fromJson),
      page: page,
      pageSize: pageSize,
      additionalQueryParameters: {
        'search': ?(normalizedSearch?.isNotEmpty == true
            ? normalizedSearch
            : null),
        'is_revoked': ?isRevoked,
      },
      cancelToken: cancelToken,
    );
  }

  Future<ManagedCertificateDetail> certificateDetail(
    int certificateId, {
    CancelToken? cancelToken,
  }) {
    if (certificateId <= 0) {
      throw ArgumentError.value(certificateId, 'certificateId');
    }
    return _get(
      'certificates/$certificateId/',
      ManagedCertificateDetail.fromJson,
      cancelToken: cancelToken,
    );
  }

  Future<CertificateRevocationResult> revokeCertificate(
    int certificateId,
    String reason, {
    CancelToken? cancelToken,
  }) async {
    if (certificateId <= 0) {
      throw ArgumentError.value(certificateId, 'certificateId');
    }
    final normalizedReason = reason.trim();
    if (normalizedReason.isEmpty || normalizedReason.length > 1000) {
      throw ArgumentError.value(reason, 'reason');
    }
    final path = '/management/certificates/$certificateId/revoke/';
    try {
      final response = await apiClient.dio.post(
        path,
        data: {'reason': normalizedReason},
        cancelToken: cancelToken,
      );
      if (cancelToken?.cancelError case final error?) throw error;
      if (response.statusCode != 200) {
        throw const FormatException(
          'Certificate revocation returned an unexpected status.',
        );
      }
      return CertificateRevocationResult.fromJson(
        response.data as Map<String, dynamic>,
      );
    } catch (error) {
      throw apiClient.mapExceptionToApiError(error);
    }
  }

  Future<AssignmentReportPageViewData> assignmentReport({
    required AssignmentReportFilterQuery query,
    CancelToken? cancelToken,
  }) {
    final additional = _assignmentReportFilters(query);

    return _get(
      'reports/assignments/',
      (json) => AssignmentReportPageViewData.fromJson(
        json,
        page: query.page,
        pageSize: query.pageSize,
      ),
      page: query.page,
      pageSize: query.pageSize,
      additionalQueryParameters: additional.isEmpty ? null : additional,
      cancelToken: cancelToken,
    );
  }

  Map<String, dynamic> _assignmentReportFilters(
    AssignmentReportFilterQuery query, {
    bool strict = false,
  }) {
    final parameters = <String, dynamic>{};
    final status = query.status?.trim();
    if (status != null && status.isNotEmpty) parameters['status'] = status;
    for (final entry in {
      'department': query.departmentId,
      'job_role': query.jobRoleId,
      'training': query.trainingId,
      'training_version': query.trainingVersionId,
    }.entries) {
      final value = entry.value;
      if (value == null || value.isEmpty) continue;
      final id = int.tryParse(value);
      if (id == null || id <= 0) {
        if (strict) {
          throw ApiError(
            message: 'A selected report filter is invalid. Reopen the filters and try again.',
            statusCode: 400,
            code: 'validation_error',
          );
        }
        continue;
      }
      parameters[entry.key] = id;
    }
    if (query.overdueOnly == true) parameters['overdue_only'] = true;
    return parameters;
  }

  Future<AssignmentReportCsvDownload> downloadAssignmentReportCsv({
    required AssignmentReportFilterQuery query,
    CancelToken? cancelToken,
  }) async {
    final requests = CancelToken();
    var pending = true;
    cancelToken?.whenCancel.then((error) {
      if (pending) requests.cancel(error);
    });
    try {
      if (cancelToken?.cancelError case final cancelled?) throw cancelled;
      final response = await apiClient.dio
          .get<List<int>>(
            '/management/reports/assignments/export/',
            queryParameters: _assignmentReportFilters(query, strict: true),
            cancelToken: requests,
            options: Options(
              responseType: ResponseType.bytes,
              // DRF negotiates JSON errors before returning the CSV response.
              headers: {'Accept': 'text/csv, application/json'},
              receiveTimeout: const Duration(seconds: 90),
            ),
          )
          .timeout(
            const Duration(minutes: 2),
            onTimeout: () {
              requests.cancel('Report download deadline exceeded.');
              throw ApiError.timeout();
            },
          );
      if (cancelToken?.cancelError case final cancelled?) throw cancelled;
      return AssignmentReportCsvDownload.fromResponse(response);
    } catch (error) {
      if (error is DioException) {
        if (CancelToken.isCancel(error)) rethrow;
        if (error.error is ApiError) {
          throw apiClient.mapExceptionToApiError(error);
        }
        final status = error.response?.statusCode;
        // Dio byte responses also contain bytes for JSON error envelopes.
        // Decode errors only; never send them to the document saver.
        if (status != null) {
          if (status == 413) {
            throw ApiError(
              message: 'Reports are limited to 10,000 rows. Narrow the filters and try again.',
              statusCode: 413,
              code: 'export_too_large',
            );
          }
          try {
            final body = error.response?.data;
            final decoded = body is List<int>
                ? jsonDecode(utf8.decode(body))
                : body;
            if (decoded is Map<String, dynamic> && status < 500) {
              throw ApiError.fromBackend(status, decoded);
            }
          } on FormatException {
            // Non-JSON errors use controlled messages below.
          }
          throw ApiError(
            message: status == 401
                ? 'Your session has ended. Sign in again to continue.'
                : status == 403
                ? 'You do not have permission to export this report.'
                : status == 400
                ? 'The report filters are invalid. Review them and try again.'
                : 'The report could not be downloaded. Please try again later.',
            statusCode: status,
          );
        }
      }
      if (error is FormatException) {
        throw ApiError(
          message:
              'The server did not return a valid CSV report. Please try again.',
          code: 'invalid_response',
        );
      }
      throw apiClient.mapExceptionToApiError(error);
    } finally {
      pending = false;
    }
  }

  Future<AssignmentReportFilterOptionsViewData> assignmentReportFilterOptions({
    CancelToken? cancelToken,
  }) async {
    final initial = await _get(
      'reports/assignments/filters/',
      (json) => json,
      additionalQueryParameters: {'page_size': 100},
      cancelToken: cancelToken,
    );

    final statuses =
        (initial['statuses'] as List<dynamic>?)
            ?.map((item) {
              final map = item as Map<String, dynamic>;
              return ReportFilterOption(
                value: (map['value'] as String?)?.trim() ?? '',
                label: (map['label'] as String?)?.trim() ?? '',
              );
            })
            .where((opt) => opt.value.isNotEmpty)
            .toList() ??
        const [];

    final departments = <ReportFilterOption>[];
    for (final item in (initial['departments'] as List<dynamic>? ?? const [])) {
      final map = item as Map<String, dynamic>;
      final id = map['id'];
      if (id != null) {
        departments.add(
          ReportFilterOption(
            value: '$id',
            label: (map['label'] as String?)?.trim() ?? '',
          ),
        );
      }
    }

    final jobRoles = <ReportFilterOption>[];
    for (final item in (initial['job_roles'] as List<dynamic>? ?? const [])) {
      final map = item as Map<String, dynamic>;
      final id = map['id'];
      if (id != null) {
        jobRoles.add(
          ReportFilterOption(
            value: '$id',
            label: (map['label'] as String?)?.trim() ?? '',
          ),
        );
      }
    }

    final trainings = <ReportFilterOption>[];
    for (final item in (initial['trainings'] as List<dynamic>? ?? const [])) {
      final map = item as Map<String, dynamic>;
      final id = map['id'];
      if (id != null) {
        trainings.add(
          ReportFilterOption(
            value: '$id',
            label: (map['label'] as String?)?.trim() ?? '',
          ),
        );
      }
    }

    final trainingVersions = <ReportVersionFilterOption>[];
    for (final item
        in (initial['training_versions'] as List<dynamic>? ?? const [])) {
      final map = item as Map<String, dynamic>;
      final id = map['id'] as int? ?? 0;
      if (id > 0) {
        trainingVersions.add(
          ReportVersionFilterOption(
            id: id,
            trainingId: map['training_id'] as int? ?? 0,
            versionNumber: map['version_number'] as int? ?? 1,
            title:
                (map['title'] as String?)?.trim() ??
                (map['label'] as String?)?.trim() ??
                '',
          ),
        );
      }
    }

    final pagination =
        initial['pagination'] as Map<String, dynamic>? ?? const {};

    Future<void> continueCollection(
      String kind,
      void Function(Map<String, dynamic> row) addRow,
    ) async {
      final collMeta = pagination[kind] as Map<String, dynamic>?;
      final initialRows = initial[kind] as List<dynamic>? ?? const [];
      final seenIds = initialRows
          .map((row) => (row as Map<String, dynamic>)['id'])
          .toSet();
      final expectedCount = collMeta?['count'] as int? ?? initialRows.length;
      var next = collMeta?['next'];
      final seenContinuations = <Object>{};
      if (seenIds.length != initialRows.length ||
          (next != null && initialRows.isEmpty)) {
        throw _incompleteChoicesError('$kind filter options');
      }

      var pageNumber = 2;
      const maxPages = 10;
      while (next != null && pageNumber <= maxPages) {
        if (!seenContinuations.add(next)) {
          throw _incompleteChoicesError('$kind filter options');
        }
        final pageJson = await _get(
          'reports/assignments/filters/',
          (json) => json,
          additionalQueryParameters: {
            'kind': kind,
            'page': pageNumber,
            'page_size': 100,
          },
          cancelToken: cancelToken,
        );
        final rows = pageJson[kind] as List<dynamic>? ?? const [];
        if (rows.isEmpty) throw _incompleteChoicesError('$kind filter options');
        for (final r in rows) {
          if (!seenIds.add((r as Map<String, dynamic>)['id'])) {
            throw _incompleteChoicesError('$kind filter options');
          }
          addRow(r);
        }
        final pageMeta = pageJson['pagination']?[kind] as Map<String, dynamic>?;
        next = pageMeta?['next'];
        pageNumber++;
      }
      if (next != null || seenIds.length < expectedCount) {
        throw _incompleteChoicesError('$kind filter options');
      }
    }

    final failures = <String, ApiError>{};
    Future<void> loadCollection(
      String kind,
      List<dynamic> choices,
      void Function(Map<String, dynamic>) addRow,
    ) async {
      try {
        await continueCollection(kind, addRow);
      } catch (error) {
        if (cancelToken?.isCancelled == true) rethrow;
        final apiError = error is ApiError
            ? error
            : apiClient.mapExceptionToApiError(error);
        if (apiError.statusCode == 401 ||
            apiError.statusCode == 403 ||
            apiError.code == 'cancelled') {
          throw apiError;
        }
        choices.clear();
        failures[kind] = apiError;
      }
    }

    await loadCollection('departments', departments, (map) {
      final id = map['id'];
      if (id != null) {
        departments.add(
          ReportFilterOption(
            value: '$id',
            label: (map['label'] as String?)?.trim() ?? '',
          ),
        );
      }
    });

    await loadCollection('job_roles', jobRoles, (map) {
      final id = map['id'];
      if (id != null) {
        jobRoles.add(
          ReportFilterOption(
            value: '$id',
            label: (map['label'] as String?)?.trim() ?? '',
          ),
        );
      }
    });

    await loadCollection('trainings', trainings, (map) {
      final id = map['id'];
      if (id != null) {
        trainings.add(
          ReportFilterOption(
            value: '$id',
            label: (map['label'] as String?)?.trim() ?? '',
          ),
        );
      }
    });

    await loadCollection('training_versions', trainingVersions, (map) {
      final id = map['id'] as int? ?? 0;
      if (id > 0) {
        trainingVersions.add(
          ReportVersionFilterOption(
            id: id,
            trainingId: map['training_id'] as int? ?? 0,
            versionNumber: map['version_number'] as int? ?? 1,
            title:
                (map['title'] as String?)?.trim() ??
                (map['label'] as String?)?.trim() ??
                '',
          ),
        );
      }
    });

    final options = AssignmentReportFilterOptionsViewData(
      departments: departments,
      jobRoles: jobRoles,
      trainings: trainings,
      trainingVersions: trainingVersions,
      statuses: statuses.isNotEmpty
          ? statuses
          : const [
              ReportFilterOption(value: 'ASSIGNED', label: 'Assigned'),
              ReportFilterOption(value: 'IN_PROGRESS', label: 'In progress'),
              ReportFilterOption(value: 'COMPLETED', label: 'Completed'),
              ReportFilterOption(value: 'CANCELLED', label: 'Cancelled'),
            ],
    );
    if (failures.isNotEmpty) {
      throw FilterOptionsLoadFailure(
        completeOptions: options,
        failures: failures,
        cause: failures.values.first,
      );
    }
    return options;
  }

  Future<AuditLogPageViewData> auditLogs({
    required AuditLogFilterQuery query,
    CancelToken? cancelToken,
  }) {
    if (query.startDate != null && query.endDate != null) {
      final start = DateTime(
        query.startDate!.year,
        query.startDate!.month,
        query.startDate!.day,
      );
      final end = DateTime(
        query.endDate!.year,
        query.endDate!.month,
        query.endDate!.day,
      );
      if (start.isAfter(end)) {
        throw ArgumentError('End date must not precede start date.');
      }
    }

    final additional = <String, dynamic>{};
    if (query.actorId != null && query.actorId! > 0) {
      additional['actor'] = query.actorId;
    }
    if (query.action != null && query.action!.trim().isNotEmpty) {
      additional['action'] = query.action!.trim();
    }
    if (query.targetType != null && query.targetType!.trim().isNotEmpty) {
      additional['target_type'] = query.targetType!.trim();
    }
    if (query.startDate != null) {
      additional['start_date'] =
          '${query.startDate!.year.toString().padLeft(4, '0')}-${query.startDate!.month.toString().padLeft(2, '0')}-${query.startDate!.day.toString().padLeft(2, '0')}';
    }
    if (query.endDate != null) {
      additional['end_date'] =
          '${query.endDate!.year.toString().padLeft(4, '0')}-${query.endDate!.month.toString().padLeft(2, '0')}-${query.endDate!.day.toString().padLeft(2, '0')}';
    }

    return _get(
      'audit-logs/',
      (json) => AuditLogPageViewData.fromJson(
        json,
        page: query.page,
        pageSize: query.pageSize,
      ),
      page: query.page,
      pageSize: query.pageSize,
      additionalQueryParameters: additional.isEmpty ? null : additional,
      cancelToken: cancelToken,
    );
  }

  Future<AuditLogEntryViewData> auditLogDetail(
    int id, {
    CancelToken? cancelToken,
  }) {
    if (id <= 0) throw ArgumentError.value(id, 'id');
    return _get(
      'audit-logs/$id/',
      AuditLogEntryViewData.fromJson,
      cancelToken: cancelToken,
    );
  }

  Future<AuditLogFilterOptionsViewData> auditLogFilterOptions({
    CancelToken? cancelToken,
  }) async {
    final initial = await _get(
      'audit-logs/filters/',
      (json) => json,
      additionalQueryParameters: {'page_size': 100},
      cancelToken: cancelToken,
    );

    final actors = <AuditFilterActorOption>[];
    for (final item in (initial['actors'] as List<dynamic>? ?? const [])) {
      final map = item as Map<String, dynamic>;
      final id = map['id'] as int? ?? 0;
      if (id > 0) {
        actors.add(
          AuditFilterActorOption(
            id: id,
            username: (map['username'] as String?)?.trim() ?? '',
            displayName: (map['display_name'] as String?)?.trim() ?? '',
          ),
        );
      }
    }

    final entityTypes = <AuditFilterEntityOption>[];
    for (final item
        in (initial['entity_types'] as List<dynamic>? ?? const [])) {
      final map = item as Map<String, dynamic>;
      final value = (map['value'] as String?)?.trim() ?? '';
      if (value.isNotEmpty) {
        entityTypes.add(
          AuditFilterEntityOption(
            value: value,
            label: (map['label'] as String?)?.trim() ?? '',
          ),
        );
      }
    }

    try {
      final pagination =
          initial['pagination'] as Map<String, dynamic>? ?? const {};
      final actorMeta = pagination['actors'] as Map<String, dynamic>?;
      final seenIds = actors.map((actor) => actor.id).toSet();
      final expectedCount = actorMeta?['count'] as int? ?? actors.length;
      var next = actorMeta?['next'];
      if (seenIds.length != actors.length || (next != null && actors.isEmpty)) {
        throw _incompleteChoicesError('audit actor options');
      }
      if (next != null) {
        var pageNumber = 2;
        const maxPages = 10;
        final seenContinuations = <Object>{};
        while (next != null && pageNumber <= maxPages) {
          if (!seenContinuations.add(next)) {
            throw _incompleteChoicesError('audit actor options');
          }
          final pageJson = await _get(
            'audit-logs/filters/',
            (json) => json,
            additionalQueryParameters: {
              'kind': 'actors',
              'page': pageNumber,
              'page_size': 100,
            },
            cancelToken: cancelToken,
          );
          final rows = pageJson['actors'] as List<dynamic>? ?? const [];
          if (rows.isEmpty) {
            throw _incompleteChoicesError('audit actor options');
          }
          for (final r in rows) {
            final map = r as Map<String, dynamic>;
            final id = map['id'] as int? ?? 0;
            if (id > 0) {
              if (!seenIds.add(id)) {
                throw _incompleteChoicesError('audit actor options');
              }
              actors.add(
                AuditFilterActorOption(
                  id: id,
                  username: (map['username'] as String?)?.trim() ?? '',
                  displayName: (map['display_name'] as String?)?.trim() ?? '',
                ),
              );
            }
          }
          final pageMeta =
              pageJson['pagination']?['actors'] as Map<String, dynamic>?;
          next = pageMeta?['next'];
          pageNumber++;
        }
      }
      if (next != null || seenIds.length < expectedCount) {
        throw _incompleteChoicesError('audit actor options');
      }
    } catch (error) {
      if (cancelToken?.isCancelled == true) rethrow;
      final apiError = error is ApiError
          ? error
          : apiClient.mapExceptionToApiError(error);
      if (apiError.statusCode == 401 ||
          apiError.statusCode == 403 ||
          apiError.code == 'cancelled') {
        throw apiError;
      }
      throw FilterOptionsLoadFailure(
        completeOptions: AuditLogFilterOptionsViewData(
          entityTypes: entityTypes,
        ),
        failures: {'actors': apiError},
        cause: apiError,
      );
    }

    return AuditLogFilterOptionsViewData(
      actors: actors,
      entityTypes: entityTypes,
    );
  }
}
