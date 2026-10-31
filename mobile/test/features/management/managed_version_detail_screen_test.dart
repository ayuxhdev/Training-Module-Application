import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';
import 'package:training_app/core/errors/api_error.dart';
import 'package:training_app/core/presentation/components/api_error_view.dart';
import 'package:training_app/core/presentation/components/empty_view.dart';
import 'package:training_app/core/router/app_router.dart';
import 'package:training_app/core/theme/app_theme.dart';
import 'package:training_app/features/auth/domain/models/authenticated_identity.dart';
import 'package:training_app/features/auth/presentation/controllers/auth_controller.dart';
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
      () => repository.training(any(), cancelToken: any(named: 'cancelToken')),
    ).thenAnswer(
      (_) async => ManagedTraining.fromJson(
        managedTrainingJson(
          id: 1,
          code: 'TR-SAFE-001',
          title: 'Workplace Safety Fundamentals',
          description: 'Core safety curriculum.',
          isActive: true,
          latestVersionNumber: 2,
          latestVersionStatus: 'PUBLISHED',
        ),
      ),
    );

    when(
      () => repository.trainingVersions(
        any(),
        page: any(named: 'page'),
        pageSize: any(named: 'pageSize'),
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenAnswer(
      (_) async => ManagementPage.fromJson(
        pageJson([
          managedTrainingVersionJson(
            id: 20,
            trainingId: 1,
            versionNumber: 2,
            title: 'Workplace Safety v2',
            status: 'PUBLISHED',
          ),
          managedTrainingVersionJson(
            id: 10,
            trainingId: 1,
            versionNumber: 1,
            title: 'Workplace Safety v1',
            status: 'RETIRED',
          ),
        ], count: 2),
        ManagedTrainingVersionItem.fromJson,
      ),
    );

    when(
      () => repository.versionDetail(
        any(),
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenAnswer(
      (_) async => ManagedVersionDetail.fromJson(
        managedVersionDetailJson(
          id: 20,
          trainingId: 1,
          trainingCode: 'TR-SAFE-001',
          trainingTitle: 'Workplace Safety Fundamentals',
          versionNumber: 2,
          title: 'Workplace Safety v2',
          status: 'PUBLISHED',
          modules: [
            managedModuleJson(
              id: 101,
              title: 'Site Safety Protocols',
              description: 'Standard operating safety procedures.',
              order: 1,
              lessons: [
                managedLessonSummaryJson(
                  id: 201,
                  title: 'PPE Orientation',
                  lessonType: 'VIDEO',
                  order: 1,
                  isRequired: true,
                ),
                managedLessonSummaryJson(
                  id: 202,
                  title: 'Hazard Documentation Guide',
                  lessonType: 'TEXT',
                  order: 2,
                  isRequired: false,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  });

  Future<ProviderContainer> launch(
    WidgetTester tester, {
    AuthenticatedIdentity? identity,
    required String path,
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
              'training.view_trainingversion',
              'training.view_module',
              'training.view_lesson',
            },
          ),
    );

    final container = ProviderContainer(
      overrides: [
        authControllerProvider.overrideWith(() => auth),
        managementRepositoryProvider.overrideWithValue(repository),
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

  group('ManagedTrainingDetailScreen', () {
    testWidgets('router redirects away when account lacks view_training', (
      tester,
    ) async {
      await launch(
        tester,
        path: '/workspace/training/catalog/1',
        identity: managementIdentity(
          capabilities: {
            'management_workspace',
            'training.view_trainingversion',
          },
        ),
      );

      expect(router.state.matchedLocation, '/workspace');
    });

    testWidgets('renders course specifications and latest version status', (
      tester,
    ) async {
      await launch(tester, path: '/workspace/training/catalog/1');

      expect(find.text('Course details'), findsWidgets);
      expect(find.text('Workplace Safety Fundamentals'), findsOneWidget);
      expect(find.text('TR-SAFE-001'), findsOneWidget);
      expect(find.text('Active for training'), findsOneWidget);
      expect(find.text('Version 2 (PUBLISHED)'), findsOneWidget);
      expect(find.text('Core safety curriculum.'), findsWidgets);
    });

    testWidgets(
      'shows clickable version history card when authorized and navigates',
      (tester) async {
        await launch(tester, path: '/workspace/training/catalog/1');

        expect(find.text('View version history'), findsOneWidget);
        await tester.tap(find.text('View version history'));
        await tester.pumpAndSettle();

        expect(find.text('Version history'), findsWidgets);
        expect(
          router.state.matchedLocation,
          '/workspace/training/catalog/1/versions',
        );
      },
    );

    testWidgets(
      'shows restricted notice when account lacks view_trainingversion',
      (tester) async {
        await launch(
          tester,
          path: '/workspace/training/catalog/1',
          identity: managementIdentity(
            capabilities: {'management_workspace', 'training.view_training'},
          ),
        );

        expect(find.text('View version history'), findsNothing);
        expect(
          find.text('Version history requires version view permissions.'),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'shows Edit course action when identity has training.change_training and navigates',
      (tester) async {
        await launch(
          tester,
          path: '/workspace/training/catalog/1',
          identity: managementIdentity(
            capabilities: {
              'management_workspace',
              'training.view_training',
              'training.change_training',
            },
          ),
        );

        final editBtn = find.byTooltip('Edit course');
        expect(editBtn, findsOneWidget);

        await tester.tap(editBtn);
        await tester.pumpAndSettle();

        expect(find.text('Edit course'), findsWidgets);
      },
    );

    testWidgets(
      'hides Edit course action when identity lacks training.change_training',
      (tester) async {
        await launch(
          tester,
          path: '/workspace/training/catalog/1',
          identity: managementIdentity(
            capabilities: {'management_workspace', 'training.view_training'},
          ),
        );

        expect(find.byTooltip('Edit course'), findsNothing);
      },
    );

    testWidgets(
      'shows Create draft version card when identity has training.add_trainingversion and navigates',
      (tester) async {
        await launch(
          tester,
          path: '/workspace/training/catalog/1',
          identity: managementIdentity(
            capabilities: {
              'management_workspace',
              'training.view_training',
              'training.view_trainingversion',
              'training.add_trainingversion',
            },
          ),
        );

        final card = find.text('Create draft version');
        expect(card, findsOneWidget);

        await tester.tap(card);
        await tester.pumpAndSettle();

        expect(find.text('New draft version'), findsWidgets);
      },
    );

    testWidgets(
      'hides Create draft version card when identity lacks training.add_trainingversion',
      (tester) async {
        await launch(
          tester,
          path: '/workspace/training/catalog/1',
          identity: managementIdentity(
            capabilities: {
              'management_workspace',
              'training.view_training',
              'training.view_trainingversion',
            },
          ),
        );

        expect(find.text('Create draft version'), findsNothing);
      },
    );

    testWidgets(
      'permission matrix A: course-view and version-add without version-view shows Create draft version while version history remains restricted',
      (tester) async {
        await launch(
          tester,
          path: '/workspace/training/catalog/1',
          identity: managementIdentity(
            capabilities: {
              'management_workspace',
              'training.view_training',
              'training.add_trainingversion',
            },
          ),
        );

        // Course details accessible
        expect(find.text('Course details'), findsWidgets);
        expect(find.text('Workplace Safety Fundamentals'), findsOneWidget);

        // Create draft version visible and navigable
        final createCard = find.text('Create draft version');
        expect(createCard, findsOneWidget);

        // Version history remains restricted
        expect(find.text('View version history'), findsNothing);
        expect(
          find.text('Version history requires version view permissions.'),
          findsOneWidget,
        );

        // Tapping Create draft version opens authorized creation form
        await tester.tap(createCard);
        await tester.pumpAndSettle();

        expect(find.text('New draft version'), findsWidgets);
        expect(
          router.state.matchedLocation,
          '/workspace/training/catalog/1/versions/new',
        );
      },
    );

    testWidgets(
      'permission matrix B: course-view and version-view without version-add shows version history and hides draft creation',
      (tester) async {
        await launch(
          tester,
          path: '/workspace/training/catalog/1',
          identity: managementIdentity(
            capabilities: {
              'management_workspace',
              'training.view_training',
              'training.view_trainingversion',
            },
          ),
        );

        expect(find.text('Course details'), findsWidgets);
        expect(find.text('View version history'), findsOneWidget);
        expect(
          find.text('Version history requires version view permissions.'),
          findsNothing,
        );
        expect(find.text('Create draft version'), findsNothing);
      },
    );

    testWidgets(
      'permission matrix C: course-view, version-view, and version-add shows both actions without duplicates',
      (tester) async {
        await launch(
          tester,
          path: '/workspace/training/catalog/1',
          identity: managementIdentity(
            capabilities: {
              'management_workspace',
              'training.view_training',
              'training.view_trainingversion',
              'training.add_trainingversion',
            },
          ),
        );

        expect(find.text('Course details'), findsWidgets);
        expect(find.text('View version history'), findsOneWidget);
        expect(find.text('Create draft version'), findsOneWidget);
        expect(
          find.text('Version history requires version view permissions.'),
          findsNothing,
        );
      },
    );

    testWidgets(
      'permission matrix D: course-view only does not infer version-history or draft-creation permissions',
      (tester) async {
        await launch(
          tester,
          path: '/workspace/training/catalog/1',
          identity: managementIdentity(
            capabilities: {'management_workspace', 'training.view_training'},
          ),
        );

        expect(find.text('Course details'), findsWidgets);
        expect(find.text('View version history'), findsNothing);
        expect(find.text('Create draft version'), findsNothing);
        expect(
          find.text('Version history requires version view permissions.'),
          findsOneWidget,
        );
      },
    );
  });

  group('ManagedTrainingVersionsScreen', () {
    testWidgets(
      'router redirects away when account lacks view_trainingversion',
      (tester) async {
        await launch(
          tester,
          path: '/workspace/training/catalog/1/versions',
          identity: managementIdentity(
            capabilities: {'management_workspace', 'training.view_training'},
          ),
        );

        expect(router.state.matchedLocation, '/workspace');
      },
    );

    testWidgets(
      'renders version pinning notice and version list with lifecycle badges',
      (tester) async {
        await launch(tester, path: '/workspace/training/catalog/1/versions');

        expect(find.text('Version history'), findsWidgets);
        expect(find.text('Version Pinning & Immutability'), findsOneWidget);
        expect(find.text('Workplace Safety v2'), findsOneWidget);
        expect(find.text('Workplace Safety v1'), findsOneWidget);
        expect(find.text('PUBLISHED'), findsOneWidget);
        expect(find.text('RETIRED'), findsOneWidget);
      },
    );

    testWidgets(
      'tapping version card navigates to /workspace/training/versions/:id',
      (tester) async {
        await launch(tester, path: '/workspace/training/catalog/1/versions');

        expect(find.text('Workplace Safety v2'), findsOneWidget);
        await tester.tap(find.text('Workplace Safety v2'));
        await tester.pumpAndSettle();

        expect(router.state.matchedLocation, '/workspace/training/versions/20');
        expect(find.text('Curriculum structure'), findsOneWidget);
      },
    );

    testWidgets('renders empty state when course has no versions recorded', (
      tester,
    ) async {
      when(
        () => repository.trainingVersions(
          any(),
          page: any(named: 'page'),
          pageSize: any(named: 'pageSize'),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer(
        (_) async => ManagementPage.fromJson(
          pageJson([], count: 0),
          ManagedTrainingVersionItem.fromJson,
        ),
      );

      await launch(tester, path: '/workspace/training/catalog/1/versions');

      expect(find.byType(EmptyView), findsOneWidget);
      expect(find.text('No versions found for this course.'), findsOneWidget);
    });

    testWidgets(
      'shows New draft version action when identity has training.add_trainingversion and navigates',
      (tester) async {
        await launch(
          tester,
          path: '/workspace/training/catalog/1/versions',
          identity: managementIdentity(
            capabilities: {
              'management_workspace',
              'training.view_trainingversion',
              'training.add_trainingversion',
            },
          ),
        );

        final newVersionBtn = find.byTooltip('New draft version');
        expect(newVersionBtn, findsOneWidget);

        await tester.tap(newVersionBtn);
        await tester.pumpAndSettle();

        expect(find.text('New draft version'), findsWidgets);
      },
    );

    testWidgets(
      'hides New draft version action when identity lacks training.add_trainingversion',
      (tester) async {
        await launch(
          tester,
          path: '/workspace/training/catalog/1/versions',
          identity: managementIdentity(
            capabilities: {
              'management_workspace',
              'training.view_trainingversion',
            },
          ),
        );

        expect(find.byTooltip('New draft version'), findsNothing);
      },
    );
  });

  group('ManagedVersionDetailScreen curriculum and permission gating', () {
    testWidgets(
      'router redirects away when account lacks view_trainingversion',
      (tester) async {
        await launch(
          tester,
          path: '/workspace/training/versions/20',
          identity: managementIdentity(
            capabilities: {'management_workspace', 'training.view_training'},
          ),
        );

        expect(router.state.matchedLocation, '/workspace');
      },
    );

    testWidgets(
      'renders hero, lifecycle notice, and full module/lesson tree when fully authorized',
      (tester) async {
        await launch(tester, path: '/workspace/training/versions/20');

        expect(find.text('Version details'), findsWidgets);
        expect(find.text('VERSION 2'), findsOneWidget);
        expect(find.text('Workplace Safety v2'), findsOneWidget);
        expect(find.text('PUBLISHED'), findsWidgets);
        expect(find.text('MANAGEMENT VIEW'), findsOneWidget);

        // Lifecycle status summary
        expect(find.text('Lifecycle status'), findsOneWidget);
        expect(find.text('1 module(s) · 2 lesson(s) recorded'), findsOneWidget);

        // Module
        expect(find.text('Module 1: Site Safety Protocols'), findsOneWidget);
        expect(
          find.text('Standard operating safety procedures.'),
          findsOneWidget,
        );

        // Lessons
        expect(find.text('1. PPE Orientation'), findsOneWidget);
        expect(find.text('VIDEO'), findsOneWidget);
        expect(find.text('REQUIRED'), findsOneWidget);

        expect(find.text('2. Hazard Documentation Guide'), findsOneWidget);
        expect(find.text('TEXT'), findsOneWidget);
        expect(find.text('OPTIONAL'), findsOneWidget);
      },
    );

    testWidgets(
      'renders modules and lessons for version-view-only account without extra module/lesson permissions',
      (tester) async {
        await launch(
          tester,
          path: '/workspace/training/versions/20',
          identity: managementIdentity(
            capabilities: {
              'management_workspace',
              'training.view_trainingversion',
              // No training.view_module or training.view_lesson
            },
          ),
        );

        // Does not show false restriction notices
        expect(
          find.text(
            'Curriculum module details require module view permissions.',
          ),
          findsNothing,
        );
        expect(
          find.text('Lesson details require lesson view permissions.'),
          findsNothing,
        );

        // Shows module and lesson summaries returned with version detail
        expect(find.text('Module 1: Site Safety Protocols'), findsOneWidget);
        expect(find.text('1. PPE Orientation'), findsOneWidget);
        expect(find.text('VIDEO'), findsOneWidget);
        expect(find.text('REQUIRED'), findsOneWidget);
      },
    );

    testWidgets('renders error state and retries on action tap', (
      tester,
    ) async {
      when(
        () => repository.versionDetail(
          20,
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenThrow(ApiError.networkFailure());

      await launch(tester, path: '/workspace/training/versions/20');

      expect(find.byType(ApiErrorView), findsOneWidget);

      // Reset stub for successful response on retry
      when(
        () => repository.versionDetail(
          20,
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer(
        (_) async => ManagedVersionDetail.fromJson(
          managedVersionDetailJson(id: 20, title: 'Version After Retry'),
        ),
      );

      final retryButton = find.text('Retry');
      expect(retryButton, findsOneWidget);
      await tester.tap(retryButton);
      await tester.pumpAndSettle();

      expect(find.text('Version After Retry'), findsOneWidget);
    });
  });

  group('ManagedVersionDetailScreen - DRAFT Authoring Actions and Immutability', () {
    testWidgets(
      'renders authoring action buttons on DRAFT version with full permissions',
      (tester) async {
        when(
          () => repository.versionDetail(
            20,
            cancelToken: any(named: 'cancelToken'),
          ),
        ).thenAnswer(
          (_) async => ManagedVersionDetail.fromJson(
            managedVersionDetailJson(
              id: 20,
              status: 'DRAFT',
              modules: [
                managedModuleJson(
                  id: 101,
                  title: 'Draft Module 1',
                  lessons: [
                    managedLessonSummaryJson(
                      id: 201,
                      title: 'Intro Video',
                      lessonType: 'VIDEO',
                    ),
                    managedLessonSummaryJson(
                      id: 202,
                      title: 'Policy Text',
                      lessonType: 'TEXT',
                    ),
                  ],
                ),
              ],
            ),
          ),
        );

        await launch(
          tester,
          path: '/workspace/training/versions/20',
          identity: managementIdentity(
            capabilities: {
              'management_workspace',
              'training.view_trainingversion',
              'training.add_module',
              'training.change_module',
              'training.add_lesson',
              'training.view_lesson',
              'training.change_lesson',
            },
          ),
        );

        // Create module buttons (AppBar action and curriculum structure section)
        expect(find.byTooltip('Create module'), findsOneWidget);
        expect(
          find.widgetWithText(OutlinedButton, 'Create module'),
          findsOneWidget,
        );

        // Module card actions
        expect(find.byTooltip('Edit module'), findsOneWidget);
        expect(find.byTooltip('Add text lesson'), findsOneWidget);
        expect(find.byTooltip('Add video lesson'), findsOneWidget);

        // Lesson actions
        expect(find.byTooltip('Edit lesson'), findsOneWidget);
        expect(find.byTooltip('Edit video lesson'), findsOneWidget);
      },
    );

    testWidgets('respects granular permissions on DRAFT version', (
      tester,
    ) async {
      when(
        () => repository.versionDetail(
          20,
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer(
        (_) async => ManagedVersionDetail.fromJson(
          managedVersionDetailJson(
            id: 20,
            status: 'DRAFT',
            modules: [
              managedModuleJson(
                id: 101,
                title: 'Draft Module 1',
                lessons: [
                  managedLessonSummaryJson(
                    id: 202,
                    title: 'Policy Text',
                    lessonType: 'TEXT',
                  ),
                ],
              ),
            ],
          ),
        ),
      );

      // Identity with only add_module (no change_module, add_lesson, change_lesson)
      await launch(
        tester,
        path: '/workspace/training/versions/20',
        identity: managementIdentity(
          capabilities: {
            'management_workspace',
            'training.view_trainingversion',
            'training.add_module',
          },
        ),
      );

      expect(find.byTooltip('Create module'), findsOneWidget);
      expect(find.byTooltip('Edit module'), findsNothing);
      expect(find.byTooltip('Add text lesson'), findsNothing);
      expect(find.byTooltip('Add video lesson'), findsNothing);
      expect(find.byTooltip('Edit lesson'), findsNothing);
      expect(find.byTooltip('Edit video lesson'), findsNothing);
    });

    testWidgets(
      'hides edit lesson action when identity has change_lesson but lacks view_lesson',
      (tester) async {
        when(
          () => repository.versionDetail(
            20,
            cancelToken: any(named: 'cancelToken'),
          ),
        ).thenAnswer(
          (_) async => ManagedVersionDetail.fromJson(
            managedVersionDetailJson(
              id: 20,
              status: 'DRAFT',
              modules: [
                managedModuleJson(
                  id: 101,
                  title: 'Draft Module 1',
                  lessons: [
                    managedLessonSummaryJson(
                      id: 202,
                      title: 'Policy Text',
                      lessonType: 'TEXT',
                    ),
                  ],
                ),
              ],
            ),
          ),
        );

        // Identity with change_lesson but NO view_lesson
        await launch(
          tester,
          path: '/workspace/training/versions/20',
          identity: managementIdentity(
            capabilities: {
              'management_workspace',
              'training.view_trainingversion',
              'training.change_lesson',
            },
          ),
        );

        expect(find.byTooltip('Edit lesson'), findsNothing);
      },
    );

    testWidgets(
      'hides edit lesson action when identity has view_lesson but lacks change_lesson',
      (tester) async {
        when(
          () => repository.versionDetail(
            20,
            cancelToken: any(named: 'cancelToken'),
          ),
        ).thenAnswer(
          (_) async => ManagedVersionDetail.fromJson(
            managedVersionDetailJson(
              id: 20,
              status: 'DRAFT',
              modules: [
                managedModuleJson(
                  id: 101,
                  title: 'Draft Module 1',
                  lessons: [
                    managedLessonSummaryJson(
                      id: 202,
                      title: 'Policy Text',
                      lessonType: 'TEXT',
                    ),
                  ],
                ),
              ],
            ),
          ),
        );

        // Identity with view_lesson but NO change_lesson
        await launch(
          tester,
          path: '/workspace/training/versions/20',
          identity: managementIdentity(
            capabilities: {
              'management_workspace',
              'training.view_trainingversion',
              'training.view_lesson',
            },
          ),
        );

        expect(find.byTooltip('Edit lesson'), findsNothing);
      },
    );

    testWidgets('hides all authoring action buttons on PUBLISHED version', (
      tester,
    ) async {
      when(
        () => repository.versionDetail(
          20,
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer(
        (_) async => ManagedVersionDetail.fromJson(
          managedVersionDetailJson(
            id: 20,
            status: 'PUBLISHED',
            modules: [
              managedModuleJson(
                id: 101,
                title: 'Published Module 1',
                lessons: [
                  managedLessonSummaryJson(
                    id: 202,
                    title: 'Policy Text',
                    lessonType: 'TEXT',
                  ),
                ],
              ),
            ],
          ),
        ),
      );

      await launch(
        tester,
        path: '/workspace/training/versions/20',
        identity: managementIdentity(
          capabilities: {
            'management_workspace',
            'training.view_trainingversion',
            'training.add_module',
            'training.change_module',
            'training.add_lesson',
            'training.change_lesson',
          },
        ),
      );

      expect(find.byTooltip('Create module'), findsNothing);
      expect(
        find.widgetWithText(OutlinedButton, 'Create module'),
        findsNothing,
      );
      expect(find.byTooltip('Edit module'), findsNothing);
      expect(find.byTooltip('Add text lesson'), findsNothing);
      expect(find.byTooltip('Add video lesson'), findsNothing);
      expect(find.byTooltip('Edit lesson'), findsNothing);
      expect(find.byTooltip('Edit video lesson'), findsNothing);
    });

    testWidgets('hides all authoring action buttons on RETIRED version', (
      tester,
    ) async {
      when(
        () => repository.versionDetail(
          20,
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer(
        (_) async => ManagedVersionDetail.fromJson(
          managedVersionDetailJson(
            id: 20,
            status: 'RETIRED',
            modules: [
              managedModuleJson(
                id: 101,
                title: 'Retired Module 1',
                lessons: [
                  managedLessonSummaryJson(
                    id: 202,
                    title: 'Policy Text',
                    lessonType: 'TEXT',
                  ),
                ],
              ),
            ],
          ),
        ),
      );

      await launch(
        tester,
        path: '/workspace/training/versions/20',
        identity: managementIdentity(
          capabilities: {
            'management_workspace',
            'training.view_trainingversion',
            'training.add_module',
            'training.change_module',
            'training.add_lesson',
            'training.change_lesson',
          },
        ),
      );

      expect(find.byTooltip('Create module'), findsNothing);
      expect(
        find.widgetWithText(OutlinedButton, 'Create module'),
        findsNothing,
      );
      expect(find.byTooltip('Edit module'), findsNothing);
      expect(find.byTooltip('Add text lesson'), findsNothing);
      expect(find.byTooltip('Add video lesson'), findsNothing);
      expect(find.byTooltip('Edit lesson'), findsNothing);
      expect(find.byTooltip('Edit video lesson'), findsNothing);
    });
  });
}
