import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:training_app/core/network/dio_client.dart';
import 'package:training_app/core/errors/api_error.dart';
import 'package:training_app/features/management/data/repositories/management_repository.dart';
import 'package:training_app/features/management/data/services/video_file_picker.dart';

import '../../features/management/management_fixtures.dart';

import 'package:training_app/core/storage/secure_token_storage.dart';

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
  bool sessionInvalid = false;
  final writes = <String>[];
  bool failAccessWrites = false;
  bool failClear = false;
  bool failMarkerWrites = false;
  bool failMarkerReads = false;
  bool failMarkerClears = false;

  @override
  Future<String?> readAccessToken() async => sessionInvalid ? null : access;

  @override
  Future<String?> readRefreshToken() async => sessionInvalid ? null : refresh;

  @override
  Future<void> saveAccessToken(String token) async {
    writes.add('access');
    if (failAccessWrites) throw StateError('Test secure-storage write failure');
    access = token;
  }

  @override
  Future<void> saveRefreshToken(String token) async {
    writes.add('refresh');
    refresh = token;
  }

  @override
  Future<void> deleteTokens() async {
    if (failClear) throw StateError('Test secure-storage clear failure');
    access = null;
    refresh = null;
  }

  @override
  Future<void> clearAuthenticationState() async {
    await deleteTokens();
  }

  @override
  Future<void> markSessionInvalid() async {
    if (failMarkerWrites) throw StateError('Test marker write failure');
    sessionInvalid = true;
  }

  @override
  Future<void> clearInvalidationMarker() async {
    if (failMarkerClears) throw StateError('Test marker clear failure');
    sessionInvalid = false;
  }

  @override
  Future<bool> isSessionInvalid() async {
    if (failMarkerReads) throw StateError('Test marker read failure');
    return sessionInvalid;
  }
}

