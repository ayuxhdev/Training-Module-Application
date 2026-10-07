import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:training_app/core/network/dio_client.dart';
import 'package:training_app/core/providers/core_providers.dart';
import 'package:training_app/core/storage/secure_token_storage.dart';
import 'package:training_app/features/auth/domain/models/employee.dart';

final authRepositoryProvider = Provider<AuthRepository>((ref) {
  final apiClient = ref.watch(apiClientProvider);
  final tokenStorage = ref.watch(secureTokenStorageProvider);
  return AuthRepository(apiClient: apiClient, tokenStorage: tokenStorage);
});

class AuthRepository {
  final ApiClient apiClient;
  final SecureTokenStorage tokenStorage;

  AuthRepository({
    required this.apiClient,
    required this.tokenStorage,
  });

  Future<Employee> login(String employeeCode, String password) async {
    try {
      final response = await apiClient.dio.post(
        '/auth/login/',
        data: {
          'username': employeeCode, // The backend expects 'username' according to test_auth.py
          'password': password,
        },
      );

      final data = response.data as Map<String, dynamic>;
      final accessToken = data['access'] as String;
      final refreshToken = data['refresh'] as String;

      await tokenStorage.saveAccessToken(accessToken);
      await tokenStorage.saveRefreshToken(refreshToken);

      return await getCurrentEmployee();
    } catch (e) {
      throw apiClient.mapExceptionToApiError(e);
    }
  }

  Future<Employee> getCurrentEmployee() async {
    try {
      final response = await apiClient.dio.get('/auth/me/');
      return Employee.fromJson(response.data as Map<String, dynamic>);
    } catch (e) {
      throw apiClient.mapExceptionToApiError(e);
    }
  }

  Future<void> logout() async {
    try {
      final refreshToken = await tokenStorage.readRefreshToken();
      if (refreshToken != null) {
        await apiClient.dio.post(
          '/auth/logout/',
          data: {'refresh': refreshToken},
        );
      }
    } catch (_) {
      // Logout API failure should still clear local credentials silently
    } finally {
      await tokenStorage.clearAuthenticationState();
    }
  }

  Future<bool> hasStoredCredentials() async {
    final token = await tokenStorage.readAccessToken();
    return token != null && token.isNotEmpty;
  }
}
