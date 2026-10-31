import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:training_app/core/errors/api_error.dart';
import 'package:training_app/core/network/dio_client.dart';
import 'package:training_app/features/management/data/repositories/management_repository.dart';
import 'package:training_app/features/management/data/services/video_file_picker.dart';

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

    test('createTraining posts payload and parses created course', () async {
      when(
        () => dio.post(
          '/management/trainings/',
          data: {
            'code': 'TR-FIRE-001',
            'catalog_title': 'Fire Safety',
            'description': 'Emergency response',
            'is_active': true,
          },
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer(
        (_) async => Response(
          requestOptions: RequestOptions(path: '/management/trainings/'),
          statusCode: 201,
          data: managedTrainingJson(
            id: 15,
            code: 'TR-FIRE-001',
            title: 'Fire Safety',
            description: 'Emergency response',
          ),
        ),
      );

      final course = await repository.createTraining(
        code: 'TR-FIRE-001',
        catalogTitle: 'Fire Safety',
        description: 'Emergency response',
        isActive: true,
      );

      expect(course.id, 15);
      expect(course.code, 'TR-FIRE-001');
      expect(course.title, 'Fire Safety');
      expect(course.description, 'Emergency response');
      expect(course.isActive, isTrue);
    });

    test('createTraining rejects invalid input before network call', () {
      expect(
        () => repository.createTraining(code: '', catalogTitle: 'Valid title'),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => repository.createTraining(
          code: 'A' * 41,
          catalogTitle: 'Valid title',
        ),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => repository.createTraining(code: 'VALID', catalogTitle: ''),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('updateTraining patches payload and parses updated course', () async {
      when(
        () => dio.patch(
          '/management/trainings/15/',
          data: {'catalog_title': 'Updated Fire Safety', 'is_active': false},
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer(
        (_) async => Response(
          requestOptions: RequestOptions(path: '/management/trainings/15/'),
          statusCode: 200,
          data: managedTrainingJson(
            id: 15,
            code: 'TR-FIRE-001',
            title: 'Updated Fire Safety',
            isActive: false,
          ),
        ),
      );

      final course = await repository.updateTraining(
        15,
        catalogTitle: 'Updated Fire Safety',
        isActive: false,
      );

      expect(course.id, 15);
      expect(course.title, 'Updated Fire Safety');
      expect(course.isActive, isFalse);
    });

    test('updateTraining throws ArgumentError when no fields provided', () {
      expect(
        () => repository.updateTraining(15),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('createDraftVersion posts payload and parses draft detail', () async {
      when(
        () => dio.post(
          '/management/trainings/15/versions/',
          data: {
            'title': 'Fire Safety 2026',
            'description': 'Updated procedures',
            'learning_objectives': 'Evacuate safely',
            'change_summary': 'Added alarm drill',
          },
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer(
        (_) async => Response(
          requestOptions: RequestOptions(
            path: '/management/trainings/15/versions/',
          ),
          statusCode: 201,
          data: managedVersionDetailJson(
            id: 25,
            trainingId: 15,
            versionNumber: 2,
            title: 'Fire Safety 2026',
            status: 'DRAFT',
            description: 'Updated procedures',
            modules: [],
          ),
        ),
      );

      final version = await repository.createDraftVersion(
        15,
        title: 'Fire Safety 2026',
        description: 'Updated procedures',
        learningObjectives: 'Evacuate safely',
        changeSummary: 'Added alarm drill',
      );

      expect(version.id, 25);
      expect(version.trainingId, 15);
      expect(version.versionNumber, 2);
      expect(version.title, 'Fire Safety 2026');
      expect(version.status, 'DRAFT');
    });

    test('createDraftVersion maps 409 conflict to ApiError', () async {
      when(
        () => dio.post(
          '/management/trainings/15/versions/',
          data: {
            'title': 'Fire Safety 2026',
            'description': '',
            'learning_objectives': '',
            'change_summary': '',
          },
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenThrow(
        DioException(
          requestOptions: RequestOptions(
            path: '/management/trainings/15/versions/',
          ),
          response: Response(
            requestOptions: RequestOptions(
              path: '/management/trainings/15/versions/',
            ),
            statusCode: 409,
          ),
        ),
      );

      expect(
        () => repository.createDraftVersion(15, title: 'Fire Safety 2026'),
        throwsA(isA<ApiError>()),
      );
    });

    test('createModule posts payload and parses module detail', () async {
      when(
        () => dio.post(
          '/management/versions/42/modules/',
          data: {
            'title': 'Site safety',
            'description': 'Before starting work',
            'position': 1,
          },
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer(
        (_) async => Response(
          requestOptions: RequestOptions(
            path: '/management/versions/42/modules/',
          ),
          statusCode: 201,
          data: managedModuleDetailJson(
            id: 70,
            trainingVersionId: 42,
            title: 'Site safety',
            description: 'Before starting work',
            position: 1,
          ),
        ),
      );

      final module = await repository.createModule(
        42,
        title: 'Site safety',
        description: 'Before starting work',
        position: 1,
      );

      expect(module.id, 70);
      expect(module.trainingVersionId, 42);
      expect(module.title, 'Site safety');
      expect(module.description, 'Before starting work');
      expect(module.position, 1);
    });

    test('createModule validates inputs before network call', () {
      expect(
        () => repository.createModule(0, title: 'T', position: 1),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => repository.createModule(42, title: '', position: 1),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => repository.createModule(42, title: 'A' * 201, position: 1),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => repository.createModule(42, title: 'Valid', position: 0),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('moduleDetail fetches and parses module detail', () async {
      when(
        () => dio.get(
          '/management/versions/42/modules/70/',
          queryParameters: any(named: 'queryParameters'),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer(
        (_) async => Response(
          requestOptions: RequestOptions(
            path: '/management/versions/42/modules/70/',
          ),
          statusCode: 200,
          data: managedModuleDetailJson(id: 70, trainingVersionId: 42),
        ),
      );

      final module = await repository.moduleDetail(42, 70);
      expect(module.id, 70);
      expect(module.trainingVersionId, 42);
    });

    test('updateModule patches payload and parses updated module', () async {
      when(
        () => dio.patch(
          '/management/versions/42/modules/70/',
          data: {'title': 'Updated Title', 'position': 3},
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer(
        (_) async => Response(
          requestOptions: RequestOptions(
            path: '/management/versions/42/modules/70/',
          ),
          statusCode: 200,
          data: managedModuleDetailJson(
            id: 70,
            trainingVersionId: 42,
            title: 'Updated Title',
            position: 3,
          ),
        ),
      );

      final updated = await repository.updateModule(
        42,
        70,
        title: 'Updated Title',
        position: 3,
      );

      expect(updated.id, 70);
      expect(updated.title, 'Updated Title');
      expect(updated.position, 3);
    });

    test('updateModule throws ArgumentError when no fields provided', () {
      expect(
        () => repository.updateModule(42, 70),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('createTextLesson posts payload and parses lesson detail', () async {
      when(
        () => dio.post(
          '/management/versions/42/modules/70/text-lessons/',
          data: {
            'title': 'Before work',
            'body': 'Check equipment.',
            'position': 1,
            'is_required': true,
            'content_type': 'TEXT',
          },
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer(
        (_) async => Response(
          requestOptions: RequestOptions(
            path: '/management/versions/42/modules/70/text-lessons/',
          ),
          statusCode: 201,
          data: managedTextLessonDetailJson(
            id: 90,
            moduleId: 70,
            trainingVersionId: 42,
            title: 'Before work',
            body: 'Check equipment.',
            position: 1,
            isRequired: true,
          ),
        ),
      );

      final lesson = await repository.createTextLesson(
        42,
        70,
        title: 'Before work',
        body: 'Check equipment.',
        position: 1,
        isRequired: true,
      );

      expect(lesson.id, 90);
      expect(lesson.moduleId, 70);
      expect(lesson.title, 'Before work');
      expect(lesson.body, 'Check equipment.');
      expect(lesson.contentType, 'TEXT');
      expect(lesson.position, 1);
      expect(lesson.isRequired, isTrue);
    });

    test('createTextLesson validates inputs before network call', () {
      expect(
        () => repository.createTextLesson(
          0,
          70,
          title: 'T',
          body: 'B',
          position: 1,
        ),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => repository.createTextLesson(
          42,
          0,
          title: 'T',
          body: 'B',
          position: 1,
        ),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => repository.createTextLesson(
          42,
          70,
          title: '',
          body: 'B',
          position: 1,
        ),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => repository.createTextLesson(
          42,
          70,
          title: 'T',
          body: '',
          position: 1,
        ),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => repository.createTextLesson(
          42,
          70,
          title: 'T',
          body: 'B',
          position: 0,
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('textLessonDetail fetches and parses text lesson detail', () async {
      when(
        () => dio.get(
          '/management/versions/42/modules/70/text-lessons/90/',
          queryParameters: any(named: 'queryParameters'),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer(
        (_) async => Response(
          requestOptions: RequestOptions(
            path: '/management/versions/42/modules/70/text-lessons/90/',
          ),
          statusCode: 200,
          data: managedTextLessonDetailJson(
            id: 90,
            moduleId: 70,
            trainingVersionId: 42,
          ),
        ),
      );

      final lesson = await repository.textLessonDetail(42, 70, 90);
      expect(lesson.id, 90);
      expect(lesson.moduleId, 70);
      expect(lesson.contentType, 'TEXT');
    });

    test(
      'updateTextLesson patches payload and parses updated lesson',
      () async {
        when(
          () => dio.patch(
            '/management/versions/42/modules/70/text-lessons/90/',
            data: {'body': 'Updated instructions.', 'is_required': false},
            cancelToken: any(named: 'cancelToken'),
          ),
        ).thenAnswer(
          (_) async => Response(
            requestOptions: RequestOptions(
              path: '/management/versions/42/modules/70/text-lessons/90/',
            ),
            statusCode: 200,
            data: managedTextLessonDetailJson(
              id: 90,
              moduleId: 70,
              trainingVersionId: 42,
              body: 'Updated instructions.',
              isRequired: false,
            ),
          ),
        );

        final updated = await repository.updateTextLesson(
          42,
          70,
          90,
          body: 'Updated instructions.',
          isRequired: false,
        );

        expect(updated.id, 90);
        expect(updated.body, 'Updated instructions.');
        expect(updated.isRequired, isFalse);
      },
    );

    test('updateTextLesson throws ArgumentError when no fields provided', () {
      expect(
        () => repository.updateTextLesson(42, 70, 90),
        throwsA(isA<ArgumentError>()),
      );
    });

    test(
      'createVideoLesson posts multipart payload and parses lesson detail',
      () async {
        when(
          () => dio.post(
            '/management/versions/42/modules/70/video-lessons/',
            data: any(named: 'data'),
            onSendProgress: any(named: 'onSendProgress'),
            cancelToken: any(named: 'cancelToken'),
          ),
        ).thenAnswer(
          (_) async => Response(
            requestOptions: RequestOptions(
              path: '/management/versions/42/modules/70/video-lessons/',
            ),
            statusCode: 201,
            data: managedVideoLessonDetailJson(
              id: 94,
              moduleId: 70,
              trainingVersionId: 42,
              title: 'Equipment inspection',
              position: 2,
              isRequired: true,
              minimumWatchPercent: '90.00',
              videoDurationSeconds: 69,
              hasVideo: true,
            ),
          ),
        );

        final videoFile = SelectedVideoFile(
          path: '/tmp/test.mp4',
          name: 'test.mp4',
          sizeInBytes: 1024,
          multipartFileFactory: () =>
              MultipartFile.fromBytes([0, 1, 2], filename: 'test.mp4'),
        );

        final lesson = await repository.createVideoLesson(
          42,
          70,
          title: 'Equipment inspection',
          position: 2,
          videoFile: videoFile,
          isRequired: true,
          minimumWatchPercent: 90.0,
        );

        expect(lesson.id, 94);
        expect(lesson.moduleId, 70);
        expect(lesson.trainingVersionId, 42);
        expect(lesson.title, 'Equipment inspection');
        expect(lesson.contentType, 'VIDEO');
        expect(lesson.position, 2);
        expect(lesson.isRequired, isTrue);
        expect(lesson.minimumWatchPercent, '90.00');
        expect(lesson.videoDurationSeconds, 69);
        expect(lesson.hasVideo, isTrue);
      },
    );

    test('createVideoLesson validates inputs before network call', () {
      final validFile = SelectedVideoFile(
        path: '/tmp/test.mp4',
        name: 'test.mp4',
        sizeInBytes: 1024,
      );
      expect(
        () => repository.createVideoLesson(
          0,
          70,
          title: 'T',
          position: 1,
          videoFile: validFile,
        ),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => repository.createVideoLesson(
          42,
          0,
          title: 'T',
          position: 1,
          videoFile: validFile,
        ),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => repository.createVideoLesson(
          42,
          70,
          title: '',
          position: 1,
          videoFile: validFile,
        ),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => repository.createVideoLesson(
          42,
          70,
          title: 'T',
          position: 0,
          videoFile: validFile,
        ),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => repository.createVideoLesson(
          42,
          70,
          title: 'T',
          position: 1,
          videoFile: validFile,
          minimumWatchPercent: 101,
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('videoLessonDetail requests endpoint and parses detail', () async {
      when(
        () => dio.get(
          '/management/versions/42/modules/70/video-lessons/94/',
          queryParameters: any(named: 'queryParameters'),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer(
        (_) async => Response(
          requestOptions: RequestOptions(
            path: '/management/versions/42/modules/70/video-lessons/94/',
          ),
          statusCode: 200,
          data: managedVideoLessonDetailJson(
            id: 94,
            moduleId: 70,
            trainingVersionId: 42,
          ),
        ),
      );

      final lesson = await repository.videoLessonDetail(42, 70, 94);
      expect(lesson.id, 94);
      expect(lesson.moduleId, 70);
      expect(lesson.contentType, 'VIDEO');
    });

    test(
      'updateVideoLesson patches metadata-only and parses updated lesson',
      () async {
        when(
          () => dio.patch(
            '/management/versions/42/modules/70/video-lessons/94/',
            data: {'title': 'Updated Title', 'is_required': false},
            onSendProgress: any(named: 'onSendProgress'),
            cancelToken: any(named: 'cancelToken'),
          ),
        ).thenAnswer(
          (_) async => Response(
            requestOptions: RequestOptions(
              path: '/management/versions/42/modules/70/video-lessons/94/',
            ),
            statusCode: 200,
            data: managedVideoLessonDetailJson(
              id: 94,
              moduleId: 70,
              trainingVersionId: 42,
              title: 'Updated Title',
              isRequired: false,
            ),
          ),
        );

        final updated = await repository.updateVideoLesson(
          42,
          70,
          94,
          title: 'Updated Title',
          isRequired: false,
        );

        expect(updated.id, 94);
        expect(updated.title, 'Updated Title');
        expect(updated.isRequired, isFalse);
      },
    );

    test('updateVideoLesson with replacement file sends multipart', () async {
      when(
        () => dio.patch(
          '/management/versions/42/modules/70/video-lessons/94/',
          data: any(named: 'data'),
          onSendProgress: any(named: 'onSendProgress'),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer(
        (_) async => Response(
          requestOptions: RequestOptions(
            path: '/management/versions/42/modules/70/video-lessons/94/',
          ),
          statusCode: 200,
          data: managedVideoLessonDetailJson(
            id: 94,
            moduleId: 70,
            trainingVersionId: 42,
            videoDurationSeconds: 120,
            hasVideo: true,
          ),
        ),
      );

      final replacement = SelectedVideoFile(
        path: '/tmp/replacement.mp4',
        name: 'replacement.mp4',
        sizeInBytes: 2048,
        multipartFileFactory: () =>
            MultipartFile.fromBytes([3, 4, 5], filename: 'replacement.mp4'),
      );

      final updated = await repository.updateVideoLesson(
        42,
        70,
        94,
        videoFile: replacement,
      );

      expect(updated.id, 94);
      expect(updated.videoDurationSeconds, 120);
      expect(updated.hasVideo, isTrue);
    });

    test('updateVideoLesson throws ArgumentError when no fields provided', () {
      expect(
        () => repository.updateVideoLesson(42, 70, 94),
        throwsA(isA<ArgumentError>()),
      );
    });
  });
}