class AuthAdapter implements HttpClientAdapter {
  final FutureOr<ResponseBody> Function(RequestOptions options) respond;
  final Future<void> Function(Stream<Uint8List>?)? consume;
  AuthAdapter(this.respond, {this.consume});
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    await consume?.call(requestStream);
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

ApiClient clientFor(
  MemoryTokens storage,
  FutureOr<ResponseBody> Function(RequestOptions) respond,
) {
  final dio = Dio(BaseOptions(baseUrl: 'https://example.invalid/api/v1'));
  dio.httpClientAdapter = AuthAdapter(respond);
  return ApiClient(tokenStorage: storage, dioOverride: dio);
}

void main() {
  test(
    'expired access is renewed before a lesson POST, exactly once',
    () async {
      final now = DateTime.now().toUtc();
      final old = jwt(now.subtract(const Duration(minutes: 1)));
      final fresh = jwt(now.add(const Duration(minutes: 30)), tag: 'new');
      final storage = MemoryTokens()
        ..access = old
        ..refresh = 'parent';
      var refreshes = 0;
      var posts = 0;
      final dio = Dio(BaseOptions(baseUrl: 'https://example.invalid/api/v1'));
      dio.httpClientAdapter = AuthAdapter((options) {
        if (options.path == '/auth/refresh/') {
          refreshes++;
          return reply({'access': fresh, 'refresh': 'child'});
        }
        posts++;
        return options.headers['Authorization'] == 'Bearer $fresh'
            ? reply({'id': 1}, 201)
            : reply({
                'code': 'token_not_valid',
                'detail': 'Token is expired',
              }, 401);
      });
      final client = ApiClient(tokenStorage: storage, dioOverride: dio);
      final result = await client.dio.post(
        '/text-lessons/',
        data: {'title': 'Draft'},
      );
      expect(result.statusCode, 201);
      expect(refreshes, 1);
      expect(posts, 1);
      expect(storage.refresh, 'child');
      expect(storage.writes, ['refresh', 'access']);
    },
  );

  test('simultaneous expired requests share one refresh rotation', () async {
    final now = DateTime.now();
    final storage = MemoryTokens()
      ..access = jwt(now.subtract(const Duration(seconds: 1)))
      ..refresh = 'parent';
    final started = Completer<void>();
    final release = Completer<void>();
    var refreshes = 0;
    var reads = 0;
    final client = clientFor(storage, (options) async {
      if (options.path == '/auth/refresh/') {
        refreshes++;
        started.complete();
        await release.future;
        return reply({
          'access': jwt(now.add(const Duration(minutes: 30))),
          'refresh': 'child',
        });
      }
      reads++;
      return reply({'ok': true});
    });
    final requests = Future.wait(
      List.generate(8, (_) => client.dio.get('/records/')),
    );
    await started.future;
    expect(refreshes, 1);
    expect(reads, 0);
    release.complete();
    await requests;
    expect(refreshes, 1);
    expect(reads, 8);
  });

  test('access within the refresh margin is renewed before dispatch', () async {
    final storage = MemoryTokens()
      ..access = jwt(DateTime.now().add(const Duration(seconds: 30)))
      ..refresh = 'parent';
    var refreshes = 0;
    final client = clientFor(storage, (options) {
      if (options.path == '/auth/refresh/') {
        refreshes++;
        return reply({
          'access': jwt(DateTime.now().add(const Duration(minutes: 30))),
          'refresh': 'child',
        });
      }
      return reply({});
    });
    await client.dio.get('/records/');
    expect(refreshes, 1);
  });

  test('unexpected GET 401 refreshes and retries the read once', () async {
    final storage = MemoryTokens()
      ..access = jwt(DateTime.now().add(const Duration(minutes: 20)))
      ..refresh = 'parent';
    var reads = 0;
    var refreshes = 0;
    final client = clientFor(storage, (options) {
      if (options.path == '/auth/refresh/') {
        refreshes++;
        return reply({
          'access': jwt(
            DateTime.now().add(const Duration(minutes: 30)),
            tag: 'new',
          ),
          'refresh': 'child',
        });
      }
      reads++;
      return reads == 1
          ? reply({'code': 'token_not_valid'}, 401)
          : reply({'ok': true});
    });
    expect((await client.dio.get('/records/')).statusCode, 200);
    expect(reads, 2);
    expect(refreshes, 1);
  });

  test(
    'late parent 401 uses current child without a second rotation',
    () async {
      final old = jwt(DateTime.now().add(const Duration(minutes: 20)));
      final storage = MemoryTokens()
        ..access = old
        ..refresh = 'parent';
      final lateStarted = Completer<void>();
      final late = Completer<ResponseBody>();
      var refreshes = 0;
      final client = clientFor(storage, (options) {
        if (options.path == '/auth/refresh/') {
          refreshes++;
          return reply({
            'access': jwt(
              DateTime.now().add(const Duration(minutes: 30)),
              tag: 'new',
            ),
            'refresh': 'child',
          });
        }
        if (options.headers['Authorization'] == 'Bearer $old') {
          if (options.path == '/late/') {
            lateStarted.complete();
            return late.future;
          }
          return reply({}, 401);
        }
        return reply({});
      });
      final pending = client.dio.get('/late/');
      await lateStarted.future;
      await client.dio.get('/first/');
      late.complete(reply({}, 401));
      await pending;
      expect(refreshes, 1);
      expect(storage.refresh, 'child');
    },
  );

  test('POST 401 renews sign in but never replays the mutation', () async {
    final storage = MemoryTokens()
      ..access = jwt(DateTime.now().add(const Duration(minutes: 20)))
      ..refresh = 'parent';
    var posts = 0;
    final client = clientFor(storage, (options) {
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
          'recovery',
          'authentication_retry_required',
        ),
      ),
    );
    expect(posts, 1);
    expect(storage.refresh, 'child');
  });

  test('permission denial does not refresh or retry', () async {
    final storage = MemoryTokens()
      ..access = jwt(DateTime.now().add(const Duration(minutes: 20)))
      ..refresh = 'parent';
    var requests = 0;
    final client = clientFor(storage, (_) {
      requests++;
      return reply({}, 403);
    });
    await expectLater(
      client.dio.post('/text-lessons/'),
      throwsA(isA<DioException>()),
    );
    expect(requests, 1);
    expect(storage.refresh, 'parent');
  });

  test(
    'denied refresh clears credentials and prevents a lesson POST',
    () async {
      final storage = MemoryTokens()
        ..access = jwt(DateTime.now().subtract(const Duration(minutes: 1)))
        ..refresh = 'revoked';
      var posts = 0;
      final client = clientFor(storage, (options) {
        if (options.path == '/auth/refresh/') {
          return reply({'detail': 'Token is blacklisted'}, 401);
        }
        posts++;
        return reply({});
      });
      await expectLater(
        client.dio.post('/text-lessons/'),
        throwsA(
          isA<DioException>().having(
            (e) => client.mapExceptionToApiError(e).code,
            'recovery',
            'reauthentication_required',
          ),
        ),
      );
      expect(storage.access, isNull);
      expect(storage.refresh, isNull);
      expect(posts, 0);
    },
  );

