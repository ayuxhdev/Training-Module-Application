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
    isActive: json['is_active'] as bool,
    // Date-only employment dates must not be shifted through a device timezone.
    dateJoined: json['date_joined'] as String?,
    loginStatus: json['login_status'] as String?,
  );
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
