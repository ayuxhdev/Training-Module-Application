import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';
import 'package:training_app/core/errors/api_error.dart';
import 'package:training_app/core/presentation/components/loading_view.dart';
import 'package:training_app/core/router/app_router.dart';
import 'package:training_app/core/theme/app_theme.dart';
import 'package:training_app/features/auth/domain/models/auth_state.dart';
import 'package:training_app/features/auth/domain/models/authenticated_identity.dart';
import 'package:training_app/features/auth/presentation/controllers/auth_controller.dart';
import 'package:training_app/features/dashboard/domain/models/dashboard_data.dart';
import 'package:training_app/features/dashboard/presentation/controllers/dashboard_controller.dart';
import 'package:training_app/features/management/data/repositories/management_repository.dart';
import 'package:training_app/features/management/domain/models/management_models.dart';
import 'package:training_app/features/management/presentation/screens/organization_screens.dart';
import 'package:training_app/features/management/presentation/screens/organization_reference_form_screen.dart';
import 'package:training_app/features/management/presentation/screens/employee_profile_form_screen.dart';
import 'package:training_app/features/management/presentation/screens/employee_creation_form_screen.dart';
import 'package:training_app/features/management/presentation/widgets/employee_deactivation_dialog.dart';
import 'package:training_app/features/notifications/presentation/controllers/notification_controller.dart';

import 'management_fixtures.dart';

class ScreenRepositoryMock extends Mock implements ManagementRepository {}

class ZeroUnread extends NotificationUnreadController {
  @override
  Future<int?> build() async => 0;
}

