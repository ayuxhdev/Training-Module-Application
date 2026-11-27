import 'package:flutter/material.dart';

import 'cadence_tokens.dart';

/// Local to an opted-in screen; does not replace the app's appearance state.
abstract final class CadenceTheme {
  static ThemeData from(ThemeData base) {
    // Cadence is one hybrid appearance, not a system-brightness variant.
    // Start from light Material defaults so inherited controls cannot retain
    // dark canvas, icon, selection, tooltip or disabled colors.
    const surface = Colors.white;
    const text = CadenceTokens.ink;
    const muted = CadenceTokens.muted;
    const outline = CadenceTokens.control;
    const line = CadenceTokens.line;
    final scheme =
        ColorScheme.fromSeed(
          seedColor: CadenceTokens.primary,
          brightness: Brightness.light,
        ).copyWith(
          primary: CadenceTokens.primary,
          onPrimary: Colors.white,
          primaryContainer: CadenceTokens.disabled,
          onPrimaryContainer: CadenceTokens.deeper,
          secondary: CadenceTokens.teal,
          onSecondary: Colors.white,
          secondaryContainer: CadenceTokens.tealTint,
          onSecondaryContainer: CadenceTokens.teal,
          tertiary: CadenceTokens.violet,
          onTertiary: Colors.white,
          tertiaryContainer: CadenceTokens.violetTint,
          onTertiaryContainer: CadenceTokens.violet,
          surface: surface,
          onSurface: text,
          onSurfaceVariant: muted,
          surfaceDim: line,
          surfaceBright: surface,
          surfaceContainerLowest: surface,
          surfaceContainerLow: surface,
          surfaceContainer: CadenceTokens.canvas,
          surfaceContainerHigh: CadenceTokens.canvas,
          surfaceContainerHighest: line,
          outline: outline,
          outlineVariant: line,
          error: CadenceTokens.rose,
          onError: Colors.white,
          errorContainer: CadenceTokens.roseTint,
          onErrorContainer: CadenceTokens.rose,
        );
    final hybrid = ThemeData(
      colorScheme: scheme,
      useMaterial3: base.useMaterial3,
      platform: base.platform,
      visualDensity: base.visualDensity,
      materialTapTargetSize: MaterialTapTargetSize.padded,
      pageTransitionsTheme: base.pageTransitionsTheme,
    );
    final typography = base.textTheme.apply(
      bodyColor: text,
      displayColor: text,
    );
    final buttons = primaryButtonStyle(dark: false);
    return hybrid.copyWith(
      colorScheme: scheme,
      scaffoldBackgroundColor: CadenceTokens.canvas,
      textTheme: typography.copyWith(
        headlineLarge: typography.headlineLarge?.copyWith(
          fontSize: 32,
          fontWeight: FontWeight.w700,
          height: 1.15,
          letterSpacing: -0.8,
        ),
        titleLarge: typography.titleLarge?.copyWith(
          fontSize: 22,
          fontWeight: FontWeight.w700,
          height: 1.3,
        ),
        titleMedium: typography.titleMedium?.copyWith(
          fontSize: 18,
          fontWeight: FontWeight.w700,
          height: 1.3,
        ),
        bodyLarge: typography.bodyLarge?.copyWith(fontSize: 16, height: 1.5),
        bodyMedium: typography.bodyMedium?.copyWith(fontSize: 14, height: 1.5),
        bodySmall: typography.bodySmall?.copyWith(fontSize: 12, height: 1.5),
        labelSmall: typography.labelSmall?.copyWith(
          fontSize: 12,
          fontWeight: FontWeight.w700,
          height: 1.5,
          letterSpacing: 1.1,
        ),
      ),
      cardTheme: CardThemeData(
        color: surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(CadenceTokens.radius),
          side: BorderSide(color: line),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(style: buttons),
      filledButtonTheme: FilledButtonThemeData(style: buttons),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: text,
          side: BorderSide(color: outline),
          minimumSize: const Size(48, 48),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(minimumSize: const Size(48, 48)),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: CadenceTokens.teal,
        linearTrackColor: line,
        linearMinHeight: 8,
        borderRadius: BorderRadius.circular(4),
      ),
    );
  }

  static ButtonStyle primaryButtonStyle({
    required bool dark,
    bool isLoading = false,
  }) => ButtonStyle(
    minimumSize: const WidgetStatePropertyAll(Size(48, 48)),
    padding: const WidgetStatePropertyAll(
      EdgeInsets.symmetric(horizontal: 18, vertical: 12),
    ),
    shape: WidgetStatePropertyAll(
      RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
    elevation: const WidgetStatePropertyAll(0),
    textStyle: const WidgetStatePropertyAll(
      TextStyle(
        fontFamily: 'Roboto',
        fontSize: 15,
        height: 1.4,
        fontWeight: FontWeight.w700,
      ),
    ),
    backgroundColor: WidgetStateProperty.resolveWith((states) {
      if (isLoading) {
        return CadenceTokens.primary;
      }
      if (states.contains(WidgetState.disabled) && !isLoading) {
        return CadenceTokens.disabled;
      }
      if (states.contains(WidgetState.pressed)) {
        return CadenceTokens.primaryPressed;
      }
      if (states.contains(WidgetState.hovered)) {
        return CadenceTokens.primaryHover;
      }
      return CadenceTokens.primary;
    }),
    foregroundColor: WidgetStateProperty.resolveWith(
      (states) => states.contains(WidgetState.disabled) && !isLoading
          ? CadenceTokens.onDisabled
          : Colors.white,
    ),
    overlayColor: const WidgetStatePropertyAll(Colors.transparent),
    side: WidgetStateProperty.resolveWith((states) {
      // A contrasting inset focus boundary does not change layout geometry.
      if (states.contains(WidgetState.focused)) {
        return const BorderSide(color: CadenceTokens.inverseFocus, width: 3);
      }
      return BorderSide(
        color: dark ? CadenceTokens.darkOutline : Colors.transparent,
      );
    }),
  );

  static ButtonStyle get inverseButtonStyle =>
      primaryButtonStyle(dark: true).copyWith(
        backgroundColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.disabled)) {
            return CadenceTokens.disabled;
          }
          if (states.contains(WidgetState.pressed)) {
            return CadenceTokens.inversePressed;
          }
          if (states.contains(WidgetState.hovered)) {
            return CadenceTokens.inverseHover;
          }
          return Colors.white;
        }),
        foregroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.disabled)
              ? CadenceTokens.onDisabled
              : CadenceTokens.deeper,
        ),
        side: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.focused)
              ? const BorderSide(color: CadenceTokens.blue, width: 3)
              : const BorderSide(color: Colors.transparent),
        ),
      );
}
