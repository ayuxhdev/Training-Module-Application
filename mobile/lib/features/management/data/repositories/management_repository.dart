import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:training_app/core/errors/api_error.dart';
import 'package:training_app/core/network/dio_client.dart';
import 'package:training_app/core/providers/core_providers.dart';
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
      (json) => ManagementPage.fromJson(
        json,
        EmployeeAssignmentSummary.fromJson,
      ),
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
      (json) => ManagementPage.fromJson(
        json,
        AssignableTrainingVersion.fromJson,
      ),
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
