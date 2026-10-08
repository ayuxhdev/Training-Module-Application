import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:training_app/core/network/dio_client.dart';
import 'package:training_app/core/providers/core_providers.dart';
import 'package:training_app/features/dashboard/domain/models/dashboard_data.dart';

final dashboardRepositoryProvider = Provider<DashboardRepository>((ref) {
  final apiClient = ref.watch(apiClientProvider);
  return DashboardRepository(apiClient: apiClient);
});

class DashboardRepository {
  final ApiClient apiClient;

  DashboardRepository({required this.apiClient});

  Future<DashboardData> getDashboardData() async {
    try {
      final response = await apiClient.dio.get('/dashboard/');
      return DashboardData.fromJson(response.data as Map<String, dynamic>);
    } catch (e) {
      throw apiClient.mapExceptionToApiError(e);
    }
  }
}

