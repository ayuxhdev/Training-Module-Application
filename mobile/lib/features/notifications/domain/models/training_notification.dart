enum NotificationType { assigned, approaching, overdue, completed }

int notificationInteger(Object? value, {int minimum = 0}) {
  if (value is! int || value < minimum) {
    throw const FormatException('Invalid notification integer.');
  }
  return value;
}

class TrainingNotification {
  final int id;
  final NotificationType type;
  final String title;
  final String message;
  final int assignmentId;
  final DateTime createdAt;
  final DateTime? readAt;

  const TrainingNotification({
    required this.id,
    required this.type,
    required this.title,
    required this.message,
    required this.assignmentId,
    required this.createdAt,
    required this.readAt,
  });

  bool get isRead => readAt != null;

  factory TrainingNotification.fromJson(Map<String, dynamic> json) {
    final created = DateTime.parse(json['created_at'] as String);
    final read = json['read_at'] == null
        ? null
        : DateTime.parse(json['read_at'] as String);
    if (json['is_read'] is! bool || json['is_read'] != (read != null)) {
      throw const FormatException('Inconsistent notification read state.');
    }
    return TrainingNotification(
      id: notificationInteger(json['id'], minimum: 1),
      type: switch (json['type']) {
        'ASSIGNED' => NotificationType.assigned,
        'APPROACHING' => NotificationType.approaching,
        'OVERDUE' => NotificationType.overdue,
        'COMPLETED' => NotificationType.completed,
        _ => throw const FormatException('Unknown notification type.'),
      },
      title: json['title'] as String,
      message: json['message'] as String,
      assignmentId: notificationInteger(json['assignment_id'], minimum: 1),
      createdAt: created,
      readAt: read,
    );
  }
}

class NotificationPage {
  final List<TrainingNotification> items;
  final int count;
  final bool hasMore;

  NotificationPage({
    required List<TrainingNotification> items,
    required this.count,
    required this.hasMore,
  }) : items = List.unmodifiable(items);

  factory NotificationPage.fromJson(Map<String, dynamic> json) {
    final next = json['next'];
    if (next != null && next is! String) {
      throw const FormatException('Invalid notification pagination.');
    }
    final items = (json['results'] as List)
        .map(
          (item) => TrainingNotification.fromJson(item as Map<String, dynamic>),
        )
        .toList();
    if (next != null && items.isEmpty) {
      throw const FormatException('Empty notification page with a next page.');
    }
    return NotificationPage(
      items: items,
      count: notificationInteger(json['count']),
      hasMore: next != null,
    );
  }
}
