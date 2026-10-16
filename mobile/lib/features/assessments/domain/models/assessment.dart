enum AssessmentKind { quiz, finalAssessment }

enum AttemptStatus { inProgress, submitted, expired, abandoned }

enum AssessmentQuestionType { singleChoice, trueFalse }

int _integer(Map<String, dynamic> json, String key, {int minimum = 1}) {
  final value = json[key];
  if (value is! int || value < minimum) {
    throw FormatException('Invalid $key.');
  }
  return value;
}

int? _optionalId(Map<String, dynamic> json, String key) =>
    json[key] == null ? null : _integer(json, key);

String _text(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! String) throw FormatException('Invalid $key.');
  return value;
}

bool _flag(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! bool) throw FormatException('Invalid $key.');
  return value;
}

String _decimal(Map<String, dynamic> json, String key) {
  final value = _text(json, key);
  if (!RegExp(r'^\d+(?:\.\d+)?$').hasMatch(value) ||
      double.tryParse(value)?.isFinite != true) {
    throw FormatException('Invalid $key.');
  }
  return value; // Preserve the exact server Decimal; never calculate a grade.
}

DateTime _date(Map<String, dynamic> json, String key) {
  final value = DateTime.tryParse(_text(json, key));
  if (value == null) throw FormatException('Invalid $key.');
  return value;
}

DateTime? _optionalDate(Map<String, dynamic> json, String key) =>
    json[key] == null ? null : _date(json, key);

List<T> _list<T>(
  Map<String, dynamic> json,
  String key,
  T Function(Map<String, dynamic>) parse,
) {
  final value = json[key];
  if (value is! List || value.any((item) => item is! Map<String, dynamic>)) {
    throw FormatException('Invalid $key.');
  }
  return List.unmodifiable(
    value.map((item) => parse(item as Map<String, dynamic>)),
  );
}

class AssessmentEligibility {
  final bool canStart;
  final bool canResume;
  final String? blockingReason;

  const AssessmentEligibility({
    required this.canStart,
    required this.canResume,
    required this.blockingReason,
  });

  factory AssessmentEligibility.fromJson(Map<String, dynamic> json) =>
      AssessmentEligibility(
        canStart: _flag(json, 'can_start'),
        canResume: _flag(json, 'can_resume'),
        blockingReason: json['blocking_reason'] == null
            ? null
            : _text(json, 'blocking_reason'),
      );
}

class AssessmentAttemptSummary {
  final int id;
  final int attemptNumber;
  final AttemptStatus status;
  final DateTime startedAt;
  final DateTime? deadlineAt;
  final DateTime? submittedAt;
  final String? scorePoints;
  final String maximumPoints;
  final String passPercentageSnapshot;
  final bool? passed;

  const AssessmentAttemptSummary({
    required this.id,
    required this.attemptNumber,
    required this.status,
    required this.startedAt,
    required this.deadlineAt,
    required this.submittedAt,
    required this.scorePoints,
    required this.maximumPoints,
    required this.passPercentageSnapshot,
    required this.passed,
  });

  bool get isClosed => status != AttemptStatus.inProgress;

  /// Display-only countdown. Reaching zero never closes or grades an attempt.
  Duration? remainingAt(DateTime now) {
    if (deadlineAt == null || isClosed) return null;
    final remaining = deadlineAt!.difference(now);
    return remaining.isNegative ? Duration.zero : remaining;
  }

  factory AssessmentAttemptSummary.fromJson(Map<String, dynamic> json) {
    final passed = json['passed'];
    if (passed != null && passed is! bool) {
      throw const FormatException('Invalid passed.');
    }
    return AssessmentAttemptSummary(
      id: _integer(json, 'id'),
      attemptNumber: _integer(json, 'attempt_number'),
      status: switch (json['status']) {
        'IN_PROGRESS' => AttemptStatus.inProgress,
        'SUBMITTED' => AttemptStatus.submitted,
        'EXPIRED' => AttemptStatus.expired,
        'ABANDONED' => AttemptStatus.abandoned,
        _ => throw const FormatException('Invalid attempt status.'),
      },
      startedAt: _date(json, 'started_at'),
      deadlineAt: _optionalDate(json, 'deadline_at'),
      submittedAt: _optionalDate(json, 'submitted_at'),
      scorePoints: json['score_points'] == null
          ? null
          : _decimal(json, 'score_points'),
      maximumPoints: _decimal(json, 'maximum_points'),
      passPercentageSnapshot: _decimal(json, 'pass_percentage_snapshot'),
      passed: passed as bool?,
    );
  }
}

