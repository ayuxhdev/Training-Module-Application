import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:training_app/core/errors/api_error.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:training_app/core/presentation/components/error_view.dart';
import 'package:training_app/core/presentation/components/loading_view.dart';
import 'package:training_app/core/presentation/components/primary_button.dart';
import 'package:training_app/features/learning/data/repositories/learning_repository.dart';
import 'package:training_app/features/learning/domain/models/assignment_detail.dart';
import 'package:training_app/features/learning/presentation/controllers/learning_controller.dart';
import 'package:training_app/features/learning/presentation/screens/text_lesson_screen.dart';
import 'dart:async';

class MockLearningRepository implements LearningRepository {
  bool completeCalled = false;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);

  @override
  Future<LessonProgress> completeTextLesson(int assignmentId, int lessonId) async {
    completeCalled = true;
    return LessonProgress(
      resumePosition: 0.0,
      watchedSeconds: 0.0,
      progressPercent: 100.0,
      completed: true,
      completedAt: DateTime.now(),
    );
  }
}

class MockFailingLearningRepository implements LearningRepository {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);

  @override
  Future<LessonProgress> completeTextLesson(int assignmentId, int lessonId) async {
    throw ApiError(message: 'Friendly network error message from API');
  }
}

class _MockDelayedLearningRepository implements LearningRepository {
  final Completer<LessonProgress> completer;
  bool completeCalled = false;

  _MockDelayedLearningRepository(this.completer);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);

  @override
  Future<LessonProgress> completeTextLesson(int assignmentId, int lessonId) async {
    completeCalled = true;
    return completer.future;
  }
}

