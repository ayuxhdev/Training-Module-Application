import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';
import 'package:training_app/core/router/app_router.dart';
import 'package:training_app/core/theme/app_theme.dart';
import 'package:training_app/core/presentation/screens/workspace_screen.dart';
import 'package:training_app/features/auth/domain/models/auth_state.dart';
import 'package:training_app/features/auth/domain/models/authenticated_identity.dart';
import 'package:training_app/features/auth/domain/models/employee.dart';
import 'package:training_app/features/auth/presentation/controllers/auth_controller.dart';
import 'package:training_app/features/dashboard/data/repositories/dashboard_repository.dart';
import 'package:training_app/features/dashboard/domain/models/dashboard_data.dart';
import 'package:training_app/features/dashboard/presentation/controllers/dashboard_controller.dart';
import 'package:training_app/features/learning/data/repositories/learning_repository.dart';
import 'package:training_app/features/learning/presentation/controllers/learning_controller.dart';
import 'package:training_app/features/notifications/data/repositories/notification_repository.dart';
import 'package:training_app/features/notifications/presentation/controllers/notification_controller.dart';
import 'package:training_app/features/certificates/data/repositories/certificate_repository.dart';
import 'package:training_app/features/certificates/presentation/controllers/certificate_controller.dart';
import 'package:training_app/features/assessments/data/repositories/assessment_repository.dart';
import 'package:training_app/features/assessments/presentation/controllers/assessment_controller.dart';

class RoleAuth extends AuthController {
  final AuthState initial;
  RoleAuth(this.initial);
  @override
  AuthState build() => initial;
  void setAuth(AuthState auth) => state = auth;
}

class DashboardMock extends Mock implements DashboardRepository {}

class LearningMock extends Mock implements LearningRepository {}

class NotificationMock extends Mock implements NotificationRepository {}

class CertificateMock extends Mock implements CertificateRepository {}

class AssessmentMock extends Mock implements AssessmentRepository {}

final learner = Employee(
  username: 'learner',
  employeeCode: 'QA',
  displayName: 'Learner',
  department: 'QA',
  jobRole: 'Employment role',
  isActive: true,
);
final management = AuthenticatedIdentity(
  userId: 4,
  username: 'management',
  displayName: 'Management QA',
  capabilities: {'management_workspace'},
);

