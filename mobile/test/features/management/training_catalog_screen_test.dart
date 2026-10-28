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
import 'package:training_app/features/management/presentation/screens/training_catalog_screen.dart';
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
      () => repository.trainings(
        page: any(named: 'page'),
        pageSize: any(named: 'pageSize'),
        search: any(named: 'search'),
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenAnswer((_) async => managedTrainingPage());
  });

  Future<ProviderContainer> launch(
    WidgetTester tester, {
    AuthenticatedIdentity? identity,
    String path = '/workspace/training/catalog',
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

  group('TrainingCatalogScreen access and rendering', () {
    testWidgets('router redirects away when identity lacks view_training', (
      tester,
    ) async {
      await launch(
        tester,
        identity: managementIdentity(
          capabilities: {'management_workspace', 'training.add_module'},
        ),
      );

      expect(router.state.matchedLocation, '/workspace');
    });

    testWidgets(
      'displays access denied when rendered directly without view_training',
      (tester) async {
        final unauthIdentity = managementIdentity(
          capabilities: {'management_workspace', 'training.add_module'},
        );

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              authControllerProvider.overrideWith(
                () => ManagementTestAuth(unauthIdentity),
              ),
              managementRepositoryProvider.overrideWithValue(repository),
            ],
            child: const MaterialApp(home: TrainingCatalogScreen()),
          ),
        );
        await tester.pumpAndSettle();

        expect(
          find.text('You do not have permission to view the training catalog.'),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'renders course list with code, title, active badge, and version',
      (tester) async {
        when(
          () => repository.trainings(
            page: 1,
            pageSize: any(named: 'pageSize'),
            search: any(named: 'search'),
            cancelToken: any(named: 'cancelToken'),
          ),
        ).thenAnswer(
          (_) async => ManagementPage.fromJson(
            pageJson([
              managedTrainingJson(
                id: 1,
                code: 'TR-SAFE-001',
                title: 'Workplace Safety Fundamentals',
                description: 'Core safety curriculum.',
                isActive: true,
                latestVersionNumber: 2,
                latestVersionStatus: 'PUBLISHED',
              ),
              managedTrainingJson(
                id: 2,
                code: 'TR-ARCH-002',
                title: 'Legacy Archived Course',
                description: 'Archived equipment training.',
                isActive: false,
                latestVersionNumber: null,
                latestVersionStatus: null,
              ),
            ], count: 2),
            ManagedTraining.fromJson,
          ),
        );

        await launch(tester);

        expect(find.text('Training catalog'), findsWidgets);
        expect(find.text('Workplace Safety Fundamentals'), findsOneWidget);
        expect(find.text('Code: TR-SAFE-001'), findsOneWidget);
        expect(find.text('ACTIVE'), findsOneWidget);
        expect(find.text('VERSION 2'), findsOneWidget);
        expect(find.text('PUBLISHED'), findsOneWidget);

        expect(find.text('Legacy Archived Course'), findsOneWidget);
        expect(find.text('Code: TR-ARCH-002'), findsOneWidget);
        expect(find.text('INACTIVE'), findsOneWidget);
      },
    );

    testWidgets(
      'debounced search triggers repository query and clear button resets',
      (tester) async {
        await launch(tester);

        final searchField = find.byType(TextField);
        expect(searchField, findsOneWidget);

        await tester.enterText(searchField, 'Forklift');
        await tester.pump(const Duration(milliseconds: 100));
        // Not yet fired before debounce
        verifyNever(
          () => repository.trainings(
            page: 1,
            search: 'Forklift',
            cancelToken: any(named: 'cancelToken'),
          ),
        );

        // Fast-forward debounce duration
        await tester.pump(const Duration(milliseconds: 400));
        await tester.pumpAndSettle();

        verify(
          () => repository.trainings(
            page: 1,
            search: 'Forklift',
            cancelToken: any(named: 'cancelToken'),
          ),
        ).called(1);

        // Clear search button
        final clearButton = find.byIcon(Icons.clear);
        expect(clearButton, findsOneWidget);
        await tester.tap(clearButton);
        await tester.pumpAndSettle();

        expect(find.text('Forklift'), findsNothing);
        // 1 initial load + 1 clear reset = 2 calls with search: null
        verify(
          () => repository.trainings(
            page: 1,
            search: null,
            cancelToken: any(named: 'cancelToken'),
          ),
        ).called(2);
      },
    );

    testWidgets('pagination controls navigate between pages', (tester) async {
      when(
        () => repository.trainings(
          page: 1,
          pageSize: any(named: 'pageSize'),
          search: any(named: 'search'),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer(
        (_) async => ManagementPage.fromJson(
          pageJson(
            [managedTrainingJson(id: 1, title: 'Course Page 1')],
            count: 25,
            next: 'https://example.invalid/next',
          ),
          ManagedTraining.fromJson,
        ),
      );

      when(
        () => repository.trainings(
          page: 2,
          pageSize: any(named: 'pageSize'),
          search: any(named: 'search'),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer(
        (_) async => ManagementPage.fromJson(
          pageJson([
            managedTrainingJson(id: 2, title: 'Course Page 2'),
          ], count: 25),
          ManagedTraining.fromJson,
        ),
      );

      await launch(tester);

      expect(find.text('Course Page 1'), findsOneWidget);
      expect(find.text('Page 1'), findsOneWidget);

      final nextButton = find.widgetWithText(TextButton, 'Next page');
      expect(nextButton, findsOneWidget);
      await tester.tap(nextButton);
      await tester.pumpAndSettle();

      expect(find.text('Course Page 2'), findsOneWidget);
      expect(find.text('Page 2'), findsOneWidget);

      final prevButton = find.widgetWithText(TextButton, 'Previous page');
      expect(prevButton, findsOneWidget);
      await tester.tap(prevButton);
      await tester.pumpAndSettle();

      expect(find.text('Course Page 1'), findsOneWidget);
    });

    testWidgets('renders empty state when no courses exist in catalog', (
      tester,
    ) async {
      when(
        () => repository.trainings(
          page: any(named: 'page'),
          pageSize: any(named: 'pageSize'),
          search: any(named: 'search'),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer(
        (_) async => ManagementPage.fromJson(
          pageJson([], count: 0),
          ManagedTraining.fromJson,
        ),
      );

      await launch(tester);

      expect(find.byType(EmptyView), findsOneWidget);
      expect(
        find.text('No training courses currently in catalog.'),
        findsOneWidget,
      );
    });

    testWidgets('renders error state and retries on action tap', (
      tester,
    ) async {
      when(
        () => repository.trainings(
          page: any(named: 'page'),
          pageSize: any(named: 'pageSize'),
          search: any(named: 'search'),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenThrow(ApiError.networkFailure());

      await launch(tester);

      expect(find.byType(ApiErrorView), findsOneWidget);

      // Now set successful response on retry
      when(
        () => repository.trainings(
          page: any(named: 'page'),
          pageSize: any(named: 'pageSize'),
          search: any(named: 'search'),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer(
        (_) async => managedTrainingPage(title: 'Course After Retry'),
      );

      final retryButton = find.text('Retry');
      expect(retryButton, findsOneWidget);
      await tester.tap(retryButton);
      await tester.pumpAndSettle();

      expect(find.text('Course After Retry'), findsOneWidget);
    });

    testWidgets('tapping course navigates to /workspace/training/catalog/:id', (
      tester,
    ) async {
      when(
        () => repository.training(1, cancelToken: any(named: 'cancelToken')),
      ).thenAnswer(
        (_) async => ManagedTraining.fromJson(
          managedTrainingJson(id: 1, title: 'Workplace Safety Fundamentals'),
        ),
      );

      await launch(tester);

      expect(find.text('Workplace Safety Fundamentals'), findsOneWidget);
      await tester.tap(find.text('Workplace Safety Fundamentals'));
      await tester.pumpAndSettle();

      expect(find.text('Course details'), findsWidgets);
      expect(find.text('Version history'), findsOneWidget);
    });
  });
}
