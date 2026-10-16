import 'package:flutter_test/flutter_test.dart';
import 'package:training_app/features/assessments/domain/models/assessment.dart';

import '../../assessment_fixtures.dart';

void main() {
  test(
    'overview parses server eligibility, blocking reason, limits and history',
    () {
      final catalog = AssignmentAssessments.fromJson(catalogJson());
      expect((catalog.assignmentId, catalog.trainingVersionId), (1, 3));
      final assessment = catalog.assessments.single;
      expect(assessment.kind, AssessmentKind.quiz);
      expect(
        (assessment.moduleId, assessment.sequence, assessment.isRequired),
        (4, 1, true),
      );
      expect(assessment.passPercentage, '80.00');
      expect(assessment.eligibility.canResume, isTrue);
      expect(assessment.eligibility.canStart, isFalse);
      expect(assessment.eligibility.blockingReason, contains('in progress'));
      expect(
        (
          assessment.maxAttempts,
          assessment.attemptsUsed,
          assessment.attemptsRemaining,
        ),
        (3, 1, 2),
      );
      expect(assessment.attempts.single.id, assessment.ongoingAttemptId);
    },
  );

  test('final assessment and empty catalog support nullable fields', () {
    final json = catalogJson();
    final item = (json['assessments'] as List).single as Map<String, dynamic>;
    item.addAll({
      'kind': 'FINAL',
      'module_id': null,
      'time_limit_minutes': null,
      'ongoing_attempt_id': null,
      'blocking_reason': null,
      'attempts': [],
    });
    final assessment = AssignmentAssessments.fromJson(json).assessments.single;
    expect(assessment.kind, AssessmentKind.finalAssessment);
    expect(assessment.moduleId, isNull);
    expect(assessment.timeLimitMinutes, isNull);
    expect(assessment.eligibility.blockingReason, isNull);
    json['assessments'] = [];
    expect(AssignmentAssessments.fromJson(json).assessments, isEmpty);
  });

  test('ongoing questions expose IDs and options without local grading or saved answers', () {
    final value = attempt();
    expect(value.summary.passed, isNull);
    expect(value.summary.scorePoints, isNull);
    expect(value.answers, isEmpty);
    final question = value.questions.single;
    expect(
      (question.id, question.type, question.points),
      (11, AssessmentQuestionType.singleChoice, '2.00'),
    );
    expect(question.options.map((item) => item.id), [21, 22]);
    final json = attemptJson();
    (json['questions'] as List).single['type'] = 'TRUE_FALSE';
    expect(
      AssessmentAttempt.fromJson(json).questions.single.type,
      AssessmentQuestionType.trueFalse,
    );
  });

  test('persisted result preserves Decimal strings, review and assignment/certificate references', () {
    final result = attempt(status: 'SUBMITTED');
    expect(result.summary.isClosed, isTrue);
    expect(
      (result.summary.scorePoints, result.summary.maximumPoints),
      ('2.00', '2.00'),
    );
    expect(result.summary.passed, isTrue);
    expect((result.assignmentStatus, result.certificateId), ('COMPLETED', 8));
    expect(result.questions, isEmpty);
    expect(result.answers.single.selectedOptionText, 'Yes');
    final expired = attempt(status: 'EXPIRED', passed: false);
    expect(expired.summary.status, AttemptStatus.expired);
    expect(expired.answers.single.selectedOptionId, isNull);
    expect(expired.summary.passed, isFalse);
  });

  test('deadline countdown cannot expire or grade an attempt', () {
    final summary = attempt().summary;
    expect(
      summary.remainingAt(DateTime.utc(2040, 1, 1, 10, 0, 30)),
      const Duration(seconds: 30),
    );
    expect(summary.remainingAt(DateTime.utc(2040, 1, 1, 10, 2)), Duration.zero);
    expect(summary.status, AttemptStatus.inProgress);
    expect(summary.passed, isNull);
    final json = summaryJson()..['deadline_at'] = null;
    expect(
      AssessmentAttemptSummary.fromJson(json).remainingAt(DateTime.now()),
      isNull,
    );
  });

  test('abandoned history preserves nullable result without adding abandonment behavior', () {
    final json = summaryJson(status: 'ABANDONED')
      ..addAll({'score_points': null, 'passed': null});
    final summary = AssessmentAttemptSummary.fromJson(json);
    expect(summary.status, AttemptStatus.abandoned);
    expect(summary.passed, isNull);
  });

  test('model collections cannot be mutated', () {
    final value = attempt();
    expect(() => value.questions.clear(), throwsUnsupportedError);
    expect(
      () => value.questions.single.options.clear(),
      throwsUnsupportedError,
    );
    expect(
      () => AssignmentAssessments.fromJson(catalogJson()).assessments.clear(),
      throwsUnsupportedError,
    );
  });

  test(
    'malformed IDs, types, timestamps, decimals and collections fail closed',
    () {
      for (final field in <String, dynamic>{
        'id': 0,
        'assignment_id': '1',
        'status': 'UNKNOWN',
        'started_at': 'bad',
        'passed': 'true',
        'maximum_points': 'NaN',
        'questions': {},
      }.entries) {
        final json = attemptJson()..[field.key] = field.value;
        expect(
          () => AssessmentAttempt.fromJson(json),
          throwsFormatException,
          reason: field.key,
        );
      }
      final json = attemptJson();
      (json['questions'] as List).single['type'] = 'ESSAY';
      expect(() => AssessmentAttempt.fromJson(json), throwsFormatException);
    },
  );
}
