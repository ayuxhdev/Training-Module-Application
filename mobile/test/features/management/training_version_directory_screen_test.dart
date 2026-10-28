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
      () => repository.allTrainingVersions(
        page: any(named: 'page'),
        pageSize: any(named: 'pageSize'),
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenAnswer((invocation) async {
      final page = invocation.namedArguments[#page] as int? ?? 1;
      if (page == 1) {
        return ManagementPage.fromJson(
          pageJson(
            [
              managedTrainingVersionJson(
                id: 201,
                trainingId: 10,
                trainingTitle: 'Equipment Operation',
                versionNumber: 2,
                title: 'Heavy Machinery v2',
                status: 'PUBLISHED',
                description: 'Certified hydraulic procedures.',
              ),
              managedTrainingVersionJson(
                id: 101,
                trainingId: 10,
                trainingTitle: 'Equipment Operation',
                versionNumber: 1,
                title: 'Heavy Machinery v1',
                status: 'RETIRED',
                description: 'Legacy machinery standard.',
              ),
            ],
            count: 3,
            next: 'https://example.invalid/next',
          ),
          ManagedTrainingVersionItem.fromJson,
        );
      } else {
        return ManagementPage.fromJson(
          pageJson([
            managedTrainingVersionJson(
              id: 301,
              trainingId: 15,
              trainingTitle: 'Electrical Safety',
              versionNumber: 1,
              title: 'High Voltage v1',
              status: 'DRAFT',
              description: 'Under development.',
            ),
          ], count: 3),
          ManagedTrainingVersionItem.fromJson,
        );
      }
    });

    when(
      () => repository.versionDetail(
        any(),
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenAnswer(
      (_) async => ManagedVersionDetail.fromJson(
        managedVersionDetailJson(
          id: 201,
          trainingId: 10,
          trainingTitle: 'Equipment Operation',
          versionNumber: 2,
          title: 'Heavy Machinery v2',
          status: 'PUBLISHED',
        ),
      ),
    );
  });

  Future<ProviderContainer> launch(
    WidgetTester tester, {
    AuthenticatedIdentity? identity,
    String path = '/workspace/training/versions',
    Size size = const Size(800, 2400),
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
          theme: AppTheme.lightTheme,
          routerConfig: router,
        ),
      ),
    );
    await tester.pumpAndSettle();
    return container;
  }

  group('TrainingVersionDirectoryScreen', () {
    testWidgets(
      'router redirects away when account lacks view_trainingversion',
      (tester) async {
        await launch(
          tester,
          path: '/workspace/training/versions',
          identity: managementIdentity(
            capabilities: {
              'management_workspace',
              'training.view_training', // Course view only, no view_trainingversion
            },
          ),
        );

        // Blocked and redirected to homePath (/workspace)
        expect(find.text('Version Directory & Immutability'), findsNothing);
        expect(find.text('Account access'), findsOneWidget);
      },
    );

    testWidgets('renders version directory for version-view-only account', (
      tester,
    ) async {
      await launch(
        tester,
        path: '/workspace/training/versions',
        identity: managementIdentity(
          capabilities: {
            'management_workspace',
            'training.view_trainingversion',
            // No training.view_training (no catalog permissions)
          },
        ),
      );

      expect(find.text('Training versions'), findsWidgets);
      expect(find.text('Version Directory & Immutability'), findsOneWidget);
      expect(find.text('3 version(s) recorded'), findsOneWidget);

      // Verify version item cards
      expect(find.text('Heavy Machinery v2'), findsOneWidget);
      expect(find.text('Certified hydraulic procedures.'), findsOneWidget);
      expect(find.text('Equipment Operation'), findsNWidgets(2));
      expect(find.text('PUBLISHED'), findsOneWidget);
      expect(find.text('RETIRED'), findsOneWidget);
      expect(find.text('VERSION 2'), findsOneWidget);
      expect(find.text('VERSION 1'), findsOneWidget);
    });

    testWidgets('tapping version card navigates to version detail route', (
      tester,
    ) async {
      await launch(tester, path: '/workspace/training/versions');

      await tester.tap(find.text('Heavy Machinery v2'));
      await tester.pumpAndSettle();

      expect(router.state.matchedLocation, '/workspace/training/versions/201');
      expect(find.text('Version details'), findsWidgets);
      verify(
        () => repository.versionDetail(
          201,
          cancelToken: any(named: 'cancelToken'),
        ),
      ).called(1);
    });

    testWidgets('paginates to next and previous pages', (tester) async {
      await launch(tester, path: '/workspace/training/versions');

      expect(find.text('Page 1'), findsOneWidget);
      expect(find.text('Heavy Machinery v2'), findsOneWidget);

      // Tap Next page
      await tester.tap(find.text('Next page'));
      await tester.pumpAndSettle();

      expect(find.text('Page 2'), findsOneWidget);
      expect(find.text('High Voltage v1'), findsOneWidget);
      expect(find.text('DRAFT'), findsOneWidget);
      expect(find.text('Electrical Safety'), findsOneWidget);

      // Tap Previous page
      await tester.tap(find.text('Previous page'));
      await tester.pumpAndSettle();

      expect(find.text('Page 1'), findsOneWidget);
      expect(find.text('Heavy Machinery v2'), findsOneWidget);
    });

    testWidgets('renders empty view when no versions found', (tester) async {
      when(
        () => repository.allTrainingVersions(
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

      await launch(tester, path: '/workspace/training/versions');

      expect(find.byType(EmptyView), findsOneWidget);
      expect(find.text('No training versions found.'), findsOneWidget);
    });

    testWidgets('renders error view and retries on action tap', (tester) async {
      when(
        () => repository.allTrainingVersions(
          page: any(named: 'page'),
          pageSize: any(named: 'pageSize'),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenThrow(ApiError.networkFailure());

      await launch(tester, path: '/workspace/training/versions');

      expect(find.byType(ApiErrorView), findsOneWidget);

      when(
        () => repository.allTrainingVersions(
          page: any(named: 'page'),
          pageSize: any(named: 'pageSize'),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer(
        (_) async => ManagementPage.fromJson(
          pageJson([
            managedTrainingVersionJson(
              id: 50,
              trainingId: 1,
              trainingTitle: 'Safety Basics',
              versionNumber: 1,
              title: 'Safety Basics v1',
              status: 'PUBLISHED',
            ),
          ], count: 1),
          ManagedTrainingVersionItem.fromJson,
        ),
      );

      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();

      expect(find.text('Safety Basics v1'), findsOneWidget);
    });
  });
}
