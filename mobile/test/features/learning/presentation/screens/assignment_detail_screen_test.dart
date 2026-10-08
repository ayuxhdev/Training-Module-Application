import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:training_app/core/presentation/components/error_view.dart';
import 'package:training_app/core/presentation/components/loading_view.dart';
import 'package:training_app/core/presentation/components/primary_button.dart';
import 'package:training_app/features/learning/domain/models/assignment_detail.dart';
import 'package:training_app/features/learning/presentation/controllers/learning_controller.dart';
import 'package:training_app/features/learning/presentation/screens/assignment_detail_screen.dart';
import 'dart:async';

void main() {
  Widget createTestWidget(ProviderContainer container) {
    return UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(
        home: AssignmentDetailScreen(assignmentId: 1),
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
      id: 1,
      trainingId: 101,
      trainingTitle: 'Cleanup',
      versionNumber: 1,
      status: 'ASSIGNED',
      isOverdue: false,
      modules: [],
    ));
    await tester.pumpAndSettle();
  });

  testWidgets('shows ErrorView when fetching detail fails', (tester) async {
    final container = ProviderContainer(
      overrides: [
        assignmentDetailProvider(1).overrideWith((ref) async {
          throw Exception('Failed to fetch detail');
        }),
      ],
    );

    await tester.pumpWidget(createTestWidget(container));
    await tester.pumpAndSettle();

    expect(find.byType(ErrorView), findsOneWidget);
  });

  testWidgets('shows AssignmentDetail on successful fetch and handles primary button tap', (tester) async {
    final mockDetail = AssignmentDetail(
      id: 1,
      trainingId: 101,
      trainingTitle: 'Safety Basics',
      versionNumber: 1,
      status: 'IN_PROGRESS',
      isOverdue: false,
      dueAt: DateTime(2023, 10, 1),
      modules: [],
    );

    final container = ProviderContainer(
      overrides: [
        assignmentDetailProvider(1).overrideWith((ref) async => mockDetail),
      ],
    );

    await tester.pumpWidget(createTestWidget(container));
    await tester.pumpAndSettle();

    expect(find.text('Safety Basics'), findsOneWidget);
    expect(find.text('Due: 2023-10-01'), findsOneWidget);
    expect(find.text('Progress: 0/0 lessons'), findsOneWidget);
    
    expect(find.text('Progress: 0/0 lessons'), findsOneWidget);
    expect(find.byType(PrimaryButton), findsOneWidget);
  });

  testWidgets('Start Training button navigates to modules list route', (tester) async {
    final mockDetail = AssignmentDetail(
      id: 1,
      trainingId: 101,
      trainingTitle: 'Safety Basics',
      versionNumber: 1,
      status: 'IN_PROGRESS',
      isOverdue: false,
      dueAt: DateTime(2023, 10, 1),
      modules: [],
    );

    final container = ProviderContainer(
      overrides: [
        assignmentDetailProvider(1).overrideWith((ref) async => mockDetail),
      ],
    );

    final router = GoRouter(
      initialLocation: '/detail',
      routes: [
        GoRoute(
          path: '/detail',
          builder: (context, state) => const AssignmentDetailScreen(assignmentId: 1),
        ),
        GoRoute(
          path: '/learning/assignments/:id/modules',
          builder: (context, state) => Text('Modules Route for ${state.pathParameters['id']}'),
        ),
      ],
    );

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(
          routerConfig: router,
        ),
      ),
    );

    await tester.pumpAndSettle();

    final button = find.widgetWithText(PrimaryButton, 'Start Training');
    expect(button, findsOneWidget);

    await tester.tap(button);
    await tester.pumpAndSettle();

    expect(find.text('Modules Route for 1'), findsOneWidget);
  });
}
