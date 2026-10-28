import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:training_app/core/errors/api_error.dart';
import 'package:training_app/core/network/dio_client.dart';
import 'package:training_app/features/management/data/repositories/management_repository.dart';
import 'package:training_app/features/management/domain/models/management_models.dart';

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

  void reply(String path, Object data, {int? page, int? pageSize}) {
    final query = <String, dynamic>{
      if (page != null && page > 1) 'page': page,
      'page_size': ?pageSize,
    };
    when(
      () => dio.get(
        path,
        queryParameters: query.isEmpty ? null : query,
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenAnswer(
      (_) async => Response(
        requestOptions: RequestOptions(path: path),
        data: data,
      ),
    );
  }

  void replyMutation(String path, Object data, {required bool patch}) {
    final request = patch ? dio.patch : dio.post;
    when(
      () => request(
        path,
        data: any(named: 'data'),
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenAnswer(
      (_) async => Response(
        requestOptions: RequestOptions(path: path),
        data: data,
      ),
    );
  }

  test(
    'dashboard parses company/team metrics and exact decimal score strings',
    () async {
      for (final team in [false, true]) {
        reply('/management/dashboard/', managementDashboardJson(team: team));
        final dashboard = await repository.dashboard();
        expect(dashboard.isCompany, !team);
        expect(dashboard.metrics.completionPercent, 33.3);
        expect(dashboard.metrics.eligible, 3);
        expect(dashboard.recentFailures.single.scorePoints, '0.00');
        expect(dashboard.incompleteEmployees.length, team ? 1 : 0);
      }
    },
  );

  test(
    'directory pagination uses fixed authenticated paths, never returned URLs',
    () async {
      reply(
        '/management/employees/',
        pageJson(
          [employeeJson()],
          count: 2,
          next: 'https://untrusted.invalid/media',
        ),
        page: 2,
      );
      final page = await repository.employees(page: 2);
      expect(page.hasMore, isTrue);
      expect(page.items.single.employeeCode, 'EMP1');
      verify(
        () => dio.get(
          '/management/employees/',
          queryParameters: {'page': 2},
          cancelToken: null,
        ),
      ).called(1);
      verifyNever(() => dio.get('https://untrusted.invalid/media'));
      expect(() => page.items.clear(), throwsUnsupportedError);
    },
  );

  test(
    'directory search and filters use the agreed server query contract',
    () async {
      final response = Response(
        requestOptions: RequestOptions(path: '/management/employees/'),
        data: pageJson([employeeJson()]),
      );
      when(
        () => dio.get(
          '/management/employees/',
          queryParameters: {
            'page': 3,
            'page_size': 25,
            'search': 'Taylor',
            'department_id': 4,
            'job_role_id': 9,
            'is_active': false,
          },
          cancelToken: null,
        ),
      ).thenAnswer((_) async => response);

      final page = await repository.employees(
        page: 3,
        pageSize: 25,
        search: '  Taylor  ',
        departmentId: 4,
        jobRoleId: 9,
        isActive: false,
      );

      expect(page.items.single.employeeCode, 'EMP1');
      verify(
        () => dio.get(
          '/management/employees/',
          queryParameters: {
            'page': 3,
            'page_size': 25,
            'search': 'Taylor',
            'department_id': 4,
            'job_role_id': 9,
            'is_active': false,
          },
          cancelToken: null,
        ),
      ).called(1);
    },
  );

  test(
    'employee detail and both reference routes parse their exact contracts',
    () async {
      reply('/management/employees/3/', employeeDetailJson(3));
      final employee = await repository.employee(3);
      expect(employee.reportingManager, 'Team Manager');
      expect(employee.reportingManagerId, 9);
      expect(employee.dateJoined, '2020-01-02');
      expect(employee.loginStatus, 'ACTIVE');
      for (final kind in ReferenceKind.values) {
        reply(
          '/management/${kind.path}/',
          pageJson([referenceJson()..['is_active'] = false]),
        );
        final references = await repository.references(kind);
        expect(references.items.single.isActive, isFalse);
        expect(references.items.single.description, 'Organization reference');
      }
    },
  );

  test(
    'employee detail requires a typed reporting manager ID and name',
    () async {
      final missingId = employeeDetailJson(3)..remove('reporting_manager_id');
      reply('/management/employees/3/', missingId);
      await expectLater(repository.employee(3), throwsA(isA<ApiError>()));

      final invalidId = employeeDetailJson(3)..['reporting_manager_id'] = '9';
      reply('/management/employees/3/', invalidId);
      await expectLater(repository.employee(3), throwsA(isA<ApiError>()));

      final nullManager = employeeDetailJson(3)
        ..['reporting_manager'] = null
        ..['reporting_manager_id'] = null;
      reply('/management/employees/3/', nullManager);
      final parsed = await repository.employee(3);
      expect(parsed.reportingManager, isNull);
      expect(parsed.reportingManagerId, isNull);
    },
  );

  test(
    'employee edit choices load every authorized page and exclude the target',
    () async {
      for (final kind in ReferenceKind.values) {
        final path = '/management/${kind.path}/';
        final first = referenceJson()..['is_active'] = true;
        reply(
          path,
          pageJson([first], count: 2, next: 'server-next-url-is-ignored'),
          pageSize: 100,
        );
        reply(
          path,
          pageJson([
            {
              'id': 2,
              'code': 'INACTIVE',
              'name': 'Inactive choice',
              'description': '',
              'is_active': false,
            },
          ]),
          page: 2,
          pageSize: 100,
        );
      }
      reply(
        '/management/employees/',
        pageJson([employeeJson(1), employeeJson(2)], count: 3, next: 'next'),
        pageSize: 100,
      );
      reply(
        '/management/employees/',
        pageJson([employeeJson(3)]),
        page: 2,
        pageSize: 100,
      );

      final choices = await repository.employeeEditChoices(employeeId: 1);
      expect(choices.departments.map((item) => item.id), [1, 2]);
      expect(choices.departments.last.isActive, isFalse);
      expect(choices.jobRoles.map((item) => item.id), [1, 2]);
      expect(choices.jobRoles.last.isActive, isFalse);
      expect(choices.reportingManagers.map((item) => item.id), [2, 3]);
      verify(
        () => dio.get(
          '/management/employees/',
          queryParameters: {'page': 2, 'page_size': 100},
          cancelToken: null,
        ),
      ).called(1);
    },
  );

  test(
    'employee creation choices paginate, deduplicate and retain manager IDs',
    () async {
      for (final kind in ReferenceKind.values) {
        final path = '/management/${kind.path}/';
        reply(
          path,
          pageJson([referenceJson()], count: 3, next: 'next'),
          pageSize: 100,
        );
        reply(
          path,
          pageJson([referenceJson(), referenceJson(2)], count: 3, next: 'next'),
          page: 2,
          pageSize: 100,
        );
        reply(
          path,
          pageJson([referenceJson(3)], count: 3),
          page: 3,
          pageSize: 100,
        );
      }
      reply(
        '/management/employees/',
        pageJson([employeeJson(1), employeeJson(2)], count: 4, next: 'next'),
        pageSize: 100,
      );
      reply(
        '/management/employees/',
        pageJson([employeeJson(2), employeeJson(3)], count: 4, next: 'next'),
        page: 2,
        pageSize: 100,
      );
      reply(
        '/management/employees/',
        pageJson([employeeJson(4)], count: 4),
        page: 3,
        pageSize: 100,
      );

      final choices = await repository.employeeCreationChoices();
      expect(choices.departments.map((item) => item.id), [1, 2, 3]);
      expect(choices.jobRoles.map((item) => item.id), [1, 2, 3]);
      expect(choices.reportingManagers.map((item) => item.id), [1, 2, 3, 4]);
      verify(
        () => dio.get(
          '/management/employees/',
          queryParameters: {'page': 2, 'page_size': 100},
          cancelToken: null,
        ),
      ).called(1);
    },
  );

  test(
    'employee creation choices omit optional managers without directory access',
    () async {
      for (final kind in ReferenceKind.values) {
        reply(
          '/management/${kind.path}/',
          pageJson([referenceJson()]),
          pageSize: 100,
        );
      }
      final choices = await repository.employeeCreationChoices(
        includeReportingManagers: false,
      );
      expect(choices.departments, hasLength(1));
      expect(choices.jobRoles, hasLength(1));
      expect(choices.reportingManagers, isEmpty);
      verifyNever(
        () => dio.get(
          '/management/employees/',
          queryParameters: any(named: 'queryParameters'),
          cancelToken: any(named: 'cancelToken'),
        ),
      );
    },
  );

  test(
    'Employee POST sends supported fields and parses created detail',
    () async {
      final response = employeeDetailJson(42, 'New employee')
        ..['employee_code'] = 'NEW-42'
        ..['reporting_manager'] = null
        ..['reporting_manager_id'] = null
        ..['login_status'] = 'NOT_LINKED';
      when(
        () => dio.post(
          '/management/employees/',
          data: any(named: 'data'),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer(
        (_) async => Response(
          requestOptions: RequestOptions(path: '/management/employees/'),
          statusCode: 201,
          data: response,
        ),
      );

      final created = await repository.createEmployee(
        employeeCode: ' NEW-42 ',
        displayName: ' New employee ',
        departmentId: 2,
        jobRoleId: 3,
        dateJoined: '2026-10-22',
      );

      expect(created.id, 42);
      expect(created.reportingManagerId, isNull);
      expect(created.loginStatus, 'NOT_LINKED');
      verify(
        () => dio.post(
          '/management/employees/',
          data: {
            'employee_code': 'NEW-42',
            'display_name': 'New employee',
            'department': 2,
            'job_role': 3,
            'date_joined': '2026-10-22',
            'reporting_manager': null,
          },
          cancelToken: null,
        ),
      ).called(1);
    },
  );

  test(
    'Employee deactivation posts reason and parses confirmed detail',
    () async {
      final response = employeeDetailJson()
        ..['is_active'] = false
        ..['login_status'] = 'INACTIVE';
      when(
        () => dio.post(
          '/management/employees/1/deactivate/',
          data: any(named: 'data'),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer(
        (_) async => Response(
          requestOptions: RequestOptions(
            path: '/management/employees/1/deactivate/',
          ),
          statusCode: 200,
          data: response,
        ),
      );

      final saved = await repository.deactivateEmployee(
        1,
        reason: '  Employment ended  ',
      );

      expect(saved.id, 1);
      expect(saved.isActive, isFalse);
      expect(saved.loginStatus, 'INACTIVE');
      verify(
        () => dio.post(
          '/management/employees/1/deactivate/',
          data: {'reason': 'Employment ended'},
          cancelToken: null,
        ),
      ).called(1);
    },
  );

  test('invalid deactivation input is rejected before networking', () async {
    await expectLater(
      repository.deactivateEmployee(0, reason: 'Reason'),
      throwsA(isA<ArgumentError>()),
    );
    await expectLater(
      repository.deactivateEmployee(1, reason: '  '),
      throwsA(isA<ArgumentError>()),
    );
    await expectLater(
      repository.deactivateEmployee(1, reason: 'x' * 1001),
      throwsA(isA<ArgumentError>()),
    );
    verifyZeroInteractions(dio);
  });

  test('choice pagination rejects a stagnant page instead of returning partial choices', () async {
    for (final kind in ReferenceKind.values) {
      final path = '/management/${kind.path}/';
      reply(
        path,
        pageJson([referenceJson(1), referenceJson(2)], count: 3, next: 'next'),
        pageSize: 100,
      );
      // Page 2 returns duplicate ID 2 and indicates more data is available
      reply(
        path,
        pageJson([referenceJson(2)], count: 3, next: 'stagnant-loop'),
        page: 2,
        pageSize: 100,
      );
    }

    await expectLater(
      repository.employeeEditChoices(employeeId: 1),
      throwsA(
        isA<ApiError>().having(
          (error) => error.code,
          'code',
          'incomplete_pagination',
        ),
      ),
    );
    verify(
      () => dio.get(
        '/management/departments/',
        queryParameters: {'page': 2, 'page_size': 100},
        cancelToken: null,
      ),
    ).called(1);
    verifyNever(
      () => dio.get(
        '/management/employees/',
        queryParameters: any(named: 'queryParameters'),
        cancelToken: any(named: 'cancelToken'),
      ),
    );
  });

  test(
    'employee choice pagination rejects an empty continuation page',
    () async {
      for (final kind in ReferenceKind.values) {
        reply(
          '/management/${kind.path}/',
          pageJson([referenceJson()], count: 1),
          pageSize: 100,
        );
      }
      reply(
        '/management/employees/',
        pageJson([employeeJson(1)], count: 2, next: 'next'),
        pageSize: 100,
      );
      reply(
        '/management/employees/',
        pageJson([], count: 2),
        page: 2,
        pageSize: 100,
      );

      await expectLater(
        repository.employeeEditChoices(employeeId: 1),
        throwsA(
          isA<ApiError>().having(
            (error) => error.code,
            'code',
            'incomplete_pagination',
          ),
        ),
      );
    },
  );

  test(
    'reference choice pagination reports the maximum-page safety cap',
    () async {
      for (var page = 1; page <= 50; page++) {
        reply(
          '/management/departments/',
          pageJson([referenceJson(page)], count: 5001, next: 'next'),
          page: page,
          pageSize: 100,
        );
      }
      reply(
        '/management/job-roles/',
        pageJson([referenceJson()], count: 1),
        pageSize: 100,
      );

      await expectLater(
        repository.employeeCreationChoices(includeReportingManagers: false),
        throwsA(
          isA<ApiError>().having(
            (error) => error.code,
            'code',
            'incomplete_pagination',
          ),
        ),
      );
      verify(
        () => dio.get(
          '/management/departments/',
          queryParameters: {'page': 50, 'page_size': 100},
          cancelToken: null,
        ),
      ).called(1);
      verifyNever(
        () => dio.get(
          '/management/departments/',
          queryParameters: {'page': 51, 'page_size': 100},
          cancelToken: null,
        ),
      );
    },
  );

  test('choice pagination accepts empty first page with count 0 and no continuation', () async {
    reply('/management/departments/', pageJson([], count: 0), pageSize: 100);
    reply('/management/job-roles/', pageJson([], count: 0), pageSize: 100);
    reply('/management/employees/', pageJson([], count: 0), pageSize: 100);

    final choices = await repository.employeeCreationChoices();
    expect(choices.departments, isEmpty);
    expect(choices.jobRoles, isEmpty);
    expect(choices.reportingManagers, isEmpty);
  });

  test('choice pagination accepts terminal page containing previously seen IDs when expected count is met', () async {
    reply(
      '/management/departments/',
      pageJson([referenceJson(1), referenceJson(2)], count: 2, next: 'page-2'),
      pageSize: 100,
    );
    reply(
      '/management/departments/',
      pageJson([referenceJson(2)], count: 2),
      page: 2,
      pageSize: 100,
    );
    reply(
      '/management/job-roles/',
      pageJson([referenceJson(10)], count: 1),
      pageSize: 100,
    );
    reply(
      '/management/employees/',
      pageJson([employeeJson(1), employeeJson(2)], count: 2, next: 'page-2'),
      pageSize: 100,
    );
    reply(
      '/management/employees/',
      pageJson([employeeJson(2)], count: 2),
      page: 2,
      pageSize: 100,
    );

    final choices = await repository.employeeCreationChoices();
    expect(choices.departments.map((d) => d.id).toList(), [1, 2]);
    expect(choices.reportingManagers.map((m) => m.id).toList(), [1, 2]);
  });

  test('choice pagination throws incomplete_pagination when terminal page has duplicate IDs and missing records', () async {
    reply(
      '/management/departments/',
      pageJson([referenceJson(1)], count: 3, next: 'page-2'),
      pageSize: 100,
    );
    reply(
      '/management/departments/',
      pageJson([referenceJson(1)], count: 3),
      page: 2,
      pageSize: 100,
    );
    reply(
      '/management/job-roles/',
      pageJson([referenceJson(10)], count: 1),
      pageSize: 100,
    );
    reply('/management/employees/', pageJson([], count: 0), pageSize: 100);

    await expectLater(
      repository.employeeCreationChoices(),
      throwsA(
        isA<ApiError>().having(
          (error) => error.code,
          'code',
          'incomplete_pagination',
        ),
      ),
    );
  });

  test('choice pagination throws incomplete_pagination when records are missing from count', () async {
    reply(
      '/management/departments/',
      pageJson([referenceJson(1)], count: 5),
      pageSize: 100,
    );
    reply(
      '/management/job-roles/',
      pageJson([referenceJson(10)], count: 1),
      pageSize: 100,
    );
    reply('/management/employees/', pageJson([], count: 0), pageSize: 100);

    await expectLater(
      repository.employeeCreationChoices(),
      throwsA(
        isA<ApiError>().having(
          (error) => error.code,
          'code',
          'incomplete_pagination',
        ),
      ),
    );
  });

  test(
    'employee profile PATCH sends changed relationship IDs and explicit null',
    () async {
      final response = employeeDetailJson()
        ..['display_name'] = 'Updated employee'
        ..['department'] = {'id': 2, 'code': 'D2', 'name': 'Department 2'}
        ..['reporting_manager'] = null
        ..['reporting_manager_id'] = null
        ..['date_joined'] = '2020-01-02';
      when(
        () => dio.patch(
          '/management/employees/1/',
          data: any(named: 'data'),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer(
        (_) async => Response(
          requestOptions: RequestOptions(path: '/management/employees/1/'),
          data: response,
        ),
      );

      final updated = await repository.updateEmployeeProfile(
        DirectoryEmployee.fromJson(employeeDetailJson()),
        displayName: 'Updated employee',
        departmentId: 2,
        jobRoleId: 1,
        dateJoined: '2020-01-02',
        updateReportingManager: true,
        reportingManagerId: null,
      );
      expect(updated.displayName, 'Updated employee');
      expect(updated.department.id, 2);
      expect(updated.reportingManager, isNull);
      expect(updated.reportingManagerId, isNull);
      verify(
        () => dio.patch(
          '/management/employees/1/',
          data: {
            'display_name': 'Updated employee',
            'department': 2,
            'reporting_manager': null,
          },
          cancelToken: null,
        ),
      ).called(1);
    },
  );

  test(
    'employee profile PATCH only sends changed fields and matches returned ID',
    () async {
      when(
        () => dio.patch(
          '/management/employees/1/',
          data: any(named: 'data'),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer(
        (_) async => Response(
          requestOptions: RequestOptions(path: '/management/employees/1/'),
          data: employeeDetailJson()..['display_name'] = 'Changed',
        ),
      );
      final original = DirectoryEmployee.fromJson(employeeDetailJson());
      await repository.updateEmployeeProfile(
        original,
        displayName: 'Changed',
        departmentId: original.department.id,
        jobRoleId: original.jobRole.id,
        dateJoined: original.dateJoined!,
        updateReportingManager: false,
      );
      verify(
        () => dio.patch(
          '/management/employees/1/',
          data: {'display_name': 'Changed'},
          cancelToken: null,
        ),
      ).called(1);
      await expectLater(
        repository.updateEmployeeProfile(
          original,
          displayName: original.displayName,
          departmentId: original.department.id,
          jobRoleId: original.jobRole.id,
          dateJoined: original.dateJoined!,
          updateReportingManager: false,
        ),
        throwsArgumentError,
      );
    },
  );

  test(
    'employee profile PATCH accepts a changed manager ID and parses response',
    () async {
      when(
        () => dio.patch(
          '/management/employees/1/',
          data: any(named: 'data'),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer(
        (_) async => Response(
          requestOptions: RequestOptions(path: '/management/employees/1/'),
          data: employeeDetailJson()
            ..['reporting_manager'] = 'New manager'
            ..['reporting_manager_id'] = 3,
        ),
      );
      final original = DirectoryEmployee.fromJson(employeeDetailJson());
      final updated = await repository.updateEmployeeProfile(
        original,
        displayName: original.displayName,
        departmentId: original.department.id,
        jobRoleId: original.jobRole.id,
        dateJoined: original.dateJoined!,
        updateReportingManager: true,
        reportingManagerId: 3,
      );
      expect(updated.reportingManager, 'New manager');
      expect(updated.reportingManagerId, 3);
      verify(
        () => dio.patch(
          '/management/employees/1/',
          data: {'reporting_manager': 3},
          cancelToken: null,
        ),
      ).called(1);
    },
  );

  test('Department and Job Role POST sends all writable fields', () async {
    for (final kind in ReferenceKind.values) {
      final path = '/management/${kind.path}/';
      replyMutation(path, referenceJson(), patch: false);
      final created = await repository.saveReference(
        kind,
        code: 'REF1',
        name: 'Operations 1',
        description: 'Organization reference',
        isActive: true,
      );
      expect(created.id, 1);
      verify(
        () => dio.post(
          path,
          data: {
            'code': 'REF1',
            'name': 'Operations 1',
            'description': 'Organization reference',
            'is_active': true,
          },
          cancelToken: null,
        ),
      ).called(1);
    }
  });

  test(
    'PATCH sends only changed fields and preserves values changed elsewhere',
    () async {
      for (final kind in ReferenceKind.values) {
        final path = '/management/${kind.path}/1/';
        final response = referenceJson()
          ..['name'] = 'Updated name'
          ..['code'] = 'Changed elsewhere'
          ..['description'] = 'Changed elsewhere too'
          ..['is_active'] = false;
        replyMutation(path, response, patch: true);
        final updated = await repository.saveReference(
          kind,
          id: 1,
          original: const OrganizationReference(
            id: 1,
            code: 'REF1',
            name: 'Operations 1',
            description: 'Organization reference',
          ),
          code: 'REF1',
          name: 'Updated name',
          description: 'Organization reference',
          isActive: true,
        );
        expect(updated.code, 'Changed elsewhere');
        expect(updated.description, 'Changed elsewhere too');
        expect(updated.isActive, isFalse);
        verify(
          () => dio.patch(
            path,
            data: {'name': 'Updated name'},
            cancelToken: null,
          ),
        ).called(1);
      }
    },
  );

  test(
    'employee profile PATCH rejects success responses missing manager ID',
    () async {
      when(
        () => dio.patch(
          '/management/employees/1/',
          data: any(named: 'data'),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer(
        (_) async => Response(
          requestOptions: RequestOptions(path: '/management/employees/1/'),
          data: employeeJson()..['display_name'] = 'Changed',
        ),
      );
      final original = DirectoryEmployee.fromJson(employeeDetailJson());
      await expectLater(
        repository.updateEmployeeProfile(
          original,
          displayName: 'Changed',
          departmentId: original.department.id,
          jobRoleId: original.jobRole.id,
          dateJoined: original.dateJoined!,
          updateReportingManager: false,
        ),
        throwsA(isA<ApiError>()),
      );
    },
  );

  test('PATCH includes boolean false when active status changes', () async {
    const original = OrganizationReference(
      id: 1,
      code: 'REF1',
      name: 'Operations 1',
      description: 'Organization reference',
    );
    replyMutation(
      '/management/departments/1/',
      referenceJson()..['is_active'] = false,
      patch: true,
    );
    final updated = await repository.saveReference(
      ReferenceKind.departments,
      id: 1,
      original: original,
      code: original.code,
      name: original.name,
      description: original.description,
      isActive: false,
    );
    expect(updated.isActive, isFalse);
    verify(
      () => dio.patch(
        '/management/departments/1/',
        data: {'is_active': false},
        cancelToken: null,
      ),
    ).called(1);
  });

  test(
    'unchanged or mismatched reference edits are rejected before networking',
    () async {
      const original = OrganizationReference(
        id: 1,
        code: 'REF1',
        name: 'Operations 1',
      );
      await expectLater(
        repository.saveReference(
          ReferenceKind.departments,
          id: 1,
          original: original,
          code: original.code,
          name: original.name,
          description: original.description,
          isActive: original.isActive,
        ),
        throwsArgumentError,
      );
      await expectLater(
        repository.saveReference(
          ReferenceKind.departments,
          id: 1,
          original: const OrganizationReference(
            id: 2,
            code: 'REF2',
            name: 'Other',
          ),
          code: 'REF1',
          name: 'Changed',
          description: '',
          isActive: true,
        ),
        throwsArgumentError,
      );
      verifyZeroInteractions(dio);
    },
  );

  test('mutations preserve server errors and reject invalid IDs or mismatched records', () async {
    final denied = ApiError(message: 'Not authorized.', statusCode: 403);
    when(
      () => dio.post(
        '/management/departments/',
        data: any(named: 'data'),
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenThrow(denied);
    await expectLater(
      repository.saveReference(
        ReferenceKind.departments,
        code: 'D1',
        name: 'Department',
        description: '',
        isActive: true,
      ),
      throwsA(same(denied)),
    );
    await expectLater(
      repository.saveReference(
        ReferenceKind.departments,
        id: 0,
        code: 'D1',
        name: 'Department',
        description: '',
        isActive: true,
      ),
      throwsArgumentError,
    );
    replyMutation('/management/job-roles/2/', referenceJson(3), patch: true);
    await expectLater(
      repository.saveReference(
        ReferenceKind.jobRoles,
        id: 2,
        original: const OrganizationReference(id: 2, code: 'R2', name: 'Role'),
        code: 'R2',
        name: 'Changed role',
        description: '',
        isActive: true,
      ),
      throwsA(isA<ApiError>()),
    );
  });

  test('empty pages and nullable reporting relationships are represented correctly', () async {
    reply('/management/employees/', pageJson([]));
    expect((await repository.employees()).items, isEmpty);
    final employee = employeeDetailJson()
      ..['reporting_manager'] = null
      ..['reporting_manager_id'] = null;
    reply('/management/employees/1/', employee);
    final detail = await repository.employee(1);
    expect(detail.reportingManager, isNull);
    expect(detail.reportingManagerId, isNull);
  });

  test('invalid identifiers are rejected before networking', () async {
    await expectLater(repository.employee(0), throwsArgumentError);
    await expectLater(repository.employees(page: 0), throwsArgumentError);
    await expectLater(repository.employees(pageSize: 0), throwsArgumentError);
    await expectLater(repository.employees(pageSize: 101), throwsArgumentError);
    expect(() => repository.employees(departmentId: 0), throwsArgumentError);
    expect(() => repository.employees(jobRoleId: 0), throwsArgumentError);
    await expectLater(
      repository.references(ReferenceKind.jobRoles, page: -1),
      throwsArgumentError,
    );
    await expectLater(
      repository.employeeEditChoices(employeeId: 1, pageSize: 0),
      throwsArgumentError,
    );
    verifyZeroInteractions(dio);
  });

  test('structured authorization failures and network errors are mapped without retries', () async {
    for (final status in [401, 403, 404, 500]) {
      final error = ApiError(message: 'Controlled failure', statusCode: status);
      when(
        () => dio.get(
          '/management/dashboard/',
          queryParameters: null,
          cancelToken: null,
        ),
      ).thenThrow(error);
      await expectLater(repository.dashboard(), throwsA(same(error)));
    }
    verify(
      () => dio.get(
        '/management/dashboard/',
        queryParameters: null,
        cancelToken: null,
      ),
    ).called(4);
  });

  test('cancelled responses are not parsed as current data', () async {
    final token = CancelToken()..cancel();
    reply('/management/dashboard/', managementDashboardJson());
    await expectLater(
      repository.dashboard(cancelToken: token),
      throwsA(isA<ApiError>()),
    );
    verify(() => client.mapExceptionToApiError(any(that: isA<DioException>())))
        .called(1);
  });

  test('mismatched employee detail identifiers fail closed', () async {
    reply('/management/employees/2/', employeeDetailJson(99));
    await expectLater(repository.employee(2), throwsA(isA<ApiError>()));
  });

  test('malformed scope and empty continuing pages are rejected', () {
    expect(
      () => ManagementDashboard.fromJson(
        managementDashboardJson()..['scope'] = 'all',
      ),
      throwsFormatException,
    );
    expect(
      () => ManagementPage.fromJson(
        pageJson([], next: 'next'),
        DirectoryEmployee.fromJson,
      ),
      throwsFormatException,
    );
  });

  group('Assignable training versions and assignment creation', () {
    test('assignableTrainingVersions queries endpoint with pagination and search', () async {
      reply(
        '/management/training-versions/',
        pageJson([
          assignableVersionJson(
            10,
            trainingId: 5,
            code: 'SAFE',
            trainingTitle: 'Safety 101',
            title: 'Safety 101 v1',
            versionNumber: 1,
            publishedAt: '2026-10-27T10:00:00Z',
          ),
        ]),
      );

      final page = await repository.assignableTrainingVersions();
      expect(page.items.length, 1);
      final item = page.items.single;
      expect(item.id, 10);
      expect(item.trainingId, 5);
      expect(item.trainingCode, 'SAFE');
      expect(item.trainingTitle, 'Safety 101');
      expect(item.title, 'Safety 101 v1');
      expect(item.versionNumber, 1);
      expect(item.publishedAt, '2026-10-27T10:00:00Z');

      verify(
        () => dio.get(
          '/management/training-versions/',
          queryParameters: null,
          cancelToken: any(named: 'cancelToken'),
        ),
      ).called(1);
    });

    test('assignableTrainingVersions trims search and forwards page', () async {
      when(
        () => dio.get(
          '/management/training-versions/',
          queryParameters: {'page': 2, 'search': 'safety'},
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer(
        (_) async => Response(
          requestOptions: RequestOptions(path: '/management/training-versions/'),
          data: pageJson([assignableVersionJson(11)]),
        ),
      );

      final page = await repository.assignableTrainingVersions(
        page: 2,
        search: '  safety  ',
      );
      expect(page.items.single.id, 11);
    });

    test('assignableTrainingVersions rejects invalid page or page size', () async {
      await expectLater(
        repository.assignableTrainingVersions(page: 0),
        throwsArgumentError,
      );
      await expectLater(
        repository.assignableTrainingVersions(pageSize: 0),
        throwsArgumentError,
      );
      await expectLater(
        repository.assignableTrainingVersions(pageSize: 101),
        throwsArgumentError,
      );
      verifyZeroInteractions(dio);
    });

    test('assignTraining posts assignment data and parses created assignment', () async {
      when(
        () => dio.post(
          '/management/assignments/',
          data: {
            'employee_id': 42,
            'training_version_id': 12,
            'due_date': '2026-11-30',
          },
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer(
        (_) async => Response(
          requestOptions: RequestOptions(path: '/management/assignments/'),
          statusCode: 201,
          data: createdAssignmentJson(
            id: 99,
            employeeId: 42,
            trainingVersionId: 12,
            dueDate: '2026-11-30',
          ),
        ),
      );

      final created = await repository.assignTraining(
        employeeId: 42,
        trainingVersionId: 12,
        dueDate: '2026-11-30',
      );

      expect(created.id, 99);
      expect(created.employeeId, 42);
      expect(created.trainingVersionId, 12);
      expect(created.status, 'ASSIGNED');
      expect(created.source, 'MANUAL');
      expect(created.dueAt, '2026-11-30T23:59:59Z');
    });

    test('assignTraining omits due_date when null or empty', () async {
      when(
        () => dio.post(
          '/management/assignments/',
          data: {
            'employee_id': 42,
            'training_version_id': 12,
          },
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer(
        (_) async => Response(
          requestOptions: RequestOptions(path: '/management/assignments/'),
          statusCode: 201,
          data: createdAssignmentJson(
            id: 100,
            employeeId: 42,
            trainingVersionId: 12,
          ),
        ),
      );

      final created = await repository.assignTraining(
        employeeId: 42,
        trainingVersionId: 12,
      );
      expect(created.id, 100);
      expect(created.dueAt, isNull);
    });

    test('assignTraining rejects non-positive employeeId or trainingVersionId', () async {
      await expectLater(
        repository.assignTraining(employeeId: 0, trainingVersionId: 12),
        throwsArgumentError,
      );
      await expectLater(
        repository.assignTraining(employeeId: 42, trainingVersionId: 0),
        throwsArgumentError,
      );
      verifyZeroInteractions(dio);
    });

    test('assignTraining maps errors via mapExceptionToApiError', () async {
      when(
        () => dio.post(
          '/management/assignments/',
          data: any(named: 'data'),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenThrow(
        DioException(
          requestOptions: RequestOptions(path: '/management/assignments/'),
          response: Response(
            requestOptions: RequestOptions(path: '/management/assignments/'),
            statusCode: 400,
            data: {
              'error': {
                'code': 'validation_error',
                'message': 'This employee already has an assignment for that training version.',
              },
            },
          ),
        ),
      );

      await expectLater(
        repository.assignTraining(employeeId: 42, trainingVersionId: 12),
        throwsA(isA<ApiError>()),
      );
    });

    test('employeeAssignments requests /management/employees/{id}/assignments/ and parses page', () async {
      reply(
        '/management/employees/42/assignments/',
        pageJson([
          employeeAssignmentSummaryJson(
            id: 101,
            trainingTitle: 'Hazard Communication',
            versionNumber: 2,
            status: 'IN_PROGRESS',
            assignedAt: '2026-10-01T08:00:00Z',
            dueAt: '2026-10-15T23:59:59Z',
            isOverdue: true,
            progressSummary: {
              'required_lessons_completed': 3,
              'required_lessons_total': 5,
            },
          ),
        ], count: 1),
        page: 1,
      );

      final page = await repository.employeeAssignments(42);
      expect(page.count, 1);
      expect(page.hasMore, isFalse);
      expect(page.items.length, 1);
      final item = page.items.first;
      expect(item.id, 101);
      expect(item.trainingTitle, 'Hazard Communication');
      expect(item.versionNumber, 2);
      expect(item.status, 'IN_PROGRESS');
      expect(item.isOverdue, isTrue);
      expect(item.assignedAt, DateTime.utc(2026, 10, 1, 8, 0, 0));
      expect(item.dueAt, DateTime.utc(2026, 10, 15, 23, 59, 59));
      expect(item.progressSummary?.requiredLessonsCompleted, 3);
      expect(item.progressSummary?.requiredLessonsTotal, 5);
    });

    test('employeeAssignments validates arguments', () async {
      expect(() => repository.employeeAssignments(0), throwsArgumentError);
      expect(() => repository.employeeAssignments(-1), throwsArgumentError);
      await expectLater(
        repository.employeeAssignments(42, page: 0),
        throwsArgumentError,
      );
      await expectLater(
        repository.employeeAssignments(42, pageSize: 0),
        throwsArgumentError,
      );
      await expectLater(
        repository.employeeAssignments(42, pageSize: 101),
        throwsArgumentError,
      );
      verifyZeroInteractions(dio);
    });

    test('employeeAssignments maps DioException to ApiError', () async {
      when(
        () => dio.get(
          '/management/employees/42/assignments/',
          queryParameters: any(named: 'queryParameters'),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenThrow(
        DioException(
          requestOptions: RequestOptions(path: '/management/employees/42/assignments/'),
          response: Response(
            requestOptions: RequestOptions(path: '/management/employees/42/assignments/'),
            statusCode: 404,
            data: {'detail': 'Employee not found or outside reporting scope.'},
          ),
        ),
      );

      await expectLater(
        repository.employeeAssignments(42),
        throwsA(isA<ApiError>()),
      );
    });
  });
}