  test(
    'offline refresh preserves credentials and does not submit a mutation',
    () async {
      final storage = MemoryTokens()
        ..access = jwt(DateTime.now().subtract(const Duration(seconds: 1)))
        ..refresh = 'parent';
      var requests = 0;
      final client = clientFor(storage, (options) {
        requests++;
        throw DioException(
          requestOptions: options,
          type: DioExceptionType.connectionError,
        );
      });
      await expectLater(
        client.dio.post('/text-lessons/'),
        throwsA(isA<DioException>()),
      );
      expect(requests, 1);
      expect(storage.refresh, 'parent');
      expect(storage.access, isNotNull);
    },
  );

  test('app restart uses the persisted rotated refresh, including refresh-only recovery', () async {
    final storage = MemoryTokens()..refresh = 'parent';
    final parents = <String>[];
    FutureOr<ResponseBody> respond(RequestOptions options) {
      if (options.path == '/auth/refresh/') {
        parents.add((options.data as Map)['refresh'] as String);
        return reply({
          'access': jwt(DateTime.now().add(const Duration(minutes: 30))),
          'refresh': 'child-${parents.length}',
        });
      }
      return reply({});
    }

    await clientFor(storage, respond).dio.get('/records/');
    expect(storage.refresh, 'child-1');
    storage.access = jwt(DateTime.now().subtract(const Duration(seconds: 1)));
    await clientFor(storage, respond).dio.get('/records/');
    expect(parents, ['parent', 'child-1']);
    expect(storage.refresh, 'child-2');
  });

  test(
    'logout waits for rotation, revokes the child and cannot restore tokens',
    () async {
      final storage = MemoryTokens()
        ..access = jwt(DateTime.now().subtract(const Duration(seconds: 1)))
        ..refresh = 'parent';
      final started = Completer<void>();
      final release = Completer<void>();
      String? revoked;
      final client = clientFor(storage, (options) async {
        if (options.path == '/auth/refresh/') {
          started.complete();
          await release.future;
          return reply({
            'access': jwt(DateTime.now().add(const Duration(minutes: 30))),
            'refresh': 'child',
          });
        }
        if (options.path == '/auth/logout/') {
          revoked = (options.data as Map)['refresh'] as String;
          return reply({}, 204);
        }
        fail('Protected request must not be dispatched after logout begins.');
      });
      final read = client.dio.get('/records/');
      final rejected = expectLater(read, throwsA(isA<DioException>()));
      await started.future;
      final logout = client.session.logout();
      release.complete();
      await Future.wait([logout, rejected]);
      expect(revoked, 'child');
      expect(storage.access, isNull);
      expect(storage.refresh, isNull);
    },
  );

  test(
    'login serializes behind refresh and isolates old account responses',
    () async {
      final storage = MemoryTokens()
        ..access = jwt(DateTime.now().subtract(const Duration(seconds: 1)))
        ..refresh = 'parent';
      final started = Completer<void>();
      final release = Completer<void>();
      final nextAccess = jwt(
        DateTime.now().add(const Duration(minutes: 30)),
        user: 2,
      );
      final client = clientFor(storage, (options) async {
        if (options.path == '/auth/refresh/') {
          started.complete();
          await release.future;
          return reply({
            'access': jwt(DateTime.now().add(const Duration(minutes: 30))),
            'refresh': 'old-child',
          });
        }
        if (options.path == '/auth/login/') {
          return reply({'access': nextAccess, 'refresh': 'next-parent'});
        }
        fail('Old account request must not reach the adapter.');
      });
      final oldRequest = client.dio.get('/records/');
      final rejected = expectLater(oldRequest, throwsA(isA<DioException>()));
      await started.future;
      final login = client.session.login('next', 'test-only-password');
      release.complete();
      await Future.wait([login, rejected]);
      expect(storage.access, nextAccess);
      expect(storage.refresh, 'next-parent');
    },
  );

  test(
    'cancellation while waiting for refresh never dispatches the POST',
    () async {
      final storage = MemoryTokens()
        ..access = jwt(DateTime.now().subtract(const Duration(seconds: 1)))
        ..refresh = 'parent';
      final started = Completer<void>();
      final release = Completer<void>();
      var posts = 0;
      final client = clientFor(storage, (options) async {
        if (options.path == '/auth/refresh/') {
          started.complete();
          await release.future;
          return reply({
            'access': jwt(DateTime.now().add(const Duration(minutes: 30))),
            'refresh': 'child',
          });
        }
        posts++;
        return reply({});
      });
      final cancel = CancelToken();
      final request = client.dio.post('/text-lessons/', cancelToken: cancel);
      final rejected = expectLater(
        request,
        throwsA(
          isA<DioException>().having(
            (e) => e.type,
            'cancel',
            DioExceptionType.cancel,
          ),
        ),
      );
      await started.future;
      cancel.cancel();
      release.complete();
      await rejected;
      expect(posts, 0);
    },
  );