DashboardData emptyDashboard() => DashboardData(
  metrics: DashboardMetrics(
    total: 0,
    assigned: 0,
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
  setUpAll(() => registerFallbackValue(CancelToken()));

  Future<(RoleAuth, GoRouter)> app(
    WidgetTester tester,
    AuthenticatedIdentity identity, {
    ThemeData? theme,
    double textScale = 1,
  }) async {
    final auth = RoleAuth(AuthAuthenticated.identity(identity));
    final container = ProviderContainer(
      overrides: [
        authControllerProvider.overrideWith(() => auth),
        dashboardDataProvider.overrideWith((_) async => emptyDashboard()),
        notificationUnreadCountProvider.overrideWith(() => ZeroUnread()),
      ],
    );
    addTearDown(container.dispose);
    final router = container.read(appRouterProvider);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(
          theme: theme,
          routerConfig: router,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: TextScaler.linear(textScale),
              disableAnimations: true,
            ),
            child: child!,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return (auth, router);
  }

  testWidgets(
    'management-only startup and deep links never build learner destinations',
    (tester) async {
      final (_, router) = await app(tester, management);
      expect(find.byType(WorkspaceScreen), findsOneWidget);
      expect(find.text('Management'), findsOneWidget);
      expect(find.text('Learning'), findsNothing);
      expect(find.text('Dashboard'), findsNothing);
      for (final path in [
        '/dashboard',
        '/learning',
        '/learning/assignments/96',
        '/notifications',
        '/profile/certificates',
        '/profile/certificates/36',
        '/learning/assignments/96/assessments',
        '/learning/assignments/96/modules/4/lessons/8/video',
      ]) {
        router.go(path);
        await tester.pumpAndSettle();
        expect(
          router.routerDelegate.currentConfiguration.uri.path,
          '/workspace',
          reason: path,
        );
        expect(find.byType(WorkspaceScreen), findsOneWidget);
        expect(tester.takeException(), isNull);
      }
    },
  );

  testWidgets(
    'management Profile has account data, appearance and no employee-only actions',
    (tester) async {
      final (_, router) = await app(tester, management);
      router.go('/profile');
      await tester.pumpAndSettle();
      expect(find.text('Management QA'), findsOneWidget);
      expect(find.text('management'), findsOneWidget);
      expect(find.text('Employee Code'), findsNothing);
      expect(find.text('My Certificates'), findsNothing);
      expect(find.byTooltip('Appearance'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('Logout'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('Logout'), findsOneWidget);
    },
  );

  testWidgets(
    'Employee cannot open workspace and keeps exactly three destinations',
    (tester) async {
      final (_, router) = await app(
        tester,
        AuthenticatedIdentity.fromEmployee(learner),
      );
      router.go('/workspace');
      await tester.pumpAndSettle();
      expect(router.routerDelegate.currentConfiguration.uri.path, '/dashboard');
      final nav = tester.widget<NavigationBar>(find.byType(NavigationBar));
      expect(nav.destinations.length, 3);
      expect(find.text('Management'), findsNothing);
      expect(find.text('Team'), findsNothing);
    },
  );

  testWidgets(
    'Manager gets Team alongside personal navigation without management actions',
    (tester) async {
      final (_, router) = await app(
        tester,
        AuthenticatedIdentity(
          username: 'learner',
          displayName: 'Manager',
          employee: learner,
          capabilities: {'personal_learning', 'team_workspace'},
        ),
      );
      await tester.tap(find.text('Team'));
      await tester.pumpAndSettle();
      expect(router.routerDelegate.currentConfiguration.uri.path, '/workspace');
      expect(find.text('Team access'), findsOneWidget);
      expect(find.text('Management access'), findsNothing);
      expect(find.text('Create assignment'), findsNothing);
    },
  );

  testWidgets(
    'combined capabilities render both summaries and loss removes workspace',
    (tester) async {
      final (auth, router) = await app(
        tester,
        AuthenticatedIdentity(
          username: 'learner',
          displayName: 'Combined',
          employee: learner,
          capabilities: {
            'personal_learning',
            'team_workspace',
            'management_workspace',
          },
        ),
      );
      router.go('/workspace');
      await tester.pumpAndSettle();
      expect(find.text('Management access'), findsOneWidget);
      expect(find.text('Team access'), findsOneWidget);
      auth.setAuth(AuthAuthenticated(learner));
      await tester.pumpAndSettle();
      expect(router.routerDelegate.currentConfiguration.uri.path, '/dashboard');
      expect(find.text('Management access'), findsNothing);
      expect(find.text('Team access'), findsNothing);
      auth.setAuth(AuthUnauthenticated());
      await tester.pumpAndSettle();
      expect(router.routerDelegate.currentConfiguration.uri.path, '/login');
      expect(find.text('Combined'), findsNothing);
      expect(find.text('Username'), findsOneWidget);
    },
  );

  for (final brightness in Brightness.values) {
    testWidgets('$brightness workspace supports narrow layout and large text', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await app(
        tester,
        management,
        theme: brightness == Brightness.dark
            ? AppTheme.darkTheme
            : AppTheme.lightTheme,
        textScale: 2,
      );
      expect(find.byType(WorkspaceScreen), findsOneWidget);
      expect(
        Theme.of(tester.element(find.byType(WorkspaceScreen))).brightness,
        brightness,
      );
      await tester.drag(find.byType(ListView), const Offset(0, -400));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }

  test('management-only identity blocks personal providers before repository calls', () async {
    final dashboard = DashboardMock();
    final learning = LearningMock();
    final notifications = NotificationMock();
    final certificates = CertificateMock();
    final assessments = AssessmentMock();
    final container = ProviderContainer(
      overrides: [
        authControllerProvider.overrideWith(
          () => RoleAuth(AuthAuthenticated.identity(management)),
        ),
        dashboardRepositoryProvider.overrideWithValue(dashboard),
        learningRepositoryProvider.overrideWithValue(learning),
        notificationRepositoryProvider.overrideWithValue(notifications),
        certificateRepositoryProvider.overrideWithValue(certificates),
        assessmentRepositoryProvider.overrideWithValue(assessments),
      ],
    );
    addTearDown(container.dispose);
    for (final future in [
      container.read(dashboardDataProvider.future),
      container.read(assignmentListProvider.future),
      container.read(assignmentDetailProvider(96).future),
      container.read(notificationUnreadCountProvider.future),
      container.read(notificationListProvider.future),
      container.read(certificateListProvider.future),
      container.read(assessmentOverviewProvider(96).future),
    ]) {
      await expectLater(future, throwsA(isA<Exception>()));
    }
    for (final mock in [
      dashboard,
      learning,
      notifications,
      certificates,
      assessments,
    ]) {
      verifyZeroInteractions(mock);
    }
  });

  test('switching to management cancels pending personal data and ignores its stale response', () async {
    final repository = DashboardMock();
    final response = Completer<DashboardData>();
    late CancelToken request;
    when(
      () => repository.getDashboardData(cancelToken: any(named: 'cancelToken')),
    ).thenAnswer((call) {
      request = call.namedArguments[#cancelToken] as CancelToken;
      return response.future;
    });
    final auth = RoleAuth(AuthAuthenticated(learner));
    final container = ProviderContainer(
      overrides: [
        authControllerProvider.overrideWith(() => auth),
        dashboardRepositoryProvider.overrideWithValue(repository),
      ],
    );
    addTearDown(container.dispose);
    final sub = container.listen(dashboardDataProvider, (_, _) {});
    addTearDown(sub.close);
    await Future<void>.delayed(Duration.zero);
    auth.setAuth(AuthAuthenticated.identity(management));
    await expectLater(
      container.read(dashboardDataProvider.future),
      throwsA(isA<Exception>()),
    );
    expect(request.isCancelled, isTrue);
    response.complete(emptyDashboard());
    await Future<void>.delayed(Duration.zero);
    expect(container.read(dashboardDataProvider).hasValue, isFalse);
    verify(
      () => repository.getDashboardData(cancelToken: any(named: 'cancelToken')),
    ).called(1);
  });
}

class ZeroUnread extends NotificationUnreadController {
  @override
  Future<int?> build() async => 0;
}
