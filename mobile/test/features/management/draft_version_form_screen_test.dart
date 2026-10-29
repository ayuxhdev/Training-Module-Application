import 'dart:async';

import 'package:dio/dio.dart';
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
import 'package:training_app/features/management/data/repositories/management_repository.dart';
import 'package:training_app/features/management/domain/models/management_models.dart';
import 'package:training_app/features/management/presentation/screens/draft_version_form_screen.dart';
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
          latestVersionNumber: 1,
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
            id: 10,
            trainingId: 1,
            versionNumber: 1,
            title: 'Workplace Safety v1',
            status: 'PUBLISHED',
          ),
        ]),
        ManagedTrainingVersionItem.fromJson,
      ),
    );
  });

  Future<ProviderContainer> launch(
    WidgetTester tester, {
    AuthenticatedIdentity? identity,
    String path = '/workspace/training/catalog/1/versions/new',
    ThemeMode themeMode = ThemeMode.light,
    Size size = const Size(800, 2400),
    double textScale = 1.0,
    Object? extra,
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
              'training.add_trainingversion',
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

    router = container.read(appRouterProvider);
    if (extra != null) {
      router.go(path, extra: extra);
    } else {
      router.go(path);
    }

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

  group('DraftVersionFormScreen - Version creation workflow', () {
    testWidgets(
      'renders draft version form with server-allocated numbering notice and fields',
      (tester) async {
        await launch(tester);

        expect(find.byType(DraftVersionFormScreen), findsOneWidget);
        expect(find.text('New draft version'), findsWidgets);
        expect(
          find.text(
            'Version numbers are allocated sequentially by the server upon creation. '
            'New versions start in editable DRAFT status.',
          ),
          findsOneWidget,
        );
        expect(find.text('Version title *'), findsOneWidget);
        expect(find.text('Description'), findsOneWidget);
        expect(find.text('Learning objectives'), findsOneWidget);
        expect(find.text('Change summary'), findsOneWidget);
        expect(find.text('Create draft version'), findsOneWidget);
        expect(find.text('Cancel'), findsOneWidget);
      },
    );

    testWidgets('client-side validation requires version title', (
      tester,
    ) async {
      await launch(tester);

      await tester.tap(find.text('Create draft version'));
      await tester.pumpAndSettle();

      expect(find.text('Version title is required.'), findsOneWidget);
      verifyZeroInteractions(repository);
    });

    testWidgets('prevents duplicate submission while save is in flight', (
      tester,
    ) async {
      final completer = Completer<ManagedVersionDetail>();
      when(
        () => repository.createDraftVersion(
          1,
          title: any(named: 'title'),
          description: any(named: 'description'),
          learningObjectives: any(named: 'learningObjectives'),
          changeSummary: any(named: 'changeSummary'),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer((_) => completer.future);

      await launch(tester);

      await tester.enterText(
        find.widgetWithText(TextFormField, 'Version title *'),
        'Safety Refresh 2026',
      );

      // First tap initiates save
      await tester.tap(find.text('Create draft version'));
      await tester.pump();

      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      // Second tap while saving must do nothing
      await tester.tap(find.byType(FilledButton));
      await tester.pump();

      verify(
        () => repository.createDraftVersion(
          1,
          title: 'Safety Refresh 2026',
          description: '',
          learningObjectives: '',
          changeSummary: '',
          cancelToken: any(named: 'cancelToken'),
        ),
      ).called(1);

      completer.complete(
        ManagedVersionDetail.fromJson(
          managedVersionDetailJson(
            id: 30,
            trainingId: 1,
            versionNumber: 2,
            title: 'Safety Refresh 2026',
            status: 'DRAFT',
          ),
        ),
      );
      await tester.pumpAndSettle();
    });

    testWidgets(
      'successful creation posts draft version, displays snackbar, and pops',
      (tester) async {
        when(
          () => repository.createDraftVersion(
            1,
            title: any(named: 'title'),
            description: any(named: 'description'),
            learningObjectives: any(named: 'learningObjectives'),
            changeSummary: any(named: 'changeSummary'),
            cancelToken: any(named: 'cancelToken'),
          ),
        ).thenAnswer(
          (_) async => ManagedVersionDetail.fromJson(
            managedVersionDetailJson(
              id: 30,
              trainingId: 1,
              versionNumber: 2,
              title: 'Safety Refresh 2026 v2',
              description: 'Comprehensive 2026 safety update.',
              status: 'DRAFT',
              learningObjectives: 'Operate safely with updated gear.',
              changeSummary: 'Added new personal protective equipment section.',
            ),
          ),
        );

        await launch(tester);

        await tester.enterText(
          find.widgetWithText(TextFormField, 'Version title *'),
          'Safety Refresh 2026 v2',
        );
        await tester.enterText(
          find.widgetWithText(TextFormField, 'Description'),
          'Comprehensive 2026 safety update.',
        );
        await tester.enterText(
          find.widgetWithText(TextFormField, 'Learning objectives'),
          'Operate safely with updated gear.',
        );
        await tester.enterText(
          find.widgetWithText(TextFormField, 'Change summary'),
          'Added new personal protective equipment section.',
        );

        await tester.tap(find.text('Create draft version'));
        await tester.pumpAndSettle();

        verify(
          () => repository.createDraftVersion(
            1,
            title: 'Safety Refresh 2026 v2',
            description: 'Comprehensive 2026 safety update.',
            learningObjectives: 'Operate safely with updated gear.',
            changeSummary: 'Added new personal protective equipment section.',
            cancelToken: any(named: 'cancelToken'),
          ),
        ).called(1);

        expect(
          find.text('Draft version created successfully.'),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'returning to a previously empty version-history screen refreshes the list after creation',
      (tester) async {
        var versionsCallCount = 0;
        when(
          () => repository.trainingVersions(
            1,
            page: any(named: 'page'),
            pageSize: any(named: 'pageSize'),
            cancelToken: any(named: 'cancelToken'),
          ),
        ).thenAnswer((_) async {
          versionsCallCount++;
          if (versionsCallCount == 1) {
            return ManagementPage.fromJson(
              pageJson([], count: 0),
              ManagedTrainingVersionItem.fromJson,
            );
          }
          return ManagementPage.fromJson(
            pageJson([
              managedTrainingVersionJson(
                id: 11,
                trainingId: 1,
                versionNumber: 1,
                title: 'Initial Safety Draft',
                status: 'DRAFT',
              ),
            ], count: 1),
            ManagedTrainingVersionItem.fromJson,
          );
        });

        when(
          () => repository.createDraftVersion(
            1,
            title: any(named: 'title'),
            description: any(named: 'description'),
            learningObjectives: any(named: 'learningObjectives'),
            changeSummary: any(named: 'changeSummary'),
            cancelToken: any(named: 'cancelToken'),
          ),
        ).thenAnswer(
          (_) async => ManagedVersionDetail.fromJson(
            managedVersionDetailJson(
              id: 11,
              trainingId: 1,
              versionNumber: 1,
              title: 'Initial Safety Draft',
              status: 'DRAFT',
            ),
          ),
        );

        await launch(tester, path: '/workspace/training/catalog/1/versions');

        expect(find.text('No versions found for this course.'), findsOneWidget);
        expect(versionsCallCount, 1);

        router.push('/workspace/training/catalog/1/versions/new');
        await tester.pumpAndSettle();

        expect(find.byType(DraftVersionFormScreen), findsOneWidget);

        await tester.enterText(
          find.widgetWithText(TextFormField, 'Version title *'),
          'Initial Safety Draft',
        );

        await tester.tap(find.text('Create draft version'));
        await tester.pumpAndSettle();

        expect(find.byType(DraftVersionFormScreen), findsNothing);
        expect(find.text('No versions found for this course.'), findsNothing);
        expect(find.text('Initial Safety Draft'), findsOneWidget);
        expect(versionsCallCount, 2);
      },
    );

    testWidgets(
      'existing cached version-history pages refresh correctly after creation',
      (tester) async {
        var versionsCallCount = 0;
        when(
          () => repository.trainingVersions(
            1,
            page: any(named: 'page'),
            pageSize: any(named: 'pageSize'),
            cancelToken: any(named: 'cancelToken'),
          ),
        ).thenAnswer((_) async {
          versionsCallCount++;
          if (versionsCallCount == 1) {
            return ManagementPage.fromJson(
              pageJson([
                managedTrainingVersionJson(
                  id: 10,
                  trainingId: 1,
                  versionNumber: 1,
                  title: 'Workplace Safety v1',
                  status: 'PUBLISHED',
                ),
              ], count: 1),
              ManagedTrainingVersionItem.fromJson,
            );
          }
          return ManagementPage.fromJson(
            pageJson([
              managedTrainingVersionJson(
                id: 20,
                trainingId: 1,
                versionNumber: 2,
                title: 'Workplace Safety v2 Draft',
                status: 'DRAFT',
              ),
              managedTrainingVersionJson(
                id: 10,
                trainingId: 1,
                versionNumber: 1,
                title: 'Workplace Safety v1',
                status: 'PUBLISHED',
              ),
            ], count: 2),
            ManagedTrainingVersionItem.fromJson,
          );
        });

        when(
          () => repository.createDraftVersion(
            1,
            title: any(named: 'title'),
            description: any(named: 'description'),
            learningObjectives: any(named: 'learningObjectives'),
            changeSummary: any(named: 'changeSummary'),
            cancelToken: any(named: 'cancelToken'),
          ),
        ).thenAnswer(
          (_) async => ManagedVersionDetail.fromJson(
            managedVersionDetailJson(
              id: 20,
              trainingId: 1,
              versionNumber: 2,
              title: 'Workplace Safety v2 Draft',
              status: 'DRAFT',
            ),
          ),
        );

        await launch(tester, path: '/workspace/training/catalog/1/versions');

        expect(find.text('Workplace Safety v1'), findsOneWidget);
        expect(find.text('Workplace Safety v2 Draft'), findsNothing);
        expect(versionsCallCount, 1);

        router.push('/workspace/training/catalog/1/versions/new');
        await tester.pumpAndSettle();

        await tester.enterText(
          find.widgetWithText(TextFormField, 'Version title *'),
          'Workplace Safety v2 Draft',
        );

        await tester.tap(find.text('Create draft version'));
        await tester.pumpAndSettle();

        expect(find.text('Workplace Safety v2 Draft'), findsOneWidget);
        expect(find.text('Workplace Safety v1'), findsOneWidget);
        expect(versionsCallCount, 2);
      },
    );

    testWidgets(
      'failed mutation does not falsely invalidate or update version history',
      (tester) async {
        var versionsCallCount = 0;
        when(
          () => repository.trainingVersions(
            1,
            page: any(named: 'page'),
            pageSize: any(named: 'pageSize'),
            cancelToken: any(named: 'cancelToken'),
          ),
        ).thenAnswer((_) async {
          versionsCallCount++;
          return ManagementPage.fromJson(
            pageJson([], count: 0),
            ManagedTrainingVersionItem.fromJson,
          );
        });

        when(
          () => repository.createDraftVersion(
            1,
            title: any(named: 'title'),
            description: any(named: 'description'),
            learningObjectives: any(named: 'learningObjectives'),
            changeSummary: any(named: 'changeSummary'),
            cancelToken: any(named: 'cancelToken'),
          ),
        ).thenThrow(ApiError(message: 'Server failure.', statusCode: 500));

        await launch(tester, path: '/workspace/training/catalog/1/versions');
        expect(find.text('No versions found for this course.'), findsOneWidget);
        expect(versionsCallCount, 1);

        router.push('/workspace/training/catalog/1/versions/new');
        await tester.pumpAndSettle();

        await tester.enterText(
          find.widgetWithText(TextFormField, 'Version title *'),
          'Failing Draft',
        );

        await tester.tap(find.text('Create draft version'));
        await tester.pumpAndSettle();

        expect(find.byType(DraftVersionFormScreen), findsOneWidget);
        expect(find.text('Server failure.'), findsOneWidget);
        expect(versionsCallCount, 1);
      },
    );

    testWidgets(
      'displays 409 conflict error when another author created that version',
      (tester) async {
        when(
          () => repository.createDraftVersion(
            1,
            title: any(named: 'title'),
            description: any(named: 'description'),
            learningObjectives: any(named: 'learningObjectives'),
            changeSummary: any(named: 'changeSummary'),
            cancelToken: any(named: 'cancelToken'),
          ),
        ).thenThrow(
          ApiError(
            message: 'Conflict: version already exists.',
            statusCode: 409,
          ),
        );

        await launch(tester);

        await tester.enterText(
          find.widgetWithText(TextFormField, 'Version title *'),
          'Conflicting Version',
        );

        await tester.tap(find.text('Create draft version'));
        await tester.pumpAndSettle();

        expect(
          find.text(
            'Another author created that version. Refresh the version history and try again.',
          ),
          findsOneWidget,
        );
      },
    );

    testWidgets('displays 400 field errors when server rejects input', (
      tester,
    ) async {
      when(
        () => repository.createDraftVersion(
          1,
          title: any(named: 'title'),
          description: any(named: 'description'),
          learningObjectives: any(named: 'learningObjectives'),
          changeSummary: any(named: 'changeSummary'),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenThrow(
        ApiError(
          message: 'Invalid input.',
          statusCode: 400,
          details: {
            'title': ['A draft version with this title already exists.'],
          },
        ),
      );

      await launch(tester);

      await tester.enterText(
        find.widgetWithText(TextFormField, 'Version title *'),
        'Duplicate Title',
      );

      await tester.tap(find.text('Create draft version'));
      await tester.pumpAndSettle();

      expect(
        find.text('A draft version with this title already exists.'),
        findsOneWidget,
      );
    });

    testWidgets('displays 403 error message when forbidden', (tester) async {
      when(
        () => repository.createDraftVersion(
          1,
          title: any(named: 'title'),
          description: any(named: 'description'),
          learningObjectives: any(named: 'learningObjectives'),
          changeSummary: any(named: 'changeSummary'),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenThrow(ApiError(message: 'Permission denied.', statusCode: 403));

      await launch(tester);

      await tester.enterText(
        find.widgetWithText(TextFormField, 'Version title *'),
        'Forbidden Version',
      );

      await tester.tap(find.text('Create draft version'));
      await tester.pumpAndSettle();

      expect(
        find.text('You are not authorized to create draft training versions.'),
        findsOneWidget,
      );
    });
  });

  group('DraftVersionFormScreen - Permissions & Router Guard', () {
    testWidgets(
      'router redirects away when identity lacks training.add_trainingversion',
      (tester) async {
        await launch(
          tester,
          identity: managementIdentity(
            capabilities: {
              'management_workspace',
              'training.view_training',
              'training.view_trainingversion',
            },
          ),
        );

        expect(router.state.matchedLocation, '/workspace');
      },
    );

    testWidgets(
      'displays permission denied screen when rendered directly without training.add_trainingversion',
      (tester) async {
        final unauthIdentity = managementIdentity(
          capabilities: {
            'management_workspace',
            'training.view_training',
            'training.view_trainingversion',
          },
        );

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              authControllerProvider.overrideWith(
                () => ManagementTestAuth(unauthIdentity),
              ),
              managementRepositoryProvider.overrideWithValue(repository),
            ],
            child: const MaterialApp(
              home: DraftVersionFormScreen(trainingId: 1),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(
          find.text(
            'You do not have permission to create draft training versions.',
          ),
          findsOneWidget,
        );
        expect(find.text('Create draft version'), findsNothing);
      },
    );
  });

  group('DraftVersionFormScreen - Navigation & Discard Dialog', () {
    testWidgets('cancels in-flight request when user account switches', (
      tester,
    ) async {
      final completer = Completer<ManagedVersionDetail>();
      CancelToken? token;
      when(
        () => repository.createDraftVersion(
          1,
          title: any(named: 'title'),
          description: any(named: 'description'),
          learningObjectives: any(named: 'learningObjectives'),
          changeSummary: any(named: 'changeSummary'),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer((invocation) {
        token = invocation.namedArguments[#cancelToken] as CancelToken?;
        return completer.future;
      });

      await launch(tester);

      await tester.enterText(
        find.widgetWithText(TextFormField, 'Version title *'),
        'Cancel Version Test',
      );

      await tester.tap(find.text('Create draft version'));
      await tester.pump();

      expect(token, isNotNull);
      expect(token!.isCancelled, isFalse);

      auth.setAuth(
        AuthAuthenticated.identity(
          managementIdentity(
            team: true,
            username: 'different_user',
            capabilities: {
              'management_workspace',
              'training.view_training',
              'training.view_trainingversion',
              'training.add_trainingversion',
            },
          ),
        ),
      );
      await tester.pump();

      expect(token!.isCancelled, isTrue);
    });

    testWidgets(
      'tapping Cancel with dirty form prompts discard dialog and Keep editing stays',
      (tester) async {
        await launch(tester);

        await tester.enterText(
          find.widgetWithText(TextFormField, 'Version title *'),
          'Unsaved Version',
        );
        await tester.pumpAndSettle();

        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();

        expect(find.text('Discard draft version?'), findsOneWidget);
        expect(
          find.text('Your unsaved version details will be lost.'),
          findsOneWidget,
        );

        await tester.tap(find.text('Keep editing'));
        await tester.pumpAndSettle();

        expect(find.text('Discard draft version?'), findsNothing);
        expect(find.byType(DraftVersionFormScreen), findsOneWidget);
      },
    );

    testWidgets('tapping Discard in dialog pops form screen', (tester) async {
      await launch(tester, path: '/workspace/training/catalog/1/versions');

      router.push('/workspace/training/catalog/1/versions/new');
      await tester.pumpAndSettle();

      expect(find.byType(DraftVersionFormScreen), findsOneWidget);

      await tester.enterText(
        find.widgetWithText(TextFormField, 'Version title *'),
        'Discard Version',
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(find.text('Discard draft version?'), findsOneWidget);

      await tester.tap(find.text('Discard'));
      await tester.pumpAndSettle();

      expect(find.text('Discard draft version?'), findsNothing);
      expect(find.byType(DraftVersionFormScreen), findsNothing);
      expect(find.text('Version history'), findsWidgets);
    });
  });

  group('Dark, light, and responsive layouts', () {
    testWidgets('renders cleanly in dark mode', (tester) async {
      await launch(tester, themeMode: ThemeMode.dark);

      expect(find.byType(DraftVersionFormScreen), findsOneWidget);
      expect(find.text('New draft version'), findsWidgets);
      expect(tester.takeException(), isNull);
    });

    testWidgets('fits small screen (320x640 at 2.0x text scale)', (
      tester,
    ) async {
      await launch(tester, size: const Size(320, 640), textScale: 2.0);

      expect(find.byType(DraftVersionFormScreen), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('fits landscape screen (844x390 at 1.6x text scale)', (
      tester,
    ) async {
      await launch(tester, size: const Size(844, 390), textScale: 1.6);

      expect(find.byType(DraftVersionFormScreen), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
