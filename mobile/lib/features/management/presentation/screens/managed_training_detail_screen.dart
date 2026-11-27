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
              if (canVersions || canCreateVersion) ...[
                const SizedBox(height: AppSpacing.lg),
                const SectionHeading('Version history'),
                if (canVersions)
                  TrainingNavigationCard(
                    title: 'View version history',
                    description: 'Browse versions for this course.',
                    icon: Icons.history_outlined,
                    onTap: () => context.push(
                      '/workspace/training/catalog/$trainingId/versions',
                    ),
                  )
                else
                  TrainingNavigationCard(
                    title: 'Create draft version',
                    description: 'Add a draft for this course.',
                    icon: Icons.post_add_outlined,
                    onTap: () => context.push(
                      '/workspace/training/catalog/$trainingId/versions/new',
                      extra: course,
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
