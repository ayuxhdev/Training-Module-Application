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
  setUpAll(() => registerFallbackValue(CancelToken()));
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
        employeeJson(call.positionalArguments.first as int),
      ),
    );
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
