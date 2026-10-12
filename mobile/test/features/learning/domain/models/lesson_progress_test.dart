import 'package:flutter_test/flutter_test.dart';
import 'package:training_app/features/learning/domain/models/assignment_detail.dart';

void main() {
  test(
    'parses authoritative ranges, decimals and optional session context',
    () {
      final progress = LessonProgress.fromJson({
        'resume_position': '10.123',
        'watched_seconds': '12.123',
        'progress_percent': '12.123',
        'completed': false,
        'watched_ranges': [
          [0, 10.123],
          [20, 22],
        ],
        'session_id': 7,
      });
      expect(progress.resumePosition, 10.123);
      expect(progress.watchedSeconds, 12.123);
      expect(progress.progressPercent, 12.123);
      expect(progress.watchedRanges, [
        [0.0, 10.123],
        [20.0, 22.0],
      ]);
      expect(progress.sessionId, 7);
      expect(progress.completed, isFalse);
      expect(
        () => progress.watchedRanges.add([30, 31]),
        throwsUnsupportedError,
      );
      expect(() => progress.watchedRanges[0][1] = 99, throwsUnsupportedError);
    },
  );

  test('legacy text progress and absent session fields remain supported', () {
    final progress = LessonProgress.fromJson({'completed': true});
    expect(progress.completed, isTrue);
    expect(progress.watchedRanges, isEmpty);
    expect(progress.sessionId, isNull);
    expect(progress.watchedSeconds, 0);
  });

  test('malformed numbers, ranges and session IDs fail closed', () {
    for (final data in <Map<String, dynamic>>[
      {'resume_position': double.nan},
      {'watched_seconds': -1},
      {'progress_percent': 101},
      {'session_id': '7'},
      {'session_id': 0},
      {
        'watched_ranges': [
          [0],
        ],
      },
      {
        'watched_ranges': [
          [2, 1],
        ],
      },
      {
        'watched_ranges': [
          [0, 3],
          [2, 4],
        ],
      },
      {
        'watched_ranges': [
          [0, double.infinity],
        ],
      },
    ]) {
      expect(() => LessonProgress.fromJson(data), throwsFormatException);
    }
  });
}
