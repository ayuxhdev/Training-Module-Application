import 'package:flutter_test/flutter_test.dart';
import 'package:training_app/features/learning/domain/models/assignment.dart';

void main() {
  group('Assignment Model', () {
    test('fromJson creates a valid Assignment object from JSON', () {
      final json = {
        'id': 1,
        'training_id': 101,
        'training_title': 'Safety Training',
        'version_number': 2,
        'status': 'IN_PROGRESS',
        'assigned_at': '2023-01-01T10:00:00Z',
        'due_at': '2023-12-31T23:59:59Z',
        'started_at': '2023-01-02T10:00:00Z',
        'is_overdue': false,
        'progress_summary': {
          'required_lessons_completed': 3,
          'required_lessons_total': 5,
        }
      };

      final assignment = Assignment.fromJson(json);

      expect(assignment.id, 1);
      expect(assignment.trainingId, 101);
      expect(assignment.trainingTitle, 'Safety Training');
      expect(assignment.versionNumber, 2);
      expect(assignment.status, 'IN_PROGRESS');
      expect(assignment.assignedAt, isNotNull);
      expect(assignment.dueAt, isNotNull);
      expect(assignment.startedAt, isNotNull);
      expect(assignment.completedAt, isNull);
      expect(assignment.isOverdue, false);
      expect(assignment.progressSummary.requiredLessonsCompleted, 3);
      expect(assignment.progressSummary.requiredLessonsTotal, 5);
    });

    test('fromJson handles missing fields gracefully', () {
      final json = <String, dynamic>{};

      final assignment = Assignment.fromJson(json);

      expect(assignment.id, 0);
      expect(assignment.trainingId, 0);
      expect(assignment.trainingTitle, '');
      expect(assignment.versionNumber, 1);
      expect(assignment.status, '');
      expect(assignment.assignedAt, isNull);
      expect(assignment.dueAt, isNull);
      expect(assignment.isOverdue, false);
      expect(assignment.progressSummary.requiredLessonsCompleted, 0);
      expect(assignment.progressSummary.requiredLessonsTotal, 0);
    });
  });
}

