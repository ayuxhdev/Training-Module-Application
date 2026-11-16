import 'package:training_app/features/learning/domain/models/assignment.dart';

enum ReferenceKind { departments, jobRoles }

extension ReferenceKindLabels on ReferenceKind {
  String get singular =>
      this == ReferenceKind.departments ? 'department' : 'job role';
  String get path =>
      this == ReferenceKind.departments ? 'departments' : 'job-roles';
  String get title =>
      this == ReferenceKind.departments ? 'Departments' : 'Job roles';
  String get permission => this == ReferenceKind.departments
      ? 'organization.view_department'
      : 'organization.view_jobrole';
  String get addPermission => this == ReferenceKind.departments
      ? 'organization.add_department'
      : 'organization.add_jobrole';
  String get changePermission => this == ReferenceKind.departments
      ? 'organization.change_department'
      : 'organization.change_jobrole';
}

class OrganizationReference {
  final int id;
  final String code, name, description;
  final bool isActive;

  const OrganizationReference({
    required this.id,
    required this.code,
    required this.name,
    this.description = '',
    this.isActive = true,
  });

  factory OrganizationReference.fromJson(Map<String, dynamic> json) =>
      OrganizationReference(
        id: json['id'] as int,
        code: json['code'] as String,
        name: json['name'] as String,
        description: json['description'] as String? ?? '',
        isActive: json['is_active'] as bool? ?? true,
      );
}

class DirectoryEmployee {
  final int id;
  final String employeeCode, displayName;
  final OrganizationReference department, jobRole;
  final String? reportingManager;
  final int? reportingManagerId;
  final bool isActive;
  final String? dateJoined, loginStatus;

  const DirectoryEmployee({
    required this.id,
    required this.employeeCode,
    required this.displayName,
    required this.department,
    required this.jobRole,
    required this.isActive,
    this.reportingManager,
    this.reportingManagerId,
    this.dateJoined,
    this.loginStatus,
  });

  factory DirectoryEmployee.fromJson(
    Map<String, dynamic> json,
  ) => DirectoryEmployee(
    id: json['id'] as int,
    employeeCode: json['employee_code'] as String,
    displayName: json['display_name'] as String,
    department: OrganizationReference.fromJson(
      json['department'] as Map<String, dynamic>,
    ),
    jobRole: OrganizationReference.fromJson(
      json['job_role'] as Map<String, dynamic>,
    ),
    reportingManager: json['reporting_manager'] as String?,
    reportingManagerId: json['reporting_manager_id'] as int?,
    isActive: json['is_active'] as bool,
    // Date-only employment dates must not be shifted through a device timezone.
    dateJoined: json['date_joined'] as String?,
    loginStatus: json['login_status'] as String?,
  );
}

class EmployeeEditChoices {
  final List<OrganizationReference> departments;
  final List<OrganizationReference> jobRoles;
  final List<DirectoryEmployee> reportingManagers;

  EmployeeEditChoices({
    required List<OrganizationReference> departments,
    required List<OrganizationReference> jobRoles,
    required List<DirectoryEmployee> reportingManagers,
  }) : departments = List.unmodifiable(departments),
       jobRoles = List.unmodifiable(jobRoles),
       reportingManagers = List.unmodifiable(reportingManagers);
}

class ManagementPage<T> {
  final List<T> items;
  final int count;
  final bool hasMore;

  ManagementPage({
    required List<T> items,
    required this.count,
    required this.hasMore,
  }) : items = List.unmodifiable(items);

  factory ManagementPage.fromJson(
    Map<String, dynamic> json,
    T Function(Map<String, dynamic>) parse,
  ) {
    final count = json['count'] as int;
    final next = json['next'];
    final items = (json['results'] as List)
        .map((item) => parse(item as Map<String, dynamic>))
        .toList();
    if (count < 0 || (next != null && (next is! String || items.isEmpty))) {
      throw const FormatException('Invalid management pagination.');
    }
    return ManagementPage(items: items, count: count, hasMore: next != null);
  }
}

class ManagementMetrics {
  final int total,
      assigned,
      inProgress,
      completed,
      cancelled,
      overdue,
      eligible;
  final double completionPercent;

  const ManagementMetrics({
    required this.total,
    required this.assigned,
    required this.inProgress,
    required this.completed,
    required this.cancelled,
    required this.overdue,
    required this.eligible,
    required this.completionPercent,
  });

  factory ManagementMetrics.fromJson(Map<String, dynamic> json) =>
      ManagementMetrics(
        total: json['total'] as int,
        assigned: json['assigned'] as int,
        inProgress: json['in_progress'] as int,
        completed: json['completed'] as int,
        cancelled: json['cancelled'] as int,
        overdue: json['overdue'] as int,
        eligible: json['eligible'] as int,
        completionPercent: (json['completion_percent'] as num).toDouble(),
      );
}

