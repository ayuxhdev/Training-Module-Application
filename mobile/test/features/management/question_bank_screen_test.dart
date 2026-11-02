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

      expect(find.text('Prompt is required.'), findsOneWidget);
    });

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
      'changing question type to TRUE_FALSE applies preset and persists via PATCH',
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
          ),
        );

        await launch(
          tester,
          path: '/workspace/training/questions/5/revisions/10',
        );

        // Change dropdown to TRUE_FALSE
        await tester.tap(find.text('Single choice (Multiple choice)').last);
        await tester.pumpAndSettle();
        await tester.tap(find.text('True / False').last);
        await tester.pumpAndSettle();

        // Tap Preset T/F
        await tester.tap(find.text('Preset T/F'));
        await tester.pumpAndSettle();

        expect(find.text('True'), findsOneWidget);
        expect(find.text('False'), findsOneWidget);

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

        expect(find.text('Revision saved successfully.'), findsOneWidget);
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
