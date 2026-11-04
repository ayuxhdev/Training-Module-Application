import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:training_app/core/network/dio_client.dart';
import 'package:training_app/core/providers/core_providers.dart';
import 'package:training_app/core/storage/secure_token_storage.dart';
import 'package:training_app/features/auth/domain/models/authenticated_identity.dart';

final authRepositoryProvider = Provider<AuthRepository>((ref) {
  final apiClient = ref.watch(apiClientProvider);
  final tokenStorage = ref.watch(secureTokenStorageProvider);
  return AuthRepository(apiClient: apiClient, tokenStorage: tokenStorage);
});

class AuthRepository {
  final ApiClient apiClient;
  final SecureTokenStorage tokenStorage;

  AuthRepository({required this.apiClient, required this.tokenStorage});

  Future<AuthenticatedIdentity> login(String username, String password) async {
    try {
      await apiClient.session.login(username, password);

      return await getCurrentIdentity();
    } catch (e) {
      throw apiClient.mapExceptionToApiError(e);
    }
  }

  Future<AuthenticatedIdentity> getCurrentIdentity() async {
    try {
      final response = await apiClient.dio.get('/auth/me/');
      return AuthenticatedIdentity.fromJson(
        response.data as Map<String, dynamic>,
      );
    } catch (e) {
      throw apiClient.mapExceptionToApiError(e);
    }
  }

  Future<void> logout() async {
    try {
      await apiClient.session.logout();
    } catch (_) {
      // Offline logout still clears credentials in the session's finally block.
    }
  }

  Future<bool> hasStoredCredentials() async {
    final token = await tokenStorage.readAccessToken();
    if (token != null && token.isNotEmpty) return true;
    final refresh = await tokenStorage.readRefreshToken();
    return refresh != null && refresh.isNotEmpty;
  }
}
