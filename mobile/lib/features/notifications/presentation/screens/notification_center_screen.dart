import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:training_app/core/presentation/components/api_error_view.dart';
import 'package:training_app/core/presentation/components/cinematic_components.dart';
import 'package:training_app/core/presentation/components/content_skeleton.dart';
import 'package:training_app/core/presentation/components/empty_view.dart';
import 'package:training_app/core/presentation/components/error_view.dart';
import 'package:training_app/core/theme/app_spacing.dart';
import 'package:training_app/features/auth/domain/models/auth_state.dart';
import 'package:training_app/features/auth/presentation/controllers/auth_controller.dart';
import 'package:training_app/features/notifications/domain/models/training_notification.dart';
import 'package:training_app/features/notifications/presentation/controllers/notification_controller.dart';

class NotificationCenterScreen extends ConsumerStatefulWidget {
  const NotificationCenterScreen({super.key});

  @override
  ConsumerState<NotificationCenterScreen> createState() =>
      _NotificationCenterScreenState();
}

class _NotificationCenterScreenState
    extends ConsumerState<NotificationCenterScreen> {
  late final TextEditingController _searchController;
  Timer? _debounceTimer;

  @override
  void initState() {
    super.initState();
    _searchController = TextEditingController();
  }

  @override
  void dispose() {
    _debounceTimer?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  void _onSearchChanged(String text) {
    setState(() {});
    _debounceTimer?.cancel();
    _debounceTimer = Timer(const Duration(milliseconds: 250), () {
      if (mounted) {
        ref.read(notificationListProvider.notifier).applyFilter(query: text);
      }
    });
  }

  void _clearFilters() {
    _debounceTimer?.cancel();
    _searchController.clear();
    setState(() {});
    ref
        .read(notificationListProvider.notifier)
        .applyFilter(status: NotificationReadFilter.all, query: '');
  }

  Future<void> _refresh() async {
    final result = ref.read(notificationListProvider);
    final feed = result.asData?.value;
    if (feed?.busy == true || feed?.filtering == true) return;
    ref.invalidate(notificationUnreadCountProvider);
    if (feed?.filterError != null) {
      await ref.read(notificationListProvider.notifier).applyFilter();
      return;
    }
    if (result.error is NotificationMutationError) {
      await ref.read(notificationListProvider.notifier).reconcile();
      return;
    }
    await ref
        .refresh(notificationListProvider.future)
        .then<void>((_) {}, onError: (Object _, StackTrace _) {});
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<AuthState>(authControllerProvider, (previous, next) {
      if (previous != next) {
        _debounceTimer?.cancel();
        _searchController.clear();
      }
    });

    final result = ref.watch(notificationListProvider);
    final unread = ref.watch(notificationUnreadCountProvider);
    final feed = result.asData?.value;
    final working =
        feed?.busy == true ||
        feed?.loadingMore == true ||
        feed?.filtering == true ||
        feed?.filterError != null;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Notifications'),
        actions: [
          IconButton(
            tooltip: 'Mark all as read',
            icon: const Icon(Icons.done_all),
            onPressed:
                feed == null ||
                    working ||
                    (unread.asData?.value == 0 &&
                        !feed.items.any((item) => !item.isRead))
                ? null
                : () =>
                      ref.read(notificationListProvider.notifier).markAllRead(),
          ),
        ],
      ),
      body: result.when(
        skipLoadingOnRefresh: false,
        skipLoadingOnReload: false,
        loading: () => const SkeletonPage(
          child: CardListSkeleton(message: 'Loading notifications…'),
        ),
        error: (error, _) =>
            error is NotificationMutationError &&
                error.statusCode != 401 &&
                error.statusCode != 403
            ? ErrorView(
                title: 'Read status not confirmed',
                message: error.message,
                retryLabel: 'Refresh',
                onRetry: _refresh,
              )
            : ApiErrorView(error: error, onRetry: _refresh),
        data: (feed) {
          if (feed == null) return const SizedBox.shrink();
          if (feed.filterError case final error? when error.statusCode == 401) {
            return ApiErrorView(error: error, onRetry: _refresh);
          }
          if (feed.filterError case final error? when error.statusCode == 403) {
            return ErrorView(
              title: 'Access denied',
              message: error.message,
              retryLabel: 'Retry',
              onRetry: _refresh,
            );
          }
          final hasItems = feed.items.isNotEmpty;

          return RefreshIndicator(
            onRefresh: _refresh,
            child: ListView.builder(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: AppSpacing.pagePadding,
              itemCount: hasItems ? feed.items.length + 2 : 2,
              itemBuilder: (context, index) {
                if (index == 0) {
                  return Padding(
                    padding: const EdgeInsets.only(bottom: AppSpacing.md),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        CinematicHero(
                          eyebrow: 'Notification center',
                          title: 'Your updates',
                          subtitle: 'Stay in step with your training.',
                          icon: Icons.notifications_none_rounded,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Semantics(
                                liveRegion: true,
                                child: Text(
                                  unread.isLoading
                                      ? 'Checking unread notifications…'
                                      : unread.hasError ||
                                            unread.asData?.value == null
                                      ? 'Unread count unavailable'
                                      : '${unread.asData!.value} unread · ${feed.count} notification${feed.count == 1 ? '' : 's'}',
                                ),
                              ),
                              if (unread.hasError)
                                TextButton.icon(
                                  onPressed: () => ref.invalidate(
                                    notificationUnreadCountProvider,
                                  ),
                                  icon: const Icon(Icons.refresh),
                                  label: const Text('Refresh unread count'),
                                ),
                              if (feed.busy)
                                Padding(
                                  padding: const EdgeInsets.only(
                                    top: AppSpacing.sm,
                                  ),
                                  child: Semantics(
                                    liveRegion: true,
                                    child: const Text('Saving read status…'),
                                  ),
                                ),
                            ],
                          ),
                        ),
                        if (feed.filtering)
                          Padding(
                            padding: EdgeInsets.only(bottom: AppSpacing.sm),
                            child: Semantics(
                              liveRegion: true,
                              child: const Text('Updating notifications…'),
                            ),
                          ),
                        if (feed.filterError != null)
                          Padding(
                            padding: const EdgeInsets.only(
                              bottom: AppSpacing.sm,
                            ),
                            child: ApiErrorView(
                              error: feed.filterError!,
                              onRetry: _refresh,
                            ),
                          ),
                        const SizedBox(height: AppSpacing.md),
                        _buildFilterSection(context, feed),
                      ],
                    ),
                  );
                }

                if (hasItems && index <= feed.items.length) {
                  final item = feed.items[index - 1];
                  return _NotificationCard(
                    item: item,
                    working: working,
                    onRead: () => ref
                        .read(notificationListProvider.notifier)
                        .markRead(item.id),
                  );
                }

                if (!hasItems) {
                  if (feed.filtering || feed.filterError != null) {
                    return const SizedBox.shrink();
                  }
                  if (!feed.hasActiveFilters) {
                    return const EmptyView(
                      message: 'You’re all caught up. Training updates will appear here.',
                      icon: Icons.notifications_none,
                    );
                  }
                  return _buildFilteredEmptyView(context, feed);
                }

                return _buildFooter(context, feed, working);
              },
            ),
          );
        },
      ),
    );
  }

  Widget _buildFilterSection(BuildContext context, NotificationFeed feed) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _searchController,
          decoration: InputDecoration(
            labelText: 'Search notifications',
            hintText: 'Search by title or message',
            prefixIcon: const Icon(Icons.search),
            suffixIcon: _searchController.text.isNotEmpty
                ? IconButton(
                    icon: const Icon(Icons.clear),
                    tooltip: 'Clear search',
                    style: IconButton.styleFrom(
                      minimumSize: const Size.square(48),
                      tapTargetSize: MaterialTapTargetSize.padded,
                    ),
                    onPressed: () {
                      _searchController.clear();
                      _onSearchChanged('');
                    },
                  )
                : null,
            border: const OutlineInputBorder(
              borderRadius: BorderRadius.all(Radius.circular(16)),
            ),
            isDense: true,
          ),
          textInputAction: TextInputAction.search,
          onChanged: _onSearchChanged,
          onSubmitted: (text) {
            _debounceTimer?.cancel();
            ref
                .read(notificationListProvider.notifier)
                .applyFilter(query: text);
          },
        ),
        const SizedBox(height: AppSpacing.sm),
        Wrap(
          spacing: AppSpacing.xs,
          runSpacing: AppSpacing.xs,
          children: [
            ChoiceChip(
              materialTapTargetSize: MaterialTapTargetSize.padded,
              label: const Text('All'),
              selected: feed.status == NotificationReadFilter.all,
              onSelected: (selected) {
                if (selected) {
                  ref
                      .read(notificationListProvider.notifier)
                      .applyFilter(status: NotificationReadFilter.all);
                }
              },
            ),
            ChoiceChip(
              materialTapTargetSize: MaterialTapTargetSize.padded,
              label: const Text('Unread'),
              selected: feed.status == NotificationReadFilter.unread,
              onSelected: (selected) {
                if (selected) {
                  ref
                      .read(notificationListProvider.notifier)
                      .applyFilter(status: NotificationReadFilter.unread);
                }
              },
            ),
            ChoiceChip(
              materialTapTargetSize: MaterialTapTargetSize.padded,
              label: const Text('Read'),
              selected: feed.status == NotificationReadFilter.read,
              onSelected: (selected) {
                if (selected) {
                  ref
                      .read(notificationListProvider.notifier)
                      .applyFilter(status: NotificationReadFilter.read);
                }
              },
            ),
            if (feed.hasActiveFilters)
              ActionChip(
                materialTapTargetSize: MaterialTapTargetSize.padded,
                avatar: const Icon(Icons.clear_all, size: 18),
                label: const Text('Clear search and filters'),
                onPressed: _clearFilters,
              ),
          ],
        ),
        if (feed.hasActiveFilters &&
            !feed.filtering &&
            feed.filterError == null) ...[
          const SizedBox(height: AppSpacing.xs),
          Semantics(
            liveRegion: true,
            child: Text(
              'Showing ${feed.items.length} of ${feed.count} notification${feed.count == 1 ? '' : 's'}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: colors.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildFilteredEmptyView(BuildContext context, NotificationFeed feed) {
    if (feed.status == NotificationReadFilter.unread && feed.query.isEmpty) {
      return EmptyView(
        icon: Icons.mark_email_read_outlined,
        title: 'No unread notifications',
        message: 'You have no unread notifications. You’re all caught up on your updates.',
        action: TextButton(
          style: TextButton.styleFrom(
            minimumSize: const Size(48, 48),
            tapTargetSize: MaterialTapTargetSize.padded,
          ),
          onPressed: () => ref
              .read(notificationListProvider.notifier)
              .applyFilter(status: NotificationReadFilter.all),
          child: const Text('View all notifications'),
        ),
      );
    }

    if (feed.query.isNotEmpty) {
      return EmptyView(
        icon: Icons.search_off_outlined,
        title: 'No matching notifications',
        message:
            'No notifications match "${feed.query}". Try adjusting your search query.',
        action: TextButton(
          style: TextButton.styleFrom(
            minimumSize: const Size(48, 48),
            tapTargetSize: MaterialTapTargetSize.padded,
          ),
          onPressed: _clearFilters,
          child: const Text('Clear search and filters'),
        ),
      );
    }

    return EmptyView(
      icon: Icons.notifications_none_outlined,
      title: 'No read notifications',
      message: 'You have no read notifications yet.',
      action: TextButton(
        style: TextButton.styleFrom(
          minimumSize: const Size(48, 48),
          tapTargetSize: MaterialTapTargetSize.padded,
        ),
        onPressed: () => ref
            .read(notificationListProvider.notifier)
            .applyFilter(status: NotificationReadFilter.all),
        child: const Text('View all notifications'),
      ),
    );
  }

  Widget _buildFooter(
    BuildContext context,
    NotificationFeed feed,
    bool working,
  ) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (feed.moreError case final error?)
          ApiErrorView(
            error: error,
            onRetry: () =>
                ref.read(notificationListProvider.notifier).loadMore(),
          ),
        if (feed.nextPage != null && feed.moreError == null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
            child: OutlinedButton.icon(
              onPressed: working
                  ? null
                  : () =>
                        ref.read(notificationListProvider.notifier).loadMore(),
              icon: const Icon(Icons.expand_more),
              label: Text(
                feed.loadingMore ? 'Loading more…' : 'Load more notifications',
              ),
            ),
          ),
      ],
    );
  }
}

