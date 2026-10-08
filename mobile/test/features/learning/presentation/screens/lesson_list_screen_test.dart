import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:training_app/core/presentation/components/error_view.dart';
import 'package:training_app/core/presentation/components/loading_view.dart';
import 'package:training_app/core/presentation/components/empty_view.dart';
import 'package:training_app/features/learning/domain/models/assignment_detail.dart';
import 'package:training_app/features/learning/presentation/controllers/learning_controller.dart';
import 'package:training_app/features/learning/presentation/screens/lesson_list_screen.dart';
import 'dart:async';

void main() {
  Widget createTestWidget(ProviderContainer container) {
    return UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(
        home: LessonListScreen(assignmentId: 1, moduleId: 10),
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

  testWidgets('shows ErrorView when module is not found', (tester) async {
    final mockDetail = AssignmentDetail(
      id: 1, trainingId: 101, trainingTitle: 'Safety Basics', versionNumber: 1, status: 'IN_PROGRESS', isOverdue: false,
      modules: [], // No module 10
    );

    final container = ProviderContainer(
      overrides: [
        assignmentDetailProvider(1).overrideWith((ref) async => mockDetail),
      ],
    );

    await tester.pumpWidget(createTestWidget(container));
    await tester.pumpAndSettle();
    expect(find.byType(ErrorView), findsOneWidget);
    expect(find.text('Module not found'), findsOneWidget);
  });

  testWidgets('shows EmptyView when there are no lessons', (tester) async {
    final mockDetail = AssignmentDetail(
      id: 1, trainingId: 101, trainingTitle: 'Safety Basics', versionNumber: 1, status: 'IN_PROGRESS', isOverdue: false,
      modules: [
        ModuleLearning(id: 10, title: 'Module 1', description: 'Desc 1', position: 1, lessons: []),
      ],
    );

    final container = ProviderContainer(
      overrides: [
        assignmentDetailProvider(1).overrideWith((ref) async => mockDetail),
      ],
    );

    await tester.pumpWidget(createTestWidget(container));
    await tester.pumpAndSettle();
    expect(find.byType(EmptyView), findsOneWidget);
    expect(find.text('No lessons found in this module.'), findsOneWidget);
  });

  testWidgets('shows lessons list successfully', (tester) async {
    final mockDetail = AssignmentDetail(
      id: 1, trainingId: 101, trainingTitle: 'Safety Basics', versionNumber: 1, status: 'IN_PROGRESS', isOverdue: false,
      modules: [
        ModuleLearning(id: 10, title: 'Module 1', description: 'Desc 1', position: 1, lessons: [
          LessonLearning(
            id: 100, title: 'Lesson 1', position: 1, type: 'VIDEO', isRequired: true, body: '',
            progress: LessonProgress(resumePosition: 0, watchedSeconds: 0, progressPercent: 0, completed: false),
          ),
        ]),
      ],
    );

    final container = ProviderContainer(
      overrides: [
        assignmentDetailProvider(1).overrideWith((ref) async => mockDetail),
      ],
    );

    await tester.pumpWidget(createTestWidget(container));
    await tester.pumpAndSettle();

    expect(find.text('1. Lesson 1'), findsOneWidget);
    expect(find.text('VIDEO'), findsOneWidget);
    expect(find.text('PENDING'), findsOneWidget);
    expect(find.text('• REQUIRED'), findsOneWidget);
  });
}

