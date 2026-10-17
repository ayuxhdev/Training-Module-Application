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
}
