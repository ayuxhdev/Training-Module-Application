import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';
import 'package:training_app/core/errors/api_error.dart';
import 'package:training_app/core/network/dio_client.dart';
import 'package:training_app/core/router/app_router.dart';
import 'package:training_app/core/theme/app_theme.dart';
import 'package:training_app/features/auth/domain/models/auth_state.dart';
import 'package:training_app/features/auth/domain/models/authenticated_identity.dart';
import 'package:training_app/features/auth/presentation/controllers/auth_controller.dart';
import 'package:training_app/features/management/data/repositories/management_repository.dart';
import 'package:training_app/features/management/domain/models/management_models.dart';
import 'package:training_app/features/management/presentation/controllers/management_controller.dart';
import 'package:training_app/features/management/presentation/screens/role_requirements_screen.dart';
import 'package:training_app/features/notifications/presentation/controllers/notification_controller.dart';

import 'management_fixtures.dart';

class ClientMock extends Mock implements ApiClient {}

class DioMock extends Mock implements Dio {}

class MockManagementRepository extends Mock implements ManagementRepository {}

class ZeroUnread extends NotificationUnreadController {
  @override
  Future<int?> build() async => 0;
}

void main() {
  setUpAll(() {
    registerFallbackValue(CancelToken());
    registerFallbackValue(ReferenceKind.jobRoles);
    registerFallbackValue(RoleRequirementOptionKind.jobRoles);
  });

  group('Role Training Requirement Models - Finding 4 Strict Parsing', () {
    test('RoleTrainingRequirement.fromJson parses valid json correctly', () {
      final json = roleTrainingRequirementJson(
        id: 42,
        jobRoleId: 3,
        jobRoleCode: 'ELEC',
        jobRoleName: 'Electrician',
        trainingVersionId: 7,
        trainingId: 2,
        trainingTitle: 'High Voltage Safety',
        versionTitle: 'V1 Revised',
        versionNumber: 2,
        versionStatus: 'PUBLISHED',
        dueInDays: 45,
        isActive: true,
        createdAt: '2025-02-01T10:00:00Z',
        updatedAt: '2025-02-02T12:00:00Z',
      );

      final req = RoleTrainingRequirement.fromJson(json);

      expect(req.id, 42);
      expect(req.jobRoleId, 3);
      expect(req.jobRoleCode, 'ELEC');
      expect(req.jobRoleName, 'Electrician');
      expect(req.trainingVersionId, 7);
      expect(req.trainingId, 2);
      expect(req.trainingTitle, 'High Voltage Safety');
      expect(req.versionTitle, 'V1 Revised');
      expect(req.versionNumber, 2);
      expect(req.versionStatus, 'PUBLISHED');
      expect(req.dueInDays, 45);
      expect(req.isActive, isTrue);
      expect(req.isPublished, isTrue);
      expect(req.isRetired, isFalse);
      expect(req.createdAt, DateTime.parse('2025-02-01T10:00:00Z'));
      expect(req.updatedAt, DateTime.parse('2025-02-02T12:00:00Z'));
    });

    test('RoleTrainingRequirement recognizes retired status', () {
      final json = roleTrainingRequirementJson(versionStatus: 'RETIRED');
      final req = RoleTrainingRequirement.fromJson(json);

      expect(req.isPublished, isFalse);
      expect(req.isRetired, isTrue);
    });

    test(
      'RoleTrainingRequirement fails safely when required fields are missing',
      () {
        final base = roleTrainingRequirementJson();

        for (final field in [
          'id',
          'job_role_id',
          'job_role_code',
          'job_role_name',
          'training_version_id',
          'training_id',
          'training_title',
          'version_title',
          'version_number',
          'version_status',
          'due_in_days',
          'is_active',
          'created_at',
          'updated_at',
        ]) {
          final missing = Map<String, dynamic>.from(base)..remove(field);
          expect(
            () => RoleTrainingRequirement.fromJson(missing),
            throwsA(isA<FormatException>()),
            reason: 'Expected FormatException when $field is missing',
          );
        }
      },
    );

    test('RoleTrainingRequirement fails safely when required fields have wrong types or invalid values', () {
      final base = roleTrainingRequirementJson();

      // Wrong type for version_number (string or null or 0)
      expect(
        () => RoleTrainingRequirement.fromJson(
          Map<String, dynamic>.from(base)..['version_number'] = '1',
        ),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => RoleTrainingRequirement.fromJson(
          Map<String, dynamic>.from(base)..['version_number'] = 0,
        ),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => RoleTrainingRequirement.fromJson(
          Map<String, dynamic>.from(base)..['version_number'] = -1,
        ),
        throwsA(isA<FormatException>()),
      );

      // Wrong type for version_status (empty or wrong type or whitespace)
      expect(
        () => RoleTrainingRequirement.fromJson(
          Map<String, dynamic>.from(base)..['version_status'] = '',
        ),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => RoleTrainingRequirement.fromJson(
          Map<String, dynamic>.from(base)..['version_status'] = 123,
        ),
        throwsA(isA<FormatException>()),
      );

      // Wrong type or negative for due_in_days
      expect(
        () => RoleTrainingRequirement.fromJson(
          Map<String, dynamic>.from(base)..['due_in_days'] = -5,
        ),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => RoleTrainingRequirement.fromJson(
          Map<String, dynamic>.from(base)..['due_in_days'] = '30',
        ),
        throwsA(isA<FormatException>()),
      );

      // Wrong type for is_active
      expect(
        () => RoleTrainingRequirement.fromJson(
          Map<String, dynamic>.from(base)..['is_active'] = 'true',
        ),
        throwsA(isA<FormatException>()),
      );

      // Invalid timestamp
      expect(
        () => RoleTrainingRequirement.fromJson(
          Map<String, dynamic>.from(base)..['created_at'] = 'invalid-date',
        ),
        throwsA(isA<FormatException>()),
      );
    });

    test('RoleBatchResult.fromJson parses batch execution counts', () {
      final json = roleBatchResultJson(
        roleRequirementId: 10,
        jobRoleId: 2,
        trainingVersionId: 4,
        createdCount: 8,
        skippedCount: 3,
      );

      final result = RoleBatchResult.fromJson(json);

      expect(result.roleRequirementId, 10);
      expect(result.jobRoleId, 2);
      expect(result.trainingVersionId, 4);
      expect(result.createdCount, 8);
      expect(result.skippedCount, 3);
      expect(result.totalTargets, 11);
    });

    test('RoleBatchResult fails safely on missing or invalid counts', () {
      final base = roleBatchResultJson();

      for (final field in [
        'job_role_id',
        'training_version_id',
        'created_count',
        'skipped_count',
      ]) {
        final missing = Map<String, dynamic>.from(base)..remove(field);
        expect(
          () => RoleBatchResult.fromJson(missing),
          throwsA(isA<FormatException>()),
          reason: 'Expected FormatException when $field is missing',
        );
      }

      expect(
        () => RoleBatchResult.fromJson(
          Map<String, dynamic>.from(base)..['created_count'] = -1,
        ),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => RoleBatchResult.fromJson(
          Map<String, dynamic>.from(base)..['skipped_count'] = -1,
        ),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => RoleBatchResult.fromJson(
          Map<String, dynamic>.from(base)..['role_requirement_id'] = 0,
        ),
        throwsA(isA<FormatException>()),
      );
    });

    test('RoleRequirementOption.fromJson parses valid json correctly', () {
      final json = {'id': 8, 'label': 'Electrician'};
      final option = RoleRequirementOption.fromJson(json);
      expect(option.id, 8);
      expect(option.label, 'Electrician');
      expect(
        option,
        equals(const RoleRequirementOption(id: 8, label: 'Electrician')),
      );
      expect(option.hashCode, isA<int>());
      expect(option.toString(), contains('Electrician'));
    });

    test('RoleRequirementOption.fromJson fails safely on missing or invalid fields', () {
      expect(
        () => RoleRequirementOption.fromJson({'label': 'Electrician'}),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => RoleRequirementOption.fromJson({'id': 0, 'label': 'Electrician'}),
        throwsA(isA<FormatException>()),
      );
      expect(
        () =>
            RoleRequirementOption.fromJson({'id': -1, 'label': 'Electrician'}),
        throwsA(isA<FormatException>()),
      );
      expect(
        () =>
            RoleRequirementOption.fromJson({'id': '8', 'label': 'Electrician'}),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => RoleRequirementOption.fromJson({'id': 8}),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => RoleRequirementOption.fromJson({'id': 8, 'label': ''}),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => RoleRequirementOption.fromJson({'id': 8, 'label': '   '}),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => RoleRequirementOption.fromJson({'id': 8, 'label': 123}),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('ManagementRepository Role Requirements API', () {
    late ClientMock client;
    late DioMock dio;
    late ManagementRepository repository;

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

    test('roleRequirements rejects invalid argument values', () {
      expect(
        () => repository.roleRequirements(jobRoleId: 0),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => repository.roleRequirements(jobRoleId: -5),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => repository.roleRequirements(trainingVersionId: 0),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => repository.roleRequirements(trainingVersionId: -1),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => repository.roleRequirements(page: 0),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => repository.roleRequirements(pageSize: 101),
        throwsA(isA<ArgumentError>()),
      );
    });

    test(
      'roleRequirements sends correct parameters and parses results',
      () async {
        when(
          () => dio.get(
            '/management/role-requirements/',
            queryParameters: any(named: 'queryParameters'),
            cancelToken: any(named: 'cancelToken'),
          ),
        ).thenAnswer(
          (_) async => Response(
            requestOptions: RequestOptions(
              path: '/management/role-requirements/',
            ),
            data: pageJson([
              roleTrainingRequirementJson(id: 1, jobRoleName: 'Operator'),
              roleTrainingRequirementJson(id: 2, jobRoleName: 'Supervisor'),
            ]),
          ),
        );

        final result = await repository.roleRequirements(
          page: 1,
          pageSize: 10,
          search: 'Operator',
          jobRoleId: 1,
          trainingVersionId: 10,
          isActive: true,
        );

        expect(result.count, 2);
        expect(result.items.length, 2);
        expect(result.items.first.jobRoleName, 'Operator');

        final captured =
            verify(
                  () => dio.get(
                    '/management/role-requirements/',
                    queryParameters: captureAny(named: 'queryParameters'),
                    cancelToken: any(named: 'cancelToken'),
                  ),
                ).captured.single
                as Map<String, dynamic>;

        expect(captured['page_size'], 10);
        expect(captured['search'], 'Operator');
        expect(captured['job_role_id'], 1);
        expect(captured['training_version_id'], 10);
        expect(captured['is_active'], isTrue);
      },
    );

    test('roleRequirement fetches single item by ID', () async {
      when(
        () => dio.get(
          '/management/role-requirements/15/',
          queryParameters: any(named: 'queryParameters'),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer(
        (_) async => Response(
          requestOptions: RequestOptions(
            path: '/management/role-requirements/15/',
          ),
          data: roleTrainingRequirementJson(id: 15, jobRoleName: 'Lead'),
        ),
      );

      final result = await repository.roleRequirement(15);
      expect(result.id, 15);
      expect(result.jobRoleName, 'Lead');

      expect(
        () => repository.roleRequirement(0),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('createRoleRequirement validates and posts payload', () async {
      expect(
        () => repository.createRoleRequirement(
          jobRoleId: 0,
          trainingVersionId: 1,
        ),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => repository.createRoleRequirement(
          jobRoleId: 1,
          trainingVersionId: -1,
        ),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => repository.createRoleRequirement(
          jobRoleId: 1,
          trainingVersionId: 1,
          dueInDays: -5,
        ),
        throwsA(isA<ArgumentError>()),
      );

      when(
        () => dio.post(
          '/management/role-requirements/',
          data: any(named: 'data'),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer(
        (_) async => Response(
          requestOptions: RequestOptions(
            path: '/management/role-requirements/',
          ),
          statusCode: 201,
          data: roleTrainingRequirementJson(
            id: 99,
            jobRoleId: 4,
            trainingVersionId: 12,
            dueInDays: 60,
            isActive: true,
          ),
        ),
      );

      final created = await repository.createRoleRequirement(
        jobRoleId: 4,
        trainingVersionId: 12,
        dueInDays: 60,
        isActive: true,
      );

      expect(created.id, 99);
      expect(created.dueInDays, 60);

      final captured =
          verify(
                () => dio.post(
                  '/management/role-requirements/',
                  data: captureAny(named: 'data'),
                  cancelToken: any(named: 'cancelToken'),
                ),
              ).captured.single
              as Map<String, dynamic>;

      expect(captured['job_role_id'], 4);
      expect(captured['training_version_id'], 12);
      expect(captured['due_in_days'], 60);
      expect(captured['is_active'], isTrue);
    });

    test('updateRoleRequirement validates and patches payload', () async {
      expect(
        () => repository.updateRoleRequirement(id: 0),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => repository.updateRoleRequirement(id: 1, dueInDays: -1),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => repository.updateRoleRequirement(id: 1),
        throwsA(isA<ArgumentError>()),
      );

      when(
        () => dio.patch(
          '/management/role-requirements/22/',
          data: any(named: 'data'),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer(
        (_) async => Response(
          requestOptions: RequestOptions(
            path: '/management/role-requirements/22/',
          ),
          statusCode: 200,
          data: roleTrainingRequirementJson(
            id: 22,
            isActive: false,
            dueInDays: 14,
          ),
        ),
      );

      final updated = await repository.updateRoleRequirement(
        id: 22,
        isActive: false,
        dueInDays: 14,
      );

      expect(updated.id, 22);
      expect(updated.isActive, isFalse);
      expect(updated.dueInDays, 14);

      final captured =
          verify(
                () => dio.patch(
                  '/management/role-requirements/22/',
                  data: captureAny(named: 'data'),
                  cancelToken: any(named: 'cancelToken'),
                ),
              ).captured.single
              as Map<String, dynamic>;

      expect(captured['is_active'], isFalse);
      expect(captured['due_in_days'], 14);
    });

    test(
      'executeRoleBatchAssignment executes POST and parses result',
      () async {
        expect(
          () => repository.executeRoleBatchAssignment(0),
          throwsA(isA<ArgumentError>()),
        );

        when(
          () => dio.post(
            '/management/role-requirements/5/assignments/',
            data: any(named: 'data'),
            cancelToken: any(named: 'cancelToken'),
          ),
        ).thenAnswer(
          (_) async => Response(
            requestOptions: RequestOptions(
              path: '/management/role-requirements/5/assignments/',
            ),
            statusCode: 200,
            data: roleBatchResultJson(
              roleRequirementId: 5,
              createdCount: 4,
              skippedCount: 1,
            ),
          ),
        );

        final result = await repository.executeRoleBatchAssignment(5);

        expect(result.roleRequirementId, 5);
        expect(result.createdCount, 4);
        expect(result.skippedCount, 1);
      },
    );

    test('allPublishedTrainingVersions paginates through all pages without truncation', () async {
      var callCount = 0;
      when(
        () => dio.get(
          '/management/versions/',
          queryParameters: any(named: 'queryParameters'),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer((_) async {
        callCount++;
        if (callCount == 1) {
          return Response(
            requestOptions: RequestOptions(path: '/management/versions/'),
            data: pageJson(
              [
                {
                  'id': 1,
                  'training_id': 1,
                  'training_title': 'Course A',
                  'version_number': 1,
                  'title': 'V1',
                  'status': 'PUBLISHED',
                },
              ],
              count: 2,
              next: '/management/versions/?page=2',
            ),
          );
        } else {
          return Response(
            requestOptions: RequestOptions(path: '/management/versions/'),
            data: pageJson(
              [
                {
                  'id': 2,
                  'training_id': 2,
                  'training_title': 'Course B',
                  'version_number': 1,
                  'title': 'V1',
                  'status': 'PUBLISHED',
                },
              ],
              count: 2,
              next: null,
            ),
          );
        }
      });

      final versions = await repository.allPublishedTrainingVersions(
        canViewVersionsPermission: true,
        canAssignTrainingPermission: false,
      );

      expect(versions.length, 2);
      expect(versions[0].id, 1);
      expect(versions[1].id, 2);
      expect(callCount, 2);
    });

    test(
      'allPublishedTrainingVersions throws 403 when neither permission is held',
      () async {
        expect(
          () => repository.allPublishedTrainingVersions(
            canViewVersionsPermission: false,
            canAssignTrainingPermission: false,
          ),
          throwsA(
            isA<ApiError>().having((e) => e.statusCode, 'statusCode', 403),
          ),
        );
      },
    );

    group('roleRequirementCreationOptions API', () {
      test('rejects invalid pagination arguments', () {
        expect(
          () => repository.roleRequirementCreationOptions(
            kind: RoleRequirementOptionKind.jobRoles,
            page: 0,
          ),
          throwsA(isA<ArgumentError>()),
        );
        expect(
          () => repository.roleRequirementCreationOptions(
            kind: RoleRequirementOptionKind.jobRoles,
            pageSize: 0,
          ),
          throwsA(isA<ArgumentError>()),
        );
        expect(
          () => repository.roleRequirementCreationOptions(
            kind: RoleRequirementOptionKind.jobRoles,
            pageSize: 101,
          ),
          throwsA(isA<ArgumentError>()),
        );
      });

      test('sends kind=job_roles and parses paginated results', () async {
        when(
          () => dio.get(
            '/management/role-requirements/creation-options/',
            queryParameters: any(named: 'queryParameters'),
            cancelToken: any(named: 'cancelToken'),
          ),
        ).thenAnswer(
          (_) async => Response(
            requestOptions: RequestOptions(
              path: '/management/role-requirements/creation-options/',
            ),
            data: pageJson([
              {'id': 1, 'label': 'Operator'},
              {'id': 2, 'label': 'Electrician'},
            ], count: 2),
          ),
        );

        final result = await repository.roleRequirementCreationOptions(
          kind: RoleRequirementOptionKind.jobRoles,
          page: 1,
          pageSize: 20,
        );

        expect(result.count, 2);
        expect(result.items.length, 2);
        expect(result.items.first.id, 1);
        expect(result.items.first.label, 'Operator');
        expect(result.items.last.id, 2);
        expect(result.items.last.label, 'Electrician');

        final captured =
            verify(
                  () => dio.get(
                    '/management/role-requirements/creation-options/',
                    queryParameters: captureAny(named: 'queryParameters'),
                    cancelToken: any(named: 'cancelToken'),
                  ),
                ).captured.single
                as Map<String, dynamic>;

        expect(captured['kind'], 'job_roles');
        expect(captured['page_size'], 20);
      });

      test(
        'sends kind=training_versions and parses paginated results',
        () async {
          when(
            () => dio.get(
              '/management/role-requirements/creation-options/',
              queryParameters: any(named: 'queryParameters'),
              cancelToken: any(named: 'cancelToken'),
            ),
          ).thenAnswer(
            (_) async => Response(
              requestOptions: RequestOptions(
                path: '/management/role-requirements/creation-options/',
              ),
              data: pageJson([
                {'id': 10, 'label': 'Safety — Version 1 (v1)'},
              ], count: 1),
            ),
          );

          final result = await repository.roleRequirementCreationOptions(
            kind: RoleRequirementOptionKind.trainingVersions,
            page: 1,
            pageSize: 20,
          );

          expect(result.count, 1);
          expect(result.items.single.id, 10);
          expect(result.items.single.label, 'Safety — Version 1 (v1)');

          final captured =
              verify(
                    () => dio.get(
                      '/management/role-requirements/creation-options/',
                      queryParameters: captureAny(named: 'queryParameters'),
                      cancelToken: any(named: 'cancelToken'),
                    ),
                  ).captured.single
                  as Map<String, dynamic>;

          expect(captured['kind'], 'training_versions');
          expect(captured['page_size'], 20);
        },
      );
    });

    group('allRoleRequirementCreationOptions pagination', () {
      test(
        'paginates through multiple pages until next is null for job_roles',
        () async {
          var pageCall = 0;
          when(
            () => dio.get(
              '/management/role-requirements/creation-options/',
              queryParameters: any(named: 'queryParameters'),
              cancelToken: any(named: 'cancelToken'),
            ),
          ).thenAnswer((_) async {
            pageCall++;
            if (pageCall == 1) {
              return Response(
                requestOptions: RequestOptions(
                  path: '/management/role-requirements/creation-options/',
                ),
                data: pageJson(
                  [
                    {'id': 1, 'label': 'Operator'},
                    {'id': 2, 'label': 'Electrician'},
                  ],
                  count: 3,
                  next: '/management/role-requirements/creation-options/?kind=job_roles&page=2',
                ),
              );
            } else {
              return Response(
                requestOptions: RequestOptions(
                  path: '/management/role-requirements/creation-options/',
                ),
                data: pageJson(
                  [
                    {'id': 3, 'label': 'Mechanic'},
                  ],
                  count: 3,
                  next: null,
                ),
              );
            }
          });

          final results = await repository.allRoleRequirementCreationOptions(
            kind: RoleRequirementOptionKind.jobRoles,
          );

          expect(results.length, 3);
          expect(results.map((r) => r.id), [1, 2, 3]);
          expect(pageCall, 2);
        },
      );

      test('paginates through multiple pages until next is null for training_versions', () async {
        var pageCall = 0;
        when(
          () => dio.get(
            '/management/role-requirements/creation-options/',
            queryParameters: any(named: 'queryParameters'),
            cancelToken: any(named: 'cancelToken'),
          ),
        ).thenAnswer((_) async {
          pageCall++;
          if (pageCall == 1) {
            return Response(
              requestOptions: RequestOptions(
                path: '/management/role-requirements/creation-options/',
              ),
              data: pageJson(
                [
                  {'id': 10, 'label': 'Safety — V1 (v1)'},
                ],
                count: 2,
                next: '/management/role-requirements/creation-options/?kind=training_versions&page=2',
              ),
            );
          } else {
            return Response(
              requestOptions: RequestOptions(
                path: '/management/role-requirements/creation-options/',
              ),
              data: pageJson(
                [
                  {'id': 20, 'label': 'Security — V1 (v1)'},
                ],
                count: 2,
                next: null,
              ),
            );
          }
        });

        final results = await repository.allRoleRequirementCreationOptions(
          kind: RoleRequirementOptionKind.trainingVersions,
        );

        expect(results.length, 2);
        expect(results[0].id, 10);
        expect(results[1].id, 20);
        expect(pageCall, 2);
      });

      test('succeeds when reaching exactly maxPages (50) and hasMore is false', () async {
        var pageCall = 0;
        when(
          () => dio.get(
            '/management/role-requirements/creation-options/',
            queryParameters: any(named: 'queryParameters'),
            cancelToken: any(named: 'cancelToken'),
          ),
        ).thenAnswer((_) async {
          pageCall++;
          return Response(
            requestOptions: RequestOptions(
              path: '/management/role-requirements/creation-options/',
            ),
            data: pageJson(
              [
                {'id': pageCall, 'label': 'Option $pageCall'},
              ],
              count: 50,
              next: pageCall < 50
                  ? '/management/role-requirements/creation-options/?page=${pageCall + 1}'
                  : null,
            ),
          );
        });

        final results = await repository.allRoleRequirementCreationOptions(
          kind: RoleRequirementOptionKind.jobRoles,
          maxPages: 50,
        );
        expect(results.length, 50);
        expect(pageCall, 50);
      });

      test('fails closed with incomplete_pagination when maxPages reached but hasMore is true', () async {
        var pageCall = 0;
        when(
          () => dio.get(
            '/management/role-requirements/creation-options/',
            queryParameters: any(named: 'queryParameters'),
            cancelToken: any(named: 'cancelToken'),
          ),
        ).thenAnswer((_) async {
          pageCall++;
          return Response(
            requestOptions: RequestOptions(
              path: '/management/role-requirements/creation-options/',
            ),
            data: pageJson(
              [
                {'id': pageCall, 'label': 'Option $pageCall'},
              ],
              count: 100,
              next:
                  '/management/role-requirements/creation-options/?page=${pageCall + 1}',
            ),
          );
        });

        expect(
          () => repository.allRoleRequirementCreationOptions(
            kind: RoleRequirementOptionKind.jobRoles,
            maxPages: 50,
          ),
          throwsA(
            isA<ApiError>().having(
              (e) => e.code,
              'code',
              'incomplete_pagination',
            ),
          ),
        );
      });

      test('fails closed with incomplete_pagination when duplicate IDs appear in options', () async {
        when(
          () => dio.get(
            '/management/role-requirements/creation-options/',
            queryParameters: any(named: 'queryParameters'),
            cancelToken: any(named: 'cancelToken'),
          ),
        ).thenAnswer((_) async {
          return Response(
            requestOptions: RequestOptions(
              path: '/management/role-requirements/creation-options/',
            ),
            data: pageJson(
              [
                {'id': 1, 'label': 'Duplicate Option'},
                {'id': 1, 'label': 'Duplicate Option'},
              ],
              count: 2,
              next: null,
            ),
          );
        });

        expect(
          () => repository.allRoleRequirementCreationOptions(
            kind: RoleRequirementOptionKind.jobRoles,
          ),
          throwsA(
            isA<ApiError>().having(
              (e) => e.code,
              'code',
              'incomplete_pagination',
            ),
          ),
        );
      });

      test('fails closed with incomplete_pagination when total count does not match expected items', () async {
        when(
          () => dio.get(
            '/management/role-requirements/creation-options/',
            queryParameters: any(named: 'queryParameters'),
            cancelToken: any(named: 'cancelToken'),
          ),
        ).thenAnswer((_) async {
          return Response(
            requestOptions: RequestOptions(
              path: '/management/role-requirements/creation-options/',
            ),
            data: pageJson(
              [
                {'id': 1, 'label': 'Option 1'},
              ],
              count: 5,
              next: null,
            ),
          );
        });

        expect(
          () => repository.allRoleRequirementCreationOptions(
            kind: RoleRequirementOptionKind.jobRoles,
          ),
          throwsA(
            isA<ApiError>().having(
              (e) => e.code,
              'code',
              'incomplete_pagination',
            ),
          ),
        );
      });
    });

    group('allAssignableTrainingVersions pagination', () {
      test('paginates through multiple pages successfully', () async {
        var pageCall = 0;
        when(
          () => dio.get(
            '/management/training-versions/',
            queryParameters: any(named: 'queryParameters'),
            cancelToken: any(named: 'cancelToken'),
          ),
        ).thenAnswer((_) async {
          pageCall++;
          if (pageCall == 1) {
            return Response(
              requestOptions: RequestOptions(
                path: '/management/training-versions/',
              ),
              data: pageJson(
                [assignableVersionJson(1, trainingTitle: 'Course 1')],
                count: 2,
                next: '/management/training-versions/?page=2',
              ),
            );
          } else {
            return Response(
              requestOptions: RequestOptions(
                path: '/management/training-versions/',
              ),
              data: pageJson(
                [assignableVersionJson(2, trainingTitle: 'Course 2')],
                count: 2,
                next: null,
              ),
            );
          }
        });

        final results = await repository.allAssignableTrainingVersions();
        expect(results.length, 2);
        expect(results[0].id, 1);
        expect(results[1].id, 2);
        expect(pageCall, 2);
      });

      test(
        'succeeds when reaching exactly maxPages (50) and hasMore is false',
        () async {
          var pageCall = 0;
          when(
            () => dio.get(
              '/management/training-versions/',
              queryParameters: any(named: 'queryParameters'),
              cancelToken: any(named: 'cancelToken'),
            ),
          ).thenAnswer((_) async {
            pageCall++;
            return Response(
              requestOptions: RequestOptions(
                path: '/management/training-versions/',
              ),
              data: pageJson(
                [
                  assignableVersionJson(
                    pageCall,
                    trainingTitle: 'Course $pageCall',
                  ),
                ],
                count: 50,
                next: pageCall < 50
                    ? '/management/training-versions/?page=${pageCall + 1}'
                    : null,
              ),
            );
          });

          final results = await repository.allAssignableTrainingVersions(
            maxPages: 50,
          );
          expect(results.length, 50);
          expect(pageCall, 50);
        },
      );

      test('fails closed with incomplete_pagination when maxPages reached but hasMore is true', () async {
        var pageCall = 0;
        when(
          () => dio.get(
            '/management/training-versions/',
            queryParameters: any(named: 'queryParameters'),
            cancelToken: any(named: 'cancelToken'),
          ),
        ).thenAnswer((_) async {
          pageCall++;
          return Response(
            requestOptions: RequestOptions(
              path: '/management/training-versions/',
            ),
            data: pageJson(
              [
                assignableVersionJson(
                  pageCall,
                  trainingTitle: 'Course $pageCall',
                ),
              ],
              count: 100,
              next: '/management/training-versions/?page=${pageCall + 1}',
            ),
          );
        });

        expect(
          () => repository.allAssignableTrainingVersions(maxPages: 50),
          throwsA(
            isA<ApiError>().having(
              (e) => e.code,
              'code',
              'incomplete_pagination',
            ),
          ),
        );
      });

      test('fails closed with incomplete_pagination when duplicate items produce loop', () async {
        when(
          () => dio.get(
            '/management/training-versions/',
            queryParameters: any(named: 'queryParameters'),
            cancelToken: any(named: 'cancelToken'),
          ),
        ).thenAnswer((_) async {
          return Response(
            requestOptions: RequestOptions(
              path: '/management/training-versions/',
            ),
            data: pageJson(
              [assignableVersionJson(1, trainingTitle: 'Same Course')],
              count: 10,
              next: '/management/training-versions/?page=2',
            ),
          );
        });

        expect(
          () => repository.allAssignableTrainingVersions(),
          throwsA(
            isA<ApiError>().having(
              (e) => e.code,
              'code',
              'incomplete_pagination',
            ),
          ),
        );
      });

      test('fails closed with incomplete_pagination when total count does not match expected items', () async {
        when(
          () => dio.get(
            '/management/training-versions/',
            queryParameters: any(named: 'queryParameters'),
            cancelToken: any(named: 'cancelToken'),
          ),
        ).thenAnswer((_) async {
          return Response(
            requestOptions: RequestOptions(
              path: '/management/training-versions/',
            ),
            data: pageJson([assignableVersionJson(1)], count: 5, next: null),
          );
        });

        expect(
          () => repository.allAssignableTrainingVersions(),
          throwsA(
            isA<ApiError>().having(
              (e) => e.code,
              'code',
              'incomplete_pagination',
            ),
          ),
        );
      });
    });

    group('allPublishedVersionsFromDiscovery pagination', () {
      test('filters DRAFT and RETIRED items while validating raw item count without false truncation failure', () async {
        var pageCall = 0;
        when(
          () => dio.get(
            '/management/versions/',
            queryParameters: any(named: 'queryParameters'),
            cancelToken: any(named: 'cancelToken'),
          ),
        ).thenAnswer((_) async {
          pageCall++;
          if (pageCall == 1) {
            return Response(
              requestOptions: RequestOptions(path: '/management/versions/'),
              data: pageJson(
                [
                  {
                    'id': 1,
                    'training_id': 1,
                    'training_title': 'Draft Course',
                    'version_number': 1,
                    'title': 'V1',
                    'status': 'DRAFT',
                  },
                  {
                    'id': 2,
                    'training_id': 2,
                    'training_title': 'Published Course A',
                    'version_number': 1,
                    'title': 'V1',
                    'status': 'PUBLISHED',
                  },
                ],
                count: 3,
                next: '/management/versions/?page=2',
              ),
            );
          } else {
            return Response(
              requestOptions: RequestOptions(path: '/management/versions/'),
              data: pageJson(
                [
                  {
                    'id': 3,
                    'training_id': 3,
                    'training_title': 'Retired Course',
                    'version_number': 1,
                    'title': 'V1',
                    'status': 'RETIRED',
                  },
                ],
                count: 3,
                next: null,
              ),
            );
          }
        });

        final results = await repository.allPublishedVersionsFromDiscovery();
        expect(results.length, 1);
        expect(results[0].id, 2);
        expect(results[0].trainingTitle, 'Published Course A');
        expect(pageCall, 2);
      });

      test('succeeds at exactly maxPages (50) when hasMore is false', () async {
        var pageCall = 0;
        when(
          () => dio.get(
            '/management/versions/',
            queryParameters: any(named: 'queryParameters'),
            cancelToken: any(named: 'cancelToken'),
          ),
        ).thenAnswer((_) async {
          pageCall++;
          return Response(
            requestOptions: RequestOptions(path: '/management/versions/'),
            data: pageJson(
              [
                {
                  'id': pageCall,
                  'training_id': pageCall,
                  'training_title': 'Course $pageCall',
                  'version_number': 1,
                  'title': 'V1',
                  'status': 'PUBLISHED',
                },
              ],
              count: 50,
              next: pageCall < 50
                  ? '/management/versions/?page=${pageCall + 1}'
                  : null,
            ),
          );
        });

        final results = await repository.allPublishedVersionsFromDiscovery(
          maxPages: 50,
        );
        expect(results.length, 50);
        expect(pageCall, 50);
      });

      test('fails closed with incomplete_pagination when maxPages reached but hasMore is true', () async {
        var pageCall = 0;
        when(
          () => dio.get(
            '/management/versions/',
            queryParameters: any(named: 'queryParameters'),
            cancelToken: any(named: 'cancelToken'),
          ),
        ).thenAnswer((_) async {
          pageCall++;
          return Response(
            requestOptions: RequestOptions(path: '/management/versions/'),
            data: pageJson(
              [
                {
                  'id': pageCall,
                  'training_id': pageCall,
                  'training_title': 'Course $pageCall',
                  'version_number': 1,
                  'title': 'V1',
                  'status': 'PUBLISHED',
                },
              ],
              count: 100,
              next: '/management/versions/?page=${pageCall + 1}',
            ),
          );
        });

        expect(
          () => repository.allPublishedVersionsFromDiscovery(maxPages: 50),
          throwsA(
            isA<ApiError>().having(
              (e) => e.code,
              'code',
              'incomplete_pagination',
            ),
          ),
        );
      });

      test('fails closed with incomplete_pagination when seen raw IDs is less than expectedCount', () async {
        when(
          () => dio.get(
            '/management/versions/',
            queryParameters: any(named: 'queryParameters'),
            cancelToken: any(named: 'cancelToken'),
          ),
        ).thenAnswer((_) async {
          return Response(
            requestOptions: RequestOptions(path: '/management/versions/'),
            data: pageJson(
              [
                {
                  'id': 1,
                  'training_id': 1,
                  'training_title': 'Course 1',
                  'version_number': 1,
                  'title': 'V1',
                  'status': 'PUBLISHED',
                },
              ],
              count: 5,
              next: null,
            ),
          );
        });

        expect(
          () => repository.allPublishedVersionsFromDiscovery(),
          throwsA(
            isA<ApiError>().having(
              (e) => e.code,
              'code',
              'incomplete_pagination',
            ),
          ),
        );
      });

      test('fails closed with incomplete_pagination when duplicate raw items produce loop in discovery', () async {
        when(
          () => dio.get(
            '/management/versions/',
            queryParameters: any(named: 'queryParameters'),
            cancelToken: any(named: 'cancelToken'),
          ),
        ).thenAnswer((_) async {
          return Response(
            requestOptions: RequestOptions(path: '/management/versions/'),
            data: pageJson(
              [
                {
                  'id': 1,
                  'training_id': 1,
                  'training_title': 'Draft Course',
                  'version_number': 1,
                  'title': 'V1',
                  'status': 'DRAFT',
                },
              ],
              count: 10,
              next: '/management/versions/?page=2',
            ),
          );
        });

        expect(
          () => repository.allPublishedVersionsFromDiscovery(),
          throwsA(
            isA<ApiError>().having(
              (e) => e.code,
              'code',
              'incomplete_pagination',
            ),
          ),
        );
      });
    });
  });

  group('RoleRequirementMutationController Permissions', () {
    late MockManagementRepository mockRepo;

    setUp(() {
      mockRepo = MockManagementRepository();
    });

    test(
      'create rejects when missing training.add_roletrainingrequirement',
      () async {
        final controller = RoleRequirementMutationController(
          repository: mockRepo,
          readAuth: () => AuthAuthenticated.identity(
            managementIdentity(capabilities: {'management_workspace'}),
          ),
        );

        expect(
          () => controller.create(jobRoleId: 1, trainingVersionId: 1),
          throwsA(
            isA<ApiError>().having((e) => e.statusCode, 'statusCode', 403),
          ),
        );
      },
    );

    test(
      'update rejects when missing training.change_roletrainingrequirement',
      () async {
        final controller = RoleRequirementMutationController(
          repository: mockRepo,
          readAuth: () => AuthAuthenticated.identity(
            managementIdentity(capabilities: {'management_workspace'}),
          ),
        );

        expect(
          () => controller.update(id: 1, isActive: false),
          throwsA(
            isA<ApiError>().having((e) => e.statusCode, 'statusCode', 403),
          ),
        );
      },
    );

    test(
      'executeBatch rejects when missing training.add_trainingassignment',
      () async {
        final controller = RoleRequirementMutationController(
          repository: mockRepo,
          readAuth: () => AuthAuthenticated.identity(
            managementIdentity(capabilities: {'management_workspace'}),
          ),
        );

        expect(
          () => controller.executeBatch(id: 1),
          throwsA(
            isA<ApiError>().having((e) => e.statusCode, 'statusCode', 403),
          ),
        );
      },
    );
  });

  group('RoleRequirementsScreen UI & Widget Tests', () {
    late MockManagementRepository repository;
    late ManagementTestAuth auth;
    late GoRouter router;

    setUp(() {
      repository = MockManagementRepository();

      when(
        () => repository.roleRequirements(
          page: any(named: 'page'),
          pageSize: any(named: 'pageSize'),
          search: any(named: 'search'),
          jobRoleId: any(named: 'jobRoleId'),
          trainingVersionId: any(named: 'trainingVersionId'),
          isActive: any(named: 'isActive'),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer(
        (_) async => ManagementPage<RoleTrainingRequirement>(
          count: 1,
          hasMore: false,
          items: [
            RoleTrainingRequirement.fromJson(
              roleTrainingRequirementJson(
                id: 1,
                jobRoleCode: 'OP',
                jobRoleName: 'Operator',
                trainingTitle: 'Safety in Operations',
                versionNumber: 1,
                dueInDays: 30,
                isActive: true,
              ),
            ),
          ],
        ),
      );

      when(
        () => repository.allRoleRequirementCreationOptions(
          kind: RoleRequirementOptionKind.jobRoles,
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer(
        (_) async => [
          const RoleRequirementOption(id: 1, label: 'Operator (OP)'),
          const RoleRequirementOption(id: 2, label: 'Engineer (ENG)'),
        ],
      );

      when(
        () => repository.allRoleRequirementCreationOptions(
          kind: RoleRequirementOptionKind.trainingVersions,
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer(
        (_) async => [
          const RoleRequirementOption(
            id: 10,
            label: 'Safety in Operations — Initial (v1)',
          ),
        ],
      );
    });

    Future<ProviderContainer> launch(
      WidgetTester tester, {
      AuthenticatedIdentity? identity,
      String path = '/workspace/training/role-requirements',
      Size size = const Size(800, 2400),
    }) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      auth = ManagementTestAuth(
        identity ??
            managementIdentity(
              capabilities: {
                'management_workspace',
                'training.view_roletrainingrequirement',
                'training.add_roletrainingrequirement',
                'training.change_roletrainingrequirement',
                'training.add_trainingassignment',
                'training.view_trainingversion',
              },
            ),
      );

      final container = ProviderContainer(
        overrides: [
          authControllerProvider.overrideWith(() => auth),
          managementRepositoryProvider.overrideWithValue(repository),
          notificationUnreadCountProvider.overrideWith(ZeroUnread.new),
        ],
      );
      addTearDown(container.dispose);

      router = container.read(appRouterProvider);
      router.go(path);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp.router(
            routerConfig: router,
            theme: AppTheme.lightTheme,
          ),
        ),
      );
      await tester.pumpAndSettle();
      return container;
    }

    testWidgets('unauthorized route access redirects away via router', (
      tester,
    ) async {
      await launch(
        tester,
        identity: managementIdentity(capabilities: {'management_workspace'}),
      );

      expect(
        router.state.uri.path,
        isNot('/workspace/training/role-requirements'),
      );
    });

    testWidgets('direct pump of screen without permission shows denial view', (
      tester,
    ) async {
      final unauth = ManagementTestAuth(
        managementIdentity(capabilities: {'management_workspace'}),
      );
      final container = ProviderContainer(
        overrides: [
          authControllerProvider.overrideWith(() => unauth),
          managementRepositoryProvider.overrideWithValue(repository),
          notificationUnreadCountProvider.overrideWith(ZeroUnread.new),
        ],
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: RoleRequirementsScreen()),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.text('You do not have permission to view role requirements.'),
        findsOneWidget,
      );
    });

    testWidgets('authorized user sees requirements list and details', (
      tester,
    ) async {
      await launch(tester);

      expect(find.text('Role requirements'), findsWidgets);
      expect(find.text('Operator'), findsOneWidget);
      expect(find.text('Code: OP'), findsOneWidget);
      expect(find.text('Safety in Operations'), findsOneWidget);
      expect(find.text('Due in 30 days'), findsOneWidget);
      expect(find.text('ACTIVE'), findsOneWidget);

      // Tap card to open details bottom sheet
      await tester.tap(find.text('Operator'));
      await tester.pumpAndSettle();

      expect(find.text('Requirement details'), findsOneWidget);
      expect(find.text('Job role'), findsOneWidget);
      expect(find.text('Operator (OP)'), findsOneWidget);
      expect(find.text('Course'), findsOneWidget);
      expect(find.text('Safety in Operations'), findsWidgets);
      expect(find.text('30 days'), findsWidgets);
    });

    testWidgets('filter chips toggle correctly', (tester) async {
      await launch(tester);

      expect(find.text('All'), findsOneWidget);
      expect(find.text('Active only'), findsOneWidget);
      expect(find.text('Inactive only'), findsOneWidget);

      await tester.tap(find.text('Active only'));
      await tester.pumpAndSettle();

      verify(
        () => repository.roleRequirements(
          page: 1,
          search: any(named: 'search'),
          jobRoleId: any(named: 'jobRoleId'),
          trainingVersionId: any(named: 'trainingVersionId'),
          isActive: true,
          cancelToken: any(named: 'cancelToken'),
        ),
      ).called(greaterThanOrEqualTo(1));
    });

    // Finding 1: Empty Paginated Page Recovery
    testWidgets(
      'Finding 1: page 2 becoming empty automatically recovers to page 1',
      (tester) async {
        // Page 1 has item 1; Page 2 initially has item 2
        when(
          () => repository.roleRequirements(
            page: 1,
            pageSize: any(named: 'pageSize'),
            search: any(named: 'search'),
            jobRoleId: any(named: 'jobRoleId'),
            trainingVersionId: any(named: 'trainingVersionId'),
            isActive: any(named: 'isActive'),
            cancelToken: any(named: 'cancelToken'),
          ),
        ).thenAnswer(
          (_) async => ManagementPage<RoleTrainingRequirement>(
            count: 2,
            hasMore: true,
            items: [
              RoleTrainingRequirement.fromJson(
                roleTrainingRequirementJson(id: 1, jobRoleName: 'Operator 1'),
              ),
            ],
          ),
        );

        when(
          () => repository.roleRequirements(
            page: 2,
            pageSize: any(named: 'pageSize'),
            search: any(named: 'search'),
            jobRoleId: any(named: 'jobRoleId'),
            trainingVersionId: any(named: 'trainingVersionId'),
            isActive: any(named: 'isActive'),
            cancelToken: any(named: 'cancelToken'),
          ),
        ).thenAnswer(
          (_) async => ManagementPage<RoleTrainingRequirement>(
            count: 2,
            hasMore: false,
            items: [
              RoleTrainingRequirement.fromJson(
                roleTrainingRequirementJson(id: 2, jobRoleName: 'Operator 2'),
              ),
            ],
          ),
        );

        await launch(tester);

        expect(find.text('Operator 1'), findsOneWidget);

        // Navigate to page 2
        await tester.tap(find.text('Next'));
        await tester.pumpAndSettle();

        expect(find.text('Operator 2'), findsOneWidget);

        // Now requirement 2 is deactivated, making page 2 return empty
        when(
          () => repository.roleRequirements(
            page: 2,
            pageSize: any(named: 'pageSize'),
            search: any(named: 'search'),
            jobRoleId: any(named: 'jobRoleId'),
            trainingVersionId: any(named: 'trainingVersionId'),
            isActive: any(named: 'isActive'),
            cancelToken: any(named: 'cancelToken'),
          ),
        ).thenAnswer(
          (_) async => ManagementPage<RoleTrainingRequirement>(
            count: 1,
            hasMore: false,
            items: [],
          ),
        );

        // Trigger refresh while on page 2
        await tester.tap(find.byTooltip('Refresh'));
        await tester.pump();
        await tester.pumpAndSettle();

        // Reliable recovery: navigated back to page 1 and shows Operator 1!
        expect(find.text('Operator 1'), findsOneWidget);
        expect(find.text('Page 1 · 2 total'), findsOneWidget);
      },
    );

    // Finding 2: In-Flight Duplicate Protection
    testWidgets(
      'Finding 2: status toggle prevents duplicate mutations and shows busy state',
      (tester) async {
        final completer = Completer<RoleTrainingRequirement>();
        when(
          () => repository.updateRoleRequirement(
            id: 1,
            isActive: false,
            cancelToken: any(named: 'cancelToken'),
          ),
        ).thenAnswer((_) => completer.future);

        await launch(tester);

        final deactivateBtn = find.text('Deactivate');
        await tester.tap(deactivateBtn);
        await tester.pumpAndSettle();

        // Confirm in dialog
        await tester.tap(find.widgetWithText(FilledButton, 'Deactivate'));
        await tester.pump(); // Start async mutation

        // While in-flight: button displays "Updating..."
        expect(find.text('Updating...'), findsOneWidget);

        // Attempting to tap the card or action again while in-flight does nothing
        await tester.tap(find.text('Updating...'), warnIfMissed: false);
        await tester.pump();

        // Only 1 mutation was dispatched to repository
        verify(
          () => repository.updateRoleRequirement(
            id: 1,
            isActive: false,
            cancelToken: any(named: 'cancelToken'),
          ),
        ).called(1);

        // Complete the future
        completer.complete(
          RoleTrainingRequirement.fromJson(
            roleTrainingRequirementJson(id: 1, isActive: false),
          ),
        );
        await tester.pumpAndSettle();

        // Success message shown and button state restored
        expect(
          find.text('Requirement deactivated successfully.'),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'Finding 2: batch assignment prevents duplicate mutations and shows busy state',
      (tester) async {
        final completer = Completer<RoleBatchResult>();
        when(
          () => repository.executeRoleBatchAssignment(
            1,
            cancelToken: any(named: 'cancelToken'),
          ),
        ).thenAnswer((_) => completer.future);

        await launch(tester);

        await tester.tap(find.text('Assign batch'));
        await tester.pumpAndSettle();

        await tester.tap(find.text('Assign now'));
        await tester.pump(); // Start async execution

        // While in-flight: button displays "Assigning..."
        expect(find.text('Assigning...'), findsOneWidget);

        // Attempting to tap again while in-flight does nothing
        await tester.tap(find.text('Assigning...'), warnIfMissed: false);
        await tester.pump();

        // Only 1 batch assignment was dispatched to repository
        verify(
          () => repository.executeRoleBatchAssignment(
            1,
            cancelToken: any(named: 'cancelToken'),
          ),
        ).called(1);

        completer.complete(
          const RoleBatchResult(
            roleRequirementId: 1,
            jobRoleId: 1,
            trainingVersionId: 10,
            createdCount: 3,
            skippedCount: 1,
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('Batch assignment completed'), findsOneWidget);
        await tester.tap(find.text('OK'));
        await tester.pumpAndSettle();
      },
    );

    testWidgets(
      'User with only training.add_roletrainingrequirement can load both creation-options lists without view or assignment permissions',
      (tester) async {
        final creatorOnlyIdentity = managementIdentity(
          capabilities: {
            'management_workspace',
            'training.add_roletrainingrequirement',
          },
        );

        when(
          () => repository.createRoleRequirement(
            jobRoleId: 1,
            trainingVersionId: 10,
            dueInDays: 30,
            isActive: true,
            cancelToken: any(named: 'cancelToken'),
          ),
        ).thenAnswer(
          (_) async => RoleTrainingRequirement.fromJson(
            roleTrainingRequirementJson(
              id: 3,
              jobRoleId: 1,
              trainingVersionId: 10,
            ),
          ),
        );

        await launch(tester, identity: creatorOnlyIdentity);

        // Verified: router allowed navigation to role-requirements route
        expect(router.state.uri.path, '/workspace/training/role-requirements');

        // Verified: create-only screen is rendered without fetching requirements list
        expect(
          find.text('Choose a job role and a published version.'),
          findsOneWidget,
        );
        expect(
          find.widgetWithText(FilledButton, 'Add role requirement'),
          findsOneWidget,
        );

        // Verified: no list retrieval was triggered
        verifyNever(
          () => repository.roleRequirements(
            page: any(named: 'page'),
            pageSize: any(named: 'pageSize'),
            search: any(named: 'search'),
            jobRoleId: any(named: 'jobRoleId'),
            trainingVersionId: any(named: 'trainingVersionId'),
            isActive: any(named: 'isActive'),
            cancelToken: any(named: 'cancelToken'),
          ),
        );

        // Open Add dialog from create-only view
        await tester.tap(
          find.widgetWithText(FilledButton, 'Add role requirement'),
        );
        await tester.pumpAndSettle();

        expect(find.text('Select job role'), findsOneWidget);
        expect(find.text('Select training version'), findsOneWidget);

        // Verified: allRoleRequirementCreationOptions was called for both kinds without view/assignment permissions
        verify(
          () => repository.allRoleRequirementCreationOptions(
            kind: RoleRequirementOptionKind.jobRoles,
            cancelToken: any(named: 'cancelToken'),
          ),
        ).called(1);
        verify(
          () => repository.allRoleRequirementCreationOptions(
            kind: RoleRequirementOptionKind.trainingVersions,
            cancelToken: any(named: 'cancelToken'),
          ),
        ).called(1);

        // Select options and submit
        await tester.tap(find.text('Select job role'), warnIfMissed: false);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Operator (OP)').last);
        await tester.pumpAndSettle();

        await tester.tap(
          find.text('Select training version'),
          warnIfMissed: false,
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Safety in Operations — Initial (v1)').last);
        await tester.pumpAndSettle();

        await tester.tap(find.widgetWithText(FilledButton, 'Create'));
        await tester.pumpAndSettle();

        // Verify repository mutation was invoked with correct arguments
        verify(
          () => repository.createRoleRequirement(
            jobRoleId: 1,
            trainingVersionId: 10,
            dueInDays: 30,
            isActive: true,
            cancelToken: any(named: 'cancelToken'),
          ),
        ).called(1);

        // Verified: requirements list GET was still never called
        verifyNever(
          () => repository.roleRequirements(
            page: any(named: 'page'),
            pageSize: any(named: 'pageSize'),
            search: any(named: 'search'),
            jobRoleId: any(named: 'jobRoleId'),
            trainingVersionId: any(named: 'trainingVersionId'),
            isActive: any(named: 'isActive'),
            cancelToken: any(named: 'cancelToken'),
          ),
        );

        // Success snackbar displayed
        expect(
          find.text('Role requirement created successfully.'),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'user without training.add_roletrainingrequirement cannot add requirements',
      (tester) async {
        final viewOnlyIdentity = managementIdentity(
          capabilities: {
            'management_workspace',
            'training.view_roletrainingrequirement',
          },
        );

        await launch(tester, identity: viewOnlyIdentity);

        expect(find.byIcon(Icons.add), findsNothing);
        expect(find.text('Add role requirement'), findsNothing);
        expect(find.text('Operator'), findsOneWidget);
      },
    );

    testWidgets(
      'add-only account can access training workspace and navigate to role requirements',
      (tester) async {
        final addOnlyIdentity = managementIdentity(
          capabilities: {
            'management_workspace',
            'training.add_roletrainingrequirement',
          },
        );

        await launch(
          tester,
          identity: addOnlyIdentity,
          path: '/workspace/training',
        );

        // Verify training management screen displays role requirements entry point
        expect(find.text('Role requirements'), findsOneWidget);

        // Tap card to navigate to role requirements
        await tester.tap(find.text('Role requirements'));
        await tester.pumpAndSettle();

        expect(router.state.uri.path, '/workspace/training/role-requirements');
        expect(
          find.widgetWithText(FilledButton, 'Add role requirement'),
          findsOneWidget,
        );
        expect(find.byTooltip('Add requirement'), findsNothing);
      },
    );

    testWidgets('empty state displays friendly message and create button', (
      tester,
    ) async {
      when(
        () => repository.roleRequirements(
          page: any(named: 'page'),
          pageSize: any(named: 'pageSize'),
          search: any(named: 'search'),
          jobRoleId: any(named: 'jobRoleId'),
          trainingVersionId: any(named: 'trainingVersionId'),
          isActive: any(named: 'isActive'),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer(
        (_) async => ManagementPage<RoleTrainingRequirement>(
          count: 0,
          hasMore: false,
          items: [],
        ),
      );

      await launch(tester);

      expect(find.text('No role requirements found.'), findsOneWidget);
      expect(
        find.widgetWithText(FilledButton, 'Add requirement'),
        findsOneWidget,
      );
    });

    testWidgets(
      'create requirement dialog opens, validates and submits successfully',
      (tester) async {
        when(
          () => repository.createRoleRequirement(
            jobRoleId: 1,
            trainingVersionId: 10,
            dueInDays: 30,
            isActive: true,
            cancelToken: any(named: 'cancelToken'),
          ),
        ).thenAnswer(
          (_) async => RoleTrainingRequirement.fromJson(
            roleTrainingRequirementJson(
              id: 2,
              jobRoleId: 1,
              trainingVersionId: 10,
              dueInDays: 30,
              isActive: true,
            ),
          ),
        );

        await launch(tester);

        // Click Add button in AppBar
        await tester.tap(find.byIcon(Icons.add));
        await tester.pumpAndSettle();

        expect(
          find.widgetWithText(AlertDialog, 'Add role requirement'),
          findsOneWidget,
        );
        expect(find.text('Due in days *'), findsOneWidget);

        // Select job role dropdown
        await tester.tap(find.text('Select job role'), warnIfMissed: false);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Operator (OP)').last);
        await tester.pumpAndSettle();

        // Select training version dropdown
        await tester.tap(
          find.text('Select training version'),
          warnIfMissed: false,
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Safety in Operations — Initial (v1)').last);
        await tester.pumpAndSettle();

        // Tap Create
        await tester.tap(find.widgetWithText(FilledButton, 'Create'));
        await tester.pumpAndSettle();

        verify(
          () => repository.createRoleRequirement(
            jobRoleId: 1,
            trainingVersionId: 10,
            dueInDays: 30,
            isActive: true,
            cancelToken: any(named: 'cancelToken'),
          ),
        ).called(1);
      },
    );

    testWidgets(
      'create requirement dialog supports published versions from inactive catalogs',
      (tester) async {
        when(
          () => repository.allRoleRequirementCreationOptions(
            kind: RoleRequirementOptionKind.trainingVersions,
            cancelToken: any(named: 'cancelToken'),
          ),
        ).thenAnswer(
          (_) async => [
            const RoleRequirementOption(
              id: 99,
              label: 'Archived Safety Course — Final Revision (v3)',
            ),
          ],
        );

        when(
          () => repository.createRoleRequirement(
            jobRoleId: 1,
            trainingVersionId: 99,
            dueInDays: 30,
            isActive: true,
            cancelToken: any(named: 'cancelToken'),
          ),
        ).thenAnswer(
          (_) async => RoleTrainingRequirement.fromJson(
            roleTrainingRequirementJson(
              id: 5,
              jobRoleId: 1,
              trainingVersionId: 99,
              dueInDays: 30,
              isActive: true,
            ),
          ),
        );

        await launch(tester);

        await tester.tap(find.byIcon(Icons.add));
        await tester.pumpAndSettle();

        await tester.tap(find.text('Select job role'), warnIfMissed: false);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Operator (OP)').last);
        await tester.pumpAndSettle();

        await tester.tap(
          find.text('Select training version'),
          warnIfMissed: false,
        );
        await tester.pumpAndSettle();
        await tester.tap(
          find.text('Archived Safety Course — Final Revision (v3)').last,
        );
        await tester.pumpAndSettle();

        await tester.tap(find.widgetWithText(FilledButton, 'Create'));
        await tester.pumpAndSettle();

        verify(
          () => repository.createRoleRequirement(
            jobRoleId: 1,
            trainingVersionId: 99,
            dueInDays: 30,
            isActive: true,
            cancelToken: any(named: 'cancelToken'),
          ),
        ).called(1);
      },
    );

    testWidgets('create requirement handles 409 conflict gracefully', (
      tester,
    ) async {
      when(
        () => repository.createRoleRequirement(
          jobRoleId: 1,
          trainingVersionId: 10,
          dueInDays: 30,
          isActive: true,
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenThrow(
        ApiError(
          statusCode: 409,
          message: 'Another operation conflicts with this request. Refresh before trying again.',
        ),
      );

      await launch(tester);

      await tester.tap(find.byIcon(Icons.add));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Select job role'), warnIfMissed: false);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Operator (OP)').last);
      await tester.pumpAndSettle();

      await tester.tap(
        find.text('Select training version'),
        warnIfMissed: false,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Safety in Operations — Initial (v1)').last);
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(FilledButton, 'Create'));
      await tester.pumpAndSettle();

      expect(
        find.text(
          'Another operation conflicts with this request. Refresh before trying again.',
        ),
        findsOneWidget,
      );
    });

    testWidgets(
      'create requirement handles POST 403 gracefully when permission revoked after loading options',
      (tester) async {
        when(
          () => repository.createRoleRequirement(
            jobRoleId: 1,
            trainingVersionId: 10,
            dueInDays: 30,
            isActive: true,
            cancelToken: any(named: 'cancelToken'),
          ),
        ).thenThrow(
          ApiError(
            statusCode: 403,
            message: 'You do not have permission to create role requirements.',
          ),
        );

        await launch(tester);

        await tester.tap(find.byIcon(Icons.add));
        await tester.pumpAndSettle();

        await tester.tap(find.text('Select job role'), warnIfMissed: false);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Operator (OP)').last);
        await tester.pumpAndSettle();

        await tester.tap(
          find.text('Select training version'),
          warnIfMissed: false,
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Safety in Operations — Initial (v1)').last);
        await tester.pumpAndSettle();

        await tester.tap(find.widgetWithText(FilledButton, 'Create'));
        await tester.pumpAndSettle();

        expect(
          find.text('You do not have permission to create role requirements.'),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'Finding 1: reference loading failure disables Create button without crashing and supports Retry',
      (tester) async {
        when(
          () => repository.allRoleRequirementCreationOptions(
            kind: RoleRequirementOptionKind.jobRoles,
            cancelToken: any(named: 'cancelToken'),
          ),
        ).thenThrow(
          ApiError(
            statusCode: 500,
            message: 'Internal server error loading job roles.',
          ),
        );

        await launch(tester);

        // Open Add dialog
        await tester.tap(find.byIcon(Icons.add));
        await tester.pumpAndSettle();

        // Form is not shown; error view is displayed
        expect(
          find.widgetWithText(AlertDialog, 'Add role requirement'),
          findsOneWidget,
        );
        expect(
          find.textContaining('Internal server error loading job roles.'),
          findsOneWidget,
        );
        expect(find.text('Retry'), findsOneWidget);

        // Create button is disabled
        final createButton = tester.widget<FilledButton>(
          find.widgetWithText(FilledButton, 'Create'),
        );
        expect(createButton.onPressed, isNull);

        // Tapping Create does not crash and does not call createRoleRequirement
        await tester.tap(
          find.widgetWithText(FilledButton, 'Create'),
          warnIfMissed: false,
        );
        await tester.pump();
        verifyNever(
          () => repository.createRoleRequirement(
            jobRoleId: any(named: 'jobRoleId'),
            trainingVersionId: any(named: 'trainingVersionId'),
          ),
        );

        // Fix repository mock and tap Retry
        when(
          () => repository.allRoleRequirementCreationOptions(
            kind: RoleRequirementOptionKind.jobRoles,
            cancelToken: any(named: 'cancelToken'),
          ),
        ).thenAnswer(
          (_) async => [
            const RoleRequirementOption(id: 1, label: 'Operator (OP)'),
          ],
        );

        await tester.tap(find.text('Retry'));
        await tester.pumpAndSettle();

        // Form is now rendered and options are loaded
        expect(find.text('Select job role'), findsOneWidget);
        expect(find.text('Select training version'), findsOneWidget);
      },
    );

    testWidgets(
      'Finding 1: partial reference loading failure disables Create button and shows specific failure',
      (tester) async {
        when(
          () => repository.allRoleRequirementCreationOptions(
            kind: RoleRequirementOptionKind.jobRoles,
            cancelToken: any(named: 'cancelToken'),
          ),
        ).thenAnswer(
          (_) async => [
            const RoleRequirementOption(id: 1, label: 'Operator (OP)'),
          ],
        );

        when(
          () => repository.allRoleRequirementCreationOptions(
            kind: RoleRequirementOptionKind.trainingVersions,
            cancelToken: any(named: 'cancelToken'),
          ),
        ).thenThrow(
          ApiError(
            statusCode: 502,
            message: 'Training version discovery gateway timeout.',
          ),
        );

        await launch(tester);

        await tester.tap(find.byIcon(Icons.add));
        await tester.pumpAndSettle();

        expect(
          find.textContaining(
            'Training versions: Training version discovery gateway timeout.',
          ),
          findsOneWidget,
        );

        final createButton = tester.widget<FilledButton>(
          find.widgetWithText(FilledButton, 'Create'),
        );
        expect(createButton.onPressed, isNull);
      },
    );

    testWidgets(
      'Finding 1: closing dialog during in-flight reference fetch cancels request safely',
      (tester) async {
        final rolesCompleter = Completer<List<RoleRequirementOption>>();
        when(
          () => repository.allRoleRequirementCreationOptions(
            kind: RoleRequirementOptionKind.jobRoles,
            cancelToken: any(named: 'cancelToken'),
          ),
        ).thenAnswer((invocation) {
          final token = invocation.namedArguments[#cancelToken] as CancelToken?;
          token?.whenCancel.then((_) {
            if (!rolesCompleter.isCompleted) {
              rolesCompleter.completeError(token.cancelError!);
            }
          });
          return rolesCompleter.future;
        });

        await launch(tester);

        await tester.tap(find.byIcon(Icons.add));
        await tester.pump();

        expect(find.byType(CircularProgressIndicator), findsOneWidget);

        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();

        expect(find.text('Add role requirement'), findsNothing);
      },
    );

    testWidgets(
      'Finding 3: identity with only training.add_roletrainingrequirement shows permission error for reference options and keeps Create disabled',
      (tester) async {
        final addOnlyIdentity = managementIdentity(
          capabilities: {
            'management_workspace',
            'training.add_roletrainingrequirement',
          },
        );

        when(
          () => repository.allRoleRequirementCreationOptions(
            kind: RoleRequirementOptionKind.jobRoles,
            cancelToken: any(named: 'cancelToken'),
          ),
        ).thenThrow(
          ApiError(
            statusCode: 403,
            message: 'You do not have permission to view job roles.',
          ),
        );

        when(
          () => repository.allRoleRequirementCreationOptions(
            kind: RoleRequirementOptionKind.trainingVersions,
            cancelToken: any(named: 'cancelToken'),
          ),
        ).thenThrow(
          ApiError(
            statusCode: 403,
            message: 'Viewing published training versions requires training version view permissions (training.view_trainingversion) or assignment authority.',
          ),
        );

        await launch(tester, identity: addOnlyIdentity);

        expect(find.byIcon(Icons.add), findsWidgets);

        await tester.tap(find.byIcon(Icons.add).first);
        await tester.pumpAndSettle();

        expect(
          find.widgetWithText(AlertDialog, 'Add role requirement'),
          findsOneWidget,
        );
        expect(
          find.textContaining(
            'Job roles permission required: You do not have permission to view job roles.',
          ),
          findsOneWidget,
        );
        expect(
          find.textContaining(
            'Training versions permission required: Viewing published training versions requires training version view permissions (training.view_trainingversion) or assignment authority.',
          ),
          findsOneWidget,
        );

        final createButton = tester.widget<FilledButton>(
          find.widgetWithText(FilledButton, 'Create'),
        );
        expect(createButton.onPressed, isNull);

        expect(find.text('Select job role'), findsNothing);
        expect(find.text('Select training version'), findsNothing);

        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsNothing);
      },
    );

    testWidgets(
      'in-flight reference completion under changed auth identity discards stale options',
      (tester) async {
        final rolesCompleter = Completer<List<RoleRequirementOption>>();
        when(
          () => repository.allRoleRequirementCreationOptions(
            kind: RoleRequirementOptionKind.jobRoles,
            cancelToken: any(named: 'cancelToken'),
          ),
        ).thenAnswer((_) => rolesCompleter.future);

        await launch(tester);

        await tester.tap(find.byIcon(Icons.add));
        await tester.pump();

        expect(find.byType(CircularProgressIndicator), findsOneWidget);

        // Switch account while request is in flight
        auth.setAuth(
          AuthAuthenticated.identity(
            managementIdentity(username: 'other_user', team: true),
          ),
        );

        // Now complete the pending future
        rolesCompleter.complete([
          const RoleRequirementOption(id: 1, label: 'Operator (OP)'),
        ]);
        await tester.pumpAndSettle();

        // Stale options were discarded; form inputs not rendered
        expect(find.textContaining('Account context changed'), findsOneWidget);
        expect(find.text('Select job role'), findsNothing);
      },
    );
  });
}
