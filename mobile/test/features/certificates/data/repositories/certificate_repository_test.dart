import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:training_app/core/errors/api_error.dart';
import 'package:training_app/core/network/dio_client.dart';
import 'package:training_app/features/certificates/data/repositories/certificate_repository.dart';
class _MockApiClient extends Mock implements ApiClient {}
class _MockDio extends Mock implements Dio {}

Map<String, dynamic> _certJson(int id) => {
      'id': id,
      'certificate_number': 'GN-CERT-$id',
      'training_title': 'Training $id',
      'version_number': 1,
      'issued_at': '2024-01-0${id}T00:00:00Z',
      'is_revoked': false,
    };

Map<String, dynamic> _detailJson(int id) => {
      'id': id,
      'certificate_number': 'GN-DET-$id',
      'training_title': 'Training Detail $id',
      'version_number': 1,
      'employee_name': 'Test Employee',
      'employee_code': 'GN-EMP-001',
      'issued_at': '2024-02-01T00:00:00Z',
      'is_revoked': false,
      'revoked_at': null,
      'assignment_id': id * 10,
      'has_document': false,
    };

Response<dynamic> _okResponse(dynamic data) => Response(
      data: data,
      statusCode: 200,
      requestOptions: RequestOptions(),
    );

void main() {
  late _MockApiClient mockApiClient;
  late _MockDio mockDio;
  late CertificateRepository repository;

  setUp(() {
    mockApiClient = _MockApiClient();
    mockDio = _MockDio();
    when(() => mockApiClient.dio).thenReturn(mockDio);
    repository = CertificateRepository(apiClient: mockApiClient);
  });

  // ---------------------------------------------------------------------------
  // getCertificates
  // ---------------------------------------------------------------------------

  group('getCertificates', () {
    test('returns empty list when API returns empty results', () async {
      when(() => mockDio.get('/certificates/', cancelToken: any(named: 'cancelToken')))
          .thenAnswer(
        (_) async => _okResponse({'count': 0, 'next': null, 'results': []}),
      );

      final result = await repository.getCertificates();
      expect(result, isEmpty);
    });

    test('returns single-page list correctly', () async {
      when(() => mockDio.get('/certificates/', cancelToken: any(named: 'cancelToken')))
          .thenAnswer(
        (_) async => _okResponse({
          'count': 2,
          'next': null,
          'results': [_certJson(1), _certJson(2)],
        }),
      );

      final result = await repository.getCertificates();
      expect(result.length, 2);
      expect(result[0].certificateNumber, 'GN-CERT-1');
      expect(result[1].certificateNumber, 'GN-CERT-2');
    });

    test('follows pagination correctly across two pages', () async {
      when(
        () => mockDio.get(
          '/certificates/',
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer(
        (_) async => _okResponse({
          'count': 3,
          'next': 'https://example.com/api/v1/certificates/?page=2',
          'results': [_certJson(1)],
        }),
      );
      when(
        () => mockDio.get(
          '/certificates/',
          queryParameters: {'page': 2},
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer(
        (_) async => _okResponse({
          'count': 3,
          'next': null,
          'results': [_certJson(2), _certJson(3)],
        }),
      );

      final result = await repository.getCertificates();
      expect(result.length, 3);
    });

    test('throws ApiError on DioException', () async {
      when(
        () => mockDio.get('/certificates/', cancelToken: any(named: 'cancelToken')),
      ).thenThrow(
        DioException(
          type: DioExceptionType.connectionError,
          requestOptions: RequestOptions(),
        ),
      );
      when(() => mockApiClient.mapExceptionToApiError(any()))
          .thenReturn(ApiError.networkFailure());

      expect(
        () => repository.getCertificates(),
        throwsA(isA<ApiError>()),
      );
    });
  });

  // ---------------------------------------------------------------------------
  // getCertificateDetail
  // ---------------------------------------------------------------------------

  group('getCertificateDetail', () {
    test('returns certificate detail for valid id', () async {
      when(
        () => mockDio.get(
          '/certificates/5/',
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer((_) async => _okResponse(_detailJson(5)));

      final detail = await repository.getCertificateDetail(5);
      expect(detail.id, 5);
      expect(detail.certificateNumber, 'GN-DET-5');
      expect(detail.assignmentId, 50);
      expect(detail.hasDocument, false);
    });

    test('throws ArgumentError for non-positive id', () {
      expect(
        () => repository.getCertificateDetail(0),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => repository.getCertificateDetail(-1),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('maps 404 DioException to ApiError', () async {
      when(
        () => mockDio.get(
          '/certificates/999/',
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenThrow(
        DioException(
          type: DioExceptionType.badResponse,
          response: Response(
            statusCode: 404,
            data: {'error': {'code': 'not_found', 'message': 'Not found.', 'fields': {}}},
            requestOptions: RequestOptions(),
          ),
          requestOptions: RequestOptions(),
        ),
      );
      when(() => mockApiClient.mapExceptionToApiError(any())).thenReturn(
        ApiError(message: 'Not found.', statusCode: 404),
      );

      await expectLater(
        repository.getCertificateDetail(999),
        throwsA(isA<ApiError>()),
      );
    });

    test('maps network error to ApiError', () async {
      when(
        () => mockDio.get(
          '/certificates/1/',
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenThrow(
        DioException(
          type: DioExceptionType.connectionTimeout,
          requestOptions: RequestOptions(),
        ),
      );
      when(() => mockApiClient.mapExceptionToApiError(any()))
          .thenReturn(ApiError.timeout());

      await expectLater(
        repository.getCertificateDetail(1),
        throwsA(isA<ApiError>()),
      );
    });
  });
}