  test('a second GET 401 ends recovery without a retry loop', () async {
    final storage = MemoryTokens()
      ..access = jwt(DateTime.now().add(const Duration(minutes: 20)))
      ..refresh = 'parent';
    var refreshes = 0;
    var reads = 0;
    final client = clientFor(storage, (options) {
      if (options.path == '/auth/refresh/') {
        refreshes++;
        return reply({
          'access': jwt(DateTime.now().add(const Duration(minutes: 30))),
          'refresh': 'child',
        });
      }
      reads++;
      return reply({}, 401);
    });
    await expectLater(
      client.dio.get('/records/'),
      throwsA(isA<DioException>()),
    );
    expect(reads, 2);
    expect(refreshes, 1);
    expect(storage.refresh, isNull);
  });

  test('refresh cannot install another account token', () async {
    final storage = MemoryTokens()
      ..access = jwt(DateTime.now().subtract(const Duration(seconds: 1)))
      ..refresh = 'parent';
    final client = clientFor(
      storage,
      (_) => reply({
        'access': jwt(DateTime.now().add(const Duration(minutes: 30)), user: 2),
        'refresh': 'foreign',
      }),
    );
    await expectLater(
      client.dio.get('/records/'),
      throwsA(isA<DioException>()),
    );
    expect(storage.access, isNull);
    expect(storage.refresh, isNull);
  });

  test(
    'malformed rotation fails closed without dispatching a mutation',
    () async {
      final storage = MemoryTokens()
        ..access = jwt(DateTime.now().subtract(const Duration(seconds: 1)))
        ..refresh = 'parent';
      var calls = 0;
      final client = clientFor(storage, (_) {
        calls++;
        return reply({'access': 'missing-refresh'});
      });
      await expectLater(
        client.dio.post('/text-lessons/'),
        throwsA(isA<DioException>()),
      );
      expect(calls, 1);
      expect(storage.access, isNull);
      expect(storage.refresh, isNull);
    },
  );

  test(
    'upload preflight renews early and streams 45 MB once with upload timeouts',
    () async {
      final storage = MemoryTokens()
        ..access = jwt(DateTime.now().add(const Duration(minutes: 2)))
        ..refresh = 'parent';
      final order = <String>[];
      var bytes = 0;
      var posts = 0;
      final fresh = jwt(
        DateTime.now().add(const Duration(minutes: 30)),
        tag: 'fresh',
      );
      final dio = Dio(
        BaseOptions(
          baseUrl: 'https://example.invalid/api/v1',
          sendTimeout: const Duration(seconds: 15),
        ),
      );
      dio.httpClientAdapter = AuthAdapter(
        (options) {
          if (options.path == '/auth/refresh/') {
            order.add('refresh');
            return reply({'access': fresh, 'refresh': 'child'});
          }
          if (options.path == '/auth/me/') {
            order.add('validate');
            return reply({
              'user': {'id': 1},
            });
          }
          posts++;
          expect(options.headers['Authorization'], 'Bearer $fresh');
          expect(options.sendTimeout, const Duration(minutes: 10));
          expect(options.receiveTimeout, const Duration(seconds: 90));
          return reply(managedVideoLessonDetailJson(), 201);
        },
        consume: (stream) async {
          if (stream != null) {
            await for (final chunk in stream) {
              bytes += chunk.length;
            }
          }
        },
      );
      final client = ApiClient(tokenStorage: storage, dioOverride: dio);
      final file = SelectedVideoFile(
        path: '/unused/test.mp4',
        name: 'test.mp4',
        sizeInBytes: 45 * 1024 * 1024,
        multipartFileFactory: () {
          order.add('open-file');
          return MultipartFile.fromStream(
            () => Stream.fromIterable(List.filled(720, Uint8List(64 * 1024))),
            45 * 1024 * 1024,
            filename: 'test.mp4',
          );
        },
      );
      await ManagementRepository(
        client,
      ).createVideoLesson(20, 51, title: 'Video', position: 1, videoFile: file);
      expect(order, ['refresh', 'validate', 'open-file']);
      expect(posts, 1);
      expect(bytes, greaterThan(45 * 1024 * 1024));
      expect(dio.options.sendTimeout, const Duration(seconds: 15));
    },
  );

