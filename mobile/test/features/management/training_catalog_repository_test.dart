import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:training_app/core/errors/api_error.dart';
import 'package:training_app/core/network/dio_client.dart';
import 'package:training_app/features/management/data/repositories/management_repository.dart';

import 'management_fixtures.dart';

class ClientMock extends Mock implements ApiClient {}

class DioMock extends Mock implements Dio {}

void main() {
  late ClientMock client;
  late DioMock dio;
  late ManagementRepository repository;

  setUpAll(() => registerFallbackValue(CancelToken()));

  setUp(() {
    client = ClientMock();
    dio = DioMock();
    when(() => client.dio).thenReturn(dio);
    when(() => client.mapExceptionToApiError(any())).thenAnswer(
      (invocation) => invocation.positionalArguments.first is ApiError
          ? invocation.positionalArguments.first as ApiError
          : ApiError.unexpected(),
    );
    repository = ManagementRepository(client);
  });

  group('ManagementRepository - Training Catalog & Versions', () {
    test(
      'trainings parses paginated courses and applies search query',
      () async {
        when(
          () => dio.get(
            '/management/trainings/',
            queryParameters: {'page': 2, 'page_size': 10, 'search': 'Safety'},
            cancelToken: any(named: 'cancelToken'),
          ),
        ).thenAnswer(
          (_) async => Response(
            requestOptions: RequestOptions(path: '/management/trainings/'),
            data: {
              'count': 1,
              'next': null,
              'previous': null,
              'results': [
                managedTrainingJson(
                  id: 5,
                  code: 'TR-SAFE-001',
                  title: 'Workplace Safety Fundamentals',
                  description: 'Core safety curriculum.',
                  isActive: true,
                  latestVersionNumber: 3,
                  latestVersionStatus: 'PUBLISHED',
                ),
              ],
            },
          ),
        );

        final page = await repository.trainings(
          page: 2,
          pageSize: 10,
          search: 'Safety',
        );

        expect(page.count, 1);
        expect(page.items.length, 1);
        final course = page.items.first;
        expect(course.id, 5);
        expect(course.code, 'TR-SAFE-001');
        expect(course.title, 'Workplace Safety Fundamentals');
        expect(course.description, 'Core safety curriculum.');
        expect(course.isActive, isTrue);
        expect(course.latestVersionNumber, 3);
        expect(course.latestVersionStatus, 'PUBLISHED');
      },
    );

    test(
      'trainings falls back gracefully for alternative field names and nulls',
      () async {
        when(
          () => dio.get(
            '/management/trainings/',
            queryParameters: null,
            cancelToken: any(named: 'cancelToken'),
          ),
        ).thenAnswer(
          (_) async => Response(
            requestOptions: RequestOptions(path: '/management/trainings/'),
            data: {
              'count': 1,
              'next': null,
              'previous': null,
              'results': [
                {
                  'id': 7,
                  'code': 'TR-DRAFT-007',
                  'catalog_title': 'Draft Equipment Training',
                  'description': null,
                  'is_active': false,
                  'latest_version_number': null,
                  'latest_version_status': null,
                },
              ],
            },
          ),
        );

        final page = await repository.trainings();
        expect(page.items.length, 1);
        final course = page.items.first;
        expect(course.id, 7);
        expect(course.title, 'Draft Equipment Training');
        expect(course.description, '');
        expect(course.isActive, isFalse);
        expect(course.latestVersionNumber, isNull);
        expect(course.latestVersionStatus, isNull);
      },
    );

    test('training retrieves single course details by id', () async {
      when(
        () => dio.get(
          '/management/trainings/12/',
          queryParameters: null,
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer(
        (_) async => Response(
          requestOptions: RequestOptions(path: '/management/trainings/12/'),
          data: managedTrainingJson(
            id: 12,
            code: 'TR-FORK-002',
            title: 'Forklift Operations',
          ),
        ),
      );

      final course = await repository.training(12);
      expect(course.id, 12);
      expect(course.code, 'TR-FORK-002');
      expect(course.title, 'Forklift Operations');
    });

    test('training maps DioException to ApiError', () async {
      when(
        () => dio.get(
          '/management/trainings/999/',
          queryParameters: null,
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenThrow(
        DioException(
          requestOptions: RequestOptions(path: '/management/trainings/999/'),
          response: Response(
            requestOptions: RequestOptions(path: '/management/trainings/999/'),
            statusCode: 404,
          ),
        ),
      );

      expect(() => repository.training(999), throwsA(isA<ApiError>()));
    });

    test(
      'trainingVersions retrieves paginated version history for course',
      () async {
        when(
          () => dio.get(
            '/management/trainings/12/versions/',
            queryParameters: {'page_size': 20},
            cancelToken: any(named: 'cancelToken'),
          ),
        ).thenAnswer(
          (_) async => Response(
            requestOptions: RequestOptions(
              path: '/management/trainings/12/versions/',
            ),
            data: {
              'count': 2,
              'next': null,
              'previous': null,
              'results': [
                managedTrainingVersionJson(
                  id: 101,
                  trainingId: 12,
                  versionNumber: 2,
                  title: 'Forklift Operations v2',
                  status: 'PUBLISHED',
                ),
                managedTrainingVersionJson(
                  id: 100,
                  trainingId: 12,
                  versionNumber: 1,
                  title: 'Forklift Operations v1',
                  status: 'RETIRED',
                ),
              ],
            },
          ),
        );

        final page = await repository.trainingVersions(
          12,
          page: 1,
          pageSize: 20,
        );
        expect(page.count, 2);
        expect(page.items.length, 2);
        expect(page.items[0].versionNumber, 2);
        expect(page.items[0].status, 'PUBLISHED');
        expect(page.items[1].versionNumber, 1);
        expect(page.items[1].status, 'RETIRED');
      },
    );

    test(
      'versionDetail retrieves curriculum with sorted modules and lessons',
      () async {
        when(
          () => dio.get(
            '/management/versions/42/',
            queryParameters: null,
            cancelToken: any(named: 'cancelToken'),
          ),
        ).thenAnswer(
          (_) async => Response(
            requestOptions: RequestOptions(path: '/management/versions/42/'),
            data: managedVersionDetailJson(
              id: 42,
              trainingId: 12,
              trainingTitle: 'Forklift Operations',
              trainingCode: 'TR-FORK-002',
              versionNumber: 2,
              title: 'Forklift Operations v2',
              status: 'PUBLISHED',
              modules: [
                managedModuleJson(
                  id: 202,
                  title: 'Practical Inspection',
                  order: 2,
                  lessons: [
                    managedLessonSummaryJson(
                      id: 303,
                      title: 'Hydraulic System Inspection',
                      lessonType: 'VIDEO',
                      order: 2,
                      isRequired: true,
                    ),
                    managedLessonSummaryJson(
                      id: 302,
                      title: 'Pre-shift Walkaround Checklist',
                      lessonType: 'TEXT',
                      order: 1,
                      isRequired: true,
                    ),
                  ],
                ),
                managedModuleJson(
                  id: 201,
                  title: 'Safety Regulations',
                  order: 1,
                  lessons: [
                    managedLessonSummaryJson(
                      id: 301,
                      title: 'OSHA Standards Overview',
                      lessonType: 'TEXT',
                      order: 1,
                      isRequired: false,
                    ),
                  ],
                ),
              ],
            ),
          ),
        );

        final detail = await repository.versionDetail(42);
        expect(detail.id, 42);
        expect(detail.trainingTitle, 'Forklift Operations');
        expect(detail.trainingCode, 'TR-FORK-002');
        expect(detail.versionNumber, 2);
        expect(detail.status, 'PUBLISHED');

        // Modules sorted by order (1, then 2)
        expect(detail.modules.length, 2);
        expect(detail.modules[0].id, 201);
        expect(detail.modules[0].order, 1);
        expect(detail.modules[0].title, 'Safety Regulations');

        expect(detail.modules[1].id, 202);
        expect(detail.modules[1].order, 2);
        expect(detail.modules[1].title, 'Practical Inspection');

        // Lessons in module 202 sorted by order (1, then 2)
        final lessons = detail.modules[1].lessons;
        expect(lessons.length, 2);
        expect(lessons[0].id, 302);
        expect(lessons[0].order, 1);
        expect(lessons[0].lessonType, 'TEXT');
        expect(lessons[0].isRequired, isTrue);

        expect(lessons[1].id, 303);
        expect(lessons[1].order, 2);
        expect(lessons[1].lessonType, 'VIDEO');
        expect(lessons[1].isRequired, isTrue);
      },
    );

    test('versionDetail maps DioException to ApiError', () async {
      when(
        () => dio.get(
          '/management/versions/999/',
          queryParameters: null,
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenThrow(
        DioException(
          requestOptions: RequestOptions(path: '/management/versions/999/'),
          response: Response(
            requestOptions: RequestOptions(path: '/management/versions/999/'),
            statusCode: 403,
          ),
        ),
      );

      expect(() => repository.versionDetail(999), throwsA(isA<ApiError>()));
    });

    test('allTrainingVersions retrieves paginated version directory', () async {
      when(
        () => dio.get(
          '/management/versions/',
          queryParameters: null,
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer(
        (_) async => Response(
          requestOptions: RequestOptions(path: '/management/versions/'),
          data: {
            'count': 1,
            'next': null,
            'previous': null,
            'results': [
              {
                'id': 101,
                'training_id': 12,
                'training_title': 'Forklift Operations',
                'version_number': 3,
                'title': 'Forklift Operations v3',
                'status': 'PUBLISHED',
              },
            ],
          },
        ),
      );

      final page = await repository.allTrainingVersions();
      expect(page.count, 1);
      expect(page.items.length, 1);
      final item = page.items.first;
      expect(item.id, 101);
      expect(item.trainingId, 12);
      expect(item.trainingTitle, 'Forklift Operations');
      expect(item.versionNumber, 3);
      expect(item.title, 'Forklift Operations v3');
      expect(item.status, 'PUBLISHED');
      expect(item.description, '');
    });

    test('allTrainingVersions maps DioException to ApiError', () async {
      when(
        () => dio.get(
          '/management/versions/',
          queryParameters: null,
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenThrow(
        DioException(
          requestOptions: RequestOptions(path: '/management/versions/'),
          response: Response(
            requestOptions: RequestOptions(path: '/management/versions/'),
            statusCode: 403,
          ),
        ),
      );

      expect(() => repository.allTrainingVersions(), throwsA(isA<ApiError>()));
    });
  });
}
