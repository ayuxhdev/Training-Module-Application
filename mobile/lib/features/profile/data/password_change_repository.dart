import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:training_app/core/network/dio_client.dart';
import 'package:training_app/core/providers/core_providers.dart';

final passwordChangeRepositoryProvider = Provider<PasswordChangeRepository>(
  (ref) => PasswordChangeRepository(ref.watch(apiClientProvider)),
);

class PasswordChangeRepository {
  final ApiClient _client;

  PasswordChangeRepository(this._client);

  Future<void> changePassword({
    required String currentPassword,
    required String newPassword,
    required String confirmation,
    CancelToken? cancelToken,
  }) async {
    try {
      // The existing auth interceptor renews credentials but never replays POST.
      await _client.dio.post<void>(
        '/auth/password-change/',
        data: {
          'current_password': currentPassword,
          'new_password': newPassword,
          'confirm_password': confirmation,
        },
        cancelToken: cancelToken,
      );
    } catch (error) {
      if (error is DioException && CancelToken.isCancel(error)) rethrow;
      throw _client.mapExceptionToApiError(error);
    }
  }
}
