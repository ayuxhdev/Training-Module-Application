import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:training_app/core/errors/api_error.dart';
import 'package:training_app/core/network/dio_client.dart';
import 'package:training_app/features/notifications/data/repositories/notification_repository.dart';

import '../../notification_fixtures.dart';

class _Client extends Mock implements ApiClient {}

class _Dio extends Mock implements Dio {}

void main() {
  late _Client client;
  late _Dio dio;
  late NotificationRepository repository;

  Response<dynamic> response(Object data) => Response(
    data: data,
    requestOptions: RequestOptions(path: '/notifications/'),
  );

  setUp(() {
    client = _Client();
    dio = _Dio();
    when(() => client.dio).thenReturn(dio);
    when(() => client.mapExceptionToApiError(any()))
        .thenReturn(ApiError.unexpected());
    repository = NotificationRepository(client);
  });

  test(
    'fetches only the local paginated endpoint, ignoring arbitrary next URLs',
    () async {
      when(
        () => dio.get(
          '/notifications/',
          queryParameters: null,
          cancelToken: null,
        ),
      ).thenAnswer(
        (_) async => response({
          'count': 2,
          'next': 'https://untrusted.invalid/',
          'previous': null,
          'results': [notificationJson()],
        }),
      );
      when(
        () => dio.get(
          '/notifications/',
          queryParameters: {'page': 2},
          cancelToken: null,
        ),
      ).thenAnswer(
        (_) async => response({
          'count': 2,
          'next': null,
          'previous': '/notifications/',
          'results': [notificationJson(id: 2)],
        }),
      );
      expect((await repository.getPage()).hasMore, isTrue);
      expect((await repository.getPage(page: 2)).items.single.id, 2);
      verifyNever(() => dio.get('https://untrusted.invalid/'));
    },
  );

  test('reads the exact unread-count and mark-all count contracts', () async {
    when(() => dio.get('/notifications/unread-count/', cancelToken: null))
        .thenAnswer((_) async => response({'unread_count': 3}));
    when(
      () => dio.post(
        '/notifications/read-all/',
        data: const <String, dynamic>{},
        cancelToken: null,
      ),
    ).thenAnswer((_) async => response({'updated_count': 3}));
    expect(await repository.getUnreadCount(), 3);
    expect(await repository.markAllRead(), 3);
    verify(
      () => dio.post(
        '/notifications/read-all/',
        data: const <String, dynamic>{},
        cancelToken: null,
      ),
    ).called(1);
  });

  test('mark-read sends an empty payload and requires a matching server-confirmed read', () async {
    when(
      () => dio.post(
        '/notifications/1/read/',
        data: const <String, dynamic>{},
        cancelToken: null,
      ),
    ).thenAnswer((_) async => response(notificationJson(read: true)));
    expect((await repository.markRead(1)).isRead, isTrue);
    for (final data in [
      notificationJson(),
      notificationJson(id: 2, read: true),
    ]) {
      when(
        () => dio.post(
          '/notifications/1/read/',
          data: const <String, dynamic>{},
          cancelToken: null,
        ),
      ).thenAnswer((_) async => response(data));
      await expectLater(repository.markRead(1), throwsA(isA<ApiError>()));
    }
  });

  test(
    'failed mutation is mapped once and never automatically replayed',
    () async {
      final failure = DioException(
        requestOptions: RequestOptions(path: '/notifications/1/read/'),
        type: DioExceptionType.receiveTimeout,
      );
      when(
        () => dio.post(
          '/notifications/1/read/',
          data: const <String, dynamic>{},
          cancelToken: null,
        ),
      ).thenThrow(failure);
      when(() => client.mapExceptionToApiError(failure))
          .thenReturn(ApiError.timeout());
      await expectLater(
        repository.markRead(1),
        throwsA(isA<ApiError>().having((e) => e.code, 'code', 'timeout')),
      );
      verify(
        () => dio.post(
          '/notifications/1/read/',
          data: const <String, dynamic>{},
          cancelToken: null,
        ),
      ).called(1);
    },
  );

  test('cancellation discards a late mocked response', () async {
    final token = CancelToken();
    when(
      () =>
          dio.get('/notifications/', queryParameters: null, cancelToken: token),
    ).thenAnswer((_) async {
      token.cancel();
      return response({
        'count': 1,
        'next': null,
        'results': [notificationJson()],
      });
    });
    await expectLater(
      repository.getPage(cancelToken: token),
      throwsA(isA<ApiError>()),
    );
  });

  test('invalid identifiers and count values fail without unsafe requests or invented state', () async {
    await expectLater(repository.markRead(0), throwsArgumentError);
    await expectLater(repository.getPage(page: -1), throwsArgumentError);
    verifyZeroInteractions(dio);
    when(() => dio.get('/notifications/unread-count/', cancelToken: null))
        .thenAnswer((_) async => response({'unread_count': '3'}));
    await expectLater(repository.getUnreadCount(), throwsA(isA<ApiError>()));
    when(
      () => dio.post(
        '/notifications/read-all/',
        data: const <String, dynamic>{},
        cancelToken: null,
      ),
    ).thenAnswer((_) async => response({'updated_count': -1}));
    await expectLater(repository.markAllRead(), throwsA(isA<ApiError>()));
  });
}