class RecentFailure {
  final String assessmentTitle, employeeName, scorePoints, maximumPoints;
  final DateTime submittedAt;

  const RecentFailure({
    required this.assessmentTitle,
    required this.employeeName,
    required this.scorePoints,
    required this.maximumPoints,
    required this.submittedAt,
  });

  factory RecentFailure.fromJson(Map<String, dynamic> json) => RecentFailure(
    assessmentTitle: json['assessment_title'] as String,
    employeeName: json['employee_name'] as String,
    scorePoints: json['score_points'] as String,
    maximumPoints: json['maximum_points'] as String,
    submittedAt: DateTime.parse(json['submitted_at'] as String),
  );
}

class IncompleteEmployee {
  final int employeeId, incompleteCount, overdueCount;
  final String employeeName;

  const IncompleteEmployee({
    required this.employeeId,
    required this.employeeName,
    required this.incompleteCount,
    required this.overdueCount,
  });

  factory IncompleteEmployee.fromJson(Map<String, dynamic> json) =>
      IncompleteEmployee(
        employeeId: json['employee_id'] as int,
        employeeName: json['employee_name'] as String,
        incompleteCount: json['incomplete_assignment_count'] as int,
        overdueCount: json['overdue_assignment_count'] as int,
      );
}

class ManagementDashboard {
  final bool isCompany;
  final ManagementMetrics metrics;
  final Map<String, int> summary;
  final List<RecentFailure> recentFailures;
  final List<IncompleteEmployee> incompleteEmployees;

  ManagementDashboard({
    required this.isCompany,
    required this.metrics,
    required Map<String, int> summary,
    required List<RecentFailure> recentFailures,
    required List<IncompleteEmployee> incompleteEmployees,
  }) : summary = Map.unmodifiable(summary),
       recentFailures = List.unmodifiable(recentFailures),
       incompleteEmployees = List.unmodifiable(incompleteEmployees);

  factory ManagementDashboard.fromJson(Map<String, dynamic> json) {
    if (json['scope'] != 'company' && json['scope'] != 'team') {
      throw const FormatException('Invalid dashboard scope.');
    }
    return ManagementDashboard(
      isCompany: json['scope'] == 'company',
      metrics: ManagementMetrics.fromJson(
        json['metrics'] as Map<String, dynamic>,
      ),
      summary: (json['summary'] as Map<String, dynamic>).map(
        (key, value) => MapEntry(key, value as int),
      ),
      recentFailures: (json['recent_failures'] as List)
          .map((item) => RecentFailure.fromJson(item as Map<String, dynamic>))
          .toList(),
      incompleteEmployees: (json['incomplete_employees'] as List)
          .map(
            (item) => IncompleteEmployee.fromJson(item as Map<String, dynamic>),
          )
          .toList(),
    );
  }
}

class AssignableTrainingVersion {
  final int id;
  final int trainingId;
  final String trainingCode;
  final String trainingTitle;
  final int versionNumber;
  final String title;
  final String description;
  final String status;
  final String? publishedAt;

  const AssignableTrainingVersion({
    required this.id,
    required this.trainingId,
    required this.trainingCode,
    required this.trainingTitle,
    required this.versionNumber,
    required this.title,
    this.description = '',
    this.status = 'PUBLISHED',
    this.publishedAt,
  });

  factory AssignableTrainingVersion.fromJson(Map<String, dynamic> json) =>
      AssignableTrainingVersion(
        id: json['id'] as int,
        trainingId: (json['training_id'] ?? json['training']) as int,
        trainingCode: (json['training_code'] ?? '') as String,
        trainingTitle: (json['training_title'] ?? '') as String,
        versionNumber: json['version_number'] as int,
        title: (json['title'] ?? '') as String,
        description: (json['description'] ?? '') as String,
        status: (json['status'] ?? 'PUBLISHED') as String,
        publishedAt: json['published_at'] as String?,
      );
}

class CreatedAssignment {
  final int id;
  final int employeeId;
  final int trainingVersionId;
  final String status;
  final String source;
  final String assignedAt;
  final String? dueAt;

  const CreatedAssignment({
    required this.id,
    required this.employeeId,
    required this.trainingVersionId,
    required this.status,
    required this.source,
    required this.assignedAt,
    this.dueAt,
  });

  factory CreatedAssignment.fromJson(Map<String, dynamic> json) {
    final emp = json['employee'];
    final employeeId = emp is Map<String, dynamic>
        ? (emp['id'] as int)
        : (json['employee_id'] as int? ?? 0);
    final ver = json['training_version'];
    final trainingVersionId = ver is Map<String, dynamic>
        ? (ver['id'] as int)
        : (json['training_version_id'] as int? ?? 0);
    return CreatedAssignment(
      id: json['id'] as int,
      employeeId: employeeId,
      trainingVersionId: trainingVersionId,
      status: (json['status'] ?? 'ASSIGNED') as String,
      source: (json['source'] ?? 'MANUAL') as String,
      assignedAt: (json['assigned_at'] ?? '') as String,
      dueAt: json['due_at'] as String?,
    );
  }
}

