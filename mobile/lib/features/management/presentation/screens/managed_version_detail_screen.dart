import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:training_app/core/presentation/components/api_error_view.dart';
import 'package:training_app/core/presentation/components/cinematic_components.dart';
import 'package:training_app/core/presentation/components/content_skeleton.dart';
import 'package:training_app/core/presentation/components/custom_card.dart';
import 'package:training_app/core/presentation/components/empty_view.dart';
import 'package:training_app/core/presentation/components/status_badge.dart';
import 'package:training_app/core/theme/app_spacing.dart';
import 'package:training_app/features/auth/domain/models/auth_state.dart';
import 'package:training_app/features/auth/presentation/controllers/auth_controller.dart';
import 'package:training_app/features/management/presentation/components/curriculum_components.dart';
import 'package:training_app/features/management/presentation/controllers/management_controller.dart';

class ManagedVersionDetailScreen extends ConsumerWidget {
  final int versionId;

  const ManagedVersionDetailScreen({super.key, required this.versionId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authControllerProvider);
    if (auth is! AuthAuthenticated || !canViewVersions(auth.identity)) {
      return Scaffold(
        appBar: AppBar(title: const Text('Version details')),
        body: const Center(
          child: Text('You do not have permission to view version details.'),
        ),
      );
    }

    final asyncVersion = ref.watch(managedVersionDetailProvider(versionId));
    final theme = Theme.of(context);
    final identity = auth.identity;
    final isDraft = asyncVersion.asData?.value.status.toUpperCase() == 'DRAFT';

    return Scaffold(
      appBar: AppBar(
        title: const Text('Version details'),
        actions: [
          if (isDraft && canCreateModules(identity))
            IconButton(
              tooltip: 'Create module',
              onPressed: () => context.push(
                '/workspace/training/versions/$versionId/modules/new',
                extra: asyncVersion.asData?.value,
              ),
              icon: const Icon(Icons.add_box_outlined),
            ),
          IconButton(
            tooltip: 'Refresh',
            onPressed: () =>
                ref.refresh(managedVersionDetailProvider(versionId).future),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: asyncVersion.when(
        loading: () => const Center(
          child: CardListSkeleton(message: 'Loading curriculum', compact: true),
        ),
        error: (error, _) => ApiErrorView(
          error: error,
          onRetry: () =>
              ref.refresh(managedVersionDetailProvider(versionId).future),
        ),
        data: (version) {
          final totalLessons = version.modules.fold<int>(
            0,
            (sum, m) => sum + m.lessons.length,
          );
          final status = version.status.toUpperCase();
          final lifecyclePolicy = switch (status) {
            'PUBLISHED' => 'This version is PUBLISHED and immutable. Content cannot be edited or deleted. Active learner assignments are pinned to this version.',
            'DRAFT' => 'This version is in DRAFT. Content, modules, lessons, and media can be configured before publication.',
            'RETIRED' => 'This version is RETIRED. Existing learners may complete their training, but no new assignments can be made.',
            _ => 'Version status: $status',
          };

          return RefreshIndicator(
            onRefresh: () async {
              ref.invalidate(managedVersionDetailProvider(versionId));
              await ref.read(managedVersionDetailProvider(versionId).future);
            },
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.all(AppSpacing.md),
              children: [
                CinematicHero(
                  eyebrow: 'VERSION ${version.versionNumber}',
                  title: version.title,
                  subtitle: version.description.isNotEmpty
                      ? version.description
                      : (version.trainingTitle ?? 'Curriculum structure'),
                  icon: Icons.layers_outlined,
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      VersionLifecycleBadge(status: version.status),
                      const StatusBadge(
                        text: 'MANAGEMENT VIEW',
                        status: BadgeStatus.info,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: AppSpacing.lg),

                // Lifecycle and architecture summary
                const SectionHeading(
                  'Lifecycle status',
                  subtitle: 'Garden’s Need enforces strict immutability and version rules.',
                ),
                CustomCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            status == 'PUBLISHED'
                                ? Icons.verified_outlined
                                : status == 'DRAFT'
                                ? Icons.edit_note_outlined
                                : Icons.archive_outlined,
                            color: theme.colorScheme.primary,
                          ),
                          const SizedBox(width: AppSpacing.sm),
                          Expanded(
                            child: Text(
                              '$status Version',
                              style: theme.textTheme.titleSmall?.copyWith(
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: AppSpacing.xs),
                      Text(
                        lifecyclePolicy,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: AppSpacing.sm),
                      const Divider(height: 1),
                      const SizedBox(height: AppSpacing.sm),
                      Text(
                        '${version.modules.length} module(s) · $totalLessons lesson(s) recorded',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: AppSpacing.lg),

                // Modules and lessons curriculum section
                const SectionHeading(
                  'Curriculum structure',
                  subtitle:
                      'Ordered modules and lesson summaries for this version.',
                ),
                if (status == 'DRAFT' && canCreateModules(identity))
                  Padding(
                    padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                    child: OutlinedButton.icon(
                      icon: const Icon(Icons.add),
                      label: const Text('Create module'),
                      onPressed: () => context.push(
                        '/workspace/training/versions/$versionId/modules/new',
                        extra: version,
                      ),
                    ),
                  ),
                if (version.modules.isEmpty)
                  const EmptyView(
                    message: 'No modules defined in this version.',
                    icon: Icons.view_module_outlined,
                  )
                else
                  ...version.modules.map(
                    (module) => Padding(
                      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                      child: ManagedModuleCard(
                        module: module,
                        actionSlot: status == 'DRAFT'
                            ? Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  if (canEditModules(identity))
                                    IconButton(
                                      tooltip: 'Edit module',
                                      icon: const Icon(
                                        Icons.edit_outlined,
                                        size: 20,
                                      ),
                                      visualDensity: VisualDensity.compact,
                                      padding: EdgeInsets.zero,
                                      constraints: const BoxConstraints(),
                                      onPressed: () => context.push(
                                        '/workspace/training/versions/$versionId/modules/${module.id}/edit',
                                        extra: module,
                                      ),
                                    ),
                                  if (canCreateLessons(identity)) ...[
                                    const SizedBox(width: AppSpacing.xs),
                                    IconButton(
                                      tooltip: 'Add text lesson',
                                      icon: const Icon(
                                        Icons.add_circle_outline,
                                        size: 20,
                                      ),
                                      visualDensity: VisualDensity.compact,
                                      padding: EdgeInsets.zero,
                                      constraints: const BoxConstraints(),
                                      onPressed: () => context.push(
                                        '/workspace/training/versions/$versionId/modules/${module.id}/lessons/new',
                                        extra: module,
                                      ),
                                    ),
                                  ],
                                ],
                              )
                            : null,
                        onEditLesson:
                            status == 'DRAFT' &&
                                canAccessLessonEditForm(identity)
                            ? (lesson) => context.push(
                                '/workspace/training/versions/$versionId/modules/${module.id}/lessons/${lesson.id}/edit',
                                extra: lesson,
                              )
                            : null,
                      ),
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}
