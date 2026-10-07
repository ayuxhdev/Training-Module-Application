import 'package:dio/dio.dart';
import '../storage/secure_token_storage.dart';

class AuthInterceptor extends Interceptor {
  final SecureTokenStorage tokenStorage;

  AuthInterceptor({required this.tokenStorage});

  @override
  Future<void> onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    // Only attach token if the request requires it. 
    // In our backend, almost all endpoints under /api/v1 require auth,
    // except perhaps login/refresh. The backend will reject if absent.
    final token = await tokenStorage.readAccessToken();

    if (token != null && token.isNotEmpty) {
      options.headers['Authorization'] = 'Bearer $token';
    }

    return handler.next(options);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    // Note: Automatic token refresh logic would go here.
    // For M14 Step 2 foundation, we simply pass the error along.
    // Real refresh logic belongs in a dedicated authentication step later.
    return handler.next(err);
  }
}

