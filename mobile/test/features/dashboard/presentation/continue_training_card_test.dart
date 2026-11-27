import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:training_app/core/theme/app_theme.dart';
import 'package:training_app/core/theme/cadence_theme.dart';
import 'package:training_app/features/dashboard/domain/models/dashboard_data.dart';
import 'package:training_app/features/dashboard/presentation/widgets/continue_training_card.dart';

DashboardAssignment assignment({
  String title = 'Safety v1',
  bool overdue = false,
}) => DashboardAssignment(
  id: 17,
  trainingId: 3,
  trainingTitle: title,
  versionNumber: 2,
  status: 'IN_PROGRESS',
  isOverdue: overdue,
  dueAt: overdue ? DateTime(2026, 1, 2) : null,
);
Widget app({
  String title = 'Safety v1',
  double scale = 1,
  bool loading = false,
  bool enabled = true,
  bool reduced = false,
  VoidCallback? onContinue,
  bool overdue = false,
}) => MaterialApp(
  theme: CadenceTheme.from(AppTheme.lightTheme),
  home: MediaQuery(
    data: MediaQueryData(
      textScaler: TextScaler.linear(scale),
      disableAnimations: reduced,
    ),
    child: Scaffold(
      body: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: ContinueTrainingCard(
            assignment: assignment(title: title, overdue: overdue),
            onContinue: enabled ? (onContinue ?? () {}) : null,
            isLoading: loading,
          ),
        ),
      ),
    ),
  ),
);
void main() {
  testWidgets('real assignment metadata, no invented lesson progress', (
    tester,
  ) async {
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    expect(find.text('Safety v1'), findsOneWidget);
    expect(find.text('In progress'), findsOneWidget);
    expect(find.text('Version 2'), findsOneWidget);
    expect(find.text('No deadline'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsNothing);
  });
  testWidgets(
    'compact standard card has a 48px action with keyboard activation',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      var calls = 0;
      await tester.pumpWidget(app(onContinue: () => calls++));
      await tester.pumpAndSettle();
      expect(
        tester.getSize(find.byType(ContinueTrainingCard)).height,
        lessThanOrEqualTo(230),
      );
      expect(
        tester.getSize(find.byType(ElevatedButton)).height,
        greaterThanOrEqualTo(48),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(calls, 1);
    },
  );
  for (final width in [320.0, 390.0, 414.0]) {
    for (final scale in [1.0, 1.5, 2.0]) {
      testWidgets('long title fits width $width at ${scale}x text', (
        tester,
      ) async {
        await tester.binding.setSurfaceSize(Size(width, 844));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        const title =
            'Safe operation and maintenance of manufacturing equipment with extended training instructions';
        await tester.pumpWidget(app(title: title, scale: scale));
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(find.text('Continue training'), 150);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(tester.widget<Text>(find.text(title)).maxLines, isNull);
        expect(
          MediaQuery.textScalerOf(tester.element(find.text(title))).scale(12),
          12 * scale,
        );
        if (scale == 2) {
          expect(
            tester.getSize(find.text(title)).width,
            greaterThanOrEqualTo(width - 72),
          );
          expect(find.byIcon(Icons.arrow_forward), findsNothing);
        }
        expect(
          tester.getSize(find.byType(ElevatedButton)).height,
          greaterThanOrEqualTo(48),
        );
      });
    }
  }
  testWidgets('overdue is additional to the lifecycle state', (tester) async {
    await tester.pumpWidget(app(overdue: true));
    await tester.pumpAndSettle();
    expect(find.text('In progress'), findsOneWidget);
    expect(find.text('Overdue'), findsOneWidget);
    expect(find.text('Due 2026-01-02'), findsOneWidget);
  });
  testWidgets('disabled and loading actions never submit', (tester) async {
    var calls = 0;
    await tester.pumpWidget(app(enabled: false, onContinue: () => calls++));
    await tester.pumpAndSettle();
    expect(
      tester.widget<ElevatedButton>(find.byType(ElevatedButton)).onPressed,
      isNull,
    );
    await tester.pumpWidget(app(loading: true, onContinue: () => calls++));
    await tester.pump();
    expect(
      tester.widget<ElevatedButton>(find.byType(ElevatedButton)).onPressed,
      isNull,
    );
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(calls, 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets(
    'reduced motion loading stays announced without an animated spinner',
    (tester) async {
      final semantics = tester.ensureSemantics();
      await tester.pumpWidget(app(loading: true, reduced: true));
      await tester.pumpAndSettle();
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.byIcon(Icons.hourglass_empty), findsOneWidget);
      expect(find.bySemanticsLabel('Continue training'), findsWidgets);
      semantics.dispose();
    },
  );
}
