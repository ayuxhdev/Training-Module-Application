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
    expect(tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex, index);
  });
  }
}
