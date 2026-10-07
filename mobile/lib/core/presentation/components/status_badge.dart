import 'package:flutter/material.dart';
import 'package:training_app/core/theme/app_colors.dart';

enum BadgeStatus { success, warning, info, error }

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
        return AppColors.statusSuccess.withAlpha(26); // ~0.1 opacity
      case BadgeStatus.warning:
        return AppColors.statusWarning.withAlpha(26);
      case BadgeStatus.info:
        return AppColors.statusInfo.withAlpha(26);
      case BadgeStatus.error:
        return AppColors.error.withAlpha(26);
    }
  }

  Color _getTextColor() {
    switch (status) {
      case BadgeStatus.success:
        return Colors.green.shade800;
      case BadgeStatus.warning:
        return Colors.orange.shade900;
      case BadgeStatus.info:
        return Colors.blue.shade800;
      case BadgeStatus.error:
        return Colors.red.shade800;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: _getBackgroundColor(),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text.toUpperCase(),
        style: TextStyle(
          color: _getTextColor(),
          fontSize: 12,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}