  test(
    'failed live upload validation never opens the file or sends a POST',
    () async {
      final storage = MemoryTokens()
        ..access = jwt(DateTime.now().add(const Duration(minutes: 30)))
        ..refresh = 'parent';
      var opened = false;
      var posts = 0;
      final client = clientFor(storage, (options) {
        if (options.path == '/auth/me/') return reply({}, 401);
        if (options.path == '/auth/refresh/') return reply({}, 401);
        posts++;
        return reply({});
      });
      final file = SelectedVideoFile(
        path: '/unused/test.mp4',
        name: 'test.mp4',
        sizeInBytes: 1,
        multipartFileFactory: () {
          opened = true;
          return MultipartFile.fromBytes([1]);
        },
      );
      await expectLater(
        ManagementRepository(client).createVideoLesson(
          20,
          51,
          title: 'Video',
          position: 1,
          videoFile: file,
        ),
        throwsA(
          isA<ApiError>().having(
            (e) => e.code,
            'recovery',
            'reauthentication_required',
          ),
        ),
      );
      expect(opened, isFalse);
      expect(posts, 0);
    },
  );

  test(
    'replacement upload validates first and never replays a rejected PATCH',
    () async {
      final storage = MemoryTokens()
        ..access = jwt(DateTime.now().add(const Duration(minutes: 30)))
        ..refresh = 'parent';
      final order = <String>[];
      var patches = 0;
      final client = clientFor(storage, (options) {
        if (options.path == '/auth/me/') {
          order.add('validate');
          return reply({});
        }
        if (options.path == '/auth/refresh/') {
          return reply({
            'access': jwt(
              DateTime.now().add(const Duration(minutes: 30)),
              tag: 'new',
            ),
            'refresh': 'child',
          });
        }
        patches++;
        expect(options.method, 'PATCH');
        return reply({}, 401);
      });
      final file = SelectedVideoFile(
        path: '/unused/test.mp4',
        name: 'test.mp4',
        sizeInBytes: 1,
        multipartFileFactory: () {
          order.add('open-file');
          return MultipartFile.fromBytes([1]);
        },
      );
      await expectLater(
        ManagementRepository(client)
            .updateVideoLesson(20, 51, 94, videoFile: file),
        throwsA(
          isA<ApiError>().having(
            (e) => e.code,
            'recovery',
            'authentication_retry_required',
          ),
        ),
      );
      expect(order, ['validate', 'open-file']);
      expect(patches, 1);
    },
  );

  test('upload transport timeout is reported without resubmission', () async {
    final storage = MemoryTokens()
      ..access = jwt(DateTime.now().add(const Duration(minutes: 30)))
      ..refresh = 'parent';
    var posts = 0;
    final client = clientFor(storage, (options) {
      if (options.path == '/auth/me/') return reply({});
      posts++;
      throw DioException(
        requestOptions: options,
        type: DioExceptionType.sendTimeout,
      );
    });
    final file = SelectedVideoFile(
      path: '/unused/test.mp4',
      name: 'test.mp4',
      sizeInBytes: 1,
      multipartFileFactory: () => MultipartFile.fromBytes([1]),
    );
    await expectLater(
      ManagementRepository(
        client,
      ).createVideoLesson(20, 51, title: 'Video', position: 1, videoFile: file),
      throwsA(
        isA<ApiError>()
            .having((e) => e.code, 'code', 'timeout')
            .having(
              (e) => e.message,
              'uncertain outcome',
              contains('Check the curriculum before retrying'),
            ),
      ),
    );
    expect(posts, 1);
    expect(storage.refresh, 'parent');
  });

  test(
    'metadata-only video edit retains ordinary timeout and no upload probe',
    () async {
      final storage = MemoryTokens()
        ..access = jwt(DateTime.now().add(const Duration(minutes: 30)))
        ..refresh = 'parent';
      final paths = <String>[];
      final client = clientFor(storage, (options) {
        paths.add(options.path);
        expect(options.data, {'title': 'Updated'});
        return reply(managedVideoLessonDetailJson());
      });
      await ManagementRepository(client)
          .updateVideoLesson(20, 51, 94, title: 'Updated');
      expect(paths, ['/management/versions/20/modules/51/video-lessons/94/']);
    },
  );

