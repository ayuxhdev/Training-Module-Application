import 'dart:async';

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

class TrainingCatalogScreen extends ConsumerStatefulWidget {
  const TrainingCatalogScreen({super.key});

  @override
  ConsumerState<TrainingCatalogScreen> createState() =>
      _TrainingCatalogScreenState();
}

class _TrainingCatalogScreenState extends ConsumerState<TrainingCatalogScreen> {
  static const _searchDebounceDuration = Duration(milliseconds: 350);

  final _searchController = TextEditingController();
  Timer? _searchDebounce;
  String _searchQuery = '';
  int _page = 1;

  TrainingCatalogRequest _request({int? page}) =>
      (page: page ?? _page, search: _searchQuery.isEmpty ? null : _searchQuery);

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  void _onSearchChanged(String _) {
    _searchDebounce?.cancel();
    setState(() {});
    _searchDebounce = Timer(_searchDebounceDuration, () {
      if (!mounted) return;
      final query = _searchController.text.trim();
      if (_searchQuery == query) return;
      setState(() {
        _searchQuery = query;
        _page = 1;
      });
    });
  }

  void _clearSearch() {
    _searchDebounce?.cancel();
    _searchController.clear();
    setState(() {
      _searchQuery = '';
      _page = 1;
    });
  }

  Future<void> _refresh() async {
    final request = _request();
    ref.invalidate(managedTrainingsProvider(request));
    try {
      await ref.read(managedTrainingsProvider(request).future);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authControllerProvider);
    if (auth is! AuthAuthenticated || !canViewTraining(auth.identity)) {
      return Scaffold(
        appBar: AppBar(title: const Text('Training catalog')),
        body: const Center(
          child: Text(
            'You do not have permission to view the training catalog.',
          ),
        ),
      );
    }

    final request = _request();
    final asyncData = ref.watch(managedTrainingsProvider(request));
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Training catalog'),
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
            // Search Bar
            TextField(
              controller: _searchController,
              onChanged: _onSearchChanged,
              decoration: InputDecoration(
                hintText: 'Search courses by title or code...',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _searchController.text.isNotEmpty
                    ? IconButton(
                        tooltip: 'Clear search',
                        icon: const Icon(Icons.clear),
                        onPressed: _clearSearch,
                      )
                    : null,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.md,
                  vertical: AppSpacing.sm,
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.md),

            // Content
            asyncData.when(
              loading: () => const CardListSkeleton(
                message: 'Loading course catalog',
                showHeader: false,
                compact: true,
              ),
              error: (error, _) => ApiErrorView(
                error: error,
                onRetry: () =>
                    ref.refresh(managedTrainingsProvider(request).future),
              ),
              data: (page) {
                if (page.items.isEmpty) {
                  return _searchQuery.isNotEmpty
                      ? EmptyView(
                          message: 'No courses match "$_searchQuery".',
                          icon: Icons.search_off,
                        )
                      : const EmptyView(
                          message: 'No training courses currently in catalog.',
                          icon: Icons.school_outlined,
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
                        '${page.count} course(s) in catalog',
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                    ...page.items.map(
                      (course) => Padding(
                        padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                        child: _courseCard(context, course),
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

  Widget _courseCard(BuildContext context, ManagedTraining course) {
    final theme = Theme.of(context);

    return CustomCard(
      onTap: () => context.push('/workspace/training/catalog/${course.id}'),
      semanticLabel: 'Course: ${course.title}. Code: ${course.code}',
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
                      course.title,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Code: ${course.code}',
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
          if (course.description.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.xs),
            Text(
              course.description,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
          const SizedBox(height: AppSpacing.sm),
          Wrap(
            spacing: 8,
            runSpacing: 4,
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
                VersionLifecycleBadge(status: course.latestVersionStatus!),
            ],
          ),
        ],
      ),
    );
  }
}
