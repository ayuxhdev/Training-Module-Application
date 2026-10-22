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

  test('choice pagination deduplicates records by ID and halts on stagnant loop', () async {
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
    reply(
      '/management/employees/',
      pageJson([employeeJson(1), employeeJson(2)], count: 3, next: 'next'),
      pageSize: 100,
    );
    // Page 2 returns duplicate employee 2 and new employee 3
    reply(
      '/management/employees/',
      pageJson([employeeJson(2), employeeJson(3)]),
      page: 2,
      pageSize: 100,
    );

    final choices = await repository.employeeEditChoices(employeeId: 1);
    expect(choices.departments.map((d) => d.id), [1, 2]);
    expect(choices.jobRoles.map((r) => r.id), [1, 2]);
    expect(choices.reportingManagers.map((m) => m.id), [2, 3]);
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
}
