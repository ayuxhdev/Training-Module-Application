import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:training_app/core/presentation/components/status_badge.dart';
import 'package:training_app/core/theme/app_theme.dart';

double _contrast(Color foreground, Color background) {
  final luminances = [
    foreground.computeLuminance(),
    background.computeLuminance(),
  ]..sort();
  return (luminances.last + 0.05) / (luminances.first + 0.05);
}

void main() {
  for (final brightness in Brightness.values) {
    final theme = brightness == Brightness.dark
        ? AppTheme.darkTheme
        : AppTheme.lightTheme;

    test(
      '${brightness.name} theme has readable text, selections, errors and inputs',
      () {
        final colors = theme.colorScheme;
        final pairs = <String, (Color, Color)>{
          'body': (
            theme.textTheme.bodyMedium!.color!,
            theme.scaffoldBackgroundColor,
          ),
          'surface': (colors.onSurface, colors.surface),
          'muted text': (
            colors.onSurfaceVariant,
            colors.surfaceContainerHighest,
          ),
          'primary text': (colors.primary, colors.surface),
          'primary button': (colors.onPrimary, colors.primary),
          'selected answer': (
            colors.onPrimaryContainer,
            colors.primaryContainer,
          ),
          'error text': (colors.error, colors.surface),
          'input': (colors.onSurface, theme.inputDecorationTheme.fillColor!),
        };
        for (final entry in pairs.entries) {
          expect(
            _contrast(entry.value.$1, entry.value.$2),
            greaterThanOrEqualTo(4.5),
            reason: entry.key,
          );
        }
      },
    );

    testWidgets(
      '${brightness.name} status badges remain distinguishable and readable',
      (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            theme: theme,
            home: Scaffold(
              body: Column(
                children: [
                  for (final status in BadgeStatus.values)
                    StatusBadge(text: status.name, status: status),
                ],
              ),
            ),
          ),
        );
        for (final status in BadgeStatus.values) {
          final badge = find.widgetWithText(
            StatusBadge,
            status.name.toUpperCase(),
          );
          final label = tester.widget<Text>(
            find.descendant(of: badge, matching: find.byType(Text)),
          );
          final container = tester.widget<Container>(
            find.descendant(of: badge, matching: find.byType(Container)),
          );
          final tint = (container.decoration! as BoxDecoration).color!;
          final background = Color.alphaBlend(
            tint,
            theme.scaffoldBackgroundColor,
          );
          expect(
            _contrast(label.style!.color!, background),
            greaterThanOrEqualTo(4.5),
            reason: status.name,
          );
        }
      },
    );
  }

  test(
    'light theme preserves established surfaces, primary color and typography',
    () {
      final theme = AppTheme.lightTheme;
      expect(theme.scaffoldBackgroundColor, Colors.white);
      expect(theme.colorScheme.surface, Colors.white);
      expect(theme.colorScheme.primary, Colors.green.shade800);
      expect(theme.inputDecorationTheme.fillColor, Colors.grey.shade50);
      expect(theme.textTheme.titleLarge!.fontSize, 22);
    },
  );
}