class EmployeeAssignmentSummary {
  final int id;
  final String trainingTitle;
  final int versionNumber;
  final String status;
  final DateTime? assignedAt;
  final DateTime? dueAt;
  final DateTime? startedAt;
  final DateTime? completedAt;
  final bool isOverdue;
  final ProgressSummary? progressSummary;
  final int? trainingId;
  final int? trainingVersionId;

  const EmployeeAssignmentSummary({
    required this.id,
    required this.trainingTitle,
    required this.versionNumber,
    required this.status,
    this.assignedAt,
    this.dueAt,
    this.startedAt,
    this.completedAt,
    this.isOverdue = false,
    this.progressSummary,
    this.trainingId,
    this.trainingVersionId,
  });

  factory EmployeeAssignmentSummary.fromJson(Map<String, dynamic> json) {
    final id = (json['id'] as num?)?.toInt() ?? 0;
    final trainingId = (json['training_id'] as num?)?.toInt();
    final trainingVersionId = (json['training_version_id'] as num?)?.toInt();
    final trainingTitle =
        (json['training_title'] ?? json['trainingTitle'] ?? '') as String;
    final versionNumber =
        (json['version_number'] ??
                json['version_identifier'] ??
                json['versionNumber'] ??
                1)
            as int;
    final status = (json['status'] ?? 'ASSIGNED') as String;
    final assignedAtStr = json['assigned_at'] ?? json['assigned_date'];
    final dueAtStr = json['due_at'] ?? json['due_date'];
    final startedAtStr = json['started_at'];
    final completedAtStr = json['completed_at'] ?? json['completion_date'];
    final isOverdue = json['is_overdue'] as bool? ?? false;
    final progressJson = json['progress_summary'];

    return EmployeeAssignmentSummary(
      id: id,
      trainingTitle: trainingTitle,
      versionNumber: versionNumber,
      status: status,
      assignedAt: assignedAtStr != null
          ? DateTime.tryParse(assignedAtStr.toString())
          : null,
      dueAt: dueAtStr != null ? DateTime.tryParse(dueAtStr.toString()) : null,
      startedAt: startedAtStr != null
          ? DateTime.tryParse(startedAtStr.toString())
          : null,
      completedAt: completedAtStr != null
          ? DateTime.tryParse(completedAtStr.toString())
          : null,
      isOverdue: isOverdue,
      progressSummary: progressJson is Map<String, dynamic>
          ? ProgressSummary.fromJson(progressJson)
          : null,
      trainingId: trainingId,
      trainingVersionId: trainingVersionId,
    );
  }
}

class ManagedTraining {
  final int id;
  final String code;
  final String title;
  final String description;
  final bool isActive;
  final int? latestVersionNumber;
  final String? latestVersionStatus;

  const ManagedTraining({
    required this.id,
    required this.code,
    required this.title,
    this.description = '',
    this.isActive = true,
    this.latestVersionNumber,
    this.latestVersionStatus,
  });

  factory ManagedTraining.fromJson(Map<String, dynamic> json) =>
      ManagedTraining(
        id: json['id'] as int,
        code: (json['code'] ?? '') as String,
        title: (json['catalog_title'] ?? json['title'] ?? '') as String,
        description: (json['description'] ?? '') as String,
        isActive: (json['is_active'] ?? true) as bool,
        latestVersionNumber: (json['latest_version_number'] as num?)?.toInt(),
        latestVersionStatus: json['latest_version_status'] as String?,
      );
}

class ManagedTrainingVersionItem {
  final int id;
  final int trainingId;
  final String? trainingTitle;
  final int versionNumber;
  final String title;
  final String status;
  final String description;

  const ManagedTrainingVersionItem({
    required this.id,
    required this.trainingId,
    this.trainingTitle,
    required this.versionNumber,
    required this.title,
    required this.status,
    this.description = '',
  });

  factory ManagedTrainingVersionItem.fromJson(Map<String, dynamic> json) =>
      ManagedTrainingVersionItem(
        id: json['id'] as int,
        trainingId: (json['training_id'] ?? json['training']) as int? ?? 0,
        trainingTitle:
            (json['training_title'] ?? json['trainingTitle']) as String?,
        versionNumber:
            (json['version_number'] ?? json['versionNumber'] ?? 1) as int,
        title: (json['title'] ?? '') as String,
        status: (json['status'] ?? 'DRAFT') as String,
        description: (json['description'] ?? '') as String,
      );
}

class ManagedLessonSummary {
  final int id;
  final String title;
  final String lessonType;
  final int order;
  final bool isRequired;

  const ManagedLessonSummary({
    required this.id,
    required this.title,
    required this.lessonType,
    required this.order,
    this.isRequired = true,
  });

