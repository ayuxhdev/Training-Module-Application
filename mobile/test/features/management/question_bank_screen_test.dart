import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';
import 'package:training_app/core/errors/api_error.dart';
import 'package:training_app/core/presentation/components/api_error_view.dart';
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
      () => repository.questions(
        page: any(named: 'page'),
        pageSize: any(named: 'pageSize'),
        search: any(named: 'search'),
        isActive: any(named: 'isActive'),
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenAnswer(
      (_) async => ManagementPage<ManagedQuestion>(
        count: 1,
        hasMore: false,
        items: [
          ManagedQuestion.fromJson(
            managedQuestionJson(
              id: 5,
              code: 'SEC-001',
              topic: 'Safety Protocols',
            ),
          ),
        ],
      ),
    );

    when(
      () => repository.questionDetail(
        any(),
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenAnswer(
      (_) async => ManagedQuestion.fromJson(
        managedQuestionJson(id: 5, code: 'SEC-001', topic: 'Safety Protocols'),
      ),
    );

    when(
      () => repository.questionRevisions(
        any(),
        page: any(named: 'page'),
        pageSize: any(named: 'pageSize'),
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenAnswer(
      (_) async => ManagementPage<ManagedQuestionRevisionSummary>(
        count: 1,
        hasMore: false,
        items: [
          ManagedQuestionRevisionSummary.fromJson(
            managedQuestionRevisionSummaryJson(
              id: 10,
              questionId: 5,
              revisionNumber: 1,
              status: 'DRAFT',
            ),
          ),
        ],
      ),
    );

    when(
      () => repository.questionRevisionDetail(
        any(),
        any(),
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenAnswer(
      (_) async => ManagedQuestionRevisionDetail.fromJson(
        managedQuestionRevisionDetailJson(
          id: 10,
          questionId: 5,
          revisionNumber: 1,
          status: 'DRAFT',
          prompt: 'What PPE is required when handling chemicals?',
        ),
      ),
    );
  });

  Future<ProviderContainer> launch(
    WidgetTester tester, {
    AuthenticatedIdentity? identity,
    String path = '/workspace/training/questions',
    ThemeMode themeMode = ThemeMode.light,
    Size size = const Size(800, 2400),
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
              'assessments.view_question',
              'assessments.add_question',
              'assessments.change_question',
              'assessments.view_questionrevision',
              'assessments.add_questionrevision',
              'assessments.change_questionrevision',
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
    router.go(path, extra: extra);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(
          routerConfig: router,
          theme: AppTheme.lightTheme,
          darkTheme: AppTheme.darkTheme,
          themeMode: themeMode,
        ),
      ),
    );
    await tester.pumpAndSettle();
    return container;
  }

  group('QuestionBankScreen', () {
    testWidgets('renders question list and filters', (tester) async {
      await launch(tester);

      expect(find.text('Question bank'), findsWidgets);
      expect(find.text('SEC-001'), findsOneWidget);
      expect(find.text('Safety Protocols'), findsOneWidget);
      expect(find.text('ACTIVE'), findsOneWidget);
      expect(find.text('All'), findsOneWidget);
      expect(find.text('Active only'), findsOneWidget);
      expect(find.text('Inactive only'), findsOneWidget);
    });

    testWidgets('tapping question navigates to QuestionDetailScreen', (
      tester,
    ) async {
      await launch(tester);

      await tester.tap(find.text('SEC-001'));
      await tester.pumpAndSettle();

      expect(find.text('Question details'), findsWidgets);
      expect(find.text('QUESTION ENTRY'), findsOneWidget);
      expect(find.text('Revision 1'), findsOneWidget);
    });
  });

  group('QuestionDetailScreen', () {
    testWidgets(
      'paginates question revision history beyond page one with retry on failure',
      (tester) async {
        var page2Calls = 0;
        when(
          () => repository.questionRevisions(
            5,
            page: 1,
            pageSize: any(named: 'pageSize'),
            cancelToken: any(named: 'cancelToken'),
          ),
        ).thenAnswer(
          (_) async => ManagementPage<ManagedQuestionRevisionSummary>(
            count: 25,
            hasMore: true,
            items: List.generate(
              20,
              (i) => ManagedQuestionRevisionSummary.fromJson(
                managedQuestionRevisionSummaryJson(
                  id: 100 + i,
                  questionId: 5,
                  revisionNumber: i + 1,
                  status: 'FROZEN',
                ),
              ),
            ),
          ),
        );

        when(
          () => repository.questionRevisions(
            5,
            page: 2,
            pageSize: any(named: 'pageSize'),
            cancelToken: any(named: 'cancelToken'),
          ),
        ).thenAnswer((_) async {
          page2Calls++;
          if (page2Calls == 1) {
            throw ApiError(
              code: 'SERVER_ERROR',
              message: 'Failed to fetch revision page 2',
            );
          }
          return ManagementPage<ManagedQuestionRevisionSummary>(
            count: 25,
            hasMore: false,
            items: List.generate(
              5,
              (i) => ManagedQuestionRevisionSummary.fromJson(
                managedQuestionRevisionSummaryJson(
                  id: 120 + i,
                  questionId: 5,
                  revisionNumber: 21 + i,
                  status: 'DRAFT',
                ),
              ),
            ),
          );
        });

        await launch(
          tester,
          path: '/workspace/training/questions/5',
          size: const Size(800, 3600),
        );

        expect(find.text('Revision 1'), findsOneWidget);
        expect(find.text('Revision 20'), findsOneWidget);
        expect(find.text('Page 1 · 25 total'), findsOneWidget);

        // Tap Next to navigate to page 2 (which fails initially)
        await tester.tap(find.widgetWithText(TextButton, 'Next'));
        await tester.pumpAndSettle();

        expect(
          find.textContaining('Failed to fetch revision page 2'),
          findsOneWidget,
        );
        expect(find.widgetWithText(TextButton, 'Retry'), findsOneWidget);

        // Tap Retry to reload page 2 successfully
        await tester.tap(find.widgetWithText(TextButton, 'Retry'));
        await tester.pumpAndSettle();

        expect(find.text('Revision 21'), findsOneWidget);
        expect(find.text('Revision 25'), findsOneWidget);
        expect(find.text('Page 2 · 25 total'), findsOneWidget);

        // Navigate back to Page 1
        await tester.tap(find.widgetWithText(TextButton, 'Previous'));
        await tester.pumpAndSettle();

        expect(find.text('Revision 1'), findsOneWidget);
        expect(find.text('Page 1 · 25 total'), findsOneWidget);
      },
    );
  });

  group('QuestionFormScreen', () {
    testWidgets('creates question and navigates to question detail', (
      tester,
    ) async {
      when(
        () => repository.createQuestion(
          code: any(named: 'code'),
          topic: any(named: 'topic'),
          isActive: any(named: 'isActive'),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer(
        (_) async => ManagedQuestion.fromJson(
          managedQuestionJson(id: 6, code: 'ENV-001', topic: 'Environmental'),
        ),
      );

      await launch(tester, path: '/workspace/training/questions/new');

      expect(find.text('Create question'), findsWidgets);

      // Validate required code
      await tester.tap(find.widgetWithText(FilledButton, 'Create question'));
      await tester.pumpAndSettle();

      expect(find.text('Question code is required.'), findsOneWidget);

      await tester.enterText(find.byType(TextFormField).first, 'ENV-001');
      await tester.enterText(
        find.byType(TextFormField).at(1),
        'Environmental Compliance',
      );
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(FilledButton, 'Create question'));
      await tester.pumpAndSettle();

      verify(
        () => repository.createQuestion(
          code: 'ENV-001',
          topic: 'Environmental Compliance',
          isActive: true,
          cancelToken: any(named: 'cancelToken'),
        ),
      ).called(1);
    });
  });

  group('QuestionRevisionDetailScreen', () {
    testWidgets('new draft prompt is empty and uses Draft question as hint', (
      tester,
    ) async {
      when(
        () => repository.questionRevisionDetail(
          any(),
          any(),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer(
        (_) async => ManagedQuestionRevisionDetail.fromJson(
          managedQuestionRevisionDetailJson(
            id: 10,
            questionId: 5,
            revisionNumber: 1,
            status: 'DRAFT',
            prompt: 'Draft question',
          ),
        ),
      );

      await launch(
        tester,
        path: '/workspace/training/questions/5/revisions/10',
      );

      final promptField = find.widgetWithText(TextFormField, 'Prompt *');
      expect(promptField, findsOneWidget);

      final field = tester.widget<TextFormField>(promptField);
      expect(field.controller?.text, isEmpty);
      final decoratorFinder = find.descendant(
        of: promptField,
        matching: find.byType(InputDecorator),
      );
      expect(decoratorFinder, findsOneWidget);
      final decorator = tester.widget<InputDecorator>(decoratorFinder);
      expect(decorator.decoration.hintText, 'Draft question');
    });

    testWidgets('existing draft retains its saved prompt', (tester) async {
      when(
        () => repository.questionRevisionDetail(
          any(),
          any(),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer(
        (_) async => ManagedQuestionRevisionDetail.fromJson(
          managedQuestionRevisionDetailJson(
            id: 10,
            questionId: 5,
            revisionNumber: 1,
            status: 'DRAFT',
            prompt: 'Saved question prompt',
          ),
        ),
      );

      await launch(
        tester,
        path: '/workspace/training/questions/5/revisions/10',
      );

      final promptField = find.widgetWithText(TextFormField, 'Prompt *');
      expect(promptField, findsOneWidget);

      final field = tester.widget<TextFormField>(promptField);
      expect(field.controller?.text, 'Saved question prompt');
      expect(find.text('Saved question prompt'), findsOneWidget);
    });

    testWidgets('untouched Draft question placeholder cannot be frozen', (
      tester,
    ) async {
      when(
        () => repository.questionRevisionDetail(
          any(),
          any(),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer(
        (_) async => ManagedQuestionRevisionDetail.fromJson(
          managedQuestionRevisionDetailJson(
            id: 10,
            questionId: 5,
            revisionNumber: 1,
            status: 'DRAFT',
            prompt: 'Draft question',
          ),
        ),
      );

      await launch(
        tester,
        path: '/workspace/training/questions/5/revisions/10',
      );

      await tester.tap(find.text('Freeze revision permanently'));
      await tester.pumpAndSettle();

      expect(find.text('Freeze revision?'), findsNothing);
      expect(find.text('Prompt is required.'), findsWidgets);
      verifyNever(
        () => repository.freezeQuestionRevision(
          any(),
          any(),
          cancelToken: any(named: 'cancelToken'),
        ),
      );
    });

    testWidgets(
      'internal whitespace placeholder variant is recognized and cannot be frozen',
      (tester) async {
        when(
          () => repository.questionRevisionDetail(
            any(),
            any(),
            cancelToken: any(named: 'cancelToken'),
          ),
        ).thenAnswer(
          (_) async => ManagedQuestionRevisionDetail.fromJson(
            managedQuestionRevisionDetailJson(
              id: 10,
              questionId: 5,
              revisionNumber: 1,
              status: 'DRAFT',
              prompt: '  Draft \t  question  ',
            ),
          ),
        );

        await launch(
          tester,
          path: '/workspace/training/questions/5/revisions/10',
        );

        final promptField = find.widgetWithText(TextFormField, 'Prompt *');
        expect(promptField, findsOneWidget);
        final field = tester.widget<TextFormField>(promptField);
        expect(field.controller?.text, isEmpty);

        // Attempt to enter internal whitespace variant and freeze
        await tester.enterText(promptField, 'Draft   question');
        await tester.pumpAndSettle();

        await tester.tap(find.text('Freeze revision permanently'));
        await tester.pumpAndSettle();

        expect(find.text('Freeze revision?'), findsNothing);
        expect(find.text('Prompt is required.'), findsWidgets);
        verifyNever(
          () => repository.freezeQuestionRevision(
            any(),
            any(),
            cancelToken: any(named: 'cancelToken'),
          ),
        );
      },
    );

    testWidgets(
      'permits saving other changes to an incomplete draft and preserves stored placeholder',
      (tester) async {
        when(
          () => repository.questionRevisionDetail(
            any(),
            any(),
            cancelToken: any(named: 'cancelToken'),
          ),
        ).thenAnswer(
          (_) async => ManagedQuestionRevisionDetail.fromJson(
            managedQuestionRevisionDetailJson(
              id: 10,
              questionId: 5,
              revisionNumber: 1,
              status: 'DRAFT',
              prompt: 'Draft question',
              explanation: 'Initial explanation',
            ),
          ),
        );
        when(
          () => repository.updateQuestionRevision(
            any(),
            any(),
            questionType: any(named: 'questionType'),
            prompt: any(named: 'prompt'),
            explanation: any(named: 'explanation'),
            options: any(named: 'options'),
            cancelToken: any(named: 'cancelToken'),
          ),
        ).thenAnswer(
          (_) async => ManagedQuestionRevisionDetail.fromJson(
            managedQuestionRevisionDetailJson(
              id: 10,
              questionId: 5,
              revisionNumber: 1,
              status: 'DRAFT',
              prompt: 'Draft question',
              explanation: 'Updated explanation',
            ),
          ),
        );

        await launch(
          tester,
          path: '/workspace/training/questions/5/revisions/10',
        );

        // Visible prompt is empty because placeholder is hidden
        final promptField = find.widgetWithText(TextFormField, 'Prompt *');
        expect(
          tester.widget<TextFormField>(promptField).controller?.text,
          isEmpty,
        );

        // Edit only the explanation
        final explanationField = find.widgetWithText(
          TextFormField,
          'Explanation (optional)',
        );
        await tester.enterText(explanationField, 'Updated explanation');
        await tester.pumpAndSettle();

        // Save draft changes: should succeed and send stored placeholder
        await tester.tap(find.text('Save draft changes'));
        await tester.pumpAndSettle();

        verify(
          () => repository.updateQuestionRevision(
            5,
            10,
            questionType: any(named: 'questionType'),
            prompt: 'Draft question',
            explanation: 'Updated explanation',
            options: any(named: 'options'),
            cancelToken: any(named: 'cancelToken'),
          ),
        ).called(1);
        expect(find.text('Revision saved successfully.'), findsOneWidget);
      },
    );

    testWidgets(
      'clearing prompt on an existing draft with real prompt blocks save with validation error',
      (tester) async {
        when(
          () => repository.questionRevisionDetail(
            any(),
            any(),
            cancelToken: any(named: 'cancelToken'),
          ),
        ).thenAnswer(
          (_) async => ManagedQuestionRevisionDetail.fromJson(
            managedQuestionRevisionDetailJson(
              id: 10,
              questionId: 5,
              revisionNumber: 1,
              status: 'DRAFT',
              prompt: 'Existing real prompt',
              explanation: 'Initial explanation',
            ),
          ),
        );

        await launch(
          tester,
          path: '/workspace/training/questions/5/revisions/10',
        );

        final promptField = find.widgetWithText(
          TextFormField,
          'Existing real prompt',
        );
        expect(promptField, findsOneWidget);

        // Clear the prompt field
        await tester.enterText(promptField, '');
        await tester.pumpAndSettle();

        // Attempt to save: should be blocked by form validator
        await tester.tap(find.text('Save draft changes'));
        await tester.pumpAndSettle();

        expect(find.text('Prompt is required.'), findsWidgets);
        verifyNever(
          () => repository.updateQuestionRevision(
            any(),
            any(),
            questionType: any(named: 'questionType'),
            prompt: any(named: 'prompt'),
            explanation: any(named: 'explanation'),
            options: any(named: 'options'),
            cancelToken: any(named: 'cancelToken'),
          ),
        );
      },
    );

    testWidgets('whitespace-only prompt cannot be frozen', (tester) async {
      await launch(
        tester,
        path: '/workspace/training/questions/5/revisions/10',
      );

      await tester.enterText(
        find.widgetWithText(
          TextFormField,
          'What PPE is required when handling chemicals?',
        ),
        '   ',
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Freeze revision permanently'));
      await tester.pumpAndSettle();

      expect(find.text('Freeze revision?'), findsNothing);
      expect(find.text('Prompt is required.'), findsWidgets);
      verifyNever(
        () => repository.freezeQuestionRevision(
          any(),
          any(),
          cancelToken: any(named: 'cancelToken'),
        ),
      );
    });

    testWidgets('valid prompt allows freezing', (tester) async {
      when(
        () => repository.freezeQuestionRevision(
          any(),
          any(),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer(
        (_) async => ManagedQuestionRevisionDetail.fromJson(
          managedQuestionRevisionDetailJson(
            id: 10,
            questionId: 5,
            status: 'FROZEN',
            frozenAt: '2026-10-31T12:00:00Z',
            prompt: 'A valid saved question prompt',
          ),
        ),
      );

      await launch(
        tester,
        path: '/workspace/training/questions/5/revisions/10',
      );

      await tester.tap(find.text('Freeze revision permanently'));
      await tester.pumpAndSettle();
      expect(find.text('Freeze revision?'), findsOneWidget);

      await tester.tap(find.text('Freeze permanently'));
      await tester.pumpAndSettle();

      verify(
        () => repository.freezeQuestionRevision(
          5,
          10,
          cancelToken: any(named: 'cancelToken'),
        ),
      ).called(1);
    });

    testWidgets('existing saved draft retains prompt and can be frozen', (
      tester,
    ) async {
      when(
        () => repository.questionRevisionDetail(
          any(),
          any(),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer(
        (_) async => ManagedQuestionRevisionDetail.fromJson(
          managedQuestionRevisionDetailJson(
            id: 10,
            questionId: 5,
            revisionNumber: 1,
            status: 'DRAFT',
            prompt: 'Saved draft prompt',
          ),
        ),
      );
      when(
        () => repository.freezeQuestionRevision(
          any(),
          any(),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer(
        (_) async => ManagedQuestionRevisionDetail.fromJson(
          managedQuestionRevisionDetailJson(
            id: 10,
            questionId: 5,
            status: 'FROZEN',
            frozenAt: '2026-10-31T12:00:00Z',
            prompt: 'Saved draft prompt',
          ),
        ),
      );

      await launch(
        tester,
        path: '/workspace/training/questions/5/revisions/10',
      );

      final promptField = find.widgetWithText(TextFormField, 'Prompt *');
      final field = tester.widget<TextFormField>(promptField);
      expect(field.controller?.text, 'Saved draft prompt');

      await tester.tap(find.text('Freeze revision permanently'));
      await tester.pumpAndSettle();
      expect(find.text('Freeze revision?'), findsOneWidget);

      await tester.tap(find.text('Freeze permanently'));
      await tester.pumpAndSettle();

      verify(
        () => repository.freezeQuestionRevision(
          5,
          10,
          cancelToken: any(named: 'cancelToken'),
        ),
      ).called(1);
    });

    testWidgets('renders prompt and options for draft revision', (
      tester,
    ) async {
      await launch(
        tester,
        path: '/workspace/training/questions/5/revisions/10',
      );

      expect(find.text('Revision 1'), findsWidgets);
      expect(
        find.text('What PPE is required when handling chemicals?'),
        findsOneWidget,
      );
      expect(find.text('Gloves and safety goggles'), findsOneWidget);
      expect(find.text('Save draft changes'), findsOneWidget);
      expect(find.text('Freeze revision permanently'), findsOneWidget);
    });

    testWidgets(
      'freezing revision prompts confirmation dialog and calls repository',
      (tester) async {
        when(
          () => repository.freezeQuestionRevision(
            any(),
            any(),
            cancelToken: any(named: 'cancelToken'),
          ),
        ).thenAnswer(
          (_) async => ManagedQuestionRevisionDetail.fromJson(
            managedQuestionRevisionDetailJson(
              id: 10,
              questionId: 5,
              status: 'FROZEN',
              frozenAt: '2026-10-31T12:00:00Z',
            ),
          ),
        );

        await launch(
          tester,
          path: '/workspace/training/questions/5/revisions/10',
        );

        await tester.tap(find.text('Freeze revision permanently'));
        await tester.pumpAndSettle();

        expect(find.text('Freeze revision?'), findsOneWidget);
        expect(
          find.text(
            'Freezing permanently locks this revision so it can never be edited or deleted. It will be available to attach to assessments. This operation cannot be undone.',
          ),
          findsOneWidget,
        );

        await tester.tap(find.text('Freeze permanently'));
        await tester.pumpAndSettle();

        verify(
          () => repository.freezeQuestionRevision(
            5,
            10,
            cancelToken: any(named: 'cancelToken'),
          ),
        ).called(1);

        expect(
          find.text('Revision frozen successfully and locked permanently.'),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'frozen revision displays locked banner and hides edit actions',
      (tester) async {
        when(
          () => repository.questionRevisionDetail(
            any(),
            any(),
            cancelToken: any(named: 'cancelToken'),
          ),
        ).thenAnswer(
          (_) async => ManagedQuestionRevisionDetail.fromJson(
            managedQuestionRevisionDetailJson(
              id: 10,
              questionId: 5,
              status: 'FROZEN',
              frozenAt: '2026-10-31T12:00:00Z',
            ),
          ),
        );

        await launch(
          tester,
          path: '/workspace/training/questions/5/revisions/10',
        );

        expect(
          find.text(
            'This revision is FROZEN. Answers and options are permanently locked and cannot be edited.',
          ),
          findsOneWidget,
        );
        expect(find.text('Save draft changes'), findsNothing);
        expect(find.text('Freeze revision permanently'), findsNothing);
        expect(find.text('Add option'), findsNothing);
      },
    );

    testWidgets(
      'navigation without initialSummary displays sensible title and updates to revision number',
      (tester) async {
        final completer = Completer<ManagedQuestionRevisionDetail>();
        when(
          () => repository.questionRevisionDetail(
            5,
            10,
            cancelToken: any(named: 'cancelToken'),
          ),
        ).thenAnswer((_) => completer.future);

        await launch(
          tester,
          path: '/workspace/training/questions/5/revisions/10',
          extra: null,
        );

        // Before async data resolves, title is sensible
        expect(
          find.descendant(
            of: find.byType(AppBar),
            matching: find.text('Revision details'),
          ),
          findsOneWidget,
        );
        expect(find.text('Revision '), findsNothing);

        // Resolve data with revisionNumber: 3
        completer.complete(
          ManagedQuestionRevisionDetail.fromJson(
            managedQuestionRevisionDetailJson(
              id: 10,
              questionId: 5,
              revisionNumber: 3,
              status: 'DRAFT',
              prompt: 'Sample prompt',
            ),
          ),
        );
        await tester.pumpAndSettle();

        // Title updates to loaded revision number in AppBar
        expect(
          find.descendant(
            of: find.byType(AppBar),
            matching: find.text('Revision 3'),
          ),
          findsOneWidget,
        );
      },
    );

    testWidgets('empty prompt prevents freezing and shows validation error', (
      tester,
    ) async {
      await launch(
        tester,
        path: '/workspace/training/questions/5/revisions/10',
      );

      // Clear the prompt
      await tester.enterText(
        find.widgetWithText(
          TextFormField,
          'What PPE is required when handling chemicals?',
        ),
        '',
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Freeze revision permanently'));
      await tester.pumpAndSettle();

      expect(find.text('Freeze revision?'), findsNothing);
      expect(find.text('Prompt is required.'), findsWidgets);

      verifyNever(
        () => repository.freezeQuestionRevision(
          any(),
          any(),
          cancelToken: any(named: 'cancelToken'),
        ),
      );
      verifyNever(
        () => repository.updateQuestionRevision(
          any(),
          any(),
          questionType: any(named: 'questionType'),
          prompt: any(named: 'prompt'),
          explanation: any(named: 'explanation'),
          options: any(named: 'options'),
          cancelToken: any(named: 'cancelToken'),
        ),
      );
    });

    testWidgets(
      'attempting freeze with empty prompt then valid prompt clears prompt errors and opens dialog',
      (tester) async {
        when(
          () => repository.freezeQuestionRevision(
            any(),
            any(),
            cancelToken: any(named: 'cancelToken'),
          ),
        ).thenAnswer(
          (_) async => ManagedQuestionRevisionDetail.fromJson(
            managedQuestionRevisionDetailJson(
              id: 10,
              questionId: 5,
              status: 'FROZEN',
              frozenAt: '2026-10-31T12:00:00Z',
              prompt: 'A valid question prompt',
            ),
          ),
        );

        await launch(
          tester,
          path: '/workspace/training/questions/5/revisions/10',
        );

        final promptFinder = find.widgetWithText(
          TextFormField,
          'What PPE is required when handling chemicals?',
        );

        // 1. Attempt freeze with an empty prompt
        await tester.enterText(promptFinder, '');
        await tester.pumpAndSettle();

        await tester.tap(find.text('Freeze revision permanently'));
        await tester.pumpAndSettle();

        // Confirmation dialog is blocked, field error and banner are shown
        expect(find.text('Freeze revision?'), findsNothing);
        expect(find.text('Prompt is required.'), findsWidgets);
        expect(
          find.byKey(const ValueKey('revision-error-banner')),
          findsOneWidget,
        );

        // 2. Enter a valid prompt and attempt freeze again
        await tester.enterText(
          find.byType(TextFormField).first,
          'A valid question prompt',
        );
        await tester.pumpAndSettle();

        await tester.tap(find.text('Freeze revision permanently'));
        await tester.pumpAndSettle();

        // Obsolete prompt field error and matching banner are cleared
        expect(find.text('Prompt is required.'), findsNothing);
        expect(
          find.byKey(const ValueKey('revision-error-banner')),
          findsNothing,
        );

        // Confirmation dialog is allowed to open
        expect(find.text('Freeze revision?'), findsOneWidget);
      },
    );

    testWidgets(
      'valid prompt freeze clears Prompt is required banner but preserves unrelated server error',
      (tester) async {
        when(
          () => repository.updateQuestionRevision(
            any(),
            any(),
            questionType: any(named: 'questionType'),
            prompt: any(named: 'prompt'),
            explanation: any(named: 'explanation'),
            options: any(named: 'options'),
            cancelToken: any(named: 'cancelToken'),
          ),
        ).thenThrow(
          ApiError(
            code: 'service_unavailable',
            message: 'Server currently offline.',
          ),
        );

        await launch(
          tester,
          path: '/workspace/training/questions/5/revisions/10',
        );

        // Trigger an unrelated server error by saving changes
        await tester.enterText(
          find.widgetWithText(
            TextFormField,
            'What PPE is required when handling chemicals?',
          ),
          'Modified prompt for save',
        );
        await tester.pumpAndSettle();

        await tester.tap(find.text('Save draft changes'));
        await tester.pumpAndSettle();

        // Verify unrelated server error is shown
        expect(
          find.descendant(
            of: find.byKey(const ValueKey('revision-error-banner')),
            matching: find.text('Server currently offline.'),
          ),
          findsOneWidget,
        );

        // Now attempt freeze with the valid prompt:
        // The unrelated server error must be preserved
        await tester.tap(find.text('Freeze revision permanently'));
        await tester.pumpAndSettle();

        // Dialog still opens because prompt and options are valid
        expect(find.text('Freeze revision?'), findsOneWidget);
        // And unrelated server error was not cleared by prompt validation
        expect(
          find.descendant(
            of: find.byKey(const ValueKey('revision-error-banner')),
            matching: find.text('Server currently offline.'),
          ),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'invalid options (fewer than 2 active options) prevents freezing',
      (tester) async {
        when(
          () => repository.questionRevisionDetail(
            5,
            10,
            cancelToken: any(named: 'cancelToken'),
          ),
        ).thenAnswer(
          (_) async => ManagedQuestionRevisionDetail.fromJson(
            managedQuestionRevisionDetailJson(
              id: 10,
              questionId: 5,
              revisionNumber: 1,
              status: 'DRAFT',
              prompt: 'Sample prompt',
              options: [
                managedQuestionOptionJson(
                  id: 101,
                  text: 'Only option',
                  position: 1,
                  isCorrect: true,
                ),
              ],
            ),
          ),
        );

        await launch(
          tester,
          path: '/workspace/training/questions/5/revisions/10',
        );

        await tester.tap(find.text('Freeze revision permanently'));
        await tester.pumpAndSettle();

        verifyNever(
          () => repository.freezeQuestionRevision(
            any(),
            any(),
            cancelToken: any(named: 'cancelToken'),
          ),
        );
        verifyNever(
          () => repository.updateQuestionRevision(
            any(),
            any(),
            questionType: any(named: 'questionType'),
            prompt: any(named: 'prompt'),
            explanation: any(named: 'explanation'),
            options: any(named: 'options'),
            cancelToken: any(named: 'cancelToken'),
          ),
        );
        expect(
          find.descendant(
            of: find.byType(SnackBar),
            matching: find.text(
              'A frozen question needs at least two options and exactly one correct option.',
            ),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: find.byKey(const ValueKey('revision-error-banner')),
            matching: find.text(
              'A frozen question needs at least two options and exactly one correct option.',
            ),
          ),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'validation error on mobile viewport (390x844) is visible in SnackBar near bottom and in banner at top',
      (tester) async {
        when(
          () => repository.questionRevisionDetail(
            5,
            10,
            cancelToken: any(named: 'cancelToken'),
          ),
        ).thenAnswer(
          (_) async => ManagedQuestionRevisionDetail.fromJson(
            managedQuestionRevisionDetailJson(
              id: 10,
              questionId: 5,
              revisionNumber: 1,
              status: 'DRAFT',
              prompt: 'Sample prompt for mobile viewport test',
              options: [
                managedQuestionOptionJson(
                  id: 101,
                  text: 'Only option',
                  position: 1,
                  isCorrect: true,
                ),
              ],
            ),
          ),
        );

        await launch(
          tester,
          path: '/workspace/training/questions/5/revisions/10',
          size: const Size(390, 844),
        );

        // Scroll down to the Freeze button at the bottom of the form
        await tester.drag(find.byType(ListView), const Offset(0, -500));
        await tester.pumpAndSettle();

        // The freeze button is visible
        expect(find.text('Freeze revision permanently'), findsOneWidget);

        // Tap freeze - triggers validation failure (only 1 option)
        await tester.tap(find.text('Freeze revision permanently'));
        await tester.pumpAndSettle();

        // Verify that the error SnackBar is immediately visible on screen WITHOUT scrolling
        expect(
          find.descendant(
            of: find.byType(SnackBar),
            matching: find.text(
              'A frozen question needs at least two options and exactly one correct option.',
            ),
          ),
          findsOneWidget,
        );

        // Verify no API call occurred
        verifyNever(
          () => repository.freezeQuestionRevision(
            any(),
            any(),
            cancelToken: any(named: 'cancelToken'),
          ),
        );
        verifyNever(
          () => repository.updateQuestionRevision(
            any(),
            any(),
            questionType: any(named: 'questionType'),
            prompt: any(named: 'prompt'),
            explanation: any(named: 'explanation'),
            options: any(named: 'options'),
            cancelToken: any(named: 'cancelToken'),
          ),
        );

        // Now scroll back to top and verify the banner also displays the error
        await tester.drag(find.byType(ListView), const Offset(0, 500));
        await tester.pumpAndSettle();

        expect(
          find.descendant(
            of: find.byKey(const ValueKey('revision-error-banner')),
            matching: find.text(
              'A frozen question needs at least two options and exactly one correct option.',
            ),
          ),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'matcher accurately detects unwanted update call on invalid prompt and matches successful save call',
      (tester) async {
        when(
          () => repository.updateQuestionRevision(
            any(),
            any(),
            questionType: any(named: 'questionType'),
            prompt: any(named: 'prompt'),
            explanation: any(named: 'explanation'),
            options: any(named: 'options'),
            cancelToken: any(named: 'cancelToken'),
          ),
        ).thenAnswer(
          (_) async => ManagedQuestionRevisionDetail.fromJson(
            managedQuestionRevisionDetailJson(
              id: 10,
              questionId: 5,
              revisionNumber: 1,
              status: 'DRAFT',
              prompt: 'Valid updated prompt',
            ),
          ),
        );

        await launch(
          tester,
          path: '/workspace/training/questions/5/revisions/10',
        );

        final promptFinder = find.widgetWithText(TextFormField, 'Prompt *');
        expect(promptFinder, findsOneWidget);

        // 1. Enter empty prompt and attempt to save
        await tester.enterText(promptFinder, '');
        await tester.pumpAndSettle();

        await tester.tap(find.text('Save draft changes'));
        await tester.pumpAndSettle();

        expect(find.text('Prompt is required.'), findsOneWidget);
        verifyNever(
          () => repository.updateQuestionRevision(
            any(),
            any(),
            questionType: any(named: 'questionType'),
            prompt: any(named: 'prompt'),
            explanation: any(named: 'explanation'),
            options: any(named: 'options'),
            cancelToken: any(named: 'cancelToken'),
          ),
        );

        // 2. Enter a valid prompt and save
        expect(promptFinder, findsOneWidget);
        await tester.enterText(promptFinder, 'Valid updated prompt');
        await tester.pumpAndSettle();

        await tester.tap(find.text('Save draft changes'));
        await tester.pumpAndSettle();

        // Demonstrates the exact same Mocktail matcher detects the real invocation
        verify(
          () => repository.updateQuestionRevision(
            5,
            10,
            questionType: any(named: 'questionType'),
            prompt: 'Valid updated prompt',
            explanation: any(named: 'explanation'),
            options: any(named: 'options'),
            cancelToken: any(named: 'cancelToken'),
          ),
        ).called(1);
      },
    );

    testWidgets(
      'prompt finder remains unique and stable when prompt and explanation are both empty',
      (tester) async {
        when(
          () => repository.questionRevisionDetail(
            any(),
            any(),
            cancelToken: any(named: 'cancelToken'),
          ),
        ).thenAnswer(
          (_) async => ManagedQuestionRevisionDetail.fromJson(
            managedQuestionRevisionDetailJson(
              id: 10,
              questionId: 5,
              revisionNumber: 1,
              status: 'DRAFT',
              prompt: 'Initial prompt text',
              explanation: '',
            ),
          ),
        );

        await launch(
          tester,
          path: '/workspace/training/questions/5/revisions/10',
        );

        final promptFinder = find.widgetWithText(TextFormField, 'Prompt *');
        final explanationFinder = find.widgetWithText(
          TextFormField,
          'Explanation (optional)',
        );

        // Explanation is initially empty, prompt is filled:
        expect(promptFinder, findsOneWidget);
        expect(explanationFinder, findsOneWidget);

        // Clear prompt so both prompt and explanation are empty:
        await tester.enterText(promptFinder, '');
        await tester.pumpAndSettle();

        // Both fields are empty, but label-based finders remain unambiguous:
        expect(promptFinder, findsOneWidget);
        expect(explanationFinder, findsOneWidget);

        // Ambiguous finder find.widgetWithText(TextFormField, '') matches multiple:
        final ambiguousEmptyFinder = find.widgetWithText(TextFormField, '');
        expect(ambiguousEmptyFinder.evaluate().length, greaterThanOrEqualTo(2));

        // Re-enter valid prompt text using promptFinder without ambiguity:
        await tester.enterText(promptFinder, 'Re-entered valid prompt');
        await tester.pumpAndSettle();

        expect(promptFinder, findsOneWidget);
        expect(find.text('Re-entered valid prompt'), findsOneWidget);
      },
    );

    testWidgets(
      'widget disposal during save completes safely without post-disposal errors',
      (tester) async {
        final completer = Completer<ManagedQuestionRevisionDetail>();
        when(
          () => repository.updateQuestionRevision(
            any(),
            any(),
            questionType: any(named: 'questionType'),
            prompt: any(named: 'prompt'),
            explanation: any(named: 'explanation'),
            options: any(named: 'options'),
            cancelToken: any(named: 'cancelToken'),
          ),
        ).thenAnswer((_) => completer.future);

        await launch(
          tester,
          path: '/workspace/training/questions/5/revisions/10',
        );

        // Make dirty
        await tester.enterText(
          find.widgetWithText(
            TextFormField,
            'What PPE is required when handling chemicals?',
          ),
          'Updated prompt pending save',
        );
        await tester.pumpAndSettle();

        // Trigger save
        await tester.tap(find.text('Save draft changes'));
        await tester.pump(); // Start save, future is pending

        // Unmount widget (simulate navigation away or disposal)
        await tester.pumpWidget(const SizedBox.shrink());

        // Complete the pending future after disposal
        completer.complete(
          ManagedQuestionRevisionDetail.fromJson(
            managedQuestionRevisionDetailJson(
              id: 10,
              questionId: 5,
              revisionNumber: 1,
              status: 'DRAFT',
              prompt: 'Updated prompt pending save',
            ),
          ),
        );
        await tester.pumpAndSettle();
      },
    );

    testWidgets('Save API failure on dirty form prevents freezing', (
      tester,
    ) async {
      when(
        () => repository.updateQuestionRevision(
          any(),
          any(),
          questionType: any(named: 'questionType'),
          prompt: any(named: 'prompt'),
          explanation: any(named: 'explanation'),
          options: any(named: 'options'),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenThrow(
        ApiError(
          message: 'Invalid option payload from server.',
          statusCode: 400,
        ),
      );

      await launch(
        tester,
        path: '/workspace/training/questions/5/revisions/10',
      );

      // Make dirty
      await tester.enterText(
        find.widgetWithText(
          TextFormField,
          'What PPE is required when handling chemicals?',
        ),
        'Updated prompt text',
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Freeze revision permanently'));
      await tester.pumpAndSettle();

      expect(find.text('Freeze revision?'), findsOneWidget);
      await tester.tap(find.text('Freeze permanently'));
      await tester.pumpAndSettle();

      verifyNever(
        () => repository.freezeQuestionRevision(
          any(),
          any(),
          cancelToken: any(named: 'cancelToken'),
        ),
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('revision-error-banner')),
          matching: find.text('Invalid option payload from server.'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byType(SnackBar),
          matching: find.text('Invalid option payload from server.'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('failed post-save re-read prevents freezing', (tester) async {
      var callCount = 0;
      when(
        () => repository.questionRevisionDetail(
          any(),
          any(),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer((_) async {
        callCount++;
        if (callCount > 1) {
          throw ApiError(message: 'Re-read failed', statusCode: 500);
        }
        return ManagedQuestionRevisionDetail.fromJson(
          managedQuestionRevisionDetailJson(
            id: 10,
            questionId: 5,
            revisionNumber: 1,
            status: 'DRAFT',
          ),
        );
      });

      when(
        () => repository.updateQuestionRevision(
          any(),
          any(),
          questionType: any(named: 'questionType'),
          prompt: any(named: 'prompt'),
          explanation: any(named: 'explanation'),
          options: any(named: 'options'),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer(
        (_) async => ManagedQuestionRevisionDetail.fromJson(
          managedQuestionRevisionDetailJson(
            id: 10,
            questionId: 5,
            revisionNumber: 1,
            status: 'DRAFT',
          ),
        ),
      );

      await launch(
        tester,
        path: '/workspace/training/questions/5/revisions/10',
      );

      // Make dirty
      await tester.enterText(
        find.widgetWithText(
          TextFormField,
          'What PPE is required when handling chemicals?',
        ),
        'Updated prompt text',
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Freeze revision permanently'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Freeze permanently'));
      await tester.pumpAndSettle();

      verifyNever(
        () => repository.freezeQuestionRevision(
          any(),
          any(),
          cancelToken: any(named: 'cancelToken'),
        ),
      );
      expect(
        find.descendant(
          of: find.byType(ApiErrorView),
          matching: find.text('Re-read failed'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byType(SnackBar),
          matching: find.text('Re-read failed'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('successful dirty save proceeds to freezing exactly once', (
      tester,
    ) async {
      when(
        () => repository.updateQuestionRevision(
          any(),
          any(),
          questionType: any(named: 'questionType'),
          prompt: any(named: 'prompt'),
          explanation: any(named: 'explanation'),
          options: any(named: 'options'),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer(
        (_) async => ManagedQuestionRevisionDetail.fromJson(
          managedQuestionRevisionDetailJson(
            id: 10,
            questionId: 5,
            revisionNumber: 1,
            status: 'DRAFT',
            prompt: 'Updated prompt text',
          ),
        ),
      );

      when(
        () => repository.freezeQuestionRevision(
          any(),
          any(),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer(
        (_) async => ManagedQuestionRevisionDetail.fromJson(
          managedQuestionRevisionDetailJson(
            id: 10,
            questionId: 5,
            revisionNumber: 1,
            status: 'FROZEN',
            frozenAt: '2026-10-31T12:00:00Z',
            prompt: 'Updated prompt text',
          ),
        ),
      );

      await launch(
        tester,
        path: '/workspace/training/questions/5/revisions/10',
      );

      // Make dirty
      await tester.enterText(
        find.widgetWithText(
          TextFormField,
          'What PPE is required when handling chemicals?',
        ),
        'Updated prompt text',
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Freeze revision permanently'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Freeze permanently'));
      await tester.pumpAndSettle();

      verify(
        () => repository.updateQuestionRevision(
          5,
          10,
          questionType: any(named: 'questionType'),
          prompt: 'Updated prompt text',
          explanation: any(named: 'explanation'),
          options: any(named: 'options'),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).called(1);

      verify(
        () => repository.freezeQuestionRevision(
          5,
          10,
          cancelToken: any(named: 'cancelToken'),
        ),
      ).called(1);

      expect(
        find.text('Revision frozen successfully and locked permanently.'),
        findsOneWidget,
      );
    });

    testWidgets(
      'empty True/False draft initializes locally and supports deselection and freezing',
      (tester) async {
        var detail = ManagedQuestionRevisionDetail.fromJson(
          managedQuestionRevisionDetailJson(
            id: 10,
            questionId: 5,
            questionType: 'TRUE_FALSE',
            status: 'DRAFT',
            prompt: 'New True/False prompt',
            options: [],
          ),
        );
        List<Map<String, dynamic>>? savedOptions;
        when(
          () => repository.questionRevisionDetail(
            5,
            10,
            cancelToken: any(named: 'cancelToken'),
          ),
        ).thenAnswer((_) async => detail);
        when(
          () => repository.updateQuestionRevision(
            5,
            10,
            questionType: any(named: 'questionType'),
            prompt: any(named: 'prompt'),
            explanation: any(named: 'explanation'),
            options: any(named: 'options'),
            cancelToken: any(named: 'cancelToken'),
          ),
        ).thenAnswer((call) async {
          savedOptions =
              call.namedArguments[#options] as List<Map<String, dynamic>>;
          detail = ManagedQuestionRevisionDetail.fromJson(
            managedQuestionRevisionDetailJson(
              id: 10,
              questionId: 5,
              questionType: 'TRUE_FALSE',
              status: 'DRAFT',
              prompt: 'New True/False prompt',
              options: [
                for (var i = 0; i < savedOptions!.length; i++)
                  {
                    ...savedOptions![i],
                    'id': savedOptions![i]['id'] ?? 201 + i,
                  },
              ],
            ),
          );
          return detail;
        });
        when(
          () => repository.freezeQuestionRevision(
            5,
            10,
            cancelToken: any(named: 'cancelToken'),
          ),
        ).thenAnswer((_) async => detail);
        await launch(
          tester,
          path: '/workspace/training/questions/5/revisions/10',
        );
        final yes = find.byKey(const ValueKey('correct-option-true'));
        final no = find.byKey(const ValueKey('correct-option-false'));
        expect(find.text('True'), findsOneWidget);
        expect(find.text('False'), findsOneWidget);
        expect(tester.widget<Checkbox>(yes).value, isFalse);
        expect(tester.widget<Checkbox>(no).value, isFalse);
        verifyNever(
          () => repository.updateQuestionRevision(
            any(),
            any(),
            questionType: any(named: 'questionType'),
            prompt: any(named: 'prompt'),
            explanation: any(named: 'explanation'),
            options: any(named: 'options'),
            cancelToken: any(named: 'cancelToken'),
          ),
        );
        await tester.tap(yes);
        await tester.pumpAndSettle();
        expect(tester.widget<Checkbox>(yes).value, isTrue);
        expect(tester.widget<Checkbox>(no).value, isFalse);
        await tester.tap(yes);
        await tester.pumpAndSettle();
        expect(tester.widget<Checkbox>(yes).value, isFalse);
        await tester.tap(yes);
        await tester.pumpAndSettle();
        await tester.tap(no);
        await tester.pumpAndSettle();
        expect(tester.widget<Checkbox>(yes).value, isFalse);
        expect(tester.widget<Checkbox>(no).value, isTrue);
        await tester.tap(no);
        await tester.pumpAndSettle();
        expect(tester.widget<Checkbox>(no).value, isFalse);
        await tester.tap(find.text('Save draft changes'));
        await tester.pumpAndSettle();
        expect(savedOptions!.map((o) => o['text']), ['True', 'False']);
        expect(savedOptions!.every((o) => o['is_correct'] == false), isTrue);
        expect(savedOptions!.every((o) => !o.containsKey('id')), isTrue);
        expect(find.text('Revision saved successfully.'), findsOneWidget);
        await tester.tap(find.text('Freeze revision permanently'));
        await tester.pumpAndSettle();
        expect(find.text('Freeze revision?'), findsNothing);
        verifyNever(
          () => repository.freezeQuestionRevision(
            5,
            10,
            cancelToken: any(named: 'cancelToken'),
          ),
        );
        await tester.tap(no);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Freeze revision permanently'));
        await tester.pumpAndSettle();
        expect(find.text('Freeze revision?'), findsOneWidget);
        await tester.tap(find.text('Freeze permanently'));
        await tester.pumpAndSettle();
        expect(
          savedOptions!.where((o) => o['is_correct'] == true),
          hasLength(1),
        );
        expect(
          savedOptions!.singleWhere((o) => o['is_correct'] == true)['text'],
          'False',
        );
        expect(savedOptions!.map((o) => o['id']), [201, 202]);
        verify(
          () => repository.freezeQuestionRevision(
            5,
            10,
            cancelToken: any(named: 'cancelToken'),
          ),
        ).called(1);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'saved True/False answer can be deselected without changing the other answer',
      (tester) async {
        when(
          () => repository.questionRevisionDetail(
            5,
            10,
            cancelToken: any(named: 'cancelToken'),
          ),
        ).thenAnswer(
          (_) async => ManagedQuestionRevisionDetail.fromJson(
            managedQuestionRevisionDetailJson(
              id: 10,
              questionId: 5,
              questionType: 'TRUE_FALSE',
              status: 'DRAFT',
              prompt: 'Saved prompt',
              options: [
                managedQuestionOptionJson(
                  id: 201,
                  text: 'True',
                  position: 1,
                  isCorrect: true,
                ),
                managedQuestionOptionJson(
                  id: 202,
                  text: 'False',
                  position: 2,
                  isCorrect: false,
                ),
              ],
            ),
          ),
        );
        await launch(
          tester,
          path: '/workspace/training/questions/5/revisions/10',
        );
        final yes = find.byKey(const ValueKey('correct-option-true'));
        final no = find.byKey(const ValueKey('correct-option-false'));
        expect(tester.widget<Checkbox>(yes).value, isTrue);
        await tester.tap(yes);
        await tester.pumpAndSettle();
        expect(tester.widget<Checkbox>(yes).value, isFalse);
        expect(tester.widget<Checkbox>(no).value, isFalse);
      },
    );

    testWidgets(
      'True/False with three answers cannot freeze even with one correct answer',
      (tester) async {
        when(
          () => repository.questionRevisionDetail(
            5,
            10,
            cancelToken: any(named: 'cancelToken'),
          ),
        ).thenAnswer(
          (_) async => ManagedQuestionRevisionDetail.fromJson(
            managedQuestionRevisionDetailJson(
              id: 10,
              questionId: 5,
              questionType: 'TRUE_FALSE',
              status: 'DRAFT',
              prompt: 'Valid prompt',
              options: [
                managedQuestionOptionJson(
                  id: 201,
                  text: 'True',
                  position: 1,
                  isCorrect: true,
                ),
                managedQuestionOptionJson(
                  id: 202,
                  text: 'False',
                  position: 2,
                  isCorrect: false,
                ),
                managedQuestionOptionJson(
                  id: 203,
                  text: 'True',
                  position: 3,
                  isCorrect: false,
                ),
              ],
            ),
          ),
        );
        await launch(
          tester,
          path: '/workspace/training/questions/5/revisions/10',
        );
        await tester.tap(find.text('Freeze revision permanently'));
        await tester.pumpAndSettle();
        expect(find.text('Freeze revision?'), findsNothing);
        expect(
          find.text(
            'True/false questions require exactly the True and False options.',
          ),
          findsWidgets,
        );
        verifyNever(
          () => repository.freezeQuestionRevision(
            5,
            10,
            cancelToken: any(named: 'cancelToken'),
          ),
        );
      },
    );

    for (final extraOption in [false, true]) {
      testWidgets(
        'invalid True/False structure repairs explicitly and preserves IDs and edits (extra=$extraOption)',
        (tester) async {
          var detail = ManagedQuestionRevisionDetail.fromJson(
            managedQuestionRevisionDetailJson(
              id: 10,
              questionId: 5,
              questionType: 'TRUE_FALSE',
              status: 'DRAFT',
              prompt: 'Saved prompt',
              options: [
                managedQuestionOptionJson(
                  id: 201,
                  text: extraOption ? 'True' : 'Yes',
                  position: 1,
                  isCorrect: true,
                ),
                managedQuestionOptionJson(
                  id: 202,
                  text: 'False',
                  position: 2,
                  isCorrect: false,
                ),
                if (extraOption)
                  managedQuestionOptionJson(
                    id: 203,
                    text: 'Legacy option',
                    position: 3,
                    isCorrect: false,
                  ),
              ],
            ),
          );
          List<Map<String, dynamic>>? savedOptions;
          when(
            () => repository.questionRevisionDetail(
              5,
              10,
              cancelToken: any(named: 'cancelToken'),
            ),
          ).thenAnswer((_) async => detail);
          when(
            () => repository.updateQuestionRevision(
              5,
              10,
              questionType: any(named: 'questionType'),
              prompt: any(named: 'prompt'),
              explanation: any(named: 'explanation'),
              options: any(named: 'options'),
              cancelToken: any(named: 'cancelToken'),
            ),
          ).thenAnswer((call) async {
            savedOptions =
                call.namedArguments[#options] as List<Map<String, dynamic>>;
            expect(call.namedArguments[#prompt], 'Unsaved author edit');
            detail = ManagedQuestionRevisionDetail.fromJson(
              managedQuestionRevisionDetailJson(
                id: 10,
                questionId: 5,
                questionType: 'TRUE_FALSE',
                status: 'DRAFT',
                prompt: 'Unsaved author edit',
                options: savedOptions!
                    .where((o) => o['delete'] != true)
                    .toList(),
              ),
            );
            return detail;
          });
          await launch(
            tester,
            path: '/workspace/training/questions/5/revisions/10',
          );
          expect(
            find.text(extraOption ? 'Legacy option' : 'Yes'),
            findsOneWidget,
          );
          expect(
            find.textContaining('Use Edit, Remove or Add option'),
            findsOneWidget,
          );
          expect(
            find.widgetWithText(FilledButton, 'Add option'),
            findsOneWidget,
          );
          verifyNever(
            () => repository.updateQuestionRevision(
              any(),
              any(),
              questionType: any(named: 'questionType'),
              prompt: any(named: 'prompt'),
              explanation: any(named: 'explanation'),
              options: any(named: 'options'),
              cancelToken: any(named: 'cancelToken'),
            ),
          );
          await tester.enterText(
            find.widgetWithText(TextFormField, 'Saved prompt'),
            'Unsaved author edit',
          );
          if (extraOption) {
            await tester.tap(find.byTooltip('Remove option').last);
            await tester.pumpAndSettle();
          } else {
            await tester.tap(find.byTooltip('Edit option').first);
            await tester.pumpAndSettle();
            final dialog = find.byType(AlertDialog);
            await tester.enterText(
              find
                  .descendant(of: dialog, matching: find.byType(TextField))
                  .first,
              'True',
            );
            expect(
              tester
                  .widget<CheckboxListTile>(find.byType(CheckboxListTile))
                  .value,
              isTrue,
            );
            await tester.tap(find.widgetWithText(FilledButton, 'Save option'));
            await tester.pumpAndSettle();
          }
          expect(find.byTooltip('Edit option'), findsNothing);
          expect(find.byTooltip('Remove option'), findsNothing);
          expect(find.text('Add option'), findsNothing);
          expect(
            tester
                .widget<Checkbox>(
                  find.byKey(const ValueKey('correct-option-true')),
                )
                .value,
            isTrue,
          );
          expect(
            tester
                .widget<Checkbox>(
                  find.byKey(const ValueKey('correct-option-false')),
                )
                .value,
            isFalse,
          );
          await tester.tap(find.text('Save draft changes'));
          await tester.pumpAndSettle();
          expect(
            savedOptions!.where((o) => o['delete'] != true).map((o) => o['id']),
            [201, 202],
          );
          expect(
            savedOptions!.singleWhere((o) => o['id'] == 201)['is_correct'],
            isTrue,
          );
          if (extraOption) {
            expect(savedOptions!.singleWhere((o) => o['id'] == 203), {
              'id': 203,
              'delete': true,
            });
          } else {
            expect(savedOptions!.any((o) => o['delete'] == true), isFalse);
          }
          expect(find.text('Unsaved author edit'), findsOneWidget);
          expect(find.text('Revision saved successfully.'), findsOneWidget);
        },
      );
    }

    testWidgets(
      'switching to True/False preserves nonempty options and unsaved author edits',
      (tester) async {
        await launch(
          tester,
          path: '/workspace/training/questions/5/revisions/10',
        );
        final before = find.byType(TextFormField).first;
        await tester.enterText(before, 'Keep this unsaved prompt');
        await tester.tap(find.text('Single choice (Multiple choice)').last);
        await tester.pumpAndSettle();
        await tester.tap(find.text('True / False').last);
        await tester.pumpAndSettle();
        expect(find.text('No PPE required'), findsOneWidget);
        expect(find.text('True'), findsNothing);
        expect(find.text('False'), findsNothing);
        expect(find.text('Keep this unsaved prompt'), findsOneWidget);
        expect(find.byTooltip('Edit option'), findsNWidgets(2));
        expect(
          find.textContaining('Use Edit, Remove or Add option'),
          findsOneWidget,
        );
        await tester.tap(find.text('True / False').last);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Single choice (Multiple choice)').last);
        await tester.pumpAndSettle();
        expect(find.text('No PPE required'), findsOneWidget);
        expect(find.text('Keep this unsaved prompt'), findsOneWidget);
        verifyNever(
          () => repository.updateQuestionRevision(
            any(),
            any(),
            questionType: any(named: 'questionType'),
            prompt: any(named: 'prompt'),
            explanation: any(named: 'explanation'),
            options: any(named: 'options'),
            cancelToken: any(named: 'cancelToken'),
          ),
        );
      },
    );

    testWidgets(
      'view-only True/False draft does not initialize or expose editing controls',
      (tester) async {
        when(
          () => repository.questionRevisionDetail(
            5,
            10,
            cancelToken: any(named: 'cancelToken'),
          ),
        ).thenAnswer(
          (_) async => ManagedQuestionRevisionDetail.fromJson(
            managedQuestionRevisionDetailJson(
              id: 10,
              questionId: 5,
              questionType: 'TRUE_FALSE',
              status: 'DRAFT',
              options: [],
            ),
          ),
        );
        await launch(
          tester,
          path: '/workspace/training/questions/5/revisions/10',
          identity: managementIdentity(
            capabilities: {
              'management_workspace',
              'assessments.view_questionrevision',
            },
          ),
        );
        expect(
          find.text('No options configured for this revision.'),
          findsOneWidget,
        );
        expect(find.text('True'), findsNothing);
        expect(find.text('False'), findsNothing);
        expect(find.text('Add option'), findsNothing);
        expect(find.text('Save draft changes'), findsNothing);
        expect(find.byType(Checkbox), findsNothing);
        verifyNever(
          () => repository.updateQuestionRevision(
            any(),
            any(),
            questionType: any(named: 'questionType'),
            prompt: any(named: 'prompt'),
            explanation: any(named: 'explanation'),
            options: any(named: 'options'),
            cancelToken: any(named: 'cancelToken'),
          ),
        );
      },
    );

    for (final empty in [true, false]) {
      testWidgets(
        'frozen True/False remains read-only without local setup (empty=$empty)',
        (tester) async {
          when(
            () => repository.questionRevisionDetail(
              5,
              10,
              cancelToken: any(named: 'cancelToken'),
            ),
          ).thenAnswer(
            (_) async => ManagedQuestionRevisionDetail.fromJson(
              managedQuestionRevisionDetailJson(
                id: 10,
                questionId: 5,
                questionType: 'TRUE_FALSE',
                status: 'FROZEN',
                options: empty
                    ? []
                    : [
                        managedQuestionOptionJson(
                          id: 201,
                          text: 'True',
                          position: 1,
                          isCorrect: true,
                        ),
                        managedQuestionOptionJson(
                          id: 202,
                          text: 'False',
                          position: 2,
                          isCorrect: false,
                        ),
                      ],
              ),
            ),
          );
          await launch(
            tester,
            path: '/workspace/training/questions/5/revisions/10',
          );
          expect(find.text('True'), empty ? findsNothing : findsOneWidget);
          expect(find.text('False'), empty ? findsNothing : findsOneWidget);
          expect(find.byType(Checkbox), findsNothing);
          expect(find.byTooltip('Edit option'), findsNothing);
          expect(find.byTooltip('Remove option'), findsNothing);
          expect(find.text('Add option'), findsNothing);
          expect(find.text('Save draft changes'), findsNothing);
          expect(find.text('Freeze revision permanently'), findsNothing);
          verifyNever(
            () => repository.updateQuestionRevision(
              any(),
              any(),
              questionType: any(named: 'questionType'),
              prompt: any(named: 'prompt'),
              explanation: any(named: 'explanation'),
              options: any(named: 'options'),
              cancelToken: any(named: 'cancelToken'),
            ),
          );
        },
      );
    }

    testWidgets(
      'changing question type to TRUE_FALSE creates two unchecked options without Add Option',
      (tester) async {
        when(
          () => repository.questionRevisionDetail(
            5,
            10,
            cancelToken: any(named: 'cancelToken'),
          ),
        ).thenAnswer(
          (_) async => ManagedQuestionRevisionDetail.fromJson(
            managedQuestionRevisionDetailJson(
              id: 10,
              questionId: 5,
              prompt: 'What PPE is required when handling chemicals?',
              options: [],
            ),
          ),
        );
        List<Map<String, dynamic>>? capturedOptions;
        when(
          () => repository.updateQuestionRevision(
            any(),
            any(),
            questionType: any(named: 'questionType'),
            prompt: any(named: 'prompt'),
            explanation: any(named: 'explanation'),
            options: any(named: 'options'),
            cancelToken: any(named: 'cancelToken'),
          ),
        ).thenAnswer((invocation) async {
          capturedOptions =
              invocation.namedArguments[#options]
                  as List<Map<String, dynamic>>?;
          return ManagedQuestionRevisionDetail.fromJson(
            managedQuestionRevisionDetailJson(
              id: 10,
              questionId: 5,
              revisionNumber: 1,
              questionType: 'TRUE_FALSE',
              status: 'DRAFT',
              prompt: 'What PPE is required when handling chemicals?',
              options: [
                managedQuestionOptionJson(
                  id: 201,
                  text: 'True',
                  position: 1,
                  isCorrect: true,
                ),
                managedQuestionOptionJson(
                  id: 202,
                  text: 'False',
                  position: 2,
                  isCorrect: false,
                ),
              ],
            ),
          );
        });

        await launch(
          tester,
          path: '/workspace/training/questions/5/revisions/10',
        );

        // Change dropdown to TRUE_FALSE
        await tester.tap(find.text('Single choice (Multiple choice)').last);
        await tester.pumpAndSettle();
        await tester.tap(find.text('True / False').last);
        await tester.pumpAndSettle();

        expect(find.text('True'), findsOneWidget);
        expect(find.text('False'), findsOneWidget);
        expect(find.text('Add option'), findsNothing);
        expect(find.byTooltip('Remove option'), findsNothing);
        expect(find.byTooltip('Edit option'), findsNothing);

        final trueCorrect = find.byKey(const ValueKey('correct-option-true'));
        final falseCorrect = find.byKey(const ValueKey('correct-option-false'));
        expect(tester.widget<Checkbox>(trueCorrect).value, isFalse);
        expect(tester.widget<Checkbox>(falseCorrect).value, isFalse);
        await tester.tap(trueCorrect);
        await tester.pumpAndSettle();
        expect(tester.widget<Checkbox>(trueCorrect).value, isTrue);
        expect(tester.widget<Checkbox>(falseCorrect).value, isFalse);

        await tester.tap(find.text('Save draft changes'));
        await tester.pumpAndSettle();

        verify(
          () => repository.updateQuestionRevision(
            5,
            10,
            questionType: 'TRUE_FALSE',
            prompt: any(named: 'prompt'),
            explanation: any(named: 'explanation'),
            options: any(named: 'options'),
            cancelToken: any(named: 'cancelToken'),
          ),
        ).called(1);

        expect(capturedOptions, isNotNull);
        final activeCapturedOptions = capturedOptions!
            .where((option) => !option.containsKey('delete'))
            .toList();
        expect(activeCapturedOptions.length, 2);
        expect(
          activeCapturedOptions.where((option) => option['is_correct'] == true),
          hasLength(1),
        );
        expect(
          activeCapturedOptions.singleWhere(
            (option) => option['text'] == 'True',
          )['is_correct'],
          isTrue,
        );
        expect(find.text('Revision saved successfully.'), findsOneWidget);
      },
    );

    testWidgets(
      'True/False no-correct draft can save incompletely but cannot freeze',
      (tester) async {
        when(
          () => repository.questionRevisionDetail(
            5,
            10,
            cancelToken: any(named: 'cancelToken'),
          ),
        ).thenAnswer(
          (_) async => ManagedQuestionRevisionDetail.fromJson(
            managedQuestionRevisionDetailJson(
              id: 10,
              questionId: 5,
              revisionNumber: 1,
              questionType: 'TRUE_FALSE',
              status: 'DRAFT',
              prompt: 'Incomplete draft',
              options: [
                managedQuestionOptionJson(
                  id: 201,
                  text: 'True',
                  position: 1,
                  isCorrect: false,
                ),
                managedQuestionOptionJson(
                  id: 202,
                  text: 'False',
                  position: 2,
                  isCorrect: false,
                ),
              ],
            ),
          ),
        );
        when(
          () => repository.updateQuestionRevision(
            any(),
            any(),
            questionType: any(named: 'questionType'),
            prompt: any(named: 'prompt'),
            explanation: any(named: 'explanation'),
            options: any(named: 'options'),
            cancelToken: any(named: 'cancelToken'),
          ),
        ).thenAnswer(
          (_) async => ManagedQuestionRevisionDetail.fromJson(
            managedQuestionRevisionDetailJson(
              id: 10,
              questionId: 5,
              revisionNumber: 1,
              questionType: 'TRUE_FALSE',
              status: 'DRAFT',
              prompt: 'Incomplete draft',
              options: [
                managedQuestionOptionJson(
                  id: 201,
                  text: 'True',
                  position: 1,
                  isCorrect: false,
                ),
                managedQuestionOptionJson(
                  id: 202,
                  text: 'False',
                  position: 2,
                  isCorrect: false,
                ),
              ],
            ),
          ),
        );

        await launch(
          tester,
          path: '/workspace/training/questions/5/revisions/10',
        );

        await tester.tap(find.text('Save draft changes'));
        await tester.pumpAndSettle();
        expect(find.text('Revision saved successfully.'), findsOneWidget);

        await tester.tap(find.text('Freeze revision permanently'));
        await tester.pumpAndSettle();
        expect(find.text('Freeze revision?'), findsNothing);
        verifyNever(
          () => repository.freezeQuestionRevision(
            any(),
            any(),
            cancelToken: any(named: 'cancelToken'),
          ),
        );
      },
    );

    testWidgets(
      'existing True/False draft preserves its saved correct answer',
      (tester) async {
        when(
          () => repository.questionRevisionDetail(
            5,
            10,
            cancelToken: any(named: 'cancelToken'),
          ),
        ).thenAnswer(
          (_) async => ManagedQuestionRevisionDetail.fromJson(
            managedQuestionRevisionDetailJson(
              id: 10,
              questionId: 5,
              revisionNumber: 1,
              questionType: 'TRUE_FALSE',
              status: 'DRAFT',
              prompt: 'Saved True/False prompt',
              options: [
                managedQuestionOptionJson(
                  id: 201,
                  text: 'True',
                  position: 1,
                  isCorrect: false,
                ),
                managedQuestionOptionJson(
                  id: 202,
                  text: 'False',
                  position: 2,
                  isCorrect: true,
                ),
              ],
            ),
          ),
        );

        await launch(
          tester,
          path: '/workspace/training/questions/5/revisions/10',
        );

        expect(find.text('Saved True/False prompt'), findsOneWidget);
        expect(find.text('Add option'), findsNothing);
        expect(
          tester
              .widget<Checkbox>(
                find.byKey(const ValueKey('correct-option-true')),
              )
              .value,
          isFalse,
        );
        expect(
          tester
              .widget<Checkbox>(
                find.byKey(const ValueKey('correct-option-false')),
              )
              .value,
          isTrue,
        );
      },
    );

    testWidgets(
      'adding new option sends payload without id field and preserves existing option IDs',
      (tester) async {
        List<Map<String, dynamic>>? capturedOptions;
        when(
          () => repository.updateQuestionRevision(
            any(),
            any(),
            questionType: any(named: 'questionType'),
            prompt: any(named: 'prompt'),
            explanation: any(named: 'explanation'),
            options: any(named: 'options'),
            cancelToken: any(named: 'cancelToken'),
          ),
        ).thenAnswer((invocation) async {
          capturedOptions =
              invocation.namedArguments[#options]
                  as List<Map<String, dynamic>>?;
          return ManagedQuestionRevisionDetail.fromJson(
            managedQuestionRevisionDetailJson(
              id: 10,
              questionId: 5,
              revisionNumber: 1,
              status: 'DRAFT',
            ),
          );
        });

        await launch(
          tester,
          path: '/workspace/training/questions/5/revisions/10',
        );

        await tester.tap(find.widgetWithText(FilledButton, 'Add option'));
        await tester.pumpAndSettle();

        expect(
          find.descendant(
            of: find.byType(AlertDialog),
            matching: find.text('Add option'),
          ),
          findsOneWidget,
        );
        await tester.enterText(
          find.widgetWithText(TextField, 'Option text *'),
          'Full respirator mask',
        );
        await tester.tap(find.widgetWithText(FilledButton, 'Save option'));
        await tester.pumpAndSettle();

        expect(find.text('Full respirator mask'), findsOneWidget);

        await tester.tap(find.text('Save draft changes'));
        await tester.pumpAndSettle();

        expect(capturedOptions, isNotNull);
        final existingOpt = capturedOptions!.firstWhere((o) => o['id'] == 101);
        expect(existingOpt['text'], 'Gloves and safety goggles');

        final newOpt = capturedOptions!.firstWhere(
          (o) => o['text'] == 'Full respirator mask',
        );
        expect(newOpt.containsKey('id'), isFalse);
        expect(newOpt['position'], 3);
        expect(newOpt['is_correct'], false);
      },
    );

    testWidgets(
      'removing newly added unsaved option drops it and never sends deletion to server',
      (tester) async {
        List<Map<String, dynamic>>? capturedOptions;
        when(
          () => repository.updateQuestionRevision(
            any(),
            any(),
            questionType: any(named: 'questionType'),
            prompt: any(named: 'prompt'),
            explanation: any(named: 'explanation'),
            options: any(named: 'options'),
            cancelToken: any(named: 'cancelToken'),
          ),
        ).thenAnswer((invocation) async {
          capturedOptions =
              invocation.namedArguments[#options]
                  as List<Map<String, dynamic>>?;
          return ManagedQuestionRevisionDetail.fromJson(
            managedQuestionRevisionDetailJson(
              id: 10,
              questionId: 5,
              revisionNumber: 1,
              status: 'DRAFT',
            ),
          );
        });

        await launch(
          tester,
          path: '/workspace/training/questions/5/revisions/10',
        );

        await tester.tap(find.widgetWithText(FilledButton, 'Add option'));
        await tester.pumpAndSettle();

        await tester.enterText(
          find.widgetWithText(TextField, 'Option text *'),
          'Temporary choice',
        );
        await tester.tap(find.widgetWithText(FilledButton, 'Save option'));
        await tester.pumpAndSettle();

        expect(find.text('Temporary choice'), findsOneWidget);

        // Delete the temporary choice
        await tester.tap(find.byIcon(Icons.delete_outline).last);
        await tester.pumpAndSettle();

        expect(find.text('Temporary choice'), findsNothing);

        // Make dirty by editing prompt
        await tester.enterText(
          find.widgetWithText(
            TextFormField,
            'What PPE is required when handling chemicals?',
          ),
          'Updated prompt text',
        );
        await tester.pumpAndSettle();

        await tester.tap(find.text('Save draft changes'));
        await tester.pumpAndSettle();

        expect(capturedOptions, isNotNull);
        expect(
          capturedOptions!.any((o) => o['text'] == 'Temporary choice'),
          isFalse,
        );
        expect(
          capturedOptions!.any(
            (o) => !o.containsKey('id') && o['delete'] == true,
          ),
          isFalse,
        );
      },
    );

    testWidgets('deleting an existing option sends {id: <id>, delete: true}', (
      tester,
    ) async {
      List<Map<String, dynamic>>? capturedOptions;
      when(
        () => repository.updateQuestionRevision(
          any(),
          any(),
          questionType: any(named: 'questionType'),
          prompt: any(named: 'prompt'),
          explanation: any(named: 'explanation'),
          options: any(named: 'options'),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer((invocation) async {
        capturedOptions =
            invocation.namedArguments[#options] as List<Map<String, dynamic>>?;
        return ManagedQuestionRevisionDetail.fromJson(
          managedQuestionRevisionDetailJson(
            id: 10,
            questionId: 5,
            revisionNumber: 1,
            status: 'DRAFT',
          ),
        );
      });

      await launch(
        tester,
        path: '/workspace/training/questions/5/revisions/10',
      );

      // Delete the second option (id: 102, 'No PPE required')
      await tester.tap(find.byIcon(Icons.delete_outline).at(1));
      await tester.pumpAndSettle();

      expect(find.text('No PPE required'), findsNothing);

      await tester.tap(find.text('Save draft changes'));
      await tester.pumpAndSettle();

      expect(capturedOptions, isNotNull);
      final deletedOpt = capturedOptions!.firstWhere((o) => o['id'] == 102);
      expect(deletedOpt['delete'], isTrue);
      expect(deletedOpt.containsKey('text'), isFalse);
    });

    testWidgets(
      'Finding 3 — save with nested fields.options list error surfaces formatted message in banner and SnackBar on 390x844 viewport',
      (tester) async {
        when(
          () => repository.updateQuestionRevision(
            any(),
            any(),
            questionType: any(named: 'questionType'),
            prompt: any(named: 'prompt'),
            explanation: any(named: 'explanation'),
            options: any(named: 'options'),
            cancelToken: any(named: 'cancelToken'),
          ),
        ).thenThrow(
          ApiError(
            code: 'VALIDATION_ERROR',
            message: 'Invalid options',
            details: const {
              'fields': {
                'options': [
                  {
                    'position': ['Position must be unique among options.'],
                  },
                ],
              },
            },
          ),
        );

        await launch(
          tester,
          path: '/workspace/training/questions/5/revisions/10',
          size: const Size(390, 844),
        );

        // Enter prompt text to make dirty
        await tester.enterText(
          find.widgetWithText(
            TextFormField,
            'What PPE is required when handling chemicals?',
          ),
          'Updated prompt with duplicate position',
        );
        await tester.pumpAndSettle();

        // Drag from top of screen so the focused TextFormField doesn't capture the gesture
        await tester.dragFrom(const Offset(200, 100), const Offset(0, -600));
        await tester.pumpAndSettle();

        await tester.tap(find.text('Save draft changes'));
        await tester.pumpAndSettle();

        const expectedError =
            'Option 1: Position: Position must be unique among options.';

        // SnackBar is immediately visible on 390x844
        expect(
          find.descendant(
            of: find.byType(SnackBar),
            matching: find.text(expectedError),
          ),
          findsOneWidget,
        );

        // Scroll back to top to view error banner
        await tester.dragFrom(const Offset(200, 500), const Offset(0, 600));
        await tester.pumpAndSettle();

        // Error banner is also populated
        expect(
          find.descendant(
            of: find.byKey(const ValueKey('revision-error-banner')),
            matching: find.text(expectedError),
          ),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'Finding 3 — save with nested fields.options map error surfaces message in banner and SnackBar',
      (tester) async {
        when(
          () => repository.updateQuestionRevision(
            any(),
            any(),
            questionType: any(named: 'questionType'),
            prompt: any(named: 'prompt'),
            explanation: any(named: 'explanation'),
            options: any(named: 'options'),
            cancelToken: any(named: 'cancelToken'),
          ),
        ).thenThrow(
          ApiError(
            code: 'VALIDATION_ERROR',
            message: 'Invalid options',
            details: const {
              'fields': {
                'options': {
                  'non_field_errors': [
                    'Option ID 999 does not belong to this revision.',
                  ],
                },
              },
            },
          ),
        );

        await launch(
          tester,
          path: '/workspace/training/questions/5/revisions/10',
          size: const Size(390, 844),
        );

        // Make dirty
        await tester.enterText(
          find.widgetWithText(
            TextFormField,
            'What PPE is required when handling chemicals?',
          ),
          'Updated prompt text',
        );
        await tester.pumpAndSettle();

        // Drag from top of screen so the focused TextFormField doesn't capture the gesture
        await tester.dragFrom(const Offset(200, 100), const Offset(0, -600));
        await tester.pumpAndSettle();

        await tester.tap(find.text('Save draft changes'));
        await tester.pumpAndSettle();

        const expectedError = 'Option ID 999 does not belong to this revision.';

        expect(
          find.descendant(
            of: find.byType(SnackBar),
            matching: find.text(expectedError),
          ),
          findsOneWidget,
        );

        // Scroll back to top to view error banner
        await tester.dragFrom(const Offset(200, 500), const Offset(0, 600));
        await tester.pumpAndSettle();

        expect(
          find.descendant(
            of: find.byKey(const ValueKey('revision-error-banner')),
            matching: find.text(expectedError),
          ),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'Finding 3 — freeze revision aborts permanently when save changes fails with option error',
      (tester) async {
        when(
          () => repository.updateQuestionRevision(
            any(),
            any(),
            questionType: any(named: 'questionType'),
            prompt: any(named: 'prompt'),
            explanation: any(named: 'explanation'),
            options: any(named: 'options'),
            cancelToken: any(named: 'cancelToken'),
          ),
        ).thenThrow(
          ApiError(
            code: 'VALIDATION_ERROR',
            message: 'Validation failed',
            details: const {
              'options': [
                {
                  'text': ['Option text cannot be blank.'],
                },
              ],
            },
          ),
        );

        await launch(
          tester,
          path: '/workspace/training/questions/5/revisions/10',
        );

        // Make dirty
        await tester.enterText(
          find.widgetWithText(
            TextFormField,
            'What PPE is required when handling chemicals?',
          ),
          'Updated prompt text',
        );
        await tester.pumpAndSettle();

        // Tap freeze - triggers confirm dialog
        await tester.tap(find.text('Freeze revision permanently'));
        await tester.pumpAndSettle();

        expect(find.text('Freeze revision?'), findsOneWidget);

        // Confirm freeze - saves first, which fails!
        await tester.tap(find.text('Freeze permanently'));
        await tester.pumpAndSettle();

        // freezeQuestionRevision was NEVER called
        verifyNever(
          () => repository.freezeQuestionRevision(
            any(),
            any(),
            cancelToken: any(named: 'cancelToken'),
          ),
        );

        const expectedError = 'Option 1: Text: Option text cannot be blank.';

        expect(
          find.descendant(
            of: find.byType(SnackBar),
            matching: find.text(expectedError),
          ),
          findsOneWidget,
        );

        // Scroll back to top to view error banner
        await tester.dragFrom(const Offset(200, 500), const Offset(0, 600));
        await tester.pumpAndSettle();

        expect(
          find.descendant(
            of: find.byKey(const ValueKey('revision-error-banner')),
            matching: find.text(expectedError),
          ),
          findsOneWidget,
        );
      },
    );
  });
}