void main() {
  late ScreenRepositoryMock repository;
  late ManagementTestAuth auth;
  late GoRouter router;
  setUpAll(() {
    registerFallbackValue(CancelToken());
    registerFallbackValue(DirectoryEmployee.fromJson(employeeJson()));
  });
  setUp(() {
    repository = ScreenRepositoryMock();
    when(() => repository.dashboard(cancelToken: any(named: 'cancelToken')))
        .thenAnswer((_) async => dashboardFixture());
    when(
      () => repository.employees(
        page: any(named: 'page'),
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenAnswer((_) async => employeePage());
    when(
      () => repository.employee(any(), cancelToken: any(named: 'cancelToken')),
    ).thenAnswer(
      (call) async => DirectoryEmployee.fromJson(
        employeeDetailJson(call.positionalArguments.first as int),
      ),
    );
    when(
      () => repository.employeeEditChoices(
        employeeId: any(named: 'employeeId'),
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenAnswer(
      (call) async => employeeEditChoicesFixture(
        employeeId: call.namedArguments[#employeeId] as int,
      ),
    );
    when(
      () => repository.employeeCreationChoices(
        includeReportingManagers: any(named: 'includeReportingManagers'),
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenAnswer((_) async => employeeEditChoicesFixture());
    for (final kind in ReferenceKind.values) {
      when(
        () => repository.references(
          kind,
          page: any(named: 'page'),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer(
        (_) async => ManagementPage.fromJson(
          pageJson([referenceJson()]),
          OrganizationReference.fromJson,
        ),
      );
    }
  });

  Future<void> launch(
    WidgetTester tester, {
    AuthenticatedIdentity? identity,
    String path = '/workspace',
    Brightness brightness = Brightness.light,
    double textScale = 1,
  }) async {
    auth = ManagementTestAuth(identity ?? managementIdentity());
    final container = ProviderContainer(
      overrides: [
        authControllerProvider.overrideWith(() => auth),
        managementRepositoryProvider.overrideWithValue(repository),
        dashboardDataProvider.overrideWith(
          (_) async => DashboardData(
            metrics: DashboardMetrics(
              total: 0,
              assigned: 0,
              inProgress: 0,
              completed: 0,
              cancelled: 0,
              overdue: 0,
              completionPercent: 0,
              certificatesCount: 0,
            ),
            actionRequired: [],
            recentCertificates: [],
          ),
        ),
        notificationUnreadCountProvider.overrideWith(ZeroUnread.new),
      ],
    );
    addTearDown(container.dispose);
    router = container.read(appRouterProvider)..go(path);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(
          routerConfig: router,
          theme: brightness == Brightness.dark
              ? AppTheme.darkTheme
              : AppTheme.lightTheme,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: TextScaler.linear(textScale),
              disableAnimations: true,
            ),
            child: child!,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> tap(WidgetTester tester, String label) async {
    await tester.scrollUntilVisible(
      find.text(label),
      150,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text(label));
    await tester.pumpAndSettle();
  }

  Future<void> fillEmployeeCreationForm(WidgetTester tester) async {
    await tester.enterText(find.byType(TextFormField).at(0), 'NEW-42');
    await tester.enterText(find.byType(TextFormField).at(1), 'New employee');
    for (final (index, label) in [(0, 'Operations'), (1, 'Operator')]) {
      final field = find.byType(DropdownButtonFormField<int>).at(index);
      await tester.ensureVisible(field);
      await tester.tap(field);
      await tester.pumpAndSettle();
      await tester.tap(find.text(label).last);
      await tester.pumpAndSettle();
    }
    await tap(tester, 'Choose date');
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'workspace opens employee detail and both authorized reference lists',
    (tester) async {
      await launch(tester);
      await tap(tester, 'Employee directory');
      expect(find.byType(OrganizationListScreen), findsOneWidget);
      expect(find.text('EMP1'), findsOneWidget);
      await tap(tester, 'Employee 1');
      expect(find.byType(DirectoryEmployeeScreen), findsOneWidget);
      expect(find.text('2020-01-02'), findsOneWidget);
      expect(find.text('Edit employee'), findsNothing);
      router.go('/workspace');
      await tester.pumpAndSettle();
      await tap(tester, 'Departments');
      expect(find.text('Operations 1'), findsOneWidget);
      router.go('/workspace');
      await tester.pumpAndSettle();
      await tap(tester, 'Job roles');
      expect(find.text('Operations 1'), findsOneWidget);
      expect(find.text('Create assignment'), findsNothing);
    },
  );

  testWidgets(
    'company dashboard displays server metrics and failure information',
    (tester) async {
      await launch(tester, path: '/workspace/dashboard');
      expect(find.text('Company dashboard'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('33.3%'),
        150,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('33.3%'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('Score: 0.00 / 2.00'),
        150,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      expect(find.text('Score: 0.00 / 2.00'), findsOneWidget);
      expect(find.text('Not passed'), findsOneWidget);
      verify(() => repository.dashboard(cancelToken: any(named: 'cancelToken')))
          .called(1);
    },
  );

  testWidgets(
    'Manager workspace opens the team dashboard and scoped employee information',
    (tester) async {
      when(() => repository.dashboard(cancelToken: any(named: 'cancelToken')))
          .thenAnswer((_) async => dashboardFixture(team: true));
      await launch(tester, identity: managementIdentity(team: true));
      expect(find.text('Company dashboard'), findsNothing);
      await tap(tester, 'Team dashboard');
      await tap(tester, 'Employee 1');
      expect(find.byType(DirectoryEmployeeScreen), findsOneWidget);
      expect(find.text('Employee 1'), findsOneWidget);
    },
  );

  testWidgets(
    'combined capabilities retain company dashboard precedence in the workspace',
    (tester) async {
      await launch(
        tester,
        identity: managementIdentity(
          team: true,
          capabilities: {
            'personal_learning',
            'team_workspace',
            'management_workspace',
            'company_dashboard',
            'organization.view_employee',
            'organization.view_department',
            'organization.view_jobrole',
          },
        ),
      );
      await tap(tester, 'Company dashboard');
      expect(find.text('Company dashboard'), findsOneWidget);
      expect(find.text('Team dashboard'), findsNothing);
    },
  );

  testWidgets(
    'directory pagination, previous page and refresh use explicit read requests',
    (tester) async {
      when(
        () => repository.employees(
          page: 1,
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer((_) async => employeePage(more: true));
      when(
        () => repository.employees(
          page: 2,
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer((_) async => employeePage(id: 2));
      await launch(tester, path: '/workspace/employees');
      await tap(tester, 'Next page');
      expect(find.text('Employee 2'), findsOneWidget);
      expect(find.text('Employee 1'), findsNothing);
      await tap(tester, 'Previous page');
      expect(find.text('Employee 1'), findsOneWidget);
      await tap(tester, 'Next page');
      await tester.tap(find.byTooltip('Refresh'));
      await tester.pumpAndSettle();
      expect(find.text('Page 1'), findsOneWidget);
      expect(find.text('Employee 1'), findsOneWidget);
    },
  );

  testWidgets(
    'offline dashboard has explicit Retry and recovers without a mutation',
    (tester) async {
      when(() => repository.dashboard(cancelToken: any(named: 'cancelToken')))
          .thenThrow(ApiError.networkFailure());
      await launch(tester, path: '/workspace/dashboard');
      expect(find.text('Connection unavailable'), findsOneWidget);
      when(() => repository.dashboard(cancelToken: any(named: 'cancelToken')))
          .thenAnswer((_) async => dashboardFixture());
      await tap(tester, 'Retry');
      expect(find.text('Company dashboard'), findsOneWidget);
      verify(() => repository.dashboard(cancelToken: any(named: 'cancelToken')))
          .called(2);
    },
  );

  testWidgets(
    'inaccessible employee detail fails safely without displaying another record',
    (tester) async {
      when(
        () => repository.employee(99, cancelToken: any(named: 'cancelToken')),
      ).thenThrow(ApiError(message: 'Not found.', statusCode: 404));
      await launch(tester, path: '/workspace/employees/99');
      expect(find.text('Not found.'), findsOneWidget);
      expect(find.text('Employee 1'), findsNothing);
      expect(find.text('Edit employee'), findsNothing);
    },
  );

  testWidgets(
    'deactivation action requires active employee and change capability',
    (tester) async {
      await launch(
        tester,
        path: '/workspace/employees/1',
        identity: managementIdentity(
          capabilities: {'organization.view_employee'},
        ),
      );
      expect(find.byTooltip('Deactivate employee'), findsNothing);

      auth.setAuth(
        AuthAuthenticated.identity(
          managementIdentity(
            capabilities: {
              'organization.view_employee',
              'organization.change_employee',
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byTooltip('Deactivate employee'), findsOneWidget);
    },
  );

  testWidgets('deactivation action is hidden for inactive employees', (
    tester,
  ) async {
    when(() => repository.employee(1, cancelToken: any(named: 'cancelToken')))
        .thenAnswer(
          (_) async => DirectoryEmployee.fromJson(
            employeeDetailJson()..['is_active'] = false,
          ),
        );
    await launch(
      tester,
      path: '/workspace/employees/1',
      identity: managementIdentity(
        capabilities: {
          'organization.view_employee',
          'organization.change_employee',
        },
      ),
    );
    expect(find.text('Inactive'), findsOneWidget);
    expect(find.byTooltip('Deactivate employee'), findsNothing);
  });

  testWidgets(
    'deactivation confirmation validates reason and explains consequences',
    (tester) async {
      when(
        () => repository.deactivateEmployee(
          1,
          reason: 'Employment ended',
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer(
        (_) async => DirectoryEmployee.fromJson(
          employeeDetailJson()..['is_active'] = false,
        ),
      );
      await launch(
        tester,
        path: '/workspace/employees/1',
        identity: managementIdentity(
          capabilities: {
            'organization.view_employee',
            'organization.change_employee',
          },
        ),
      );
      await tester.tap(find.byTooltip('Deactivate employee'));
      await tester.pumpAndSettle();
      expect(find.byType(EmployeeDeactivationDialog), findsOneWidget);
      expect(
        find.textContaining('disables this employee’s login access'),
        findsOneWidget,
      );
      expect(
        find.textContaining('Historical training records are preserved'),
        findsOneWidget,
      );
      final reasonField = tester.widget<TextField>(find.byType(TextField));
      expect(reasonField.maxLength, 1000);

      await tester.tap(find.text('Deactivate'));
      await tester.pumpAndSettle();
      expect(find.text('Enter a reason.'), findsOneWidget);

      await tester.enterText(find.byType(TextFormField), 'Employment ended');
      await tester.tap(find.text('Deactivate'));
      await tester.pumpAndSettle();
      expect(find.byType(EmployeeDeactivationDialog), findsNothing);
      expect(
        find.textContaining('Any linked login is disabled'),
        findsOneWidget,
      );
      verify(
        () => repository.deactivateEmployee(
          1,
          reason: 'Employment ended',
          cancelToken: any(named: 'cancelToken'),
        ),
      ).called(1);
      verify(
        () => repository.employee(1, cancelToken: any(named: 'cancelToken')),
      ).called(2);
    },
  );

  testWidgets('deactivation displays server, conflict and network errors', (
    tester,
  ) async {
    var nextError = ApiError(
      message: 'Reason rejected.',
      statusCode: 400,
      details: {
        'reason': ['Reason rejected.'],
      },
    );
    when(
      () => repository.deactivateEmployee(
        1,
        reason: 'Employment ended',
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenAnswer((_) async => throw nextError);
    await launch(
      tester,
      path: '/workspace/employees/1',
      identity: managementIdentity(
        capabilities: {
          'organization.view_employee',
          'organization.change_employee',
        },
      ),
    );

    Future<void> submitReason() async {
      await tester.tap(find.byTooltip('Deactivate employee'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField), 'Employment ended');
      await tester.tap(find.text('Deactivate'));
      await tester.pumpAndSettle();
    }

    await submitReason();
    expect(find.text('Reason rejected.'), findsOneWidget);

    nextError = ApiError(message: 'Forbidden.', statusCode: 403);
    await submitReason();
    expect(
      find.text('You are not authorized to deactivate this employee.'),
      findsOneWidget,
    );

    nextError = ApiError(
      message: 'This employee is already inactive.',
      statusCode: 409,
    );
    await submitReason();
    expect(find.text('This employee is already inactive.'), findsOneWidget);

    nextError = ApiError.networkFailure();
    await submitReason();
    expect(find.textContaining('Network connection failed.'), findsOneWidget);
    expect(find.byTooltip('Deactivate employee'), findsOneWidget);
  });

  testWidgets(
    'deactivation prevents duplicate saves and cancels on account switch',
    (tester) async {
      final pending = Completer<DirectoryEmployee>();
      CancelToken? request;
      when(
        () => repository.deactivateEmployee(
          1,
          reason: 'Employment ended',
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer((call) {
        request = call.namedArguments[#cancelToken] as CancelToken;
        return pending.future;
      });
      await launch(
        tester,
        path: '/workspace/employees/1',
        identity: managementIdentity(
          username: 'first',
          capabilities: {
            'organization.view_employee',
            'organization.change_employee',
          },
        ),
      );
      await tester.tap(find.byTooltip('Deactivate employee'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField), 'Employment ended');
      await tester.tap(find.text('Deactivate'));
      await tester.pump();
      expect(find.byTooltip('Deactivating employee'), findsOneWidget);
      await tester.tap(find.byTooltip('Deactivating employee'));
      await tester.pump();
      verify(
        () => repository.deactivateEmployee(
          1,
          reason: 'Employment ended',
          cancelToken: any(named: 'cancelToken'),
        ),
      ).called(1);

      auth.setAuth(
        AuthAuthenticated.identity(
          managementIdentity(
            username: 'second',
            capabilities: {
              'organization.view_employee',
              'organization.change_employee',
            },
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
      expect(request!.isCancelled, isTrue);
      pending.complete(
        DirectoryEmployee.fromJson(employeeDetailJson()..['is_active'] = false),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('Any linked login is disabled'), findsNothing);
    },
  );

  testWidgets('deactivation action is hidden for the current employee', (
    tester,
  ) async {
    when(() => repository.employee(1, cancelToken: any(named: 'cancelToken')))
        .thenAnswer(
          (_) async => DirectoryEmployee.fromJson(
            employeeDetailJson()
              ..['employee_code'] = 'MGR'
              ..['display_name'] = 'Current user',
          ),
        );
    await launch(
      tester,
      path: '/workspace/employees/1',
      identity: managementIdentity(
        team: true,
        capabilities: {
          'organization.view_employee',
          'organization.change_employee',
        },
      ),
    );
    expect(find.text('Current user'), findsOneWidget);
    expect(find.byTooltip('Deactivate employee'), findsNothing);
  });

  testWidgets(
    'HTTP 409 employee_inactive invalidates detail and directory caches without success banner',
    (tester) async {
      var employeeFetchCount = 0;
      var directoryFetchCount = 0;
      when(() => repository.employee(1, cancelToken: any(named: 'cancelToken')))
          .thenAnswer((_) async {
            employeeFetchCount++;
            return DirectoryEmployee.fromJson(
              employeeDetailJson()..['is_active'] = employeeFetchCount == 1,
            );
          });
      when(
        () => repository.employees(
          page: 1,
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer((_) async {
        directoryFetchCount++;
        return employeePage();
      });
      when(
        () => repository.deactivateEmployee(
          1,
          reason: 'Employment ended',
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer(
        (_) async => throw ApiError(
          message: 'This employee is already inactive.',
          statusCode: 409,
          code: 'employee_inactive',
        ),
      );

      await launch(
        tester,
        path: '/workspace/employees',
        identity: managementIdentity(
          capabilities: {
            'organization.view_employee',
            'organization.change_employee',
          },
        ),
      );
      expect(directoryFetchCount, 1);
      await tap(tester, 'Employee 1');
      expect(employeeFetchCount, 1);
      expect(find.byTooltip('Deactivate employee'), findsOneWidget);

      await tester.tap(find.byTooltip('Deactivate employee'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField), 'Employment ended');
      await tester.tap(find.text('Deactivate'));
      await tester.pumpAndSettle();

      // Error message is displayed; no success message is displayed.
      expect(find.text('This employee is already inactive.'), findsOneWidget);
      expect(find.textContaining('Any linked login is disabled'), findsNothing);

      // Detail cache was invalidated immediately because it is actively watched.
      expect(employeeFetchCount, 2);

      // With re-fetched detail indicating is_active: false, button is gone and Inactive is shown.
      expect(find.text('Inactive'), findsOneWidget);
      expect(find.byTooltip('Deactivate employee'), findsNothing);

      // Returning to directory re-fetches the invalidated directory cache.
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(directoryFetchCount, 2);
    },
  );

  testWidgets(
    'non-409 errors or different 409 codes do not invalidate detail or directory caches',
    (tester) async {
      var employeeFetchCount = 0;
      var directoryFetchCount = 0;
      when(
        () => repository.employees(
          page: any(named: 'page'),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer((_) async {
        directoryFetchCount++;
        return employeePage();
      });
      when(() => repository.employee(1, cancelToken: any(named: 'cancelToken')))
          .thenAnswer((_) async {
            employeeFetchCount++;
            return DirectoryEmployee.fromJson(employeeDetailJson());
          });
      when(
        () => repository.deactivateEmployee(
          1,
          reason: 'Employment ended',
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer(
        (_) async => throw ApiError(
          message: 'Another conflict occurred.',
          statusCode: 409,
          code: 'other_conflict',
        ),
      );

      await launch(
        tester,
        path: '/workspace/employees',
        identity: managementIdentity(
          capabilities: {
            'organization.view_employee',
            'organization.change_employee',
          },
        ),
      );

      expect(directoryFetchCount, 1);
      await tap(tester, 'Employee 1');
      expect(employeeFetchCount, 1);
      await tester.tap(find.byTooltip('Deactivate employee'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField), 'Employment ended');
      await tester.tap(find.text('Deactivate'));
      await tester.pumpAndSettle();

      expect(find.text('Another conflict occurred.'), findsOneWidget);
      // Detail cache was NOT invalidated.
      expect(employeeFetchCount, 1);
      expect(find.byTooltip('Deactivate employee'), findsOneWidget);

      // Returning to directory confirms directory cache was NOT invalidated.
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(directoryFetchCount, 1);
    },
  );

  testWidgets(
    'stale 409 response after account switch does not trigger cache invalidation',
    (tester) async {
      final pending = Completer<DirectoryEmployee>();
      CancelToken? request;
      var employeeFetchCount = 0;
      when(() => repository.employee(1, cancelToken: any(named: 'cancelToken')))
          .thenAnswer((_) async {
            employeeFetchCount++;
            return DirectoryEmployee.fromJson(employeeDetailJson());
          });
      when(
        () => repository.deactivateEmployee(
          1,
          reason: 'Employment ended',
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer((call) {
        request = call.namedArguments[#cancelToken] as CancelToken;
        return pending.future;
      });

      await launch(
        tester,
        path: '/workspace/employees/1',
        identity: managementIdentity(
          username: 'first',
          capabilities: {
            'organization.view_employee',
            'organization.change_employee',
          },
        ),
      );

      expect(employeeFetchCount, 1);
      await tester.tap(find.byTooltip('Deactivate employee'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField), 'Employment ended');
      await tester.tap(find.text('Deactivate'));
      await tester.pump();

      // Switch authenticated account while request is in-flight.
      auth.setAuth(
        AuthAuthenticated.identity(
          managementIdentity(
            username: 'second',
            capabilities: {
              'organization.view_employee',
              'organization.change_employee',
            },
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
      expect(request!.isCancelled, isTrue);

      final countAfterSwitch = employeeFetchCount;
      expect(countAfterSwitch, 2);

      // Stale 409 arrives from previous account.
      pending.completeError(
        ApiError(
          message: 'This employee is already inactive.',
          statusCode: 409,
          code: 'employee_inactive',
        ),
      );
      await tester.pumpAndSettle();

      // Ensure no error message for the new account and no extra fetch of detail.
      expect(find.text('This employee is already inactive.'), findsNothing);
      expect(employeeFetchCount, countAfterSwitch);
    },
  );

  testWidgets('employee edit action requires server-issued capability', (
    tester,
  ) async {
    await launch(
      tester,
      path: '/workspace/employees/1',
      identity: managementIdentity(
        capabilities: {'organization.view_employee'},
      ),
    );
    expect(find.byTooltip('Edit employee'), findsNothing);

    auth.setAuth(
      AuthAuthenticated.identity(
        managementIdentity(
          capabilities: {
            'organization.view_employee',
            'organization.change_employee',
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byTooltip('Edit employee'), findsOneWidget);
  });

  testWidgets('Add Employee entry point requires server-issued capability', (
    tester,
  ) async {
    await launch(
      tester,
      path: '/workspace/employees',
      identity: managementIdentity(
        capabilities: {'organization.view_employee'},
      ),
    );
    expect(find.byTooltip('Add employee'), findsNothing);

    auth.setAuth(
      AuthAuthenticated.identity(
        managementIdentity(
          capabilities: {
            'organization.view_employee',
            'organization.add_employee',
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byTooltip('Add employee'), findsOneWidget);
    await tester.tap(find.byTooltip('Add employee'));
    await tester.pumpAndSettle();
    expect(find.byType(EmployeeCreationFormScreen), findsOneWidget);
    expect(find.text('Employee code'), findsOneWidget);
    expect(find.text('Display name'), findsOneWidget);
    expect(find.text('Department'), findsOneWidget);
    expect(find.text('Job role'), findsOneWidget);
    expect(find.textContaining('will not have login access'), findsOneWidget);
  });

  testWidgets('Employee creation validates required profile fields locally', (
    tester,
  ) async {
    await launch(
      tester,
      path: '/workspace/employees/new',
      identity: managementIdentity(
        capabilities: {
          'organization.view_employee',
          'organization.add_employee',
        },
      ),
    );
    expect(find.byType(EmployeeCreationFormScreen), findsOneWidget);
    await tap(tester, 'Create employee');
    await tester.pumpAndSettle();
    expect(find.text('This field is required.'), findsAtLeastNWidgets(1));
    expect(find.text('Select a department.'), findsOneWidget);
    expect(find.text('Select a job role.'), findsOneWidget);
    expect(find.text('Select a date joined.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'Employee creation posts validated profile and refreshes directory',
    (tester) async {
      final response = DirectoryEmployee.fromJson(
        employeeDetailJson(42, 'New employee')
          ..['employee_code'] = 'NEW-42'
          ..['reporting_manager'] = null
          ..['reporting_manager_id'] = null
          ..['login_status'] = 'NOT_LINKED',
      );
      final pending = Completer<DirectoryEmployee>();
      late CancelToken request;
      when(
        () => repository.createEmployee(
          employeeCode: 'NEW-42',
          displayName: 'New employee',
          departmentId: 1,
          jobRoleId: 1,
          dateJoined: any(named: 'dateJoined'),
          reportingManagerId: null,
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer((call) {
        request = call.namedArguments[#cancelToken] as CancelToken;
        return pending.future;
      });
      await launch(
        tester,
        path: '/workspace/employees',
        identity: managementIdentity(
          capabilities: {
            'organization.view_employee',
            'organization.add_employee',
          },
        ),
      );
      await tester.tap(find.byTooltip('Add employee'));
      await tester.pumpAndSettle();
      await fillEmployeeCreationForm(tester);
      await tester.scrollUntilVisible(
        find.text('Create employee'),
        150,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('Create employee'));
      await tester.pump();
      expect(find.text('Creating…'), findsOneWidget);
      await tester.tap(find.text('Creating…'));
      await tester.pump();
      final cancelButton = tester.widget<OutlinedButton>(
        find.widgetWithText(OutlinedButton, 'Cancel'),
      );
      expect(cancelButton.onPressed, isNull);
      await tester.binding.handlePopRoute();
      await tester.pump();
      expect(find.byType(EmployeeCreationFormScreen), findsOneWidget);
      expect(request.isCancelled, isFalse);
      pending.complete(response);
      await tester.pumpAndSettle();

      verify(
        () => repository.createEmployee(
          employeeCode: 'NEW-42',
          displayName: 'New employee',
          departmentId: 1,
          jobRoleId: 1,
          dateJoined: any(named: 'dateJoined'),
          reportingManagerId: null,
          cancelToken: any(named: 'cancelToken'),
        ),
      ).called(1);
      verify(
        () => repository.employees(
          page: 1,
          cancelToken: any(named: 'cancelToken'),
        ),
      ).called(2);
      expect(find.byType(EmployeeCreationFormScreen), findsNothing);
      expect(
        find.text('Employee created. No login account was linked.'),
        findsOneWidget,
      );
    },
  );

  testWidgets('Employee creation shows server field and non-field errors', (
    tester,
  ) async {
    when(
      () => repository.createEmployee(
        employeeCode: 'DUPLICATE',
        displayName: 'New employee',
        departmentId: 1,
        jobRoleId: 1,
        dateJoined: any(named: 'dateJoined'),
        reportingManagerId: null,
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenAnswer(
      (_) async => throw ApiError(
        message: 'Correct the highlighted details.',
        statusCode: 400,
        details: {
          'employee_code': ['This employee code is already in use.'],
          'non_field_errors': ['Employee could not be created.'],
        },
      ),
    );
    await launch(
      tester,
      path: '/workspace/employees/new',
      identity: managementIdentity(capabilities: {'organization.add_employee'}),
    );
    await fillEmployeeCreationForm(tester);
    await tester.enterText(find.byType(TextFormField).at(0), 'DUPLICATE');
    await tap(tester, 'Create employee');
    expect(find.text('This employee code is already in use.'), findsOneWidget);
    expect(find.text('Employee could not be created.'), findsOneWidget);
    expect(find.text('Correct the highlighted details.'), findsOneWidget);
  });

  testWidgets(
    'Employee creation dynamic error notices announce via Semantics liveRegion',
    (tester) async {
      when(
        () => repository.createEmployee(
          employeeCode: 'DUPLICATE',
          displayName: 'New employee',
          departmentId: 1,
          jobRoleId: 1,
          dateJoined: any(named: 'dateJoined'),
          reportingManagerId: null,
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer(
        (_) async => throw ApiError(
          message: 'Correct the highlighted details.',
          statusCode: 400,
          details: {
            'employee_code': ['This employee code is already in use.'],
            'non_field_errors': ['Employee could not be created.'],
          },
        ),
      );
      await launch(
        tester,
        path: '/workspace/employees/new',
        identity: managementIdentity(
          capabilities: {'organization.add_employee'},
        ),
      );
      expect(
        find.descendant(
          of: find.byType(EmployeeCreationFormScreen),
          matching: find.byWidgetPredicate(
            (w) => w is Semantics && w.properties.liveRegion == true,
          ),
        ),
        findsNothing,
      );

      await fillEmployeeCreationForm(tester);
      await tester.enterText(find.byType(TextFormField).at(0), 'DUPLICATE');
      await tap(tester, 'Create employee');

      expect(
        find.text('This employee code is already in use.'),
        findsOneWidget,
      );
      expect(find.text('Employee could not be created.'), findsOneWidget);

      final liveRegions = find.descendant(
        of: find.byType(EmployeeCreationFormScreen),
        matching: find.byWidgetPredicate(
          (w) => w is Semantics && w.properties.liveRegion == true,
        ),
      );
      expect(liveRegions, findsAtLeastNWidgets(1));
      final semantics = tester.widget<Semantics>(liveRegions.first);
      expect(semantics.properties.liveRegion, isTrue);
    },
  );

  testWidgets('Employee creation handles 403 and network errors', (
    tester,
  ) async {
    var attempts = 0;
    when(
      () => repository.createEmployee(
        employeeCode: 'NEW-42',
        displayName: 'New employee',
        departmentId: 1,
        jobRoleId: 1,
        dateJoined: any(named: 'dateJoined'),
        reportingManagerId: null,
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenAnswer((_) async {
      attempts++;
      if (attempts == 1) {
        throw ApiError(message: 'Denied.', statusCode: 403);
      }
      throw ApiError.networkFailure();
    });
    await launch(
      tester,
      path: '/workspace/employees/new',
      identity: managementIdentity(capabilities: {'organization.add_employee'}),
    );
    await fillEmployeeCreationForm(tester);
    await tester.scrollUntilVisible(
      find.text('Create employee'),
      150,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('Create employee'));
    await tester.pump();
    expect(
      find.text('You are not authorized to create employees.'),
      findsOneWidget,
    );
    await tap(tester, 'Create employee');
    expect(find.textContaining('Network connection failed.'), findsOneWidget);
    expect(find.byType(EmployeeCreationFormScreen), findsOneWidget);
  });

  testWidgets(
    'Employee creation cancels an in-flight request on account switch',
    (tester) async {
      final pending = Completer<DirectoryEmployee>();
      CancelToken? request;
      when(
        () => repository.createEmployee(
          employeeCode: 'NEW-42',
          displayName: 'New employee',
          departmentId: 1,
          jobRoleId: 1,
          dateJoined: any(named: 'dateJoined'),
          reportingManagerId: null,
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer((call) {
        request = call.namedArguments[#cancelToken] as CancelToken;
        return pending.future;
      });
      await launch(
        tester,
        path: '/workspace/employees/new',
        identity: managementIdentity(
          username: 'first',
          capabilities: {'organization.add_employee'},
        ),
      );
      await fillEmployeeCreationForm(tester);
      await tester.scrollUntilVisible(
        find.text('Create employee'),
        150,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('Create employee'));
      await tester.pump();
      auth.setAuth(
        AuthAuthenticated.identity(
          managementIdentity(
            username: 'second',
            capabilities: {'organization.add_employee'},
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(request!.isCancelled, isTrue);
      pending.complete(DirectoryEmployee.fromJson(employeeDetailJson(42)));
      await tester.pumpAndSettle();
      expect(
        find.text('Employee created. No login account was linked.'),
        findsNothing,
      );
      expect(find.byType(EmployeeCreationFormScreen), findsOneWidget);
    },
  );

  testWidgets(
    'employee edit displays protected fields and submits selected relationship IDs',
    (tester) async {
      when(
        () => repository.updateEmployeeProfile(
          any(),
          displayName: 'Updated employee',
          departmentId: 2,
          jobRoleId: 2,
          dateJoined: '2020-01-02',
          updateReportingManager: true,
          reportingManagerId: 2,
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer(
        (_) async => DirectoryEmployee.fromJson(
          employeeDetailJson()
            ..['display_name'] = 'Updated employee'
            ..['department'] = {
              'id': 2,
              'code': 'ARCHIVE',
              'name': 'Archived Department',
            }
            ..['job_role'] = {'id': 2, 'code': 'LEAD', 'name': 'Lead'}
            ..['reporting_manager'] = 'Manager Two'
            ..['reporting_manager_id'] = 2,
        ),
      );
      await launch(
        tester,
        path: '/workspace/employees/1',
        identity: managementIdentity(
          capabilities: {
            'organization.view_employee',
            'organization.change_employee',
          },
        ),
      );
      await tester.tap(find.byTooltip('Edit employee'));
      await tester.pumpAndSettle();
      expect(
        find.text(
          'Employee code, login access, groups and employment status are protected.',
        ),
        findsOneWidget,
      );
      expect(find.text('EMP1'), findsNothing);
      expect(find.text('Reporting manager'), findsOneWidget);
      final managerField = tester.widget<DropdownButtonFormField<int>>(
        find.byType(DropdownButtonFormField<int>).at(2),
      );
      expect(managerField.initialValue, 9);
      expect(find.text('Team Manager (current)'), findsOneWidget);

      await tester.enterText(find.byType(TextFormField), 'Updated employee');
      await tester.tap(find.byType(DropdownButtonFormField<int>).at(0));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Archived Department (inactive)').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byType(DropdownButtonFormField<int>).at(1));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Lead (inactive)').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byType(DropdownButtonFormField<int>).at(2));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Manager Two · EMP2'));
      await tester.pumpAndSettle();

      await tester.drag(find.byType(ListView).last, const Offset(0, -600));
      await tester.pumpAndSettle();
      final saveButton = find.widgetWithText(FilledButton, 'Save');
      await tester.ensureVisible(saveButton);
      await tester.tap(saveButton);
      await tester.pumpAndSettle();
      verify(
        () => repository.updateEmployeeProfile(
          any(),
          displayName: 'Updated employee',
          departmentId: 2,
          jobRoleId: 2,
          dateJoined: '2020-01-02',
          updateReportingManager: true,
          reportingManagerId: 2,
          cancelToken: any(named: 'cancelToken'),
        ),
      ).called(1);
      expect(find.text('Employee profile saved.'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('employee edit preserves server field and non-field errors', (
    tester,
  ) async {
    when(
      () => repository.updateEmployeeProfile(
        any(),
        displayName: 'Duplicate employee',
        departmentId: 1,
        jobRoleId: 1,
        dateJoined: '2020-01-02',
        updateReportingManager: false,
        reportingManagerId: null,
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenThrow(
      ApiError(
        message: 'Please correct the highlighted fields.',
        statusCode: 400,
        details: {
          'display_name': ['This name is already in use.'],
          'non_field_errors': ['The profile cannot be changed right now.'],
        },
      ),
    );
    await launch(
      tester,
      path: '/workspace/employees/1',
      identity: managementIdentity(
        capabilities: {
          'organization.view_employee',
          'organization.change_employee',
        },
      ),
    );
    await tester.tap(find.byTooltip('Edit employee'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), 'Duplicate employee');
    await tester.drag(find.byType(ListView).last, const Offset(0, -600));
    await tester.pumpAndSettle();
    final saveButton = find.widgetWithText(FilledButton, 'Save');
    await tester.ensureVisible(saveButton);
    await tester.tap(saveButton);
    await tester.pumpAndSettle();
    expect(find.text('This name is already in use.'), findsOneWidget);
    expect(
      find.text('The profile cannot be changed right now.'),
      findsOneWidget,
    );
    expect(find.text('Employee profile saved.'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('employee edit presents a real authorization denial', (
    tester,
  ) async {
    when(
      () => repository.updateEmployeeProfile(
        any(),
        displayName: 'Changed employee',
        departmentId: 1,
        jobRoleId: 1,
        dateJoined: '2020-01-02',
        updateReportingManager: false,
        reportingManagerId: null,
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenThrow(ApiError(message: 'Permission denied.', statusCode: 403));
    await launch(
      tester,
      path: '/workspace/employees/1',
      identity: managementIdentity(
        capabilities: {
          'organization.view_employee',
          'organization.change_employee',
        },
      ),
    );
    await tester.tap(find.byTooltip('Edit employee'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), 'Changed employee');
    await tester.drag(find.byType(ListView).last, const Offset(0, -600));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();
    expect(
      find.text('You are not authorized to edit this employee.'),
      findsOneWidget,
    );
    expect(find.text('Employee profile saved.'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('employee edit cancels pending mutation on account switch', (
    tester,
  ) async {
    final response = Completer<DirectoryEmployee>();
    late CancelToken request;
    when(
      () => repository.updateEmployeeProfile(
        any(),
        displayName: 'Changed employee',
        departmentId: 1,
        jobRoleId: 1,
        dateJoined: '2020-01-02',
        updateReportingManager: false,
        reportingManagerId: null,
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenAnswer((call) {
      request = call.namedArguments[#cancelToken] as CancelToken;
      return response.future;
    });
    await launch(
      tester,
      path: '/workspace/employees/1',
      identity: managementIdentity(
        username: 'first',
        capabilities: {
          'organization.view_employee',
          'organization.change_employee',
        },
      ),
    );
    await tester.tap(find.byTooltip('Edit employee'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), 'Changed employee');
    await tester.drag(find.byType(ListView).last, const Offset(0, -600));
    await tester.pumpAndSettle();
    final saveButton = find.widgetWithText(FilledButton, 'Save');
    await tester.ensureVisible(saveButton);
    await tester.tap(saveButton);
    await tester.pump();

    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(find.byType(EmployeeProfileFormScreen), findsOneWidget);
    expect(request.isCancelled, isFalse);

    auth.setAuth(
      AuthAuthenticated.identity(
        managementIdentity(
          username: 'second',
          capabilities: {
            'organization.view_employee',
            'organization.change_employee',
          },
        ),
      ),
    );
    await tester.pump();
    expect(request.isCancelled, isTrue);
    response.complete(DirectoryEmployee.fromJson(employeeJson()));
    await tester.pumpAndSettle();
    expect(find.text('Employee profile saved.'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('employee edit route without a loaded record fails safely', (
    tester,
  ) async {
    await launch(
      tester,
      path: '/workspace/employees/1/edit',
      identity: managementIdentity(
        capabilities: {
          'organization.view_employee',
          'organization.change_employee',
        },
      ),
    );
    expect(find.byType(EmployeeProfileFormScreen), findsOneWidget);
    expect(
      find.text(
        'Employee details are unavailable. Return to the directory and open the record again.',
      ),
      findsOneWidget,
    );
    expect(find.byType(TextFormField), findsNothing);
    expect(find.widgetWithText(FilledButton, 'Save'), findsNothing);
    verifyNever(
      () => repository.updateEmployeeProfile(
        any(),
        displayName: any(named: 'displayName'),
        departmentId: any(named: 'departmentId'),
        jobRoleId: any(named: 'jobRoleId'),
        dateJoined: any(named: 'dateJoined'),
        updateReportingManager: any(named: 'updateReportingManager'),
        reportingManagerId: any(named: 'reportingManagerId'),
        cancelToken: any(named: 'cancelToken'),
      ),
    );
  });

  testWidgets('unchanged employee edit cannot be submitted', (tester) async {
    await launch(
      tester,
      path: '/workspace/employees/1',
      identity: managementIdentity(
        capabilities: {
          'organization.view_employee',
          'organization.change_employee',
        },
      ),
    );
    await tester.tap(find.byTooltip('Edit employee'));
    await tester.pumpAndSettle();
    expect(find.byType(EmployeeProfileFormScreen), findsOneWidget);

    final saveButtonFinder = find.widgetWithText(FilledButton, 'Save');
    await tester.drag(find.byType(ListView).last, const Offset(0, -600));
    await tester.pumpAndSettle();
    await tester.ensureVisible(saveButtonFinder);
    var saveButton = tester.widget<FilledButton>(saveButtonFinder);
    expect(saveButton.onPressed, isNull);

    await tester.drag(find.byType(ListView).last, const Offset(0, 600));
    await tester.pumpAndSettle();
    final nameField = find.byType(TextFormField);
    await tester.enterText(nameField, 'Changed Name');
    await tester.pump();

    await tester.drag(find.byType(ListView).last, const Offset(0, -600));
    await tester.pumpAndSettle();
    await tester.ensureVisible(saveButtonFinder);
    saveButton = tester.widget<FilledButton>(saveButtonFinder);
    expect(saveButton.onPressed, isNotNull);

    await tester.drag(find.byType(ListView).last, const Offset(0, 600));
    await tester.pumpAndSettle();
    await tester.enterText(nameField, 'Employee 1');
    await tester.pump();

    await tester.drag(find.byType(ListView).last, const Offset(0, -600));
    await tester.pumpAndSettle();
    await tester.ensureVisible(saveButtonFinder);
    saveButton = tester.widget<FilledButton>(saveButtonFinder);
    expect(saveButton.onPressed, isNull);

    verifyNever(
      () => repository.updateEmployeeProfile(
        any(),
        displayName: any(named: 'displayName'),
        departmentId: any(named: 'departmentId'),
        jobRoleId: any(named: 'jobRoleId'),
        dateJoined: any(named: 'dateJoined'),
        updateReportingManager: any(named: 'updateReportingManager'),
        reportingManagerId: any(named: 'reportingManagerId'),
        cancelToken: any(named: 'cancelToken'),
      ),
    );
  });

  testWidgets(
    'discard confirmation appears when leaving dirty employee edit form',
    (tester) async {
      await launch(
        tester,
        path: '/workspace/employees/1',
        identity: managementIdentity(
          capabilities: {
            'organization.view_employee',
            'organization.change_employee',
          },
        ),
      );
      await tester.tap(find.byTooltip('Edit employee'));
      await tester.pumpAndSettle();

      final nameField = find.byType(TextFormField);
      await tester.enterText(nameField, 'Changed Name');
      await tester.pump();

      final cancelButtonFinder = find.widgetWithText(OutlinedButton, 'Cancel');
      await tester.drag(find.byType(ListView).last, const Offset(0, -600));
      await tester.pumpAndSettle();
      await tester.ensureVisible(cancelButtonFinder);
      await tester.tap(cancelButtonFinder);
      await tester.pumpAndSettle();

      expect(find.text('Discard changes?'), findsOneWidget);
      expect(find.text('Your unsaved changes will be lost.'), findsOneWidget);

      await tester.tap(find.text('Keep editing'));
      await tester.pumpAndSettle();
      expect(find.byType(EmployeeProfileFormScreen), findsOneWidget);

      await tester.drag(find.byType(ListView).last, const Offset(0, -600));
      await tester.pumpAndSettle();
      await tester.ensureVisible(cancelButtonFinder);
      await tester.tap(cancelButtonFinder);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Discard'));
      await tester.pumpAndSettle();
      expect(find.byType(EmployeeProfileFormScreen), findsNothing);
    },
  );

  testWidgets(
    'missing reference view permissions fail safe with liveRegion notice',
    (tester) async {
      when(
        () => repository.employeeEditChoices(
          employeeId: 1,
          pageSize: any(named: 'pageSize'),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenThrow(
        ApiError(
          message: 'You do not have permission to view departments.',
          statusCode: 403,
        ),
      );

      await launch(
        tester,
        path: '/workspace/employees/1',
        identity: managementIdentity(
          capabilities: {
            'organization.view_employee',
            'organization.change_employee',
          },
        ),
      );
      await tester.tap(find.byTooltip('Edit employee'));
      await tester.pumpAndSettle();

      expect(
        find.text('You do not have permission to view departments.'),
        findsOneWidget,
      );
      expect(find.byType(TextFormField), findsNothing);
      expect(find.widgetWithText(FilledButton, 'Save'), findsNothing);

      final semantics = tester.widget<Semantics>(
        find
            .descendant(
              of: find.byType(EmployeeProfileFormScreen),
              matching: find.byWidgetPredicate(
                (w) => w is Semantics && w.properties.liveRegion == true,
              ),
            )
            .first,
      );
      expect(semantics.properties.liveRegion, isTrue);
    },
  );

  testWidgets(
    'successful employee profile update invalidates directory cache and re-fetches',
    (tester) async {
      when(
        () => repository.updateEmployeeProfile(
          any(),
          displayName: any(named: 'displayName'),
          departmentId: any(named: 'departmentId'),
          jobRoleId: any(named: 'jobRoleId'),
          dateJoined: any(named: 'dateJoined'),
          updateReportingManager: any(named: 'updateReportingManager'),
          reportingManagerId: any(named: 'reportingManagerId'),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer(
        (_) async => DirectoryEmployee.fromJson(
          employeeDetailJson()..['display_name'] = 'Updated Name',
        ),
      );

      await launch(
        tester,
        path: '/workspace/employees',
        identity: managementIdentity(
          capabilities: {
            'organization.view_employee',
            'organization.change_employee',
          },
        ),
      );

      expect(find.text('Employee 1'), findsOneWidget);
      verify(
        () => repository.employees(
          page: 1,
          cancelToken: any(named: 'cancelToken'),
        ),
      ).called(1);

      await tester.tap(find.text('Employee 1'));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Edit employee'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextFormField), 'Updated Name');
      await tester.pumpAndSettle();

      final saveButton = find.widgetWithText(FilledButton, 'Save');
      await tester.drag(find.byType(ListView).last, const Offset(0, -600));
      await tester.pumpAndSettle();
      await tester.ensureVisible(saveButton);
      await tester.tap(saveButton);
      await tester.pumpAndSettle();

      expect(find.text('Employee profile saved.'), findsOneWidget);

      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();

      verify(
        () => repository.employees(
          page: 1,
          cancelToken: any(named: 'cancelToken'),
        ),
      ).called(1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Employee keeps three tabs and opens only its authorized reference lists',
    (tester) async {
      final employee = managementIdentity(
        team: true,
        capabilities: {'personal_learning', 'organization.view_department'},
      );
      await launch(tester, identity: employee, path: '/workspace/dashboard');
      expect(router.routerDelegate.currentConfiguration.uri.path, '/dashboard');
      verifyNever(
        () => repository.dashboard(cancelToken: any(named: 'cancelToken')),
      );
      router.go('/profile');
      await tester.pumpAndSettle();
      await tap(tester, 'Departments');
      expect(find.text('Operations 1'), findsOneWidget);
      final navigation = tester.widget<NavigationBar>(
        find.byType(NavigationBar),
      );
      expect(navigation.destinations.length, 3);
      expect(navigation.selectedIndex, 2);
      router.go('/workspace/employees');
      await tester.pumpAndSettle();
      expect(router.routerDelegate.currentConfiguration.uri.path, '/dashboard');
      verifyNever(
        () => repository.employees(
          page: any(named: 'page'),
          cancelToken: any(named: 'cancelToken'),
        ),
      );
    },
  );

  testWidgets(
    'account switching hides previously loaded employees while new data is pending',
    (tester) async {
      when(
        () => repository.employees(
          page: 1,
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer((_) async => employeePage(name: 'Old private employee'));
      await launch(tester, path: '/workspace/employees');
      expect(find.text('Old private employee'), findsOneWidget);
      final response = Completer<ManagementPage<DirectoryEmployee>>();
      when(
        () => repository.employees(
          page: 1,
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer((_) => response.future);
      auth.setAuth(
        AuthAuthenticated.identity(managementIdentity(username: 'second')),
      );
      await tester.pump();
      expect(find.text('Old private employee'), findsNothing);
      expect(find.byType(LoadingView), findsOneWidget);
      response.complete(employeePage(name: 'Current employee'));
      await tester.pumpAndSettle();
      expect(find.text('Current employee'), findsOneWidget);
      auth.setAuth(AuthUnauthenticated());
      await tester.pumpAndSettle();
      expect(router.routerDelegate.currentConfiguration.uri.path, '/login');
      expect(find.text('Current employee'), findsNothing);
    },
  );

  testWidgets(
    'loss of company capability cannot retain company dashboard data in team view',
    (tester) async {
      await launch(tester, path: '/workspace/dashboard');
      expect(find.text('Company dashboard'), findsOneWidget);
      final response = Completer<ManagementDashboard>();
      when(() => repository.dashboard(cancelToken: any(named: 'cancelToken')))
          .thenAnswer((_) => response.future);
      final manager = managementIdentity(team: true, username: 'admin');
      auth.setAuth(
        AuthAuthenticated.identity(
          AuthenticatedIdentity(
            userId: 1,
            username: 'admin',
            displayName: 'admin',
            employee: manager.employee,
            capabilities: manager.capabilities,
          ),
        ),
      );
      await tester.pump();
      expect(find.text('Company dashboard'), findsNothing);
      response.complete(dashboardFixture(team: true));
      await tester.pumpAndSettle();
      expect(find.text('Team dashboard'), findsOneWidget);
    },
  );

  testWidgets('empty and inactive reference states remain readable', (
    tester,
  ) async {
    when(
      () => repository.references(
        ReferenceKind.departments,
        page: 1,
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenAnswer(
      (_) async => ManagementPage(items: [], count: 0, hasMore: false),
    );
    await launch(tester, path: '/workspace/departments');
    expect(find.text('0 departments'), findsOneWidget);
    expect(find.text('No records to display.'), findsOneWidget);
    when(
      () => repository.references(
        ReferenceKind.departments,
        page: 1,
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenAnswer(
      (_) async => ManagementPage.fromJson(
        pageJson([referenceJson()..['is_active'] = false]),
        OrganizationReference.fromJson,
      ),
    );
    await tester.tap(find.byTooltip('Refresh'));
    await tester.pumpAndSettle();
    expect(find.text('1 department'), findsOneWidget);
    expect(find.text('INACTIVE'), findsOneWidget);
  });

  testWidgets(
    'reference actions are visible only for granted write capabilities',
    (tester) async {
      await launch(
        tester,
        path: '/workspace/departments',
        identity: managementIdentity(
          team: true,
          capabilities: {
            'personal_learning',
            'team_workspace',
            'organization.view_department',
          },
        ),
      );
      expect(find.byTooltip('Add department'), findsNothing);
      expect(find.byTooltip('Edit department: Operations 1'), findsNothing);

      auth.setAuth(
        AuthAuthenticated.identity(
          managementIdentity(
            team: true,
            capabilities: {'personal_learning', 'organization.view_department'},
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byTooltip('Add department'), findsNothing);
      expect(find.byTooltip('Edit department: Operations 1'), findsNothing);

      auth.setAuth(
        AuthAuthenticated.identity(
          managementIdentity(
            capabilities: {
              'personal_learning',
              'organization.view_department',
              'organization.add_department',
              'organization.change_department',
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byTooltip('Add department'), findsOneWidget);
      expect(find.byTooltip('Edit department: Operations 1'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('edit route without a loaded record fails safely', (
    tester,
  ) async {
    await launch(
      tester,
      path: '/workspace/departments/44/edit',
      identity: managementIdentity(
        capabilities: {
          'organization.view_department',
          'organization.change_department',
        },
      ),
    );
    expect(find.byType(OrganizationReferenceFormScreen), findsOneWidget);
    expect(
      find.text(
        'This record could not be loaded. Return to the list and select it again.',
      ),
      findsOneWidget,
    );
    expect(find.byType(TextFormField), findsNothing);
  });

  testWidgets(
    'Department creation prevents duplicate submits and refreshes the list',
    (tester) async {
      final request = Completer<OrganizationReference>();
      late CancelToken token;
      var listReads = 0;
      when(
        () => repository.references(
          ReferenceKind.departments,
          page: 1,
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer((_) async {
        listReads++;
        return ManagementPage(
          items: [
            OrganizationReference(
              id: listReads == 1 ? 1 : 2,
              code: listReads == 1 ? 'REF1' : 'D2',
              name: listReads == 1 ? 'Operations 1' : 'Facilities',
            ),
          ],
          count: 1,
          hasMore: false,
        );
      });
      when(
        () => repository.saveReference(
          ReferenceKind.departments,
          original: null,
          code: 'D2',
          name: 'Facilities',
          description: '',
          isActive: true,
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer((call) {
        token = call.namedArguments[#cancelToken] as CancelToken;
        return request.future;
      });
      await launch(
        tester,
        path: '/workspace/departments',
        identity: managementIdentity(writeReferences: true),
      );
      await tester.tap(find.byTooltip('Add department'));
      await tester.pumpAndSettle();
      expect(find.byType(OrganizationReferenceFormScreen), findsOneWidget);

      await tester.enterText(find.byType(TextFormField).at(0), 'D2');
      await tester.enterText(find.byType(TextFormField).at(1), 'Facilities');
      tester.testTextInput.hide();
      await tester.pumpAndSettle();
      final saveButton = find.widgetWithText(FilledButton, 'Save');
      await tester.drag(find.byType(ListView).last, const Offset(0, -240));
      await tester.pumpAndSettle();
      await tester.ensureVisible(saveButton);
      await tester.tap(saveButton);
      await tester.pump();
      expect(find.text('Saving…'), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pump();
      expect(find.byType(OrganizationReferenceFormScreen), findsOneWidget);
      expect(token.isCancelled, isFalse);
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, 'Saving…'))
            .onPressed,
        isNull,
      );
      verify(
        () => repository.saveReference(
          ReferenceKind.departments,
          original: null,
          code: 'D2',
          name: 'Facilities',
          description: '',
          isActive: true,
          cancelToken: any(named: 'cancelToken'),
        ),
      ).called(1);
      request.complete(
        const OrganizationReference(id: 2, code: 'D2', name: 'Facilities'),
      );
      await tester.pumpAndSettle();
      expect(find.text('Facilities'), findsOneWidget);
      expect(listReads, 2);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Job Role edit pre-fills values and displays backend field errors',
    (tester) async {
      var saveCalls = 0;
      when(
        () => repository.saveReference(
          ReferenceKind.jobRoles,
          id: 1,
          original: any(named: 'original'),
          code: 'REF1',
          name: 'Changed role',
          description: 'Organization reference',
          isActive: true,
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer((_) async {
        saveCalls++;
        if (saveCalls == 1) {
          throw ApiError(
            message: 'Please correct the highlighted fields.',
            statusCode: 400,
            details: {
              'name': ['A role with this name already exists.'],
              'non_field_errors': [
                'This reference cannot be changed right now.',
              ],
            },
          );
        }
        throw ApiError(message: 'Not authorized.', statusCode: 403);
      });
      await launch(
        tester,
        path: '/workspace/job-roles',
        identity: managementIdentity(
          capabilities: {
            'organization.view_jobrole',
            'organization.change_jobrole',
          },
        ),
      );
      await tester.tap(find.byTooltip('Edit job role: Operations 1'));
      await tester.pumpAndSettle();
      expect(find.byType(OrganizationReferenceFormScreen), findsOneWidget);
      final codeField = tester.widget<TextFormField>(
        find.byType(TextFormField).at(0),
      );
      expect(codeField.controller?.text, 'REF1');
      final descriptionField = tester.widget<TextFormField>(
        find.byType(TextFormField).at(2),
      );
      expect(descriptionField.controller?.text, 'Organization reference');

      await tester.enterText(find.byType(TextFormField).at(1), 'Changed role');
      tester.testTextInput.hide();
      await tester.pumpAndSettle();
      final saveButton = find.widgetWithText(FilledButton, 'Save');
      await tester.drag(find.byType(ListView).last, const Offset(0, -240));
      await tester.pumpAndSettle();
      await tester.ensureVisible(saveButton);
      await tester.tap(saveButton);
      await tester.pumpAndSettle();
      expect(
        find.text('A role with this name already exists.'),
        findsOneWidget,
      );
      expect(
        find.text('Please correct the highlighted fields.'),
        findsOneWidget,
      );
      expect(
        find.text('This reference cannot be changed right now.'),
        findsOneWidget,
      );
      final retryButton = find.widgetWithText(FilledButton, 'Save');
      await tester.drag(find.byType(ListView).last, const Offset(0, -240));
      await tester.pumpAndSettle();
      await tester.ensureVisible(retryButton);
      await tester.tap(retryButton);
      await tester.pumpAndSettle();
      expect(
        find.text('You are not authorized to save this job role.'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Job Role update saves and returns to the refreshed list', (
    tester,
  ) async {
    var listReads = 0;
    when(
      () => repository.references(
        ReferenceKind.jobRoles,
        page: 1,
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenAnswer((_) async {
      listReads++;
      return ManagementPage(
        items: [
          OrganizationReference(
            id: 1,
            code: 'REF1',
            name: listReads == 1 ? 'Operations 1' : 'Senior Operator',
            description: 'Organization reference',
          ),
        ],
        count: 1,
        hasMore: false,
      );
    });
    when(
      () => repository.saveReference(
        ReferenceKind.jobRoles,
        id: 1,
        original: any(named: 'original'),
        code: 'REF1',
        name: 'Senior Operator',
        description: 'Organization reference',
        isActive: true,
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenAnswer(
      (_) async => const OrganizationReference(
        id: 1,
        code: 'REF1',
        name: 'Senior Operator',
        description: 'Organization reference',
      ),
    );
    await launch(
      tester,
      path: '/workspace/job-roles',
      identity: managementIdentity(
        capabilities: {
          'organization.view_jobrole',
          'organization.change_jobrole',
        },
      ),
    );
    await tester.tap(find.byTooltip('Edit job role: Operations 1'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).at(1), 'Senior Operator');
    tester.testTextInput.hide();
    await tester.pumpAndSettle();
    final saveButton = find.widgetWithText(FilledButton, 'Save');
    await tester.drag(find.byType(ListView).last, const Offset(0, -240));
    await tester.pumpAndSettle();
    await tester.ensureVisible(saveButton);
    await tester.tap(saveButton);
    await tester.pumpAndSettle();
    expect(find.text('Senior Operator'), findsOneWidget);
    verify(
      () => repository.saveReference(
        ReferenceKind.jobRoles,
        id: 1,
        original: any(named: 'original'),
        code: 'REF1',
        name: 'Senior Operator',
        description: 'Organization reference',
        isActive: true,
        cancelToken: any(named: 'cancelToken'),
      ),
    ).called(1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('unchanged Job Role edit cannot be submitted', (tester) async {
    await launch(
      tester,
      path: '/workspace/job-roles',
      identity: managementIdentity(
        capabilities: {
          'organization.view_jobrole',
          'organization.change_jobrole',
        },
      ),
    );
    await tester.tap(find.byTooltip('Edit job role: Operations 1'));
    await tester.pumpAndSettle();
    var saveButton = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Save'),
    );
    expect(saveButton.onPressed, isNull);

    final nameField = find.byType(TextFormField).at(1);
    await tester.enterText(nameField, 'Temporary name');
    await tester.pump();
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, 'Save'))
          .onPressed,
      isNotNull,
    );
    await tester.enterText(nameField, 'Operations 1');
    await tester.pump();
    saveButton = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Save'),
    );
    expect(saveButton.onPressed, isNull);
    verifyNever(
      () => repository.saveReference(
        ReferenceKind.jobRoles,
        id: 1,
        original: any(named: 'original'),
        code: any(named: 'code'),
        name: any(named: 'name'),
        description: any(named: 'description'),
        isActive: any(named: 'isActive'),
        cancelToken: any(named: 'cancelToken'),
      ),
    );
  });

  testWidgets(
    'permission denial and account switching cannot show save success',
    (tester) async {
      final request = Completer<OrganizationReference>();
      late CancelToken token;
      when(
        () => repository.saveReference(
          ReferenceKind.departments,
          original: null,
          code: 'D2',
          name: 'Facilities',
          description: '',
          isActive: true,
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer((call) {
        token = call.namedArguments[#cancelToken] as CancelToken;
        return request.future;
      });
      await launch(
        tester,
        path: '/workspace/departments',
        identity: managementIdentity(writeReferences: true),
      );
      await tester.tap(find.byTooltip('Add department'));
      await tester.pumpAndSettle();
      expect(find.byType(OrganizationReferenceFormScreen), findsOneWidget);
      await tester.enterText(find.byType(TextFormField).at(0), 'D2');
      await tester.enterText(find.byType(TextFormField).at(1), 'Facilities');
      tester.testTextInput.hide();
      await tester.pumpAndSettle();
      final saveButton = find.widgetWithText(FilledButton, 'Save');
      await tester.drag(find.byType(ListView).last, const Offset(0, -240));
      await tester.pumpAndSettle();
      await tester.ensureVisible(saveButton);
      await tester.tap(saveButton);
      await tester.pump();
      expect(find.text('Saving…'), findsOneWidget);

      auth.setAuth(
        AuthAuthenticated.identity(
          managementIdentity(username: 'new-account', writeReferences: true),
        ),
      );
      await tester.pumpAndSettle();
      expect(token.isCancelled, isTrue);
      expect(
        find.text('This account does not have permission to make this change.'),
        findsOneWidget,
      );
      request.complete(
        const OrganizationReference(id: 2, code: 'D2', name: 'Facilities'),
      );
      await tester.pumpAndSettle();
      expect(find.text('Department saved.'), findsNothing);
      expect(find.text('Facilities'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  for (final brightness in Brightness.values) {
    for (final (size, scale) in [
      (const Size(320, 640), 2.0),
      (const Size(844, 390), 1.6),
    ]) {
      testWidgets('$brightness management pages fit $size at ${scale}x', (
        tester,
      ) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await launch(
          tester,
          path: '/workspace/dashboard',
          brightness: brightness,
          textScale: scale,
        );
        for (final path in [
          '/workspace/dashboard',
          '/workspace/employees',
          '/workspace/employees/1',
          '/workspace/job-roles',
        ]) {
          router.go(path);
          await tester.pumpAndSettle();
          await tester.drag(find.byType(ListView), const Offset(0, -500));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull, reason: path);
        }
      });
    }
  }
}
