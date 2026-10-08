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

    await tester.pumpWidget(createTestWidget(container));
    await tester.pumpAndSettle();
    expect(find.byType(ErrorView), findsOneWidget);
    expect(find.text('Lesson not found'), findsOneWidget);
  });

  testWidgets('shows ErrorView when lesson is not TEXT type', (tester) async {
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

    await tester.pumpWidget(createTestWidget(container));
    await tester.pumpAndSettle();
    expect(find.byType(ErrorView), findsOneWidget);
    expect(find.text('This screen only supports text lessons.'), findsOneWidget);
  });

  testWidgets('shows incomplete lesson and handles complete action', (tester) async {
    final mockRepo = MockLearningRepository();
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

    await tester.pumpWidget(createTestWidget(container));
    await tester.pumpAndSettle();

    expect(find.text('Text Lesson'), findsOneWidget);
    expect(find.text('Some lesson content here.'), findsOneWidget);
    expect(find.text('INCOMPLETE'), findsOneWidget);
    
    final button = find.widgetWithText(PrimaryButton, 'Complete Lesson');
    expect(button, findsOneWidget);

    await tester.tap(button);
    await tester.pump(); // Start async action

    // We can't pumpAndSettle if there's a navigation or something that requires go_router if we don't mock go_router context
    // Wait, the completion calls context.pop(). Since we don't have go_router in this test (just MaterialApp), context.pop will pop the root navigator.
    await tester.pumpAndSettle();
    
    expect(mockRepo.completeCalled, isTrue);
  });
  
  testWidgets('shows completed lesson with Back button', (tester) async {
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

    await tester.pumpWidget(createTestWidget(container));
    await tester.pumpAndSettle();

    expect(find.text('Text Lesson Completed'), findsOneWidget);
    expect(find.text('COMPLETED'), findsOneWidget);
    expect(find.widgetWithText(PrimaryButton, 'Back to Module'), findsOneWidget);
    expect(find.widgetWithText(PrimaryButton, 'Complete Lesson'), findsNothing);
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

    await tester.pumpWidget(createTestWidget(container));
    await tester.pumpAndSettle();
    
    final button = find.widgetWithText(PrimaryButton, 'Complete Lesson');
    await tester.tap(button);
    await tester.pump();
    await tester.pumpAndSettle();
    
    expect(find.text('Friendly network error message from API'), findsOneWidget);
    expect(find.text('Exception: Friendly network error message from API'), findsNothing);
  });
}

