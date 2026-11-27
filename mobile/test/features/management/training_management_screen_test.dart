import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';
import 'package:training_app/core/errors/api_error.dart';
import 'package:training_app/core/router/app_router.dart';
import 'package:training_app/core/theme/app_theme.dart';
import 'package:training_app/features/auth/domain/models/auth_state.dart';
import 'package:training_app/features/auth/domain/models/authenticated_identity.dart';
import 'package:training_app/features/auth/presentation/controllers/auth_controller.dart';
import 'package:training_app/features/dashboard/domain/models/dashboard_data.dart';
import 'package:training_app/features/dashboard/presentation/controllers/dashboard_controller.dart';
import 'package:training_app/features/management/data/repositories/management_repository.dart';
import 'package:training_app/features/management/domain/models/management_models.dart';
import 'package:training_app/features/management/presentation/components/curriculum_components.dart';
import 'package:training_app/features/notifications/presentation/controllers/notification_controller.dart';

import 'management_fixtures.dart';

class MockManagementRepository extends Mock implements ManagementRepository {}

class ZeroUnread extends NotificationUnreadController {
  @override
  Future<int?> build() async => 0;
}

void main() {
  late MockManagementRepository repository;
  late ManagementTestAuth auth;
  late GoRouter router;

  Future<ManagementPage<AssignableTrainingVersion>> assignableVersions() =>
      repository.assignableTrainingVersions(
        page: any(named: 'page'),
        pageSize: any(named: 'pageSize'),
        search: any(named: 'search'),
        cancelToken: any(named: 'cancelToken'),
      );

  AuthenticatedIdentity account(Set<String> permissions) => managementIdentity(
    capabilities: {'management_workspace', ...permissions},
  );

  setUp(() {
    repository = MockManagementRepository();
    when(() => repository.dashboard(cancelToken: any(named: 'cancelToken')))
        .thenAnswer((_) async => dashboardFixture(team: false));
    when(assignableVersions).thenAnswer((_) async => assignableVersionPage());
    when(
      () => repository.questions(
        page: any(named: 'page'),
        pageSize: any(named: 'pageSize'),
        search: any(named: 'search'),
        isActive: any(named: 'isActive'),
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenAnswer(
      (_) async => ManagementPage(items: [], count: 0, hasMore: false),
    );
    when(
      () => repository.roleRequirements(
        page: any(named: 'page'),
        pageSize: any(named: 'pageSize'),
        search: any(named: 'search'),
        jobRoleId: any(named: 'jobRoleId'),
        trainingVersionId: any(named: 'trainingVersionId'),
        isActive: any(named: 'isActive'),
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenAnswer(
      (_) async => ManagementPage(items: [], count: 0, hasMore: false),
    );
    when(
      () => repository.trainings(
        page: any(named: 'page'),
        pageSize: any(named: 'pageSize'),
        search: any(named: 'search'),
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenAnswer((_) async => managedTrainingPage());
    when(
      () => repository.allTrainingVersions(
        page: any(named: 'page'),
        pageSize: any(named: 'pageSize'),
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenAnswer((_) async => managedTrainingVersionPage());
  });

  Future<ProviderContainer> launch(
    WidgetTester tester, {
    AuthenticatedIdentity? identity,
    String path = '/workspace',
    ThemeMode themeMode = ThemeMode.light,
    Size size = const Size(800, 2400),
    double textScale = 1.0,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    auth = ManagementTestAuth(
      identity ??
          managementIdentity(
            capabilities: {
              'management_workspace',
              'training.view_training',
              'training.add_training',
              'training.view_trainingversion',
              'training.add_trainingversion',
              'training.add_trainingassignment',
            },
          ),
    );
    final container = ProviderContainer(
      overrides: [
        authControllerProvider.overrideWith(() => auth),
        managementRepositoryProvider.overrideWithValue(repository),
        dashboardDataProvider.overrideWith(
          (_) async => DashboardData(
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
          ),
        ),
        notificationUnreadCountProvider.overrideWith(ZeroUnread.new),
      ],
    );
    addTearDown(container.dispose);
    router = container.read(appRouterProvider)..go(path);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(
          routerConfig: router,
          theme: AppTheme.lightTheme,
          darkTheme: AppTheme.darkTheme,
          themeMode: themeMode,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              disableAnimations: true,
              textScaler: TextScaler.linear(textScale),
            ),
            child: child!,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return container;
  }

  const home = '/workspace/training';
  const allTools = {
    'training.view_training',
    'training.add_training',
    'training.change_training',
    'training.view_trainingversion',
    'training.add_trainingversion',
    'training.change_trainingversion',
    'training.add_trainingassignment',
    'training.add_module',
    'training.add_lesson',
    'assessments.view_question',
    'training.view_roletrainingrequirement',
  };

  Future<void> tapText(WidgetTester tester, String label) async {
    final target = find.text(label);
    await tester.ensureVisible(target);
    await tester.tap(target);
    await tester.pumpAndSettle();
  }

  testWidgets(
    'workspace opens a compact hub without developer-facing content',
    (tester) async {
      await launch(tester, identity: account(allTools));
      await tapText(tester, 'Training management');

      expect(router.state.matchedLocation, home);
      expect(find.byType(TrainingNavigationCard), findsNWidgets(4));
      for (final label in [
        'Course catalog',
        'Training versions',
        'Question bank',
        'Role requirements',
      ]) {
        expect(find.text(label), findsOneWidget);
      }
      for (final obsolete in [
        'Authoring capabilities',
        'Authoring operations',
        'Version lifecycle',
        'Published assignable versions',
        'Create course',
        'Edit course',
        'Upload video',
      ]) {
        expect(find.text(obsolete), findsNothing);
      }
      expect(find.textContaining('Stage 2'), findsNothing);
      expect(find.byType(ActionChip), findsNothing);
      verifyNever(assignableVersions);
    },
  );

  for (final entry in {
    'Course catalog': '$home/catalog',
    'Training versions': '$home/versions',
    'Question bank': '$home/questions',
    'Role requirements': '$home/role-requirements',
  }.entries) {
    testWidgets('${entry.key} opens the existing destination', (tester) async {
      await launch(tester, path: home, identity: account(allTools));

      await tapText(tester, entry.key);

      expect(router.state.matchedLocation, entry.value);
      if (entry.key == 'Course catalog') {
        expect(find.byTooltip('New course'), findsOneWidget);
      }
    });
  }

  testWidgets(
    'course creators without browse access retain the creation path',
    (tester) async {
      await launch(
        tester,
        path: home,
        identity: account({'training.add_training'}),
      );

      expect(find.text('Course catalog'), findsNothing);
      await tapText(tester, 'Create course');

      expect(router.state.matchedLocation, '$home/catalog/new');
      expect(find.text('New training course'), findsOneWidget);
    },
  );

  testWidgets('version readers without catalog access can browse versions', (
    tester,
  ) async {
    await launch(
      tester,
      path: home,
      identity: account({'training.view_trainingversion'}),
    );

    expect(find.text('Course catalog'), findsNothing);
    await tapText(tester, 'Training versions');
    expect(router.state.matchedLocation, '$home/versions');
    expect(find.byTooltip('Assignable versions'), findsNothing);
    verifyNever(assignableVersions);
  });

  testWidgets('a catalog reader sees one shortcut and no authoring grants', (
    tester,
  ) async {
    await launch(
      tester,
      path: home,
      identity: account({'training.view_training'}),
    );

    expect(find.text('Course catalog'), findsOneWidget);
    expect(find.byType(TrainingNavigationCard), findsOneWidget);
    for (final path in [
      '$home/catalog/new',
      '$home/versions',
      '$home/questions',
      '$home/role-requirements',
    ]) {
      router.go(path);
      await tester.pumpAndSettle();
      expect(router.state.matchedLocation, '/workspace');
    }
    verifyNever(assignableVersions);
  });

  testWidgets('a learner without management access cannot open the hub', (
    tester,
  ) async {
    await launch(
      tester,
      path: home,
      identity: managementIdentity(
        team: true,
        capabilities: {'personal_learning'},
      ),
    );

    expect(router.state.matchedLocation, '/dashboard');
    expect(find.byType(TrainingNavigationCard), findsNothing);
    verifyNever(assignableVersions);
  });

  testWidgets('team reporting alone does not expose training authoring', (
    tester,
  ) async {
    await launch(
      tester,
      identity: managementIdentity(
        team: true,
        capabilities: {'team_workspace', 'assignment_report'},
      ),
    );
    expect(find.text('Training management'), findsNothing);

    router.go(home);
    await tester.pumpAndSettle();
    expect(router.state.matchedLocation, '/workspace');
    verifyNever(assignableVersions);
  });

  testWidgets(
    'granular module or lesson grants do not expose unrelated tools',
    (tester) async {
      await launch(
        tester,
        path: home,
        identity: account({'training.add_module', 'training.change_lesson'}),
      );
      expect(find.byType(TrainingNavigationCard), findsNothing);
      expect(
        find.text('No training tools are available for this account.'),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'assignment-ready versions load only on request from the directory',
    (tester) async {
      await launch(tester, path: home, identity: account(allTools));

      expect(find.text('Assignable versions'), findsNothing);
      await tapText(tester, 'Training versions');
      verifyNever(assignableVersions);

      await tester.tap(find.byTooltip('Assignable versions'));
      await tester.pumpAndSettle();

      expect(find.text('Workplace safety v1'), findsOneWidget);
      verify(assignableVersions).called(1);
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      expect(router.state.matchedLocation, '$home/versions');
      expect(find.text('Workplace safety v1'), findsNothing);
    },
  );

  testWidgets(
    'assignment grant keeps a fallback for users without version access',
    (tester) async {
      await launch(
        tester,
        path: home,
        identity: account({
          'training.view_training',
          'training.add_trainingassignment',
        }),
      );

      expect(find.text('Training versions'), findsNothing);
      verifyNever(assignableVersions);
      await tapText(tester, 'Assignable versions');

      expect(find.text('Workplace safety v1'), findsOneWidget);
      expect(find.textContaining('Version 1'), findsOneWidget);
      verify(assignableVersions).called(1);
    },
  );

  testWidgets('assignable version failures can be retried to an empty list', (
    tester,
  ) async {
    var requests = 0;
    when(assignableVersions).thenAnswer((_) async {
      requests++;
      if (requests == 1) {
        throw ApiError(
          message: 'Failed to load assignable versions',
          statusCode: 503,
        );
      }
      return ManagementPage(items: [], count: 0, hasMore: false);
    });
    await launch(
      tester,
      path: home,
      identity: account({
        'training.view_training',
        'training.add_trainingassignment',
      }),
    );

    await tapText(tester, 'Assignable versions');
    expect(find.text('Failed to load assignable versions'), findsOneWidget);
    await tapText(tester, 'Retry');
    expect(
      find.text('No published training versions currently available.'),
      findsOneWidget,
    );
    expect(requests, 2);
  });

  testWidgets('an account change clears an open assignment-ready list', (
    tester,
  ) async {
    await launch(
      tester,
      path: home,
      identity: account({
        'training.view_training',
        'training.add_trainingassignment',
      }),
    );
    await tapText(tester, 'Assignable versions');
    expect(find.text('Workplace safety v1'), findsOneWidget);

    auth.setAuth(
      AuthAuthenticated.identity(
        managementIdentity(
          username: 'another-user',
          capabilities: {'management_workspace', 'training.view_training'},
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Workplace safety v1'), findsNothing);
    verify(assignableVersions).called(1);
  });

  for (final theme in [ThemeMode.light, ThemeMode.dark]) {
    testWidgets('${theme.name} layout fits narrow screens at 200% text', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      try {
        await launch(
          tester,
          path: home,
          identity: account(allTools),
          size: const Size(320, 520),
          textScale: 2,
          themeMode: theme,
        );

        final card = find.byType(TrainingNavigationCard).first;
        expect(tester.getSize(card).height, greaterThanOrEqualTo(48));
        expect(
          Theme.of(tester.element(card)).brightness,
          theme == ThemeMode.dark ? Brightness.dark : Brightness.light,
        );
        expect(find.bySemanticsLabel(RegExp('Course catalog')), findsOneWidget);
        await tester.scrollUntilVisible(find.text('Role requirements'), 150);
        expect(tester.takeException(), isNull);
        expect(find.text('Role requirements').hitTestable(), findsOneWidget);
      } finally {
        semantics.dispose();
      }
    });
  }
}
