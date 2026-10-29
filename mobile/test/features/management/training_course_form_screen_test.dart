import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';
import 'package:training_app/core/errors/api_error.dart';
import 'package:training_app/core/presentation/components/api_error_view.dart';
import 'package:training_app/core/router/app_router.dart';
import 'package:training_app/core/theme/app_theme.dart';
import 'package:training_app/features/auth/domain/models/auth_state.dart';
import 'package:training_app/features/auth/domain/models/authenticated_identity.dart';
import 'package:training_app/features/auth/presentation/controllers/auth_controller.dart';
import 'package:training_app/features/management/data/repositories/management_repository.dart';
import 'package:training_app/features/management/domain/models/management_models.dart';
import 'package:training_app/features/management/presentation/screens/training_course_form_screen.dart';
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
  });

  Future<ProviderContainer> launch(
    WidgetTester tester, {
    AuthenticatedIdentity? identity,
    String path = '/workspace/training/catalog/new',
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
              'training.add_training',
              'training.change_training',
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

  group('TrainingCourseFormScreen - Create course', () {
    testWidgets('renders creation form fields and default active switch', (
      tester,
    ) async {
      await launch(tester, path: '/workspace/training/catalog/new');

      expect(find.byType(TrainingCourseFormScreen), findsOneWidget);
      expect(find.text('New course'), findsOneWidget);
      expect(find.text('New training course'), findsOneWidget);
      expect(find.text('Course code *'), findsOneWidget);
      expect(find.text('Course title *'), findsOneWidget);
      expect(find.text('Description'), findsOneWidget);
      expect(find.text('Active for training'), findsOneWidget);
      expect(find.text('Create course'), findsOneWidget);
      expect(find.text('Cancel'), findsOneWidget);
    });

    testWidgets('client-side validation requires course code and title', (
      tester,
    ) async {
      await launch(tester, path: '/workspace/training/catalog/new');

      // Tap Create course without filling fields
      await tester.tap(find.text('Create course'));
      await tester.pumpAndSettle();

      expect(find.text('Course code is required.'), findsOneWidget);
      expect(find.text('Course title is required.'), findsOneWidget);
      verifyZeroInteractions(repository);
    });

    testWidgets('prevents duplicate submission while save is in flight', (
      tester,
    ) async {
      final completer = Completer<ManagedTraining>();
      when(
        () => repository.createTraining(
          code: any(named: 'code'),
          catalogTitle: any(named: 'catalogTitle'),
          description: any(named: 'description'),
          isActive: any(named: 'isActive'),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer((_) => completer.future);

      await launch(tester, path: '/workspace/training/catalog/new');

      await tester.enterText(
        find.widgetWithText(TextFormField, 'Course code *'),
        'TR-NEW-001',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Course title *'),
        'New Forklift Training',
      );

      // First tap initiates save
      await tester.tap(find.text('Create course'));
      await tester.pump();

      // Submit button should show progress indicator
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      // Second tap while saving must do nothing
      await tester.tap(find.byType(FilledButton));
      await tester.pump();

      verify(
        () => repository.createTraining(
          code: 'TR-NEW-001',
          catalogTitle: 'New Forklift Training',
          description: '',
          isActive: true,
          cancelToken: any(named: 'cancelToken'),
        ),
      ).called(1);

      // Complete mutation
      completer.complete(
        ManagedTraining.fromJson(
          managedTrainingJson(
            id: 99,
            code: 'TR-NEW-001',
            title: 'New Forklift Training',
          ),
        ),
      );
      await tester.pumpAndSettle();
    });

    testWidgets(
      'successful creation posts course, displays snackbar, and pops',
      (tester) async {
        when(
          () => repository.createTraining(
            code: any(named: 'code'),
            catalogTitle: any(named: 'catalogTitle'),
            description: any(named: 'description'),
            isActive: any(named: 'isActive'),
            cancelToken: any(named: 'cancelToken'),
          ),
        ).thenAnswer(
          (_) async => ManagedTraining.fromJson(
            managedTrainingJson(
              id: 10,
              code: 'TR-CRANE-001',
              title: 'Overhead Crane Operation',
              description: 'Safe operation of overhead crane systems.',
              isActive: true,
            ),
          ),
        );

        await launch(tester, path: '/workspace/training/catalog/new');

        await tester.enterText(
          find.widgetWithText(TextFormField, 'Course code *'),
          'TR-CRANE-001',
        );
        await tester.enterText(
          find.widgetWithText(TextFormField, 'Course title *'),
          'Overhead Crane Operation',
        );
        await tester.enterText(
          find.widgetWithText(TextFormField, 'Description'),
          'Safe operation of overhead crane systems.',
        );

        await tester.tap(find.text('Create course'));
        await tester.pumpAndSettle();

        verify(
          () => repository.createTraining(
            code: 'TR-CRANE-001',
            catalogTitle: 'Overhead Crane Operation',
            description: 'Safe operation of overhead crane systems.',
            isActive: true,
            cancelToken: any(named: 'cancelToken'),
          ),
        ).called(1);

        expect(
          find.text('Training course created successfully.'),
          findsOneWidget,
        );
      },
    );

    testWidgets('displays server field errors on 400 validation error', (
      tester,
    ) async {
      when(
        () => repository.createTraining(
          code: any(named: 'code'),
          catalogTitle: any(named: 'catalogTitle'),
          description: any(named: 'description'),
          isActive: any(named: 'isActive'),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenThrow(
        ApiError(
          message: 'Invalid input.',
          statusCode: 400,
          details: {
            'code': ['A training course with this code already exists.'],
          },
        ),
      );

      await launch(tester, path: '/workspace/training/catalog/new');

      await tester.enterText(
        find.widgetWithText(TextFormField, 'Course code *'),
        'TR-DUP-001',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Course title *'),
        'Duplicate Code Test',
      );

      await tester.tap(find.text('Create course'));
      await tester.pumpAndSettle();

      expect(
        find.text('A training course with this code already exists.'),
        findsOneWidget,
      );
    });

    testWidgets('displays server error notice on 403 permission denial', (
      tester,
    ) async {
      when(
        () => repository.createTraining(
          code: any(named: 'code'),
          catalogTitle: any(named: 'catalogTitle'),
          description: any(named: 'description'),
          isActive: any(named: 'isActive'),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenThrow(ApiError(message: 'Permission denied.', statusCode: 403));

      await launch(tester, path: '/workspace/training/catalog/new');

      await tester.enterText(
        find.widgetWithText(TextFormField, 'Course code *'),
        'TR-403-001',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Course title *'),
        'Forbidden Course Test',
      );

      await tester.tap(find.text('Create course'));
      await tester.pumpAndSettle();

      expect(
        find.text('You are not authorized to create this course.'),
        findsOneWidget,
      );
    });

    testWidgets(
      'router redirects away when identity lacks training.add_training',
      (tester) async {
        await launch(
          tester,
          path: '/workspace/training/catalog/new',
          identity: managementIdentity(
            capabilities: {'management_workspace', 'training.view_training'},
          ),
        );

        expect(router.state.matchedLocation, '/workspace');
      },
    );

    testWidgets(
      'displays permission denied screen when rendered directly without training.add_training',
      (tester) async {
        final unauthIdentity = managementIdentity(
          capabilities: {'management_workspace', 'training.view_training'},
        );

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              authControllerProvider.overrideWith(
                () => ManagementTestAuth(unauthIdentity),
              ),
              managementRepositoryProvider.overrideWithValue(repository),
            ],
            child: const MaterialApp(home: TrainingCourseFormScreen()),
          ),
        );
        await tester.pumpAndSettle();

        expect(
          find.text('You do not have permission to create training courses.'),
          findsOneWidget,
        );
        expect(find.text('Create course'), findsNothing);
      },
    );
  });

  group('TrainingCourseFormScreen - Edit course', () {
    testWidgets(
      'loads course without initialTraining and renders exactly one Scaffold and AppBar',
      (tester) async {
        await launch(tester, path: '/workspace/training/catalog/1/edit');

        expect(find.widgetWithText(AppBar, 'Edit course'), findsOneWidget);
        expect(
          find.descendant(
            of: find.byType(TrainingCourseFormScreen),
            matching: find.byType(Scaffold),
          ),
          findsOneWidget,
        );
        expect(find.text('TR-SAFE-001'), findsOneWidget);
        expect(find.text('Workplace Safety Fundamentals'), findsOneWidget);
        expect(find.text('Core safety curriculum.'), findsOneWidget);
      },
    );

    testWidgets(
      'back navigation with unsaved changes in Edit Course prompts discard dialog',
      (tester) async {
        await launch(tester, path: '/workspace/training/catalog/1/edit');

        final titleField = find.widgetWithText(
          TextFormField,
          'Workplace Safety Fundamentals',
        );
        await tester.enterText(titleField, 'Modified Title');
        await tester.pumpAndSettle();

        await tester.tap(find.byTooltip('Cancel'));
        await tester.pumpAndSettle();

        expect(find.text('Discard changes?'), findsOneWidget);
        expect(
          find.text('Your unsaved course changes will be lost.'),
          findsOneWidget,
        );

        await tester.tap(find.text('Keep editing'));
        await tester.pumpAndSettle();

        expect(find.text('Discard changes?'), findsNothing);
        expect(find.byType(TrainingCourseFormScreen), findsOneWidget);
        expect(find.text('Modified Title'), findsOneWidget);
        expect(
          find.descendant(
            of: find.byType(TrainingCourseFormScreen),
            matching: find.byType(Scaffold),
          ),
          findsOneWidget,
        );
      },
    );

    testWidgets('discarding changes in Edit Course dialog pops the screen', (
      tester,
    ) async {
      await launch(tester, path: '/workspace/training/catalog');

      router.push('/workspace/training/catalog/1/edit');
      await tester.pumpAndSettle();

      expect(find.byType(TrainingCourseFormScreen), findsOneWidget);

      final titleField = find.widgetWithText(
        TextFormField,
        'Workplace Safety Fundamentals',
      );
      await tester.enterText(titleField, 'Modified Title');
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Cancel'));
      await tester.pumpAndSettle();

      expect(find.text('Discard changes?'), findsOneWidget);

      await tester.tap(find.text('Discard'));
      await tester.pumpAndSettle();

      expect(find.text('Discard changes?'), findsNothing);
      expect(find.byType(TrainingCourseFormScreen), findsNothing);
      expect(find.text('Training catalog'), findsOneWidget);
    });

    testWidgets(
      'clean form in Edit Course navigates back without discard prompt',
      (tester) async {
        await launch(tester, path: '/workspace/training/catalog');

        router.push('/workspace/training/catalog/1/edit');
        await tester.pumpAndSettle();

        expect(find.byType(TrainingCourseFormScreen), findsOneWidget);
        expect(find.text('Workplace Safety Fundamentals'), findsOneWidget);

        await tester.tap(find.byTooltip('Cancel'));
        await tester.pumpAndSettle();

        expect(find.text('Discard changes?'), findsNothing);
        expect(find.byType(TrainingCourseFormScreen), findsNothing);
        expect(find.text('Training catalog'), findsOneWidget);
      },
    );

    testWidgets(
      'loading failure in Edit Course renders ApiErrorView and retry succeeds',
      (tester) async {
        var callCount = 0;
        when(
          () => repository.training(1, cancelToken: any(named: 'cancelToken')),
        ).thenAnswer((_) async {
          callCount++;
          if (callCount == 1) {
            throw ApiError(
              message: 'Failed to load course details.',
              statusCode: 500,
            );
          }
          return ManagedTraining.fromJson(
            managedTrainingJson(
              id: 1,
              code: 'TR-RELOAD-001',
              title: 'Reloaded Course Title',
            ),
          );
        });

        await launch(tester, path: '/workspace/training/catalog/1/edit');

        expect(find.byType(ApiErrorView), findsOneWidget);
        expect(find.widgetWithText(AppBar, 'Edit course'), findsOneWidget);
        expect(
          find.descendant(
            of: find.byType(TrainingCourseFormScreen),
            matching: find.byType(Scaffold),
          ),
          findsOneWidget,
        );

        await tester.tap(find.text('Retry'));
        await tester.pumpAndSettle();

        expect(find.byType(ApiErrorView), findsNothing);
        expect(find.text('TR-RELOAD-001'), findsOneWidget);
        expect(find.text('Reloaded Course Title'), findsOneWidget);
        expect(find.widgetWithText(AppBar, 'Edit course'), findsOneWidget);
        expect(
          find.descendant(
            of: find.byType(TrainingCourseFormScreen),
            matching: find.byType(Scaffold),
          ),
          findsOneWidget,
        );
      },
    );

    testWidgets('save button is disabled when form is unchanged (not dirty)', (
      tester,
    ) async {
      await launch(tester, path: '/workspace/training/catalog/1/edit');

      final saveButton = tester.widget<FilledButton>(find.byType(FilledButton));
      expect(saveButton.onPressed, isNull);
    });

    testWidgets(
      'modifying a field enables save button and updates course on save',
      (tester) async {
        when(
          () => repository.updateTraining(
            1,
            code: any(named: 'code'),
            catalogTitle: any(named: 'catalogTitle'),
            description: any(named: 'description'),
            isActive: any(named: 'isActive'),
            cancelToken: any(named: 'cancelToken'),
          ),
        ).thenAnswer(
          (_) async => ManagedTraining.fromJson(
            managedTrainingJson(
              id: 1,
              code: 'TR-SAFE-001',
              title: 'Workplace Safety Fundamentals Updated',
              description: 'Core safety curriculum.',
              isActive: true,
            ),
          ),
        );

        await launch(tester, path: '/workspace/training/catalog/1/edit');

        // Modify title
        final titleField = find.widgetWithText(
          TextFormField,
          'Workplace Safety Fundamentals',
        );
        await tester.enterText(
          titleField,
          'Workplace Safety Fundamentals Updated',
        );
        await tester.pumpAndSettle();

        final saveButton = tester.widget<FilledButton>(
          find.byType(FilledButton),
        );
        expect(saveButton.onPressed, isNotNull);

        await tester.tap(find.text('Save changes'));
        await tester.pumpAndSettle();

        verify(
          () => repository.updateTraining(
            1,
            code: 'TR-SAFE-001',
            catalogTitle: 'Workplace Safety Fundamentals Updated',
            description: 'Core safety curriculum.',
            isActive: true,
            cancelToken: any(named: 'cancelToken'),
          ),
        ).called(1);

        expect(find.text('Course updated successfully.'), findsOneWidget);
      },
    );

    testWidgets(
      'router redirects away when identity lacks training.change_training',
      (tester) async {
        await launch(
          tester,
          path: '/workspace/training/catalog/1/edit',
          identity: managementIdentity(
            capabilities: {
              'management_workspace',
              'training.view_training',
              'training.add_training',
            },
          ),
        );

        expect(router.state.matchedLocation, '/workspace');
      },
    );

    testWidgets(
      'displays permission denied screen when rendered directly without training.change_training',
      (tester) async {
        final unauthIdentity = managementIdentity(
          capabilities: {
            'management_workspace',
            'training.view_training',
            'training.add_training',
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
              home: TrainingCourseFormScreen(trainingId: 1),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(
          find.text('You do not have permission to edit training courses.'),
          findsOneWidget,
        );
        expect(find.text('Save changes'), findsNothing);
      },
    );
  });

  group('TrainingCourseFormScreen - Navigation & Discard Dialog', () {
    testWidgets('cancels in-flight request when user account switches', (
      tester,
    ) async {
      final completer = Completer<ManagedTraining>();
      CancelToken? token;
      when(
        () => repository.createTraining(
          code: any(named: 'code'),
          catalogTitle: any(named: 'catalogTitle'),
          description: any(named: 'description'),
          isActive: any(named: 'isActive'),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer((invocation) {
        token = invocation.namedArguments[#cancelToken] as CancelToken?;
        return completer.future;
      });

      await launch(tester, path: '/workspace/training/catalog/new');

      await tester.enterText(
        find.widgetWithText(TextFormField, 'Course code *'),
        'TR-CANCEL-001',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Course title *'),
        'Cancellation Test',
      );

      await tester.tap(find.text('Create course'));
      await tester.pump();

      expect(token, isNotNull);
      expect(token!.isCancelled, isFalse);

      // Account switch
      auth.setAuth(
        AuthAuthenticated.identity(
          managementIdentity(
            team: true,
            username: 'different_user',
            capabilities: {
              'management_workspace',
              'training.view_training',
              'training.add_training',
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
        await launch(tester, path: '/workspace/training/catalog/new');

        await tester.enterText(
          find.widgetWithText(TextFormField, 'Course code *'),
          'TR-DIRTY-001',
        );
        await tester.pumpAndSettle();

        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();

        expect(find.text('Discard changes?'), findsOneWidget);
        expect(
          find.text('Your unsaved course changes will be lost.'),
          findsOneWidget,
        );

        // Tap Keep editing
        await tester.tap(find.text('Keep editing'));
        await tester.pumpAndSettle();

        expect(find.text('Discard changes?'), findsNothing);
        expect(find.byType(TrainingCourseFormScreen), findsOneWidget);
      },
    );

    testWidgets('tapping Discard in dialog pops form screen', (tester) async {
      await launch(tester, path: '/workspace/training/catalog');

      router.push('/workspace/training/catalog/new');
      await tester.pumpAndSettle();

      expect(find.byType(TrainingCourseFormScreen), findsOneWidget);

      await tester.enterText(
        find.widgetWithText(TextFormField, 'Course code *'),
        'TR-DISCARD-001',
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(find.text('Discard changes?'), findsOneWidget);

      await tester.tap(find.text('Discard'));
      await tester.pumpAndSettle();

      expect(find.text('Discard changes?'), findsNothing);
      expect(find.byType(TrainingCourseFormScreen), findsNothing);
      expect(find.text('Training catalog'), findsOneWidget);
    });
  });

  group('Dark, light, and responsive layouts', () {
    testWidgets('renders cleanly in dark mode', (tester) async {
      await launch(
        tester,
        path: '/workspace/training/catalog/new',
        themeMode: ThemeMode.dark,
      );

      expect(find.byType(TrainingCourseFormScreen), findsOneWidget);
      expect(find.text('New training course'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('fits small screen (320x640 at 2.0x text scale)', (
      tester,
    ) async {
      await launch(
        tester,
        path: '/workspace/training/catalog/new',
        size: const Size(320, 640),
        textScale: 2.0,
      );

      expect(find.byType(TrainingCourseFormScreen), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('fits landscape screen (844x390 at 1.6x text scale)', (
      tester,
    ) async {
      await launch(
        tester,
        path: '/workspace/training/catalog/new',
        size: const Size(844, 390),
        textScale: 1.6,
      );

      expect(find.byType(TrainingCourseFormScreen), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
