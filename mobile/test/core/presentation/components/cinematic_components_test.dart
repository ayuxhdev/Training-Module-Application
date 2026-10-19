import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:training_app/core/presentation/components/cinematic_components.dart';
import 'package:training_app/core/presentation/components/status_badge.dart';
import 'package:training_app/core/theme/app_theme.dart';

void main() {
  testWidgets(
    'learning card supports keyboard activation and button semantics',
    (tester) async {
      var activated = 0;
      final semantics = tester.ensureSemantics();
      try {
        await tester.pumpWidget(
          MaterialApp(
            theme: AppTheme.darkTheme,
            home: Scaffold(
              body: LearningCard(
                title: 'Safe handling',
                subtitle: 'Version 3',
                status: 'IN_PROGRESS',
                badgeStatus: BadgeStatus.info,
                onTap: () => activated++,
              ),
            ),
          ),
        );
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        expect(activated, 1);
        expect(find.text('IN PROGRESS'), findsOneWidget);
        expect(
          tester.getSemantics(find.byType(InkWell)),
          matchesSemantics(
            label: 'Safe handling\nVersion 3\nIN PROGRESS',
            isButton: true,
            isFocusable: true,
            isFocused: true,
            hasTapAction: true,
            hasFocusAction: true,
          ),
        );
      } finally {
        semantics.dispose();
      }
    },
  );

  testWidgets('reduced motion renders entrance immediately without a tween', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: const CinematicEntrance(child: Text('Ready')),
        ),
      ),
    );
    expect(find.text('Ready'), findsOneWidget);
    expect(find.byType(TweenAnimationBuilder<double>), findsNothing);
    expect(tester.binding.transientCallbackCount, 0);
  });

  testWidgets('entrance settles once and does not animate continuously', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(home: CinematicEntrance(child: Text('Ready'))),
    );
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.widget<Opacity>(find.byType(Opacity).last).opacity, 1);
    expect(tester.binding.transientCallbackCount, 0);
  });

  testWidgets(
    'progress displays backend counts and updates to confirmed value',
    (tester) async {
      Widget progress(int completed) => MaterialApp(
        theme: AppTheme.lightTheme,
        home: Scaffold(
          body: LearningProgress(
            completed: completed,
            total: 4,
            label: '$completed of 4 confirmed',
          ),
        ),
      );
      await tester.pumpWidget(progress(1));
      expect(
        tester
            .widget<LinearProgressIndicator>(
              find.byType(LinearProgressIndicator),
            )
            .value,
        .25,
      );
      await tester.pumpWidget(progress(2));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<LinearProgressIndicator>(
              find.byType(LinearProgressIndicator),
            )
            .value,
        .5,
      );
      expect(find.text('2 of 4 confirmed'), findsOneWidget);
      await tester.pumpWidget(
        const MaterialApp(
          home: LearningProgress(completed: 0, total: 0, label: 'No lessons'),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<LinearProgressIndicator>(
              find.byType(LinearProgressIndicator),
            )
            .value,
        0,
      );
    },
  );
}
