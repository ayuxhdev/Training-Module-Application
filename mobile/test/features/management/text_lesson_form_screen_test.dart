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
import 'package:training_app/features/management/presentation/screens/text_lesson_form_screen.dart';
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
      () => repository.textLessonDetail(
        any(),
        any(),
        any(),
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenAnswer(
      (_) async => ManagedTextLessonDetail.fromJson(
        managedTextLessonDetailJson(
          id: 90,
          moduleId: 51,
          trainingVersionId: 20,
          title: 'Workplace Protocols',
          contentType: 'TEXT',
          body: 'Detailed procedures and emergency steps.',
          position: 1,
          isRequired: true,
        ),
      ),
    );
  });

  Future<ProviderContainer> launch(
    WidgetTester tester, {
    AuthenticatedIdentity? identity,
    String path = '/workspace/training/versions/20/modules/51/lessons/new',
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
              'training.view_lesson',
              'training.add_lesson',
              'training.change_lesson',
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

  group('TextLessonFormScreen - Create text lesson', () {
    testWidgets('renders creation form fields and default values', (
      tester,
    ) async {
      await launch(tester);

      expect(find.text('New text lesson'), findsOneWidget);
      expect(find.text('Lesson Title *'), findsOneWidget);
      expect(find.text('Position *'), findsOneWidget);
      expect(find.text('Required lesson'), findsOneWidget);
      expect(find.text('Lesson Body (plain text) *'), findsOneWidget);
      expect(find.text('Create Lesson'), findsOneWidget);
    });

    testWidgets('client-side validation requires title, body and position', (
      tester,
    ) async {
      await launch(tester);

      await tester.tap(find.text('Create Lesson'));
      await tester.pumpAndSettle();

      expect(find.text('Lesson title is required.'), findsOneWidget);
      expect(find.text('Lesson body is required.'), findsOneWidget);

      await tester.enterText(
        find.widgetWithText(TextFormField, 'Position *'),
        '0',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Lesson Title *'),
        'Valid Title',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Lesson Body (plain text) *'),
        'Valid Body Text',
      );
      await tester.tap(find.text('Create Lesson'));
      await tester.pumpAndSettle();

      expect(find.text('Position must be a positive integer.'), findsOneWidget);
    });

    testWidgets('prevents duplicate submission while save is in flight', (
      tester,
    ) async {
      final completer = Completer<ManagedTextLessonDetail>();
      when(
        () => repository.createTextLesson(
          20,
          51,
          title: 'Safety Equipment',
          body: any(named: 'body'),
          position: any(named: 'position'),
          isRequired: any(named: 'isRequired'),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer((_) => completer.future);

      await launch(tester);

      await tester.enterText(
        find.widgetWithText(TextFormField, 'Lesson Title *'),
        'Safety Equipment',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Lesson Body (plain text) *'),
        'Wear helmets at all times.',
      );

      await tester.tap(find.text('Create Lesson'));
      await tester.pump();

      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      await tester.tap(find.byType(FilledButton));
      await tester.pump();

      verify(
        () => repository.createTextLesson(
          20,
          51,
          title: 'Safety Equipment',
          body: any(named: 'body'),
          position: any(named: 'position'),
          isRequired: any(named: 'isRequired'),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).called(1);

      completer.complete(
        ManagedTextLessonDetail.fromJson(
          managedTextLessonDetailJson(id: 95, title: 'Safety Equipment'),
        ),
      );
      await tester.pumpAndSettle();
    });

    testWidgets('successful creation posts lesson, shows snackbar, and pops', (
      tester,
    ) async {
      when(
        () => repository.createTextLesson(
          20,
          51,
          title: 'Emergency Exits',
          body: 'Know your exit paths.',
          position: 2,
          isRequired: true,
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer(
        (_) async => ManagedTextLessonDetail.fromJson(
          managedTextLessonDetailJson(
            id: 96,
            moduleId: 51,
            trainingVersionId: 20,
            title: 'Emergency Exits',
            body: 'Know your exit paths.',
            position: 2,
            isRequired: true,
          ),
        ),
      );

      await launch(tester);

      await tester.enterText(
        find.widgetWithText(TextFormField, 'Lesson Title *'),
        'Emergency Exits',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Position *'),
        '2',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Lesson Body (plain text) *'),
        'Know your exit paths.',
      );

      await tester.tap(find.text('Create Lesson'));
      await tester.pumpAndSettle();

      expect(
        find.text('Text lesson "Emergency Exits" created successfully.'),
        findsOneWidget,
      );
    });

    testWidgets('displays server field errors on 400 validation error', (
      tester,
    ) async {
      when(
        () => repository.createTextLesson(
          20,
          51,
          title: any(named: 'title'),
          body: any(named: 'body'),
          position: any(named: 'position'),
          isRequired: any(named: 'isRequired'),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenThrow(
        ApiError(
          message: 'Invalid input.',
          statusCode: 400,
          details: {
            'position': ['This module already has a lesson at that position.'],
          },
        ),
      );

      await launch(tester);

      await tester.enterText(
        find.widgetWithText(TextFormField, 'Lesson Title *'),
        'Duplicate Position Lesson',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Lesson Body (plain text) *'),
        'Content here.',
      );
      await tester.tap(find.text('Create Lesson'));
      await tester.pumpAndSettle();

      expect(
        find.text('This module already has a lesson at that position.'),
        findsOneWidget,
      );
    });

    testWidgets('displays position conflict notice on 409 conflict error', (
      tester,
    ) async {
      when(
        () => repository.createTextLesson(
          20,
          51,
          title: any(named: 'title'),
          body: any(named: 'body'),
          position: any(named: 'position'),
          isRequired: any(named: 'isRequired'),
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
        find.widgetWithText(TextFormField, 'Lesson Title *'),
        'Conflict Lesson',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Lesson Body (plain text) *'),
        'Content here.',
      );
      await tester.tap(find.text('Create Lesson'));
      await tester.pumpAndSettle();

      expect(
        find.text(
          'That position was taken by another edit. Refresh and choose an unused position.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('preserves leading indentation when submitting lesson body', (
      tester,
    ) async {
      const indentedBody =
          '    Step 1: inspect belt\n    Step 2: tighten buckle';
      when(
        () => repository.createTextLesson(
          20,
          51,
          title: 'Indentation Test',
          body: indentedBody,
          position: 1,
          isRequired: true,
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer(
        (_) async => ManagedTextLessonDetail.fromJson(
          managedTextLessonDetailJson(
            id: 101,
            title: 'Indentation Test',
            body: indentedBody,
          ),
        ),
      );

      await launch(tester);

      await tester.enterText(
        find.widgetWithText(TextFormField, 'Lesson Title *'),
        'Indentation Test',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Lesson Body (plain text) *'),
        indentedBody,
      );
      await tester.tap(find.text('Create Lesson'));
      await tester.pumpAndSettle();

      verify(
        () => repository.createTextLesson(
          20,
          51,
          title: 'Indentation Test',
          body: indentedBody,
          position: 1,
          isRequired: true,
          cancelToken: any(named: 'cancelToken'),
        ),
      ).called(1);
    });

    testWidgets(
      'preserves trailing newline characters when submitting lesson body',
      (tester) async {
        const trailingNewlineBody = 'Line with trailing newlines\n\n\n';
        when(
          () => repository.createTextLesson(
            20,
            51,
            title: 'Trailing Newline Test',
            body: trailingNewlineBody,
            position: 1,
            isRequired: true,
            cancelToken: any(named: 'cancelToken'),
          ),
        ).thenAnswer(
          (_) async => ManagedTextLessonDetail.fromJson(
            managedTextLessonDetailJson(
              id: 102,
              title: 'Trailing Newline Test',
              body: trailingNewlineBody,
            ),
          ),
        );

        await launch(tester);

        await tester.enterText(
          find.widgetWithText(TextFormField, 'Lesson Title *'),
          'Trailing Newline Test',
        );
        await tester.enterText(
          find.widgetWithText(TextFormField, 'Lesson Body (plain text) *'),
          trailingNewlineBody,
        );
        await tester.tap(find.text('Create Lesson'));
        await tester.pumpAndSettle();

        verify(
          () => repository.createTextLesson(
            20,
            51,
            title: 'Trailing Newline Test',
            body: trailingNewlineBody,
            position: 1,
            isRequired: true,
            cancelToken: any(named: 'cancelToken'),
          ),
        ).called(1);
      },
    );

    testWidgets('preserves multiple intentional blank lines in lesson body', (
      tester,
    ) async {
      const multilineBlankBody = 'Section 1\n\n\n\nSection 2';
      when(
        () => repository.createTextLesson(
          20,
          51,
          title: 'Blank Lines Test',
          body: multilineBlankBody,
          position: 1,
          isRequired: true,
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer(
        (_) async => ManagedTextLessonDetail.fromJson(
          managedTextLessonDetailJson(
            id: 103,
            title: 'Blank Lines Test',
            body: multilineBlankBody,
          ),
        ),
      );

      await launch(tester);

      await tester.enterText(
        find.widgetWithText(TextFormField, 'Lesson Title *'),
        'Blank Lines Test',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Lesson Body (plain text) *'),
        multilineBlankBody,
      );
      await tester.tap(find.text('Create Lesson'));
      await tester.pumpAndSettle();

      verify(
        () => repository.createTextLesson(
          20,
          51,
          title: 'Blank Lines Test',
          body: multilineBlankBody,
          position: 1,
          isRequired: true,
          cancelToken: any(named: 'cancelToken'),
        ),
      ).called(1);
    });

    testWidgets('rejects whitespace-only required body content', (
      tester,
    ) async {
      await launch(tester);

      await tester.enterText(
        find.widgetWithText(TextFormField, 'Lesson Title *'),
        'Whitespace Test',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Lesson Body (plain text) *'),
        '   \n\t  \n  ',
      );
      await tester.tap(find.text('Create Lesson'));
      await tester.pumpAndSettle();

      expect(find.text('Lesson body is required.'), findsOneWidget);
      verifyNever(
        () => repository.createTextLesson(
          any(),
          any(),
          title: any(named: 'title'),
          body: any(named: 'body'),
          position: any(named: 'position'),
          isRequired: any(named: 'isRequired'),
          cancelToken: any(named: 'cancelToken'),
        ),
      );
    });
  });

  group('TextLessonFormScreen - Edit text lesson', () {
    testWidgets('prefills fields from ManagedTextLessonDetail extra', (
      tester,
    ) async {
      final detail = ManagedTextLessonDetail.fromJson(
        managedTextLessonDetailJson(
          id: 90,
          moduleId: 51,
          trainingVersionId: 20,
          title: 'Full Lesson Detail',
          body: 'Loaded body content.',
          position: 4,
          isRequired: false,
        ),
      );

      await launch(
        tester,
        path: '/workspace/training/versions/20/modules/51/lessons/90/edit',
        extra: detail,
      );

      expect(find.text('Edit text lesson'), findsOneWidget);
      expect(find.text('Full Lesson Detail'), findsOneWidget);
      expect(find.text('Loaded body content.'), findsOneWidget);
      expect(find.text('4'), findsOneWidget);
      expect(find.text('Save Changes'), findsOneWidget);
    });

    testWidgets('prefills from ManagedLessonSummary and loads body via API', (
      tester,
    ) async {
      final summary = ManagedLessonSummary.fromJson(
        managedLessonSummaryJson(
          id: 90,
          title: 'Summary Title',
          lessonType: 'TEXT',
          order: 1,
          isRequired: true,
        ),
      );

      await launch(
        tester,
        path: '/workspace/training/versions/20/modules/51/lessons/90/edit',
        extra: summary,
      );

      expect(find.text('Edit text lesson'), findsOneWidget);
      expect(find.text('Workplace Protocols'), findsOneWidget);
      expect(
        find.text('Detailed procedures and emergency steps.'),
        findsOneWidget,
      );
    });

    testWidgets('blocks editing when extra is a VIDEO lesson summary', (
      tester,
    ) async {
      final videoSummary = ManagedLessonSummary.fromJson(
        managedLessonSummaryJson(
          id: 99,
          title: 'Safety Video',
          lessonType: 'VIDEO',
          order: 1,
        ),
      );

      await launch(
        tester,
        path: '/workspace/training/versions/20/modules/51/lessons/99/edit',
        extra: videoSummary,
      );

      expect(find.text('Edit lesson'), findsOneWidget);
      expect(
        find.text(
          'Video lessons cannot be edited through text lesson authoring.',
        ),
        findsOneWidget,
      );
      expect(find.byType(TextFormField), findsNothing);
    });

    testWidgets('modifying a field enables save and updates lesson', (
      tester,
    ) async {
      when(
        () => repository.updateTextLesson(
          20,
          51,
          90,
          title: any(named: 'title'),
          body: 'Updated body text.',
          position: any(named: 'position'),
          isRequired: any(named: 'isRequired'),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer(
        (_) async => ManagedTextLessonDetail.fromJson(
          managedTextLessonDetailJson(
            id: 90,
            moduleId: 51,
            trainingVersionId: 20,
            body: 'Updated body text.',
          ),
        ),
      );

      final detail = ManagedTextLessonDetail.fromJson(
        managedTextLessonDetailJson(
          id: 90,
          moduleId: 51,
          trainingVersionId: 20,
          body: 'Initial body.',
        ),
      );

      await launch(
        tester,
        path: '/workspace/training/versions/20/modules/51/lessons/90/edit',
        extra: detail,
      );

      await tester.enterText(
        find.widgetWithText(TextFormField, 'Lesson Body (plain text) *'),
        'Updated body text.',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save Changes'));
      await tester.pumpAndSettle();

      expect(find.text('Text lesson updated successfully.'), findsOneWidget);
    });

    testWidgets('loading failure in Edit renders ApiErrorView and retries', (
      tester,
    ) async {
      var fail = true;
      when(
        () => repository.textLessonDetail(
          20,
          51,
          99,
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer((_) async {
        if (fail) {
          throw ApiError(
            message: 'Lesson not found or not draft.',
            statusCode: 500,
          );
        }
        return ManagedTextLessonDetail.fromJson(
          managedTextLessonDetailJson(
            id: 99,
            moduleId: 51,
            trainingVersionId: 20,
            title: 'Recovered Lesson',
          ),
        );
      });

      await launch(
        tester,
        path: '/workspace/training/versions/20/modules/51/lessons/99/edit',
      );

      expect(find.text('Lesson not found or not draft.'), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);

      fail = false;
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();

      expect(find.text('Recovered Lesson'), findsOneWidget);
    });

    testWidgets(
      'unchanged edit form with trailing newline remains clean and does not trigger discard confirmation or send PATCH',
      (tester) async {
        const bodyWithNewline = 'Existing procedure guidelines.\n\n';
        final detail = ManagedTextLessonDetail.fromJson(
          managedTextLessonDetailJson(
            id: 90,
            moduleId: 51,
            trainingVersionId: 20,
            title: 'Unchanged Form',
            body: bodyWithNewline,
            position: 1,
            isRequired: true,
          ),
        );

        await launch(tester, path: '/workspace/training/versions/20');
        router.push(
          '/workspace/training/versions/20/modules/51/lessons/90/edit',
          extra: detail,
        );
        await tester.pumpAndSettle();

        // Save button is disabled because form is clean
        final saveButton = tester.widget<FilledButton>(
          find.widgetWithText(FilledButton, 'Save Changes'),
        );
        expect(saveButton.onPressed, isNull);

        // Cancel pops without discard dialog
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();

        expect(find.text('Discard unsaved changes?'), findsNothing);
        expect(find.byType(TextLessonFormScreen), findsNothing);

        verifyNever(
          () => repository.updateTextLesson(
            any(),
            any(),
            any(),
            title: any(named: 'title'),
            body: any(named: 'body'),
            position: any(named: 'position'),
            isRequired: any(named: 'isRequired'),
            cancelToken: any(named: 'cancelToken'),
          ),
        );
      },
    );

    testWidgets(
      'editing other fields does not unexpectedly trim or submit the body',
      (tester) async {
        const bodyWithWhitespace = '   Indented code sample\n\n';
        final detail = ManagedTextLessonDetail.fromJson(
          managedTextLessonDetailJson(
            id: 90,
            moduleId: 51,
            trainingVersionId: 20,
            title: 'Old Title',
            body: bodyWithWhitespace,
            position: 1,
            isRequired: true,
          ),
        );

        when(
          () => repository.updateTextLesson(
            20,
            51,
            90,
            title: 'New Title',
            body: null,
            position: null,
            isRequired: null,
            cancelToken: any(named: 'cancelToken'),
          ),
        ).thenAnswer(
          (_) async => ManagedTextLessonDetail.fromJson(
            managedTextLessonDetailJson(
              id: 90,
              moduleId: 51,
              trainingVersionId: 20,
              title: 'New Title',
              body: bodyWithWhitespace,
            ),
          ),
        );

        await launch(
          tester,
          path: '/workspace/training/versions/20/modules/51/lessons/90/edit',
          extra: detail,
        );

        await tester.enterText(
          find.widgetWithText(TextFormField, 'Lesson Title *'),
          'New Title',
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Save Changes'));
        await tester.pumpAndSettle();

        // Verify update was called with body: null, not trimmed body
        verify(
          () => repository.updateTextLesson(
            20,
            51,
            90,
            title: 'New Title',
            body: null,
            position: null,
            isRequired: null,
            cancelToken: any(named: 'cancelToken'),
          ),
        ).called(1);
      },
    );

    testWidgets(
      'submitting modified body with leading indentation and trailing newlines preserves formatting in PATCH',
      (tester) async {
        const updatedBody = '  Leading two spaces\nLine 2\n\n';
        final detail = ManagedTextLessonDetail.fromJson(
          managedTextLessonDetailJson(
            id: 90,
            moduleId: 51,
            trainingVersionId: 20,
            title: 'Original Title',
            body: 'Old Body',
          ),
        );

        when(
          () => repository.updateTextLesson(
            20,
            51,
            90,
            title: null,
            body: updatedBody,
            position: null,
            isRequired: null,
            cancelToken: any(named: 'cancelToken'),
          ),
        ).thenAnswer(
          (_) async => ManagedTextLessonDetail.fromJson(
            managedTextLessonDetailJson(
              id: 90,
              moduleId: 51,
              trainingVersionId: 20,
              body: updatedBody,
            ),
          ),
        );

        await launch(
          tester,
          path: '/workspace/training/versions/20/modules/51/lessons/90/edit',
          extra: detail,
        );

        await tester.enterText(
          find.widgetWithText(TextFormField, 'Lesson Body (plain text) *'),
          updatedBody,
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Save Changes'));
        await tester.pumpAndSettle();

        verify(
          () => repository.updateTextLesson(
            20,
            51,
            90,
            title: null,
            body: updatedBody,
            position: null,
            isRequired: null,
            cancelToken: any(named: 'cancelToken'),
          ),
        ).called(1);
      },
    );

    testWidgets(
      'rebuilding widget after typing does not reset text controllers',
      (tester) async {
        await launch(tester);

        await tester.enterText(
          find.widgetWithText(TextFormField, 'Lesson Title *'),
          'Typed Title',
        );
        await tester.enterText(
          find.widgetWithText(TextFormField, 'Lesson Body (plain text) *'),
          'Typed Body Content',
        );

        // Toggle isRequired switch which triggers setState and widget rebuild
        await tester.tap(find.byType(Switch));
        await tester.pump();

        expect(find.text('Typed Title'), findsOneWidget);
        expect(find.text('Typed Body Content'), findsOneWidget);
      },
    );

    testWidgets('no route extra loads detail asynchronously from repository', (
      tester,
    ) async {
      await launch(
        tester,
        path: '/workspace/training/versions/20/modules/51/lessons/90/edit',
        extra: null,
      );

      expect(find.text('Edit text lesson'), findsOneWidget);
      expect(find.text('Workplace Protocols'), findsOneWidget);
      expect(
        find.text('Detailed procedures and emergency steps.'),
        findsOneWidget,
      );
      expect(find.text('1'), findsOneWidget);
    });
  });

  group('TextLessonFormScreen - Permissions & Router Guard', () {
    testWidgets(
      'router redirects away when identity lacks training.add_lesson',
      (tester) async {
        await launch(
          tester,
          path: '/workspace/training/versions/20/modules/51/lessons/new',
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

    testWidgets(
      'router redirects away when identity lacks training.change_lesson',
      (tester) async {
        await launch(
          tester,
          path: '/workspace/training/versions/20/modules/51/lessons/90/edit',
          identity: managementIdentity(
            capabilities: {
              'management_workspace',
              'training.view_trainingversion',
              'training.view_module',
              'training.view_lesson',
            },
          ),
        );

        expect(router.state.matchedLocation, '/workspace');
      },
    );

    testWidgets(
      'router redirects away when identity has training.change_lesson but lacks training.view_lesson',
      (tester) async {
        await launch(
          tester,
          path: '/workspace/training/versions/20/modules/51/lessons/90/edit',
          identity: managementIdentity(
            capabilities: {
              'management_workspace',
              'training.view_trainingversion',
              'training.view_module',
              'training.change_lesson', // change only, NO view_lesson
            },
          ),
        );

        expect(router.state.matchedLocation, '/workspace');
      },
    );

    testWidgets(
      'router allows edit route when identity has both view_lesson and change_lesson',
      (tester) async {
        await launch(
          tester,
          path: '/workspace/training/versions/20/modules/51/lessons/90/edit',
          identity: managementIdentity(
            capabilities: {
              'management_workspace',
              'training.view_trainingversion',
              'training.view_module',
              'training.view_lesson',
              'training.change_lesson',
            },
          ),
        );

        expect(
          router.state.matchedLocation,
          '/workspace/training/versions/20/modules/51/lessons/90/edit',
        );
      },
    );

    testWidgets(
      'router allows creation route when identity has add_lesson, even without change_lesson',
      (tester) async {
        await launch(
          tester,
          path: '/workspace/training/versions/20/modules/51/lessons/new',
          identity: managementIdentity(
            capabilities: {
              'management_workspace',
              'training.view_trainingversion',
              'training.view_module',
              'training.add_lesson',
            },
          ),
        );

        expect(
          router.state.matchedLocation,
          '/workspace/training/versions/20/modules/51/lessons/new',
        );
      },
    );
  });

  group('TextLessonFormScreen - Navigation & Discard Dialog', () {
    testWidgets('tapping Cancel with dirty form prompts discard dialog', (
      tester,
    ) async {
      await launch(tester);

      await tester.enterText(
        find.widgetWithText(TextFormField, 'Lesson Title *'),
        'Unsaved edits',
      );
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(find.text('Discard unsaved changes?'), findsOneWidget);

      await tester.tap(find.text('Keep editing'));
      await tester.pumpAndSettle();

      expect(find.text('New text lesson'), findsOneWidget);
      expect(find.text('Unsaved edits'), findsOneWidget);
    });

    testWidgets('tapping Discard in dialog pops form screen', (tester) async {
      await launch(tester, path: '/workspace/training/versions/20');
      router.push('/workspace/training/versions/20/modules/51/lessons/new');
      await tester.pumpAndSettle();

      await tester.enterText(
        find.widgetWithText(TextFormField, 'Lesson Title *'),
        'Discard me',
      );
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(find.text('Discard unsaved changes?'), findsOneWidget);

      await tester.tap(find.text('Discard'));
      await tester.pumpAndSettle();

      expect(find.byType(TextLessonFormScreen), findsNothing);
    });

    testWidgets('cancels in-flight request when user account switches', (
      tester,
    ) async {
      final completer = Completer<ManagedTextLessonDetail>();
      CancelToken? token;
      when(
        () => repository.createTextLesson(
          20,
          51,
          title: any(named: 'title'),
          body: any(named: 'body'),
          position: any(named: 'position'),
          isRequired: any(named: 'isRequired'),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer((invocation) {
        token = invocation.namedArguments[#cancelToken] as CancelToken?;
        return completer.future;
      });

      await launch(tester);

      await tester.enterText(
        find.widgetWithText(TextFormField, 'Lesson Title *'),
        'Account Switch Test',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Lesson Body (plain text) *'),
        'Body content',
      );
      await tester.tap(find.text('Create Lesson'));
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
              'training.add_lesson',
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
      expect(find.text('New text lesson'), findsOneWidget);
    });

    testWidgets('fits small screen (320x640 at 2.0x text scale)', (
      tester,
    ) async {
      await launch(tester, size: const Size(320, 640), textScale: 2.0);
      expect(find.text('New text lesson'), findsOneWidget);
    });

    testWidgets('fits landscape screen (844x390 at 1.6x text scale)', (
      tester,
    ) async {
      await launch(tester, size: const Size(844, 390), textScale: 1.6);
      expect(find.text('New text lesson'), findsOneWidget);
    });
  });
}
