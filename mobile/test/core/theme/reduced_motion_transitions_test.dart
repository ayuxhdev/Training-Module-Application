import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:training_app/core/theme/app_theme.dart';

void main() {
  for (final reduced in [false, true]) {
    for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
      testWidgets(
        '$platform route push and back preserve navigation (reduced: $reduced)',
        (tester) async {
          tester.platformDispatcher.accessibilityFeaturesTestValue =
              FakeAccessibilityFeatures(disableAnimations: reduced);
          addTearDown(
            tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
          );
          final navigator = GlobalKey<NavigatorState>();
          await tester.pumpWidget(
            MaterialApp(
              theme: AppTheme.lightTheme.copyWith(platform: platform),
              navigatorKey: navigator,
              home: const Scaffold(body: Text('Origin')),
            ),
          );
          await tester.pumpAndSettle();
          final route = MaterialPageRoute<void>(
            builder: (_) =>
                const Scaffold(body: Center(child: Text('Destination'))),
          );
          navigator.currentState!.push(route);
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 1));
          final position = tester.getCenter(find.text('Destination'));
          await tester.pump(const Duration(milliseconds: 1));
          if (reduced) {
            expect(tester.getCenter(find.text('Destination')), position);
            expectVisibleWithoutMotion(tester, 'Destination');
          }
          await tester.pumpAndSettle();
          expect(find.text('Destination'), findsOneWidget);
          navigator.currentState!.pop();
          await tester.pumpAndSettle();
          expect(find.text('Origin'), findsOneWidget);
        },
      );
    }

    testWidgets('iOS edge swipe cancels and pops (reduced: $reduced)', (
      tester,
    ) async {
      final navigator = await pushDestination(
        tester,
        TargetPlatform.iOS,
        reduced,
      );
      final destination = tester.getRect(find.text('Destination'));
      final width =
          tester.view.physicalSize.width / tester.view.devicePixelRatio;
      final edge = Offset(1, destination.center.dy);

      final cancelled = await tester.startGesture(edge);
      await cancelled.moveBy(Offset(width * .2, 0));
      await tester.pump();
      expect(navigator.currentState!.userGestureInProgress, isTrue);
      if (reduced) {
        expect(tester.getRect(find.text('Destination')), destination);
        expectVisibleWithoutMotion(tester, 'Destination');
      } else {
        expect(
          tester.getRect(find.text('Destination')).left,
          greaterThan(destination.left),
        );
      }
      await cancelled.up();
      await tester.pumpAndSettle();
      expect(find.text('Destination'), findsOneWidget);
      expect(navigator.currentState!.userGestureInProgress, isFalse);
      expect(tester.getRect(find.text('Destination')), destination);

      final completed = await tester.startGesture(edge);
      await completed.moveBy(Offset(width * .75, 0));
      await tester.pump();
      if (reduced) {
        expect(tester.getRect(find.text('Destination')), destination);
      }
      await completed.up();
      await tester.pumpAndSettle();
      expect(find.text('Destination'), findsNothing);
      expect(find.text('Origin'), findsOneWidget);
      expect(navigator.currentState!.canPop(), isFalse);
      expect(navigator.currentState!.userGestureInProgress, isFalse);
      expectVisibleWithoutMotion(tester, 'Origin');
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'Android predictive back cancels and commits (reduced: $reduced)',
      (tester) async {
        final navigator = await pushDestination(
          tester,
          TargetPlatform.android,
          reduced,
        );
        final destination = tester.getRect(find.text('Destination'));
        Future<void> backEvent(
          String method, [
          double? progress,
          double y = 300,
        ]) async {
          await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
            'flutter/backgesture',
            const StandardMethodCodec().encodeMethodCall(
              MethodCall(
                method,
                progress == null
                    ? null
                    : {
                        'touchOffset': <double>[5, y],
                        'progress': progress,
                        'swipeEdge': 0,
                      },
              ),
            ),
            (_) {},
          );
          await tester.pump();
        }

        await backEvent('startBackGesture', 0);
        await backEvent('updateBackGestureProgress', .35);
        expect(navigator.currentState!.userGestureInProgress, isTrue);
        if (reduced) {
          expect(tester.getRect(find.text('Destination')), destination);
          expectVisibleWithoutMotion(tester, 'Destination');
          // The SDK follows vertical finger input independently of its animation.
          // Preserve that user-driven feedback; no autonomous travel or scaling.
          await backEvent('updateBackGestureProgress', .35, 314);
          final followingFinger = tester.getRect(find.text('Destination'));
          expect(followingFinger.left, destination.left);
          expect(followingFinger.size, destination.size);
          expect(followingFinger.top, greaterThanOrEqualTo(destination.top));
          await tester.pump(const Duration(milliseconds: 100));
          expect(tester.getRect(find.text('Destination')), followingFinger);
          expectVisibleWithoutMotion(tester, 'Destination');
        }
        await backEvent('cancelBackGesture');
        await tester.pumpAndSettle();
        expect(find.text('Destination'), findsOneWidget);
        expect(navigator.currentState!.userGestureInProgress, isFalse);
        expect(tester.getRect(find.text('Destination')), destination);

        await backEvent('startBackGesture', 0);
        await backEvent('updateBackGestureProgress', .7);
        await backEvent('commitBackGesture');
        await tester.pumpAndSettle();
        expect(find.text('Destination'), findsNothing);
        expect(find.text('Origin'), findsOneWidget);
        expect(navigator.currentState!.canPop(), isFalse);
        expect(navigator.currentState!.userGestureInProgress, isFalse);
        expectVisibleWithoutMotion(tester, 'Origin');
        expect(tester.getCenter(find.text('Origin')), destination.center);
        expect(tester.takeException(), isNull);
      },
    );
  }
}

Future<GlobalKey<NavigatorState>> pushDestination(
  WidgetTester tester,
  TargetPlatform platform,
  bool reduced,
) async {
  tester.platformDispatcher.accessibilityFeaturesTestValue =
      FakeAccessibilityFeatures(disableAnimations: reduced);
  addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
  final navigator = GlobalKey<NavigatorState>();
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.lightTheme.copyWith(platform: platform),
      navigatorKey: navigator,
      home: const Scaffold(body: Center(child: Text('Origin'))),
    ),
  );
  await tester.pumpAndSettle();
  navigator.currentState!.push(
    MaterialPageRoute<void>(
      builder: (_) => const Scaffold(body: Center(child: Text('Destination'))),
    ),
  );
  await tester.pumpAndSettle();
  return navigator;
}

void expectVisibleWithoutMotion(WidgetTester tester, String text) {
  final fades = tester.widgetList<FadeTransition>(
    find.ancestor(of: find.text(text), matching: find.byType(FadeTransition)),
  );
  for (final fade in fades) {
    expect(fade.opacity.value, 1);
  }
  for (final opacity in tester.widgetList<Opacity>(
    find.ancestor(of: find.text(text), matching: find.byType(Opacity)),
  )) {
    expect(opacity.opacity, 1);
  }
  final slides = tester.widgetList<SlideTransition>(
    find.ancestor(of: find.text(text), matching: find.byType(SlideTransition)),
  );
  for (final slide in slides) {
    expect(slide.position.value, Offset.zero);
  }
}
