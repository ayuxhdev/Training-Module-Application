import 'package:dio/dio.dart';

import '../errors/api_error.dart';
import '../storage/secure_token_storage.dart';
import 'auth_session.dart';

class AuthInterceptor extends Interceptor {
  final SecureTokenStorage tokenStorage;
  final AuthSession? session;
  final Dio? dio;

  AuthInterceptor({required this.tokenStorage, this.session, this.dio});

  bool _publicAuth(RequestOptions options) =>
      options.path.endsWith('/auth/login/') ||
      options.path.endsWith('/auth/refresh/');

  DioException _failure(
    RequestOptions options,
    Object error, {
    Response? response,
  }) => error is DioException
      ? error
      : DioException(requestOptions: options, response: response, error: error);

  @override
  Future<void> onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    if (_publicAuth(options)) {
      options.headers.remove('Authorization');
      return handler.next(options);
    }
    if (options.extra[AuthSession.bypass] == true) return handler.next(options);
    final owner = session;
    final generation = owner?.generation;
    try {
      final token = owner == null
          ? await tokenStorage.readAccessToken()
          : await owner.accessToken(
              minimumValidity:
                  options.extra[AuthSession.minimumValidityKey] as Duration? ??
                  const Duration(seconds: 60),
            );
      if (options.cancelToken?.cancelError case final cancelled?) {
        throw cancelled;
      }
      if (owner != null &&
          (!owner.canAuthorize || owner.generation != generation)) {
        throw AuthSession.signInRequired();
      }
      options.extra[AuthSession.generationKey] = generation;
      if (token != null && token.isNotEmpty) {
        options.headers['Authorization'] = 'Bearer $token';
      } else {
        options.headers.remove('Authorization');
      }
      handler.next(options);
    } catch (error) {
      handler.reject(_failure(options, error));
    }
  }

  @override
  void onResponse(Response response, ResponseInterceptorHandler handler) {
    final generation = response.requestOptions.extra[AuthSession.generationKey];
    if (generation != null &&
        (generation != session?.generation || session?.canAuthorize != true)) {
      final method = response.requestOptions.method.toUpperCase();
      final isMutation =
          method == 'POST' ||
          method == 'PATCH' ||
          method == 'PUT' ||
          method == 'DELETE';
      if (isMutation) {
        return handler.reject(
          _failure(
            response.requestOptions,
            ApiError(
              message:
                  'Your session changed after sending this request. Your changes may already have been saved. Check the current status before trying again.',
              statusCode: 401,
              code: 'authentication_retry_required',
            ),
            response: response,
          ),
        );
      }
      return handler.reject(
        _failure(response.requestOptions, AuthSession.signInRequired()),
      );
    }
    handler.next(response);
  }

  @override
  Future<void> onError(
    DioException err,
    ErrorInterceptorHandler handler,
  ) async {
    final options = err.requestOptions;
    final owner = session;
    if (owner == null ||
        dio == null ||
        _publicAuth(options) ||
        options.extra[AuthSession.bypass] == true ||
        err.response?.statusCode != 401) {
      return handler.next(err);
    }
    final generation = options.extra[AuthSession.generationKey];
    if (generation != owner.generation) {
      return handler.reject(
        _failure(options, AuthSession.signInRequired(), response: err.response),
      );
    }
    try {
      if (options.extra['authReadRetried'] == true) {
        await owner.rejectCurrent(owner.generation);
        throw AuthSession.signInRequired();
      }
      final header = options.headers['Authorization'] as String?;
      final fresh = await owner.renew(
        rejectedToken: header?.startsWith('Bearer ') == true
            ? header!.substring(7)
            : null,
      );
      if (options.cancelToken?.cancelError case final cancelled?) {
        throw cancelled;
      }
      if (!owner.canAuthorize || generation != owner.generation) {
        throw AuthSession.signInRequired();
      }
      if ((options.method == 'GET' || options.method == 'HEAD') &&
          options.data == null) {
        final response = await dio!.fetch(
          options.copyWith(
            headers: {...options.headers, 'Authorization': 'Bearer $fresh'},
            extra: {...options.extra, 'authReadRetried': true},
          ),
        );
        return handler.resolve(response);
      }
      // Never replay a mutation, especially an already consumed multipart body.
      throw ApiError(
        message:
            'Your sign-in was renewed. Check the current status before trying your action again.',
        statusCode: 401,
        code: 'authentication_retry_required',
      );
    } catch (failure) {
      handler.reject(_failure(options, failure, response: err.response));
    }
  }
}
