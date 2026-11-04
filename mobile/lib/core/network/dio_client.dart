import 'package:dio/dio.dart';

import '../config/api_config.dart';
import '../errors/api_error.dart';
import '../storage/secure_token_storage.dart';
import 'auth_session.dart';
import 'dio_interceptor.dart';

class ApiClient {
  late final Dio _dio;
  late final AuthSession session;

  ApiClient({required SecureTokenStorage tokenStorage, Dio? dioOverride}) {
    _dio =
        dioOverride ??
        Dio(
          BaseOptions(
            baseUrl: ApiConfig.baseUrl,
            followRedirects: false,
            connectTimeout: const Duration(seconds: 10),
            receiveTimeout: const Duration(seconds: 15),
            sendTimeout: const Duration(seconds: 15),
            responseType: ResponseType.json,
          ),
        );
    final existing = _dio.interceptors.whereType<AuthInterceptor>().firstOrNull;
    session =
        existing?.session ?? AuthSession(dio: _dio, storage: tokenStorage);
    if (existing == null) {
      _dio.interceptors.add(
        AuthInterceptor(
          tokenStorage: tokenStorage,
          session: session,
          dio: _dio,
        ),
      );
    }
  }

  Dio get dio => _dio;

  /// Validate live account eligibility before opening/sending a large file.
  Future<void> prepareUpload({CancelToken? cancelToken}) async {
    try {
      await _dio.get(
        '/auth/me/',
        cancelToken: cancelToken,
        options: Options(
          extra: {AuthSession.minimumValidityKey: const Duration(minutes: 12)},
        ),
      );
    } catch (error) {
      if (error is DioException && CancelToken.isCancel(error)) rethrow;
      throw mapExceptionToApiError(error);
    }
  }

  static Options get uploadOptions => Options(
    extra: const {'videoUpload': true},
    sendTimeout: const Duration(minutes: 10),
    receiveTimeout: const Duration(seconds: 90),
  );

  ApiError mapExceptionToApiError(dynamic exception) {
    if (exception is ApiError) return exception;
    if (exception is DioException) {
      if (exception.error is ApiError) return exception.error as ApiError;
      switch (exception.type) {
        case DioExceptionType.connectionTimeout:
        case DioExceptionType.sendTimeout:
        case DioExceptionType.receiveTimeout:
          if (exception.requestOptions.extra['videoUpload'] == true) {
            return ApiError(
              message: 'The video upload timed out. Check the curriculum before retrying; the lesson may have been saved.',
              code: 'timeout',
            );
          }
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
