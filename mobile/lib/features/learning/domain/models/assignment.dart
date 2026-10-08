class ProgressSummary {
  final int requiredLessonsCompleted;
  final int requiredLessonsTotal;

  ProgressSummary({
    required this.requiredLessonsCompleted,
    required this.requiredLessonsTotal,
  });

  factory ProgressSummary.fromJson(Map<String, dynamic> json) {
    return ProgressSummary(
      requiredLessonsCompleted: json['required_lessons_completed'] as int? ?? 0,
      requiredLessonsTotal: json['required_lessons_total'] as int? ?? 0,
    );
  }
}

class Assignment {
  final int id;
  final int trainingId;
  final String trainingTitle;
  final int versionNumber;
  final String status;
  final DateTime? assignedAt;
  final DateTime? dueAt;
  final DateTime? startedAt;
  final DateTime? completedAt;
  final bool isOverdue;
  final ProgressSummary progressSummary;

  Assignment({
    required this.id,
    required this.trainingId,
    required this.trainingTitle,
    required this.versionNumber,
    required this.status,
    this.assignedAt,
    this.dueAt,
    this.startedAt,
    this.completedAt,
    required this.isOverdue,
    required this.progressSummary,
  });

  factory Assignment.fromJson(Map<String, dynamic> json) {
    return Assignment(
      id: json['id'] as int? ?? 0,
      trainingId: json['training_id'] as int? ?? 0,
      trainingTitle: json['training_title'] as String? ?? '',
      versionNumber: json['version_number'] as int? ?? 1,
      status: json['status'] as String? ?? '',
      assignedAt: json['assigned_at'] != null ? DateTime.tryParse(json['assigned_at']) : null,
      dueAt: json['due_at'] != null ? DateTime.tryParse(json['due_at']) : null,
      startedAt: json['started_at'] != null ? DateTime.tryParse(json['started_at']) : null,
      completedAt: json['completed_at'] != null ? DateTime.tryParse(json['completed_at']) : null,
      isOverdue: json['is_overdue'] as bool? ?? false,
      progressSummary: ProgressSummary.fromJson(json['progress_summary'] ?? {}),
    );
  }
}