  test('failed rotated-token persistence fails closed instead of using stale credentials', () async {
    final storage = MemoryTokens()
      ..access = jwt(DateTime.now().subtract(const Duration(seconds: 1)))
      ..refresh = 'parent'
      ..failAccessWrites = true;
    var calls = 0;
    final client = clientFor(storage, (_) {
      calls++;
      return reply({
        'access': jwt(DateTime.now().add(const Duration(minutes: 30))),
        'refresh': 'child',
      });
    });
    await expectLater(
      client.dio.post('/text-lessons/'),
      throwsA(isA<DioException>()),
    );
    expect(storage.writes, ['refresh', 'access']);
    expect(storage.access, isNull);
    expect(storage.refresh, isNull);
    expect(calls, 1);
  });

  test(
    'account switch during upload validation prevents opening the old file',
    () async {
      final storage = MemoryTokens()
        ..access = jwt(DateTime.now().add(const Duration(minutes: 30)))
        ..refresh = 'parent';
      final checking = Completer<void>();
      final release = Completer<ResponseBody>();
      var opened = false;
      final client = clientFor(storage, (options) {
        if (options.path == '/auth/me/') {
          checking.complete();
          return release.future;
        }
        if (options.path == '/auth/login/') {
          return reply({
            'access': jwt(
              DateTime.now().add(const Duration(minutes: 30)),
              user: 2,
            ),
            'refresh': 'next-account',
          });
        }
        fail('The old upload must never be sent.');
      });
      final file = SelectedVideoFile(
        path: '/unused/test.mp4',
        name: 'test.mp4',
        sizeInBytes: 1,
        multipartFileFactory: () {
          opened = true;
          return MultipartFile.fromBytes([1]);
        },
      );
      final request = ManagementRepository(client).createVideoLesson(
        20,
        51,
        title: 'Old account',
        position: 1,
        videoFile: file,
      );
      final rejected = expectLater(request, throwsA(isA<ApiError>()));
      await checking.future;
      await client.session.login('next', 'test-only-password');
      release.complete(
        reply({
          'user': {'id': 1},
        }),
      );
      await rejected;
      expect(opened, isFalse);
      expect(storage.refresh, 'next-account');
    },
  );

  test('failed account switch (401) clears previous credentials and prevents session restoration after restart', () async {
    final oldAccess = jwt(
      DateTime.now().add(const Duration(minutes: 30)),
      user: 1,
    );
    final storage = MemoryTokens()
      ..access = oldAccess
      ..refresh = 'account-a-refresh';
    final client = clientFor(storage, (options) {
      if (options.path == '/auth/login/') {
        return reply({'detail': 'Invalid credentials'}, 401);
      }
      return reply({});
    });

    await expectLater(
      client.session.login('account-b', 'wrong-password'),
      throwsA(isA<DioException>()),
    );

    // Current session in memory is invalidated and cannot authorize
    expect(client.session.canAuthorize, isFalse);
    await expectLater(
      client.session.accessToken(),
      throwsA(
        isA<ApiError>().having(
          (e) => e.code,
          'recovery',
          'reauthentication_required',
        ),
      ),
    );

    // Storage is cleared
    expect(storage.access, isNull);
    expect(storage.refresh, isNull);

    // App restart with the same storage cannot restore Account A
    final restartedClient = clientFor(storage, (_) => reply({}));
    expect(await storage.readAccessToken(), isNull);
    expect(await storage.readRefreshToken(), isNull);
    await expectLater(
      restartedClient.session.accessToken(),
      throwsA(
        isA<ApiError>().having(
          (e) => e.code,
          'recovery',
          'reauthentication_required',
        ),
      ),
    );
  });

  test('failed account switch (network error) clears previous credentials and prevents session restoration after restart', () async {
    final oldAccess = jwt(
      DateTime.now().add(const Duration(minutes: 30)),
      user: 1,
    );
    final storage = MemoryTokens()
      ..access = oldAccess
      ..refresh = 'account-a-refresh';
    final client = clientFor(storage, (options) {
      if (options.path == '/auth/login/') {
        throw DioException(
          requestOptions: options,
          type: DioExceptionType.connectionError,
        );
      }
      return reply({});
    });

    await expectLater(
      client.session.login('account-b', 'wrong-password'),
      throwsA(isA<DioException>()),
    );

    expect(client.session.canAuthorize, isFalse);
    await expectLater(
      client.session.accessToken(),
      throwsA(
        isA<ApiError>().having(
          (e) => e.code,
          'recovery',
          'reauthentication_required',
        ),
      ),
    );

    expect(storage.access, isNull);
    expect(storage.refresh, isNull);

    final restartedClient = clientFor(storage, (_) => reply({}));
    expect(await storage.readAccessToken(), isNull);
    expect(await storage.readRefreshToken(), isNull);
    await expectLater(
      restartedClient.session.accessToken(),
      throwsA(
        isA<ApiError>().having(
          (e) => e.code,
          'recovery',
          'reauthentication_required',
        ),
      ),
    );
  });

