import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:training_app/core/presentation/components/api_error_view.dart';
import 'package:training_app/core/presentation/components/content_skeleton.dart';
import 'package:training_app/core/presentation/components/custom_card.dart';
import 'package:training_app/core/presentation/components/empty_view.dart';
import 'package:training_app/core/presentation/components/status_badge.dart';
import 'package:training_app/core/theme/app_spacing.dart';
import 'package:training_app/features/auth/domain/models/auth_state.dart';
import 'package:training_app/features/auth/presentation/controllers/auth_controller.dart';
import 'package:training_app/features/management/domain/models/management_models.dart';
import 'package:training_app/features/management/presentation/components/curriculum_components.dart';
import 'package:training_app/features/management/presentation/controllers/management_controller.dart';

/// Read-only directory listing all training versions across the organization.
/// Allows version-authorized users without catalog access to browse versions.
class TrainingVersionDirectoryScreen extends ConsumerStatefulWidget {
  const TrainingVersionDirectoryScreen({super.key});

  @override
  ConsumerState<TrainingVersionDirectoryScreen> createState() =>
      _TrainingVersionDirectoryScreenState();
}

class _TrainingVersionDirectoryScreenState
    extends ConsumerState<TrainingVersionDirectoryScreen> {
  int _page = 1;

  Future<void> _refresh() async {
    ref.invalidate(allTrainingVersionsProvider(_page));
    try {
      await ref.read(allTrainingVersionsProvider(_page).future);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authControllerProvider);
    if (auth is! AuthAuthenticated || !canViewVersions(auth.identity)) {
      return Scaffold(
        appBar: AppBar(title: const Text('Training versions')),
        body: const Center(
          child: Text('You do not have permission to view training versions.'),
        ),
      );
    }

    final asyncData = ref.watch(allTrainingVersionsProvider(_page));
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Training versions'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: asyncData.isLoading ? null : () => _refresh(),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(AppSpacing.md),
          children: [
            // Architectural policy card
            CustomCard(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.history_outlined,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Version Directory & Immutability',
                          style: theme.textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'All training versions across courses. Published versions are '
                          'immutable and pinned to learner assignments.',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.md),

            asyncData.when(
              loading: () => const CardListSkeleton(
                message: 'Loading versions',
                compact: true,
                showHeader: false,
              ),
              error: (error, _) => ApiErrorView(
                error: error,
                onRetry: () =>
                    ref.refresh(allTrainingVersionsProvider(_page).future),
              ),
              data: (page) {
                if (page.items.isEmpty) {
                  return const EmptyView(
                    message: 'No training versions found.',
                    icon: Icons.history,
                  );
                }

                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(
                        left: 4,
                        bottom: AppSpacing.sm,
                      ),
                      child: Text(
                        '${page.count} version(s) recorded',
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                    ...page.items.map(
                      (version) => Padding(
                        padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                        child: _versionCard(context, version),
                      ),
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    // Pagination
                    Wrap(
                      alignment: WrapAlignment.spaceBetween,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        TextButton.icon(
                          onPressed: _page > 1
                              ? () => setState(() => _page--)
                              : null,
                          icon: const Icon(Icons.chevron_left),
                          label: const Text('Previous page'),
                        ),
                        Text(
                          'Page $_page',
                          style: theme.textTheme.labelMedium?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                        TextButton.icon(
                          onPressed: page.hasMore
                              ? () => setState(() => _page++)
                              : null,
                          icon: const Icon(Icons.chevron_right),
                          label: const Text('Next page'),
                        ),
                      ],
                    ),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _versionCard(
    BuildContext context,
    ManagedTrainingVersionItem version,
  ) {
    final theme = Theme.of(context);
    final status = version.status.toUpperCase();
    final lifecycleDescription = switch (status) {
      'PUBLISHED' => 'Published version · Immutable and pinned to assignments',
      'DRAFT' => 'Draft version · Content is actively mutable',
      'RETIRED' => 'Retired version · Historical read-only archive',
      _ => 'Version status: $status',
    };

    return CustomCard(
      onTap: () => context.push('/workspace/training/versions/${version.id}'),
      semanticLabel:
          'Version ${version.versionNumber}: ${version.title}. Status $status',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (version.trainingTitle != null &&
                        version.trainingTitle!.isNotEmpty) ...[
                      Text(
                        version.trainingTitle!,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.primary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 2),
                    ],
                    Text(
                      version.title.isNotEmpty
                          ? version.title
                          : 'Version ${version.versionNumber}',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      lifecycleDescription,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right),
            ],
          ),
          if (version.description.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.xs),
            Text(
              version.description,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall,
            ),
          ],
          const SizedBox(height: AppSpacing.sm),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              StatusBadge(
                text: 'Version ${version.versionNumber}',
                status: BadgeStatus.neutral,
              ),
              VersionLifecycleBadge(status: version.status),
            ],
          ),
        ],
      ),
    );
  }
}
