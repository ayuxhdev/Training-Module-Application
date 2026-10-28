import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';
import 'package:training_app/core/errors/api_error.dart';
import 'package:training_app/core/presentation/components/status_badge.dart';
import 'package:training_app/core/router/app_router.dart';
import 'package:training_app/core/theme/app_theme.dart';
import 'package:training_app/features/auth/domain/models/auth_state.dart';
import 'package:training_app/features/auth/domain/models/authenticated_identity.dart';
import 'package:training_app/features/auth/domain/models/employee.dart';
import 'package:training_app/features/auth/presentation/controllers/auth_controller.dart';
import 'package:training_app/features/dashboard/domain/models/dashboard_data.dart';
import 'package:training_app/features/dashboard/presentation/controllers/dashboard_controller.dart';
import 'package:training_app/features/management/data/repositories/management_repository.dart';
import 'package:training_app/features/management/domain/models/management_models.dart';
import 'package:training_app/features/notifications/presentation/controllers/notification_controller.dart';

import 'management_fixtures.dart';

class MockManagementRepository extends Mock implements ManagementRepository {}

class ZeroUnread extends NotificationUnreadController {
  @override
  Future<int?> build() async => 0;
}

void main() {
  late MockManagementRepository repository;
  late ManagementTestAuth auth;
  late GoRouter router;

  setUpAll(() {
    registerFallbackValue(CancelToken());
    registerFallbackValue(DirectoryEmployee.fromJson(employeeJson()));
  });

  setUp(() {
    repository = MockManagementRepository();
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
      () => repository.assignableTrainingVersions(
        page: any(named: 'page'),
        pageSize: any(named: 'pageSize'),
        search: any(named: 'search'),
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenAnswer((_) async => assignableVersionPage());
    when(
      () => repository.employeeAssignments(
        any(),
        page: any(named: 'page'),
        pageSize: any(named: 'pageSize'),
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenAnswer((_) async => employeeAssignmentPage());
  });

  Future<ProviderContainer> launch(
    WidgetTester tester, {
    AuthenticatedIdentity? identity,
    String path = '/workspace/employees/1',
  }) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    auth = ManagementTestAuth(
      identity ??
          managementIdentity(
            team: true,
            capabilities: {
              'team_workspace',
              'team_assignment',
              'organization.view_employee',
            },
          ),
    );
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
          theme: AppTheme.lightTheme,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: true),
            child: child!,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return container;
  }

  testWidgets(
    'DirectoryEmployeeScreen displays Training Assignments section for authorized manager',
    (tester) async {
      when(
        () => repository.employeeAssignments(
          1,
          page: 1,
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer(
        (_) async => ManagementPage.fromJson(
          pageJson([
            employeeAssignmentSummaryJson(
              id: 10,
              trainingTitle: 'Equipment Safety Protocols',
              versionNumber: 2,
              status: 'IN_PROGRESS',
              assignedAt: '2026-10-10T12:00:00Z',
              dueAt: '2026-11-01T12:00:00Z',
            ),
          ]),
          EmployeeAssignmentSummary.fromJson,
        ),
      );

      await launch(tester);

      expect(find.text('Training assignments'), findsOneWidget);
      expect(find.text('Equipment Safety Protocols'), findsOneWidget);
      expect(find.text('Version 2'), findsOneWidget);
      expect(find.widgetWithText(StatusBadge, 'IN PROGRESS'), findsOneWidget);
      expect(find.text('Assigned: 2026-10-10'), findsOneWidget);
      expect(find.text('Deadline: 2026-11-01'), findsOneWidget);
      verify(
        () => repository.employeeAssignments(
          1,
          page: 1,
          cancelToken: any(named: 'cancelToken'),
        ),
      ).called(1);
    },
  );

  testWidgets(
    'DirectoryEmployeeScreen hides Training Assignments section for directory-only viewer',
    (tester) async {
      await launch(
        tester,
        identity: managementIdentity(
          capabilities: {'organization.view_employee'},
        ),
      );

      expect(find.text('Employee details'), findsOneWidget);
      expect(find.text('Employee profile'), findsOneWidget);
      expect(find.text('Training assignments'), findsNothing);
      verifyNever(
        () => repository.employeeAssignments(
          any(),
          page: any(named: 'page'),
          cancelToken: any(named: 'cancelToken'),
        ),
      );
    },
  );

  testWidgets(
    'DirectoryEmployeeScreen displays empty state when employee has no assignments',
    (tester) async {
      when(
        () => repository.employeeAssignments(
          1,
          page: 1,
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer(
        (_) async => ManagementPage.fromJson(
          pageJson([]),
          EmployeeAssignmentSummary.fromJson,
        ),
      );

      await launch(tester);

      expect(find.text('Training assignments'), findsOneWidget);
      expect(
        find.text('No training assignments found for this employee.'),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'DirectoryEmployeeScreen renders multiple assignments with correct statuses',
    (tester) async {
      when(
        () => repository.employeeAssignments(
          1,
          page: 1,
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer(
        (_) async => ManagementPage.fromJson(
          pageJson([
            employeeAssignmentSummaryJson(
              id: 11,
              trainingTitle: 'Course Alpha',
              status: 'ASSIGNED',
            ),
            employeeAssignmentSummaryJson(
              id: 12,
              trainingTitle: 'Course Beta',
              status: 'IN_PROGRESS',
            ),
            employeeAssignmentSummaryJson(
              id: 13,
              trainingTitle: 'Course Gamma',
              status: 'COMPLETED',
              completedAt: '2026-10-25T14:30:00Z',
            ),
          ]),
          EmployeeAssignmentSummary.fromJson,
        ),
      );

      await launch(tester);

      expect(find.text('Course Alpha'), findsOneWidget);
      expect(find.widgetWithText(StatusBadge, 'ASSIGNED'), findsOneWidget);
      expect(find.text('Course Beta'), findsOneWidget);
      expect(find.widgetWithText(StatusBadge, 'IN PROGRESS'), findsOneWidget);
      expect(find.text('Course Gamma'), findsOneWidget);
      expect(find.widgetWithText(StatusBadge, 'COMPLETED'), findsOneWidget);
      expect(find.text('Completed: 2026-10-25'), findsOneWidget);
    },
  );

  testWidgets(
    'DirectoryEmployeeScreen renders overdue indicator for overdue assignment',
    (tester) async {
      when(
        () => repository.employeeAssignments(
          1,
          page: 1,
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer(
        (_) async => ManagementPage.fromJson(
          pageJson([
            employeeAssignmentSummaryJson(
              id: 20,
              trainingTitle: 'Overdue Course',
              status: 'IN_PROGRESS',
              dueAt: '2026-10-01T12:00:00Z',
              isOverdue: true,
            ),
          ]),
          EmployeeAssignmentSummary.fromJson,
        ),
      );

      await launch(tester);

      expect(find.text('Overdue Course'), findsOneWidget);
      expect(find.widgetWithText(StatusBadge, 'OVERDUE'), findsOneWidget);
      expect(find.text('Deadline: 2026-10-01'), findsOneWidget);
    },
  );

  testWidgets(
    'DirectoryEmployeeScreen renders progress summary bar and text when provided',
    (tester) async {
      when(
        () => repository.employeeAssignments(
          1,
          page: 1,
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer(
        (_) async => ManagementPage.fromJson(
          pageJson([
            employeeAssignmentSummaryJson(
              id: 25,
              trainingTitle: 'Progress Course',
              status: 'IN_PROGRESS',
              progressSummary: {
                'required_lessons_completed': 4,
                'required_lessons_total': 8,
              },
            ),
          ]),
          EmployeeAssignmentSummary.fromJson,
        ),
      );

      await launch(tester);

      expect(find.text('Progress Course'), findsOneWidget);
      expect(
        find.text('4 of 8 required lessons completed'),
        findsOneWidget,
      );
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
    },
  );

  testWidgets(
    'DirectoryEmployeeScreen supports pagination between pages',
    (tester) async {
      when(
        () => repository.employeeAssignments(
          1,
          page: 1,
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer(
        (_) async => ManagementPage.fromJson(
          pageJson(
            [
              employeeAssignmentSummaryJson(
                id: 101,
                trainingTitle: 'Page One Course',
              ),
            ],
            count: 3,
            next: 'https://api.gardensneed.test/assignments/?page=2',
          ),
          EmployeeAssignmentSummary.fromJson,
        ),
      );
      when(
        () => repository.employeeAssignments(
          1,
          page: 2,
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer(
        (_) async => ManagementPage.fromJson(
          pageJson(
            [
              employeeAssignmentSummaryJson(
                id: 102,
                trainingTitle: 'Page Two Course',
              ),
            ],
            count: 3,
            next: null,
          ),
          EmployeeAssignmentSummary.fromJson,
        ),
      );

      await launch(tester);

      expect(find.text('Page One Course'), findsOneWidget);
      expect(find.text('Page 1'), findsOneWidget);

      final nextButton = find.byKey(const ValueKey('assignments-next-page'));
      expect(nextButton, findsOneWidget);

      await tester.tap(nextButton);
      await tester.pumpAndSettle();

      expect(find.text('Page Two Course'), findsOneWidget);
      expect(find.text('Page 2'), findsOneWidget);
      verify(
        () => repository.employeeAssignments(
          1,
          page: 2,
          cancelToken: any(named: 'cancelToken'),
        ),
      ).called(1);

      final prevButton = find.byKey(const ValueKey('assignments-previous-page'));
      await tester.tap(prevButton);
      await tester.pumpAndSettle();

      expect(find.text('Page One Course'), findsOneWidget);
      expect(find.text('Page 1'), findsOneWidget);
    },
  );

  testWidgets(
    'DirectoryEmployeeScreen renders error state and retries on tap',
    (tester) async {
      var shouldFail = true;
      when(
        () => repository.employeeAssignments(
          1,
          page: 1,
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer((_) async {
        if (shouldFail) {
          throw ApiError(
            message: 'Unable to connect to the assignments service.',
            statusCode: 503,
          );
        }
        return ManagementPage.fromJson(
          pageJson([
            employeeAssignmentSummaryJson(
              id: 99,
              trainingTitle: 'Recovered Course',
            ),
          ]),
          EmployeeAssignmentSummary.fromJson,
        );
      });

      await launch(tester);

      expect(find.text('Unable to load assignments'), findsOneWidget);
      expect(
        find.text('Unable to connect to the assignments service.'),
        findsOneWidget,
      );

      shouldFail = false;
      final retryButton = find.byKey(const ValueKey('employee-assignments-retry'));
      expect(retryButton, findsOneWidget);

      await tester.tap(retryButton);
      await tester.pumpAndSettle();

      expect(find.text('Recovered Course'), findsOneWidget);
      expect(find.text('Unable to load assignments'), findsNothing);
    },
  );

  testWidgets(
    'Assign Training button remains present and functional alongside assignments section',
    (tester) async {
      await launch(tester);

      expect(find.text('Training assignments'), findsOneWidget);
      final assignButton = find.byKey(const ValueKey('assign-training-button'));
      expect(assignButton, findsOneWidget);

      await tester.tap(assignButton);
      await tester.pumpAndSettle();

      expect(find.text('Assign training'), findsWidgets);
    },
  );

  testWidgets(
    'Account switching to unauthorized user removes assignments section',
    (tester) async {
      await launch(tester);

      expect(find.text('Training assignments'), findsOneWidget);

      auth.setAuth(
        AuthAuthenticated.identity(
          managementIdentity(
            username: 'viewer',
            capabilities: {'organization.view_employee'},
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Training assignments'), findsNothing);
    },
  );

  testWidgets(
    'DirectoryEmployeeScreen hides assignments section when team-only manager views own employee',
    (tester) async {
      when(
        () => repository.employee(99, cancelToken: any(named: 'cancelToken')),
      ).thenAnswer(
        (_) async => DirectoryEmployee.fromJson(
          employeeDetailJson(99)..['employee_code'] = 'MGR',
        ),
      );

      await launch(
        tester,
        path: '/workspace/employees/99',
        identity: managementIdentity(
          team: true,
          capabilities: {
            'team_workspace',
            'team_assignment',
            'organization.view_employee',
          },
        ),
      );

      expect(find.text('Employee details'), findsOneWidget);
      expect(find.text('Training assignments'), findsNothing);
      expect(find.byKey(const ValueKey('assign-training-button')), findsNothing);
      verifyNever(
        () => repository.employeeAssignments(
          any(),
          page: any(named: 'page'),
          cancelToken: any(named: 'cancelToken'),
        ),
      );
    },
  );

  testWidgets(
    'DirectoryEmployeeScreen displays assignments section when company-authorized user views own employee',
    (tester) async {
      when(
        () => repository.employee(99, cancelToken: any(named: 'cancelToken')),
      ).thenAnswer(
        (_) async => DirectoryEmployee.fromJson(
          employeeDetailJson(99)..['employee_code'] = 'ADMIN_EMP',
        ),
      );

      final adminWithEmployee = AuthenticatedIdentity(
        userId: 1,
        username: 'admin',
        displayName: 'Administrator',
        employee: Employee(
          username: 'admin',
          employeeCode: 'ADMIN_EMP',
          displayName: 'Administrator',
          department: 'Executive',
          jobRole: 'Administrator',
          isActive: true,
        ),
        capabilities: {
          'training.add_trainingassignment',
          'organization.view_employee',
        },
      );

      await launch(
        tester,
        path: '/workspace/employees/99',
        identity: adminWithEmployee,
      );

      expect(find.text('Employee details'), findsOneWidget);
      expect(find.text('Training assignments'), findsOneWidget);
      verify(
        () => repository.employeeAssignments(
          99,
          page: 1,
          cancelToken: any(named: 'cancelToken'),
        ),
      ).called(1);
    },
  );

  testWidgets(
    'DirectoryEmployeeScreen displays assignments section when company-authorized user views permitted employee',
    (tester) async {
      final companyAdmin = managementIdentity(
        capabilities: {
          'training.add_trainingassignment',
          'organization.view_employee',
        },
      );

      await launch(
        tester,
        path: '/workspace/employees/1',
        identity: companyAdmin,
      );

      expect(find.text('Employee details'), findsOneWidget);
      expect(find.text('Training assignments'), findsOneWidget);
      verify(
        () => repository.employeeAssignments(
          1,
          page: 1,
          cancelToken: any(named: 'cancelToken'),
        ),
      ).called(1);
    },
  );

  testWidgets(
    'DirectoryEmployeeScreen handles mixed-role manager with company authority correctly for both self and subordinate',
    (tester) async {
      when(
        () => repository.employee(99, cancelToken: any(named: 'cancelToken')),
      ).thenAnswer(
        (_) async => DirectoryEmployee.fromJson(
          employeeDetailJson(99)..['employee_code'] = 'MGR',
        ),
      );

      final mixedRoleManager = managementIdentity(
        team: true,
        capabilities: {
          'team_workspace',
          'team_assignment',
          'training.add_trainingassignment',
          'organization.view_employee',
        },
      );

      // 1. Viewing own employee: section is visible because of company-wide authority
      await launch(
        tester,
        path: '/workspace/employees/99',
        identity: mixedRoleManager,
      );

      expect(find.text('Training assignments'), findsOneWidget);
      verify(
        () => repository.employeeAssignments(
          99,
          page: 1,
          cancelToken: any(named: 'cancelToken'),
        ),
      ).called(1);

      // 2. Navigating to subordinate: section is also visible
      router.go('/workspace/employees/1');
      await tester.pumpAndSettle();

      expect(find.text('Training assignments'), findsOneWidget);
      verify(
        () => repository.employeeAssignments(
          1,
          page: 1,
          cancelToken: any(named: 'cancelToken'),
        ),
      ).called(1);
    },
  );
}
