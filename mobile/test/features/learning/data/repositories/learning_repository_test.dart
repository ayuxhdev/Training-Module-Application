import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:dio/dio.dart';
import 'package:training_app/core/errors/api_error.dart';
import 'package:training_app/core/network/dio_client.dart';
import 'package:training_app/features/learning/data/repositories/learning_repository.dart';

class MockApiClient extends Mock implements ApiClient {}
class MockDio extends Mock implements Dio {}

void main() {
  late MockApiClient mockApiClient;
  late MockDio mockDio;
  late LearningRepository repository;

  setUp(() {
    mockApiClient = MockApiClient();
    mockDio = MockDio();
    when(() => mockApiClient.dio).thenReturn(mockDio);
    repository = LearningRepository(apiClient: mockApiClient);
  });

  group('LearningRepository', () {
    test('getAssignments returns a list of Assignments on success', () async {
      final mockData = [
        {
          'id': 1,
          'training_title': 'Test Training 1',
          'progress_summary': {'required_lessons_completed': 1, 'required_lessons_total': 2}
        },
        {
          'id': 2,
          'training_title': 'Test Training 2',
          'progress_summary': {'required_lessons_completed': 0, 'required_lessons_total': 3}
        }
      ];

      when(() => mockDio.get('/assignments/')).thenAnswer(
        (_) async => Response(
          requestOptions: RequestOptions(path: '/assignments/'),
          data: mockData,
          statusCode: 200,
        ),
      );

      final assignments = await repository.getAssignments();

      expect(assignments.length, 2);
      expect(assignments[0].id, 1);
      expect(assignments[0].trainingTitle, 'Test Training 1');
      expect(assignments[1].id, 2);
      expect(assignments[1].trainingTitle, 'Test Training 2');
    });

    test('getAssignments throws ApiError on failure', () async {
      final error = DioException(requestOptions: RequestOptions(path: '/assignments/'));
      final apiError = ApiError(message: 'Failed to fetch assignments');

      when(() => mockDio.get('/assignments/')).thenThrow(error);
      when(() => mockApiClient.mapExceptionToApiError(error)).thenReturn(apiError);

      expect(() => repository.getAssignments(), throwsA(isA<ApiError>()));
    });

    test('getAssignmentDetail returns AssignmentDetail on success', () async {
      final mockData = {
        'id': 1,
        'training_title': 'Detail Training',
        'modules': []
      };

      when(() => mockDio.get('/assignments/1/')).thenAnswer(
        (_) async => Response(
          requestOptions: RequestOptions(path: '/assignments/1/'),
          data: mockData,
          statusCode: 200,
        ),
      );

      final detail = await repository.getAssignmentDetail(1);

      expect(detail.id, 1);
      expect(detail.trainingTitle, 'Detail Training');
    });

    test('getAssignmentDetail throws ApiError on failure', () async {
      final error = DioException(requestOptions: RequestOptions(path: '/assignments/1/'));
      final apiError = ApiError(message: 'Failed to fetch detail');

      when(() => mockDio.get('/assignments/1/')).thenThrow(error);
      when(() => mockApiClient.mapExceptionToApiError(error)).thenReturn(apiError);

      expect(() => repository.getAssignmentDetail(1), throwsA(isA<ApiError>()));
    });
  });
}
