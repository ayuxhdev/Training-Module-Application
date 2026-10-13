import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:training_app/core/errors/api_error.dart';
import 'package:training_app/core/presentation/components/primary_button.dart';
import 'package:training_app/core/presentation/components/loading_view.dart';
import 'package:training_app/features/learning/data/repositories/learning_repository.dart';
import 'package:training_app/features/learning/domain/models/assignment.dart';
import 'package:training_app/features/learning/domain/models/assignment_detail.dart';
import 'package:training_app/features/learning/presentation/controllers/learning_controller.dart';
import 'package:training_app/features/learning/presentation/screens/text_lesson_screen.dart';

LessonProgress progress(bool completed) => LessonProgress(
  resumePosition: 0,
  watchedSeconds: 0,
  progressPercent: completed ? 100 : 0,
  completed: completed,
);

class CompletionRepository implements LearningRepository {
  final responses = <int, Completer<LessonProgress>>{};
  final completed = <int>{};
  final calls = <int>[];
  int detailFetches = 0;
  int listFetches = 0;
  Completer<void>? refreshGate;

  @override
  Future<LessonProgress> completeTextLesson(
    int assignmentId,
    int lessonId,
  ) async {
    calls.add(lessonId);
    final result = await responses[lessonId]!.future;
    if (result.completed) completed.add(lessonId);
    return result;
  }

  @override
  Future<AssignmentDetail> getAssignmentDetail(int assignmentId) async {
    detailFetches++;
    if (detailFetches > 1 && refreshGate != null) await refreshGate!.future;
    return AssignmentDetail(
      id: assignmentId,
      trainingId: 1,
      trainingTitle: 'Training',
      versionNumber: 1,
      status: 'IN_PROGRESS',
      isOverdue: false,
      modules: [
        ModuleLearning(
          id: 1,
          title: 'Module',
          description: '',
          position: 1,
          lessons: [
            for (final id in [10, 11])
              LessonLearning(
                id: id,
                title: 'Lesson $id',
                position: id,
                type: 'TEXT',
                isRequired: true,
                body: 'Content',
                progress: progress(completed.contains(id)),
              ),
          ],
        ),
      ],
    );
  }

