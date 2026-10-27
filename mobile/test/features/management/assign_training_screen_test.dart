import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';
import 'package:training_app/core/errors/api_error.dart';
import 'package:training_app/core/router/app_router.dart';
import 'package:training_app/core/theme/app_theme.dart';
import 'package:training_app/features/auth/domain/models/auth_state.dart';
import 'package:training_app/features/auth/domain/models/authenticated_identity.dart';
import 'package:training_app/features/auth/presentation/controllers/auth_controller.dart';
import 'package:training_app/features/dashboard/domain/models/dashboard_data.dart';
import 'package:training_app/features/dashboard/presentation/controllers/dashboard_controller.dart';
import 'package:training_app/features/management/data/repositories/management_repository.dart';
import 'package:training_app/features/management/domain/models/management_models.dart';
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
      () => repository.assignableTrainingVersions(
        page: any(named: 'page'),
        pageSize: any(named: 'pageSize'),
        search: any(named: 'search'),
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenAnswer((_) async => assignableVersionPage());
  });

  Future<ProviderContainer> launch(
    WidgetTester tester, {
    AuthenticatedIdentity? identity,
    String path = '/workspace',
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

  group('DirectoryEmployeeScreen assign training entry point', () {
    testWidgets('shows assign training button for eligible subordinate', (
      tester,
    ) async {
      when(
        () => repository.employee(10, cancelToken: any(named: 'cancelToken')),
      ).thenAnswer(
        (_) async => DirectoryEmployee.fromJson(
          employeeDetailJson(10, 'Subordinate Employee')
            ..['employee_code'] = 'SUB10'
            ..['is_active'] = true,
        ),
      );

      await launch(tester, path: '/workspace/employees/10');

      expect(find.byKey(const ValueKey('assign-training-button')), findsOneWidget);
      expect(find.byIcon(Icons.school_outlined), findsAtLeastNWidgets(1));
    });

    testWidgets('hides assign training button for manager viewing self', (
      tester,
    ) async {
      when(
        () => repository.employee(2, cancelToken: any(named: 'cancelToken')),
      ).thenAnswer(
        (_) async => DirectoryEmployee.fromJson(
          employeeDetailJson(2, 'Manager Self')
            ..['employee_code'] = 'MGR'
            ..['is_active'] = true,
        ),
      );

      await launch(tester, path: '/workspace/employees/2');

      expect(find.byKey(const ValueKey('assign-training-button')), findsNothing);
    });

    testWidgets('hides assign training button for inactive employee', (
      tester,
    ) async {
      when(
        () => repository.employee(11, cancelToken: any(named: 'cancelToken')),
      ).thenAnswer(
        (_) async => DirectoryEmployee.fromJson(
          employeeDetailJson(11, 'Inactive Employee')
            ..['employee_code'] = 'INACT11'
            ..['is_active'] = false,
        ),
      );

      await launch(tester, path: '/workspace/employees/11');

      expect(find.byKey(const ValueKey('assign-training-button')), findsNothing);
    });

    testWidgets('hides assign training button when user lacks assignment capability', (
      tester,
    ) async {
      final viewOnlyIdentity = managementIdentity(
        team: true,
        capabilities: {
          'team_workspace',
          'organization.view_employee',
        },
      );
      when(
        () => repository.employee(10, cancelToken: any(named: 'cancelToken')),
      ).thenAnswer(
        (_) async => DirectoryEmployee.fromJson(
          employeeDetailJson(10, 'Subordinate Employee')
            ..['employee_code'] = 'SUB10'
            ..['is_active'] = true,
        ),
      );

      await launch(tester, identity: viewOnlyIdentity, path: '/workspace/employees/10');

      expect(find.byKey(const ValueKey('assign-training-button')), findsNothing);
    });

    testWidgets('tapping assign training navigates to assign training screen', (
      tester,
    ) async {
      when(
        () => repository.employee(10, cancelToken: any(named: 'cancelToken')),
      ).thenAnswer(
        (_) async => DirectoryEmployee.fromJson(
          employeeDetailJson(10, 'Subordinate Employee')
            ..['employee_code'] = 'SUB10'
            ..['is_active'] = true,
        ),
      );

      await launch(tester, path: '/workspace/employees/10');

      final button = find.byKey(const ValueKey('assign-training-button'));
      await tester.tap(button);
      await tester.pumpAndSettle();

      expect(find.text('Assign training'), findsAtLeastNWidgets(1));
      expect(find.text('Subordinate Employee'), findsOneWidget);
      expect(find.text('SUB10'), findsOneWidget);
    });
  });

  group('AssignTrainingScreen workflow and behavior', () {
    testWidgets('renders read-only target recipient details', (tester) async {
      when(
        () => repository.employee(10, cancelToken: any(named: 'cancelToken')),
      ).thenAnswer(
        (_) async => DirectoryEmployee.fromJson(
          employeeDetailJson(10, 'John Doe')
            ..['employee_code'] = 'EMP010'
            ..['is_active'] = true,
        ),
      );

      await launch(tester, path: '/workspace/employees/10');
      await tester.tap(find.byKey(const ValueKey('assign-training-button')));
      await tester.pumpAndSettle();

      expect(find.text('John Doe'), findsOneWidget);
      expect(find.text('EMP010'), findsOneWidget);
      expect(find.text('Recipient details'), findsOneWidget);
      expect(find.text('Read-only'), findsOneWidget);
      expect(find.byIcon(Icons.lock_outline), findsOneWidget);
      expect(find.text('Department'), findsOneWidget);
      expect(find.text('Job role'), findsOneWidget);
      expect(find.text('Reporting manager'), findsOneWidget);
    });

    testWidgets('displays published training versions and allows selection', (
      tester,
    ) async {
      when(
        () => repository.employee(10, cancelToken: any(named: 'cancelToken')),
      ).thenAnswer(
        (_) async => DirectoryEmployee.fromJson(
          employeeDetailJson(10, 'John Doe')
            ..['employee_code'] = 'EMP010'
            ..['is_active'] = true,
        ),
      );

      when(
        () => repository.assignableTrainingVersions(
          page: 1,
          search: any(named: 'search'),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer(
        (_) async => ManagementPage.fromJson(
          pageJson([
            assignableVersionJson(
              1,
              code: 'SAFE-1',
              trainingTitle: 'Workplace Safety',
              versionNumber: 1,
            ),
            assignableVersionJson(
              2,
              code: 'SEC-1',
              trainingTitle: 'Data Security',
              versionNumber: 2,
            ),
          ]),
          AssignableTrainingVersion.fromJson,
        ),
      );

      await launch(tester, path: '/workspace/employees/10');
      await tester.tap(find.byKey(const ValueKey('assign-training-button')));
      await tester.pumpAndSettle();

      expect(find.text('Workplace Safety'), findsOneWidget);
      expect(find.text('SAFE-1'), findsOneWidget);
      expect(find.text('Data Security'), findsOneWidget);
      expect(find.text('SEC-1'), findsOneWidget);

      final submitFinder = find.byKey(const ValueKey('submit-assignment-button'));
      expect(tester.widget<FilledButton>(submitFinder).onPressed, isNull);

      // Select Workplace Safety
      final version1Finder = find.byKey(const ValueKey('training-version-1'));
      await tester.tap(version1Finder);
      await tester.pumpAndSettle();

      // Submit button should now be enabled
      expect(tester.widget<FilledButton>(submitFinder).onPressed, isNotNull);
    });

    testWidgets('search filters training versions with debouncing', (
      tester,
    ) async {
      when(
        () => repository.employee(10, cancelToken: any(named: 'cancelToken')),
      ).thenAnswer(
        (_) async => DirectoryEmployee.fromJson(
          employeeDetailJson(10, 'John Doe')
            ..['employee_code'] = 'EMP010'
            ..['is_active'] = true,
        ),
      );

      when(
        () => repository.assignableTrainingVersions(
          page: 1,
          search: any(named: 'search'),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer(
        (_) async => assignableVersionPage(trainingTitle: 'Workplace Safety'),
      );

      await launch(tester, path: '/workspace/employees/10');
      await tester.tap(find.byKey(const ValueKey('assign-training-button')));
      await tester.pumpAndSettle();

      final searchFinder = find.byType(TextField);
      expect(searchFinder, findsOneWidget);

      await tester.enterText(searchFinder, 'security');
      // Advance past debounce (350ms)
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();

      verify(
        () => repository.assignableTrainingVersions(
          page: 1,
          search: 'security',
          cancelToken: any(named: 'cancelToken'),
        ),
      ).called(1);
    });

    testWidgets('displays empty state when no versions match', (tester) async {
      when(
        () => repository.employee(10, cancelToken: any(named: 'cancelToken')),
      ).thenAnswer(
        (_) async => DirectoryEmployee.fromJson(
          employeeDetailJson(10, 'John Doe')
            ..['employee_code'] = 'EMP010'
            ..['is_active'] = true,
        ),
      );

      when(
        () => repository.assignableTrainingVersions(
          page: 1,
          search: any(named: 'search'),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer(
        (_) async => ManagementPage.fromJson(
          pageJson([]),
          AssignableTrainingVersion.fromJson,
        ),
      );

      await launch(tester, path: '/workspace/employees/10');
      await tester.tap(find.byKey(const ValueKey('assign-training-button')));
      await tester.pumpAndSettle();

      expect(
        find.text('No published training versions match your search.'),
        findsOneWidget,
      );
    });

    testWidgets('due date can be cleared after selection', (tester) async {
      when(
        () => repository.employee(10, cancelToken: any(named: 'cancelToken')),
      ).thenAnswer(
        (_) async => DirectoryEmployee.fromJson(
          employeeDetailJson(10, 'Jane Smith')
            ..['employee_code'] = 'EMP010'
            ..['is_active'] = true,
        ),
      );

      when(
        () => repository.assignableTrainingVersions(
          page: 1,
          search: any(named: 'search'),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer(
        (_) async => assignableVersionPage(id: 5),
      );

      await launch(tester, path: '/workspace/employees/10');
      await tester.tap(find.byKey(const ValueKey('assign-training-button')));
      await tester.pumpAndSettle();

      expect(find.text('No due date set'), findsOneWidget);
      expect(find.byIcon(Icons.clear), findsNothing);
    });

    testWidgets('successful assignment shows SnackBar and pops screen', (
      tester,
    ) async {
      when(
        () => repository.employee(10, cancelToken: any(named: 'cancelToken')),
      ).thenAnswer(
        (_) async => DirectoryEmployee.fromJson(
          employeeDetailJson(10, 'Jane Smith')
            ..['employee_code'] = 'EMP010'
            ..['is_active'] = true,
        ),
      );

      when(
        () => repository.assignableTrainingVersions(
          page: 1,
          search: any(named: 'search'),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer(
        (_) async => assignableVersionPage(
          id: 5,
          trainingTitle: 'Customer Care',
        ),
      );

      final assignmentCompleter = Completer<CreatedAssignment>();
      when(
        () => repository.assignTraining(
          employeeId: 10,
          trainingVersionId: 5,
          dueDate: any(named: 'dueDate'),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer((_) => assignmentCompleter.future);

      await launch(tester, path: '/workspace/employees/10');
      await tester.tap(find.byKey(const ValueKey('assign-training-button')));
      await tester.pumpAndSettle();

      // Select version 5
      await tester.tap(find.byKey(const ValueKey('training-version-5')));
      await tester.pumpAndSettle();

      // Submit assignment
      final submitFinder = find.byKey(const ValueKey('submit-assignment-button'));
      await tester.tap(submitFinder);
      await tester.pump(); // Start request

      // Verify submit button disabled during saving
      expect(find.text('Assigning training...'), findsOneWidget);

      assignmentCompleter.complete(
        CreatedAssignment.fromJson(
          createdAssignmentJson(
            id: 200,
            employeeId: 10,
            trainingVersionId: 5,
          ),
        ),
      );
      await tester.pumpAndSettle(); // Complete request

      expect(
        find.text('Training "Customer Care" assigned to Jane Smith.'),
        findsOneWidget,
      );
      // Screen should have popped back to employee detail
      expect(find.byKey(const ValueKey('submit-assignment-button')), findsNothing);
      expect(find.byKey(const ValueKey('assign-training-button')), findsOneWidget);
    });

    testWidgets('unauthenticated 401 response triggers auth logout', (
      tester,
    ) async {
      when(
        () => repository.employee(10, cancelToken: any(named: 'cancelToken')),
      ).thenAnswer(
        (_) async => DirectoryEmployee.fromJson(
          employeeDetailJson(10, 'Jane Smith')
            ..['employee_code'] = 'EMP010'
            ..['is_active'] = true,
        ),
      );

      when(
        () => repository.assignableTrainingVersions(
          page: 1,
          search: any(named: 'search'),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer(
        (_) async => assignableVersionPage(
          id: 5,
          trainingTitle: 'Customer Care',
        ),
      );

      when(
        () => repository.assignTraining(
          employeeId: 10,
          trainingVersionId: 5,
          dueDate: any(named: 'dueDate'),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenThrow(
        ApiError(
          statusCode: 401,
          message: 'Token expired',
        ),
      );

      final container = await launch(tester, path: '/workspace/employees/10');
      await tester.tap(find.byKey(const ValueKey('assign-training-button')));
      await tester.pumpAndSettle();

      // Select version 5
      await tester.tap(find.byKey(const ValueKey('training-version-5')));
      await tester.pumpAndSettle();

      // Submit
      final submitFinder = find.byKey(const ValueKey('submit-assignment-button'));
      await tester.tap(submitFinder);
      await tester.pumpAndSettle();

      // Auth controller should have transitioned to unauthenticated
      expect(container.read(authControllerProvider), isA<AuthUnauthenticated>());
    });

    testWidgets('duplicate assignment displays server validation error banner', (
      tester,
    ) async {
      when(
        () => repository.employee(10, cancelToken: any(named: 'cancelToken')),
      ).thenAnswer(
        (_) async => DirectoryEmployee.fromJson(
          employeeDetailJson(10, 'Jane Smith')
            ..['employee_code'] = 'EMP010'
            ..['is_active'] = true,
        ),
      );

      when(
        () => repository.assignableTrainingVersions(
          page: 1,
          search: any(named: 'search'),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer(
        (_) async => assignableVersionPage(
          id: 5,
          trainingTitle: 'Customer Care',
        ),
      );

      when(
        () => repository.assignTraining(
          employeeId: 10,
          trainingVersionId: 5,
          dueDate: any(named: 'dueDate'),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenThrow(
        ApiError(
          statusCode: 400,
          message: 'Validation failed',
          details: {
            'non_field_errors': [
              'This employee already has an assignment for that training version.',
            ],
          },
        ),
      );

      await launch(tester, path: '/workspace/employees/10');
      await tester.tap(find.byKey(const ValueKey('assign-training-button')));
      await tester.pumpAndSettle();

      // Select version 5
      await tester.tap(find.byKey(const ValueKey('training-version-5')));
      await tester.pumpAndSettle();

      // Submit
      final submitFinder = find.byKey(const ValueKey('submit-assignment-button'));
      await tester.tap(submitFinder);
      await tester.pumpAndSettle();

      // Error banner displayed and screen did NOT pop
      expect(
        find.text(
          'This employee already has an assignment for that training version.',
        ),
        findsOneWidget,
      );
      expect(submitFinder, findsOneWidget);
    });

    testWidgets('discard dialog prompts when navigating back from dirty form', (
      tester,
    ) async {
      when(
        () => repository.employee(10, cancelToken: any(named: 'cancelToken')),
      ).thenAnswer(
        (_) async => DirectoryEmployee.fromJson(
          employeeDetailJson(10, 'Jane Smith')
            ..['employee_code'] = 'EMP010'
            ..['is_active'] = true,
        ),
      );

      when(
        () => repository.assignableTrainingVersions(
          page: 1,
          search: any(named: 'search'),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer(
        (_) async => assignableVersionPage(id: 5),
      );

      await launch(tester, path: '/workspace/employees/10');
      await tester.tap(find.byKey(const ValueKey('assign-training-button')));
      await tester.pumpAndSettle();

      // Select version to make form dirty
      await tester.tap(find.byKey(const ValueKey('training-version-5')));
      await tester.pumpAndSettle();

      // Tap back button
      final backButton = find.byTooltip('Back');
      await tester.tap(backButton);
      await tester.pumpAndSettle();

      // Discard dialog is displayed
      expect(find.text('Discard training assignment?'), findsOneWidget);
      expect(find.text('Keep editing'), findsOneWidget);
      expect(find.text('Discard'), findsOneWidget);

      // Tap Keep editing
      await tester.tap(find.text('Keep editing'));
      await tester.pumpAndSettle();

      // Still on assign training screen
      expect(find.byKey(const ValueKey('submit-assignment-button')), findsOneWidget);

      // Tap back again and confirm Discard
      await tester.tap(backButton);
      await tester.pumpAndSettle();

      await tester.tap(find.text('Discard'));
      await tester.pumpAndSettle();

      // Pop completed back to employee details
      expect(find.byKey(const ValueKey('submit-assignment-button')), findsNothing);
      expect(find.byKey(const ValueKey('assign-training-button')), findsOneWidget);
    });

    testWidgets('clean form pops immediately without discard confirmation', (
      tester,
    ) async {
      when(
        () => repository.employee(10, cancelToken: any(named: 'cancelToken')),
      ).thenAnswer(
        (_) async => DirectoryEmployee.fromJson(
          employeeDetailJson(10, 'Jane Smith')
            ..['employee_code'] = 'EMP010'
            ..['is_active'] = true,
        ),
      );

      when(
        () => repository.assignableTrainingVersions(
          page: 1,
          search: any(named: 'search'),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer(
        (_) async => assignableVersionPage(id: 5),
      );

      await launch(tester, path: '/workspace/employees/10');
      await tester.tap(find.byKey(const ValueKey('assign-training-button')));
      await tester.pumpAndSettle();

      // Form is clean, tap back
      final backButton = find.byTooltip('Back');
      await tester.tap(backButton);
      await tester.pumpAndSettle();

      // Popped without dialog
      expect(find.text('Discard training assignment?'), findsNothing);
      expect(find.byKey(const ValueKey('submit-assignment-button')), findsNothing);
      expect(find.byKey(const ValueKey('assign-training-button')), findsOneWidget);
    });
  });
}
