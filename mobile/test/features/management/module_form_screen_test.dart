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
import 'package:training_app/features/management/presentation/screens/module_form_screen.dart';
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
      () => repository.versionDetail(
        any(),
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenAnswer(
      (_) async => ManagedVersionDetail.fromJson(
        managedVersionDetailJson(
          id: 20,
          trainingId: 1,
          versionNumber: 2,
          title: 'Workplace Safety v2',
          status: 'DRAFT',
        ),
      ),
    );

    when(
      () => repository.moduleDetail(
        any(),
        any(),
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenAnswer(
      (_) async => ManagedModuleDetail.fromJson(
        managedModuleDetailJson(
          id: 51,
          trainingVersionId: 20,
          title: 'Introduction to Site Safety',
          description: 'Basic workplace protocols.',
          position: 1,
        ),
      ),
    );
  });

  Future<ProviderContainer> launch(
    WidgetTester tester, {
    AuthenticatedIdentity? identity,
    String path = '/workspace/training/versions/20/modules/new',
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
              'training.view_trainingversion',
              'training.view_module',
              'training.add_module',
              'training.change_module',
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

    router = container.read(appRouterProvider);
    router.go(path, extra: extra);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MediaQuery(
          data: MediaQueryData(
            size: size,
            textScaler: TextScaler.linear(textScale),
          ),
          child: MaterialApp.router(
            routerConfig: router,
            theme: AppTheme.lightTheme,
            darkTheme: AppTheme.darkTheme,
            themeMode: themeMode,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return container;
  }

  group('ModuleFormScreen - Create module', () {
    testWidgets('renders creation form fields and default position', (
      tester,
    ) async {
      await launch(tester);

      expect(find.text('New module'), findsOneWidget);
      expect(find.text('Module Title *'), findsOneWidget);
      expect(find.text('Position *'), findsOneWidget);
      expect(find.text('Description (optional)'), findsOneWidget);
      expect(find.text('Create Module'), findsOneWidget);
    });

    testWidgets('client-side validation requires title and valid position', (
      tester,
    ) async {
      await launch(tester);

      await tester.tap(find.text('Create Module'));
      await tester.pumpAndSettle();

      expect(find.text('Module title is required.'), findsOneWidget);

      await tester.enterText(
        find.widgetWithText(TextFormField, 'Position *'),
        '0',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Module Title *'),
        'Valid Title',
      );
      await tester.tap(find.text('Create Module'));
      await tester.pumpAndSettle();

      expect(find.text('Position must be a positive integer.'), findsOneWidget);
    });

    testWidgets('prevents duplicate submission while save is in flight', (
      tester,
    ) async {
      final completer = Completer<ManagedModuleDetail>();
      when(
        () => repository.createModule(
          20,
          title: 'Emergency Response',
          description: any(named: 'description'),
          position: any(named: 'position'),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer((_) => completer.future);

      await launch(tester);

      await tester.enterText(
        find.widgetWithText(TextFormField, 'Module Title *'),
        'Emergency Response',
      );
      await tester.tap(find.text('Create Module'));
      await tester.pump();

      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      await tester.tap(find.byType(FilledButton));
      await tester.pump();

      verify(
        () => repository.createModule(
          20,
          title: 'Emergency Response',
          description: any(named: 'description'),
          position: any(named: 'position'),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).called(1);

      completer.complete(
        ManagedModuleDetail.fromJson(
          managedModuleDetailJson(id: 60, title: 'Emergency Response'),
        ),
      );
      await tester.pumpAndSettle();
    });

    testWidgets('successful creation posts module, shows snackbar, and pops', (
      tester,
    ) async {
      when(
        () => repository.createModule(
          20,
          title: 'Hazard Identification',
          description: 'Spotting workplace dangers',
          position: 2,
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer(
        (_) async => ManagedModuleDetail.fromJson(
          managedModuleDetailJson(
            id: 61,
            trainingVersionId: 20,
            title: 'Hazard Identification',
            description: 'Spotting workplace dangers',
            position: 2,
          ),
        ),
      );

      await launch(tester);

      await tester.enterText(
        find.widgetWithText(TextFormField, 'Module Title *'),
        'Hazard Identification',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Position *'),
        '2',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Description (optional)'),
        'Spotting workplace dangers',
      );

      await tester.tap(find.text('Create Module'));
      await tester.pumpAndSettle();

      expect(
        find.text('Module "Hazard Identification" created successfully.'),
        findsOneWidget,
      );
    });

    testWidgets('displays server field errors on 400 validation error', (
      tester,
    ) async {
      when(
        () => repository.createModule(
          20,
          title: any(named: 'title'),
          description: any(named: 'description'),
          position: any(named: 'position'),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenThrow(
        ApiError(
          message: 'Invalid input.',
          statusCode: 400,
          details: {
            'position': ['This version already has a module at that position.'],
          },
        ),
      );

      await launch(tester);

      await tester.enterText(
        find.widgetWithText(TextFormField, 'Module Title *'),
        'Duplicate Position Module',
      );
      await tester.tap(find.text('Create Module'));
      await tester.pumpAndSettle();

      expect(
        find.text('This version already has a module at that position.'),
        findsOneWidget,
      );
    });

    testWidgets('displays position conflict notice on 409 conflict error', (
      tester,
    ) async {
      when(
        () => repository.createModule(
          20,
          title: any(named: 'title'),
          description: any(named: 'description'),
          position: any(named: 'position'),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenThrow(
        ApiError(
          message: 'That position was taken by another edit. Refresh and choose an unused position.',
          statusCode: 409,
        ),
      );

      await launch(tester);

      await tester.enterText(
        find.widgetWithText(TextFormField, 'Module Title *'),
        'Conflict Module',
      );
      await tester.tap(find.text('Create Module'));
      await tester.pumpAndSettle();

      expect(
        find.text(
          'That position was taken by another edit. Refresh and choose an unused position.',
        ),
        findsOneWidget,
      );
    });
  });

  group('ModuleFormScreen - Edit module', () {
    testWidgets('prefills fields from initialModule extra', (tester) async {
      final module = ManagedModule.fromJson(
        managedModuleJson(
          id: 51,
          title: 'Existing Module Title',
          description: 'Existing Description',
          order: 3,
        ),
      );

      await launch(
        tester,
        path: '/workspace/training/versions/20/modules/51/edit',
        extra: module,
      );

      expect(find.text('Edit module'), findsOneWidget);
      expect(find.text('Existing Module Title'), findsOneWidget);
      expect(find.text('Existing Description'), findsOneWidget);
      expect(find.text('3'), findsOneWidget);
      expect(find.text('Save Changes'), findsOneWidget);
    });

    testWidgets('loads module without initialModule via repository', (
      tester,
    ) async {
      await launch(
        tester,
        path: '/workspace/training/versions/20/modules/51/edit',
      );

      expect(find.text('Edit module'), findsOneWidget);
      expect(find.text('Introduction to Site Safety'), findsOneWidget);
      expect(find.text('Basic workplace protocols.'), findsOneWidget);
    });

    testWidgets('modifying a field enables save and updates module', (
      tester,
    ) async {
      when(
        () => repository.updateModule(
          20,
          51,
          title: 'Updated Site Safety',
          description: any(named: 'description'),
          position: any(named: 'position'),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer(
        (_) async => ManagedModuleDetail.fromJson(
          managedModuleDetailJson(
            id: 51,
            trainingVersionId: 20,
            title: 'Updated Site Safety',
          ),
        ),
      );

      final module = ManagedModule.fromJson(
        managedModuleJson(id: 51, title: 'Initial Site Safety', order: 1),
      );

      await launch(
        tester,
        path: '/workspace/training/versions/20/modules/51/edit',
        extra: module,
      );

      await tester.enterText(
        find.widgetWithText(TextFormField, 'Module Title *'),
        'Updated Site Safety',
      );
      await tester.tap(find.text('Save Changes'));
      await tester.pumpAndSettle();

      expect(find.text('Module updated successfully.'), findsOneWidget);
    });

    testWidgets('loading failure in Edit renders ApiErrorView and retries', (
      tester,
    ) async {
      var fail = true;
      when(
        () => repository.moduleDetail(
          20,
          99,
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer((_) async {
        if (fail) {
          throw ApiError(
            message: 'Module not found or not draft.',
            statusCode: 500,
          );
        }
        return ManagedModuleDetail.fromJson(
          managedModuleDetailJson(
            id: 99,
            trainingVersionId: 20,
            title: 'Recovered Module',
          ),
        );
      });

      await launch(
        tester,
        path: '/workspace/training/versions/20/modules/99/edit',
      );

      expect(find.text('Module not found or not draft.'), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);

      fail = false;
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();

      expect(find.text('Recovered Module'), findsOneWidget);
    });
  });

  group('ModuleFormScreen - Permissions & Router Guard', () {
    testWidgets(
      'router redirects away when identity lacks training.add_module',
      (tester) async {
        await launch(
          tester,
          path: '/workspace/training/versions/20/modules/new',
          identity: managementIdentity(
            capabilities: {
              'management_workspace',
              'training.view_trainingversion',
            },
          ),
        );

        expect(router.state.matchedLocation, '/workspace');
      },
    );

    testWidgets(
      'router redirects away when identity lacks training.change_module',
      (tester) async {
        await launch(
          tester,
          path: '/workspace/training/versions/20/modules/51/edit',
          identity: managementIdentity(
            capabilities: {
              'management_workspace',
              'training.view_trainingversion',
              'training.view_module',
            },
          ),
        );

        expect(router.state.matchedLocation, '/workspace');
      },
    );
  });

  group('ModuleFormScreen - Navigation & Discard Dialog', () {
    testWidgets('tapping Cancel with dirty form prompts discard dialog', (
      tester,
    ) async {
      await launch(tester);

      await tester.enterText(
        find.widgetWithText(TextFormField, 'Module Title *'),
        'Unsaved edits',
      );
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(find.text('Discard unsaved changes?'), findsOneWidget);

      await tester.tap(find.text('Keep editing'));
      await tester.pumpAndSettle();

      expect(find.text('New module'), findsOneWidget);
      expect(find.text('Unsaved edits'), findsOneWidget);
    });

    testWidgets('tapping Discard in dialog pops form screen', (tester) async {
      await launch(tester, path: '/workspace/training/versions/20');
      router.push('/workspace/training/versions/20/modules/new');
      await tester.pumpAndSettle();

      await tester.enterText(
        find.widgetWithText(TextFormField, 'Module Title *'),
        'Discard me',
      );
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(find.text('Discard unsaved changes?'), findsOneWidget);

      await tester.tap(find.text('Discard'));
      await tester.pumpAndSettle();

      expect(find.byType(ModuleFormScreen), findsNothing);
    });

    testWidgets('cancels in-flight request when user account switches', (
      tester,
    ) async {
      final completer = Completer<ManagedModuleDetail>();
      CancelToken? token;
      when(
        () => repository.createModule(
          20,
          title: any(named: 'title'),
          description: any(named: 'description'),
          position: any(named: 'position'),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer((invocation) {
        token = invocation.namedArguments[#cancelToken] as CancelToken?;
        return completer.future;
      });

      await launch(tester);

      await tester.enterText(
        find.widgetWithText(TextFormField, 'Module Title *'),
        'Account Switch Test',
      );
      await tester.tap(find.text('Create Module'));
      await tester.pump();

      expect(token, isNotNull);
      expect(token!.isCancelled, isFalse);

      auth.setAuth(
        AuthAuthenticated.identity(
          managementIdentity(
            username: 'switch_user',
            capabilities: {
              'management_workspace',
              'training.view_trainingversion',
              'training.view_module',
              'training.add_module',
            },
          ),
        ),
      );
      await tester.pump();

      expect(token!.isCancelled, isTrue);
    });
  });

  group('Dark, light, and responsive layouts', () {
    testWidgets('renders cleanly in dark mode', (tester) async {
      await launch(tester, themeMode: ThemeMode.dark);
      expect(find.text('New module'), findsOneWidget);
    });

    testWidgets('fits small screen (320x640 at 2.0x text scale)', (
      tester,
    ) async {
      await launch(tester, size: const Size(320, 640), textScale: 2.0);
      expect(find.text('New module'), findsOneWidget);
    });

    testWidgets('fits landscape screen (844x390 at 1.6x text scale)', (
      tester,
    ) async {
      await launch(tester, size: const Size(844, 390), textScale: 1.6);
      expect(find.text('New module'), findsOneWidget);
    });
  });
}
