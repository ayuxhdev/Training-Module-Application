import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:training_app/core/errors/api_error.dart';
import 'package:training_app/core/presentation/components/secondary_button.dart';
import 'package:training_app/core/theme/app_spacing.dart';
import 'package:training_app/core/theme/app_theme.dart';
import 'package:training_app/features/auth/domain/models/authenticated_identity.dart';
import 'package:training_app/features/auth/domain/models/auth_state.dart';
import 'package:training_app/features/auth/domain/models/employee.dart';
import 'package:training_app/features/auth/presentation/controllers/auth_controller.dart';
import 'package:training_app/features/profile/presentation/screens/profile_screen.dart';

class AuthControllerMock extends AuthController {
  final Future<Employee> Function()? onRefresh;
  int logoutCalls = 0;
  AuthControllerMock({this.onRefresh});

  @override
  Future<void> refreshProfile() async {
    final refresh = onRefresh;
    if (refresh == null) {
      throw StateError('refreshProfile called without an onRefresh callback.');
    }
    state = AuthAuthenticated(await refresh());
  }

  @override
  Future<void> logout() async {
    logoutCalls++;
    state = AuthUnauthenticated();
  }

  @override
  AuthState build() {
    return AuthAuthenticated(
      Employee(
        username: 'jdoe',
        employeeCode: 'EMP123',
        displayName: 'John Doe',
        department: 'Engineering',
        jobRole: 'Developer',
        isActive: true,
      ),
    );
  }
}


class ProfileIdentityAuthController extends AuthController {
  final AuthenticatedIdentity _identity;
  ProfileIdentityAuthController(this._identity);

  @override
  AuthState build() => AuthAuthenticated.identity(_identity);
}

void main() {
  Future<void> pumpProfile(WidgetTester tester, AuthControllerMock auth) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [authControllerProvider.overrideWith(() => auth)],
        child: const MaterialApp(home: ProfileScreen()),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('refresh keeps profile visible and displays updated data', (
    tester,
  ) async {
    final response = Completer<Employee>();
    await pumpProfile(
      tester,
      AuthControllerMock(onRefresh: () => response.future),
    );
    final refresh = tester
        .widget<RefreshIndicator>(find.byType(RefreshIndicator))
        .onRefresh();
    await tester.pump();
    expect(find.text('John Doe'), findsOneWidget);
    response.complete(
      Employee(
        username: 'jdoe',
        employeeCode: 'EMP123',
        displayName: 'Updated Name',
        department: 'Operations',
        jobRole: 'Developer',
        isActive: true,
      ),
    );
    await refresh;
    await tester.pump();
    expect(find.text('Updated Name'), findsOneWidget);
    expect(find.text('Operations'), findsOneWidget);
    expect(find.text('John Doe'), findsNothing);
  });

  testWidgets('refresh failure retains information and shows readable error', (
    tester,
  ) async {
    await pumpProfile(
      tester,
      AuthControllerMock(
        onRefresh: () async => throw ApiError.networkFailure(),
      ),
    );
    await tester
        .widget<RefreshIndicator>(find.byType(RefreshIndicator))
        .onRefresh();
    await tester.pump();
    expect(find.text('John Doe'), findsOneWidget);
    expect(find.text(ApiError.networkFailure().message), findsOneWidget);
    expect(find.byType(SnackBar), findsOneWidget);
  });

  testWidgets('logout hides employee information immediately', (tester) async {
    final auth = AuthControllerMock();
    await pumpProfile(tester, auth);
    await tester.scrollUntilVisible(find.text('Logout'), 150);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Logout'));
    await tester.pump();
    expect(auth.logoutCalls, 1);
    expect(find.text('John Doe'), findsNothing);
    expect(find.text('EMP123'), findsNothing);
  });

  testWidgets('ProfileScreen displays authenticated employee data', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          authControllerProvider.overrideWith(() => AuthControllerMock()),
        ],
        child: const MaterialApp(home: ProfileScreen()),
      ),
    );

    await tester.pumpAndSettle();

    expect(find.text('Profile'), findsOneWidget);
    expect(find.text('John Doe'), findsOneWidget);
    expect(find.text('EMP123'), findsOneWidget);
    expect(find.text('Engineering'), findsOneWidget);
    expect(find.text('Developer'), findsOneWidget);
    expect(find.text('jdoe'), findsOneWidget);
    expect(find.text('ACTIVE'), findsOneWidget);
    expect(find.text('System Default'), findsNothing);
    await tester.tap(find.byTooltip('Appearance'));
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsOneWidget);
    expect(find.text('System Default'), findsOneWidget);
    await tester.tap(find.byTooltip('Close appearance'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('My Certificates'), 150);
    await tester.pumpAndSettle();
    expect(find.text('My Certificates'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Logout'), 150);
    await tester.pumpAndSettle();
    expect(find.byType(SecondaryButton), findsOneWidget);
  });

  testWidgets(
    'Profile navigation cards maintain consistent 16px separation from each other and logout button',
    (tester) async {
      final employee = Employee(
        username: 'lead',
        employeeCode: 'EMP999',
        displayName: 'Lead Employee',
        department: 'Operations',
        jobRole: 'Specialist',
        isActive: true,
      );
      final identity = AuthenticatedIdentity(
        username: 'lead',
        displayName: 'Lead Employee',
        employee: employee,
        capabilities: {
          'personal_learning',
          'organization.view_department',
          'organization.view_jobrole',
        },
      );

      tester.view.physicalSize = const Size(800, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      for (final theme in [AppTheme.lightTheme, AppTheme.darkTheme]) {
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              authControllerProvider.overrideWith(
                () => ProfileIdentityAuthController(identity),
              ),
            ],
            child: MaterialApp(
              theme: theme,
              home: const ProfileScreen(),
            ),
          ),
        );
        await tester.pumpAndSettle();

        final certsFinder = find.ancestor(
          of: find.widgetWithText(ListTile, 'My Certificates'),
          matching: find.byType(Card),
        );
        final deptFinder = find.ancestor(
          of: find.widgetWithText(ListTile, 'Departments'),
          matching: find.byType(Card),
        );
        final jobFinder = find.ancestor(
          of: find.widgetWithText(ListTile, 'Job roles'),
          matching: find.byType(Card),
        );
        final logoutFinder = find.widgetWithText(SecondaryButton, 'Logout');

        expect(certsFinder, findsOneWidget);
        expect(deptFinder, findsOneWidget);
        expect(jobFinder, findsOneWidget);
        expect(logoutFinder, findsOneWidget);

        final certsRect = tester.getRect(certsFinder);
        final deptRect = tester.getRect(deptFinder);
        final jobRect = tester.getRect(jobFinder);
        final logoutRect = tester.getRect(logoutFinder);

        expect(deptRect.top - certsRect.bottom, AppSpacing.md);
        expect(jobRect.top - deptRect.bottom, AppSpacing.md);
        expect(logoutRect.top - jobRect.bottom, AppSpacing.md);
      }
    },
  );
}