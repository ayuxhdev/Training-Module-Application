import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:training_app/core/presentation/components/primary_button.dart';
import 'package:training_app/core/presentation/components/secondary_button.dart';
import 'package:training_app/core/presentation/components/custom_text_field.dart';
import 'package:training_app/core/presentation/components/loading_view.dart';
import 'package:training_app/core/presentation/components/error_view.dart';
import 'package:training_app/core/presentation/components/empty_view.dart';
import 'package:training_app/core/presentation/components/status_badge.dart';
import 'package:training_app/core/presentation/components/custom_card.dart';
import 'package:training_app/core/theme/app_theme.dart';

void main() {
  Widget buildTestApp(Widget child, {ThemeData? theme}) {
    final activeTheme = theme ?? AppTheme.lightTheme;
    return MaterialApp(
      theme: activeTheme,
      home: Theme(
        data: activeTheme,
        child: Scaffold(body: child),
      ),
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

    testWidgets('StatusBadge displays neutral status', (tester) async {
      await tester.pumpWidget(buildTestApp(
        const StatusBadge(text: 'Archived', status: BadgeStatus.neutral),
      ));

      expect(find.text('ARCHIVED'), findsOneWidget);
    });

    testWidgets('CustomCard handles tap and semantic label', (tester) async {
      bool tapped = false;
      await tester.pumpWidget(buildTestApp(
        CustomCard(
          onTap: () => tapped = true,
          semanticLabel: 'Card Action',
          child: const Text('Card Body'),
        ),
      ));
      expect(find.text('Card Body'), findsOneWidget);
      await tester.tap(find.text('Card Body'));
      expect(tapped, isTrue);
    });

    testWidgets('PrimaryButton displays icon when provided', (tester) async {
      await tester.pumpWidget(buildTestApp(
        const PrimaryButton(
          text: 'Save',
          icon: Icon(Icons.save),
        ),
      ));
      expect(find.text('Save'), findsOneWidget);
      expect(find.byIcon(Icons.save), findsOneWidget);
    });

    testWidgets('SecondaryButton displays icon when provided', (tester) async {
      await tester.pumpWidget(buildTestApp(
        const SecondaryButton(
          text: 'Cancel',
          icon: Icon(Icons.cancel),
        ),
      ));
      expect(find.text('Cancel'), findsOneWidget);
      expect(find.byIcon(Icons.cancel), findsOneWidget);
    });

    testWidgets('EmptyView displays title and action when provided', (tester) async {
      await tester.pumpWidget(buildTestApp(
        const EmptyView(
          title: 'No Items',
          message: 'Nothing here',
          action: Text('Add Item'),
        ),
      ));
      expect(find.text('No Items'), findsOneWidget);
      expect(find.text('Nothing here'), findsOneWidget);
      expect(find.text('Add Item'), findsOneWidget);
    });

    testWidgets('LoadingView displays title when provided', (tester) async {
      await tester.pumpWidget(buildTestApp(
        const LoadingView(title: 'Please Wait', message: 'Fetching...'),
      ));
      expect(find.text('Please Wait'), findsOneWidget);
      expect(find.text('Fetching...'), findsOneWidget);
    });
    testWidgets('PrimaryButton does not force text color and inherits effective foreground in default M3, light and dark themes', (tester) async {
      final defaultM3 = ThemeData(useMaterial3: true);
      for (final theme in [defaultM3, AppTheme.lightTheme, AppTheme.darkTheme]) {
        // Enabled
        await tester.pumpWidget(buildTestApp(
          theme: theme,
          PrimaryButton(text: 'Enabled', onPressed: () {}),
        ));
        await tester.pumpAndSettle();
        final enabledText = tester.widget<Text>(find.text('Enabled'));
        expect(enabledText.style?.color, isNull, reason: 'Text must not override effective button foreground');

        final inheritedColor = DefaultTextStyle.of(tester.element(find.text('Enabled'))).style.color;
        final expectedColor = theme == defaultM3
            ? theme.colorScheme.primary
            : theme.colorScheme.onPrimary;
        expect(inheritedColor, expectedColor);

        // Disabled
        await tester.pumpWidget(buildTestApp(
          theme: theme,
          const PrimaryButton(text: 'Disabled', onPressed: null),
        ));
        await tester.pumpAndSettle();
        final disabledText = tester.widget<Text>(find.text('Disabled'));
        expect(disabledText.style?.color, isNull, reason: 'Disabled text must not override button foreground');
        final disabledInheritedColor = DefaultTextStyle.of(tester.element(find.text('Disabled'))).style.color;
        final expectedDisabledColor = theme.elevatedButtonTheme.style?.foregroundColor?.resolve({WidgetState.disabled}) ??
            // ignore: deprecated_member_use
            theme.colorScheme.onSurface.withOpacity(0.38);
        expect(disabledInheritedColor, expectedDisabledColor);
        expect(disabledInheritedColor?.a, closeTo(0.38, 0.01),
            reason: 'Material 3 disabled button foreground opacity must be 0.38');

        // Loading spinner inherits disabled button foreground
        await tester.pumpWidget(buildTestApp(
          theme: theme,
          const PrimaryButton(text: 'Loading', isLoading: true),
        ));
        await tester.pump(const Duration(milliseconds: 250));
        final spinner = tester.widget<CircularProgressIndicator>(find.byType(CircularProgressIndicator));
        expect(spinner.color, expectedDisabledColor);

        // Optional leading icon inherits button IconTheme
        await tester.pumpWidget(buildTestApp(
          theme: theme,
          PrimaryButton(
            text: 'With Icon',
            icon: const Icon(Icons.star),
            onPressed: () {},
          ),
        ));
        await tester.pumpAndSettle();
        final iconTheme = IconTheme.of(tester.element(find.byIcon(Icons.star)));
        expect(iconTheme.color, expectedColor);
      }
    });

    testWidgets('PrimaryButton respects scoped ElevatedButtonTheme overrides for enabled, disabled, loading, and icon', (tester) async {
      const customEnabledColor = Color(0xFF6200EE);
      const customDisabledColor = Color(0xFFFF5722);

      Widget buildScopedApp({required Widget child}) {
        return MaterialApp(
          home: Scaffold(
            body: ElevatedButtonTheme(
              data: ElevatedButtonThemeData(
                style: ButtonStyle(
                  foregroundColor: WidgetStateProperty.resolveWith((states) {
                    if (states.contains(WidgetState.disabled)) {
                      return customDisabledColor;
                    }
                    return customEnabledColor;
                  }),
                ),
              ),
              child: child,
            ),
          ),
        );
      }

      // Enabled with scoped theme
      await tester.pumpWidget(buildScopedApp(
        child: PrimaryButton(text: 'Scoped Enabled', onPressed: () {}),
      ));
      await tester.pumpAndSettle();
      final enabledText = tester.widget<Text>(find.text('Scoped Enabled'));
      expect(enabledText.style?.color, isNull);
      final enabledInherited = DefaultTextStyle.of(tester.element(find.text('Scoped Enabled'))).style.color;
      expect(enabledInherited, customEnabledColor);

      // Disabled with scoped theme
      await tester.pumpWidget(buildScopedApp(
        child: const PrimaryButton(text: 'Scoped Disabled', onPressed: null),
      ));
      await tester.pumpAndSettle();
      final disabledText = tester.widget<Text>(find.text('Scoped Disabled'));
      expect(disabledText.style?.color, isNull);
      final disabledInherited = DefaultTextStyle.of(tester.element(find.text('Scoped Disabled'))).style.color;
      expect(disabledInherited, customDisabledColor);

      // Loading with scoped theme derives spinner color from effective button style
      await tester.pumpWidget(buildScopedApp(
        child: const PrimaryButton(text: 'Scoped Loading', isLoading: true),
      ));
      await tester.pump(const Duration(milliseconds: 250));
      final spinner = tester.widget<CircularProgressIndicator>(find.byType(CircularProgressIndicator));
      expect(spinner.color, customDisabledColor);

      // Leading icon with scoped theme inherits scoped foreground
      await tester.pumpWidget(buildScopedApp(
        child: PrimaryButton(
          text: 'Scoped Icon',
          icon: const Icon(Icons.star),
          onPressed: () {},
        ),
      ));
      await tester.pumpAndSettle();
      final iconTheme = IconTheme.of(tester.element(find.byIcon(Icons.star)));
      expect(iconTheme.color, customEnabledColor);
    });

    testWidgets('SecondaryButton preserves unforced label color for enabled and disabled states', (tester) async {
      for (final theme in [AppTheme.lightTheme, AppTheme.darkTheme]) {
        // Enabled
        await tester.pumpWidget(buildTestApp(
          theme: theme,
          SecondaryButton(text: 'Enabled', onPressed: () {}),
        ));
        final enabledText = tester.widget<Text>(find.text('Enabled'));
        expect(enabledText.style?.color, isNull);

        // Disabled
        await tester.pumpWidget(buildTestApp(
          theme: theme,
          const SecondaryButton(text: 'Disabled', onPressed: null),
        ));
        final disabledText = tester.widget<Text>(find.text('Disabled'));
        expect(disabledText.style?.color, isNull);
      }
    });
  });
}
