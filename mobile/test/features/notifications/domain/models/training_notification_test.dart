import 'package:flutter_test/flutter_test.dart';
import 'package:training_app/features/notifications/domain/models/training_notification.dart';

import '../../notification_fixtures.dart';

void main() {
  test(
    'parses all four backend event types and authoritative read timestamps',
    () {
      for (final type in ['ASSIGNED', 'APPROACHING', 'OVERDUE', 'COMPLETED']) {
        final item = TrainingNotification.fromJson(
          notificationJson(type: type, read: true),
        );
        expect(item.type.name.toUpperCase(), type);
        expect(item.isRead, isTrue);
        expect(item.assignmentId, 1);
        expect(item.createdAt.isUtc, isTrue);
        expect(item.readAt, DateTime.utc(2026, 10, 17, 10));
      }
      expect(notice().isRead, isFalse);
    },
  );

  test(
    'rejects forged numeric types, unknown events and inconsistent read state',
    () {
      for (final changes in <Map<String, dynamic>>[
        {'id': 0},
        {'assignment_id': -1},
        {'id': '1'},
        {'id': 1.5},
        {'id': true},
        {'type': 'UNKNOWN'},
        {'is_read': true},
        {'is_read': 'false'},
        {'created_at': 'invalid'},
      ]) {
        expect(
          () => TrainingNotification.fromJson({
            ...notificationJson(),
            ...changes,
          }),
          throwsA(anything),
        );
      }
    },
  );

  test('page matches the pagination envelope without retaining or following server URLs', () {
    final page = NotificationPage.fromJson({
      'count': 2,
      'next': 'https://untrusted.invalid/?page=2',
      'previous': null,
      'results': [notificationJson()],
    });
    expect(page.hasMore, isTrue);
    expect(page.count, 2);
    expect(page.items.single.id, 1);
    expect(() => page.items.clear(), throwsUnsupportedError);
    final empty = NotificationPage.fromJson({
      'count': 0,
      'next': null,
      'previous': null,
      'results': [],
    });
    expect(empty.hasMore, isFalse);
    expect(empty.items, isEmpty);
  });

  test('malformed or non-progressing pages are rejected', () {
    for (final changes in <Map<String, dynamic>>[
      {'count': -1},
      {'count': true},
      {'next': 2},
      {'results': {}},
      {'results': [], 'next': '/notifications/?page=2'},
    ]) {
      expect(
        () => NotificationPage.fromJson({
          'count': 1,
          'next': null,
          'previous': null,
          'results': [notificationJson()],
          ...changes,
        }),
        throwsA(anything),
      );
    }
  });

  group('NotificationReadFilter and filterTrainingNotifications', () {
    final n1 = notice(id: 1, type: 'ASSIGNED', read: false);
    final n2 = TrainingNotification(
      id: 2,
      type: NotificationType.approaching,
      title: 'Safety Deadline Approaching',
      message: 'Please complete fire safety refresher.',
      assignmentId: 2,
      createdAt: DateTime.utc(2026, 10, 18),
      readAt: DateTime.utc(2026, 10, 19),
    );
    final n3 = TrainingNotification(
      id: 3,
      type: NotificationType.overdue,
      title: 'Chemical Handling Overdue',
      message: 'Immediate safety review required.',
      assignmentId: 3,
      createdAt: DateTime.utc(2026, 10, 20),
      readAt: null,
    );
    final items = [n1, n2, n3];

    test('returns all items when filter is all and query is empty', () {
      final result = filterTrainingNotifications(
        items,
        filter: NotificationReadFilter.all,
        query: '',
      );
      expect(result.map((e) => e.id), [1, 2, 3]);
    });

    test('filters unread notifications accurately', () {
      final result = filterTrainingNotifications(
        items,
        filter: NotificationReadFilter.unread,
      );
      expect(result.map((e) => e.id), [1, 3]);
    });

    test('filters read notifications accurately', () {
      final result = filterTrainingNotifications(
        items,
        filter: NotificationReadFilter.read,
      );
      expect(result.map((e) => e.id), [2]);
    });

    test('searches case-insensitively across title and message with whitespace trimming', () {
      expect(
        filterTrainingNotifications(
          items,
          query: '  SAFETY  ',
        ).map((e) => e.id),
        [2, 3],
      );
      expect(
        filterTrainingNotifications(items, query: 'chemical').map((e) => e.id),
        [3],
      );
      expect(
        filterTrainingNotifications(items, query: 'refresher').map((e) => e.id),
        [2],
      );
      expect(
        filterTrainingNotifications(items, query: 'update 1').map((e) => e.id),
        [1],
      );
    });

    test('combines read filter and keyword search', () {
      expect(
        filterTrainingNotifications(
          items,
          filter: NotificationReadFilter.unread,
          query: 'safety',
        ).map((e) => e.id),
        [3],
      );
      expect(
        filterTrainingNotifications(
          items,
          filter: NotificationReadFilter.read,
          query: 'safety',
        ).map((e) => e.id),
        [2],
      );
    });

    test('returns empty list when no notification matches search criteria', () {
      expect(
        filterTrainingNotifications(items, query: 'nonexistent keyword'),
        isEmpty,
      );
    });
  });
}
