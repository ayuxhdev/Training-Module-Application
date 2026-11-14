import 'package:flutter/foundation.dart';

/// Presentation view data for a single item in the assignment report.
@immutable
class AssignmentReportItemViewData {
  final int id;
  final String employeeName;
  final String employeeCode;
  final String departmentName;
  final String jobRoleName;
  final String trainingTitle;
  final String versionTitle;
  final int versionNumber;
  final String status; // 'ASSIGNED', 'IN_PROGRESS', 'COMPLETED', 'CANCELLED'
  final String statusDisplay;
  final bool isOverdue;
  final DateTime? assignedAt;
  final DateTime? dueAt;
  final DateTime? completedAt;
  final int? certificateId;
  final String? certificateNumber;
  final bool? isCertificateRevoked;

  const AssignmentReportItemViewData({
    required this.id,
    required this.employeeName,
    required this.employeeCode,
    required this.departmentName,
    required this.jobRoleName,
    required this.trainingTitle,
    required this.versionTitle,
    required this.versionNumber,
    required this.status,
    required this.statusDisplay,
    required this.isOverdue,
    this.assignedAt,
    this.dueAt,
    this.completedAt,
    this.certificateId,
    this.certificateNumber,
    this.isCertificateRevoked,
  });

  String get safeEmployeeName =>
      employeeName.trim().isNotEmpty ? employeeName : 'Unknown employee';

  String get safeEmployeeCode =>
      employeeCode.trim().isNotEmpty ? employeeCode : 'N/A';

  String get safeTrainingTitle =>
      trainingTitle.trim().isNotEmpty ? trainingTitle : 'Untitled training';

  String get safeVersionTitle => versionTitle.trim().isNotEmpty
      ? versionTitle
      : 'Version $versionNumber';

  bool get hasCertificate => certificateId != null && certificateId! > 0;
  bool get hasCertificateIndicator =>
      hasCertificate || isCertificateRevoked != null;
  bool get isCompleted => status.toUpperCase() == 'COMPLETED';

  factory AssignmentReportItemViewData.fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    if (id is! int || id <= 0) {
      throw const FormatException('Invalid assignment report id.');
    }
    return AssignmentReportItemViewData(
      id: id,
      employeeName: (json['employee_name'] as String?)?.trim() ?? '',
      employeeCode: (json['employee_code'] as String?)?.trim() ?? '',
      departmentName: (json['department_name'] as String?)?.trim() ?? '',
      jobRoleName: (json['job_role_name'] as String?)?.trim() ?? '',
      trainingTitle: (json['training_title'] as String?)?.trim() ?? '',
      versionTitle: (json['version_title'] as String?)?.trim() ?? '',
      versionNumber: json['version_number'] as int? ?? 1,
      status: (json['status'] as String?)?.trim() ?? 'ASSIGNED',
      statusDisplay: (json['status_display'] as String?)?.trim() ?? 'Assigned',
      isOverdue: json['is_overdue'] as bool? ?? false,
      assignedAt: json['assigned_at'] != null
          ? DateTime.tryParse(json['assigned_at'] as String)
          : null,
      dueAt: json['due_at'] != null
          ? DateTime.tryParse(json['due_at'] as String)
          : null,
      completedAt: json['completed_at'] != null
          ? DateTime.tryParse(json['completed_at'] as String)
          : null,
      certificateId: json['certificate_id'] as int?,
      certificateNumber: json['certificate_number'] as String?,
      isCertificateRevoked: json['is_certificate_revoked'] as bool?,
    );
  }
}

/// Generic key-value option for filter dropdowns.
@immutable
class ReportFilterOption {
  final String value;
  final String label;

