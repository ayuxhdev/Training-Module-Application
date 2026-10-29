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
