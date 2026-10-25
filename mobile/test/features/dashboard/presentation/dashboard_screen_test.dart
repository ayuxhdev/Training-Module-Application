import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:training_app/core/presentation/components/loading_view.dart';
import 'package:training_app/features/auth/domain/models/auth_state.dart';
import 'package:training_app/features/auth/domain/models/employee.dart';
import 'package:training_app/features/auth/presentation/controllers/auth_controller.dart';
import 'package:training_app/features/dashboard/domain/models/dashboard_data.dart';
import 'package:training_app/features/dashboard/presentation/controllers/dashboard_controller.dart';
import 'package:training_app/features/dashboard/presentation/screens/dashboard_screen.dart';
import 'package:training_app/features/notifications/presentation/controllers/notification_controller.dart';

import '../../notifications/notification_fixtures.dart';

void main() {
  testWidgets('DashboardScreen shows loading initially', (tester) async {
    final completer = Completer<DashboardData>();
    
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          notificationUnreadCountProvider.overrideWith(ZeroUnreadController.new),
          authControllerProvider.overrideWith(() => AuthControllerMock()),
          dashboardDataProvider.overrideWith((ref) => completer.future),
        ],
        child: const MaterialApp(
          home: DashboardScreen(),
        ),
      ),
    );

    expect(find.byType(LoadingView), findsOneWidget);
    
    // complete the future to avoid pending timers
    completer.complete(DashboardData(
      metrics: DashboardMetrics(
        total: 0, assigned: 0, inProgress: 0, completed: 0, cancelled: 0, overdue: 0, completionPercent: 0, certificatesCount: 0,
      ),
      actionRequired: [],
      recentCertificates: [],
    ));
    await tester.pumpAndSettle();
  });

  testWidgets('DashboardScreen displays metrics when loaded', (tester) async {
    final mockData = DashboardData(
      metrics: DashboardMetrics(
        total: 10,
        assigned: 4,
        inProgress: 2,
        completed: 4,
        cancelled: 0,
        overdue: 1,
        completionPercent: 40.0,
        certificatesCount: 3,
      ),
      actionRequired: [],
      recentCertificates: [],
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          notificationUnreadCountProvider.overrideWith(ZeroUnreadController.new),
          authControllerProvider.overrideWith(() => AuthControllerMock()),
          dashboardDataProvider.overrideWith((ref) => mockData),
        ],
        child: const MaterialApp(
          home: DashboardScreen(),
        ),
      ),
    );

    await tester.pumpAndSettle();

    expect(find.text('Overview'), findsOneWidget);
    expect(find.text('4'), findsNWidgets(2)); // assigned, completed
    expect(find.text('2'), findsOneWidget); // in progress
  });

  testWidgets('DashboardScreen displays recent certificates when present', (tester) async {
    final mockData = DashboardData(
      metrics: DashboardMetrics(
        total: 1,
        assigned: 0,
        inProgress: 0,
        completed: 1,
        cancelled: 0,
        overdue: 0,
        completionPercent: 100.0,
        certificatesCount: 1,
      ),
      actionRequired: [],
      recentCertificates: [
        DashboardCertificate(
          id: 42,
          certificateNumber: 'CERT-2026-001',
          trainingTitle: 'Safety in Operations',
          versionNumber: 1,
          issuedAt: DateTime(2026, 10, 20),
        ),
      ],
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          notificationUnreadCountProvider.overrideWith(ZeroUnreadController.new),
          authControllerProvider.overrideWith(() => AuthControllerMock()),
          dashboardDataProvider.overrideWith((ref) => mockData),
        ],
        child: const MaterialApp(
          home: DashboardScreen(),
        ),
      ),
    );

    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Recent Certificates'), 200, scrollable: find.byType(Scrollable).first);

    expect(find.text('Recent Certificates'), findsOneWidget);
    expect(find.text('Safety in Operations'), findsOneWidget);
    expect(find.text('Cert #: CERT-2026-001'), findsOneWidget);
    expect(find.byIcon(Icons.workspace_premium), findsOneWidget);
    expect(find.byIcon(Icons.chevron_right_rounded), findsOneWidget);
  });

  testWidgets('DashboardScreen displays zero metrics cleanly', (tester) async {
    final mockData = DashboardData(
      metrics: DashboardMetrics(
        total: 0,
        assigned: 0,
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

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          notificationUnreadCountProvider.overrideWith(ZeroUnreadController.new),
          authControllerProvider.overrideWith(() => AuthControllerMock()),
          dashboardDataProvider.overrideWith((ref) => mockData),
        ],
        child: const MaterialApp(
          home: DashboardScreen(),
        ),
      ),
    );

    await tester.pumpAndSettle();
    expect(find.text('Overview'), findsOneWidget);

    await tester.scrollUntilVisible(find.text('No certificates earned yet.'), 200, scrollable: find.byType(Scrollable).first);
    expect(find.text('No certificates earned yet.'), findsOneWidget);
  });

  testWidgets('DashboardScreen shows error view on failure', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          notificationUnreadCountProvider.overrideWith(ZeroUnreadController.new),
          authControllerProvider.overrideWith(() => AuthControllerMock()),
          dashboardDataProvider.overrideWith((ref) => Future.error(Exception('Failed to load'))),
        ],
        child: const MaterialApp(
          home: DashboardScreen(),
        ),
      ),
    );

    await tester.pumpAndSettle();

    expect(find.text('Unable to load this page'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
  });
}

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
