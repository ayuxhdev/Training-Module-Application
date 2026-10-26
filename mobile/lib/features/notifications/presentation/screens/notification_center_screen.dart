import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:training_app/core/presentation/components/api_error_view.dart';
import 'package:training_app/core/presentation/components/cinematic_components.dart';
import 'package:training_app/core/presentation/components/empty_view.dart';
import 'package:training_app/core/presentation/components/error_view.dart';
import 'package:training_app/core/presentation/components/content_skeleton.dart';
import 'package:training_app/core/theme/app_spacing.dart';
import 'package:training_app/features/notifications/domain/models/training_notification.dart';
import 'package:training_app/features/notifications/presentation/controllers/notification_controller.dart';

class NotificationCenterScreen extends ConsumerWidget {
  const NotificationCenterScreen({super.key});

  Future<void> _refresh(WidgetRef ref) async {
    if (ref.read(notificationListProvider).asData?.value?.busy == true) return;
    ref.invalidate(notificationUnreadCountProvider);
    if (ref.read(notificationListProvider).error is NotificationMutationError) {
      await ref.read(notificationListProvider.notifier).reconcile();
      return;
    }
    await ref
        .refresh(notificationListProvider.future)
        .then<void>((_) {}, onError: (Object _, StackTrace _) {});
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final result = ref.watch(notificationListProvider);
    final unread = ref.watch(notificationUnreadCountProvider);
    final feed = result.asData?.value;
    final working = feed?.busy == true || feed?.loadingMore == true;
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
                onRetry: () => _refresh(ref),
              )
            : ApiErrorView(error: error, onRetry: () => _refresh(ref)),
        data: (feed) {
          if (feed == null) return const SizedBox.shrink();
          return RefreshIndicator(
            onRefresh: () => _refresh(ref),
            child: ListView.builder(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: AppSpacing.pagePadding,
              itemCount: feed.items.length + 2,
              itemBuilder: (context, index) {
                if (index == 0) {
                  return Padding(
                    padding: const EdgeInsets.only(bottom: AppSpacing.md),
                    child: CinematicHero(
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
                  );
                }
                if (index <= feed.items.length) {
                  final item = feed.items[index - 1];
                  return _NotificationCard(
                    item: item,
                    working: working,
                    onRead: () => ref
                        .read(notificationListProvider.notifier)
                        .markRead(item.id),
                  );
                }
                if (feed.items.isEmpty) {
                  return const EmptyView(
                    message: 'You’re all caught up. Training updates will appear here.',
                    icon: Icons.notifications_none,
                  );
                }
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (feed.moreError case final error?)
                      ApiErrorView(
                        error: error,
                        onRetry: () => ref
                            .read(notificationListProvider.notifier)
                            .loadMore(),
                      ),
                    if (feed.nextPage != null && feed.moreError == null)
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          vertical: AppSpacing.sm,
                        ),
                        child: OutlinedButton.icon(
                          onPressed: working
                              ? null
                              : () => ref
                                    .read(notificationListProvider.notifier)
                                    .loadMore(),
                          icon: const Icon(Icons.expand_more),
                          label: Text(
                            feed.loadingMore
                                ? 'Loading more…'
                                : 'Load more notifications',
                          ),
                        ),
                      ),
                  ],
                );
              },
            ),
          );
        },
      ),
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
            Text(
              item.isRead ? 'Read' : 'Unread',
              style: theme.textTheme.labelLarge?.copyWith(
                color: colors.primary,
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