class AssessmentOverview {
  final int id;
  final AssessmentKind kind;
  final int? moduleId;
  final String title;
  final int sequence;
  final bool isRequired;
  final String passPercentage;
  final int? timeLimitMinutes;
  final int maxAttempts;
  final int attemptsUsed;
  final int attemptsRemaining;
  final int? ongoingAttemptId;
  final bool passed;
  final bool completed;
  final AssessmentEligibility eligibility;
  final List<AssessmentAttemptSummary> attempts;

  AssessmentOverview.fromJson(Map<String, dynamic> json)
    : id = _integer(json, 'id'),
      kind = switch (json['kind']) {
        'QUIZ' => AssessmentKind.quiz,
        'FINAL' => AssessmentKind.finalAssessment,
        _ => throw const FormatException('Invalid assessment kind.'),
      },
      moduleId = _optionalId(json, 'module_id'),
      title = _text(json, 'title'),
      sequence = _integer(json, 'sequence'),
      isRequired = _flag(json, 'is_required'),
      passPercentage = _decimal(json, 'pass_percentage'),
      timeLimitMinutes = _optionalId(json, 'time_limit_minutes'),
      maxAttempts = _integer(json, 'max_attempts'),
      attemptsUsed = _integer(json, 'attempts_used', minimum: 0),
      attemptsRemaining = _integer(json, 'attempts_remaining', minimum: 0),
      ongoingAttemptId = _optionalId(json, 'ongoing_attempt_id'),
      passed = _flag(json, 'passed'),
      completed = _flag(json, 'completed'),
      eligibility = AssessmentEligibility.fromJson(json),
      attempts = _list(json, 'attempts', AssessmentAttemptSummary.fromJson);
}

class AssignmentAssessments {
  final int assignmentId;
  final int trainingVersionId;
  final List<AssessmentOverview> assessments;

  AssignmentAssessments.fromJson(Map<String, dynamic> json)
    : assignmentId = _integer(json, 'assignment_id'),
      trainingVersionId = _integer(json, 'training_version_id'),
      assessments = _list(json, 'assessments', AssessmentOverview.fromJson);
}

class AssessmentOption {
  final int id;
  final String text;
  final int position;

  AssessmentOption.fromJson(Map<String, dynamic> json)
    : id = _integer(json, 'id'),
      text = _text(json, 'text'),
      position = _integer(json, 'position');
}

class AssessmentQuestion {
  final int id;
  final int position;
  final String points;
  final String prompt;
  final AssessmentQuestionType type;
  final List<AssessmentOption> options;

  AssessmentQuestion.fromJson(Map<String, dynamic> json)
    : id = _integer(json, 'id'),
      position = _integer(json, 'position'),
      points = _decimal(json, 'points'),
      prompt = _text(json, 'prompt'),
      type = switch (json['type']) {
        'SINGLE_CHOICE' => AssessmentQuestionType.singleChoice,
        'TRUE_FALSE' => AssessmentQuestionType.trueFalse,
        _ => throw const FormatException('Unsupported question type.'),
      },
      options = _list(json, 'options', AssessmentOption.fromJson);
}

class AssessmentRecordedAnswer {
  final int assessmentQuestionId;
  final int presentedPosition;
  final String prompt;
  final int? selectedOptionId;
  final String? selectedOptionText;
  final String pointsPossible;
  final String? pointsAwarded;

  AssessmentRecordedAnswer.fromJson(Map<String, dynamic> json)
    : assessmentQuestionId = _integer(json, 'assessment_question_id'),
      presentedPosition = _integer(json, 'presented_position'),
      prompt = _text(json, 'prompt'),
      selectedOptionId = _optionalId(json, 'selected_option_id'),
      selectedOptionText = json['selected_option_text'] == null
          ? null
          : _text(json, 'selected_option_text'),
      pointsPossible = _decimal(json, 'points_possible'),
      pointsAwarded = json['points_awarded'] == null
          ? null
          : _decimal(json, 'points_awarded');
}

class AssessmentAttempt {
  final AssessmentAttemptSummary summary;
  final int assignmentId;
  final int assessmentId;
  final int trainingVersionId;
  final String assignmentStatus;
  final int? certificateId;
  final List<AssessmentQuestion> questions;
  final List<AssessmentRecordedAnswer> answers;

  AssessmentAttempt.fromJson(Map<String, dynamic> json)
    : summary = AssessmentAttemptSummary.fromJson(json),
      assignmentId = _integer(json, 'assignment_id'),
      assessmentId = _integer(json, 'assessment_id'),
      trainingVersionId = _integer(json, 'training_version_id'),
      assignmentStatus = _text(json, 'assignment_status'),
      certificateId = _optionalId(json, 'certificate_id'),
      questions = _list(json, 'questions', AssessmentQuestion.fromJson),
      answers = _list(json, 'answers', AssessmentRecordedAnswer.fromJson);
}