class _NotificationCard extends StatelessWidget {
  final TrainingNotification item;
  final bool working;
  final VoidCallback onRead;
  const _NotificationCard({
    required this.item,
    required this.working,
    required this.onRead,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final icon = switch (item.type) {
      NotificationType.assigned => Icons.assignment_outlined,
      NotificationType.approaching => Icons.schedule,
      NotificationType.overdue => Icons.event_busy,
      NotificationType.completed => Icons.task_alt,
    };
    final local = item.createdAt.toLocal();
    final locale = MaterialLocalizations.of(context);
    final received =
        '${locale.formatMediumDate(local)}, ${locale.formatTimeOfDay(TimeOfDay.fromDateTime(local))}';
    return Card(
      margin: const EdgeInsets.only(bottom: AppSpacing.md),
      color: item.isRead ? colors.surface : colors.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(24),
        side: BorderSide(
          color: item.isRead ? colors.outlineVariant : colors.primary,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ExcludeSemantics(
                  child: Icon(
                    icon,
                    color: item.type == NotificationType.overdue
                        ? colors.error
                        : colors.primary,
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Text(
                    item.title,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: item.isRead
                          ? FontWeight.w500
                          : FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            Semantics(
              label: 'Status: ${item.isRead ? "Read" : "Unread"}',
              child: Text(
                item.isRead ? 'Read' : 'Unread',
                style: theme.textTheme.labelLarge?.copyWith(
                  color: item.isRead ? colors.onSurfaceVariant : colors.primary,
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(item.message, style: theme.textTheme.bodyLarge),
            const SizedBox(height: AppSpacing.sm),
            Text(
              'Received $received',
              style: theme.textTheme.bodySmall?.copyWith(
                color: colors.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            Wrap(
              spacing: AppSpacing.sm,
              runSpacing: AppSpacing.sm,
              children: [
                TextButton.icon(
                  style: TextButton.styleFrom(
                    minimumSize: const Size(48, 48),
                    tapTargetSize: MaterialTapTargetSize.padded,
                  ),
                  onPressed: () => context.push(
                    '/learning/assignments/${item.assignmentId}',
                  ),
                  icon: const Icon(Icons.arrow_forward),
                  label: Text(
                    'Open training',
                    semanticsLabel: 'Open training for ${item.title}',
                  ),
                ),
                if (!item.isRead)
                  TextButton.icon(
                    style: TextButton.styleFrom(
                      minimumSize: const Size(48, 48),
                      tapTargetSize: MaterialTapTargetSize.padded,
                    ),
                    onPressed: working ? null : onRead,
                    icon: const Icon(Icons.mark_email_read_outlined),
                    label: Text(
                      'Mark as read',
                      semanticsLabel: 'Mark ${item.title} as read',
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
