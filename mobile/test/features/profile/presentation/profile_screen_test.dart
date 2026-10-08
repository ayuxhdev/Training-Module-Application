import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:training_app/core/presentation/components/custom_card.dart';
import 'package:training_app/core/presentation/components/secondary_button.dart';
import 'package:training_app/features/auth/domain/models/auth_state.dart';
import 'package:training_app/features/auth/domain/models/employee.dart';
import 'package:training_app/features/auth/presentation/controllers/auth_controller.dart';
import 'package:training_app/features/profile/presentation/screens/profile_screen.dart';

class AuthControllerMock extends AuthController {
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

void main() {
  testWidgets('ProfileScreen displays authenticated employee data', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          authControllerProvider.overrideWith(() => AuthControllerMock()),
        ],
        child: const MaterialApp(
          home: ProfileScreen(),
        ),
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
    expect(find.byType(CustomCard), findsOneWidget);
    expect(find.byType(SecondaryButton), findsOneWidget);
  });
}
