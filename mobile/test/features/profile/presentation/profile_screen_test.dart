import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:training_app/core/presentation/components/custom_card.dart';
import 'package:training_app/core/errors/api_error.dart';
import 'package:training_app/core/presentation/components/secondary_button.dart';
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
    await tester.ensureVisible(find.text('Logout'));
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
    expect(find.byType(CustomCard), findsOneWidget);
    expect(find.byType(SecondaryButton), findsOneWidget);
  });
}
