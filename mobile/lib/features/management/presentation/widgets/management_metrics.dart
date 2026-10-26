import 'package:flutter/material.dart';
import 'package:training_app/core/presentation/components/custom_card.dart';
import 'package:training_app/core/theme/app_colors.dart';
import 'package:training_app/core/theme/app_spacing.dart';

/// Displays server-provided values without calculating or inferring progress.
class ManagementMetricGrid extends StatelessWidget {
  final Map<String, String> values;
  final bool highlightOverdue;

  const ManagementMetricGrid({
    super.key,
    required this.values,
    this.highlightOverdue = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns =
            constraints.maxWidth >= 320 &&
                MediaQuery.textScalerOf(context).scale(14) <= 21
            ? 2
            : 1;
        final width =
            (constraints.maxWidth - AppSpacing.md * (columns - 1)) / columns;
        return Wrap(
          spacing: AppSpacing.md,
          runSpacing: AppSpacing.md,
          children: [
            for (final entry in values.entries)
              SizedBox(
                width: width,
                child: Semantics(
                  container: true,
                  label: '${entry.key}: ${entry.value}',
                  excludeSemantics: true,
                  child: CustomCard(
                    key: ValueKey('management-metric-${entry.key}'),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (entry.key == 'Overdue' && highlightOverdue)
                          Icon(
                            Icons.warning_amber_rounded,
                            color: dark
                                ? AppColors.warningTextDark
                                : AppColors.warningTextLight,
                          ),
                        Text(entry.key, style: theme.textTheme.labelLarge),
                        const SizedBox(height: 8),
                        Text(
                          entry.value,
                          style: theme.textTheme.headlineMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                            color: entry.key == 'Overdue' && highlightOverdue
                                ? (dark
                                      ? AppColors.warningTextDark
                                      : AppColors.warningTextLight)
                                : theme.colorScheme.primary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}
