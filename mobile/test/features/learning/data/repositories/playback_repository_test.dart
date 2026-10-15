import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:training_app/core/errors/api_error.dart';
import 'package:training_app/core/network/dio_client.dart';
import 'package:training_app/core/storage/secure_token_storage.dart';
import 'package:training_app/features/learning/data/repositories/learning_repository.dart';

class MockApiClient extends Mock implements ApiClient {}

class MockDio extends Mock implements Dio {}

class MockStorage extends Mock implements SecureTokenStorage {}

void main() {
  late MockApiClient client;
  late MockDio dio;
  late MockStorage storage;
  late LearningRepository repository;
  const basePath = '/assignments/1/lessons/2';

  setUpAll(() => registerFallbackValue(CancelToken()));
  setUp(() {
    client = MockApiClient();
    dio = MockDio();
    storage = MockStorage();
    when(() => client.dio).thenReturn(dio);
    when(() => dio.options)
        .thenReturn(BaseOptions(baseUrl: 'https://qa.example/api/v1'));
    when(() => storage.readAccessToken())
        .thenAnswer((_) async => 'test-access');
    final mapper = ApiClient(tokenStorage: storage);
    when(() => client.mapExceptionToApiError(any())).thenAnswer(
      (invocation) =>
          mapper.mapExceptionToApiError(invocation.positionalArguments.first),
    );
    repository = LearningRepository(apiClient: client, tokenStorage: storage);
  });

  Response response(String path) => Response(
    requestOptions: RequestOptions(path: path),
    data: {
      'session_id': 3,
      'resume_position': 0,
      'watched_seconds': 0,
      'progress_percent': 0,
      'completed': false,
      'watched_ranges': [],
      'media_url': 'https://untrusted.invalid/video',
    },
  );

  test(
    'operations use existing scoped routes and minimal observation payloads',
    () async {
      final cancellation = CancelToken();
      when(() => dio.get('$basePath/progress/', cancelToken: cancellation))
          .thenAnswer((_) async => response('$basePath/progress/'));
      when(
        () => dio.post(
          any(),
          data: any(named: 'data'),
          cancelToken: cancellation,
        ),
      ).thenAnswer(
        (invocation) async => response(invocation.positionalArguments.first),
      );

      expect(
        (await repository.getLessonProgress(
          1,
          2,
          cancelToken: cancellation,
        )).completed,
        isFalse,
      );
      expect(
        (await repository.startPlaybackSession(
          1,
          2,
          cancelToken: cancellation,
        )).sessionId,
        3,
      );
      await repository.startPlaybackSession(
        1,
        2,
        position: 0,
        cancelToken: cancellation,
      );
      final heartbeat = await repository.submitPlaybackHeartbeat(
        1,
        2,
        3,
        90,
        cancelToken: cancellation,
      );
      expect(heartbeat.watchedSeconds, 0);
      expect(heartbeat.completed, isFalse);
      await repository.endPlaybackSession(
        1,
        2,
        3,
        0,
        completedNormally: true,
        cancelToken: cancellation,
      );

      verify(
        () => dio.post(
          '$basePath/sessions/',
          data: {},
          cancelToken: cancellation,
        ),
      ).called(1);
      verify(
        () => dio.post(
          '$basePath/sessions/',
          data: {'position': 0.0},
          cancelToken: cancellation,
        ),
      ).called(1);
      verify(
        () => dio.post(
          '$basePath/progress/',
          data: {'session_id': 3, 'position': 90.0},
          cancelToken: cancellation,
        ),
      ).called(1);
      verify(
        () => dio.post(
          '$basePath/sessions/3/end/',
          data: {'position': 0.0, 'completed_normally': true},
          cancelToken: cancellation,
        ),
      ).called(1);
    },
  );

  test('media configuration uses only configured origin and keeps credentials out of URL and string output', () async {
    final request = await repository.protectedMediaRequest(1, 2, 3);
    expect(
      request.uri.toString(),
      'https://qa.example/api/v1$basePath/sessions/3/media/',
    );
    expect(request.headers, {'Authorization': 'Bearer test-access'});
    expect(request.uri.hasQuery, isFalse);
    expect(request.toString(), isNot(contains('test-access')));
    expect(() => request.headers.clear(), throwsUnsupportedError);
  });

  test('read-only replay uses authenticated scoped media without a session request', () async {
    final request = await repository.protectedReplayMediaRequest(1, 2);
    expect(
      request.uri.toString(),
      'https://qa.example/api/v1$basePath/replay/media/',
    );
    expect(request.headers, {'Authorization': 'Bearer test-access'});
    expect(request.uri.hasQuery, isFalse);
    verifyNever(() => dio.get(any(), cancelToken: any(named: 'cancelToken')));
    verifyNever(
      () => dio.post(
        any(),
        data: any(named: 'data'),
        cancelToken: any(named: 'cancelToken'),
      ),
    );
    when(() => storage.readAccessToken()).thenAnswer((_) async => null);
    await expectLater(
      repository.protectedReplayMediaRequest(1, 2),
      throwsA(isA<ApiError>()),
    );
    await expectLater(
      repository.protectedReplayMediaRequest(-1, 2),
      throwsArgumentError,
    );
  });

  test(
    'missing credentials and unsafe origins cannot configure playback',
    () async {
      for (final token in [null, '']) {
        when(() => storage.readAccessToken()).thenAnswer((_) async => token);
        await expectLater(
          repository.protectedMediaRequest(1, 2, 3),
          throwsA(
            isA<ApiError>().having((error) => error.statusCode, 'status', 401),
          ),
        );
      }
      for (final origin in [
        'ftp://qa.example/api/v1',
        'https://user:password@qa.example/api/v1',
        'https://qa.example/api/v1?token=bad',
        'https://qa.example/other',
      ]) {
        when(() => dio.options).thenReturn(BaseOptions(baseUrl: origin));
        await expectLater(
          repository.protectedMediaRequest(1, 2, 3),
          throwsStateError,
        );
      }
    },
  );

  test('invalid IDs and numeric observations make no API requests', () async {
    expect(() => repository.getLessonProgress(0, 2), throwsArgumentError);
    expect(() => repository.startPlaybackSession(1, -2), throwsArgumentError);
    expect(
      () => repository.startPlaybackSession(1, 2, position: double.nan),
      throwsArgumentError,
    );
    expect(
      () => repository.submitPlaybackHeartbeat(1, 2, 0, 1),
      throwsArgumentError,
    );
    expect(
      () => repository.submitPlaybackHeartbeat(1, 2, 3, double.nan),
      throwsArgumentError,
    );
    expect(
      () => repository.endPlaybackSession(1, 2, 3, -1),
      throwsArgumentError,
    );
    await expectLater(
      repository.protectedMediaRequest(1, 2, 0),
      throwsArgumentError,
    );
    verifyNever(() => dio.get(any(), cancelToken: any(named: 'cancelToken')));
    verifyNever(
      () => dio.post(
        any(),
        data: any(named: 'data'),
        cancelToken: any(named: 'cancelToken'),
      ),
    );
  });

  test('API status codes and messages survive session failures', () async {
    for (final status in [401, 403, 404, 409]) {
      final failure = DioException(
        requestOptions: RequestOptions(path: '$basePath/sessions/'),
        type: DioExceptionType.badResponse,
        response: Response(
          requestOptions: RequestOptions(path: '$basePath/sessions/'),
          statusCode: status,
          data: {
            'error': {
              'code': 'denied',
              'message': 'Not available.',
              'fields': {},
            },
          },
        ),
      );
      when(() => dio.post('$basePath/sessions/', data: {}, cancelToken: null))
          .thenThrow(failure);
      await expectLater(
        repository.startPlaybackSession(1, 2),
        throwsA(
          isA<ApiError>()
              .having((error) => error.statusCode, 'status', status)
              .having((error) => error.message, 'message', 'Not available.'),
        ),
      );
    }
  });
}
