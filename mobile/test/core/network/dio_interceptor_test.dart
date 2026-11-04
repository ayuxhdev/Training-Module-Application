import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:training_app/core/errors/api_error.dart';
import 'package:training_app/core/network/dio_client.dart';
import 'package:training_app/core/network/dio_interceptor.dart';
import 'package:training_app/core/storage/secure_token_storage.dart';

class MockSecureTokenStorage extends Mock implements SecureTokenStorage {}

class MockRequestInterceptorHandler extends Mock
    implements RequestInterceptorHandler {}

String jwt(DateTime expiry, {int user = 1, String tag = 'token'}) {
  String part(Object value) =>
      base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
  final header = part({'alg': 'HS256'});
  final payload = part({
    'exp': expiry.millisecondsSinceEpoch ~/ 1000,
    'user_id': user,
    'tag': tag,
  });
  return '$header.$payload.test';
}

class MemoryTokens implements SecureTokenStorage {
  String? access;
  String? refresh;
  final writes = <String>[];

  @override
  Future<String?> readAccessToken() async => access;

  @override
  Future<String?> readRefreshToken() async => refresh;

  @override
  Future<void> saveAccessToken(String token) async {
    writes.add('access');
    access = token;
  }

  @override
  Future<void> saveRefreshToken(String token) async {
    writes.add('refresh');
    refresh = token;
  }

  @override
  Future<void> deleteTokens() async {
    access = null;
    refresh = null;
  }

  @override
  Future<void> clearAuthenticationState() => deleteTokens();

  @override
  Future<void> markSessionInvalid() async {}

  @override
  Future<void> clearInvalidationMarker() async {}

  @override
  Future<bool> isSessionInvalid() async => false;
}