  factory ManagedLessonSummary.fromJson(Map<String, dynamic> json) =>
      ManagedLessonSummary(
        id: json['id'] as int,
        title: (json['title'] ?? '') as String,
        lessonType:
            (json['lesson_type'] ?? json['lessonType'] ?? 'TEXT') as String,
        order: (json['order'] as num?)?.toInt() ?? 0,
        isRequired: (json['is_required'] ?? json['isRequired'] ?? true) as bool,
      );
}

class ManagedModule {
  final int id;
  final String title;
  final String description;
  final int order;
  final List<ManagedLessonSummary> lessons;

  const ManagedModule({
    required this.id,
    required this.title,
    this.description = '',
    required this.order,
    this.lessons = const [],
  });

  factory ManagedModule.fromJson(Map<String, dynamic> json) {
    final rawLessons = json['lessons'] as List<dynamic>? ?? [];
    final lessons =
        rawLessons
            .map(
              (l) => ManagedLessonSummary.fromJson(l as Map<String, dynamic>),
            )
            .toList()
          ..sort((a, b) => a.order.compareTo(b.order));

    return ManagedModule(
      id: json['id'] as int,
      title: (json['title'] ?? '') as String,
      description: (json['description'] ?? '') as String,
      order: (json['order'] as num?)?.toInt() ?? 0,
      lessons: List.unmodifiable(lessons),
    );
  }
}

class ManagedVersionDetail {
  final int id;
  final int? trainingId;
  final String? trainingTitle;
  final String? trainingCode;
  final int versionNumber;
  final String title;
  final String status;
  final String description;
  final String learningObjectives;
  final String changeSummary;
  final List<ManagedModule> modules;

  const ManagedVersionDetail({
    required this.id,
    this.trainingId,
    this.trainingTitle,
    this.trainingCode,
    required this.versionNumber,
    required this.title,
    required this.status,
    this.description = '',
    this.learningObjectives = '',
    this.changeSummary = '',
    this.modules = const [],
  });

  factory ManagedVersionDetail.fromJson(Map<String, dynamic> json) {
    final rawModules = json['modules'] as List<dynamic>? ?? [];
    final modules =
        rawModules
            .map((m) => ManagedModule.fromJson(m as Map<String, dynamic>))
            .toList()
          ..sort((a, b) => a.order.compareTo(b.order));

    return ManagedVersionDetail(
      id: json['id'] as int,
      trainingId: (json['training_id'] ?? json['training']) as int?,
      trainingTitle: json['training_title'] as String?,
      trainingCode: json['training_code'] as String?,
      versionNumber:
          (json['version_number'] ?? json['versionNumber'] ?? 1) as int,
      title: (json['title'] ?? '') as String,
      status: (json['status'] ?? 'DRAFT') as String,
      description: (json['description'] ?? '') as String,
      learningObjectives: (json['learning_objectives'] ?? '') as String,
      changeSummary: (json['change_summary'] ?? '') as String,
      modules: List.unmodifiable(modules),
    );
  }
}

class ManagedModuleDetail {
  final int id;
  final int trainingVersionId;
  final String title;
  final String description;
  final int position;

  const ManagedModuleDetail({
    required this.id,
    required this.trainingVersionId,
    required this.title,
    this.description = '',
    required this.position,
  });

  factory ManagedModuleDetail.fromJson(Map<String, dynamic> json) =>
      ManagedModuleDetail(
        id: json['id'] as int,
        trainingVersionId:
            (json['training_version_id'] ?? json['training_version']) as int,
        title: (json['title'] ?? '') as String,
        description: (json['description'] ?? '') as String,
        position: (json['position'] as num?)?.toInt() ?? 0,
      );
}

class ManagedTextLessonDetail {
  final int id;
  final int moduleId;
  final int trainingVersionId;
  final String title;
  final String contentType;
  final String body;
  final int position;
  final bool isRequired;

  const ManagedTextLessonDetail({
    required this.id,
    required this.moduleId,
    required this.trainingVersionId,
    required this.title,
    this.contentType = 'TEXT',
    required this.body,
    required this.position,
    this.isRequired = true,
  });

  factory ManagedTextLessonDetail.fromJson(Map<String, dynamic> json) =>
      ManagedTextLessonDetail(
        id: json['id'] as int,
        moduleId: (json['module_id'] ?? json['module']) as int,
        trainingVersionId:
            (json['training_version_id'] ?? json['training_version']) as int,
        title: (json['title'] ?? '') as String,
        contentType: (json['content_type'] ?? 'TEXT') as String,
        body: (json['body'] ?? '') as String,
        position: (json['position'] as num?)?.toInt() ?? 0,
        isRequired: (json['is_required'] ?? true) as bool,
      );
}

