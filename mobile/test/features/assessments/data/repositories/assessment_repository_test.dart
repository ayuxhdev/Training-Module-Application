import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:training_app/core/errors/api_error.dart';
import 'package:training_app/core/network/dio_client.dart';
import 'package:training_app/core/storage/secure_token_storage.dart';
import 'package:training_app/features/assessments/data/repositories/assessment_repository.dart';

import '../../assessment_fixtures.dart';

class MockClient extends Mock implements ApiClient {}

class MockDio extends Mock implements Dio {}

class MockStorage extends Mock implements SecureTokenStorage {}

void main() {
  late MockClient client;
  late MockDio dio;
  late AssessmentRepository repository;
  setUpAll(() => registerFallbackValue(CancelToken()));
  setUp(() {
    client = MockClient();
    dio = MockDio();
    when(() => client.dio).thenReturn(dio);
    final mapper = ApiClient(tokenStorage: MockStorage());
    when(() => client.mapExceptionToApiError(any())).thenAnswer(
      (call) => mapper.mapExceptionToApiError(call.positionalArguments.first),
    );
    repository = AssessmentRepository(apiClient: client);
  });

  Response response(dynamic data) =>
      Response(data: data, requestOptions: RequestOptions());

  test(
    'all operations use fixed v1-relative routes and answers-only payloads',
    () async {
      final token = CancelToken();
      when(() => dio.get('/assignments/1/assessments/', cancelToken: token))
          .thenAnswer((_) async => response(catalogJson()));
      when(() => dio.get('/assessment-attempts/7/', cancelToken: token))
          .thenAnswer((_) async => response(attemptJson()));
      when(
        () => dio.post(
          any(),
          data: any(named: 'data'),
          cancelToken: token,
        ),
      ).thenAnswer(
        (call) async => response(
          attemptJson(
            status:
                call.positionalArguments.first.toString().endsWith('/submit/')
                ? 'SUBMITTED'
                : 'IN_PROGRESS',
          ),
        ),
      );
      expect(
        (await repository.getAssessments(1, cancelToken: token)).assignmentId,
        1,
      );
      expect(
        (await repository.startOrResume(1, 2, cancelToken: token)).summary.id,
        7,
      );
      expect(
        (await repository.getAttempt(7, cancelToken: token)).summary.isClosed,
        isFalse,
      );
      expect(
        (await repository.submitAttempt(7, {
          11: 21,
          12: null,
        }, cancelToken: token)).summary.passed,
        isTrue,
      );
      verify(
        () => dio.post(
          '/assignments/1/assessments/2/attempts/',
          data: {},
          cancelToken: token,
        ),
      ).called(1);
      verify(
        () => dio.post(
          '/assessment-attempts/7/submit/',
          data: {
            'answers': {'11': 21, '12': null},
          },
          cancelToken: token,
        ),
      ).called(1);
    },
  );

  test('invalid identifiers never reach the network', () async {
    await expectLater(repository.getAssessments(0), throwsArgumentError);
    expect(() => repository.startOrResume(1, -2), throwsArgumentError);
    expect(() => repository.getAttempt(0), throwsArgumentError);
    expect(() => repository.submitAttempt(7, {0: 1}), throwsArgumentError);
    expect(() => repository.submitAttempt(7, {11: -1}), throwsArgumentError);
    verifyZeroInteractions(dio);
  });

  for (final status in [400, 401, 403, 404, 409]) {
    test('preserves structured $status errors, codes and fields', () async {
      final options = RequestOptions(path: '/assessment-attempts/7/');
      when(() => dio.get(any(), cancelToken: any(named: 'cancelToken')))
          .thenThrow(
            DioException(
              requestOptions: options,
              type: DioExceptionType.badResponse,
              response: Response(
                requestOptions: options,
                statusCode: status,
                data: {
                  'error': {
                    'code': 'test_code',
                    'message': 'Controlled error',
                    'fields': {
                      'answers': ['Invalid'],
                    },
                  },
                },
              ),
            ),
          );
      await expectLater(
        repository.getAttempt(7),
        throwsA(
          isA<ApiError>()
              .having((e) => e.statusCode, 'status', status)
              .having((e) => e.code, 'code', 'test_code')
              .having((e) => e.details, 'fields', {
                'answers': ['Invalid'],
              }),
        ),
      );
    });
  }

  test('maps network, timeout and malformed response failures without retrying mutations', () async {
    for (final pair in [
      (DioExceptionType.receiveTimeout, 'timeout'),
      (DioExceptionType.connectionError, 'network_failure'),
    ]) {
      when(
        () => dio.post(
          any(),
          data: any(named: 'data'),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenThrow(
        DioException(requestOptions: RequestOptions(), type: pair.$1),
      );
      await expectLater(
        repository.submitAttempt(7, {11: 21}),
        throwsA(isA<ApiError>().having((e) => e.code, 'code', pair.$2)),
      );
    }
    verify(
      () => dio.post(
        any(),
        data: any(named: 'data'),
        cancelToken: any(named: 'cancelToken'),
      ),
    ).called(2);
    when(() => dio.get(any(), cancelToken: any(named: 'cancelToken')))
        .thenAnswer((_) async => response({'id': 'bad'}));
    await expectLater(repository.getAttempt(7), throwsA(isA<ApiError>()));
  });

  test(
    'a mismatched assignment response is a controlled parsing failure',
    () async {
      when(() => dio.get(any(), cancelToken: any(named: 'cancelToken')))
          .thenAnswer((_) async => response(catalogJson(assignmentId: 99)));
      await expectLater(
        repository.getAssessments(1),
        throwsA(isA<ApiError>().having((e) => e.code, 'code', 'unexpected')),
      );
    },
  );
}
