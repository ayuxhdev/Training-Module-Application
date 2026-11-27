import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:training_app/core/presentation/components/error_view.dart';
import 'package:training_app/core/router/app_router.dart';
import 'package:training_app/features/auth/domain/models/auth_state.dart';
import 'package:training_app/features/auth/domain/models/employee.dart';
import 'package:training_app/features/auth/presentation/controllers/auth_controller.dart';
import 'package:training_app/features/auth/presentation/screens/login_screen.dart';
import 'package:training_app/features/dashboard/domain/models/dashboard_data.dart';
import 'package:training_app/features/dashboard/presentation/controllers/dashboard_controller.dart';
import 'package:training_app/features/dashboard/presentation/screens/dashboard_screen.dart';
import 'package:training_app/features/learning/domain/models/assignment_detail.dart';
import 'package:training_app/features/learning/presentation/controllers/learning_controller.dart';
import 'package:training_app/features/notifications/presentation/controllers/notification_controller.dart';

import '../../features/notifications/notification_fixtures.dart';

class _MockAuthController extends Notifier<AuthState> implements AuthController {
  final AuthState initialState;

  _MockAuthController(this.initialState);

  @override
  AuthState build() => initialState;

  @override
  Future<void> login(String employeeCode, String password) async {}

  @override
  Future<void> logout() async {}

  @override
  void registerLessonDraft(Object owner, String path) {}

  @override
  void unregisterLessonDraft(Object owner) {}

  @override
  bool canRecoverLessonDraft(String path, {Object? owner}) => false;

  @override
  Future<void> reauthenticate(String password) async {}

  @override
  Future<void> retryAuthentication() async {}

  @override
  Future<void> refreshProfile() async {}
}

void main() {
  final testEmployee = Employee(
    username: 'EMP001',
    employeeCode: 'EMP001',
    displayName: 'Test Operator',
    department: 'Engineering',
    jobRole: 'Technician',
    isActive: true,
  );

  final mockDashboardData = DashboardData(
    metrics: DashboardMetrics(
      total: 1,
      assigned: 1,
      inProgress: 0,
      completed: 0,
      cancelled: 0,
      overdue: 0,
      completionPercent: 0.0,
      certificatesCount: 0,
    ),
    actionRequired: [],
    recentCertificates: [],
  );

  Widget createTestApp(AuthState authState) {
    return ProviderScope(
      overrides: [
        notificationUnreadCountProvider.overrideWith(ZeroUnreadController.new),
        authControllerProvider.overrideWith(() => _MockAuthController(authState)),
        dashboardDataProvider.overrideWith((ref) => Future.value(mockDashboardData)),
        assignmentListProvider.overrideWith((ref) => Future.value([])),
        assignmentDetailProvider(1).overrideWith((_) async => AssignmentDetail(
              id: 1,
              trainingId: 10,
              trainingTitle: 'Test Course',
              versionNumber: 1,
              status: 'IN_PROGRESS',
              isOverdue: false,
              modules: [],
            )),
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

  group('M19 Core Router Release Acceptance & Navigation', () {
    testWidgets('1. Visiting unauthenticated route redirects to /login', (tester) async {
      await tester.pumpWidget(createTestApp(AuthUnauthenticated()));
      await tester.pumpAndSettle();

      expect(find.byType(LoginScreen), findsOneWidget);
    });

    testWidgets('2. Authenticated user visiting root / renders dashboard screen', (tester) async {
      await tester.pumpWidget(createTestApp(AuthAuthenticated(testEmployee)));
      await tester.pumpAndSettle();

      expect(find.byType(DashboardScreen), findsOneWidget);
    });

    testWidgets('3. Deep link with malformed non-integer assignment ID displays ErrorView without crash', (tester) async {
      await tester.pumpWidget(createTestApp(AuthAuthenticated(testEmployee)));
      await tester.pumpAndSettle();

      final BuildContext context = tester.element(find.byType(DashboardScreen));
      context.go('/learning/assignments/not-a-number');
      await tester.pumpAndSettle();

      expect(find.byType(ErrorView), findsOneWidget);
      expect(find.textContaining('Invalid assignment ID'), findsOneWidget);
    });

    testWidgets('4. Deep link to valid assignment navigates outside root shell tab bar', (tester) async {
      await tester.pumpWidget(createTestApp(AuthAuthenticated(testEmployee)));
      await tester.pumpAndSettle();

      final BuildContext context = tester.element(find.byType(DashboardScreen));
      context.go('/learning/assignments/1');
      await tester.pumpAndSettle();

      expect(find.text('Test Course'), findsOneWidget);
    });
  });
}
