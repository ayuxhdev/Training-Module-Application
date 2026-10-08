
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
import 'package:training_app/features/dashboard/domain/models/dashboard_data.dart';
import 'package:training_app/features/dashboard/presentation/controllers/dashboard_controller.dart';
import 'package:training_app/features/dashboard/presentation/screens/dashboard_screen.dart';
import 'package:training_app/features/learning/domain/models/assignment.dart';
import 'package:training_app/features/learning/domain/models/assignment_detail.dart';
import 'package:training_app/features/learning/presentation/controllers/learning_controller.dart';
import 'package:training_app/features/learning/presentation/screens/learning_screen.dart';
import 'package:training_app/features/learning/presentation/screens/assignment_detail_screen.dart';
import 'package:training_app/features/learning/presentation/screens/module_list_screen.dart';
import 'package:training_app/features/learning/presentation/screens/lesson_list_screen.dart';
import 'package:training_app/features/learning/presentation/screens/text_lesson_screen.dart';
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

  final mockDashboardData = DashboardData(
    metrics: DashboardMetrics(total: 0, assigned: 0, inProgress: 0, completed: 0, cancelled: 0, overdue: 0, completionPercent: 0.0, certificatesCount: 0),
    actionRequired: [],
    recentCertificates: [],
  );

  Widget createTestApp(AuthState authState) {
    return ProviderScope(
      overrides: [
        authControllerProvider.overrideWith(() => MockAuthController(authState)),
        dashboardDataProvider.overrideWith((ref) => Future.value(mockDashboardData)),
        assignmentListProvider.overrideWith((ref) => Future.value([])),
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

  testWidgets('Navigates to detail screen from learning screen', (tester) async {
    final mockAssignments = [
      Assignment(
        id: 42,
        trainingId: 101,
        trainingTitle: 'Test Assignment',
        versionNumber: 1,
        status: 'ASSIGNED',
        isOverdue: false,
        progressSummary: ProgressSummary(requiredLessonsCompleted: 0, requiredLessonsTotal: 1),
      )
    ];

    final mockDetail = AssignmentDetail(
      id: 42,
      trainingId: 101,
      trainingTitle: 'Test Assignment Detail',
      versionNumber: 1,
      status: 'ASSIGNED',
      isOverdue: false,
      modules: [],
    );

    final app = ProviderScope(
      overrides: [
        authControllerProvider.overrideWith(() => MockAuthController(AuthAuthenticated(tEmployee))),
        dashboardDataProvider.overrideWith((ref) => Future.value(mockDashboardData)),
        assignmentListProvider.overrideWith((ref) => Future.value(mockAssignments)),
        assignmentDetailProvider(42).overrideWith((ref) => Future.value(mockDetail)),
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

    await tester.pumpWidget(app);
    await tester.pumpAndSettle();

    // Navigate to learning tab
    await tester.tap(find.text('Learning'));
    await tester.pumpAndSettle();
    expect(find.byType(LearningScreen), findsOneWidget);
    
    // Tap the assignment card
    expect(find.text('Test Assignment'), findsOneWidget);
    await tester.tap(find.text('Test Assignment'));
    await tester.pumpAndSettle();

    // Verify detail screen is shown
    expect(find.byType(AssignmentDetailScreen), findsOneWidget);
    expect(find.text('Test Assignment Detail'), findsOneWidget);
  });

  testWidgets('Shows ErrorView for non-integer assignment ID', (tester) async {
    final app = ProviderScope(
      overrides: [
        authControllerProvider.overrideWith(() => MockAuthController(AuthAuthenticated(tEmployee))),
        dashboardDataProvider.overrideWith((ref) => Future.value(mockDashboardData)),
        assignmentListProvider.overrideWith((ref) => Future.value([])),
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

    await tester.pumpWidget(app);
    await tester.pumpAndSettle();

    // Navigate to learning tab
    await tester.tap(find.text('Learning'));
    await tester.pumpAndSettle();

    // Push malformed route
    final BuildContext context = tester.element(find.byType(LearningScreen));
    context.go('/learning/assignments/abc');
    await tester.pumpAndSettle();

    expect(find.text('Invalid assignment ID'), findsOneWidget);
  });

  testWidgets('Navigates through learning flow from detail to text lesson screen', (tester) async {
    final mockAssignments = [
      Assignment(
        id: 42,
        trainingId: 101,
        trainingTitle: 'Flow Assignment',
        versionNumber: 1,
        status: 'ASSIGNED',
        isOverdue: false,
        progressSummary: ProgressSummary(requiredLessonsCompleted: 0, requiredLessonsTotal: 1),
      )
    ];

    final mockDetail = AssignmentDetail(
      id: 42,
      trainingId: 101,
      trainingTitle: 'Flow Assignment Detail',
      versionNumber: 1,
      status: 'ASSIGNED',
      isOverdue: false,
      modules: [
        ModuleLearning(
          id: 50,
          title: 'Flow Module',
          description: 'Desc',
          position: 1,
          lessons: [
            LessonLearning(
              id: 60,
              title: 'Flow Text Lesson',
              position: 1,
              type: 'TEXT',
              isRequired: true,
              body: 'Flow Body',
              progress: LessonProgress(resumePosition: 0, watchedSeconds: 0, progressPercent: 0, completed: false),
            )
          ]
        )
      ],
    );

    final app = ProviderScope(
      overrides: [
        authControllerProvider.overrideWith(() => MockAuthController(AuthAuthenticated(tEmployee))),
        dashboardDataProvider.overrideWith((ref) => Future.value(mockDashboardData)),
        assignmentListProvider.overrideWith((ref) => Future.value(mockAssignments)),
        assignmentDetailProvider(42).overrideWith((ref) => Future.value(mockDetail)),
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

    await tester.pumpWidget(app);
    await tester.pumpAndSettle();

    // Navigate to learning tab
    await tester.tap(find.text('Learning'));
    await tester.pumpAndSettle();
    
    // Tap assignment
    await tester.tap(find.text('Flow Assignment'));
    await tester.pumpAndSettle();

    // Verify detail and tap Start Training
    expect(find.byType(AssignmentDetailScreen), findsOneWidget);
    await tester.tap(find.text('Start Training'));
    await tester.pumpAndSettle();

    // Verify module list and tap module
    expect(find.byType(ModuleListScreen), findsOneWidget);
    expect(find.text('1. Flow Module'), findsOneWidget);
    await tester.tap(find.text('1. Flow Module'));
    await tester.pumpAndSettle();

    // Verify lesson list and tap lesson
    expect(find.byType(LessonListScreen), findsOneWidget);
    expect(find.text('1. Flow Text Lesson'), findsOneWidget);
    await tester.tap(find.text('1. Flow Text Lesson'));
    await tester.pumpAndSettle();

    // Verify text lesson screen is shown
    expect(find.byType(TextLessonScreen), findsOneWidget);
    expect(find.text('Flow Body'), findsOneWidget);
  });
}