class ManagedVideoLessonDetail {
  final int id;
  final int moduleId;
  final int trainingVersionId;
  final String title;
  final String contentType;
  final int position;
  final bool isRequired;
  final String minimumWatchPercent;
  final int videoDurationSeconds;
  final bool hasVideo;

  const ManagedVideoLessonDetail({
    required this.id,
    required this.moduleId,
    required this.trainingVersionId,
    required this.title,
    this.contentType = 'VIDEO',
    required this.position,
    this.isRequired = true,
    this.minimumWatchPercent = '90.00',
    this.videoDurationSeconds = 0,
    this.hasVideo = false,
  });

  factory ManagedVideoLessonDetail.fromJson(Map<String, dynamic> json) =>
      ManagedVideoLessonDetail(
        id: json['id'] as int,
        moduleId: (json['module_id'] ?? json['module']) as int,
        trainingVersionId:
            (json['training_version_id'] ?? json['training_version']) as int,
        title: (json['title'] ?? '') as String,
        contentType: (json['content_type'] ?? 'VIDEO') as String,
        position: (json['position'] as num?)?.toInt() ?? 0,
        isRequired: (json['is_required'] ?? true) as bool,
        minimumWatchPercent:
            (json['minimum_watch_percent']?.toString() ?? '90.00'),
        videoDurationSeconds:
            (json['video_duration_seconds'] as num?)?.toInt() ?? 0,
        hasVideo: (json['has_video'] as bool?) ?? false,
      );
}

class ManagedAssessment {
  final int id;
  final int trainingVersionId;
  final int? moduleId;
  final String kind;
  final String title;
  final int sequence;
  final String passPercentage;
  final int maxAttempts;
  final int? timeLimitMinutes;
  final bool isRequired;

  const ManagedAssessment({
    required this.id,
    required this.trainingVersionId,
    this.moduleId,
    required this.kind,
    required this.title,
    required this.sequence,
    this.passPercentage = '80.00',
    this.maxAttempts = 3,
    this.timeLimitMinutes,
    this.isRequired = true,
  });

  bool get isFinal => kind.toUpperCase() == 'FINAL';
  bool get isQuiz => kind.toUpperCase() == 'QUIZ';

  factory ManagedAssessment.fromJson(Map<String, dynamic> json) =>
      ManagedAssessment(
        id: json['id'] as int,
        trainingVersionId:
            (json['training_version_id'] ?? json['training_version']) as int,
        moduleId: (json['module_id'] ?? json['module']) as int?,
        kind: (json['kind'] ?? 'QUIZ') as String,
        title: (json['title'] ?? '') as String,
        sequence: (json['sequence'] as num?)?.toInt() ?? 1,
        passPercentage: json['pass_percentage']?.toString() ?? '80.00',
        maxAttempts: (json['max_attempts'] as num?)?.toInt() ?? 3,
        timeLimitMinutes: (json['time_limit_minutes'] as num?)?.toInt(),
        isRequired: (json['is_required'] ?? true) as bool,
      );
}

class ManagedAssessmentQuestion {
  final int id;
  final int assessmentId;
  final int questionRevisionId;
  final int position;
  final String points;

  const ManagedAssessmentQuestion({
    required this.id,
    required this.assessmentId,
    required this.questionRevisionId,
    required this.position,
    this.points = '1.00',
  });

  factory ManagedAssessmentQuestion.fromJson(Map<String, dynamic> json) =>
      ManagedAssessmentQuestion(
        id: json['id'] as int,
        assessmentId: (json['assessment_id'] ?? json['assessment']) as int,
        questionRevisionId:
            (json['question_revision_id'] ?? json['question_revision']) as int,
        position: (json['position'] as num?)?.toInt() ?? 1,
        points: json['points']?.toString() ?? '1.00',
      );
}

class ManagedQuestion {
  final int id;
  final String code;
  final String topic;
  final bool isActive;

  const ManagedQuestion({
    required this.id,
    required this.code,
    this.topic = '',
    this.isActive = true,
  });

  factory ManagedQuestion.fromJson(Map<String, dynamic> json) =>
      ManagedQuestion(
        id: json['id'] as int,
        code: (json['code'] ?? '') as String,
        topic: (json['topic'] ?? '') as String,
        isActive: (json['is_active'] ?? true) as bool,
      );
}

class ManagedQuestionOption {
  final int id;
  final String text;
  final int position;
  final bool isCorrect;

  const ManagedQuestionOption({
    required this.id,
    required this.text,
    required this.position,
    this.isCorrect = false,
  });

  factory ManagedQuestionOption.fromJson(Map<String, dynamic> json) =>
      ManagedQuestionOption(
        id: json['id'] as int,
        text: (json['text'] ?? '') as String,
        position: (json['position'] as num?)?.toInt() ?? 1,
        isCorrect: (json['is_correct'] ?? false) as bool,
      );

