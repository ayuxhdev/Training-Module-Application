import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:training_app/core/presentation/components/cinematic_notice.dart';
import 'package:training_app/core/theme/app_theme.dart';
import 'package:training_app/features/assessments/presentation/widgets/assessment_choice.dart';

double contrast(Color foreground, Color background) {
  final values = [foreground.computeLuminance(), background.computeLuminance()]
    ..sort();
  return (values.last + .05) / (values.first + .05);
}

void main() {
  for (final brightness in Brightness.values) {
    final theme = brightness == Brightness.dark
        ? AppTheme.darkTheme
        : AppTheme.lightTheme;
    testWidgets(
      '${brightness.name} choices keep selected text readable and keyboard-operable',
      (tester) async {
        var selected = false;
        final semantics = tester.ensureSemantics();
        try {
          await tester.pumpWidget(
            MaterialApp(
              theme: theme,
              home: Scaffold(
                body: StatefulBuilder(
                  builder: (context, setState) => AssessmentChoice(
                    text: 'Report a hazard before continuing.',
                    selected: selected,
                    onPressed: () => setState(() => selected = true),
                  ),
                ),
              ),
            ),
          );
          await tester.sendKeyEvent(LogicalKeyboardKey.tab);
          await tester.sendKeyEvent(LogicalKeyboardKey.enter);
          await tester.pumpAndSettle();
          expect(selected, isTrue);
          final choice = tester.widget<AssessmentChoice>(
            find.byType(AssessmentChoice),
          );
          expect(choice.selected, isTrue);
          final selectedSemantics = tester.widgetList<Semantics>(
            find.ancestor(
              of: find.text(choice.text),
              matching: find.byType(Semantics),
            ),
          );
          expect(
            selectedSemantics.any((item) => item.properties.selected == true),
            isTrue,
          );
          final style = tester
              .widget<OutlinedButton>(find.byType(OutlinedButton))
              .style!;
          expect(
            contrast(
              style.foregroundColor!.resolve({})!,
              style.backgroundColor!.resolve({})!,
            ),
            greaterThanOrEqualTo(4.5),
          );
          await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
          await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
        } finally {
          semantics.dispose();
        }
      },
    );

    testWidgets(
      '${brightness.name} persistent notice has readable error feedback',
      (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            theme: theme,
            home: const Scaffold(
              body: CinematicNotice(
                message: 'Check the submission status.',
                isError: true,
              ),
            ),
          ),
        );
        final text = tester.widget<Text>(
          find.text('Check the submission status.'),
        );
        final box = tester.widget<DecoratedBox>(
          find.descendant(
            of: find.byType(CinematicNotice),
            matching: find.byType(DecoratedBox),
          ),
        );
        expect(
          contrast(
            text.style!.color!,
            (box.decoration as BoxDecoration).color!,
          ),
          greaterThanOrEqualTo(4.5),
        );
        await tester.pump(const Duration(seconds: 8));
        expect(find.text('Check the submission status.'), findsOneWidget);
      },
    );
  }

  testWidgets(
    'reduced motion disables selection animation and disabled choices reject taps',
    (tester) async {
      var calls = 0;
      Widget app(VoidCallback? action) => MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: Scaffold(
            body: AssessmentChoice(
              text: 'Keep clear',
              selected: false,
              onPressed: action,
            ),
          ),
        ),
      );
      await tester.pumpWidget(app(() => calls++));
      expect(
        tester
            .widget<OutlinedButton>(find.byType(OutlinedButton))
            .style!
            .animationDuration,
        Duration.zero,
      );
      await tester.tap(find.text('Keep clear'));
      expect(calls, 1);
      await tester.pumpWidget(app(null));
      await tester.tap(find.text('Keep clear'));
      expect(calls, 1);
    },
  );
}
