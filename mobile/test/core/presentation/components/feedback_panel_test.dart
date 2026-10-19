import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:training_app/core/presentation/components/error_view.dart';
import 'package:training_app/core/presentation/components/empty_view.dart';
import 'package:training_app/core/presentation/components/loading_view.dart';
import 'package:training_app/core/theme/app_theme.dart';

void main() {
  for (final dark in [false, true]) {
    testWidgets(
      '${dark ? 'dark' : 'light'} feedback fits short screens and honors reduced motion',
      (tester) async {
        tester.view.physicalSize = const Size(320, 240);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        var retries = 0;
        for (final child in [
          ErrorView(
            title: 'Connection unavailable',
            message: 'Check your connection, then try again.',
            onRetry: () => retries++,
          ),
          const EmptyView(message: 'Your learning updates will appear here.'),
          const LoadingView(message: 'Loading your latest updates…'),
        ]) {
          await tester.pumpWidget(
            MaterialApp(
              theme: dark ? AppTheme.darkTheme : AppTheme.lightTheme,
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context).copyWith(
                  disableAnimations: true,
                  textScaler: TextScaler.linear(2),
                ),
                child: child!,
              ),
              home: Scaffold(body: child),
            ),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          if (child is ErrorView) {
            await tester.ensureVisible(find.text('Retry'));
            await tester.pumpAndSettle();
            await tester.tap(find.text('Retry'));
            expect(retries, 1);
          }
          if (child is LoadingView) {
            expect(find.byType(CircularProgressIndicator), findsNothing);
            expect(find.text('Loading your latest updates…'), findsOneWidget);
            expect(tester.binding.transientCallbackCount, 0);
          }
        }
      },
    );
  }
}