  test('initial login failure with empty storage fails cleanly leaving storage empty', () async {
    final storage = MemoryTokens();
    final client = clientFor(storage, (options) {
      if (options.path == '/auth/login/') {
        return reply({'detail': 'Invalid credentials'}, 401);
      }
      return reply({});
    });

    await expectLater(
      client.session.login('new-user', 'bad-password'),
      throwsA(isA<DioException>()),
    );

    expect(client.session.canAuthorize, isFalse);
    expect(storage.access, isNull);
    expect(storage.refresh, isNull);

    final restartedClient = clientFor(storage, (_) => reply({}));
    expect(await storage.readAccessToken(), isNull);
    expect(await storage.readRefreshToken(), isNull);
    await expectLater(
      restartedClient.session.accessToken(),
      throwsA(
        isA<ApiError>().having(
          (e) => e.code,
          'recovery',
          'reauthentication_required',
        ),
      ),
    );
  });

  test('failed account switch with token cleanup failure leaves durable marker and prevents session restoration after restart', () async {
    final oldAccess = jwt(
      DateTime.now().add(const Duration(minutes: 30)),
      user: 1,
    );
    final storage = MemoryTokens()
      ..access = oldAccess
      ..refresh = 'account-a-refresh'
      ..failClear = true;
    final client = clientFor(storage, (options) {
      if (options.path == '/auth/login/') {
        return reply({'detail': 'Invalid credentials'}, 401);
      }
      return reply({});
    });

    await expectLater(
      client.session.login('account-b', 'wrong-password'),
      throwsA(isA<StateError>()),
    );

    // In-memory session fails closed
    expect(client.session.canAuthorize, isFalse);
    await expectLater(
      client.session.accessToken(),
      throwsA(
        isA<ApiError>().having(
          (e) => e.code,
          'recovery',
          'reauthentication_required',
        ),
      ),
    );

    // Tokens were physically left in storage due to deletion failure
    expect(storage.access, oldAccess);
    expect(storage.refresh, 'account-a-refresh');

    // But durable invalidation marker is set
    expect(await storage.isSessionInvalid(), isTrue);

    // App restart with the SAME storage cannot restore Account A
    final restartedClient = clientFor(storage, (_) => reply({}));
    expect(await storage.readAccessToken(), isNull);
    expect(await storage.readRefreshToken(), isNull);
    await expectLater(
      restartedClient.session.accessToken(),
      throwsA(
        isA<ApiError>().having(
          (e) => e.code,
          'recovery',
          'reauthentication_required',
        ),
      ),
    );
  });

  test('failed account switch with network error and cleanup failure prevents session restoration after restart', () async {
    final oldAccess = jwt(
      DateTime.now().add(const Duration(minutes: 30)),
      user: 1,
    );
    final storage = MemoryTokens()
      ..access = oldAccess
      ..refresh = 'account-a-refresh'
      ..failClear = true;
    final client = clientFor(storage, (options) {
      if (options.path == '/auth/login/') {
        throw DioException(
          requestOptions: options,
          type: DioExceptionType.connectionError,
        );
      }
      return reply({});
    });

    await expectLater(
      client.session.login('account-b', 'wrong-password'),
      throwsA(isA<StateError>()),
    );

    expect(storage.access, oldAccess);
    expect(await storage.isSessionInvalid(), isTrue);

    final restartedClient = clientFor(storage, (_) => reply({}));
    expect(await storage.readAccessToken(), isNull);
    expect(await storage.readRefreshToken(), isNull);
    await expectLater(
      restartedClient.session.accessToken(),
      throwsA(
        isA<ApiError>().having(
          (e) => e.code,
          'recovery',
          'reauthentication_required',
        ),
      ),
    );
  });

  test('marker read failure never authorizes stored credentials', () async {
    final storage = MemoryTokens()
      ..access = jwt(DateTime.now().add(const Duration(minutes: 30)), user: 1)
      ..refresh = 'stored-refresh'
      ..failMarkerReads = true;
    final client = clientFor(storage, (_) => reply({}));

    await expectLater(client.session.accessToken(), throwsA(isA<StateError>()));
  });

