import 'package:flutter/material.dart';
import 'package:training_app/core/presentation/components/custom_card.dart';
import 'package:training_app/core/presentation/components/status_badge.dart';
import 'package:training_app/core/theme/app_spacing.dart';
import 'package:training_app/features/management/domain/models/management_models.dart';

/// Reusable badge reflecting version lifecycle immutability and state.
class VersionLifecycleBadge extends StatelessWidget {
  final String status;

  const VersionLifecycleBadge({super.key, required this.status});

  @override
  Widget build(BuildContext context) {
    final normalized = status.toUpperCase();
    final badgeStatus = switch (normalized) {
      'PUBLISHED' => BadgeStatus.success,
      'DRAFT' => BadgeStatus.warning,
      'RETIRED' => BadgeStatus.neutral,
      _ => BadgeStatus.info,
    };
    return StatusBadge(text: normalized, status: badgeStatus);
  }
}

/// Reusable read-only summary row for a curriculum lesson.
class ManagedLessonSummaryRow extends StatelessWidget {
  final ManagedLessonSummary lesson;

  const ManagedLessonSummaryRow({super.key, required this.lesson});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isVideo = lesson.lessonType.toUpperCase() == 'VIDEO';

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Icon(
            isVideo ? Icons.play_circle_outline : Icons.article_outlined,
            size: 20,
            color: isVideo
                ? theme.colorScheme.primary
                : theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              '${lesson.order}. ${lesson.title}',
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          const SizedBox(width: AppSpacing.xs),
          StatusBadge(
            text: isVideo ? 'VIDEO' : 'TEXT',
            status: isVideo ? BadgeStatus.info : BadgeStatus.neutral,
          ),
          const SizedBox(width: AppSpacing.xs),
          StatusBadge(
            text: lesson.isRequired ? 'REQUIRED' : 'OPTIONAL',
            status: lesson.isRequired ? BadgeStatus.neutral : BadgeStatus.info,
          ),
        ],
      ),
    );
  }
}

/// Reusable module card presenting module details, ordered lessons,
/// and future disabled authoring action slots.
class ManagedModuleCard extends StatelessWidget {
  final ManagedModule module;
  final Widget? actionSlot;

  const ManagedModuleCard({super.key, required this.module, this.actionSlot});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return CustomCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(
                  Icons.view_module_outlined,
                  size: 20,
                  color: theme.colorScheme.primary,
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Module ${module.order}: ${module.title}',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (module.description.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        module.description,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (actionSlot != null) ...[
                const SizedBox(width: AppSpacing.xs),
                actionSlot!,
              ],
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          const Divider(height: 1),
          const SizedBox(height: AppSpacing.sm),
          if (module.lessons.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
              child: Text(
                'No lessons currently in this module.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  fontStyle: FontStyle.italic,
                ),
              ),
            )
          else
            ...module.lessons.map(
              (lesson) => ManagedLessonSummaryRow(lesson: lesson),
            ),
        ],
      ),
    );
  }
}
