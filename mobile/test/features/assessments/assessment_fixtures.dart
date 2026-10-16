import 'package:training_app/features/assessments/domain/models/assessment.dart';

Map<String, dynamic> summaryJson({
  int id = 7,
  String status = 'IN_PROGRESS',
  bool passed = true,
}) => {
  'id': id,
  'attempt_number': 1,
  'status': status,
  'started_at': '2040-01-01T10:00:00Z',
  'deadline_at': '2040-01-01T10:01:00Z',
  'submitted_at': status == 'IN_PROGRESS' ? null : '2040-01-01T10:00:30Z',
  'score_points': status == 'IN_PROGRESS'
      ? null
      : passed
      ? '2.00'
      : '0.00',
  'maximum_points': '2.00',
  'pass_percentage_snapshot': '80.00',
  'passed': status == 'IN_PROGRESS' ? null : passed,
};

Map<String, dynamic> attemptJson({
  int id = 7,
  int assignmentId = 1,
  String status = 'IN_PROGRESS',
  bool passed = true,
}) => {
  ...summaryJson(id: id, status: status, passed: passed),
  'assignment_id': assignmentId,
  'assessment_id': 2,
  'training_version_id': 3,
  'assignment_status': status == 'IN_PROGRESS' ? 'IN_PROGRESS' : 'COMPLETED',
  'certificate_id': status == 'IN_PROGRESS' ? null : 8,
  'questions': status == 'IN_PROGRESS'
      ? [
          {
            'id': 11,
            'position': 1,
            'points': '2.00',
            'prompt': 'Wear PPE?',
            'type': 'SINGLE_CHOICE',
            'options': [
              {'id': 21, 'position': 1, 'text': 'Yes'},
              {'id': 22, 'position': 2, 'text': 'No'},
            ],
          },
        ]
      : [],
  'answers': status == 'IN_PROGRESS'
      ? []
      : [
          {
            'assessment_question_id': 11,
            'presented_position': 1,
            'prompt': 'Wear PPE?',
            'selected_option_id': passed ? 21 : null,
            'selected_option_text': passed ? 'Yes' : null,
            'points_possible': '2.00',
            'points_awarded': passed ? '2.00' : '0.00',
          },
        ],
};

Map<String, dynamic> catalogJson({int assignmentId = 1}) => {
  'assignment_id': assignmentId,
  'training_version_id': 3,
  'assessments': [
    <String, dynamic>{
      'id': 2,
      'kind': 'QUIZ',
      'module_id': 4,
      'title': 'Module quiz',
      'sequence': 1,
      'is_required': true,
      'pass_percentage': '80.00',
      'time_limit_minutes': 1,
      'max_attempts': 3,
      'attempts_used': 1,
      'attempts_remaining': 2,
      'ongoing_attempt_id': 7,
      'passed': false,
      'completed': false,
      'can_start': false,
      'can_resume': true,
      'blocking_reason': 'An attempt is already in progress.',
      'attempts': [summaryJson()],
    },
  ],
};

AssessmentAttempt attempt({
  int id = 7,
  int assignmentId = 1,
  String status = 'IN_PROGRESS',
  bool passed = true,
}) => AssessmentAttempt.fromJson(
  attemptJson(
    id: id,
    assignmentId: assignmentId,
    status: status,
    passed: passed,
  ),
);
