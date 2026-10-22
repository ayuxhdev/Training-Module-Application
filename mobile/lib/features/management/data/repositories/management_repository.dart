import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
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
    CancelToken? cancelToken,
  }) async {
    if (page != null && page <= 0) throw ArgumentError.value(page, 'page');
    try {
      final response = await apiClient.dio.get(
        '/management/$path',
        queryParameters: page == null || page == 1 ? null : {'page': page},
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
    CancelToken? cancelToken,
  }) => _get(
    'employees/',
    (json) => ManagementPage.fromJson(json, DirectoryEmployee.fromJson),
    page: page,
    cancelToken: cancelToken,
  );

  Future<DirectoryEmployee> employee(int id, {CancelToken? cancelToken}) async {
    if (id <= 0) throw ArgumentError.value(id, 'id');
    return _get('employees/$id/', (json) {
      final result = DirectoryEmployee.fromJson(json);
      if (result.id != id) {
        throw const FormatException('Employee identity mismatch.');
      }
      return result;
    }, cancelToken: cancelToken);
  }

  Future<ManagementPage<OrganizationReference>> references(
    ReferenceKind kind, {
    int page = 1,
    CancelToken? cancelToken,
  }) => _get(
    '${kind.path}/',
    (json) => ManagementPage.fromJson(json, OrganizationReference.fromJson),
    page: page,
    cancelToken: cancelToken,
  );
}
