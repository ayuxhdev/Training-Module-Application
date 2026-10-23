class LessonProgress {
  final double resumePosition;
  final double watchedSeconds;
  final double progressPercent;
  final bool completed;
  final DateTime? completedAt;
  final List<List<double>> watchedRanges;
  final int? sessionId;

  LessonProgress({
    required this.resumePosition,
    required this.watchedSeconds,
    required this.progressPercent,
    required this.completed,
    this.completedAt,
    List<List<double>> watchedRanges = const [],
    this.sessionId,
  }) : watchedRanges = List.unmodifiable(
         watchedRanges.map((range) => List<double>.unmodifiable(range)),
       );

  factory LessonProgress.fromJson(Map<String, dynamic> json) {
    double number(dynamic value) {
      final result = double.tryParse(value?.toString() ?? '0');
      if (result == null || !result.isFinite || result < 0) {
        throw const FormatException('Invalid lesson progress number.');
      }
      return result;
    }

    final ranges = <List<double>>[];
    for (final range in json['watched_ranges'] as List? ?? const []) {
      if (range is! List || range.length != 2) {
        throw const FormatException('Invalid watched range.');
      }
      final start = number(range[0]);
      final end = number(range[1]);
      if (end <= start || (ranges.isNotEmpty && start <= ranges.last[1])) {
        throw const FormatException(
          'Watched ranges must be ordered and merged.',
        );
      }
      ranges.add([start, end]);
    }
    final sessionId = json['session_id'];
    if (sessionId != null && (sessionId is! int || sessionId <= 0)) {
      throw const FormatException('Invalid playback session ID.');
    }
    final percent = number(json['progress_percent']);
    if (percent > 100) {
      throw const FormatException('Invalid progress percentage.');
    }
    return LessonProgress(
      resumePosition: number(json['resume_position']),
      watchedSeconds: number(json['watched_seconds']),
      progressPercent: percent,
      completed: json['completed'] as bool? ?? false,
      completedAt: json['completed_at'] != null
          ? DateTime.tryParse(json['completed_at'])
          : null,
      watchedRanges: ranges,
      sessionId: sessionId,
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
  final String playbackMode;

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
    this.playbackMode = 'tracked',
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
      minimumWatchPercent: json['minimum_watch_percent'] != null
          ? double.tryParse(json['minimum_watch_percent'].toString())
          : null,
      progress: LessonProgress.fromJson(json['progress'] ?? {}),
      playbackMode: !json.containsKey('playback_mode')
          ? 'tracked'
          : ['tracked', 'read_only_replay'].contains(json['playback_mode'])
          ? json['playback_mode'] as String
          : 'unavailable',
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
      lessons:
          (json['lessons'] as List<dynamic>?)
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
      assignedAt: json['assigned_at'] != null
          ? DateTime.tryParse(json['assigned_at'])
          : null,
      dueAt: json['due_at'] != null ? DateTime.tryParse(json['due_at']) : null,
      startedAt: json['started_at'] != null
          ? DateTime.tryParse(json['started_at'])
          : null,
      completedAt: json['completed_at'] != null
          ? DateTime.tryParse(json['completed_at'])
          : null,
      isOverdue: json['is_overdue'] as bool? ?? false,
      modules:
          (json['modules'] as List<dynamic>?)
              ?.map((e) => ModuleLearning.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
    );
  }

  int get requiredLessonsCompleted {
    return modules
        .expand((m) => m.lessons)
        .where((l) => l.isRequired && l.progress.completed)
        .length;
  }

  int get requiredLessonsTotal {
    return modules.expand((m) => m.lessons).where((l) => l.isRequired).length;
  }
}