  const ReportFilterOption({
    required this.value,
    required this.label,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ReportFilterOption &&
          runtimeType == other.runtimeType &&
          value == other.value &&
          label == other.label;

  @override
  int get hashCode => Object.hash(value, label);
}

/// Training version filter option linking version to its parent training course.
@immutable
class ReportVersionFilterOption {
  final int id;
  final int trainingId;
  final int versionNumber;
  final String title;

  const ReportVersionFilterOption({
    required this.id,
    required this.trainingId,
    required this.versionNumber,
    required this.title,
  });

  String get label => '$title (v$versionNumber)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ReportVersionFilterOption &&
          runtimeType == other.runtimeType &&
          id == other.id &&
          trainingId == other.trainingId;

  @override
  int get hashCode => Object.hash(id, trainingId);
}

/// Available filter choices scoped to the current user's reporting hierarchy.
@immutable
class AssignmentReportFilterOptionsViewData {
  final List<ReportFilterOption> departments;
  final List<ReportFilterOption> jobRoles;
  final List<ReportFilterOption> trainings;
  final List<ReportVersionFilterOption> trainingVersions;
  final List<ReportFilterOption> statuses;

  const AssignmentReportFilterOptionsViewData({
    this.departments = const [],
    this.jobRoles = const [],
    this.trainings = const [],
    this.trainingVersions = const [],
    this.statuses = const [
      ReportFilterOption(value: 'ASSIGNED', label: 'Assigned'),
      ReportFilterOption(value: 'IN_PROGRESS', label: 'In progress'),
      ReportFilterOption(value: 'COMPLETED', label: 'Completed'),
      ReportFilterOption(value: 'CANCELLED', label: 'Cancelled'),
    ],
  });

  factory AssignmentReportFilterOptionsViewData.fromJson(
    Map<String, dynamic> json,
  ) {
    final statuses = (json['statuses'] as List<dynamic>?)
            ?.map((item) {
              final map = item as Map<String, dynamic>;
              return ReportFilterOption(
                value: (map['value'] as String?)?.trim() ?? '',
                label: (map['label'] as String?)?.trim() ?? '',
              );
            })
            .where((opt) => opt.value.isNotEmpty)
            .toList() ??
        const [
          ReportFilterOption(value: 'ASSIGNED', label: 'Assigned'),
          ReportFilterOption(value: 'IN_PROGRESS', label: 'In progress'),
          ReportFilterOption(value: 'COMPLETED', label: 'Completed'),
          ReportFilterOption(value: 'CANCELLED', label: 'Cancelled'),
        ];

    final departments = (json['departments'] as List<dynamic>?)
            ?.map((item) {
              final map = item as Map<String, dynamic>;
              return ReportFilterOption(
                value: '${map['id']}',
                label: (map['label'] as String?)?.trim() ?? '',
              );
            })
            .where((opt) => opt.value.isNotEmpty && opt.value != 'null')
            .toList() ??
        const [];

    final jobRoles = (json['job_roles'] as List<dynamic>?)
            ?.map((item) {
              final map = item as Map<String, dynamic>;
              return ReportFilterOption(
                value: '${map['id']}',
                label: (map['label'] as String?)?.trim() ?? '',
              );
            })
            .where((opt) => opt.value.isNotEmpty && opt.value != 'null')
            .toList() ??
        const [];

    final trainings = (json['trainings'] as List<dynamic>?)
            ?.map((item) {
              final map = item as Map<String, dynamic>;
              return ReportFilterOption(
                value: '${map['id']}',
                label: (map['label'] as String?)?.trim() ?? '',
              );
            })
            .where((opt) => opt.value.isNotEmpty && opt.value != 'null')
            .toList() ??
        const [];

    final trainingVersions = (json['training_versions'] as List<dynamic>?)
            ?.map((item) {
              final map = item as Map<String, dynamic>;
              return ReportVersionFilterOption(
                id: map['id'] as int? ?? 0,
                trainingId: map['training_id'] as int? ?? 0,
                versionNumber: map['version_number'] as int? ?? 1,
                title: (map['title'] as String?)?.trim() ??
                    (map['label'] as String?)?.trim() ??
                    '',
              );
            })
            .where((opt) => opt.id > 0)
            .toList() ??
        const [];

    return AssignmentReportFilterOptionsViewData(
      departments: departments,
      jobRoles: jobRoles,
      trainings: trainings,
      trainingVersions: trainingVersions,
      statuses: statuses.isNotEmpty
          ? statuses
          : const [
              ReportFilterOption(value: 'ASSIGNED', label: 'Assigned'),
              ReportFilterOption(value: 'IN_PROGRESS', label: 'In progress'),
              ReportFilterOption(value: 'COMPLETED', label: 'Completed'),
              ReportFilterOption(value: 'CANCELLED', label: 'Cancelled'),
            ],
    );
  }
}

/// Current filter parameters for querying assignment reports.
/// Strictly matches confirmed Django backend parameters (status, department,
/// job_role, training, training_version, overdue_only).
@immutable
class AssignmentReportFilterQuery {
  final String? status;
  final String? departmentId;
  final String? jobRoleId;
  final String? trainingId;
  final String? trainingVersionId;
  final bool? overdueOnly;
  final int page;
  final int pageSize;

  const AssignmentReportFilterQuery({
    this.status,
    this.departmentId,
    this.jobRoleId,
    this.trainingId,
    this.trainingVersionId,
    this.overdueOnly,
    this.page = 1,
    this.pageSize = 20,
  });

  AssignmentReportFilterQuery copyWith({
    String? status,
    String? departmentId,
    String? jobRoleId,
    String? trainingId,
    String? trainingVersionId,
    bool? overdueOnly,
    int? page,
    int? pageSize,
    bool clearStatus = false,
    bool clearDepartment = false,
    bool clearJobRole = false,
    bool clearTraining = false,
    bool clearTrainingVersion = false,
    bool clearOverdue = false,
  }) {
    return AssignmentReportFilterQuery(
      status: clearStatus ? null : (status ?? this.status),
      departmentId: clearDepartment ? null : (departmentId ?? this.departmentId),
      jobRoleId: clearJobRole ? null : (jobRoleId ?? this.jobRoleId),
      trainingId: clearTraining ? null : (trainingId ?? this.trainingId),
      trainingVersionId:
          clearTrainingVersion ? null : (trainingVersionId ?? this.trainingVersionId),
      overdueOnly: clearOverdue ? null : (overdueOnly ?? this.overdueOnly),
      page: page ?? this.page,
      pageSize: pageSize ?? this.pageSize,
    );
  }

  bool get hasActiveFilters =>
      (status != null && status!.isNotEmpty) ||
      (departmentId != null && departmentId!.isNotEmpty) ||
      (jobRoleId != null && jobRoleId!.isNotEmpty) ||
      (trainingId != null && trainingId!.isNotEmpty) ||
      (trainingVersionId != null && trainingVersionId!.isNotEmpty) ||
      (overdueOnly == true);

  int get activeFilterCount {
    var count = 0;
    if (status != null && status!.isNotEmpty) count++;
    if (departmentId != null && departmentId!.isNotEmpty) count++;
    if (jobRoleId != null && jobRoleId!.isNotEmpty) count++;
    if (trainingId != null && trainingId!.isNotEmpty) count++;
    if (trainingVersionId != null && trainingVersionId!.isNotEmpty) count++;
    if (overdueOnly == true) count++;
    return count;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AssignmentReportFilterQuery &&
          runtimeType == other.runtimeType &&
          status == other.status &&
          departmentId == other.departmentId &&
          jobRoleId == other.jobRoleId &&
          trainingId == other.trainingId &&
          trainingVersionId == other.trainingVersionId &&
          overdueOnly == other.overdueOnly &&
          page == other.page &&
          pageSize == other.pageSize;

  @override
  int get hashCode => Object.hash(
        status,
        departmentId,
        jobRoleId,
        trainingId,
        trainingVersionId,
        overdueOnly,
        page,
        pageSize,
      );
}

/// Paginated report result page.
@immutable
class AssignmentReportPageViewData {
  final List<AssignmentReportItemViewData> items;
  final int count;
  final bool hasMore;
  final int page;
  final int pageSize;

  const AssignmentReportPageViewData({
    required this.items,
    required this.count,
    required this.hasMore,
    required this.page,
    this.pageSize = 20,
  });

  factory AssignmentReportPageViewData.fromJson(
    Map<String, dynamic> json, {
    required int page,
    int pageSize = 20,
  }) {
    final count = json['count'] as int? ?? 0;
    final next = json['next'];
    final rawResults = json['results'] as List<dynamic>? ?? const [];
    final items = rawResults
        .map((r) =>
            AssignmentReportItemViewData.fromJson(r as Map<String, dynamic>))
        .toList();
    return AssignmentReportPageViewData(
      items: items,
      count: count,
      hasMore: next != null,
      page: page,
      pageSize: pageSize,
    );
  }

  int get totalPages => (count <= 0) ? 1 : ((count - 1) ~/ pageSize) + 1;
}
