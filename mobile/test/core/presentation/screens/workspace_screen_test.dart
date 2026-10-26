import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:training_app/core/presentation/screens/workspace_screen.dart';
import 'package:training_app/core/theme/app_spacing.dart';
import 'package:training_app/core/theme/app_theme.dart';
import 'package:training_app/features/auth/domain/models/auth_state.dart';
import 'package:training_app/features/auth/domain/models/authenticated_identity.dart';
import 'package:training_app/features/auth/presentation/controllers/auth_controller.dart';

class WorkspaceTestAuthController extends AuthController {
  final AuthenticatedIdentity _identity;
  WorkspaceTestAuthController(this._identity);

  @override
  AuthState build() => AuthAuthenticated.identity(_identity);
}

void main() {
  Finder cardOf(String title) => find.ancestor(
        of: find.widgetWithText(ListTile, title),
        matching: find.byType(Card),
      );

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

      await tester.pumpWidget(createSubject(identity));
      await tester.pumpAndSettle();

      final managementCard = cardOf('Management access');
      final dashboardCard = cardOf('Company dashboard');
      final employeeCard = cardOf('Employee directory');
      final departmentsCard = cardOf('Departments');
      final jobRolesCard = cardOf('Job roles');

      expect(managementCard, findsOneWidget);
      expect(dashboardCard, findsOneWidget);
      expect(employeeCard, findsOneWidget);
      expect(departmentsCard, findsOneWidget);
      expect(jobRolesCard, findsOneWidget);

      final managementRect = tester.getRect(managementCard);
      final dashboardRect = tester.getRect(dashboardCard);
      final employeeRect = tester.getRect(employeeCard);
      final departmentsRect = tester.getRect(departmentsCard);
      final jobRolesRect = tester.getRect(jobRolesCard);

      expect(dashboardRect.top - managementRect.bottom, AppSpacing.md);
      expect(employeeRect.top - dashboardRect.bottom, AppSpacing.md);
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

      await tester.pumpWidget(createSubject(identity));
      await tester.pumpAndSettle();

      final teamCard = cardOf('Team access');
      final dashboardCard = cardOf('Team dashboard');
      final employeeCard = cardOf('Employee directory');
      final departmentsCard = cardOf('Departments');
      final jobRolesCard = cardOf('Job roles');

      expect(teamCard, findsOneWidget);
      expect(dashboardCard, findsOneWidget);
      expect(employeeCard, findsOneWidget);
      expect(departmentsCard, findsOneWidget);
      expect(jobRolesCard, findsOneWidget);

      final teamRect = tester.getRect(teamCard);
      final dashboardRect = tester.getRect(dashboardCard);
      final employeeRect = tester.getRect(employeeCard);
      final departmentsRect = tester.getRect(departmentsCard);
      final jobRolesRect = tester.getRect(jobRolesCard);

      expect(dashboardRect.top - teamRect.bottom, AppSpacing.md);
      expect(employeeRect.top - dashboardRect.bottom, AppSpacing.md);
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

        await tester.pumpWidget(createSubject(identity, theme: theme));
        await tester.pumpAndSettle();

        final managementCard = cardOf('Management access');
        final dashboardCard = cardOf('Company dashboard');
        final employeeCard = cardOf('Employee directory');

        final managementRect = tester.getRect(managementCard);
        final dashboardRect = tester.getRect(dashboardCard);
        final employeeRect = tester.getRect(employeeCard);

        expect(dashboardRect.top - managementRect.bottom, AppSpacing.md);
        expect(employeeRect.top - dashboardRect.bottom, AppSpacing.md);
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
}

