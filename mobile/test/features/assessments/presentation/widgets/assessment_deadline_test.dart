import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:training_app/features/assessments/domain/models/assessment.dart';
import 'package:training_app/features/assessments/presentation/widgets/assessment_deadline.dart';

import '../../assessment_fixtures.dart';

void main() {
  for (final reduced in [false, true]) {
    testWidgets('milestones have bounded live semantics (reduced: $reduced)', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      try {
        var now = DateTime.utc(2040);
        final summary = AssessmentAttemptSummary.fromJson({
          ...summaryJson(),
          'deadline_at': now
              .add(const Duration(seconds: 125))
              .toIso8601String(),
        });
        Widget page() => MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(disableAnimations: reduced),
            child: Scaffold(
              body: Column(
                children: [
                  const Text('Before countdown'),
                  AssessmentDeadline(summary: summary, now: () => now),
                  const Text('After countdown'),
                ],
              ),
            ),
          ),
        );
        await tester.pumpWidget(page());
        Future<void> advance(int seconds) async {
          now = now.add(Duration(seconds: seconds));
          await tester.pump(Duration(seconds: seconds));
        }

        SemanticsNode milestone(String label) {
          final node = tester.getSemantics(
            find.byWidgetPredicate(
              (widget) =>
                  widget is Semantics &&
                  widget.properties.liveRegion == true &&
                  widget.properties.label == label,
            ),
          );
          expect(node.label, label);
          expect(node.getSemanticsData().flagsCollection.isLiveRegion, isTrue);
          expect(node.rect.isEmpty, isFalse);
          expect(node.getSemanticsData().flagsCollection.isHidden, isFalse);
          var root = node;
          while (root.parent != null) {
            root = root.parent!;
          }
          final liveNodes = <SemanticsNode>[];
          final orderedLabels = <String>[];
          void visit(SemanticsNode candidate) {
            orderedLabels.add(candidate.label);
            if (candidate.getSemanticsData().flagsCollection.isLiveRegion) {
              liveNodes.add(candidate);
            }
            for (final child in candidate.debugListChildrenInOrder(
              DebugSemanticsDumpOrder.traversalOrder,
            )) {
              visit(child);
            }
          }

          visit(root);
          expect(liveNodes.map((n) => n.label), [label]);
          expect(
            orderedLabels.indexOf('Before countdown'),
            lessThan(orderedLabels.indexOf(label)),
          );
          expect(
            orderedLabels.indexOf('After countdown'),
            greaterThan(orderedLabels.indexOf(label)),
          );
          return node;
        }

        await advance(5);
        final nodeId = milestone('2 minutes or less remaining.').id;
        await advance(1);
        expect(milestone('2 minutes or less remaining.').id, nodeId);
        expect(find.text('Time remaining: 1:59'), findsOneWidget);
        await advance(59);
        expect(milestone('1 minute or less remaining.').id, nodeId);
        await advance(1);
        expect(milestone('1 minute or less remaining.').id, nodeId);
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        now = now.add(const Duration(seconds: 60));
        await tester.pump(const Duration(seconds: 60));
        milestone('1 minute or less remaining.');
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pump();
        const expired =
            'Deadline reached. Submit to confirm the result with the server.';
        expect(milestone(expired).id, nodeId);
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pump();
        expect(milestone(expired).id, nodeId);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(seconds: 2));
        expect(find.bySemanticsLabel(expired), findsNothing);
        await tester.pumpWidget(page());
        milestone(expired);
        expect(summary.status, AttemptStatus.inProgress);
        await tester.pumpWidget(const SizedBox.shrink());
        expect(tester.takeException(), isNull);
      } finally {
        semantics.dispose();
      }
    });
  }

  testWidgets(
    'visual ticks are nonlive; only 2m, 1m and expiry change announcements',
    (tester) async {
      var now = DateTime.utc(2040);
      var reads = 0;
      final summary = AssessmentAttemptSummary.fromJson({
        ...summaryJson(),
        'deadline_at': now.add(const Duration(seconds: 125)).toIso8601String(),
      });
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(disableAnimations: true),
            child: Scaffold(
              body: AssessmentDeadline(
                summary: summary,
                now: () {
                  reads++;
                  return now;
                },
              ),
            ),
          ),
        ),
      );
      String? announcement() => tester
          .widgetList<Semantics>(find.byType(Semantics))
          .where(
            (w) =>
                w.properties.liveRegion == true && w.properties.label != null,
          )
          .map((w) => w.properties.label)
          .firstOrNull;
      Future<void> advance(int seconds) async {
        now = now.add(Duration(seconds: seconds));
        await tester.pump(Duration(seconds: seconds));
      }

      expect(find.text('Time remaining: 2:05'), findsOneWidget);
      expect(announcement(), isNull);
      await advance(5);
      expect(find.text('Time remaining: 2:00'), findsOneWidget);
      expect(announcement(), '2 minutes or less remaining.');
      await advance(1);
      expect(find.text('Time remaining: 1:59'), findsOneWidget);
      expect(announcement(), '2 minutes or less remaining.');
      await advance(59);
      expect(find.text('Time remaining: 1:00'), findsOneWidget);
      expect(announcement(), '1 minute or less remaining.');
      await advance(1);
      expect(find.text('Time remaining: 0:59'), findsOneWidget);
      expect(announcement(), '1 minute or less remaining.');
      // Exact visual time stays readable, but its notice is not a live region.
      final countdown = find.ancestor(
        of: find.text('Time remaining: 0:59'),
        matching: find.byWidgetPredicate(
          (w) => w is Semantics && w.properties.liveRegion == true,
        ),
      );
      expect(countdown, findsNothing);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      now = now.add(const Duration(seconds: 60));
      await tester.pump(const Duration(seconds: 60));
      expect(announcement(), '1 minute or less remaining.');
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(
        announcement(),
        'Deadline reached. Submit to confirm the result with the server.',
      );
      expect(
        summary.status,
        AttemptStatus.inProgress,
      ); // No local grading/submission.
      final expiredReads = reads;
      await advance(2);
      expect(reads, expiredReads);
      expect(
        announcement(),
        'Deadline reached. Submit to confirm the result with the server.',
      );
      await tester.pumpWidget(const SizedBox.shrink());
      final afterDispose = reads;
      await tester.pump(const Duration(seconds: 10));
      expect(reads, afterDispose);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('untimed attempts have no countdown or periodic clock reads', (
    tester,
  ) async {
    var reads = 0;
    final summary = AssessmentAttemptSummary.fromJson({
      ...summaryJson(),
      'deadline_at': null,
    });
    await tester.pumpWidget(
      MaterialApp(
        home: AssessmentDeadline(
          summary: summary,
          now: () {
            reads++;
            return DateTime.utc(2040);
          },
        ),
      ),
    );
    final initial = reads;
    await tester.pump(const Duration(minutes: 2));
    expect(reads, initial);
    expect(find.textContaining('Time remaining'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
