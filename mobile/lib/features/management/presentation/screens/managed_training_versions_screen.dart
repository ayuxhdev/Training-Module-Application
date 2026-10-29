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

class ManagedTrainingVersionsScreen extends ConsumerStatefulWidget {
  final int trainingId;

  const ManagedTrainingVersionsScreen({super.key, required this.trainingId});

  @override
  ConsumerState<ManagedTrainingVersionsScreen> createState() =>
      _ManagedTrainingVersionsScreenState();
}

class _ManagedTrainingVersionsScreenState
    extends ConsumerState<ManagedTrainingVersionsScreen> {
  int _page = 1;

  TrainingVersionsRequest _request({int? page}) =>
      (trainingId: widget.trainingId, page: page ?? _page);

  Future<void> _refresh() async {
    final req = _request();
    ref.invalidate(managedTrainingVersionsProvider(req));
    try {
      await ref.read(managedTrainingVersionsProvider(req).future);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authControllerProvider);
    if (auth is! AuthAuthenticated || !canViewVersions(auth.identity)) {
      return Scaffold(
        appBar: AppBar(title: const Text('Version history')),
        body: const Center(
          child: Text('You do not have permission to view version history.'),
        ),
      );
    }

    final req = _request();
    final asyncData = ref.watch(managedTrainingVersionsProvider(req));
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Version history'),
        actions: [
          if (canCreateVersions(auth.identity))
            IconButton(
              tooltip: 'New draft version',
              onPressed: () => context.push(
                '/workspace/training/catalog/${widget.trainingId}/versions/new',
              ),
              icon: const Icon(Icons.add),
            ),
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
                  Icon(Icons.info_outline, color: theme.colorScheme.primary),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Version Pinning & Immutability',
                          style: theme.textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'PUBLISHED versions are immutable and pinned to learner '
                          'assignments. RETIRED versions remain available for existing learners.',
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
                    ref.refresh(managedTrainingVersionsProvider(req).future),
              ),
              data: (page) {
                if (page.items.isEmpty) {
                  return EmptyView(
                    message: 'No versions found for this course.',
                    icon: Icons.history,
                    action: canCreateVersions(auth.identity)
                        ? FilledButton.icon(
                            onPressed: () => context.push(
                              '/workspace/training/catalog/${widget.trainingId}/versions/new',
                            ),
                            icon: const Icon(Icons.add),
                            label: const Text('Create draft version'),
                          )
                        : null,
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
