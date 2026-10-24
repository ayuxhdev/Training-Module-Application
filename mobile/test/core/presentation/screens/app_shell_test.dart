import 'package:training_app/core/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:training_app/core/presentation/screens/app_shell.dart';
import 'package:training_app/features/auth/domain/models/auth_state.dart';
import 'package:training_app/features/auth/domain/models/employee.dart';
import 'package:training_app/features/auth/presentation/controllers/auth_controller.dart';

class ShellAuthController extends AuthController {
  @override
  AuthState build() => AuthAuthenticated(Employee(
    username: 'learner', employeeCode: 'QA', displayName: 'Learner',
    department: 'QA', jobRole: 'Employee', isActive: true,
  ));
}

void main() {
  for (final (location, index) in [('/dashboard', 0), ('/learning/assignments/42', 1), ('/profile', 2)]) {
  testWidgets('shell selects $location without a GoRouterState ancestor', (tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [authControllerProvider.overrideWith(() => ShellAuthController())],
      child: MaterialApp(home: AppShell(location: location, child: const Text('Content'))),
    ));
    expect(tester.takeException(), isNull);
    expect(find.text('Content'), findsOneWidget);
    final navBar = tester.widget<NavigationBar>(find.byType(NavigationBar));
    expect(navBar.selectedIndex, index);
    expect(navBar.elevation, 0);
    expect(navBar.backgroundColor, Theme.of(tester.element(find.byType(AppShell))).colorScheme.surfaceContainerLow);
  });
  }

  testWidgets('NavigationBar uses surfaceContainerLow background and zero elevation in both themes', (tester) async {
    for (final theme in [AppTheme.lightTheme, AppTheme.darkTheme]) {
      await tester.pumpWidget(ProviderScope(
        overrides: [authControllerProvider.overrideWith(() => ShellAuthController())],
        child: MaterialApp(
          theme: theme,
          home: Theme(
            data: theme,
            child: const AppShell(location: '/dashboard', child: Text('Content')),
          ),
        ),
      ));
      final navBar = tester.widget<NavigationBar>(find.byType(NavigationBar));
      expect(navBar.backgroundColor, theme.colorScheme.surfaceContainerLow);
      expect(navBar.elevation, 0);
    }
  });
}