  test('marker clearing failure keeps the new session invalidated', () async {
    final storage = MemoryTokens()
      ..failMarkerClears = true
      ..failClear = false;
    final newAccess = jwt(
      DateTime.now().add(const Duration(minutes: 30)),
      user: 2,
    );
    final client = clientFor(storage, (options) {
      if (options.path == '/auth/login/') {
        return reply({'access': newAccess, 'refresh': 'new-refresh'});
      }
      return reply({});
    });

    await expectLater(
      client.session.login('account-b', 'password'),
      throwsA(isA<StateError>()),
    );

    expect(await storage.isSessionInvalid(), isTrue);
    expect(storage.access, isNull);
    expect(storage.refresh, isNull);
    await expectLater(
      client.session.accessToken(),
      throwsA(
        isA<ApiError>().having(
          (e) => e.code,
          'recovery',
          'reauthentication_required',
        ),
      ),
    );
  });

  test('marker persistence failure aborts switch before making authentication changes', () async {
    final oldAccess = jwt(
      DateTime.now().add(const Duration(minutes: 30)),
      user: 1,
    );
    final storage = MemoryTokens()
      ..access = oldAccess
      ..refresh = 'account-a-refresh'
      ..failMarkerWrites = true;
    var loginRequests = 0;
    final client = clientFor(storage, (options) {
      if (options.path == '/auth/login/') {
        loginRequests++;
        return reply({'access': 'new-token', 'refresh': 'new-refresh'});
      }
      return reply({});
    });

    await expectLater(
      client.session.login('account-b', 'password'),
      throwsA(isA<StateError>()),
    );

    // Network request must NOT be sent if marker cannot be persisted
    expect(loginRequests, 0);

    // In-memory session fails closed
    expect(client.session.canAuthorize, isFalse);
    await expectLater(
      client.session.accessToken(),
      throwsA(
        isA<ApiError>().having(
          (e) => e.code,
          'recovery',
          'reauthentication_required',
        ),
      ),
    );
  });

  test('successful fresh login after recovery clears invalidation marker and persists new session across restart', () async {
    final storage = MemoryTokens()
      ..access = 'stale-token'
      ..refresh = 'stale-refresh'
      ..sessionInvalid = true; // Started from recovery state
    final newAccess = jwt(
      DateTime.now().add(const Duration(minutes: 30)),
      user: 2,
    );
    final client = clientFor(storage, (options) {
      if (options.path == '/auth/login/') {
        return reply({'access': newAccess, 'refresh': 'new-refresh'});
      }
      if (options.path == '/records/') {
        return reply({'ok': true});
      }
      return reply({});
    });

    await client.session.login('account-b', 'correct-password');

    // Marker is cleared and new tokens are active
    expect(await storage.isSessionInvalid(), isFalse);
    expect(await storage.readAccessToken(), newAccess);
    expect(await storage.readRefreshToken(), 'new-refresh');
    expect(client.session.canAuthorize, isTrue);

    // App restart uses new credentials
    final restartedClient = clientFor(storage, (options) {
      expect(options.headers['Authorization'], 'Bearer $newAccess');
      return reply({'ok': true});
    });
    expect(await restartedClient.session.accessToken(), newAccess);
    final response = await restartedClient.dio.get('/records/');
    expect(response.statusCode, 200);
  });

  test('interrupted credential writes do not clear invalidation marker or authorize older credentials', () async {
    final oldAccess = jwt(
      DateTime.now().add(const Duration(minutes: 30)),
      user: 1,
    );
    final storage = MemoryTokens()
      ..access = oldAccess
      ..refresh = 'account-a-refresh'
      ..failAccessWrites = true;
    final client = clientFor(storage, (options) {
      if (options.path == '/auth/login/') {
        return reply({
          'access': jwt(
            DateTime.now().add(const Duration(minutes: 30)),
            user: 2,
          ),
          'refresh': 'new-refresh',
        });
      }
      return reply({});
    });

    await expectLater(
      client.session.login('account-b', 'password'),
      throwsA(isA<StateError>()),
    );

    // Marker remains set
    expect(await storage.isSessionInvalid(), isTrue);

    // App restart cannot use credentials
    final restartedClient = clientFor(storage, (_) => reply({}));
    expect(await storage.readAccessToken(), isNull);
    await expectLater(
      restartedClient.session.accessToken(),
      throwsA(
        isA<ApiError>().having(
          (e) => e.code,
          'recovery',
          'reauthentication_required',
        ),
      ),
    );
  });
}
