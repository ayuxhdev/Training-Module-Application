import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:training_app/core/theme/app_theme.dart';
import 'package:training_app/core/theme/cadence_theme.dart';
import 'package:training_app/core/theme/cadence_tokens.dart';

double contrast(Color a, Color b) {
  final x = a.computeLuminance(), y = b.computeLuminance();
  return (x > y ? x + .05 : y + .05) / (x < y ? x + .05 : y + .05);
}

void main() {
  test('Harmony is opt-in and leaves the global appearance unchanged', () {
    final base = AppTheme.lightTheme;
    final original = base.colorScheme;
    final local = CadenceTheme.from(base);
    expect(base.colorScheme, original);
    expect(AppTheme.lightTheme.colorScheme.primary, original.primary);
    expect(local.scaffoldBackgroundColor, CadenceTokens.canvas);
    expect(local.colorScheme.primary, const Color(0xFF435C38));
    expect(local.colorScheme.secondary, CadenceTokens.teal);
    expect(local.pageTransitionsTheme, same(base.pageTransitionsTheme));
  });
  test('system brightness cannot recolor the opted-in hybrid appearance', () {
    final light = CadenceTheme.from(AppTheme.lightTheme);
    final dark = CadenceTheme.from(AppTheme.darkTheme);
    expect(dark.brightness, Brightness.light);
    expect(dark.scaffoldBackgroundColor, CadenceTokens.canvas);
    expect(dark.colorScheme, light.colorScheme);
    expect(dark.canvasColor, light.canvasColor);
    expect(dark.iconTheme, light.iconTheme);
    expect(dark.cardTheme, light.cardTheme);
    expect(dark.progressIndicatorTheme, light.progressIndicatorTheme);
    expect(dark.disabledColor, light.disabledColor);
    expect(dark.textSelectionTheme, light.textSelectionTheme);
    expect(AppTheme.darkTheme.brightness, Brightness.dark);
    expect(
      AppTheme.darkTheme.scaffoldBackgroundColor,
      isNot(CadenceTokens.canvas),
    );
  });
  for (final dark in [false, true]) {
    test('${dark ? 'dark' : 'light'} Harmony text and component contrast', () {
      final theme = CadenceTheme.from(
        dark ? AppTheme.darkTheme : AppTheme.lightTheme,
      );
      final c = theme.colorScheme;
      for (final pair in [
        (c.onSurface, c.surface),
        (c.onSurfaceVariant, c.surface),
        (c.onSurface, theme.scaffoldBackgroundColor),
        (Colors.white, CadenceTokens.primary),
        (Colors.white, CadenceTokens.primaryHover),
        (Colors.white, CadenceTokens.primaryPressed),
        (CadenceTokens.onDisabled, CadenceTokens.disabled),
        (Colors.white, CadenceTokens.deep),
        (CadenceTokens.onDark, CadenceTokens.deep),
        (CadenceTokens.blue, CadenceTokens.blueTint),
        (CadenceTokens.violet, CadenceTokens.violetTint),
        (CadenceTokens.teal, CadenceTokens.tealTint),
      ]) {
        expect(contrast(pair.$1, pair.$2), greaterThanOrEqualTo(4.5));
      }
      expect(contrast(c.outline, c.surface), greaterThanOrEqualTo(3));
      expect(
        contrast(CadenceTokens.inverseFocus, CadenceTokens.primary),
        greaterThanOrEqualTo(3),
      );
    });
    test(
      '${dark ? 'dark' : 'light'} primary states and disabled/busy precedence',
      () {
        final style = CadenceTheme.primaryButtonStyle(dark: dark);
        expect(style.backgroundColor!.resolve({}), CadenceTokens.primary);
        expect(
          style.backgroundColor!.resolve({WidgetState.hovered}),
          CadenceTokens.primaryHover,
        );
        expect(
          style.backgroundColor!.resolve({
            WidgetState.pressed,
            WidgetState.hovered,
          }),
          CadenceTokens.primaryPressed,
        );
        expect(
          style.backgroundColor!.resolve({
            WidgetState.disabled,
            WidgetState.hovered,
          }),
          CadenceTokens.disabled,
        );
        expect(
          style.foregroundColor!.resolve({WidgetState.disabled}),
          CadenceTokens.onDisabled,
        );
        expect(style.minimumSize!.resolve({}), const Size(48, 48));
        final focus = style.side!.resolve({WidgetState.focused})!;
        expect(focus.width, 3);
        expect(focus.color, CadenceTokens.inverseFocus);
        final busy = CadenceTheme.primaryButtonStyle(
          dark: dark,
          isLoading: true,
        );
        expect(
          busy.backgroundColor!.resolve({
            WidgetState.disabled,
            WidgetState.hovered,
          }),
          CadenceTokens.primary,
        );
        expect(
          busy.foregroundColor!.resolve({WidgetState.disabled}),
          Colors.white,
        );
      },
    );
  }
  test('inverse actions stay light and retain readable interaction states', () {
    final style = CadenceTheme.inverseButtonStyle;
    for (final state in [
      <WidgetState>{},
      {WidgetState.hovered},
      {WidgetState.pressed},
      {WidgetState.disabled},
    ]) {
      expect(
        contrast(
          style.foregroundColor!.resolve(state)!,
          style.backgroundColor!.resolve(state)!,
        ),
        greaterThanOrEqualTo(4.5),
      );
    }
    expect(style.backgroundColor!.resolve({}), Colors.white);
    expect(
      style.backgroundColor!.resolve({WidgetState.hovered}),
      CadenceTokens.inverseHover,
    );
  });
}
