import 'package:flutter/material.dart';
import 'package:training_app/core/theme/app_colors.dart';

enum BadgeStatus { success, warning, info, error, neutral }

class StatusBadge extends StatelessWidget {
  final String text;
  final BadgeStatus status;

  const StatusBadge({
    super.key,
    required this.text,
    this.status = BadgeStatus.info,
  });

  Color _getBackgroundColor() {
    switch (status) {
      case BadgeStatus.success:
        return AppColors.statusSuccess.withAlpha(26);
      case BadgeStatus.warning:
        return AppColors.statusWarning.withAlpha(26);
      case BadgeStatus.info:
        return AppColors.statusInfo.withAlpha(26);
      case BadgeStatus.error:
        return AppColors.error.withAlpha(26);
      case BadgeStatus.neutral:
        return AppColors.neutralTextLight.withAlpha(26);
    }
  }

  Color _getTextColor(Brightness brightness) {
    final isDark = brightness == Brightness.dark;
    switch (status) {
      case BadgeStatus.success:
        return isDark ? Colors.green.shade200 : Colors.green.shade900;
      case BadgeStatus.warning:
        return isDark ? Colors.orange.shade200 : Colors.deepOrange.shade900;
      case BadgeStatus.info:
        return isDark ? Colors.blue.shade200 : Colors.blue.shade800;
      case BadgeStatus.error:
        return isDark ? Colors.red.shade200 : Colors.red.shade800;
      case BadgeStatus.neutral:
        return isDark ? AppColors.neutralTextDark : AppColors.neutralTextLight;
    }
  }

  Color _getBorderColor(Brightness brightness) {
    final isDark = brightness == Brightness.dark;
    switch (status) {
      case BadgeStatus.success:
        return isDark ? AppColors.successBorderDark : AppColors.successBorderLight;
      case BadgeStatus.warning:
        return isDark ? AppColors.warningBorderDark : AppColors.warningBorderLight;
      case BadgeStatus.info:
        return isDark ? AppColors.infoBorderDark : AppColors.infoBorderLight;
      case BadgeStatus.error:
        return isDark ? AppColors.dangerBorderDark : AppColors.dangerBorderLight;
      case BadgeStatus.neutral:
        return isDark ? AppColors.neutralBorderDark : AppColors.neutralBorderLight;
    }
  }

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: _getBackgroundColor(),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: _getBorderColor(brightness)),
      ),
      child: Text(
        text.toUpperCase(),
        style: TextStyle(
          color: _getTextColor(brightness),
          fontSize: 11,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.4,
        ),
      ),
    );
  }
}
