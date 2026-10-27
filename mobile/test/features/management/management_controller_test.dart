import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:training_app/core/errors/api_error.dart';
import 'package:training_app/features/auth/domain/models/auth_state.dart';
import 'package:training_app/features/auth/presentation/controllers/auth_controller.dart';
import 'package:training_app/features/management/data/repositories/management_repository.dart';
import 'package:training_app/features/management/domain/models/management_models.dart';
import 'package:training_app/features/management/presentation/controllers/management_controller.dart';

import 'management_fixtures.dart';

class RepositoryMock extends Mock implements ManagementRepository {}

EmployeeDirectoryRequest _directoryRequest(int page) => (
  page: page,
  search: null,
  departmentId: null,
  jobRoleId: null,
  isActive: null,
);

void main() {
  late RepositoryMock repository;
  late ManagementTestAuth auth;
  late ProviderContainer container;
  setUpAll(() => registerFallbackValue(CancelToken()));
  setUp(() {
    repository = RepositoryMock();
    auth = ManagementTestAuth(managementIdentity());
    container = ProviderContainer(
      overrides: [
        authControllerProvider.overrideWith(() => auth),
        managementRepositoryProvider.overrideWithValue(repository),
      ],
    );
    container.read(authControllerProvider);
  });
  tearDown(() => container.dispose());

  test(
    'reference mutations require exact server-issued capabilities',
    () async {
      final identity = managementIdentity(
        capabilities: {'organization.view_department'},
      );
      final mutations = OrganizationReferenceMutationController(
        repository: repository,
        readAuth: () => AuthAuthenticated.identity(identity),
      );
      await expectLater(
        mutations.save(
          kind: ReferenceKind.departments,
          code: 'D1',
          name: 'Department',
          description: '',
          isActive: true,
        ),
        throwsA(isA<ApiError>()),
      );
      await expectLater(
        mutations.save(
          kind: ReferenceKind.departments,
          id: 1,
          code: 'D1',
          name: 'Department',
          description: '',
          isActive: true,
        ),
        throwsA(isA<ApiError>()),
      );
      verifyZeroInteractions(repository);
    },
  );

  test(
    'reference mutation discards a response after the account changes',
    () async {
      final response = Completer<OrganizationReference>();
      final manager = managementIdentity(
        username: 'first',
        capabilities: {'organization.change_department'},
      );
      var currentAuth = AuthAuthenticated.identity(manager);
      when(
        () => repository.saveReference(
          ReferenceKind.departments,
          id: 1,
          original: const OrganizationReference(
            id: 1,
            code: 'D1',
            name: 'Department',
          ),
          code: 'D1',
          name: 'Updated department',
          description: 'Existing description',
          isActive: true,
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer((_) => response.future);
      final mutations = OrganizationReferenceMutationController(
        repository: repository,
        readAuth: () => currentAuth,
      );
      final pending = mutations.save(
        kind: ReferenceKind.departments,
        id: 1,
        original: const OrganizationReference(
          id: 1,
          code: 'D1',
          name: 'Department',
        ),
        code: 'D1',
        name: 'Updated department',
        description: 'Existing description',
        isActive: true,
      );
      currentAuth = AuthAuthenticated.identity(
        managementIdentity(
          username: 'second',
          capabilities: {'organization.change_department'},
        ),
      );
      response.complete(OrganizationReference.fromJson(referenceJson()));
      await expectLater(pending, throwsA(isA<ApiError>()));
    },
  );

  test('employee profile mutation requires the change capability', () async {
    final mutations = EmployeeProfileMutationController(
      repository: repository,
      readAuth: () => AuthAuthenticated.identity(
        managementIdentity(capabilities: {'organization.view_employee'}),
      ),
    );
    await expectLater(
      mutations.save(
        original: DirectoryEmployee.fromJson(employeeJson()),
        displayName: 'Updated',
        departmentId: 1,
        jobRoleId: 1,
        dateJoined: '2020-01-02',
        updateReportingManager: false,
      ),
      throwsA(isA<ApiError>()),
    );
    verifyZeroInteractions(repository);
  });

  test(
    'employee profile mutation discards a response after account switching',
    () async {
      final response = Completer<DirectoryEmployee>();
      var currentAuth = AuthAuthenticated.identity(
        managementIdentity(
          username: 'first',
          capabilities: {'organization.change_employee'},
        ),
      );
      final original = DirectoryEmployee.fromJson(employeeJson());
      when(
        () => repository.updateEmployeeProfile(
          original,
          displayName: 'Updated',
          departmentId: 1,
          jobRoleId: 1,
          dateJoined: '2020-01-02',
          updateReportingManager: false,
          reportingManagerId: null,
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer((_) => response.future);
      final mutations = EmployeeProfileMutationController(
        repository: repository,
        readAuth: () => currentAuth,
      );
      final pending = mutations.save(
        original: original,
        displayName: 'Updated',
        departmentId: 1,
        jobRoleId: 1,
        dateJoined: '2020-01-02',
        updateReportingManager: false,
      );
      currentAuth = AuthAuthenticated.identity(
        managementIdentity(
          username: 'second',
          capabilities: {'organization.change_employee'},
        ),
      );
      response.complete(
        DirectoryEmployee.fromJson(
          employeeJson()..['display_name'] = 'Updated',
        ),
      );
      await expectLater(pending, throwsA(isA<ApiError>()));
    },
  );

  test('employee creation requires the server-issued add capability', () async {
    final mutations = EmployeeCreationMutationController(
      repository: repository,
      readAuth: () => AuthAuthenticated.identity(
        managementIdentity(capabilities: {'organization.view_employee'}),
      ),
    );
    await expectLater(
      mutations.create(
        employeeCode: 'NEW-1',
        displayName: 'New employee',
        departmentId: 1,
        jobRoleId: 1,
        dateJoined: '2026-10-22',
      ),
      throwsA(isA<ApiError>()),
    );
    verifyZeroInteractions(repository);
  });

  test(
    'employee creation returns response only to the initiating account',
    () async {
      final response = Completer<DirectoryEmployee>();
      var currentAuth = AuthAuthenticated.identity(
        managementIdentity(
          username: 'first',
          capabilities: {'organization.add_employee'},
        ),
      );
      when(
        () => repository.createEmployee(
          employeeCode: 'NEW-1',
          displayName: 'New employee',
          departmentId: 1,
          jobRoleId: 1,
          dateJoined: '2026-10-22',
          reportingManagerId: null,
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer((_) => response.future);
      final mutations = EmployeeCreationMutationController(
        repository: repository,
        readAuth: () => currentAuth,
      );
      final pending = mutations.create(
        employeeCode: 'NEW-1',
        displayName: 'New employee',
        departmentId: 1,
        jobRoleId: 1,
        dateJoined: '2026-10-22',
      );
      currentAuth = AuthAuthenticated.identity(
        managementIdentity(
          username: 'second',
          capabilities: {'organization.add_employee'},
        ),
      );
      response.complete(DirectoryEmployee.fromJson(employeeDetailJson(42)));
      await expectLater(pending, throwsA(isA<ApiError>()));
    },
  );

  test(
    'employee deactivation requires change permission and blocks self',
    () async {
      final employee = DirectoryEmployee.fromJson(employeeDetailJson());
      final denied = EmployeeDeactivationMutationController(
        repository: repository,
        readAuth: () => AuthAuthenticated.identity(
          managementIdentity(capabilities: {'organization.view_employee'}),
        ),
      );
      await expectLater(
        denied.deactivate(employee: employee, reason: 'Reason'),
        throwsA(isA<ApiError>()),
      );

      final self = EmployeeDeactivationMutationController(
        repository: repository,
        readAuth: () => AuthAuthenticated.identity(
          managementIdentity(
            team: true,
            capabilities: {
              'organization.view_employee',
              'organization.change_employee',
            },
          ),
        ),
      );
      final currentEmployee = DirectoryEmployee.fromJson(
        employeeDetailJson()..['employee_code'] = 'MGR',
      );
      await expectLater(
        self.deactivate(employee: currentEmployee, reason: 'Reason'),
        throwsA(isA<ApiError>()),
      );
      verifyZeroInteractions(repository);
    },
  );

  test(
    'employee deactivation discards a response after account switching',
    () async {
      final response = Completer<DirectoryEmployee>();
      var currentAuth = AuthAuthenticated.identity(
        managementIdentity(
          username: 'first',
          capabilities: {'organization.change_employee'},
        ),
      );
      final employee = DirectoryEmployee.fromJson(employeeDetailJson());
      when(
        () => repository.deactivateEmployee(
          employee.id,
          reason: 'Employment ended',
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer((_) => response.future);
      final mutation = EmployeeDeactivationMutationController(
        repository: repository,
        readAuth: () => currentAuth,
      );
      final pending = mutation.deactivate(
        employee: employee,
        reason: 'Employment ended',
      );
      currentAuth = AuthAuthenticated.identity(
        managementIdentity(
          username: 'second',
          capabilities: {'organization.change_employee'},
        ),
      );
      response.complete(
        DirectoryEmployee.fromJson(employeeDetailJson()..['is_active'] = false),
      );
      await expectLater(pending, throwsA(isA<ApiError>()));
    },
  );

  test(
    'employee creation choices require the server-issued add capability',
    () async {
      auth.setAuth(
        AuthAuthenticated.identity(
          managementIdentity(capabilities: {'organization.view_employee'}),
        ),
      );
      expect(
        canCreateEmployee(
          managementIdentity(capabilities: {'organization.add_employee'}),
        ),
        isTrue,
      );
      expect(
        canCreateEmployee(
          managementIdentity(capabilities: {'organization.view_employee'}),
        ),
        isFalse,
      );
      await expectLater(
        container.read(employeeCreationChoicesProvider.future),
        throwsA(isA<ApiError>()),
      );
      verifyZeroInteractions(repository);
    },
  );

  test(
    'employee creation choices cancel and discard data after account switch',
    () async {
      final oldResponse = Completer<EmployeeEditChoices>();
      final currentResponse = Completer<EmployeeEditChoices>();
      final tokens = <CancelToken>[];
      when(
        () => repository.employeeCreationChoices(
          includeReportingManagers: any(named: 'includeReportingManagers'),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer((call) {
        expect(call.namedArguments[#includeReportingManagers], isFalse);
        tokens.add(call.namedArguments[#cancelToken] as CancelToken);
        return tokens.length == 1 ? oldResponse.future : currentResponse.future;
      });
      auth.setAuth(
        AuthAuthenticated.identity(
          managementIdentity(
            username: 'first',
            capabilities: {'organization.add_employee'},
          ),
        ),
      );
      final sub = container.listen(employeeCreationChoicesProvider, (_, _) {});
      addTearDown(sub.close);
      await Future<void>.delayed(Duration.zero);
      auth.setAuth(
        AuthAuthenticated.identity(
          managementIdentity(
            username: 'second',
            capabilities: {'organization.add_employee'},
          ),
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(tokens.first.isCancelled, isTrue);
      oldResponse.complete(employeeEditChoicesFixture());
      await Future<void>.delayed(Duration.zero);
      expect(container.read(employeeCreationChoicesProvider).isLoading, isTrue);
      currentResponse.complete(employeeEditChoicesFixture());
      expect(
        (await container.read(employeeCreationChoicesProvider.future))
            .departments
            .first
            .id,
        1,
      );
    },
  );

  test('company, team and paginated directory reads use their repository operations', () async {
    when(() => repository.dashboard(cancelToken: any(named: 'cancelToken')))
        .thenAnswer((_) async => dashboardFixture());
    when(
      () =>
          repository.employees(page: 2, cancelToken: any(named: 'cancelToken')),
    ).thenAnswer((_) async => employeePage(id: 2));
    when(() => repository.employee(2, cancelToken: any(named: 'cancelToken')))
        .thenAnswer((_) async => DirectoryEmployee.fromJson(employeeJson(2)));
    expect(
      (await container.read(managementDashboardProvider.future)).isCompany,
      isTrue,
    );
    expect(
      (await container.read(
        employeeDirectoryProvider(_directoryRequest(2)).future,
      )).items.single.id,
      2,
    );
    expect((await container.read(directoryEmployeeProvider(2).future)).id, 2);
    auth.setAuth(AuthAuthenticated.identity(managementIdentity(team: true)));
    when(() => repository.dashboard(cancelToken: any(named: 'cancelToken')))
        .thenAnswer((_) async => dashboardFixture(team: true));
    expect(
      (await container.read(managementDashboardProvider.future)).isCompany,
      isFalse,
    );
  });

  test(
    'unauthenticated and capability-denied reads never reach repositories',
    () async {
      for (final denied in [
        AuthUnauthenticated(),
        AuthAuthenticated.identity(managementIdentity(capabilities: {})),
      ]) {
        auth.setAuth(denied);
        for (final future in [
          container.read(managementDashboardProvider.future),
          container.read(
            employeeDirectoryProvider(_directoryRequest(1)).future,
          ),
          container.read(directoryEmployeeProvider(1).future),
          container.read(
            organizationReferencesProvider((
              kind: ReferenceKind.departments,
              page: 1,
            )).future,
          ),
        ]) {
          await expectLater(future, throwsA(isA<ApiError>()));
        }
      }
      verifyZeroInteractions(repository);
    },
  );

  test('reference-only permission allows that list without granting dashboard or directory', () async {
    auth.setAuth(
      AuthAuthenticated.identity(
        managementIdentity(
          team: true,
          capabilities: {'personal_learning', 'organization.view_department'},
        ),
      ),
    );
    when(
      () => repository.references(
        ReferenceKind.departments,
        page: 1,
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenAnswer(
      (_) async => ManagementPage.fromJson(
        pageJson([referenceJson()]),
        OrganizationReference.fromJson,
      ),
    );
    expect(
      (await container.read(
        organizationReferencesProvider((
          kind: ReferenceKind.departments,
          page: 1,
        )).future,
      )).count,
      1,
    );
    await expectLater(
      container.read(managementDashboardProvider.future),
      throwsA(isA<ApiError>()),
    );
    await expectLater(
      container.read(employeeDirectoryProvider(_directoryRequest(1)).future),
      throwsA(isA<ApiError>()),
    );
    verifyNever(
      () => repository.dashboard(cancelToken: any(named: 'cancelToken')),
    );
  });

  test('account switch cancels pending directory data and ignores a late old response', () async {
    final old = Completer<ManagementPage<DirectoryEmployee>>();
    final current = Completer<ManagementPage<DirectoryEmployee>>();
    final tokens = <CancelToken>[];
    when(
      () =>
          repository.employees(page: 1, cancelToken: any(named: 'cancelToken')),
    ).thenAnswer((call) {
      tokens.add(call.namedArguments[#cancelToken] as CancelToken);
      return tokens.length == 1 ? old.future : current.future;
    });
    final sub = container.listen(
      employeeDirectoryProvider(_directoryRequest(1)),
      (_, _) {},
    );
    addTearDown(sub.close);
    await Future<void>.delayed(Duration.zero);
    auth.setAuth(
      AuthAuthenticated.identity(managementIdentity(username: 'second')),
    );
    await Future<void>.delayed(Duration.zero);
    expect(tokens.first.isCancelled, isTrue);
    old.complete(employeePage(name: 'Old private employee'));
    await Future<void>.delayed(Duration.zero);
    expect(
      container.read(employeeDirectoryProvider(_directoryRequest(1))).isLoading,
      isTrue,
    );
    current.complete(employeePage(name: 'Current employee'));
    expect(
      (await container.read(
        employeeDirectoryProvider(_directoryRequest(1)).future,
      )).items.single.displayName,
      'Current employee',
    );
  });

  test(
    'permission loss cancels directory requests and prevents a fresh request',
    () async {
      final response = Completer<ManagementPage<DirectoryEmployee>>();
      late CancelToken token;
      when(
        () => repository.employees(
          page: 1,
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer((call) {
        token = call.namedArguments[#cancelToken] as CancelToken;
        return response.future;
      });
      final sub = container.listen(
        employeeDirectoryProvider(_directoryRequest(1)),
        (_, _) {},
      );
      addTearDown(sub.close);
      await Future<void>.delayed(Duration.zero);
      auth.setAuth(
        AuthAuthenticated.identity(
          managementIdentity(capabilities: {'management_workspace'}),
        ),
      );
      await expectLater(
        container.read(employeeDirectoryProvider(_directoryRequest(1)).future),
        throwsA(isA<ApiError>()),
      );
      expect(token.isCancelled, isTrue);
      response.complete(employeePage());
      await Future<void>.delayed(Duration.zero);
      expect(
        container
            .read(employeeDirectoryProvider(_directoryRequest(1)))
            .hasError,
        isTrue,
      );
      verify(
        () => repository.employees(
          page: 1,
          cancelToken: any(named: 'cancelToken'),
        ),
      ).called(1);
    },
  );

  test(
    'logout cancels pending detail and old data cannot restore it',
    () async {
      final response = Completer<DirectoryEmployee>();
      late CancelToken token;
      when(() => repository.employee(1, cancelToken: any(named: 'cancelToken')))
          .thenAnswer((call) {
            token = call.namedArguments[#cancelToken] as CancelToken;
            return response.future;
          });
      final sub = container.listen(directoryEmployeeProvider(1), (_, _) {});
      addTearDown(sub.close);
      await Future<void>.delayed(Duration.zero);
      auth.setAuth(AuthUnauthenticated());
      await expectLater(
        container.read(directoryEmployeeProvider(1).future),
        throwsA(isA<ApiError>()),
      );
      expect(token.isCancelled, isTrue);
      response.complete(DirectoryEmployee.fromJson(employeeJson()));
      await Future<void>.delayed(Duration.zero);
      expect(container.read(directoryEmployeeProvider(1)).hasError, isTrue);
    },
  );

  test('network failure waits for explicit GET refresh instead of automatic retries', () async {
    when(() => repository.dashboard(cancelToken: any(named: 'cancelToken')))
        .thenThrow(ApiError.networkFailure());
    await expectLater(
      container.read(managementDashboardProvider.future),
      throwsA(isA<ApiError>()),
    );
    await Future<void>.delayed(Duration.zero);
    verify(() => repository.dashboard(cancelToken: any(named: 'cancelToken')))
        .called(1);
    when(() => repository.dashboard(cancelToken: any(named: 'cancelToken')))
        .thenAnswer((_) async => dashboardFixture());
    expect(
      (await container.refresh(managementDashboardProvider.future)).isCompany,
      isTrue,
    );
    verify(() => repository.dashboard(cancelToken: any(named: 'cancelToken')))
        .called(1);
  });

  test(
    'reference pagination is account-scoped and late responses are discarded',
    () async {
      final response = Completer<ManagementPage<OrganizationReference>>();
      late CancelToken token;
      when(
        () => repository.references(
          ReferenceKind.jobRoles,
          page: 2,
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer((call) {
        token = call.namedArguments[#cancelToken] as CancelToken;
        return response.future;
      });
      final target = organizationReferencesProvider((
        kind: ReferenceKind.jobRoles,
        page: 2,
      ));
      final sub = container.listen(target, (_, _) {});
      addTearDown(sub.close);
      await Future<void>.delayed(Duration.zero);
      auth.setAuth(AuthUnauthenticated());
      await expectLater(
        container.read(target.future),
        throwsA(isA<ApiError>()),
      );
      expect(token.isCancelled, isTrue);
      response.complete(
        ManagementPage.fromJson(
          pageJson([referenceJson()]),
          OrganizationReference.fromJson,
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(container.read(target).hasError, isTrue);
    },
  );

  test('disposal cancels outstanding dashboard requests', () async {
    final response = Completer<ManagementDashboard>();
    late CancelToken token;
    when(() => repository.dashboard(cancelToken: any(named: 'cancelToken')))
        .thenAnswer((call) {
          token = call.namedArguments[#cancelToken] as CancelToken;
          return response.future;
        });
    final sub = container.listen(managementDashboardProvider, (_, _) {});
    await Future<void>.delayed(Duration.zero);
    sub.close();
    await container.pump();
    expect(token.isCancelled, isTrue);
    response.complete(dashboardFixture());
  });
}
