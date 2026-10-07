import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:training_app/core/presentation/components/primary_button.dart';
import 'package:training_app/core/presentation/components/secondary_button.dart';
import 'package:training_app/core/presentation/components/custom_text_field.dart';
import 'package:training_app/core/presentation/components/loading_view.dart';
import 'package:training_app/core/presentation/components/error_view.dart';
import 'package:training_app/core/presentation/components/empty_view.dart';
import 'package:training_app/core/presentation/components/status_badge.dart';
import 'package:training_app/core/theme/app_theme.dart';

void main() {
  Widget buildTestApp(Widget child) {
    return MaterialApp(
      theme: AppTheme.lightTheme,
      home: Scaffold(body: child),
    );
  }

  group('UI Components', () {
    testWidgets('PrimaryButton displays text and handles tap', (tester) async {
      bool tapped = false;
      await tester.pumpWidget(buildTestApp(
        PrimaryButton(
          text: 'Click Me',
          onPressed: () => tapped = true,
        ),
      ));

      expect(find.text('Click Me'), findsOneWidget);
      await tester.tap(find.byType(PrimaryButton));
      expect(tapped, isTrue);
    });

    testWidgets('PrimaryButton shows loading state', (tester) async {
      await tester.pumpWidget(buildTestApp(
        const PrimaryButton(
          text: 'Click Me',
          isLoading: true,
        ),
      ));

      expect(find.text('Click Me'), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });

    testWidgets('SecondaryButton displays text and handles tap', (tester) async {
      bool tapped = false;
      await tester.pumpWidget(buildTestApp(
        SecondaryButton(
          text: 'Click Me',
          onPressed: () => tapped = true,
        ),
      ));

      expect(find.text('Click Me'), findsOneWidget);
      await tester.tap(find.byType(SecondaryButton));
      expect(tapped, isTrue);
    });

    testWidgets('SecondaryButton shows loading state', (tester) async {
      await tester.pumpWidget(buildTestApp(
        const SecondaryButton(
          text: 'Click Me',
          isLoading: true,
        ),
      ));

      expect(find.text('Click Me'), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });

    testWidgets('CustomTextField displays label and accepts input', (tester) async {
      final controller = TextEditingController();
      await tester.pumpWidget(buildTestApp(
        CustomTextField(
          label: 'Username',
          controller: controller,
        ),
      ));

      expect(find.text('Username'), findsOneWidget);
      
      await tester.enterText(find.byType(CustomTextField), 'testuser');
      expect(controller.text, 'testuser');
    });

    testWidgets('LoadingView displays message', (tester) async {
      await tester.pumpWidget(buildTestApp(
        const LoadingView(message: 'Please wait...'),
      ));

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.text('Please wait...'), findsOneWidget);
    });

    testWidgets('ErrorView displays message and retry button', (tester) async {
      bool retryTapped = false;
      await tester.pumpWidget(buildTestApp(
        ErrorView(
          message: 'Something went wrong',
          onRetry: () => retryTapped = true,
        ),
      ));

      expect(find.text('Something went wrong'), findsOneWidget);
      
      final retryButton = find.text('Retry');
      expect(retryButton, findsOneWidget);
      
      await tester.tap(retryButton);
      expect(retryTapped, isTrue);
    });

    testWidgets('EmptyView displays message and icon', (tester) async {
      await tester.pumpWidget(buildTestApp(
        const EmptyView(message: 'No data found', icon: Icons.folder_open),
      ));

      expect(find.text('No data found'), findsOneWidget);
      expect(find.byIcon(Icons.folder_open), findsOneWidget);
    });

    testWidgets('StatusBadge displays text', (tester) async {
      await tester.pumpWidget(buildTestApp(
        const StatusBadge(text: 'Active', status: BadgeStatus.success),
      ));

      expect(find.text('ACTIVE'), findsOneWidget);
    });
  });
}

