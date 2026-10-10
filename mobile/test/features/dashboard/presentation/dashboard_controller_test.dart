import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:training_app/features/auth/domain/models/auth_state.dart';
import 'package:training_app/features/auth/domain/models/employee.dart';
import 'package:training_app/features/auth/presentation/controllers/auth_controller.dart';
import 'package:training_app/features/dashboard/data/repositories/dashboard_repository.dart';
import 'package:training_app/features/dashboard/domain/models/dashboard_data.dart';
import 'package:training_app/features/dashboard/presentation/controllers/dashboard_controller.dart';

class MockDashboardRepository extends Mock implements DashboardRepository {}

class TestAuthController extends AuthController {
  @override
  AuthState build() => AuthUnauthenticated();
  void setAuth(AuthState value) => state = value;
}

Employee employee(String username) => Employee(
  username: username,
  employeeCode: username,
  displayName: username,
  department: 'QA',
  jobRole: 'Learner',
  isActive: true,
);

DashboardData dashboard(int count) => DashboardData(
  metrics: DashboardMetrics(
    total: count,
    assigned: count,
    inProgress: 0,
    completed: 0,
    cancelled: 0,
    overdue: 0,
    completionPercent: 0,
    certificatesCount: 0,
  ),
  actionRequired: [],
  recentCertificates: [],
);

void main() {
  test('account switch ignores old in-flight dashboard and logout makes no request', () async {
    final repository = MockDashboardRepository();
    final oldResponse = Completer<DashboardData>();
    final newResponse = Completer<DashboardData>();
    var calls = 0;
    when(
      () => repository.getDashboardData(),
    ).thenAnswer((_) => ++calls == 1 ? oldResponse.future : newResponse.future);
    final auth = TestAuthController();
    final container = ProviderContainer(
      overrides: [
        authControllerProvider.overrideWith(() => auth),
        dashboardRepositoryProvider.overrideWithValue(repository),
      ],
    );
    addTearDown(container.dispose);
    container.read(authControllerProvider);
    auth.setAuth(AuthAuthenticated(employee('A')));
    final subscription = container.listen(dashboardDataProvider, (_, _) {});
    addTearDown(subscription.close);
    await Future<void>.delayed(Duration.zero);
    auth.setAuth(AuthAuthenticated(employee('B')));
    await Future<void>.delayed(Duration.zero);
    oldResponse.complete(dashboard(99));
    await Future<void>.delayed(Duration.zero);
    expect(container.read(dashboardDataProvider).isLoading, isTrue);
    newResponse.complete(dashboard(2));
    expect(
      (await container.read(dashboardDataProvider.future)).metrics.total,
      2,
    );
    auth.setAuth(AuthUnauthenticated());
    await expectLater(
      container.read(dashboardDataProvider.future),
      throwsA(isA<Exception>()),
    );
    verify(() => repository.getDashboardData()).called(2);
  });
}
