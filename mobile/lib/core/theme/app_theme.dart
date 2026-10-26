import 'package:flutter/material.dart';

import 'app_colors.dart';
import 'app_spacing.dart';
import 'app_typography.dart';
import 'reduced_motion_transitions.dart';

/// Architectural Botanica Material 3 Theme System.
/// Implements balanced enterprise density with accessible contrast and 4-tier geometry.
class AppTheme {
  AppTheme._();

  static ThemeData get lightTheme => _build(Brightness.light);

  static ThemeData get darkTheme => _build(Brightness.dark);

  static final _pageTransitions = PageTransitionsTheme(
    builders: {
      for (final entry in const PageTransitionsTheme().builders.entries)
        entry.key: ReducedMotionTransitions(delegate: entry.value),
    },
  );

  static ThemeData _build(Brightness brightness) {
    final isDark = brightness == Brightness.dark;
    final colorScheme =
        ColorScheme.fromSeed(
          seedColor: AppColors.primary,
          brightness: brightness,
        ).copyWith(
          primary: isDark ? AppColors.mint : AppColors.primary,
          onPrimary: isDark ? AppColors.midnight : Colors.white,
          primaryContainer: isDark
              ? const Color(0xff13382d)
              : AppColors.accentSurface,
          onPrimaryContainer: isDark ? AppColors.mint : AppColors.primaryDark,
          secondary: isDark ? const Color(0xff80d4e0) : AppColors.secondary,
          onSecondary: isDark ? AppColors.midnight : Colors.white,
          surface: isDark ? AppColors.midnight : AppColors.surface,
          surfaceContainerLow: isDark ? AppColors.charcoal : Colors.white,
          surfaceContainer: isDark
              ? AppColors.charcoalSubtle
              : AppColors.surfaceSubtle,
          surfaceContainerHighest: isDark
              ? const Color(0xff24303e)
              : const Color(0xffe2eae6),
          onSurface: isDark ? AppColors.textPrimaryDark : AppColors.textPrimary,
          onSurfaceVariant: isDark
              ? AppColors.textSecondaryDark
              : AppColors.textSecondary,
          outline: isDark ? AppColors.borderStrongDark : AppColors.borderStrong,
          outlineVariant: isDark
              ? AppColors.borderSubtleDark
              : AppColors.borderSubtle,
          error: isDark ? AppColors.dangerTextDark : AppColors.dangerTextLight,
          onError: isDark ? AppColors.midnight : Colors.white,
          errorContainer: isDark
              ? AppColors.dangerBgDark
              : AppColors.dangerBgLight,
          onErrorContainer: isDark
              ? AppColors.dangerTextDark
              : AppColors.dangerTextLight,
        );

    final inputBorderColor = isDark
        ? colorScheme.outline
        : colorScheme.outlineVariant;

    final primaryButtonStyle = ElevatedButton.styleFrom(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.lg,
        vertical: AppSpacing.md,
      ),
      backgroundColor: colorScheme.primary,
      foregroundColor: colorScheme.onPrimary,
      minimumSize: const Size(48, 48),
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    );

    return ThemeData(
      colorScheme: colorScheme,
      useMaterial3: true,
      pageTransitionsTheme: _pageTransitions,
      scaffoldBackgroundColor: isDark
          ? AppColors.midnight
          : AppColors.background,

      appBarTheme: AppBarTheme(
        backgroundColor: isDark ? AppColors.midnight : AppColors.background,
        foregroundColor: colorScheme.onSurface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          color: colorScheme.onSurface,
          fontSize: 20,
          fontWeight: FontWeight.w700,
          letterSpacing: -0.5,
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: colorScheme.surfaceContainerLow,
        indicatorColor: colorScheme.primary.withValues(
          alpha: isDark ? .18 : .12,
        ),
        elevation: 0,
        labelTextStyle: WidgetStateProperty.resolveWith(
          (states) => TextStyle(
            fontSize: 12,
            fontWeight: states.contains(WidgetState.selected)
                ? FontWeight.w700
                : FontWeight.w500,
            color: states.contains(WidgetState.selected)
                ? colorScheme.primary
                : colorScheme.onSurfaceVariant,
          ),
        ),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: colorScheme.primary,
        linearTrackColor: colorScheme.surfaceContainerHighest,
        linearMinHeight: 6,
        borderRadius: BorderRadius.circular(12),
      ),

      textTheme: const TextTheme(
        displayLarge: AppTypography.displayLarge,
        titleLarge: AppTypography.titleLarge,
        titleMedium: AppTypography.titleMedium,
        titleSmall: AppTypography.titleSmall,
        bodyLarge: AppTypography.bodyLarge,
        bodyMedium: AppTypography.bodyMedium,
        bodySmall: AppTypography.bodySmall,
        labelLarge: AppTypography.labelLarge,
        labelMedium: AppTypography.labelMedium,
        labelSmall: AppTypography.labelSmall,
      ),

      elevatedButtonTheme: ElevatedButtonThemeData(style: primaryButtonStyle),
      filledButtonTheme: FilledButtonThemeData(style: primaryButtonStyle),

      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.lg,
            vertical: AppSpacing.md,
          ),
          minimumSize: const Size(48, 48),
          side: BorderSide(color: colorScheme.outlineVariant),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),

      dialogTheme: DialogThemeData(
        backgroundColor: colorScheme.surfaceContainerLow,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: colorScheme.surfaceContainerLow,
        surfaceTintColor: Colors.transparent,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: colorScheme.inverseSurface,
        contentTextStyle: TextStyle(color: colorScheme.onInverseSurface),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: isDark
            ? colorScheme.surfaceContainerHighest
            : AppColors.surfaceSubtle,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: AppSpacing.md,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: inputBorderColor),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: inputBorderColor),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: colorScheme.primary, width: 2),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: colorScheme.error, width: 2),
        ),
      ),

      cardTheme: CardThemeData(
        color: colorScheme.surfaceContainerLow,
        surfaceTintColor: Colors.transparent,
        elevation: isDark ? 0 : 1,
        shadowColor: Colors.black.withValues(alpha: .06),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: colorScheme.outlineVariant),
        ),
        margin: EdgeInsets.zero,
      ),
    );
  }
}
