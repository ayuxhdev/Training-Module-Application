import 'package:dio/dio.dart';
import '../config/api_config.dart';
import '../errors/api_error.dart';
import '../storage/secure_token_storage.dart';
import 'dio_interceptor.dart';

class ApiClient {
  late final Dio _dio;
  
  ApiClient({
    required SecureTokenStorage tokenStorage,
    Dio? dioOverride,
  }) {
    if (dioOverride != null) {
      _dio = dioOverride;
      final hasAuth = _dio.interceptors.any((i) => i is AuthInterceptor);
      if (!hasAuth) {
        _dio.interceptors.add(AuthInterceptor(tokenStorage: tokenStorage));
      }
    } else {
      _dio = Dio(
        BaseOptions(
          baseUrl: ApiConfig.baseUrl,
          connectTimeout: const Duration(seconds: 10),
          receiveTimeout: const Duration(seconds: 15),
          sendTimeout: const Duration(seconds: 15),
          responseType: ResponseType.json,
        ),
      );
      _dio.interceptors.add(AuthInterceptor(tokenStorage: tokenStorage));
    }
  }

  Dio get dio => _dio;

  ApiError mapExceptionToApiError(dynamic exception) {
    if (exception is DioException) {
      switch (exception.type) {
        case DioExceptionType.connectionTimeout:
        case DioExceptionType.sendTimeout:
        case DioExceptionType.receiveTimeout:
          return ApiError.timeout();
        case DioExceptionType.connectionError:
          return ApiError.networkFailure();
        case DioExceptionType.badResponse:
          final response = exception.response;
          if (response != null && response.data is Map<String, dynamic>) {
            return ApiError.fromBackend(
              response.statusCode ?? 500,
              response.data as Map<String, dynamic>,
            );
          }
          return ApiError(
            message: 'Invalid response from server.',
            statusCode: response?.statusCode,
          );
        default:
          return ApiError.unexpected();
      }
    }
    return ApiError.unexpected();
  }
}