  Map<String, dynamic> toJson({bool delete = false}) => {
    'id': id,
    if (delete)
      'delete': true
    else ...{
      'text': text,
      'position': position,
      'is_correct': isCorrect,
    },
  };
}

class ManagedQuestionRevisionSummary {
  final int id;
  final int questionId;
  final int revisionNumber;
  final String questionType;
  final String status;
  final DateTime? frozenAt;

  const ManagedQuestionRevisionSummary({
    required this.id,
    required this.questionId,
    required this.revisionNumber,
    this.questionType = 'SINGLE_CHOICE',
    this.status = 'DRAFT',
    this.frozenAt,
  });

  bool get isFrozen => status.toUpperCase() == 'FROZEN';
  bool get isDraft => status.toUpperCase() == 'DRAFT';

  factory ManagedQuestionRevisionSummary.fromJson(Map<String, dynamic> json) =>
      ManagedQuestionRevisionSummary(
        id: json['id'] as int,
        questionId: (json['question_id'] ?? json['question']) as int,
        revisionNumber: (json['revision_number'] as num?)?.toInt() ?? 1,
        questionType: (json['question_type'] ?? 'SINGLE_CHOICE') as String,
        status: (json['status'] ?? 'DRAFT') as String,
        frozenAt: json['frozen_at'] != null
            ? DateTime.tryParse(json['frozen_at'] as String)
            : null,
      );
}

class ManagedQuestionRevisionDetail {
  final int id;
  final int questionId;
  final int revisionNumber;
  final String questionType;
  final String status;
  final DateTime? frozenAt;
  final String prompt;
  final String explanation;
  final List<ManagedQuestionOption> options;

  const ManagedQuestionRevisionDetail({
    required this.id,
    required this.questionId,
    required this.revisionNumber,
    this.questionType = 'SINGLE_CHOICE',
    this.status = 'DRAFT',
    this.frozenAt,
    required this.prompt,
    this.explanation = '',
    this.options = const [],
  });

  bool get isFrozen => status.toUpperCase() == 'FROZEN';
  bool get isDraft => status.toUpperCase() == 'DRAFT';

  factory ManagedQuestionRevisionDetail.fromJson(Map<String, dynamic> json) =>
      ManagedQuestionRevisionDetail(
        id: json['id'] as int,
        questionId: (json['question_id'] ?? json['question']) as int,
        revisionNumber: (json['revision_number'] as num?)?.toInt() ?? 1,
        questionType: (json['question_type'] ?? 'SINGLE_CHOICE') as String,
        status: (json['status'] ?? 'DRAFT') as String,
        frozenAt: json['frozen_at'] != null
            ? DateTime.tryParse(json['frozen_at'] as String)
            : null,
        prompt: (json['prompt'] ?? '') as String,
        explanation: (json['explanation'] ?? '') as String,
        options:
            (json['options'] as List<dynamic>?)
                ?.map(
                  (e) =>
                      ManagedQuestionOption.fromJson(e as Map<String, dynamic>),
                )
                .toList() ??
            const [],
      );
}

class RoleTrainingRequirement {
  final int id;
  final int jobRoleId;
  final String jobRoleCode;
  final String jobRoleName;
  final int trainingVersionId;
  final int trainingId;
  final String trainingTitle;
  final String versionTitle;
  final int versionNumber;
  final String versionStatus;
  final int dueInDays;
  final bool isActive;
  final DateTime createdAt;
  final DateTime updatedAt;

  const RoleTrainingRequirement({
    required this.id,
    required this.jobRoleId,
    required this.jobRoleCode,
    required this.jobRoleName,
    required this.trainingVersionId,
    required this.trainingId,
    required this.trainingTitle,
    required this.versionTitle,
    required this.versionNumber,
    required this.versionStatus,
    required this.dueInDays,
    required this.isActive,
    required this.createdAt,
    required this.updatedAt,
  });

  bool get isPublished => versionStatus.toUpperCase() == 'PUBLISHED';
  bool get isRetired => versionStatus.toUpperCase() == 'RETIRED';

