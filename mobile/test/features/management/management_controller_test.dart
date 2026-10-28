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

  group('Training management capabilities', () {
    test('canManageTraining grants course, version, module, and lesson capabilities', () {
      final courseViewer = managementIdentity(
        capabilities: {'training.view_training'},
      );
      final courseAuthor = managementIdentity(
        capabilities: {'training.add_training'},
      );
      final courseEditor = managementIdentity(
        capabilities: {'training.change_training'},
      );
      final versionViewer = managementIdentity(
        capabilities: {'training.view_trainingversion'},
      );
      final versionAuthor = managementIdentity(
        capabilities: {'training.add_trainingversion'},
      );
      final versionEditor = managementIdentity(
        capabilities: {'training.change_trainingversion'},
      );
      final moduleAuthor = managementIdentity(
        capabilities: {'training.add_module'},
      );
      final lessonEditor = managementIdentity(
        capabilities: {'training.change_lesson'},
      );
      final teamManager = managementIdentity(
        team: true,
        capabilities: {'team_workspace', 'team_assignment'},
      );
      final directoryViewer = managementIdentity(
        capabilities: {'organization.view_employee'},
      );

      expect(canManageTraining(courseViewer), isTrue);
      expect(canManageTraining(courseAuthor), isTrue);
      expect(canManageTraining(courseEditor), isTrue);
      expect(canManageTraining(versionViewer), isTrue);
      expect(canManageTraining(versionAuthor), isTrue);
      expect(canManageTraining(versionEditor), isTrue);
      expect(canManageTraining(moduleAuthor), isTrue);
      expect(canManageTraining(lessonEditor), isTrue);
      expect(canManageTraining(teamManager), isFalse);
      expect(canManageTraining(directoryViewer), isFalse);

      expect(canViewTraining(courseViewer), isTrue);
      expect(canViewTraining(versionViewer), isFalse);
      expect(canCreateTraining(courseAuthor), isTrue);
      expect(canCreateTraining(courseViewer), isFalse);
      expect(canEditTraining(courseEditor), isTrue);
      expect(canEditTraining(courseViewer), isFalse);

      expect(canViewVersions(versionViewer), isTrue);
      expect(canViewVersions(courseViewer), isFalse);
      expect(canCreateVersions(versionAuthor), isTrue);
      expect(canCreateVersions(versionViewer), isFalse);
      expect(canEditVersions(versionEditor), isTrue);
      expect(canEditVersions(versionViewer), isFalse);

      expect(canManageVersions(versionViewer), isTrue);
      expect(canManageVersions(versionAuthor), isTrue);
      expect(canManageVersions(versionEditor), isTrue);
      expect(canManageVersions(courseViewer), isFalse);

      expect(canCreateModules(moduleAuthor), isTrue);
      expect(canCreateModules(courseViewer), isFalse);
      expect(canEditLessons(lessonEditor), isTrue);
      expect(canEditLessons(courseViewer), isFalse);
    });

    test('training-only identity resolves homePath to /workspace', () {
      final pureVersionViewer = managementIdentity(
        capabilities: {'training.view_trainingversion'},
      );
      expect(pureVersionViewer.canManage, isFalse);
      expect(pureVersionViewer.canViewTeam, isFalse);
      expect(pureVersionViewer.canManageTraining, isTrue);
      expect(pureVersionViewer.homePath, '/workspace');

      final nonLearnerCoordinator = managementIdentity(
        capabilities: {'training.view_training'},
      );
      expect(nonLearnerCoordinator.homePath, '/workspace');
    });
  });

  group('Training assignment controller and permissions', () {
    test('canAssignTraining requires global or team assignment capability', () {
      expect(
        canAssignTraining(
          managementIdentity(capabilities: {'training.add_trainingassignment'}),
        ),
        isTrue,
      );
      expect(
        canAssignTraining(
          managementIdentity(team: true, capabilities: {'team_assignment'}),
        ),
        isTrue,
      );
      expect(
        canAssignTraining(
          managementIdentity(capabilities: {'company_dashboard'}),
        ),
        isFalse,
      );
      expect(
        canAssignTraining(
          managementIdentity(capabilities: {'organization.view_employee'}),
        ),
        isFalse,
      );
    });

    test('canAssignTrainingToEmployee blocks inactive employees and manager self-assignment', () {
      final teamManager = managementIdentity(
        team: true,
        capabilities: {'team_assignment'},
      );
      final subordinate = DirectoryEmployee.fromJson(employeeJson(10));
      final selfEmployee = DirectoryEmployee.fromJson(
        employeeJson(2)..['employee_code'] = 'MGR',
      );
      final inactiveSubordinate = DirectoryEmployee.fromJson(
        employeeJson(11)..['is_active'] = false,
      );

      // Subordinate is allowed for team manager
      expect(
        canAssignTrainingToEmployee(
          identity: teamManager,
          employee: subordinate,
        ),
        isTrue,
      );

      // Self-assignment is blocked for team manager
      expect(
        canAssignTrainingToEmployee(
          identity: teamManager,
          employee: selfEmployee,
        ),
        isFalse,
      );

      // Inactive employee is blocked
      expect(
        canAssignTrainingToEmployee(
          identity: teamManager,
          employee: inactiveSubordinate,
        ),
        isFalse,
      );

      // Global company assigner can assign to any active employee
      final companyAdmin = managementIdentity(
        capabilities: {'training.add_trainingassignment'},
      );
      expect(
        canAssignTrainingToEmployee(
          identity: companyAdmin,
          employee: subordinate,
        ),
        isTrue,
      );
      expect(
        canAssignTrainingToEmployee(
          identity: companyAdmin,
          employee: inactiveSubordinate,
        ),
        isFalse,
      );
    });

    test('assignableTrainingVersionsProvider rejects unauthorized users', () async {
      final unauthorizedIdentity = managementIdentity(
        capabilities: {'organization.view_employee'},
      );
      auth.setAuth(AuthAuthenticated.identity(unauthorizedIdentity));

      final target = assignableTrainingVersionsProvider((
        page: 1,
        search: null,
      ));
      await expectLater(
        container.read(target.future),
        throwsA(isA<ApiError>().having((e) => e.statusCode, 'statusCode', 403)),
      );
      verifyZeroInteractions(repository);
    });

    test('assignableTrainingVersionsProvider forwards request parameters and cancels on disposal', () async {
      final authorizedIdentity = managementIdentity(
        capabilities: {'training.add_trainingassignment'},
      );
      auth.setAuth(AuthAuthenticated.identity(authorizedIdentity));

      final response = Completer<ManagementPage<AssignableTrainingVersion>>();
      late CancelToken token;
      when(
        () => repository.assignableTrainingVersions(
          page: 2,
          search: 'safety',
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer((call) {
        token = call.namedArguments[#cancelToken] as CancelToken;
        return response.future;
      });

      final target = assignableTrainingVersionsProvider((
        page: 2,
        search: 'safety',
      ));
      final sub = container.listen(target, (_, _) {});
      addTearDown(sub.close);
      await Future<void>.delayed(Duration.zero);

      sub.close();
      await container.pump();
      expect(token.isCancelled, isTrue);
      response.complete(assignableVersionPage());
    });

    test('TrainingAssignmentMutationController rejects unauthorized attempts', () async {
      final unauthorizedIdentity = managementIdentity(
        capabilities: {'organization.view_employee'},
      );
      final mutationController = TrainingAssignmentMutationController(
        repository: repository,
        readAuth: () => AuthAuthenticated.identity(unauthorizedIdentity),
      );

      await expectLater(
        mutationController.assign(
          employeeId: 5,
          employeeCode: 'EMP5',
          trainingVersionId: 10,
        ),
        throwsA(
          isA<ApiError>().having((e) => e.statusCode, 'statusCode', 403),
        ),
      );
      verifyZeroInteractions(repository);
    });

    test('TrainingAssignmentMutationController blocks team manager self-assignment before networking', () async {
      final teamManager = managementIdentity(
        team: true,
        capabilities: {'team_assignment'},
      );
      final mutationController = TrainingAssignmentMutationController(
        repository: repository,
        readAuth: () => AuthAuthenticated.identity(teamManager),
      );

      await expectLater(
        mutationController.assign(
          employeeId: 2,
          employeeCode: 'MGR',
          trainingVersionId: 10,
        ),
        throwsA(
          isA<ApiError>().having((e) => e.statusCode, 'statusCode', 400),
        ),
      );
      verifyZeroInteractions(repository);
    });

    test('TrainingAssignmentMutationController delegates to repository for authorized manager', () async {
      final teamManager = managementIdentity(
        team: true,
        capabilities: {'team_assignment'},
      );
      final mutationController = TrainingAssignmentMutationController(
        repository: repository,
        readAuth: () => AuthAuthenticated.identity(teamManager),
      );

      when(
        () => repository.assignTraining(
          employeeId: 5,
          trainingVersionId: 10,
          dueDate: '2026-11-30',
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer(
        (_) async => CreatedAssignment.fromJson(
          createdAssignmentJson(
            id: 101,
            employeeId: 5,
            trainingVersionId: 10,
            dueDate: '2026-11-30',
          ),
        ),
      );

      final result = await mutationController.assign(
        employeeId: 5,
        employeeCode: 'EMP5',
        trainingVersionId: 10,
        dueDate: '2026-11-30',
      );

      expect(result.id, 101);
      expect(result.employeeId, 5);
      expect(result.trainingVersionId, 10);
      expect(result.dueAt, '2026-11-30T23:59:59Z');
      verify(
        () => repository.assignTraining(
          employeeId: 5,
          trainingVersionId: 10,
          dueDate: '2026-11-30',
          cancelToken: any(named: 'cancelToken'),
        ),
      ).called(1);
    });

    test('TrainingAssignmentMutationController discards response if account switches mid-flight', () async {
      final manager1 = managementIdentity(
        username: 'manager_one',
        team: true,
        capabilities: {'team_assignment'},
      );
      final manager2 = managementIdentity(
        username: 'manager_two',
        team: true,
        capabilities: {'team_assignment'},
      );
      var currentAuth = AuthAuthenticated.identity(manager1);
      final mutationController = TrainingAssignmentMutationController(
        repository: repository,
        readAuth: () => currentAuth,
      );

      final responseCompleter = Completer<CreatedAssignment>();
      when(
        () => repository.assignTraining(
          employeeId: 5,
          trainingVersionId: 10,
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer((_) => responseCompleter.future);

      final future = mutationController.assign(
        employeeId: 5,
        employeeCode: 'EMP5',
        trainingVersionId: 10,
      );

      // Account changes mid-flight
      currentAuth = AuthAuthenticated.identity(manager2);
      responseCompleter.complete(
        CreatedAssignment.fromJson(
          createdAssignmentJson(id: 102, employeeId: 5, trainingVersionId: 10),
        ),
      );

      await expectLater(
        future,
        throwsA(
          isA<ApiError>().having((e) => e.statusCode, 'statusCode', 403),
        ),
      );
    });
  });

  group('employeeAssignmentsProvider and canViewEmployeeAssignments', () {
    test('canViewEmployeeAssignments grants managers and admins, denies directory-only viewers', () {
      final admin = managementIdentity(
        capabilities: {'training.add_trainingassignment'},
      );
      final managerWithTeam = managementIdentity(
        team: true,
        capabilities: {'team_workspace', 'assignment_report'},
      );
      final managerWithTeamAssignment = managementIdentity(
        team: true,
        capabilities: {'team_assignment'},
      );
      final directoryOnlyViewer = managementIdentity(
        capabilities: {'organization.view_employee'},
      );

      expect(canViewEmployeeAssignments(admin), isTrue);
      expect(canViewEmployeeAssignments(managerWithTeam), isTrue);
      expect(canViewEmployeeAssignments(managerWithTeamAssignment), isTrue);
      expect(canViewEmployeeAssignments(directoryOnlyViewer), isFalse);

      expect(hasCompanyAssignmentAuthority(admin), isTrue);
      expect(hasCompanyAssignmentAuthority(managerWithTeam), isFalse);

      // Self-monitoring visibility (isCurrentEmployee = true)
      expect(canViewEmployeeAssignments(admin, isCurrentEmployee: true), isTrue);
      expect(canViewEmployeeAssignments(managerWithTeam, isCurrentEmployee: true), isFalse);
      expect(canViewEmployeeAssignments(managerWithTeamAssignment, isCurrentEmployee: true), isFalse);
      expect(canViewEmployeeAssignments(directoryOnlyViewer, isCurrentEmployee: true), isFalse);

      final mixedRoleManager = managementIdentity(
        team: true,
        capabilities: {
          'team_workspace',
          'team_assignment',
          'training.add_trainingassignment',
        },
      );
      expect(hasCompanyAssignmentAuthority(mixedRoleManager), isTrue);
      expect(canViewEmployeeAssignments(mixedRoleManager, isCurrentEmployee: true), isTrue);
      expect(canViewEmployeeAssignments(mixedRoleManager, isCurrentEmployee: false), isTrue);
    });

    test('employeeAssignmentsProvider queries repository when authorized', () async {
      auth.setAuth(
        AuthAuthenticated.identity(
          managementIdentity(
            team: true,
            capabilities: {'team_assignment', 'organization.view_employee'},
          ),
        ),
      );

      when(
        () => repository.employeeAssignments(
          15,
          page: 1,
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer(
        (_) async => employeeAssignmentPage(
          id: 201,
          trainingTitle: 'Safety Induction',
          status: 'COMPLETED',
        ),
      );

      final page = await container.read(
        employeeAssignmentsProvider((employeeId: 15, page: 1)).future,
      );

      expect(page.items.length, 1);
      expect(page.items.first.trainingTitle, 'Safety Induction');
      expect(page.items.first.status, 'COMPLETED');
      verify(
        () => repository.employeeAssignments(
          15,
          page: 1,
          cancelToken: any(named: 'cancelToken'),
        ),
      ).called(1);
    });

    test('employeeAssignmentsProvider throws 403 when user lacks assignment viewing authority', () async {
      auth.setAuth(
        AuthAuthenticated.identity(
          managementIdentity(
            capabilities: {'organization.view_employee'},
          ),
        ),
      );

      await expectLater(
        container.read(
          employeeAssignmentsProvider((employeeId: 15, page: 1)).future,
        ),
        throwsA(
          isA<ApiError>().having((e) => e.statusCode, 'statusCode', 403),
        ),
      );
      verifyZeroInteractions(repository);
    });

    test('employeeAssignmentsProvider cancels request when account switches', () async {
      auth.setAuth(
        AuthAuthenticated.identity(
          managementIdentity(
            username: 'manager_a',
            team: true,
            capabilities: {'team_assignment', 'organization.view_employee'},
          ),
        ),
      );

      final tokens = <CancelToken>[];
      final completer = Completer<ManagementPage<EmployeeAssignmentSummary>>();
      when(
        () => repository.employeeAssignments(
          15,
          page: 1,
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer((call) {
        tokens.add(call.namedArguments[#cancelToken] as CancelToken);
        return completer.future;
      });

      final sub = container.listen(
        employeeAssignmentsProvider((employeeId: 15, page: 1)),
        (_, _) {},
      );
      addTearDown(sub.close);
      await Future<void>.delayed(Duration.zero);

      // Account switches to another user
      auth.setAuth(
        AuthAuthenticated.identity(
          managementIdentity(
            username: 'manager_b',
            team: true,
            capabilities: {'team_assignment', 'organization.view_employee'},
          ),
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(tokens.first.isCancelled, isTrue);
    });
  });
}
