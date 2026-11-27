import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:training_app/core/presentation/screens/app_shell.dart';
import 'package:training_app/core/presentation/screens/workspace_screen.dart';
import 'package:training_app/core/theme/app_spacing.dart';
import 'package:training_app/core/theme/app_theme.dart';
import 'package:training_app/features/auth/domain/models/auth_state.dart';
import 'package:training_app/features/auth/domain/models/authenticated_identity.dart';
import 'package:training_app/features/auth/domain/models/employee.dart';
import 'package:training_app/features/auth/presentation/controllers/auth_controller.dart';

class WorkspaceTestAuthController extends AuthController {
  final AuthenticatedIdentity _identity;
  WorkspaceTestAuthController(this._identity);

  @override
  AuthState build() => AuthAuthenticated.identity(_identity);

  void setAuth(AuthState auth) => state = auth;
}

void main() {
  Finder cardOf(String title) => find.ancestor(
    of: find.widgetWithText(ListTile, title),
    matching: find.byType(Card),
  );

  void setSpacingViewport(WidgetTester tester) {
    // Keep every authorized card available for adjacent-card measurements.
    // The narrow-screen and large-text case uses its own viewport below.
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  Widget createSubject(
    AuthenticatedIdentity identity, {
    ThemeData? theme,
    double textScale = 1.0,
  }) {
    return ProviderScope(
      overrides: [
        authControllerProvider.overrideWith(
          () => WorkspaceTestAuthController(identity),
        ),
      ],
      child: MaterialApp(
        theme: theme ?? AppTheme.lightTheme,
        home: MediaQuery(
          data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
          child: const WorkspaceScreen(),
        ),
      ),
    );
  }

  testWidgets(
    'Management access workspace cards maintain consistent 16px vertical separation',
    (tester) async {
      final identity = AuthenticatedIdentity(
        username: 'admin',
        displayName: 'Administrator',
        capabilities: {
          'management_workspace',
          'company_dashboard',
          'organization.view_employee',
          'organization.view_department',
          'organization.view_jobrole',
        },
      );

      setSpacingViewport(tester);
      await tester.pumpWidget(createSubject(identity));
      await tester.pumpAndSettle();

      final managementCard = cardOf('Management access');
      final dashboardCard = cardOf('Company dashboard');
      final reportCard = cardOf('Assignment reports');
      final employeeCard = cardOf('Employee directory');
      final departmentsCard = cardOf('Departments');
      final jobRolesCard = cardOf('Job roles');

      expect(managementCard, findsOneWidget);
      expect(dashboardCard, findsOneWidget);
      expect(reportCard, findsOneWidget);
      expect(employeeCard, findsOneWidget);
      expect(departmentsCard, findsOneWidget);
      expect(jobRolesCard, findsOneWidget);

      final managementRect = tester.getRect(managementCard);
      final dashboardRect = tester.getRect(dashboardCard);
      final reportRect = tester.getRect(reportCard);
      final employeeRect = tester.getRect(employeeCard);
      final departmentsRect = tester.getRect(departmentsCard);
      final jobRolesRect = tester.getRect(jobRolesCard);

      expect(dashboardRect.top - managementRect.bottom, AppSpacing.md);
      expect(reportRect.top - dashboardRect.bottom, AppSpacing.md);
      expect(employeeRect.top - reportRect.bottom, AppSpacing.md);
      expect(departmentsRect.top - employeeRect.bottom, AppSpacing.md);
      expect(jobRolesRect.top - departmentsRect.bottom, AppSpacing.md);
    },
  );

  testWidgets(
    'Team access workspace cards maintain consistent 16px vertical separation',
    (tester) async {
      final identity = AuthenticatedIdentity(
        username: 'manager',
        displayName: 'Team Manager',
        capabilities: {
          'team_workspace',
          'team_dashboard',
          'organization.view_employee',
          'organization.view_department',
          'organization.view_jobrole',
        },
      );

      setSpacingViewport(tester);
      await tester.pumpWidget(createSubject(identity));
      await tester.pumpAndSettle();

      final teamCard = cardOf('Team access');
      final dashboardCard = cardOf('Team dashboard');
      final reportCard = cardOf('Assignment reports');
      final teamAssignmentsCard = cardOf('Team Assignments');
      final employeeCard = cardOf('Employee directory');
      final departmentsCard = cardOf('Departments');
      final jobRolesCard = cardOf('Job roles');

      expect(teamCard, findsOneWidget);
      expect(dashboardCard, findsOneWidget);
      expect(reportCard, findsOneWidget);
      expect(teamAssignmentsCard, findsOneWidget);
      expect(employeeCard, findsOneWidget);
      expect(departmentsCard, findsOneWidget);
      expect(jobRolesCard, findsOneWidget);

      final teamRect = tester.getRect(teamCard);
      final dashboardRect = tester.getRect(dashboardCard);
      final reportRect = tester.getRect(reportCard);
      final teamAssignmentsRect = tester.getRect(teamAssignmentsCard);
      final employeeRect = tester.getRect(employeeCard);
      final departmentsRect = tester.getRect(departmentsCard);
      final jobRolesRect = tester.getRect(jobRolesCard);

      expect(dashboardRect.top - teamRect.bottom, AppSpacing.md);
      expect(reportRect.top - dashboardRect.bottom, AppSpacing.md);
      expect(teamAssignmentsRect.top - reportRect.bottom, AppSpacing.md);
      expect(employeeRect.top - teamAssignmentsRect.bottom, AppSpacing.md);
      expect(departmentsRect.top - employeeRect.bottom, AppSpacing.md);
      expect(jobRolesRect.top - departmentsRect.bottom, AppSpacing.md);
    },
  );

  testWidgets(
    'Combined capabilities separate Management and Team access cards by 16px',
    (tester) async {
      final identity = AuthenticatedIdentity(
        username: 'lead',
        displayName: 'Lead Administrator',
        capabilities: {
          'management_workspace',
          'team_workspace',
          'company_dashboard',
          'organization.view_employee',
          'organization.view_department',
          'organization.view_jobrole',
        },
      );

      setSpacingViewport(tester);
      await tester.pumpWidget(createSubject(identity));
      await tester.pumpAndSettle();

      final managementCard = cardOf('Management access');
      final teamCard = cardOf('Team access');
      final dashboardCard = cardOf('Company dashboard');

      expect(managementCard, findsOneWidget);
      expect(teamCard, findsOneWidget);
      expect(dashboardCard, findsOneWidget);

      final managementRect = tester.getRect(managementCard);
      final teamRect = tester.getRect(teamCard);
      final dashboardRect = tester.getRect(dashboardCard);

      expect(teamRect.top - managementRect.bottom, AppSpacing.md);
      expect(dashboardRect.top - teamRect.bottom, AppSpacing.md);
    },
  );

  for (final theme in [AppTheme.lightTheme, AppTheme.darkTheme]) {
    testWidgets(
      'Workspace cards maintain consistent spacing in ${theme.brightness.name} theme',
      (tester) async {
        final identity = AuthenticatedIdentity(
          username: 'admin',
          displayName: 'Administrator',
          capabilities: {
            'management_workspace',
            'company_dashboard',
            'organization.view_employee',
            'organization.view_department',
            'organization.view_jobrole',
          },
        );

        setSpacingViewport(tester);
        await tester.pumpWidget(createSubject(identity, theme: theme));
        await tester.pumpAndSettle();

        final managementCard = cardOf('Management access');
        final dashboardCard = cardOf('Company dashboard');
        final reportCard = cardOf('Assignment reports');
        final employeeCard = cardOf('Employee directory');

        final managementRect = tester.getRect(managementCard);
        final dashboardRect = tester.getRect(dashboardCard);
        final reportRect = tester.getRect(reportCard);
        final employeeRect = tester.getRect(employeeCard);

        expect(dashboardRect.top - managementRect.bottom, AppSpacing.md);
        expect(reportRect.top - dashboardRect.bottom, AppSpacing.md);
        expect(employeeRect.top - reportRect.bottom, AppSpacing.md);
      },
    );
  }

  testWidgets(
    'Workspace supports narrow layout and large text scale without overflow',
    (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final identity = AuthenticatedIdentity(
        username: 'admin',
        displayName: 'Administrator',
        capabilities: {
          'management_workspace',
          'company_dashboard',
          'organization.view_employee',
          'organization.view_department',
          'organization.view_jobrole',
        },
      );

      await tester.pumpWidget(
        createSubject(identity, theme: AppTheme.darkTheme, textScale: 2.0),
      );
      await tester.pumpAndSettle();

      expect(find.byType(WorkspaceScreen), findsOneWidget);
      await tester.drag(find.byType(ListView), const Offset(0, -400));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  AuthenticatedIdentity teamLearner() => AuthenticatedIdentity(
    userId: 2,
    username: 'manager',
    displayName: 'Team Manager',
    employee: Employee(
      username: 'manager',
      employeeCode: 'MGR',
      displayName: 'Team Manager',
      department: 'Operations',
      jobRole: 'Supervisor',
      isActive: true,
    ),
    capabilities: {'team_workspace', 'team_dashboard', 'personal_learning'},
  );

  testWidgets(
    'Team Assignments opens the existing report route, separately from My Training',
    (tester) async {
      setSpacingViewport(tester);
      final router = GoRouter(
        initialLocation: '/workspace',
        routes: [
          ShellRoute(
            builder: (_, state, child) =>
                AppShell(location: state.uri.path, child: child),
            routes: [
              GoRoute(
                path: '/workspace',
                builder: (_, _) => const WorkspaceScreen(),
              ),
              GoRoute(
                path: '/workspace/reports/assignments',
                builder: (_, _) => const Scaffold(
                  body: Text('Existing assignment-report destination'),
                ),
              ),
              GoRoute(
                path: '/learning',
                builder: (_, _) => const Scaffold(body: Text('My Training')),
              ),
            ],
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            authControllerProvider.overrideWith(
              () => WorkspaceTestAuthController(teamLearner()),
            ),
          ],
          child: MaterialApp.router(
            routerConfig: router,
            theme: AppTheme.lightTheme,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Team Assignments'), findsOneWidget);
      expect(find.text('Assignment reports'), findsOneWidget);
      await tester.tap(find.text('Team Assignments'));
      await tester.pumpAndSettle();
      expect(router.state.matchedLocation, '/workspace/reports/assignments');
      expect(
        find.text('Existing assignment-report destination'),
        findsOneWidget,
      );
      await tester.tap(find.text('Learning'));
      await tester.pumpAndSettle();
      expect(router.state.matchedLocation, '/learning');
      expect(find.text('My Training'), findsOneWidget);
      expect(find.text('Existing assignment-report destination'), findsNothing);
    },
  );

  testWidgets(
    'Team Assignments requires team access, not a role name or unrelated authority',
    (tester) async {
      setSpacingViewport(tester);
      for (final capabilities in <Set<String>>[
        {'personal_learning'},
        {'management_workspace', 'company_dashboard'},
        {'management_workspace', 'assignment_report'},
        {'training.view_training'},
        {'training.add_trainingassignment'},
      ]) {
        final identity = AuthenticatedIdentity(
          username: 'manager',
          displayName: 'Manager without team access',
          capabilities: capabilities,
        );
        await tester.pumpWidget(createSubject(identity));
        await tester.pumpAndSettle();
        expect(find.text('Team Assignments'), findsNothing);
        if (capabilities.contains('company_dashboard') ||
            capabilities.contains('assignment_report')) {
          expect(find.text('Assignment reports'), findsOneWidget);
        }
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      }
    },
  );

  testWidgets('Team Assignments is removed on account switch and logout', (
    tester,
  ) async {
    setSpacingViewport(tester);
    final auth = WorkspaceTestAuthController(teamLearner());
    final container = ProviderContainer(
      overrides: [authControllerProvider.overrideWith(() => auth)],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.lightTheme,
          home: const WorkspaceScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Team Assignments'), findsOneWidget);
    auth.setAuth(
      AuthAuthenticated.identity(
        AuthenticatedIdentity(
          userId: 3,
          username: 'employee',
          displayName: 'Employee',
          capabilities: {'personal_learning'},
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Team Assignments'), findsNothing);
    expect(find.text('Assignment reports'), findsNothing);
    expect(find.text('Team Manager'), findsNothing);
    auth.setAuth(AuthUnauthenticated());
    await tester.pumpAndSettle();
    expect(find.byType(ListTile), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
