import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:training_app/features/notifications/presentation/controllers/notification_controller.dart';

class NotificationBell extends ConsumerWidget {
  const NotificationBell({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final unread = ref.watch(notificationUnreadCountProvider);
    final count = unread.asData?.value;
    final label = unread.isLoading
        ? 'Notifications, checking unread count'
        : unread.hasError || count == null
        ? 'Notifications, unread count unavailable'
        : count == 0
        ? 'Notifications, no unread notifications'
        : 'Notifications, $count unread';
    return IconButton(
      tooltip: label,
      onPressed: () => context.push('/notifications'),
      icon: ExcludeSemantics(
        child: Badge(
          isLabelVisible:
              !unread.isLoading && !unread.hasError && (count ?? 0) > 0,
          label: Text((count ?? 0) > 99 ? '99+' : '$count'),
          child: const Icon(Icons.notifications_outlined),
        ),
      ),
    );
  }
}
