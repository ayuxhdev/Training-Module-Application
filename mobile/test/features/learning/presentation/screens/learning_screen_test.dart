import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:training_app/core/presentation/components/custom_card.dart';
import 'package:training_app/core/presentation/components/empty_view.dart';
import 'package:training_app/core/presentation/components/error_view.dart';
import 'package:training_app/core/presentation/components/loading_view.dart';
import 'package:training_app/core/presentation/components/status_badge.dart';
import 'package:training_app/features/learning/domain/models/assignment.dart';
import 'package:training_app/features/learning/presentation/controllers/learning_controller.dart';
import 'package:training_app/features/learning/presentation/screens/learning_screen.dart';

import 'dart:async';

void main() {
  Widget createTestWidget(ProviderContainer container) {
    return UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(
        home: LearningScreen(),
      ),
    );
  }

  testWidgets('shows LoadingView while fetching assignments', (tester) async {
    final completer = Completer<List<Assignment>>();
    final container = ProviderContainer(
      overrides: [
        assignmentListProvider.overrideWith((ref) => completer.future),
      ],
    );

    await tester.pumpWidget(createTestWidget(container));
    expect(find.byType(LoadingView), findsOneWidget);
    
    // Clean up
    completer.complete([]);
  });

  testWidgets('shows EmptyView when assignment list is empty', (tester) async {
    final container = ProviderContainer(
      overrides: [
        assignmentListProvider.overrideWith((ref) async => []),
      ],
    );

    await tester.pumpWidget(createTestWidget(container));
    await tester.pumpAndSettle();

    expect(find.byType(EmptyView), findsOneWidget);
    expect(find.text('No assignments found.'), findsOneWidget);
  });

  testWidgets('shows ErrorView when fetching assignments fails', (tester) async {
    final container = ProviderContainer(
      overrides: [
        assignmentListProvider.overrideWith((ref) async {
          throw Exception('Failed to fetch assignments');
        }),
      ],
    );

    await tester.pumpWidget(createTestWidget(container));
    await tester.pumpAndSettle();

    expect(find.byType(ErrorView), findsOneWidget);
  });

  testWidgets('shows Assignment list on successful fetch', (tester) async {
    final mockAssignments = [
        Assignment(
          id: 1,
          trainingId: 101,
          trainingTitle: 'Safety Basics',
          versionNumber: 1,
          status: 'COMPLETED',
          isOverdue: false,
          progressSummary: ProgressSummary(requiredLessonsCompleted: 5, requiredLessonsTotal: 5),
          dueAt: DateTime(2023, 10, 1),
        ),
        Assignment(
          id: 2,
          trainingId: 102,
          trainingTitle: 'Advanced Safety',
          versionNumber: 2,
          status: 'IN_PROGRESS',
          isOverdue: true,
          progressSummary: ProgressSummary(requiredLessonsCompleted: 1, requiredLessonsTotal: 5),
          dueAt: DateTime(2023, 9, 1),
        ),
      ];

      final container = ProviderContainer(
        overrides: [
          assignmentListProvider.overrideWith((ref) async => mockAssignments),
        ],
      );

      await tester.pumpWidget(createTestWidget(container));
      await tester.pumpAndSettle();

      expect(find.byType(CustomCard), findsNWidgets(2));
      expect(find.text('Safety Basics'), findsOneWidget);
      expect(find.text('Advanced Safety'), findsOneWidget);
      expect(find.byType(StatusBadge), findsNWidgets(2));
      expect(find.text('Progress: 5/5'), findsOneWidget);
      expect(find.text('Progress: 1/5'), findsOneWidget);
      
      // Check date formats manually (since we didn't use intl, it's YYYY-MM-DD)
      expect(find.text('Due: 2023-10-01'), findsOneWidget);
      expect(find.text('Due: 2023-09-01'), findsOneWidget);
  });
}
