import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:training_app/core/presentation/components/content_skeleton.dart';
import 'package:training_app/core/theme/app_theme.dart';

void main() {
  testWidgets(
    'dashboard placeholder metrics use a row at tablet width with 16dp gaps',
    (tester) async {
      tester.view.physicalSize = const Size(800, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.lightTheme,
          home: const Scaffold(body: SkeletonPage(child: DashboardSkeleton())),
        ),
      );
      final cards = find.byType(Card);
      final first = tester.getRect(cards.at(1));
      final second = tester.getRect(cards.at(2));
      expect(first.top, second.top);
      expect(second.left - first.right, 16);
      expect(tester.takeException(), isNull);
    },
  );

  for (final brightness in Brightness.values) {
    testWidgets('static skeletons fit narrow large text in $brightness', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(280, 500);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final semantics = tester.ensureSemantics();
      try {
        for (final entry in <(Widget, String)>[
          (const DashboardSkeleton(), 'Loading dashboard'),
          (const LearningSkeleton(), 'Loading assignments'),
          (const ManagementSkeleton(), 'Loading management dashboard'),
          (
            const CardListSkeleton(message: 'Loading certificates'),
            'Loading certificates',
          ),
          (
            const CardListSkeleton(message: 'Loading employees', compact: true),
            'Loading employees',
          ),
        ]) {
          await tester.pumpWidget(
            MaterialApp(
              theme: brightness == Brightness.dark
                  ? AppTheme.darkTheme
                  : AppTheme.lightTheme,
              home: MediaQuery(
                data: const MediaQueryData(
                  disableAnimations: true,
                  textScaler: TextScaler.linear(2),
                ),
                child: Scaffold(body: SkeletonPage(child: entry.$1)),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(find.bySemanticsLabel(entry.$2), findsOneWidget);
          final node = tester.getSemantics(find.bySemanticsLabel(entry.$2));
          expect(node.childrenCount, 0); // One announcement; no shape nodes.
          expect(tester.binding.transientCallbackCount, 0);
          expect(find.byType(CircularProgressIndicator), findsNothing);
          expect(tester.takeException(), isNull);
          await tester.drag(
            find.byType(SingleChildScrollView),
            const Offset(0, -150),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
        }
      } finally {
        semantics.dispose();
      }
    });
  }

  testWidgets(
    'skeleton has no animation before or after motion preference changes',
    (tester) async {
      Widget page(bool reduce) => MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(disableAnimations: reduce),
          child: const Scaffold(body: SkeletonPage(child: LearningSkeleton())),
        ),
      );
      await tester.pumpWidget(page(false));
      await tester.pumpAndSettle();
      expect(tester.binding.transientCallbackCount, 0);
      await tester.pumpWidget(page(true));
      expect(tester.binding.transientCallbackCount, 0);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 2));
      expect(tester.takeException(), isNull);
    },
  );
}
