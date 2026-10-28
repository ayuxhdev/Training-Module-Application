import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';
import 'package:training_app/core/errors/api_error.dart';
import 'package:training_app/core/presentation/components/status_badge.dart';
import 'package:training_app/core/router/app_router.dart';
import 'package:training_app/core/theme/app_theme.dart';
import 'package:training_app/features/auth/domain/models/auth_state.dart';
import 'package:training_app/features/auth/domain/models/authenticated_identity.dart';
import 'package:training_app/features/auth/presentation/controllers/auth_controller.dart';
import 'package:training_app/features/dashboard/domain/models/dashboard_data.dart';
import 'package:training_app/features/dashboard/presentation/controllers/dashboard_controller.dart';
import 'package:training_app/features/management/data/repositories/management_repository.dart';
import 'package:training_app/features/management/domain/models/management_models.dart';
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

  setUpAll(() {
    registerFallbackValue(ReferenceKind.departments);
  });

  setUp(() {
    repository = MockManagementRepository();
    when(
      () => repository.dashboard(cancelToken: any(named: 'cancelToken')),
    ).thenAnswer(
      (_) async => dashboardFixture(team: false),
    );
    when(
      () => repository.assignableTrainingVersions(
        page: any(named: 'page'),
        pageSize: any(named: 'pageSize'),
        search: any(named: 'search'),
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenAnswer((_) async => assignableVersionPage());
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

  group('Training Management navigation and workspace entry', () {
    testWidgets(
      'WorkspaceScreen displays Training Management entry point for authorized coordinator',
      (tester) async {
        await launch(tester);

        expect(find.text('Training management'), findsOneWidget);
        expect(
          find.text('Course catalog, version lifecycle, and curriculum authoring.'),
          findsOneWidget,
        );

        await tester.tap(find.text('Training management'));
        await tester.pumpAndSettle();

        expect(find.text('CURRICULUM & CATALOG'), findsOneWidget);
        expect(find.text('Authoring capabilities'), findsOneWidget);
        expect(find.text('Version lifecycle'), findsOneWidget);
        expect(find.text('Authoring operations'), findsOneWidget);
      },
    );

    testWidgets(
      'WorkspaceScreen hides Training Management entry point for team-only manager',
      (tester) async {
        final teamManager = managementIdentity(
          team: true,
          capabilities: {
            'team_workspace',
            'team_assignment',
            'organization.view_employee',
          },
        );

        await launch(tester, identity: teamManager);

        expect(find.text('Training management'), findsNothing);
      },
    );

    testWidgets(
      'WorkspaceScreen hides Training Management entry point for directory-only viewer',
      (tester) async {
        final viewer = managementIdentity(
          capabilities: {'organization.view_employee'},
        );

        await launch(tester, identity: viewer);

        expect(find.text('Training management'), findsNothing);
      },
    );

    testWidgets(
      'Router blocks unauthorized access to /workspace/training',
      (tester) async {
        final viewer = managementIdentity(
          capabilities: {'organization.view_employee'},
        );

        await launch(tester, identity: viewer, path: '/workspace/training');

        // Blocked path redirects to homePath ('/profile')
        expect(find.text('CURRICULUM & CATALOG'), findsNothing);
      },
    );
  });

  group('Mixed-role capability behavior', () {
    testWidgets(
      'Mixed-role manager with training permissions sees Training Management',
      (tester) async {
        final mixedRole = managementIdentity(
          team: true,
          capabilities: {
            'team_workspace',
            'team_assignment',
            'training.view_training',
            'training.add_training',
            'organization.view_employee',
          },
        );

        await launch(tester, identity: mixedRole);

        expect(find.text('Training management'), findsOneWidget);

        await tester.tap(find.text('Training management'));
        await tester.pumpAndSettle();

        expect(find.text('CURRICULUM & CATALOG'), findsOneWidget);
        expect(find.widgetWithText(StatusBadge, 'AUTHORING PERMITTED'), findsOneWidget);
      },
    );

    testWidgets(
      'Read-only catalog viewer sees Catalog view status badge',
      (tester) async {
        final readOnly = managementIdentity(
          capabilities: {
            'management_workspace',
            'training.view_training',
          },
        );

        await launch(tester, identity: readOnly, path: '/workspace/training');

        expect(find.widgetWithText(StatusBadge, 'CATALOG VIEW'), findsOneWidget);
      },
    );

    testWidgets(
      'Training-only account without workspace capabilities accesses /workspace and Management destination',
      (tester) async {
        final trainingOnly = managementIdentity(
          capabilities: {
            'training.view_training',
          },
        );

        await launch(tester, identity: trainingOnly, path: '/workspace');

        expect(find.text('Management'), findsOneWidget);
        expect(find.text('Training management'), findsOneWidget);

        await tester.tap(find.text('Training management'));
        await tester.pumpAndSettle();

        expect(find.text('CURRICULUM & CATALOG'), findsOneWidget);
        expect(find.text('View only'), findsOneWidget);
        expect(find.text('No version access'), findsOneWidget);
        expect(find.text('Assignment restricted'), findsOneWidget);
        expect(find.text('Assignable versions list requires training assignment authority.'), findsOneWidget);

        verifyNever(
          () => repository.assignableTrainingVersions(
            page: any(named: 'page'),
            pageSize: any(named: 'pageSize'),
            search: any(named: 'search'),
            cancelToken: any(named: 'cancelToken'),
          ),
        );
      },
    );

    testWidgets(
      'Version-only account without course permissions accesses Training Management with accurate grants',
      (tester) async {
        final versionOnly = managementIdentity(
          capabilities: {
            'training.view_trainingversion',
          },
        );

        await launch(tester, identity: versionOnly, path: '/workspace/training');

        expect(find.text('CURRICULUM & CATALOG'), findsOneWidget);
        expect(find.widgetWithText(StatusBadge, 'CATALOG VIEW'), findsOneWidget);
        expect(find.text('No catalog access'), findsOneWidget);
        expect(find.text('View versions only'), findsOneWidget);
        expect(find.text('Assignment restricted'), findsOneWidget);
        expect(
          find.text('Your account has view-only curriculum access. Authoring and mutation controls remain restricted.'),
          findsOneWidget,
        );
        expect(find.text('Create course'), findsNothing);
        expect(find.text('New version'), findsNothing);
        expect(find.text('Upload video'), findsNothing);

        verifyNever(
          () => repository.assignableTrainingVersions(
            page: any(named: 'page'),
            pageSize: any(named: 'pageSize'),
            search: any(named: 'search'),
            cancelToken: any(named: 'cancelToken'),
          ),
        );
      },
    );

    testWidgets(
      'Course add-only author sees Create only and Create course chip without edit permissions',
      (tester) async {
        final addOnly = managementIdentity(
          capabilities: {
            'training.add_training',
          },
        );

        await launch(tester, identity: addOnly, path: '/workspace/training');

        expect(find.widgetWithText(StatusBadge, 'AUTHORING PERMITTED'), findsOneWidget);
        expect(find.text('Create only'), findsOneWidget);
        expect(find.text('Create and edit'), findsNothing);
        expect(find.text('No version access'), findsOneWidget);
        expect(find.text('Create course'), findsOneWidget);
        expect(find.text('New version'), findsNothing);
        expect(find.text('Upload video'), findsNothing);

        verifyNever(
          () => repository.assignableTrainingVersions(
            page: any(named: 'page'),
            pageSize: any(named: 'pageSize'),
            search: any(named: 'search'),
            cancelToken: any(named: 'cancelToken'),
          ),
        );
      },
    );

    testWidgets(
      'Course edit-only author sees Edit only and Edit course chip without video upload',
      (tester) async {
        final editOnly = managementIdentity(
          capabilities: {
            'training.change_training',
          },
        );

        await launch(tester, identity: editOnly, path: '/workspace/training');

        expect(find.widgetWithText(StatusBadge, 'AUTHORING PERMITTED'), findsOneWidget);
        expect(find.text('Edit only'), findsOneWidget);
        expect(find.text('Create and edit'), findsNothing);
        expect(find.text('Edit course'), findsOneWidget);
        expect(find.text('Upload video'), findsNothing);
        expect(find.text('Create course'), findsNothing);
        expect(find.text('New version'), findsNothing);
      },
    );

    testWidgets(
      'Version add-only author sees Create versions only and New version chip without video upload',
      (tester) async {
        final versionAddOnly = managementIdentity(
          capabilities: {
            'training.add_trainingversion',
          },
        );

        await launch(tester, identity: versionAddOnly, path: '/workspace/training');

        expect(find.widgetWithText(StatusBadge, 'AUTHORING PERMITTED'), findsOneWidget);
        expect(find.text('Create versions only'), findsOneWidget);
        expect(find.text('Create and edit versions'), findsNothing);
        expect(find.text('New version'), findsOneWidget);
        expect(find.text('Upload video'), findsNothing);
        expect(find.text('Create course'), findsNothing);
      },
    );

    testWidgets(
      'Version edit-only author sees Edit versions only and Edit version chip without video upload',
      (tester) async {
        final versionEditOnly = managementIdentity(
          capabilities: {
            'training.change_trainingversion',
          },
        );

        await launch(tester, identity: versionEditOnly, path: '/workspace/training');

        expect(find.widgetWithText(StatusBadge, 'AUTHORING PERMITTED'), findsOneWidget);
        expect(find.text('Edit versions only'), findsOneWidget);
        expect(find.text('Create and edit versions'), findsNothing);
        expect(find.text('Edit version'), findsOneWidget);
        expect(find.text('Upload video'), findsNothing);
        expect(find.text('New version'), findsNothing);
      },
    );

    testWidgets(
      'Module view-only user sees View only for modules, Catalog view badge, and restricted authoring',
      (tester) async {
        final moduleViewer = managementIdentity(
          capabilities: {
            'training.view_module',
          },
        );

        await launch(tester, identity: moduleViewer, path: '/workspace/training');

        expect(find.widgetWithText(StatusBadge, 'CATALOG VIEW'), findsOneWidget);
        expect(find.text('No catalog access'), findsOneWidget);
        expect(find.text('No version access'), findsOneWidget);
        expect(find.text('View only'), findsOneWidget);
        expect(find.text('No lesson access'), findsOneWidget);
        expect(find.text('Assignment restricted'), findsOneWidget);
        expect(
          find.text('Your account has view-only curriculum access. Authoring and mutation controls remain restricted.'),
          findsOneWidget,
        );
        expect(find.byType(ActionChip), findsNothing);

        verifyNever(
          () => repository.assignableTrainingVersions(
            page: any(named: 'page'),
            pageSize: any(named: 'pageSize'),
            search: any(named: 'search'),
            cancelToken: any(named: 'cancelToken'),
          ),
        );
      },
    );

    testWidgets(
      'Module create-only author sees Create module chip, Create only, and Authoring permitted',
      (tester) async {
        final moduleCreator = managementIdentity(
          capabilities: {
            'training.add_module',
          },
        );

        await launch(tester, identity: moduleCreator, path: '/workspace/training');

        expect(find.widgetWithText(StatusBadge, 'AUTHORING PERMITTED'), findsOneWidget);
        expect(find.text('No catalog access'), findsOneWidget);
        expect(find.text('No version access'), findsOneWidget);
        expect(find.text('Create only'), findsOneWidget);
        expect(find.text('No lesson access'), findsOneWidget);
        expect(find.text('Create module'), findsOneWidget);
        expect(find.text('Edit module'), findsNothing);
        expect(find.text('Create course'), findsNothing);
        expect(find.text('New version'), findsNothing);
        expect(find.text('Upload video'), findsNothing);

        final chip = tester.widget<ActionChip>(find.widgetWithText(ActionChip, 'Create module'));
        expect(chip.onPressed, isNull);
      },
    );

    testWidgets(
      'Module edit-only author sees Edit module chip and Edit only',
      (tester) async {
        final moduleEditor = managementIdentity(
          capabilities: {
            'training.change_module',
          },
        );

        await launch(tester, identity: moduleEditor, path: '/workspace/training');

        expect(find.widgetWithText(StatusBadge, 'AUTHORING PERMITTED'), findsOneWidget);
        expect(find.text('Edit only'), findsOneWidget);
        expect(find.text('Create and edit'), findsNothing);
        expect(find.text('Edit module'), findsOneWidget);
        expect(find.text('Create module'), findsNothing);
        expect(find.text('Upload video'), findsNothing);

        final chip = tester.widget<ActionChip>(find.widgetWithText(ActionChip, 'Edit module'));
        expect(chip.onPressed, isNull);
      },
    );

    testWidgets(
      'Lesson view-only user sees View only for lessons and Catalog view badge',
      (tester) async {
        final lessonViewer = managementIdentity(
          capabilities: {
            'training.view_lesson',
          },
        );

        await launch(tester, identity: lessonViewer, path: '/workspace/training');

        expect(find.widgetWithText(StatusBadge, 'CATALOG VIEW'), findsOneWidget);
        expect(find.text('No catalog access'), findsOneWidget);
        expect(find.text('No version access'), findsOneWidget);
        expect(find.text('No module access'), findsOneWidget);
        expect(find.text('View only'), findsOneWidget);
        expect(
          find.text('Your account has view-only curriculum access. Authoring and mutation controls remain restricted.'),
          findsOneWidget,
        );
        expect(find.byType(ActionChip), findsNothing);
      },
    );

    testWidgets(
      'Lesson create-only author sees Create lesson and Upload video chips',
      (tester) async {
        final lessonCreator = managementIdentity(
          capabilities: {
            'training.add_lesson',
          },
        );

        await launch(tester, identity: lessonCreator, path: '/workspace/training');

        expect(find.widgetWithText(StatusBadge, 'AUTHORING PERMITTED'), findsOneWidget);
        expect(find.text('Create only'), findsOneWidget);
        expect(find.text('Create lesson'), findsOneWidget);
        expect(find.text('Upload video'), findsOneWidget);
        expect(find.text('Edit lesson'), findsNothing);
        expect(find.text('Create course'), findsNothing);
        expect(find.text('Create module'), findsNothing);

        final createChip = tester.widget<ActionChip>(find.widgetWithText(ActionChip, 'Create lesson'));
        expect(createChip.onPressed, isNull);
        final uploadChip = tester.widget<ActionChip>(find.widgetWithText(ActionChip, 'Upload video'));
        expect(uploadChip.onPressed, isNull);
      },
    );

    testWidgets(
      'Lesson edit-only author sees Edit lesson and Upload video chips',
      (tester) async {
        final lessonEditor = managementIdentity(
          capabilities: {
            'training.change_lesson',
          },
        );

        await launch(tester, identity: lessonEditor, path: '/workspace/training');

        expect(find.widgetWithText(StatusBadge, 'AUTHORING PERMITTED'), findsOneWidget);
        expect(find.text('Edit only'), findsOneWidget);
        expect(find.text('Edit lesson'), findsOneWidget);
        expect(find.text('Upload video'), findsOneWidget);
        expect(find.text('Create lesson'), findsNothing);

        final editChip = tester.widget<ActionChip>(find.widgetWithText(ActionChip, 'Edit lesson'));
        expect(editChip.onPressed, isNull);
      },
    );

    testWidgets(
      'Combined module and lesson author sees Create and edit for both and all module/lesson chips',
      (tester) async {
        final modLesAuthor = managementIdentity(
          capabilities: {
            'training.add_module',
            'training.change_module',
            'training.add_lesson',
            'training.change_lesson',
          },
        );

        await launch(tester, identity: modLesAuthor, path: '/workspace/training');

        expect(find.widgetWithText(StatusBadge, 'AUTHORING PERMITTED'), findsOneWidget);
        // "Create and edit" appears for both Module management and Lesson management
        expect(find.text('Create and edit'), findsNWidgets(2));
        expect(find.text('No catalog access'), findsOneWidget);
        expect(find.text('No version access'), findsOneWidget);
        expect(find.text('Create module'), findsOneWidget);
        expect(find.text('Edit module'), findsOneWidget);
        expect(find.text('Create lesson'), findsOneWidget);
        expect(find.text('Edit lesson'), findsOneWidget);
        expect(find.text('Upload video'), findsOneWidget);
        expect(find.text('Create course'), findsNothing);
        expect(find.text('New version'), findsNothing);
      },
    );

    testWidgets(
      'Full curriculum author sees all 5 capability rows granted and all authoring chips disabled',
      (tester) async {
        final fullAuthor = managementIdentity(
          capabilities: {
            'training.view_training',
            'training.add_training',
            'training.change_training',
            'training.view_trainingversion',
            'training.add_trainingversion',
            'training.change_trainingversion',
            'training.view_module',
            'training.add_module',
            'training.change_module',
            'training.view_lesson',
            'training.add_lesson',
            'training.change_lesson',
            'training.add_trainingassignment',
          },
        );

        await launch(tester, identity: fullAuthor, path: '/workspace/training');

        expect(find.widgetWithText(StatusBadge, 'AUTHORING PERMITTED'), findsOneWidget);
        expect(find.widgetWithText(StatusBadge, 'ASSIGNMENT AUTHORITY'), findsOneWidget);
        // "Create and edit" appears for Course catalog, Module management, Lesson management
        expect(find.text('Create and edit'), findsNWidgets(3));
        expect(find.text('Create and edit versions'), findsOneWidget);
        expect(find.text('Company-wide assignment'), findsOneWidget);

        expect(find.text('Create course'), findsOneWidget);
        expect(find.text('Edit course'), findsOneWidget);
        expect(find.text('New version'), findsOneWidget);
        expect(find.text('Edit version'), findsOneWidget);
        expect(find.text('Create module'), findsOneWidget);
        expect(find.text('Edit module'), findsOneWidget);
        expect(find.text('Create lesson'), findsOneWidget);
        expect(find.text('Edit lesson'), findsOneWidget);
        expect(find.text('Upload video'), findsOneWidget);

        // Every chip must be disabled
        for (final widget in tester.widgetList<ActionChip>(find.byType(ActionChip))) {
          expect(widget.onPressed, isNull);
        }

        verify(
          () => repository.assignableTrainingVersions(
            page: 1,
            pageSize: any(named: 'pageSize'),
            search: any(named: 'search'),
            cancelToken: any(named: 'cancelToken'),
          ),
        ).called(1);
      },
    );
  });

  group('TrainingManagementScreen live data integration and states', () {
    testWidgets(
      'renders published assignable versions when authorized',
      (tester) async {
        when(
          () => repository.assignableTrainingVersions(
            page: 1,
            pageSize: any(named: 'pageSize'),
            search: any(named: 'search'),
            cancelToken: any(named: 'cancelToken'),
          ),
        ).thenAnswer(
          (_) async => ManagementPage.fromJson(
            pageJson([
              assignableVersionJson(
                42,
                trainingTitle: 'Agricultural Safety Standards',
                title: 'Agricultural Safety Standards v1',
              ),
            ]),
            AssignableTrainingVersion.fromJson,
          ),
        );

        await launch(tester, path: '/workspace/training');

        expect(find.text('Published assignable versions'), findsOneWidget);
        expect(find.text('Agricultural Safety Standards v1'), findsOneWidget);
        expect(find.text('VERSION 1'), findsOneWidget);
        expect(find.widgetWithText(StatusBadge, 'PUBLISHED'), findsNWidgets(2));
      },
    );

    testWidgets(
      'renders empty state when no assignable versions exist',
      (tester) async {
        when(
          () => repository.assignableTrainingVersions(
            page: 1,
            pageSize: any(named: 'pageSize'),
            search: any(named: 'search'),
            cancelToken: any(named: 'cancelToken'),
          ),
        ).thenAnswer(
          (_) async => ManagementPage.fromJson(
            pageJson([]),
            AssignableTrainingVersion.fromJson,
          ),
        );

        await launch(tester, path: '/workspace/training');

        expect(
          find.text('No published training versions currently available.'),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'renders error state and retries on tap',
      (tester) async {
        var callCount = 0;
        when(
          () => repository.assignableTrainingVersions(
            page: 1,
            pageSize: any(named: 'pageSize'),
            search: any(named: 'search'),
            cancelToken: any(named: 'cancelToken'),
          ),
        ).thenAnswer((_) async {
          callCount++;
          if (callCount == 1) {
            throw ApiError(message: 'Failed to load assignable versions', statusCode: 500);
          }
          return ManagementPage.fromJson(
            pageJson([
              assignableVersionJson(10, trainingTitle: 'Pesticide Handling'),
            ]),
            AssignableTrainingVersion.fromJson,
          );
        });

        await launch(tester, path: '/workspace/training');

        expect(find.text('Failed to load assignable versions'), findsOneWidget);

        final retryButton = find.text('Retry');
        expect(retryButton, findsOneWidget);

        await tester.tap(retryButton);
        await tester.pumpAndSettle();

        expect(find.text('Pesticide Handling v1'), findsOneWidget);
        expect(find.text('Failed to load assignable versions'), findsNothing);
      },
    );

    testWidgets(
      'Account switching to unauthorized user revokes access',
      (tester) async {
        await launch(tester, path: '/workspace/training');

        expect(find.text('Training management'), findsWidgets);

        auth.setAuth(
          AuthAuthenticated.identity(
            managementIdentity(
              username: 'unauthorized',
              capabilities: {'organization.view_employee'},
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('CURRICULUM & CATALOG'), findsNothing);
      },
    );
  });

  group('Dark, light, and responsive layouts', () {
    testWidgets('renders cleanly in dark theme', (tester) async {
      await launch(
        tester,
        path: '/workspace/training',
        themeMode: ThemeMode.dark,
      );

      expect(find.text('Training management'), findsWidgets);
      expect(find.text('CURRICULUM & CATALOG'), findsOneWidget);
    });

    testWidgets('fits small screen (320x640 at 2.0x text scale) without overflow', (tester) async {
      await launch(
        tester,
        path: '/workspace/training',
        size: const Size(320, 640),
        textScale: 2.0,
      );

      expect(find.text('Training management'), findsWidgets);
      expect(tester.takeException(), isNull);
    });

    testWidgets('fits landscape screen (844x390 at 1.6x text scale) without overflow', (tester) async {
      await launch(
        tester,
        path: '/workspace/training',
        size: const Size(844, 390),
        textScale: 1.6,
      );

      expect(find.text('Training management'), findsWidgets);
      expect(tester.takeException(), isNull);
    });
  });
}