  factory RoleTrainingRequirement.fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    if (id is! int || id <= 0) {
      throw const FormatException('Missing or invalid requirement id.');
    }
    final jobRoleId = json['job_role_id'];
    if (jobRoleId is! int || jobRoleId <= 0) {
      throw const FormatException('Missing or invalid job_role_id.');
    }
    final jobRoleCode = json['job_role_code'];
    if (jobRoleCode is! String) {
      throw const FormatException('Missing or invalid job_role_code.');
    }
    final jobRoleName = json['job_role_name'];
    if (jobRoleName is! String) {
      throw const FormatException('Missing or invalid job_role_name.');
    }
    final trainingVersionId = json['training_version_id'];
    if (trainingVersionId is! int || trainingVersionId <= 0) {
      throw const FormatException('Missing or invalid training_version_id.');
    }
    final trainingId = json['training_id'];
    if (trainingId is! int || trainingId <= 0) {
      throw const FormatException('Missing or invalid training_id.');
    }
    final trainingTitle = json['training_title'];
    if (trainingTitle is! String) {
      throw const FormatException('Missing or invalid training_title.');
    }
    final versionTitle = json['version_title'];
    if (versionTitle is! String) {
      throw const FormatException('Missing or invalid version_title.');
    }
    final versionNumber = json['version_number'];
    if (versionNumber is! int || versionNumber <= 0) {
      throw const FormatException('Missing or invalid version_number.');
    }
    final versionStatus = json['version_status'];
    if (versionStatus is! String || versionStatus.trim().isEmpty) {
      throw const FormatException('Missing or invalid version_status.');
    }
    final dueInDays = json['due_in_days'];
    if (dueInDays is! int || dueInDays < 0) {
      throw const FormatException('Missing or invalid due_in_days.');
    }
    final isActive = json['is_active'];
    if (isActive is! bool) {
      throw const FormatException('Missing or invalid is_active.');
    }
    final createdAtStr = json['created_at'];
    if (createdAtStr is! String) {
      throw const FormatException('Missing or invalid created_at.');
    }
    final updatedAtStr = json['updated_at'];
    if (updatedAtStr is! String) {
      throw const FormatException('Missing or invalid updated_at.');
    }

    final createdAt = DateTime.tryParse(createdAtStr);
    if (createdAt == null) {
      throw const FormatException('Invalid created_at timestamp.');
    }
    final updatedAt = DateTime.tryParse(updatedAtStr);
    if (updatedAt == null) {
      throw const FormatException('Invalid updated_at timestamp.');
    }

    return RoleTrainingRequirement(
      id: id,
      jobRoleId: jobRoleId,
      jobRoleCode: jobRoleCode,
      jobRoleName: jobRoleName,
      trainingVersionId: trainingVersionId,
      trainingId: trainingId,
      trainingTitle: trainingTitle,
      versionTitle: versionTitle,
      versionNumber: versionNumber,
      versionStatus: versionStatus,
      dueInDays: dueInDays,
      isActive: isActive,
      createdAt: createdAt,
      updatedAt: updatedAt,
    );
  }
}

class RoleBatchResult {
  final int roleRequirementId;
  final int jobRoleId;
  final int trainingVersionId;
  final int createdCount;
  final int skippedCount;

  const RoleBatchResult({
    required this.roleRequirementId,
    required this.jobRoleId,
    required this.trainingVersionId,
    required this.createdCount,
    required this.skippedCount,
  });

  int get totalTargets => createdCount + skippedCount;

  factory RoleBatchResult.fromJson(Map<String, dynamic> json) {
    final roleRequirementId = json['role_requirement_id'] ?? json['id'];
    if (roleRequirementId is! int || roleRequirementId <= 0) {
      throw const FormatException('Missing or invalid role_requirement_id.');
    }
    final jobRoleId = json['job_role_id'];
    if (jobRoleId is! int || jobRoleId <= 0) {
      throw const FormatException('Missing or invalid job_role_id.');
    }
    final trainingVersionId = json['training_version_id'];
    if (trainingVersionId is! int || trainingVersionId <= 0) {
      throw const FormatException('Missing or invalid training_version_id.');
    }
    final createdCount = json['created_count'];
    if (createdCount is! int || createdCount < 0) {
      throw const FormatException('Missing or invalid created_count.');
    }
    final skippedCount = json['skipped_count'];
    if (skippedCount is! int || skippedCount < 0) {
      throw const FormatException('Missing or invalid skipped_count.');
    }

    return RoleBatchResult(
      roleRequirementId: roleRequirementId,
      jobRoleId: jobRoleId,
      trainingVersionId: trainingVersionId,
      createdCount: createdCount,
      skippedCount: skippedCount,
    );
  }
}

enum RoleRequirementOptionKind {
  jobRoles('job_roles', 'job role'),
  trainingVersions('training_versions', 'training version');

  final String queryParam;
  final String label;

  const RoleRequirementOptionKind(this.queryParam, this.label);
}

class RoleRequirementOption {
  final int id;
  final String label;

  const RoleRequirementOption({required this.id, required this.label});

  factory RoleRequirementOption.fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    if (id is! int || id <= 0) {
      throw const FormatException('Missing or invalid option id.');
    }
    final label = json['label'];
    if (label is! String || label.trim().isEmpty) {
      throw const FormatException('Missing or invalid option label.');
    }
    return RoleRequirementOption(id: id, label: label.trim());
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is RoleRequirementOption &&
          runtimeType == other.runtimeType &&
          id == other.id &&
          label == other.label;

  @override
  int get hashCode => Object.hash(id, label);

  @override
  String toString() => 'RoleRequirementOption(id: $id, label: $label)';
}

