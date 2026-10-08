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

void main() {
  testWidgets('DashboardScreen shows loading initially', (tester) async {
    final completer = Completer<DashboardData>();
    
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
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