void main() {
  Widget createTestWidget(ProviderContainer container) {
    return UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(
        home: TextLessonScreen(assignmentId: 1, lessonId: 10),
      ),
    );
  }

  testWidgets('shows LoadingView while fetching detail', (tester) async {
    final completer = Completer<AssignmentDetail>();
    final container = ProviderContainer(
      overrides: [
        assignmentDetailProvider(1).overrideWith((ref) => completer.future),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(createTestWidget(container));
    expect(find.byType(LoadingView), findsOneWidget);
    
    // Clean up
    completer.complete(AssignmentDetail(
      id: 1, trainingId: 101, trainingTitle: 'Cleanup', versionNumber: 1, status: 'ASSIGNED', isOverdue: false, modules: [],
    ));
    await tester.pumpAndSettle();
  });

  testWidgets('shows ErrorView when lesson not found', (tester) async {
    final mockDetail = AssignmentDetail(
      id: 1, trainingId: 101, trainingTitle: 'Safety Basics', versionNumber: 1, status: 'IN_PROGRESS', isOverdue: false,
      modules: [],
    );

    final container = ProviderContainer(
      overrides: [
        assignmentDetailProvider(1).overrideWith((ref) async => mockDetail),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(createTestWidget(container));
    await tester.pumpAndSettle();
    expect(find.byType(ErrorView), findsOneWidget);
    expect(find.text('Lesson not found'), findsOneWidget);
  });

  testWidgets('shows placeholder when lesson is not TEXT type', (tester) async {
    final mockDetail = AssignmentDetail(
      id: 1, trainingId: 101, trainingTitle: 'Safety Basics', versionNumber: 1, status: 'IN_PROGRESS', isOverdue: false,
      modules: [
        ModuleLearning(
          id: 5, title: 'Mod', description: '', position: 1,
          lessons: [
            LessonLearning(
              id: 10, title: 'Video Lesson', position: 1, type: 'VIDEO', isRequired: true, body: '',
              progress: LessonProgress(resumePosition: 0, watchedSeconds: 0, progressPercent: 0, completed: false),
            ),
          ],
        ),
      ],
    );

    final container = ProviderContainer(
      overrides: [
        assignmentDetailProvider(1).overrideWith((ref) async => mockDetail),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(createTestWidget(container));
    await tester.pumpAndSettle();
    expect(find.byType(ErrorView), findsNothing);
    expect(find.text('This VIDEO lesson is not supported yet.'), findsOneWidget);
  });

  testWidgets('shows incomplete lesson and handles complete action, disabling navigation while submitting', (tester) async {
    final completer = Completer<LessonProgress>();
    
    final mockDelayedRepo = _MockDelayedLearningRepository(completer);
    
    final mockDetail = AssignmentDetail(
      id: 1, trainingId: 101, trainingTitle: 'Safety Basics', versionNumber: 1, status: 'IN_PROGRESS', isOverdue: false,
      modules: [
        ModuleLearning(
          id: 5, title: 'Mod', description: '', position: 1,
          lessons: [
            LessonLearning(
              id: 9, title: 'Prev Lesson', position: 1, type: 'TEXT', isRequired: true, body: 'Prev',
              progress: LessonProgress(resumePosition: 0, watchedSeconds: 0, progressPercent: 100, completed: true),
            ),
            LessonLearning(
              id: 10, title: 'Text Lesson', position: 2, type: 'TEXT', isRequired: true, body: 'Some lesson content here.',
              progress: LessonProgress(resumePosition: 0, watchedSeconds: 0, progressPercent: 0, completed: false),
            ),
            LessonLearning(
              id: 11, title: 'Next Lesson', position: 3, type: 'TEXT', isRequired: true, body: 'Next',
              progress: LessonProgress(resumePosition: 0, watchedSeconds: 0, progressPercent: 0, completed: false),
            ),
          ],
        ),
      ],
    );

    final container = ProviderContainer(
      overrides: [
        learningRepositoryProvider.overrideWithValue(mockDelayedRepo as LearningRepository),
        assignmentDetailProvider(1).overrideWith((ref) async => mockDetail),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(createTestWidget(container));
    await tester.pumpAndSettle();

    expect(find.text('Text Lesson'), findsOneWidget);
    expect(find.text('Some lesson content here.'), findsOneWidget);
    expect(find.text('INCOMPLETE'), findsOneWidget);
    
    final completeButton = find.widgetWithText(PrimaryButton, 'Complete Lesson');
    expect(completeButton, findsOneWidget);

    OutlinedButton getPrevButton() => tester.widget(find.widgetWithText(OutlinedButton, 'Previous'));
    OutlinedButton getNextButton() => tester.widget(find.widgetWithText(OutlinedButton, 'Next'));

    // Navigation buttons are enabled initially
    expect(getPrevButton().onPressed, isNotNull);
    expect(getNextButton().onPressed, isNotNull);

    await tester.tap(completeButton);
    await tester.pump(); // Start async action and setState for loading

    // Navigation buttons should be disabled during submission
    expect(getPrevButton().onPressed, isNull);
    expect(getNextButton().onPressed, isNull);
    
    // Finish the completion request
    completer.complete(LessonProgress(
      resumePosition: 0.0,
      watchedSeconds: 0.0,
      progressPercent: 100.0,
      completed: true,
      completedAt: DateTime.now(),
    ));
    
    await tester.pumpAndSettle();
    
    expect(mockDelayedRepo.completeCalled, isTrue);
    
    // Successful completion preserves local state: Complete button is gone, COMPLETED shows
    expect(find.text('COMPLETED'), findsOneWidget);
    expect(find.text('INCOMPLETE'), findsNothing);
    expect(find.widgetWithText(PrimaryButton, 'Complete Lesson'), findsNothing);
    
    // Navigation buttons should be re-enabled after submission
    expect(getPrevButton().onPressed, isNotNull);
    expect(getNextButton().onPressed, isNotNull);
  });

  
  testWidgets('shows completed lesson without Complete button', (tester) async {
    final mockDetail = AssignmentDetail(
      id: 1, trainingId: 101, trainingTitle: 'Safety Basics', versionNumber: 1, status: 'IN_PROGRESS', isOverdue: false,
      modules: [
        ModuleLearning(
          id: 5, title: 'Mod', description: '', position: 1,
          lessons: [
            LessonLearning(
              id: 10, title: 'Text Lesson Completed', position: 1, type: 'TEXT', isRequired: true, body: 'Content',
              progress: LessonProgress(resumePosition: 0, watchedSeconds: 0, progressPercent: 100, completed: true, completedAt: DateTime.now()),
            ),
          ],
        ),
      ],
    );

    final container = ProviderContainer(
      overrides: [
        assignmentDetailProvider(1).overrideWith((ref) async => mockDetail),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(createTestWidget(container));
    await tester.pumpAndSettle();

    expect(find.text('Text Lesson Completed'), findsOneWidget);
    expect(find.text('COMPLETED'), findsOneWidget);
    expect(find.widgetWithText(PrimaryButton, 'Back to Module'), findsNothing);
    expect(find.widgetWithText(PrimaryButton, 'Complete Lesson'), findsNothing);
  });

  testWidgets('resets local completion state when navigating from completed lesson A to incomplete lesson B', (tester) async {
    final mockRepo = MockLearningRepository(); // completes immediately
    final mockDetail = AssignmentDetail(
      id: 1, trainingId: 101, trainingTitle: 'Safety Basics', versionNumber: 1, status: 'IN_PROGRESS', isOverdue: false,
      modules: [
        ModuleLearning(
          id: 5, title: 'Mod', description: '', position: 1,
          lessons: [
            LessonLearning(id: 10, title: 'Lesson A', position: 1, type: 'TEXT', isRequired: true, body: 'A', progress: LessonProgress(resumePosition: 0, watchedSeconds: 0, progressPercent: 0, completed: false)),
            LessonLearning(id: 11, title: 'Lesson B', position: 2, type: 'TEXT', isRequired: true, body: 'B', progress: LessonProgress(resumePosition: 0, watchedSeconds: 0, progressPercent: 0, completed: false)),
          ],
        ),
      ],
    );

    final container = ProviderContainer(
      overrides: [
        learningRepositoryProvider.overrideWithValue(mockRepo as LearningRepository),
        assignmentDetailProvider(1).overrideWith((ref) async => mockDetail),
      ],
    );
    addTearDown(container.dispose);

    // Pump Lesson A
    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: const MaterialApp(home: TextLessonScreen(assignmentId: 1, lessonId: 10))),
    );
    await tester.pumpAndSettle();

    // Complete Lesson A
    await tester.tap(find.widgetWithText(PrimaryButton, 'Complete Lesson'));
    await tester.pump();
    await tester.pumpAndSettle();

    // Verify A is completed locally
    expect(find.text('COMPLETED'), findsOneWidget);

    // Navigate to Lesson B (using the same widget instance)
    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: const MaterialApp(home: TextLessonScreen(assignmentId: 1, lessonId: 11))),
    );
    await tester.pumpAndSettle();

    // Verify B is INCOMPLETE (local completion state reset)
    expect(find.text('INCOMPLETE'), findsOneWidget);
    expect(find.text('COMPLETED'), findsNothing);
    expect(find.widgetWithText(PrimaryButton, 'Complete Lesson'), findsOneWidget);
  });

  testWidgets('shows friendly error message when completion fails with ApiError', (tester) async {
    final mockRepo = MockFailingLearningRepository();
    final mockDetail = AssignmentDetail(
      id: 1, trainingId: 101, trainingTitle: 'Safety Basics', versionNumber: 1, status: 'IN_PROGRESS', isOverdue: false,
      modules: [
        ModuleLearning(
          id: 5, title: 'Mod', description: '', position: 1,
          lessons: [
            LessonLearning(
              id: 10, title: 'Text Lesson', position: 1, type: 'TEXT', isRequired: true, body: 'Some lesson content here.',
              progress: LessonProgress(resumePosition: 0, watchedSeconds: 0, progressPercent: 0, completed: false),
            ),
          ],
        ),
      ],
    );

    final container = ProviderContainer(
      overrides: [
        learningRepositoryProvider.overrideWithValue(mockRepo as LearningRepository),
        assignmentDetailProvider(1).overrideWith((ref) async => mockDetail),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(createTestWidget(container));
    await tester.pumpAndSettle();
    
    final button = find.widgetWithText(PrimaryButton, 'Complete Lesson');
    await tester.tap(button);
    await tester.pump();
    await tester.pumpAndSettle();
    
    expect(find.text('Friendly network error message from API'), findsOneWidget);
    expect(find.text('Exception: Friendly network error message from API'), findsNothing);
  });

  testWidgets('renders Previous and Next buttons correctly based on sequence', (tester) async {
    final mockDetail = AssignmentDetail(
      id: 1, trainingId: 101, trainingTitle: 'Safety Basics', versionNumber: 1, status: 'IN_PROGRESS', isOverdue: false,
      modules: [
        ModuleLearning(
          id: 5, title: 'Mod1', description: '', position: 1,
          lessons: [
            LessonLearning(
              id: 10, title: 'L1', position: 1, type: 'TEXT', isRequired: true, body: 'Content',
              progress: LessonProgress(resumePosition: 0, watchedSeconds: 0, progressPercent: 100, completed: true),
            ),
            LessonLearning(
              id: 11, title: 'L2', position: 2, type: 'TEXT', isRequired: true, body: 'Content',
              progress: LessonProgress(resumePosition: 0, watchedSeconds: 0, progressPercent: 0, completed: false),
            ),
          ],
        ),
        ModuleLearning(
          id: 6, title: 'Mod2', description: '', position: 2,
          lessons: [
            LessonLearning(
              id: 12, title: 'L3', position: 1, type: 'TEXT', isRequired: true, body: 'Content',
              progress: LessonProgress(resumePosition: 0, watchedSeconds: 0, progressPercent: 0, completed: false),
            ),
          ],
        ),
      ],
    );

    Future<void> testLesson(int lessonId, bool expectPrev, bool expectNext) async {
      final container = ProviderContainer(
        overrides: [
          assignmentDetailProvider(1).overrideWith((ref) async => mockDetail),
        ],
      );

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: TextLessonScreen(assignmentId: 1, lessonId: lessonId),
          ),
        ),
      );
      await tester.pumpAndSettle();

      if (expectPrev) {
        expect(find.widgetWithText(OutlinedButton, 'Previous'), findsOneWidget);
      } else {
        expect(find.widgetWithText(OutlinedButton, 'Previous'), findsNothing);
      }

      if (expectNext) {
        expect(find.widgetWithText(OutlinedButton, 'Next'), findsOneWidget);
      } else {
        expect(find.widgetWithText(OutlinedButton, 'Next'), findsNothing);
      }
      
      container.dispose();
    }

    // First lesson (L1) - should have Next, no Previous
    await testLesson(10, false, true);

    // Middle lesson (L2) - should have both Previous and Next
    await testLesson(11, true, true);

    // Last lesson (L3) - should have Previous, no Next
    await testLesson(12, true, false);
  });
  testWidgets('does not leak local completion state when navigating before request completes', (tester) async {
    final completer = Completer<LessonProgress>();
    final mockDelayedRepo = _MockDelayedLearningRepository(completer);
    
    final mockDetail = AssignmentDetail(
      id: 1, trainingId: 101, trainingTitle: 'Safety Basics', versionNumber: 1, status: 'IN_PROGRESS', isOverdue: false,
      modules: [
        ModuleLearning(
          id: 5, title: 'Mod', description: '', position: 1,
          lessons: [
            LessonLearning(
              id: 10, title: 'Lesson A', position: 1, type: 'TEXT', isRequired: true, body: 'A',
              progress: LessonProgress(resumePosition: 0, watchedSeconds: 0, progressPercent: 0, completed: false),
            ),
            LessonLearning(
              id: 11, title: 'Lesson B', position: 2, type: 'TEXT', isRequired: true, body: 'B',
              progress: LessonProgress(resumePosition: 0, watchedSeconds: 0, progressPercent: 0, completed: false),
            ),
          ],
        ),
      ],
    );

    final container = ProviderContainer(
      overrides: [
        learningRepositoryProvider.overrideWithValue(mockDelayedRepo as LearningRepository),
        assignmentDetailProvider(1).overrideWith((ref) async => mockDetail),
      ],
    );
    addTearDown(container.dispose);

    // 1. Pump Lesson A
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: TextLessonScreen(assignmentId: 1, lessonId: 10),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Lesson A'), findsOneWidget);
    expect(find.text('INCOMPLETE'), findsOneWidget);

    // 2. Start completion for Lesson A
    final completeButtonA = find.widgetWithText(PrimaryButton, 'Complete Lesson');
    await tester.tap(completeButtonA);
    await tester.pump(); // Start async action

    // 3. Before it completes, navigate to Lesson B (using the same widget type and state)
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: TextLessonScreen(assignmentId: 1, lessonId: 11),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Lesson B'), findsOneWidget);
    expect(find.text('INCOMPLETE'), findsOneWidget);

    // 4. Resolve Lesson A's completion
    completer.complete(LessonProgress(
      resumePosition: 0.0,
      watchedSeconds: 0.0,
      progressPercent: 100.0,
      completed: true,
      completedAt: DateTime.now(),
    ));
    await tester.pumpAndSettle();

    // 5. Verify Lesson B remains INCOMPLETE
    expect(find.text('Lesson B'), findsOneWidget);
    expect(find.text('INCOMPLETE'), findsOneWidget);
    expect(find.widgetWithText(PrimaryButton, 'Complete Lesson'), findsOneWidget);
  });

  testWidgets('rejects stale results from earlier visits to the same lesson', (tester) async {
    final completer1 = Completer<LessonProgress>();
    final completer2 = Completer<LessonProgress>();
    final mockRepo = _QueueMockRepo([completer1, completer2]);
    
    final mockDetail = AssignmentDetail(
      id: 1, trainingId: 101, trainingTitle: 'Safety Basics', versionNumber: 1, status: 'IN_PROGRESS', isOverdue: false,
      modules: [
        ModuleLearning(
          id: 5, title: 'Mod', description: '', position: 1,
          lessons: [
            LessonLearning(
              id: 10, title: 'Lesson A', position: 1, type: 'TEXT', isRequired: true, body: 'A',
              progress: LessonProgress(resumePosition: 0, watchedSeconds: 0, progressPercent: 0, completed: false),
            ),
            LessonLearning(
              id: 11, title: 'Lesson B', position: 2, type: 'TEXT', isRequired: true, body: 'B',
              progress: LessonProgress(resumePosition: 0, watchedSeconds: 0, progressPercent: 0, completed: false),
            ),
          ],
        ),
      ],
    );

    final container = ProviderContainer(
      overrides: [
        learningRepositoryProvider.overrideWithValue(mockRepo as LearningRepository),
        assignmentDetailProvider(1).overrideWith((ref) async => mockDetail),
      ],
    );
    addTearDown(container.dispose);

    // Pump Lesson A
    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: const MaterialApp(home: TextLessonScreen(assignmentId: 1, lessonId: 10))),
    );
    await tester.pumpAndSettle();

    // Start 1st request
    await tester.tap(find.widgetWithText(PrimaryButton, 'Complete Lesson'));
    await tester.pump();
    
    // Nav to B
    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: const MaterialApp(home: TextLessonScreen(assignmentId: 1, lessonId: 11))),
    );
    await tester.pumpAndSettle();
    
    // Nav to A
    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: const MaterialApp(home: TextLessonScreen(assignmentId: 1, lessonId: 10))),
    );
    await tester.pumpAndSettle();
    
    // Start 2nd request
    await tester.tap(find.widgetWithText(PrimaryButton, 'Complete Lesson'));
    await tester.pump();
    
    // Verify 2nd is submitting
    expect(find.text('Submitting...'), findsOneWidget);
    
    // Resolve 1st request
    completer1.complete(LessonProgress(resumePosition: 0, watchedSeconds: 0, progressPercent: 100, completed: true, completedAt: DateTime.now()));
    await tester.pump(); // Pump once, not settle, to check if it clears submitting or shows snackbar
    
    // 1st request should be rejected as stale. Should STILL be submitting 2nd request.
    expect(find.text('Submitting...'), findsOneWidget); 
    expect(find.byType(SnackBar), findsNothing);
    
    // Resolve 2nd request
    completer2.complete(LessonProgress(resumePosition: 0, watchedSeconds: 0, progressPercent: 100, completed: true, completedAt: DateTime.now()));
    await tester.pumpAndSettle();
    
    expect(find.text('COMPLETED'), findsOneWidget);
  });

  testWidgets('invalidates assignment provider even when displayed lesson changed', (tester) async {
    final completer = Completer<LessonProgress>();
    final mockDelayedRepo = _MockDelayedLearningRepository(completer);
    
    int detailProviderFetchCount = 0;
    
    final mockDetail = AssignmentDetail(
      id: 1, trainingId: 101, trainingTitle: 'Safety Basics', versionNumber: 1, status: 'IN_PROGRESS', isOverdue: false,
      modules: [
        ModuleLearning(
          id: 5, title: 'Mod', description: '', position: 1,
          lessons: [
            LessonLearning(id: 10, title: 'Lesson A', position: 1, type: 'TEXT', isRequired: true, body: 'A', progress: LessonProgress(resumePosition: 0, watchedSeconds: 0, progressPercent: 0, completed: false)),
            LessonLearning(id: 11, title: 'Lesson B', position: 2, type: 'TEXT', isRequired: true, body: 'B', progress: LessonProgress(resumePosition: 0, watchedSeconds: 0, progressPercent: 0, completed: false)),
          ],
        ),
      ],
    );

    final container = ProviderContainer(
      overrides: [
        learningRepositoryProvider.overrideWithValue(mockDelayedRepo as LearningRepository),
        assignmentDetailProvider(1).overrideWith((ref) async {
          detailProviderFetchCount++;
          return mockDetail;
        }),
      ],
    );
    addTearDown(container.dispose);

    // Pump Lesson A
    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: const MaterialApp(home: TextLessonScreen(assignmentId: 1, lessonId: 10))),
    );
    await tester.pumpAndSettle();
    
    expect(detailProviderFetchCount, 1);

    // Start request for A
    await tester.tap(find.widgetWithText(PrimaryButton, 'Complete Lesson'));
    await tester.pump();

    // Nav to B
    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: const MaterialApp(home: TextLessonScreen(assignmentId: 1, lessonId: 11))),
    );
    await tester.pumpAndSettle();
    
    // Resolve A
    completer.complete(LessonProgress(resumePosition: 0, watchedSeconds: 0, progressPercent: 100, completed: true, completedAt: DateTime.now()));
    
    // Wait for invalidation
    await tester.pumpAndSettle();
    
    // Verify provider was fetched again due to invalidation
    expect(detailProviderFetchCount, 2);
  });
}

class _QueueMockRepo implements LearningRepository {
  final List<Completer<LessonProgress>> completers;
  int callCount = 0;
  _QueueMockRepo(this.completers);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
  @override
  Future<LessonProgress> completeTextLesson(int assignmentId, int lessonId) async {
    if (callCount < completers.length) {
      return completers[callCount++].future;
    }
    throw Exception('Out of completers');
  }
}