class ManagedCertificate {
  final int id;
  final String certificateNumber;
  final String trainingTitle;
  final int versionNumber;
  final DateTime issuedAt;
  final bool isRevoked;
  final String employeeName;
  final String employeeCode;
  final DateTime? revokedAt;

  const ManagedCertificate({
    required this.id,
    required this.certificateNumber,
    required this.trainingTitle,
    required this.versionNumber,
    required this.issuedAt,
    required this.isRevoked,
    required this.employeeName,
    required this.employeeCode,
    this.revokedAt,
  });

  factory ManagedCertificate.fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    if (id is! int || id <= 0) {
      throw const FormatException('Invalid certificate id.');
    }
    final certificateNumber = json['certificate_number'];
    if (certificateNumber is! String || certificateNumber.isEmpty) {
      throw const FormatException('Invalid certificate_number.');
    }
    final trainingTitle = json['training_title'];
    if (trainingTitle is! String) {
      throw const FormatException('Invalid training_title.');
    }
    final versionNumber = json['version_number'];
    if (versionNumber is! int || versionNumber < 1) {
      throw const FormatException('Invalid version_number.');
    }
    final issuedAtRaw = json['issued_at'];
    if (issuedAtRaw is! String) {
      throw const FormatException('Invalid issued_at.');
    }
    final issuedAt = DateTime.tryParse(issuedAtRaw);
    if (issuedAt == null) {
      throw const FormatException('Cannot parse issued_at timestamp.');
    }
    final isRevoked = json['is_revoked'];
    if (isRevoked is! bool) {
      throw const FormatException('Invalid is_revoked flag.');
    }
    final employeeName = json['employee_name'];
    if (employeeName is! String) {
      throw const FormatException('Invalid employee_name.');
    }
    final employeeCode = json['employee_code'];
    if (employeeCode is! String) {
      throw const FormatException('Invalid employee_code.');
    }
    final revokedAtRaw = json['revoked_at'];
    DateTime? revokedAt;
    if (revokedAtRaw != null) {
      if (revokedAtRaw is! String) {
        throw const FormatException('Invalid revoked_at.');
      }
      revokedAt = DateTime.tryParse(revokedAtRaw);
      if (revokedAt == null) {
        throw const FormatException('Cannot parse revoked_at timestamp.');
      }
    }
    return ManagedCertificate(
      id: id,
      certificateNumber: certificateNumber,
      trainingTitle: trainingTitle,
      versionNumber: versionNumber,
      issuedAt: issuedAt,
      isRevoked: isRevoked,
      employeeName: employeeName,
      employeeCode: employeeCode,
      revokedAt: revokedAt,
    );
  }
}

class ManagedCertificateDetail {
  final int id;
  final String certificateNumber;
  final String trainingTitle;
  final int versionNumber;
  final DateTime issuedAt;
  final bool isRevoked;
  final String employeeName;
  final String employeeCode;
  final DateTime? revokedAt;
  final String? revocationReason;

  const ManagedCertificateDetail({
    required this.id,
    required this.certificateNumber,
    required this.trainingTitle,
    required this.versionNumber,
    required this.issuedAt,
    required this.isRevoked,
    required this.employeeName,
    required this.employeeCode,
    this.revokedAt,
    this.revocationReason,
  });

  factory ManagedCertificateDetail.fromJson(Map<String, dynamic> json) {
    final base = ManagedCertificate.fromJson(json);
    final reason = json['revocation_reason'];
    if (reason != null && reason is! String) {
      throw const FormatException('Invalid revocation_reason.');
    }
    return ManagedCertificateDetail(
      id: base.id,
      certificateNumber: base.certificateNumber,
      trainingTitle: base.trainingTitle,
      versionNumber: base.versionNumber,
      issuedAt: base.issuedAt,
      isRevoked: base.isRevoked,
      employeeName: base.employeeName,
      employeeCode: base.employeeCode,
      revokedAt: base.revokedAt,
      revocationReason: reason as String?,
    );
  }
}

class CertificateRevocationResult {
  final int id;
  final bool isRevoked;
  final DateTime revokedAt;

  const CertificateRevocationResult({
    required this.id,
    required this.isRevoked,
    required this.revokedAt,
  });

  factory CertificateRevocationResult.fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    if (id is! int || id <= 0) {
      throw const FormatException('Invalid certificate id.');
    }
    final isRevoked = json['is_revoked'];
    if (isRevoked is! bool) {
      throw const FormatException('Invalid is_revoked.');
    }
    final revokedAtRaw = json['revoked_at'];
    if (revokedAtRaw is! String) {
      throw const FormatException('Invalid revoked_at.');
    }
    final revokedAt = DateTime.tryParse(revokedAtRaw);
    if (revokedAt == null) {
      throw const FormatException('Cannot parse revoked_at timestamp.');
    }
    return CertificateRevocationResult(
      id: id,
      isRevoked: isRevoked,
      revokedAt: revokedAt,
    );
  }
}
