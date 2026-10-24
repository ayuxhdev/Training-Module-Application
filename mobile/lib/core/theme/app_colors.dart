import 'package:flutter/material.dart';

/// Architectural Botanica Design System Color Tokens.
/// Verified for WCAG 2.1 AA/AAA contrast ratios across Light and Dark surfaces.
class AppColors {
  AppColors._();

  // Core Brand Tokens (Light & Dark)
  static const Color primary = Color(0xff006252); // Forest Pine (7.32:1 on White, AAA Pass)
  static const Color primaryDark = Color(0xff004d40); // Deep Forest Pine
  static const Color secondary = Color(0xff186771); // Slate Teal
  static const Color background = Color(0xfff6f8f7); // Pristine Daylight Canvas
  static const Color surface = Color(0xffffffff); // Pure Surface
  static const Color surfaceSubtle = Color(0xffedf3f0); // Layer 2 Daylight Surface
  static const Color accentSurface = Color(0xffdcf2ea); // Mint Container Surface

  // Dark Canvas & Surfaces
  static const Color midnight = Color(0xff080e15); // Obsidian Dark Canvas
  static const Color charcoal = Color(0xff101923); // Charcoal Dark Surface
  static const Color charcoalSubtle = Color(0xff172330); // Layer 2 Dark Subtle
  static const Color mint = Color(0xff34d399); // Botanical Mint (10.08:1 on Midnight, AAA Pass)
  static const Color mintDark = Color(0xff10b981); // Emerald Accent

  // Typography Tokens
  static const Color textPrimary = Color(0xff122421); // 16.15:1 on Surface (AAA Pass)
  static const Color textSecondary = Color(0xff4b6661); // 6.23:1 on Surface (AA Pass)
  static const Color textPrimaryDark = Color(0xfff0f6f8); // 16.23:1 on Charcoal (AAA Pass)
  static const Color textSecondaryDark = Color(0xff9eb2c0); // 8.08:1 on Charcoal (AAA Pass)

  // Border Tokens
  static const Color borderSubtle = Color(0xffd2ddd8);
  static const Color borderStrong = Color(0xff829c93);
  static const Color borderSubtleDark = Color(0xff253646);
  static const Color borderStrongDark = Color(0xff607c8b); // Verified 3.03:1 on dark input fill #24303e (WCAG 2.2 SC 1.4.11)

  // Status & Semantic Tokens (Preserving legacy property names for compatibility)
  static const Color error = Color(0xffef4444); // Yields >= 4.5:1 when tinted in status badges
  static const Color statusSuccess = Color(0xff065f46); // 6.78:1 on Light Success BG (AA Pass)
  static const Color statusWarning = Color(0xfff59e0b); // Yields >= 4.5:1 when tinted in status badges
  static const Color statusInfo = Color(0xff1e40af); // 7.15:1 on Light Info BG (AAA Pass)

  // Full Semantic Pairs: Light Mode
  static const Color successTextLight = Color(0xff065f46);
  static const Color successBgLight = Color(0xffd1fae5);
  static const Color successBorderLight = Color(0xffa7f3d0);

  static const Color warningTextLight = Color(0xff92400e);
  static const Color warningBgLight = Color(0xfffef3c7);
  static const Color warningBorderLight = Color(0xfffde68a);

  static const Color dangerTextLight = Color(0xff991b1b);
  static const Color dangerBgLight = Color(0xfffee2e2);
  static const Color dangerBorderLight = Color(0xfffecaca);

  static const Color infoTextLight = Color(0xff1e40af);
  static const Color infoBgLight = Color(0xffdbeafe);
  static const Color infoBorderLight = Color(0xffbfdbfe);

  static const Color neutralTextLight = Color(0xff374151);
  static const Color neutralBgLight = Color(0xfff3f4f6);
  static const Color neutralBorderLight = Color(0xffe5e7eb);

  // Full Semantic Pairs: Dark Mode (Verified AAA)
  static const Color successTextDark = Color(0xffa7f3d0); // 7.58:1 on Dark Success BG (AAA Pass)
  static const Color successBgDark = Color(0xff064e3b);
  static const Color successBorderDark = Color(0xff065f46);

  static const Color warningTextDark = Color(0xfffbbf24); // 8.97:1 on Dark Warning BG (AAA Pass)
  static const Color warningBgDark = Color(0xff451a03);
  static const Color warningBorderDark = Color(0xff78350f);

  static const Color dangerTextDark = Color(0xfffca5a5); // 8.51:1 on Dark Danger BG (AAA Pass)
  static const Color dangerBgDark = Color(0xff450a0a);
  static const Color dangerBorderDark = Color(0xff7f1d1d);

  static const Color infoTextDark = Color(0xff93c5fd); // 8.15:1 on Dark Info BG (AAA Pass)
  static const Color infoBgDark = Color(0xff172554);
  static const Color infoBorderDark = Color(0xff1e3a8a);

  static const Color neutralTextDark = Color(0xffe5e7eb); // 11.86:1 on Dark Neutral BG (AAA Pass)
  static const Color neutralBgDark = Color(0xff1f2937);
  static const Color neutralBorderDark = Color(0xff374151);

  // Video Accent Preserved
  static const Color videoAccent = Color(0xff10b981);
  static const Color videoAccentAlt = Color(0xff2dd4bf);
}
