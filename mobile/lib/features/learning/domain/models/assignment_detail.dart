class LessonProgress {
  final double resumePosition;
  final double watchedSeconds;
  final double progressPercent;
  final bool completed;
  final DateTime? completedAt;

  LessonProgress({
    required this.resumePosition,
    required this.watchedSeconds,
    required this.progressPercent,
    required this.completed,
    this.completedAt,
  });

  factory LessonProgress.fromJson(Map<String, dynamic> json) {
    return LessonProgress(
      resumePosition: double.tryParse(json['resume_position']?.toString() ?? '') ?? 0.0,
      watchedSeconds: double.tryParse(json['watched_seconds']?.toString() ?? '') ?? 0.0,
      progressPercent: double.tryParse(json['progress_percent']?.toString() ?? '') ?? 0.0,
      completed: json['completed'] as bool? ?? false,
      completedAt: json['completed_at'] != null ? DateTime.tryParse(json['completed_at']) : null,
    );
  }
}

class LessonLearning {
  final int id;
  final String title;
  final int position;
  final String type;
  final bool isRequired;
  final String body;
  final int? videoDurationSeconds;
  final double? minimumWatchPercent;
  final LessonProgress progress;

  LessonLearning({
    required this.id,
    required this.title,
    required this.position,
    required this.type,
    required this.isRequired,
    required this.body,
    this.videoDurationSeconds,
    this.minimumWatchPercent,
    required this.progress,
  });

  factory LessonLearning.fromJson(Map<String, dynamic> json) {
    return LessonLearning(
      id: json['id'] as int? ?? 0,
      title: json['title'] as String? ?? '',
      position: json['position'] as int? ?? 0,
      type: json['type'] as String? ?? '',
      isRequired: json['is_required'] as bool? ?? false,
      body: json['body'] as String? ?? '',
      videoDurationSeconds: json['video_duration_seconds'] as int?,
      minimumWatchPercent: json['minimum_watch_percent'] != null ? double.tryParse(json['minimum_watch_percent'].toString()) : null,
      progress: LessonProgress.fromJson(json['progress'] ?? {}),
    );
  }
}

class ModuleLearning {
  final int id;
  final String title;
  final String description;
  final int position;
  final List<LessonLearning> lessons;

  ModuleLearning({
    required this.id,
    required this.title,
    required this.description,
    required this.position,
    required this.lessons,
  });

  factory ModuleLearning.fromJson(Map<String, dynamic> json) {
    return ModuleLearning(
      id: json['id'] as int? ?? 0,
      title: json['title'] as String? ?? '',
      description: json['description'] as String? ?? '',
      position: json['position'] as int? ?? 0,
      lessons: (json['lessons'] as List<dynamic>?)
              ?.map((e) => LessonLearning.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
    );
  }
}

class AssignmentDetail {
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
  final List<ModuleLearning> modules;

  AssignmentDetail({
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
    required this.modules,
  });

  factory AssignmentDetail.fromJson(Map<String, dynamic> json) {
    return AssignmentDetail(
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
      modules: (json['modules'] as List<dynamic>?)
              ?.map((e) => ModuleLearning.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
    );
  }
  
  int get requiredLessonsCompleted {
    return modules.expand((m) => m.lessons).where((l) => l.isRequired && l.progress.completed).length;
  }
  
  int get requiredLessonsTotal {
    return modules.expand((m) => m.lessons).where((l) => l.isRequired).length;
  }
}

