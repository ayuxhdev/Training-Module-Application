import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:training_app/core/errors/api_error.dart';
import 'package:training_app/core/router/app_router.dart';
import 'package:training_app/features/auth/domain/models/auth_state.dart';
import 'package:training_app/features/auth/domain/models/employee.dart';
import 'package:training_app/features/auth/presentation/controllers/auth_controller.dart';
import 'package:training_app/features/auth/presentation/screens/login_screen.dart';
import 'package:training_app/features/dashboard/presentation/screens/dashboard_screen.dart';
import 'package:training_app/features/learning/presentation/screens/learning_screen.dart';
import 'package:training_app/features/profile/presentation/screens/profile_screen.dart';

class MockAuthController extends Notifier<AuthState> implements AuthController {
  final AuthState initialState;

  MockAuthController(this.initialState);

  @override
  AuthState build() => initialState;

  @override
  Future<void> login(String employeeCode, String password) async {}

  @override
  Future<void> logout() async {}

  @override
  Future<void> retryAuthentication() async {}
}

void main() {
  final tEmployee = Employee(
    username: 'EMP001',
    employeeCode: 'EMP001',
    displayName: 'Test User',
    department: 'Engineering',
    jobRole: 'Engineer',
    isActive: true,
  );

  Widget createTestApp(AuthState authState) {
    return ProviderScope(
      overrides: [
        authControllerProvider.overrideWith(() => MockAuthController(authState)),
      ],
      child: Consumer(
        builder: (context, ref, child) {
          final router = ref.watch(appRouterProvider);
          return MaterialApp.router(
            routerConfig: router,
          );
        },
      ),
    );
  }

  testWidgets('Redirects to login if unauthenticated', (tester) async {
    await tester.pumpWidget(createTestApp(AuthUnauthenticated()));
    await tester.pumpAndSettle();

    expect(find.byType(LoginScreen), findsOneWidget);
  });

  testWidgets('Redirects to dashboard if authenticated and visits root', (tester) async {
    await tester.pumpWidget(createTestApp(AuthAuthenticated(tEmployee)));
    await tester.pumpAndSettle();

    expect(find.byType(DashboardScreen), findsOneWidget);
  });

  testWidgets('Shell navigation works between tabs', (tester) async {
    await tester.pumpWidget(createTestApp(AuthAuthenticated(tEmployee)));
    await tester.pumpAndSettle();

    expect(find.byType(DashboardScreen), findsOneWidget);

    // Tap Learning tab
    await tester.tap(find.text('Learning'));
    await tester.pumpAndSettle();
    expect(find.byType(LearningScreen), findsOneWidget);

    // Tap Profile tab
    await tester.tap(find.text('Profile'));
    await tester.pumpAndSettle();
    expect(find.byType(ProfileScreen), findsOneWidget);

    // Tap Dashboard tab
    await tester.tap(find.text('Dashboard'));
    await tester.pumpAndSettle();
    expect(find.byType(DashboardScreen), findsOneWidget);
  });

  testWidgets('Preserves root route during AuthLoading', (tester) async {
    await tester.pumpWidget(createTestApp(AuthLoading()));
    await tester.pump(); // don't settle on loading indicator

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    
    // Using a builder inside to check current GoRouter location
    final BuildContext context = tester.element(find.byType(CircularProgressIndicator));
    final router = GoRouter.of(context);
    expect(router.routerDelegate.currentConfiguration.uri.toString(), '/');
  });

  testWidgets('Shows CircularProgressIndicator when AuthInitial', (tester) async {
    await tester.pumpWidget(createTestApp(AuthInitial()));
    await tester.pump(); // don't settle on loading indicator

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  testWidgets('Shows error screen when AuthError', (tester) async {
    await tester.pumpWidget(createTestApp(AuthError(ApiError(message: 'Test network error', statusCode: 500))));
    await tester.pumpAndSettle();

    expect(find.text('Test network error'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
  });
}
