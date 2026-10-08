import 'package:flutter_test/flutter_test.dart';
import 'package:training_app/features/learning/domain/models/assignment_detail.dart';

void main() {
  group('AssignmentDetail Model', () {
    test('fromJson creates a valid AssignmentDetail object from JSON', () {
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
        'modules': [
          {
            'id': 10,
            'title': 'Module 1',
            'description': 'Intro',
            'position': 1,
            'lessons': [
              {
                'id': 100,
                'title': 'Lesson 1',
                'position': 1,
                'type': 'VIDEO',
                'is_required': true,
                'body': '',
                'video_duration_seconds': 120,
                'minimum_watch_percent': 80.0,
                'progress': {
                  'resume_position': 10.0,
                  'watched_seconds': 15.0,
                  'progress_percent': 12.5,
                  'completed': false,
                }
              },
              {
                'id': 101,
                'title': 'Lesson 2',
                'position': 2,
                'type': 'TEXT',
                'is_required': true,
                'body': 'Read this.',
                'progress': {
                  'completed': true,
                  'completed_at': '2023-01-02T10:05:00Z',
                }
              }
            ]
          }
        ]
      };

      final detail = AssignmentDetail.fromJson(json);

      expect(detail.id, 1);
      expect(detail.trainingId, 101);
      expect(detail.trainingTitle, 'Safety Training');
      expect(detail.status, 'IN_PROGRESS');
      expect(detail.assignedAt, isNotNull);
      expect(detail.dueAt, isNotNull);
      expect(detail.startedAt, isNotNull);
      expect(detail.isOverdue, false);
      expect(detail.modules.length, 1);
      expect(detail.modules[0].title, 'Module 1');
      expect(detail.modules[0].lessons.length, 2);
      expect(detail.modules[0].lessons[0].type, 'VIDEO');
      expect(detail.modules[0].lessons[0].progress.resumePosition, 10.0);
      expect(detail.modules[0].lessons[1].progress.completed, true);
      expect(detail.modules[0].lessons[1].progress.completedAt, isNotNull);
      
      expect(detail.requiredLessonsCompleted, 1);
      expect(detail.requiredLessonsTotal, 2);
    });

    test('fromJson handles missing fields gracefully', () {
      final json = <String, dynamic>{};
      final detail = AssignmentDetail.fromJson(json);

      expect(detail.id, 0);
      expect(detail.trainingTitle, '');
      expect(detail.modules.isEmpty, true);
      expect(detail.requiredLessonsTotal, 0);
    });

    test('fromJson safely handles string DecimalField JSON input', () {
      final json = {
        'id': 1,
        'modules': [
          {
            'lessons': [
              {
                'minimum_watch_percent': '85.50',
                'progress': {
                  'resume_position': '10.5',
                  'watched_seconds': '15.00',
                  'progress_percent': '12.50',
                }
              }
            ]
          }
        ]
      };

      final detail = AssignmentDetail.fromJson(json);
      final lesson = detail.modules[0].lessons[0];
      
      expect(lesson.minimumWatchPercent, 85.50);
      expect(lesson.progress.resumePosition, 10.5);
      expect(lesson.progress.watchedSeconds, 15.0);
      expect(lesson.progress.progressPercent, 12.5);
    });
  });
}