  @override
  Future<List<Assignment>> getAssignments() async {
    listFetches++;
    return [
      Assignment(
        id: 1,
        trainingId: 1,
        trainingTitle: 'Training',
        versionNumber: 1,
        status: 'IN_PROGRESS',
        isOverdue: false,
        progressSummary: ProgressSummary(
          requiredLessonsCompleted: completed.length,
          requiredLessonsTotal: 2,
        ),
      ),
    ];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late CompletionRepository repository;
  late ProviderContainer container;
  final completeButton = find.widgetWithText(PrimaryButton, 'Complete Lesson');

  void prepare({bool disposeAfterTest = true}) {
    repository = CompletionRepository();
    repository.responses[10] = Completer<LessonProgress>();
    repository.responses[11] = Completer<LessonProgress>();
    container = ProviderContainer(
      overrides: [learningRepositoryProvider.overrideWithValue(repository)],
    );
    container.listen(assignmentDetailProvider(1), (_, _) {});
    container.listen(assignmentListProvider, (_, _) {});
    if (disposeAfterTest) addTearDown(container.dispose);
  }

  Future<void> showLesson(WidgetTester tester, int id) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: TextLessonScreen(assignmentId: 1, lessonId: id),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> expectRefreshedCaches(WidgetTester tester) async {
    container.read(assignmentDetailProvider(1));
    container.read(assignmentListProvider);
    await tester.pump(const Duration(milliseconds: 1));
    expect(repository.completed, contains(10));
    final detail = container.read(assignmentDetailProvider(1)).requireValue;
    final assignments = container.read(assignmentListProvider).requireValue;
    expect(detail.modules.single.lessons.first.progress.completed, isTrue);
    expect(assignments.single.progressSummary.requiredLessonsCompleted, 1);
    expect(repository.detailFetches, 2);
    expect(repository.listFetches, 2);
  }

  for (final systemBack in [false, true]) {
    testWidgets(
      'completion survives ${systemBack ? 'system' : 'AppBar'} back',
      (tester) async {
        prepare();
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              home: Scaffold(
                body: Builder(
                  builder: (context) => TextButton(
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const TextLessonScreen(
                          assignmentId: 1,
                          lessonId: 10,
                        ),
                      ),
                    ),
                    child: const Text('Open lesson'),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Open lesson'));
        await tester.pumpAndSettle();
        await tester.tap(completeButton);
        await tester.pump();
        if (systemBack) {
          await tester.binding.handlePopRoute();
        } else {
          await tester.tap(find.byType(BackButton));
        }
        await tester.pumpAndSettle();
        expect(find.byType(TextLessonScreen), findsNothing);

        repository.responses[10]!.complete(progress(true));
        await tester.pumpAndSettle();
        await expectRefreshedCaches(tester);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'successful stale completion survives a different lesson failure',
    (tester) async {
      prepare();
      await showLesson(tester, 10);
      await tester.tap(completeButton);
      await tester.pump();
      await showLesson(tester, 11);
      await tester.tap(completeButton);
      await tester.pump();

      repository.responses[10]!.complete(progress(true));
      await tester.pump();
      expect(find.text('Lesson completed successfully'), findsNothing);
      repository.responses[11]!.completeError(ApiError.networkFailure());
      await tester.pumpAndSettle();
      expect(find.text('Lesson 11'), findsOneWidget);
      expect(find.text('INCOMPLETE'), findsOneWidget);
      expect(completeButton, findsOneWidget);
      await expectRefreshedCaches(tester);

      await showLesson(tester, 10);
      expect(find.text('COMPLETED'), findsOneWidget);
      expect(completeButton, findsNothing);
    },
  );

  testWidgets('rapid switching and repeated taps share one pending request', (
    tester,
  ) async {
    prepare();
    await showLesson(tester, 10);
    await tester.tap(completeButton);
    await tester.tap(completeButton);
    await tester.pump();
    expect(repository.calls, [10]);
    await showLesson(tester, 11);
    await showLesson(tester, 10);
    await tester.tap(completeButton);
    await tester.pump();
    expect(repository.calls, [10]);

    repository.responses[10]!.complete(progress(true));
    await tester.pump();
    expect(completeButton, findsNothing);
    await tester.pumpAndSettle();
    expect(find.text('COMPLETED'), findsOneWidget);
    await expectRefreshedCaches(tester);
    expect(repository.calls, [10]);
  });

  testWidgets(
    'returning during refresh never offers completion from stale data',
    (tester) async {
      prepare();
      await showLesson(tester, 10);
      await tester.tap(completeButton);
      await tester.pump();
      await tester.pumpWidget(const SizedBox());
      repository.refreshGate = Completer<void>();
      repository.responses[10]!.complete(progress(true));
      await tester.pump();
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            home: TextLessonScreen(assignmentId: 1, lessonId: 10),
          ),
        ),
      );
      await tester.pump();
      expect(find.byType(LoadingView), findsOneWidget);
      expect(completeButton, findsNothing);
      expect(repository.calls, [10]);

      repository.refreshGate!.complete();
      await tester.pumpAndSettle();
      expect(find.text('COMPLETED'), findsOneWidget);
      expect(completeButton, findsNothing);
      await expectRefreshedCaches(tester);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('unconfirmed completion does not credit or refresh caches', (
    tester,
  ) async {
    prepare();
    await showLesson(tester, 10);
    await tester.tap(completeButton);
    await tester.pump();
    repository.responses[10]!.complete(progress(false));
    await tester.pumpAndSettle();
    expect(find.text('INCOMPLETE'), findsOneWidget);
    expect(
      find.text('Completion was not confirmed. Please try again.'),
      findsOneWidget,
    );
    expect(repository.detailFetches, 1);
    expect(repository.listFetches, 1);
  });

  testWidgets('failed completion can be retried without a cached error', (
    tester,
  ) async {
    prepare();
    await showLesson(tester, 10);
    await tester.tap(completeButton);
    await tester.pump();
    repository.responses[10]!.completeError(ApiError.networkFailure());
    await tester.pumpAndSettle();
    repository.responses[10] = Completer<LessonProgress>();
    await tester.tap(completeButton);
    await tester.pump();
    repository.responses[10]!.complete(progress(true));
    await tester.pumpAndSettle();
    expect(repository.calls, [10, 10]);
    expect(find.text('COMPLETED'), findsOneWidget);
    await expectRefreshedCaches(tester);
  });

  test(
    'container disposal while pending does not access disposed providers',
    () async {
      prepare(disposeAfterTest: false);
      final pending = container.read(
        textLessonCompletionProvider((assignmentId: 1, lessonId: 10)).future,
      );
      container.dispose();
      repository.responses[10]!.complete(progress(true));
      expect((await pending).completed, isTrue);
    },
  );
}
