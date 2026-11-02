import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';
import 'package:training_app/core/errors/api_error.dart';
import 'package:training_app/core/router/app_router.dart';
import 'package:training_app/core/theme/app_theme.dart';
import 'package:training_app/features/auth/domain/models/authenticated_identity.dart';
import 'package:training_app/features/auth/presentation/controllers/auth_controller.dart';
import 'package:training_app/features/management/data/repositories/management_repository.dart';
import 'package:training_app/features/management/domain/models/management_models.dart';
import 'package:training_app/features/management/presentation/screens/assessment_question_form_screen.dart';
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
          modules: [managedModuleJson(id: 51, title: 'Introduction', order: 1)],
        ),
      ),
    );

    when(
      () => repository.assessmentDetail(
        any(),
        any(),
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenAnswer(
      (_) async => ManagedAssessment.fromJson(
        managedAssessmentJson(
          id: 1,
          trainingVersionId: 20,
          moduleId: 51,
          kind: 'QUIZ',
          title: 'Module 1 Quiz',
          sequence: 1,
          passPercentage: '80.00',
          maxAttempts: 3,
        ),
      ),
    );

    when(
      () => repository.assessments(
        any(),
        page: any(named: 'page'),
        pageSize: any(named: 'pageSize'),
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenAnswer(
      (_) async => ManagementPage<ManagedAssessment>(
        count: 1,
        hasMore: false,
        items: [
          ManagedAssessment.fromJson(
            managedAssessmentJson(
              id: 1,
              trainingVersionId: 20,
              moduleId: 51,
              kind: 'QUIZ',
              title: 'Module 1 Quiz',
            ),
          ),
        ],
      ),
    );

    when(
      () => repository.assessmentQuestions(
        any(),
        any(),
        page: any(named: 'page'),
        pageSize: any(named: 'pageSize'),
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenAnswer(
      (_) async => ManagementPage<ManagedAssessmentQuestion>(
        count: 1,
        hasMore: false,
        items: [
          ManagedAssessmentQuestion.fromJson(
            managedAssessmentQuestionJson(
              id: 1,
              assessmentId: 1,
              questionRevisionId: 10,
              position: 1,
              points: '1.00',
            ),
          ),
        ],
      ),
    );

    when(
      () => repository.assessmentQuestionDetail(
        any(),
        any(),
        any(),
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenAnswer(
      (_) async => ManagedAssessmentQuestion.fromJson(
        managedAssessmentQuestionJson(
          id: 1,
          assessmentId: 1,
          questionRevisionId: 10,
          position: 1,
          points: '1.00',
        ),
      ),
    );
  });

  Future<ProviderContainer> launch(
    WidgetTester tester, {
    AuthenticatedIdentity? identity,
    String path = '/workspace/training/versions/20/assessments/new',
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
              'training.view_trainingversion',
              'assessments.view_assessment',
              'assessments.add_assessment',
              'assessments.change_assessment',
              'assessments.view_assessmentquestion',
              'assessments.add_assessmentquestion',
              'assessments.change_assessmentquestion',
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

  group('AssessmentFormScreen - Creation Workflow', () {
    testWidgets('renders assessment creation form with default values', (
      tester,
    ) async {
      await launch(tester);

      expect(find.text('Create assessment'), findsWidgets);
      expect(find.text('Assessment details'), findsOneWidget);
      expect(find.text('Module quiz (QUIZ)'), findsOneWidget);
      expect(find.widgetWithText(TextFormField, '80.00'), findsOneWidget);
      expect(find.widgetWithText(TextFormField, '3'), findsOneWidget);
    });

    testWidgets('validates required title and module for quiz', (tester) async {
      await launch(tester);

      final saveButton = find.widgetWithText(FilledButton, 'Create assessment');
      await tester.tap(saveButton);
      await tester.pumpAndSettle();

      expect(find.text('Title is required.'), findsOneWidget);
      expect(find.text('Please select a module.'), findsOneWidget);
    });

    testWidgets(
      'selecting FINAL disables module selection and forces sequence 1',
      (tester) async {
        await launch(tester);

        // Select FINAL
        await tester.tap(find.text('Module quiz (QUIZ)'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Final assessment (FINAL)').last);
        await tester.pumpAndSettle();

        // Module and sequence fields should not be visible for FINAL
        expect(find.text('Module *'), findsNothing);
        expect(find.text('Sequence *'), findsNothing);
        expect(
          find.text('Final assessments are always required.'),
          findsOneWidget,
        );
      },
    );

    testWidgets('successful creation invokes repository and pops', (
      tester,
    ) async {
      when(
        () => repository.createAssessment(
          any(),
          kind: any(named: 'kind'),
          title: any(named: 'title'),
          moduleId: any(named: 'moduleId'),
          sequence: any(named: 'sequence'),
          passPercentage: any(named: 'passPercentage'),
          maxAttempts: any(named: 'maxAttempts'),
          timeLimitMinutes: any(named: 'timeLimitMinutes'),
          isRequired: any(named: 'isRequired'),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer(
        (_) async => ManagedAssessment.fromJson(
          managedAssessmentJson(id: 42, title: 'Safety Final Exam'),
        ),
      );

      await launch(tester);

      // Select FINAL
      await tester.tap(find.text('Module quiz (QUIZ)'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Final assessment (FINAL)').last);
      await tester.pumpAndSettle();

      // Enter title
      await tester.enterText(
        find.widgetWithText(TextFormField, '').first,
        'Safety Final Exam',
      );
      await tester.pumpAndSettle();

      final saveButton = find.widgetWithText(FilledButton, 'Create assessment');
      await tester.tap(saveButton);
      await tester.pumpAndSettle();

      verify(
        () => repository.createAssessment(
          20,
          kind: 'FINAL',
          title: 'Safety Final Exam',
          moduleId: null,
          sequence: 1,
          passPercentage: 80.0,
          maxAttempts: 3,
          timeLimitMinutes: null,
          isRequired: true,
          cancelToken: any(named: 'cancelToken'),
        ),
      ).called(1);

      expect(find.text('Assessment created successfully.'), findsOneWidget);
    });

    testWidgets('discard dialog prompts when navigating back from dirty form', (
      tester,
    ) async {
      await launch(tester);

      await tester.enterText(
        find.widgetWithText(TextFormField, '').first,
        'Unsaved Assessment Title',
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(find.text('Discard changes?'), findsOneWidget);
      await tester.tap(find.text('Keep editing'));
      await tester.pumpAndSettle();

      expect(find.text('Create assessment'), findsWidgets);
    });
  });

  group('AssessmentFormScreen - Editing Workflow', () {
    testWidgets('pre-populates existing assessment values and saves updates', (
      tester,
    ) async {
      when(
        () => repository.updateAssessment(
          any(),
          any(),
          kind: any(named: 'kind'),
          title: any(named: 'title'),
          moduleId: any(named: 'moduleId'),
          clearModuleId: any(named: 'clearModuleId'),
          sequence: any(named: 'sequence'),
          passPercentage: any(named: 'passPercentage'),
          maxAttempts: any(named: 'maxAttempts'),
          timeLimitMinutes: any(named: 'timeLimitMinutes'),
          clearTimeLimit: any(named: 'clearTimeLimit'),
          isRequired: any(named: 'isRequired'),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer(
        (_) async => ManagedAssessment.fromJson(
          managedAssessmentJson(id: 1, title: 'Updated Module 1 Quiz'),
        ),
      );

      await launch(
        tester,
        path: '/workspace/training/versions/20/assessments/1/edit',
      );

      expect(find.text('Edit assessment'), findsWidgets);
      expect(
        find.widgetWithText(TextFormField, 'Module 1 Quiz'),
        findsOneWidget,
      );

      await tester.enterText(
        find.widgetWithText(TextFormField, 'Module 1 Quiz'),
        'Updated Module 1 Quiz',
      );
      await tester.pumpAndSettle();

      final saveButton = find.widgetWithText(FilledButton, 'Save changes');
      await tester.tap(saveButton);
      await tester.pumpAndSettle();

      verify(
        () => repository.updateAssessment(
          20,
          1,
          kind: 'QUIZ',
          title: 'Updated Module 1 Quiz',
          moduleId: 51,
          clearModuleId: false,
          sequence: 1,
          passPercentage: 80.0,
          maxAttempts: 3,
          timeLimitMinutes: null,
          clearTimeLimit: true,
          isRequired: true,
          cancelToken: any(named: 'cancelToken'),
        ),
      ).called(1);

      expect(find.text('Assessment updated successfully.'), findsOneWidget);
    });
  });

  group('ManagedAssessmentDetailScreen', () {
    testWidgets('renders assessment specifications and attached questions', (
      tester,
    ) async {
      await launch(
        tester,
        path: '/workspace/training/versions/20/assessments/1',
      );

      expect(find.text('Assessment details'), findsWidgets);
      expect(find.text('Module 1 Quiz'), findsOneWidget);
      expect(find.text('80.0%'), findsOneWidget);
      expect(find.text('3'), findsOneWidget);
      expect(find.text('Question Revision #10'), findsOneWidget);
      expect(find.text('Points: 1.00'), findsOneWidget);
      expect(find.text('Add question'), findsOneWidget);
    });
  });

  group('AssessmentQuestionFormScreen', () {
    testWidgets('validates required fields and attaches question revision', (
      tester,
    ) async {
      when(
        () => repository.createAssessmentQuestion(
          any(),
          any(),
          questionRevisionId: any(named: 'questionRevisionId'),
          position: any(named: 'position'),
          points: any(named: 'points'),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer(
        (_) async => ManagedAssessmentQuestion.fromJson(
          managedAssessmentQuestionJson(id: 10, questionRevisionId: 10),
        ),
      );

      await launch(
        tester,
        path: '/workspace/training/versions/20/assessments/1/questions/new',
      );

      expect(find.text('Attach question'), findsWidgets);

      // Attempt submit without revision ID
      await tester.tap(find.widgetWithText(FilledButton, 'Attach question'));
      await tester.pumpAndSettle();

      expect(
        find.text('Enter a valid question revision ID >= 1.'),
        findsOneWidget,
      );

      // Enter revision ID 10
      await tester.enterText(
        find.widgetWithText(TextFormField, '').first,
        '10',
      );
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(FilledButton, 'Attach question'));
      await tester.pumpAndSettle();

      verify(
        () => repository.createAssessmentQuestion(
          20,
          1,
          questionRevisionId: 10,
          position: 1,
          points: 1.0,
          cancelToken: any(named: 'cancelToken'),
        ),
      ).called(1);

      expect(
        find.text('Question attached to assessment successfully.'),
        findsOneWidget,
      );
    });

    group(
      'Finding 1 — Independent Permissions on ManagedVersionDetailScreen',
      () {
        testWidgets(
          'add-only author can create assessment and no assessment list GET is issued',
          (tester) async {
            when(
              () => repository.createAssessment(
                20,
                kind: any(named: 'kind'),
                title: any(named: 'title'),
                sequence: any(named: 'sequence'),
                passPercentage: any(named: 'passPercentage'),
                maxAttempts: any(named: 'maxAttempts'),
                timeLimitMinutes: any(named: 'timeLimitMinutes'),
                isRequired: any(named: 'isRequired'),
                moduleId: any(named: 'moduleId'),
                cancelToken: any(named: 'cancelToken'),
              ),
            ).thenAnswer(
              (_) async => ManagedAssessment.fromJson(
                managedAssessmentJson(
                  id: 10,
                  title: 'Final Exam',
                  kind: 'FINAL',
                  moduleId: null,
                ),
              ),
            );

            await launch(
              tester,
              identity: managementIdentity(
                capabilities: {
                  'management_workspace',
                  'training.view_trainingversion',
                  'assessments.add_assessment',
                },
              ),
              path: '/workspace/training/versions/20',
            );

            // Assessments section heading and Create button are shown
            expect(find.text('Assessments'), findsOneWidget);
            expect(find.text('Create assessment'), findsOneWidget);

            // Verify no unauthorized GET request to repository.assessments
            verifyNever(
              () => repository.assessments(
                any(),
                page: any(named: 'page'),
                cancelToken: any(named: 'cancelToken'),
              ),
            );

            // Tap Create assessment
            await tester.tap(find.text('Create assessment'));
            await tester.pumpAndSettle();

            expect(find.text('Create assessment'), findsWidgets);

            // Select FINAL
            await tester.tap(find.text('Module quiz (QUIZ)'));
            await tester.pumpAndSettle();
            await tester.tap(find.text('Final assessment (FINAL)').last);
            await tester.pumpAndSettle();

            // Enter title
            await tester.enterText(
              find.widgetWithText(TextFormField, '').first,
              'Final Exam',
            );
            await tester.pumpAndSettle();

            // Submit form
            await tester.tap(
              find.widgetWithText(FilledButton, 'Create assessment'),
            );
            await tester.pumpAndSettle();

            verify(
              () => repository.createAssessment(
                20,
                kind: 'FINAL',
                title: 'Final Exam',
                sequence: 1,
                passPercentage: 80.0,
                maxAttempts: 3,
                timeLimitMinutes: null,
                isRequired: true,
                moduleId: null,
                cancelToken: any(named: 'cancelToken'),
              ),
            ).called(1);

            // Popped back to version details without making any unauthorized assessment GET request
            verifyNever(
              () => repository.assessments(
                any(),
                page: any(named: 'page'),
                cancelToken: any(named: 'cancelToken'),
              ),
            );
            expect(find.text('Workplace Safety v2'), findsOneWidget);
          },
        );

        testWidgets('view-only author can list assessments but cannot create', (
          tester,
        ) async {
          await launch(
            tester,
            identity: managementIdentity(
              capabilities: {
                'management_workspace',
                'training.view_trainingversion',
                'assessments.view_assessment',
              },
            ),
            path: '/workspace/training/versions/20',
          );

          expect(find.text('Assessments'), findsOneWidget);
          expect(find.text('Create assessment'), findsNothing);
          expect(find.text('Module 1 Quiz'), findsOneWidget);

          verify(
            () => repository.assessments(
              20,
              page: any(named: 'page'),
              cancelToken: any(named: 'cancelToken'),
            ),
          ).called(1);
        });

        testWidgets('add+view author can both list assessments and create', (
          tester,
        ) async {
          await launch(
            tester,
            identity: managementIdentity(
              capabilities: {
                'management_workspace',
                'training.view_trainingversion',
                'assessments.view_assessment',
                'assessments.add_assessment',
              },
            ),
            path: '/workspace/training/versions/20',
          );

          expect(find.text('Assessments'), findsOneWidget);
          expect(find.text('Create assessment'), findsOneWidget);
          expect(find.text('Module 1 Quiz'), findsOneWidget);
        });

        testWidgets(
          'no-permission author sees neither create button nor assessment section',
          (tester) async {
            await launch(
              tester,
              identity: managementIdentity(
                capabilities: {
                  'management_workspace',
                  'training.view_trainingversion',
                },
              ),
              path: '/workspace/training/versions/20',
            );

            expect(find.text('Assessments'), findsNothing);
            expect(find.text('Create assessment'), findsNothing);
            expect(find.text('Module 1 Quiz'), findsNothing);
            verifyNever(
              () => repository.assessments(
                any(),
                page: any(named: 'page'),
                cancelToken: any(named: 'cancelToken'),
              ),
            );
          },
        );

        testWidgets(
          'backend 403 on assessments list handled with retry error card',
          (tester) async {
            when(
              () => repository.assessments(
                any(),
                page: any(named: 'page'),
                pageSize: any(named: 'pageSize'),
                cancelToken: any(named: 'cancelToken'),
              ),
            ).thenThrow(
              ApiError(message: 'Forbidden from backend', statusCode: 403),
            );

            await launch(
              tester,
              identity: managementIdentity(
                capabilities: {
                  'management_workspace',
                  'training.view_trainingversion',
                  'assessments.view_assessment',
                },
              ),
              path: '/workspace/training/versions/20',
            );

            expect(
              find.textContaining('Error loading assessments'),
              findsOneWidget,
            );
            expect(find.text('Retry'), findsOneWidget);
          },
        );
      },
    );

    group('Finding 2 — Pagination across collections (21+ records)', () {
      testWidgets(
        'managed version assessments list paginates beyond page one with 25 records',
        (tester) async {
          final page1Items = List.generate(
            20,
            (i) => ManagedAssessment.fromJson(
              managedAssessmentJson(id: i + 1, title: 'Assessment ${i + 1}'),
            ),
          );
          final page2Items = List.generate(
            5,
            (i) => ManagedAssessment.fromJson(
              managedAssessmentJson(
                id: 20 + i + 1,
                title: 'Assessment ${20 + i + 1}',
              ),
            ),
          );

          when(
            () => repository.assessments(
              20,
              page: 1,
              pageSize: any(named: 'pageSize'),
              cancelToken: any(named: 'cancelToken'),
            ),
          ).thenAnswer(
            (_) async => ManagementPage<ManagedAssessment>(
              count: 25,
              hasMore: true,
              items: page1Items,
            ),
          );

          when(
            () => repository.assessments(
              20,
              page: 2,
              pageSize: any(named: 'pageSize'),
              cancelToken: any(named: 'cancelToken'),
            ),
          ).thenAnswer(
            (_) async => ManagementPage<ManagedAssessment>(
              count: 25,
              hasMore: false,
              items: page2Items,
            ),
          );

          await launch(
            tester,
            path: '/workspace/training/versions/20',
            size: const Size(800, 3600),
          );

          expect(find.text('Assessment 1'), findsOneWidget);
          expect(find.text('Assessment 20'), findsOneWidget);
          expect(find.text('Assessment 21'), findsNothing);
          expect(find.text('Page 1 · 25 total'), findsOneWidget);

          final nextBtn = find.widgetWithText(TextButton, 'Next');
          final prevBtn = find.widgetWithText(TextButton, 'Previous');
          expect(tester.widget<TextButton>(nextBtn).onPressed, isNotNull);
          expect(tester.widget<TextButton>(prevBtn).onPressed, isNull);

          await tester.tap(nextBtn);
          await tester.pumpAndSettle();

          expect(find.text('Assessment 21'), findsOneWidget);
          expect(find.text('Assessment 25'), findsOneWidget);
          expect(find.text('Assessment 1'), findsNothing);
          expect(find.text('Page 2 · 25 total'), findsOneWidget);

          expect(tester.widget<TextButton>(nextBtn).onPressed, isNull);
          expect(tester.widget<TextButton>(prevBtn).onPressed, isNotNull);

          await tester.tap(prevBtn);
          await tester.pumpAndSettle();

          expect(find.text('Assessment 1'), findsOneWidget);
          expect(find.text('Page 1 · 25 total'), findsOneWidget);
        },
      );

      testWidgets(
        'attached assessment questions paginates beyond page one with 25 records',
        (tester) async {
          final page1Items = List.generate(
            20,
            (i) => ManagedAssessmentQuestion.fromJson(
              managedAssessmentQuestionJson(
                id: i + 1,
                questionRevisionId: 100 + i + 1,
                position: i + 1,
              ),
            ),
          );
          final page2Items = List.generate(
            5,
            (i) => ManagedAssessmentQuestion.fromJson(
              managedAssessmentQuestionJson(
                id: 20 + i + 1,
                questionRevisionId: 120 + i + 1,
                position: 20 + i + 1,
              ),
            ),
          );

          when(
            () => repository.assessmentQuestions(
              20,
              1,
              page: 1,
              pageSize: any(named: 'pageSize'),
              cancelToken: any(named: 'cancelToken'),
            ),
          ).thenAnswer(
            (_) async => ManagementPage<ManagedAssessmentQuestion>(
              count: 25,
              hasMore: true,
              items: page1Items,
            ),
          );

          when(
            () => repository.assessmentQuestions(
              20,
              1,
              page: 2,
              pageSize: any(named: 'pageSize'),
              cancelToken: any(named: 'cancelToken'),
            ),
          ).thenAnswer(
            (_) async => ManagementPage<ManagedAssessmentQuestion>(
              count: 25,
              hasMore: false,
              items: page2Items,
            ),
          );

          await launch(
            tester,
            path: '/workspace/training/versions/20/assessments/1',
            size: const Size(800, 3600),
          );

          expect(find.text('Question Revision #101'), findsOneWidget);
          expect(find.text('Page 1 · 25 total'), findsOneWidget);

          final nextBtn = find.widgetWithText(TextButton, 'Next');
          final prevBtn = find.widgetWithText(TextButton, 'Previous');
          expect(tester.widget<TextButton>(nextBtn).onPressed, isNotNull);
          expect(tester.widget<TextButton>(prevBtn).onPressed, isNull);

          await tester.tap(nextBtn);
          await tester.pumpAndSettle();

          expect(find.text('Question Revision #121'), findsOneWidget);
          expect(find.text('Page 2 · 25 total'), findsOneWidget);
          expect(tester.widget<TextButton>(nextBtn).onPressed, isNull);
          expect(tester.widget<TextButton>(prevBtn).onPressed, isNotNull);
        },
      );

      testWidgets(
        'frozen revision picker in AssessmentQuestionFormScreen paginates questions and question revisions',
        (tester) async {
          final p1Questions = List.generate(
            20,
            (i) => ManagedQuestion.fromJson(
              managedQuestionJson(
                id: i + 1,
                code: 'Q-CODE-${i + 1}',
                topic: 'Topic ${i + 1}',
              ),
            ),
          );
          final p2Questions = List.generate(
            5,
            (i) => ManagedQuestion.fromJson(
              managedQuestionJson(
                id: 20 + i + 1,
                code: 'Q-CODE-${20 + i + 1}',
                topic: 'Topic ${20 + i + 1}',
              ),
            ),
          );

          when(
            () => repository.questions(
              page: 1,
              search: any(named: 'search'),
              isActive: true,
              cancelToken: any(named: 'cancelToken'),
            ),
          ).thenAnswer(
            (_) async => ManagementPage<ManagedQuestion>(
              count: 25,
              hasMore: true,
              items: p1Questions,
            ),
          );

          when(
            () => repository.questions(
              page: 2,
              search: any(named: 'search'),
              isActive: true,
              cancelToken: any(named: 'cancelToken'),
            ),
          ).thenAnswer(
            (_) async => ManagementPage<ManagedQuestion>(
              count: 25,
              hasMore: false,
              items: p2Questions,
            ),
          );

          when(
            () => repository.questionRevisions(
              21,
              page: 1,
              pageSize: any(named: 'pageSize'),
              cancelToken: any(named: 'cancelToken'),
            ),
          ).thenAnswer(
            (_) async => ManagementPage<ManagedQuestionRevisionSummary>(
              count: 22,
              hasMore: true,
              items: List.generate(
                20,
                (i) => ManagedQuestionRevisionSummary.fromJson(
                  managedQuestionRevisionSummaryJson(
                    id: 100 + i,
                    questionId: 21,
                    revisionNumber: i + 1,
                    status: 'FROZEN',
                  ),
                ),
              ),
            ),
          );

          when(
            () => repository.questionRevisions(
              21,
              page: 2,
              pageSize: any(named: 'pageSize'),
              cancelToken: any(named: 'cancelToken'),
            ),
          ).thenAnswer(
            (_) async => ManagementPage<ManagedQuestionRevisionSummary>(
              count: 22,
              hasMore: false,
              items: [
                ManagedQuestionRevisionSummary.fromJson(
                  managedQuestionRevisionSummaryJson(
                    id: 121,
                    questionId: 21,
                    revisionNumber: 21,
                    status: 'FROZEN',
                  ),
                ),
                ManagedQuestionRevisionSummary.fromJson(
                  managedQuestionRevisionSummaryJson(
                    id: 122,
                    questionId: 21,
                    revisionNumber: 22,
                    status: 'FROZEN',
                  ),
                ),
              ],
            ),
          );

          await launch(
            tester,
            identity: managementIdentity(
              capabilities: {
                'management_workspace',
                'training.view_trainingversion',
                'assessments.view_assessment',
                'assessments.add_assessment',
                'assessments.view_assessmentquestion',
                'assessments.add_assessmentquestion',
                'assessments.view_question',
                'assessments.view_questionrevision',
              },
            ),
            path: '/workspace/training/versions/20/assessments/1/questions/new',
          );

          // Open revision picker modal bottom sheet
          await tester.tap(find.byTooltip('Browse question bank'));
          await tester.pumpAndSettle();

          expect(find.text('Select active question revision'), findsOneWidget);
          expect(find.text('Q-CODE-1'), findsOneWidget);
          expect(find.text('Page 1 · 25 total'), findsOneWidget);

          // Navigate questions to page 2
          final nextQuestionsBtn = find.widgetWithText(TextButton, 'Next');
          await tester.tap(nextQuestionsBtn);
          await tester.pumpAndSettle();

          expect(find.text('Q-CODE-21'), findsOneWidget);
          expect(find.text('Page 2 · 25 total'), findsOneWidget);

          // Expand Q-CODE-21
          await tester.tap(find.text('Q-CODE-21'));
          await tester.pumpAndSettle();

          expect(find.text('Revision 1 (SINGLE_CHOICE)'), findsOneWidget);
          expect(find.text('Revs p. 1'), findsOneWidget);

          // Next page of revisions for this question
          final nextRevsBtn = find.widgetWithText(TextButton, 'Next revs');
          expect(nextRevsBtn, findsOneWidget);
          await tester.tap(nextRevsBtn);
          await tester.pumpAndSettle();

          expect(find.text('Revision 21 (SINGLE_CHOICE)'), findsOneWidget);
          expect(find.text('Revs p. 2'), findsOneWidget);

          // Select Revision 21
          await tester.tap(find.text('Revision 21 (SINGLE_CHOICE)'));
          await tester.pumpAndSettle();

          // Modal closed, Revision ID textfield has 121
          expect(find.text('Select active question revision'), findsNothing);
          expect(find.widgetWithText(TextFormField, '121'), findsOneWidget);
        },
      );
    });

    group('Stage 10 — Question Bank Picker Permission Gating', () {
      testWidgets(
        'both view permissions: Browse button visible and opens picker',
        (tester) async {
          when(
            () => repository.questions(
              page: any(named: 'page'),
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
                    id: 50,
                    code: 'Q-GATE-1',
                    topic: 'Gatekeeper Testing',
                  ),
                ),
              ],
            ),
          );

          await launch(
            tester,
            identity: managementIdentity(
              capabilities: {
                'management_workspace',
                'training.view_trainingversion',
                'assessments.view_assessment',
                'assessments.add_assessmentquestion',
                'assessments.view_question',
                'assessments.view_questionrevision',
              },
            ),
            path: '/workspace/training/versions/20/assessments/1/questions/new',
          );

          expect(find.byTooltip('Browse question bank'), findsOneWidget);

          await tester.tap(find.byTooltip('Browse question bank'));
          await tester.pumpAndSettle();

          expect(find.text('Select active question revision'), findsOneWidget);
          expect(find.text('Q-GATE-1'), findsOneWidget);
          verify(
            () => repository.questions(
              page: any(named: 'page'),
              search: any(named: 'search'),
              isActive: any(named: 'isActive'),
              cancelToken: any(named: 'cancelToken'),
            ),
          ).called(1);
        },
      );

      testWidgets(
        'question view only: Browse button hidden and no question/revision GET requested',
        (tester) async {
          await launch(
            tester,
            identity: managementIdentity(
              capabilities: {
                'management_workspace',
                'training.view_trainingversion',
                'assessments.view_assessment',
                'assessments.add_assessmentquestion',
                'assessments.view_question',
              },
            ),
            path: '/workspace/training/versions/20/assessments/1/questions/new',
          );

          expect(find.byTooltip('Browse question bank'), findsNothing);
          expect(find.widgetWithText(TextFormField, ''), findsOneWidget);

          verifyNever(
            () => repository.questions(
              page: any(named: 'page'),
              search: any(named: 'search'),
              isActive: any(named: 'isActive'),
              cancelToken: any(named: 'cancelToken'),
            ),
          );
          verifyNever(
            () => repository.questionRevisions(
              any(),
              page: any(named: 'page'),
              pageSize: any(named: 'pageSize'),
              cancelToken: any(named: 'cancelToken'),
            ),
          );
        },
      );

      testWidgets(
        'revision view only: Browse button hidden and no question/revision GET requested',
        (tester) async {
          await launch(
            tester,
            identity: managementIdentity(
              capabilities: {
                'management_workspace',
                'training.view_trainingversion',
                'assessments.view_assessment',
                'assessments.add_assessmentquestion',
                'assessments.view_questionrevision',
              },
            ),
            path: '/workspace/training/versions/20/assessments/1/questions/new',
          );

          expect(find.byTooltip('Browse question bank'), findsNothing);
          expect(find.widgetWithText(TextFormField, ''), findsOneWidget);

          verifyNever(
            () => repository.questions(
              page: any(named: 'page'),
              search: any(named: 'search'),
              isActive: any(named: 'isActive'),
              cancelToken: any(named: 'cancelToken'),
            ),
          );
          verifyNever(
            () => repository.questionRevisions(
              any(),
              page: any(named: 'page'),
              pageSize: any(named: 'pageSize'),
              cancelToken: any(named: 'cancelToken'),
            ),
          );
        },
      );

      testWidgets(
        'neither view permission: Browse button hidden, manual revision ID usable for add-only author',
        (tester) async {
          when(
            () => repository.createAssessmentQuestion(
              any(),
              any(),
              questionRevisionId: any(named: 'questionRevisionId'),
              position: any(named: 'position'),
              points: any(named: 'points'),
              cancelToken: any(named: 'cancelToken'),
            ),
          ).thenAnswer(
            (_) async => ManagedAssessmentQuestion.fromJson(
              managedAssessmentQuestionJson(id: 42, questionRevisionId: 42),
            ),
          );

          await launch(
            tester,
            identity: managementIdentity(
              capabilities: {
                'management_workspace',
                'training.view_trainingversion',
                'assessments.view_assessment',
                'assessments.add_assessmentquestion',
              },
            ),
            path: '/workspace/training/versions/20/assessments/1/questions/new',
          );

          expect(find.byTooltip('Browse question bank'), findsNothing);

          // Enter manual revision ID
          await tester.enterText(
            find.widgetWithText(TextFormField, '').first,
            '42',
          );
          await tester.pumpAndSettle();

          await tester.tap(
            find.widgetWithText(FilledButton, 'Attach question'),
          );
          await tester.pumpAndSettle();

          verify(
            () => repository.createAssessmentQuestion(
              20,
              1,
              questionRevisionId: 42,
              position: 1,
              points: 1.0,
              cancelToken: any(named: 'cancelToken'),
            ),
          ).called(1);

          verifyNever(
            () => repository.questions(
              page: any(named: 'page'),
              search: any(named: 'search'),
              isActive: any(named: 'isActive'),
              cancelToken: any(named: 'cancelToken'),
            ),
          );
          verifyNever(
            () => repository.questionRevisions(
              any(),
              page: any(named: 'page'),
              pageSize: any(named: 'pageSize'),
              cancelToken: any(named: 'cancelToken'),
            ),
          );
        },
      );

      testWidgets(
        'change-only author without view permissions: Browse button hidden, edit functions normally',
        (tester) async {
          when(
            () => repository.updateAssessmentQuestion(
              any(),
              any(),
              any(),
              questionRevisionId: any(named: 'questionRevisionId'),
              position: any(named: 'position'),
              points: any(named: 'points'),
              cancelToken: any(named: 'cancelToken'),
            ),
          ).thenAnswer(
            (_) async => ManagedAssessmentQuestion.fromJson(
              managedAssessmentQuestionJson(id: 1, points: '3.00'),
            ),
          );

          await launch(
            tester,
            identity: managementIdentity(
              capabilities: {
                'management_workspace',
                'training.view_trainingversion',
                'assessments.view_assessment',
                'assessments.view_assessmentquestion',
                'assessments.change_assessmentquestion',
              },
            ),
            path: '/workspace/training/versions/20/assessments/1/questions/1/edit',
          );

          expect(find.text('Edit question attachment'), findsWidgets);
          expect(find.byTooltip('Browse question bank'), findsNothing);

          // Edit points
          await tester.enterText(
            find.widgetWithText(TextFormField, '1.00'),
            '3.00',
          );
          await tester.pumpAndSettle();

          await tester.tap(find.widgetWithText(FilledButton, 'Save changes'));
          await tester.pumpAndSettle();

          verify(
            () => repository.updateAssessmentQuestion(
              20,
              1,
              1,
              questionRevisionId: 10,
              position: 1,
              points: 3.0,
              cancelToken: any(named: 'cancelToken'),
            ),
          ).called(1);

          verifyNever(
            () => repository.questions(
              page: any(named: 'page'),
              search: any(named: 'search'),
              isActive: any(named: 'isActive'),
              cancelToken: any(named: 'cancelToken'),
            ),
          );
          verifyNever(
            () => repository.questionRevisions(
              any(),
              page: any(named: 'page'),
              pageSize: any(named: 'pageSize'),
              cancelToken: any(named: 'cancelToken'),
            ),
          );
        },
      );

      testWidgets(
        'no permission author: blocked by router guard and redirected away without authoring actions',
        (tester) async {
          await launch(
            tester,
            identity: managementIdentity(
              capabilities: {
                'management_workspace',
                'training.view_trainingversion',
                'assessments.view_assessment',
              },
            ),
            path: '/workspace/training/versions/20/assessments/1/questions/new',
          );

          // Router redirects to workspace home since author lacks assessments.add_assessmentquestion
          expect(find.text('Attach question'), findsNothing);
          expect(find.text('Question attachment settings'), findsNothing);
          expect(find.byTooltip('Browse question bank'), findsNothing);

          verifyNever(
            () => repository.createAssessmentQuestion(
              any(),
              any(),
              questionRevisionId: any(named: 'questionRevisionId'),
              position: any(named: 'position'),
              points: any(named: 'points'),
              cancelToken: any(named: 'cancelToken'),
            ),
          );
          verifyNever(
            () => repository.questions(
              page: any(named: 'page'),
              search: any(named: 'search'),
              isActive: any(named: 'isActive'),
              cancelToken: any(named: 'cancelToken'),
            ),
          );
        },
      );

      testWidgets(
        'AssessmentQuestionFormScreen widget shows permission denied when rendered directly without permission',
        (tester) async {
          final container = ProviderContainer(
            overrides: [
              authControllerProvider.overrideWith(
                () => ManagementTestAuth(
                  managementIdentity(
                    capabilities: {
                      'management_workspace',
                      'training.view_trainingversion',
                      'assessments.view_assessment',
                    },
                  ),
                ),
              ),
              managementRepositoryProvider.overrideWithValue(repository),
            ],
          );
          addTearDown(container.dispose);

          await tester.pumpWidget(
            UncontrolledProviderScope(
              container: container,
              child: const MaterialApp(
                home: AssessmentQuestionFormScreen(
                  versionId: 20,
                  assessmentId: 1,
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();

          expect(
            find.text(
              'You do not have permission to attach questions to assessments.',
            ),
            findsOneWidget,
          );
          expect(find.text('Question attachment settings'), findsNothing);
          expect(find.byTooltip('Browse question bank'), findsNothing);
        },
      );
    });

    group('Lazy Question Revisions Loading in Picker', () {
      testWidgets(
        'opening picker issues no revision requests; expanding a question loads only its revisions',
        (tester) async {
          when(
            () => repository.questions(
              page: any(named: 'page'),
              search: any(named: 'search'),
              isActive: any(named: 'isActive'),
              cancelToken: any(named: 'cancelToken'),
            ),
          ).thenAnswer(
            (_) async => ManagementPage<ManagedQuestion>(
              count: 2,
              hasMore: false,
              items: [
                ManagedQuestion.fromJson(
                  managedQuestionJson(
                    id: 101,
                    code: 'Q-LAZY-1',
                    topic: 'Safety Basics',
                  ),
                ),
                ManagedQuestion.fromJson(
                  managedQuestionJson(
                    id: 102,
                    code: 'Q-LAZY-2',
                    topic: 'Equipment Rules',
                  ),
                ),
              ],
            ),
          );

          when(
            () => repository.questionRevisions(
              101,
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
                    id: 201,
                    questionId: 101,
                    revisionNumber: 1,
                    status: 'FROZEN',
                  ),
                ),
              ],
            ),
          );

          when(
            () => repository.questionRevisions(
              102,
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
                    id: 202,
                    questionId: 102,
                    revisionNumber: 1,
                    status: 'FROZEN',
                  ),
                ),
              ],
            ),
          );

          await launch(
            tester,
            identity: managementIdentity(
              capabilities: {
                'management_workspace',
                'training.view_trainingversion',
                'assessments.view_assessment',
                'assessments.add_assessmentquestion',
                'assessments.view_question',
                'assessments.view_questionrevision',
              },
            ),
            path: '/workspace/training/versions/20/assessments/1/questions/new',
          );

          // 1. Open picker
          await tester.tap(find.byTooltip('Browse question bank'));
          await tester.pumpAndSettle();

          expect(find.text('Select active question revision'), findsOneWidget);
          expect(find.text('Q-LAZY-1'), findsOneWidget);
          expect(find.text('Q-LAZY-2'), findsOneWidget);

          // Opening picker MUST NOT issue any revision requests while tiles are collapsed
          verifyNever(
            () => repository.questionRevisions(
              any(),
              page: any(named: 'page'),
              pageSize: any(named: 'pageSize'),
              cancelToken: any(named: 'cancelToken'),
            ),
          );

          // 2. Expand first question (Q-LAZY-1)
          await tester.tap(find.text('Q-LAZY-1'));
          await tester.pumpAndSettle();

          // Only question 101's revisions should be requested
          verify(
            () => repository.questionRevisions(
              101,
              page: any(named: 'page'),
              pageSize: any(named: 'pageSize'),
              cancelToken: any(named: 'cancelToken'),
            ),
          ).called(1);

          verifyNever(
            () => repository.questionRevisions(
              102,
              page: any(named: 'page'),
              pageSize: any(named: 'pageSize'),
              cancelToken: any(named: 'cancelToken'),
            ),
          );

          expect(find.text('Revision 1 (SINGLE_CHOICE)'), findsOneWidget);

          // 3. Expand second question (Q-LAZY-2)
          await tester.tap(find.text('Q-LAZY-2'));
          await tester.pumpAndSettle();

          // Now question 102's revisions should be requested
          verify(
            () => repository.questionRevisions(
              102,
              page: any(named: 'page'),
              pageSize: any(named: 'pageSize'),
              cancelToken: any(named: 'cancelToken'),
            ),
          ).called(1);

          // 4. Select revision from the second question
          final matchingRevisions = find.text('Revision 1 (SINGLE_CHOICE)');
          expect(matchingRevisions, findsNWidgets(2));
          await tester.tap(matchingRevisions.last);
          await tester.pumpAndSettle();

          // Picker is closed and selected revision ID 202 is populated in the form field
          expect(find.text('Select active question revision'), findsNothing);
          expect(find.widgetWithText(TextFormField, '202'), findsOneWidget);
        },
      );
    });
  });
}
