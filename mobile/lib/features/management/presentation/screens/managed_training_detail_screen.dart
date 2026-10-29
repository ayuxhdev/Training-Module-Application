import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:training_app/core/presentation/components/api_error_view.dart';
import 'package:training_app/core/presentation/components/cinematic_components.dart';
import 'package:training_app/core/presentation/components/content_skeleton.dart';
import 'package:training_app/core/presentation/components/custom_card.dart';
import 'package:training_app/core/presentation/components/status_badge.dart';
import 'package:training_app/core/theme/app_spacing.dart';
import 'package:training_app/features/auth/domain/models/auth_state.dart';
import 'package:training_app/features/auth/presentation/controllers/auth_controller.dart';
import 'package:training_app/features/management/presentation/components/curriculum_components.dart';
import 'package:training_app/features/management/presentation/controllers/management_controller.dart';

class ManagedTrainingDetailScreen extends ConsumerWidget {
  final int trainingId;

  const ManagedTrainingDetailScreen({super.key, required this.trainingId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authControllerProvider);
    if (auth is! AuthAuthenticated || !canViewTraining(auth.identity)) {
      return Scaffold(
        appBar: AppBar(title: const Text('Course details')),
        body: const Center(
          child: Text('You do not have permission to view course details.'),
        ),
      );
    }

    final asyncCourse = ref.watch(managedTrainingDetailProvider(trainingId));
    final identity = auth.identity;
    final canVersions = canViewVersions(identity);
    final canCreateVersion = canCreateVersions(identity);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Course details'),
        actions: [
          if (canEditTraining(identity))
            IconButton(
              tooltip: 'Edit course',
              onPressed: () => context.push(
                '/workspace/training/catalog/$trainingId/edit',
                extra: asyncCourse.asData?.value,
              ),
              icon: const Icon(Icons.edit_outlined),
            ),
          IconButton(
            tooltip: 'Refresh',
            onPressed: () =>
                ref.refresh(managedTrainingDetailProvider(trainingId).future),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: asyncCourse.when(
        loading: () => const Center(
          child: CardListSkeleton(
            message: 'Loading course details',
            compact: true,
          ),
        ),
        error: (error, _) => ApiErrorView(
          error: error,
          onRetry: () =>
              ref.refresh(managedTrainingDetailProvider(trainingId).future),
        ),
        data: (course) => RefreshIndicator(
          onRefresh: () async {
            ref.invalidate(managedTrainingDetailProvider(trainingId));
            await ref.read(managedTrainingDetailProvider(trainingId).future);
          },
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.all(AppSpacing.md),
            children: [
              CinematicHero(
                eyebrow: 'COURSE ${course.code}',
                title: course.title,
                subtitle: course.description.isNotEmpty
                    ? course.description
                    : 'No description provided.',
                icon: Icons.school_outlined,
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    StatusBadge(
                      text: course.isActive ? 'ACTIVE' : 'INACTIVE',
                      status: course.isActive
                          ? BadgeStatus.success
                          : BadgeStatus.neutral,
                    ),
                    if (course.latestVersionNumber != null)
                      StatusBadge(
                        text: 'Version ${course.latestVersionNumber}',
                        status: BadgeStatus.neutral,
                      ),
                    if (course.latestVersionStatus != null)
                      VersionLifecycleBadge(
                        status: course.latestVersionStatus!,
                      ),
                  ],
                ),
              ),
              const SizedBox(height: AppSpacing.lg),

              // Course metadata
              const SectionHeading(
                'Course specifications',
                subtitle: 'Authoritative configuration from training catalog.',
              ),
              CustomCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _metadataRow(
                      context,
                      label: 'Course code',
                      value: course.code,
                    ),
                    const Divider(height: AppSpacing.md),
                    _metadataRow(
                      context,
                      label: 'Lifecycle state',
                      value: course.isActive
                          ? 'Active for training'
                          : 'Inactive course',
                    ),
                    const Divider(height: AppSpacing.md),
                    _metadataRow(
                      context,
                      label: 'Latest version',
                      value: course.latestVersionNumber != null
                          ? 'Version ${course.latestVersionNumber} (${course.latestVersionStatus ?? 'UNKNOWN'})'
                          : 'No versions created yet',
                    ),
                    if (course.description.isNotEmpty) ...[
                      const Divider(height: AppSpacing.md),
                      _metadataRow(
                        context,
                        label: 'Description',
                        value: course.description,
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: AppSpacing.lg),

              // Version History navigation
              const SectionHeading(
                'Version history',
                subtitle: 'Immutability and lifecycle records for this course.',
              ),
              if (canVersions)
                CustomCard(
                  onTap: () => context.push(
                    '/workspace/training/catalog/$trainingId/versions',
                  ),
                  semanticLabel: 'Browse version history for ${course.title}',
                  child: Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: Theme.of(context)
                              .colorScheme
                              .surfaceContainerHigh,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Icon(
                          Icons.history_outlined,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                      ),
                      const SizedBox(width: AppSpacing.md),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'View version history',
                              style: Theme.of(context).textTheme.titleSmall
                                  ?.copyWith(fontWeight: FontWeight.bold),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              'Inspect draft, published, and retired curriculum versions.',
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurfaceVariant,
                                  ),
                            ),
                          ],
                        ),
                      ),
                      const Icon(Icons.chevron_right),
                    ],
                  ),
                )
              else
                const CustomCard(
                  child: Row(
                    children: [
                      Icon(Icons.lock_outline, size: 20),
                      SizedBox(width: AppSpacing.sm),
                      Expanded(
                        child: Text(
                          'Version history requires version view permissions.',
                        ),
                      ),
                      StatusBadge(
                        text: 'Restricted',
                        status: BadgeStatus.neutral,
                      ),
                    ],
                  ),
                ),
              if (canCreateVersion) ...[
                const SizedBox(height: AppSpacing.sm),
                CustomCard(
                  onTap: () => context.push(
                    '/workspace/training/catalog/$trainingId/versions/new',
                    extra: course,
                  ),
                  semanticLabel: 'Create draft version for ${course.title}',
                  child: Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.primaryContainer,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Icon(
                          Icons.post_add_outlined,
                          color: Theme.of(context)
                              .colorScheme
                              .onPrimaryContainer,
                        ),
                      ),
                      const SizedBox(width: AppSpacing.md),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Create draft version',
                              style: Theme.of(context).textTheme.titleSmall
                                  ?.copyWith(fontWeight: FontWeight.bold),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              'Author a new draft curriculum revision for this course.',
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurfaceVariant,
                                  ),
                            ),
                          ],
                        ),
                      ),
                      const Icon(Icons.chevron_right),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _metadataRow(
    BuildContext context, {
    required String label,
    required String value,
  }) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        label,
        style: Theme.of(context).textTheme.bodySmall
            ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
      ),
      const SizedBox(height: 2),
      Text(
        value,
        style: Theme.of(context).textTheme.bodyMedium
            ?.copyWith(fontWeight: FontWeight.w500),
      ),
    ],
  );
}