class AuthAdapter implements HttpClientAdapter {
  final FutureOr<ResponseBody> Function(RequestOptions options) respond;
  AuthAdapter(this.respond);

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    return respond(options);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody reply(Object data, [int status = 200]) => ResponseBody.fromString(
  jsonEncode(data),
  status,
  headers: {
    Headers.contentTypeHeader: [Headers.jsonContentType],
  },
);

ApiClient createTestClient(
  MemoryTokens storage,
  FutureOr<ResponseBody> Function(RequestOptions) respond,
) {
  final dio = Dio(BaseOptions(baseUrl: 'https://example.invalid/api/v1'));
  dio.httpClientAdapter = AuthAdapter(respond);
  return ApiClient(tokenStorage: storage, dioOverride: dio);
}

void main() {
  group('AuthInterceptor unit tests', () {
    late MockSecureTokenStorage mockStorage;
    late MockRequestInterceptorHandler mockHandler;
    late AuthInterceptor interceptor;

    setUp(() {
      mockStorage = MockSecureTokenStorage();
      mockHandler = MockRequestInterceptorHandler();
      interceptor = AuthInterceptor(tokenStorage: mockStorage);
      registerFallbackValue(RequestOptions(path: ''));
    });

    test('Adds Authorization header if token exists', () async {
      when(() => mockStorage.readAccessToken())
          .thenAnswer((_) async => 'test_token');

      final options = RequestOptions(path: '/test');
      await interceptor.onRequest(options, mockHandler);

      expect(options.headers['Authorization'], 'Bearer test_token');
      verify(() => mockHandler.next(options)).called(1);
    });

    test('Does not add Authorization header if token is null', () async {
      when(() => mockStorage.readAccessToken()).thenAnswer((_) async => null);

      final options = RequestOptions(path: '/test');
      await interceptor.onRequest(options, mockHandler);

      expect(options.headers.containsKey('Authorization'), isFalse);
      verify(() => mockHandler.next(options)).called(1);
    });

    test('Public auth endpoints do not have Authorization header', () async {
      when(() => mockStorage.readAccessToken())
          .thenAnswer((_) async => 'test_token');

      final options = RequestOptions(
        path: '/api/v1/auth/login/',
        headers: {'Authorization': 'Bearer test_token'},
      );
      await interceptor.onRequest(options, mockHandler);

      expect(options.headers.containsKey('Authorization'), isFalse);
      verify(() => mockHandler.next(options)).called(1);
    });
  });

  group('AuthInterceptor stale response and session generation handling', () {
    late MemoryTokens storage;

    setUp(() {
      storage = MemoryTokens()
        ..access = jwt(DateTime.now().add(const Duration(minutes: 30)))
        ..refresh = 'parent';
    });

    test('successful stale POST 201 does not expose data and reports uncertain outcome with authentication_retry_required', () async {
      late ApiClient client;
      var posts = 0;
      client = createTestClient(storage, (options) async {
        if (options.path == '/text-lessons/') {
          posts++;
          // Session changes while request is in flight on the server
          await client.session.rejectCurrent(client.session.generation);
          return reply({'id': 101, 'title': 'Created'}, 201);
        }
        return reply({});
      });

      await expectLater(
        client.dio.post('/text-lessons/', data: {'title': 'Lesson'}),
        throwsA(
          isA<DioException>().having(
            (e) => client.mapExceptionToApiError(e),
            'mappedError',
            isA<ApiError>()
                .having(
                  (err) => err.code,
                  'code',
                  'authentication_retry_required',
                )
                .having((err) => err.statusCode, 'statusCode', 401)
                .having(
                  (err) => err.message,
                  'message',
                  contains('may already have been saved'),
                ),
          ),
        ),
      );
      expect(posts, 1);
    });

    test('successful stale PATCH 200 does not expose data and reports uncertain outcome with authentication_retry_required', () async {
      late ApiClient client;
      var patches = 0;
      client = createTestClient(storage, (options) async {
        if (options.path == '/text-lessons/101/') {
          patches++;
          await client.session.rejectCurrent(client.session.generation);
          return reply({'id': 101, 'title': 'Patched'}, 200);
        }
        return reply({});
      });

      await expectLater(
        client.dio.patch('/text-lessons/101/', data: {'title': 'Updated'}),
        throwsA(
          isA<DioException>().having(
            (e) => client.mapExceptionToApiError(e),
            'mappedError',
            isA<ApiError>()
                .having(
                  (err) => err.code,
                  'code',
                  'authentication_retry_required',
                )
                .having((err) => err.statusCode, 'statusCode', 401)
                .having(
                  (err) => err.message,
                  'message',
                  contains('may already have been saved'),
                ),
          ),
        ),
      );
      expect(patches, 1);
    });

    test('successful stale DELETE 204 does not expose data and reports uncertain outcome with authentication_retry_required', () async {
      late ApiClient client;
      var deletes = 0;
      client = createTestClient(storage, (options) async {
        if (options.path == '/text-lessons/101/') {
          deletes++;
          await client.session.rejectCurrent(client.session.generation);
          return reply({}, 204);
        }
        return reply({});
      });

      await expectLater(
        client.dio.delete('/text-lessons/101/'),
        throwsA(
          isA<DioException>().having(
            (e) => client.mapExceptionToApiError(e),
            'mappedError',
            isA<ApiError>()
                .having(
                  (err) => err.code,
                  'code',
                  'authentication_retry_required',
                )
                .having((err) => err.statusCode, 'statusCode', 401)
                .having(
                  (err) => err.message,
                  'message',
                  contains('may already have been saved'),
                ),
          ),
        ),
      );
      expect(deletes, 1);
    });

    test('stale GET 200 is rejected with reauthentication_required', () async {
      late ApiClient client;
      var gets = 0;
      client = createTestClient(storage, (options) async {
        if (options.path == '/records/') {
          gets++;
          await client.session.rejectCurrent(client.session.generation);
          return reply({'sensitive': 'data'}, 200);
        }
        return reply({});
      });

      await expectLater(
        client.dio.get('/records/'),
        throwsA(
          isA<DioException>().having(
            (e) => client.mapExceptionToApiError(e),
            'mappedError',
            isA<ApiError>()
                .having((err) => err.code, 'code', 'reauthentication_required')
                .having((err) => err.statusCode, 'statusCode', 401),
          ),
        ),
      );
      expect(gets, 1);
    });

    test('stale HEAD 200 is rejected with reauthentication_required', () async {
      late ApiClient client;
      var heads = 0;
      client = createTestClient(storage, (options) async {
        if (options.path == '/records/') {
          heads++;
          await client.session.rejectCurrent(client.session.generation);
          return reply({}, 200);
        }
        return reply({});
      });

      await expectLater(
        client.dio.head('/records/'),
        throwsA(
          isA<DioException>().having(
            (e) => client.mapExceptionToApiError(e),
            'mappedError',
            isA<ApiError>()
                .having((err) => err.code, 'code', 'reauthentication_required')
                .having((err) => err.statusCode, 'statusCode', 401),
          ),
        ),
      );
      expect(heads, 1);
    });

    test(
      'normal successful mutation with current session passes through',
      () async {
        final client = createTestClient(storage, (options) {
          if (options.path == '/text-lessons/') {
            return reply({'id': 102, 'title': 'Created'}, 201);
          }
          return reply({});
        });

        final response = await client.dio.post(
          '/text-lessons/',
          data: {'title': 'Lesson'},
        );
        expect(response.statusCode, 201);
        expect((response.data as Map)['id'], 102);
      },
    );

    test('normal successful GET with current session passes through', () async {
      final client = createTestClient(storage, (options) {
        if (options.path == '/records/') {
          return reply({
            'records': [1, 2, 3],
          }, 200);
        }
        return reply({});
      });

      final response = await client.dio.get('/records/');
      expect(response.statusCode, 200);
      expect((response.data as Map)['records'], [1, 2, 3]);
    });

    test(
      'POST 401 refreshes auth but never automatically replays the mutation',
      () async {
        var posts = 0;
        final client = createTestClient(storage, (options) {
          if (options.path == '/auth/refresh/') {
            return reply({
              'access': jwt(DateTime.now().add(const Duration(minutes: 30))),
              'refresh': 'child',
            });
          }
          posts++;
          return reply({
            'detail': 'Token is expired',
            'code': 'token_not_valid',
          }, 401);
        });

        await expectLater(
          client.dio.post('/text-lessons/', data: {'body': 'Keep me'}),
          throwsA(
            isA<DioException>().having(
              (e) => client.mapExceptionToApiError(e).code,
              'code',
              'authentication_retry_required',
            ),
          ),
        );
        expect(posts, 1);
        expect(storage.refresh, 'child');
      },
    );
  });
}
