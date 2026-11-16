import 'package:flutter/foundation.dart';

import 'report_audit_json_parsers.dart';

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

  String get safeVersionTitle =>
      versionTitle.trim().isNotEmpty ? versionTitle : 'Version $versionNumber';

  bool get hasCertificate => certificateId != null && certificateId! > 0;
  bool get hasCertificateIndicator =>
      hasCertificate || isCertificateRevoked != null;
  bool get isCompleted => status.toUpperCase() == 'COMPLETED';

  factory AssignmentReportItemViewData.fromJson(Map<String, dynamic> json) {
    const validStatuses = {'ASSIGNED', 'IN_PROGRESS', 'COMPLETED', 'CANCELLED'};
    final id = TypedJsonReader.readRequiredInt(json, 'id', minValue: 1);
    final versionNumber = TypedJsonReader.readRequiredInt(
      json,
      'version_number',
      minValue: 1,
    );
    final isOverdue = TypedJsonReader.readRequiredBool(json, 'is_overdue');
    final assignedAt = TypedJsonReader.readOptionalDateTime(
      json,
      'assigned_at',
    );
    final status = TypedJsonReader.readEnumString(
      json,
      'status',
      validStatuses,
    );

    return AssignmentReportItemViewData(
      id: id,
      employeeName:
          TypedJsonReader.readOptionalString(json, 'employee_name') ?? '',
      employeeCode:
          TypedJsonReader.readOptionalString(json, 'employee_code') ?? '',
      departmentName:
          TypedJsonReader.readOptionalString(json, 'department_name') ?? '',
      jobRoleName:
          TypedJsonReader.readOptionalString(json, 'job_role_name') ?? '',
      trainingTitle:
          TypedJsonReader.readOptionalString(json, 'training_title') ?? '',
      versionTitle:
          TypedJsonReader.readOptionalString(json, 'version_title') ?? '',
      versionNumber: versionNumber,
      status: status,
      statusDisplay:
          TypedJsonReader.readOptionalString(json, 'status_display') ?? status,
      isOverdue: isOverdue,
      assignedAt: assignedAt,
      dueAt: TypedJsonReader.readOptionalDateTime(json, 'due_at'),
      completedAt: TypedJsonReader.readOptionalDateTime(json, 'completed_at'),
      certificateId: TypedJsonReader.readOptionalInt(
        json,
        'certificate_id',
        minValue: 1,
      ),
      certificateNumber: TypedJsonReader.readOptionalString(
        json,
        'certificate_number',
      ),
      isCertificateRevoked: TypedJsonReader.readOptionalBool(
        json,
        'is_certificate_revoked',
      ),
    );
  }
}

/// Generic key-value option for filter dropdowns.
@immutable
class ReportFilterOption {
  final String value;
  final String label;

  const ReportFilterOption({required this.value, required this.label});

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
    final rawStatuses = TypedJsonReader.readOptionalList(json, 'statuses');
    final statuses = rawStatuses
        .map((item) {
          final map = TypedJsonReader.readMap(item, 'status option');
          return ReportFilterOption(
            value: TypedJsonReader.readRequiredString(map, 'value'),
            label: TypedJsonReader.readRequiredString(map, 'label'),
          );
        })
        .where((opt) => opt.value.isNotEmpty)
        .toList();

    final rawDepts = TypedJsonReader.readOptionalList(json, 'departments');
    final departments = rawDepts
        .map((item) {
          final map = TypedJsonReader.readMap(item, 'department option');
          final id = map['id'];
          if (id == null) {
            throw const FormatException('Missing department option id.');
          }
          return ReportFilterOption(
            value: '$id',
            label: TypedJsonReader.readRequiredString(map, 'label'),
          );
        })
        .where((opt) => opt.value.isNotEmpty && opt.value != 'null')
        .toList();

    final rawRoles = TypedJsonReader.readOptionalList(json, 'job_roles');
    final jobRoles = rawRoles
        .map((item) {
          final map = TypedJsonReader.readMap(item, 'job_role option');
          final id = map['id'];
          if (id == null) {
            throw const FormatException('Missing job_role option id.');
          }
          return ReportFilterOption(
            value: '$id',
            label: TypedJsonReader.readRequiredString(map, 'label'),
          );
        })
        .where((opt) => opt.value.isNotEmpty && opt.value != 'null')
        .toList();

    final rawTrainings = TypedJsonReader.readOptionalList(json, 'trainings');
    final trainings = rawTrainings
        .map((item) {
          final map = TypedJsonReader.readMap(item, 'training option');
          final id = map['id'];
          if (id == null) {
            throw const FormatException('Missing training option id.');
          }
          return ReportFilterOption(
            value: '$id',
            label: TypedJsonReader.readRequiredString(map, 'label'),
          );
        })
        .where((opt) => opt.value.isNotEmpty && opt.value != 'null')
        .toList();

    final rawVersions = TypedJsonReader.readOptionalList(
      json,
      'training_versions',
    );
    final trainingVersions = rawVersions.map((item) {
      final map = TypedJsonReader.readMap(item, 'training_version option');
      return ReportVersionFilterOption(
        id: TypedJsonReader.readRequiredInt(map, 'id', minValue: 1),
        trainingId: TypedJsonReader.readRequiredInt(
          map,
          'training_id',
          minValue: 1,
        ),
        versionNumber: TypedJsonReader.readRequiredInt(
          map,
          'version_number',
          minValue: 1,
        ),
        title:
            TypedJsonReader.readOptionalString(map, 'title') ??
            TypedJsonReader.readOptionalString(map, 'label') ??
            '',
      );
    }).toList();

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
      departmentId: clearDepartment
          ? null
          : (departmentId ?? this.departmentId),
      jobRoleId: clearJobRole ? null : (jobRoleId ?? this.jobRoleId),
      trainingId: clearTraining ? null : (trainingId ?? this.trainingId),
      trainingVersionId: clearTrainingVersion
          ? null
          : (trainingVersionId ?? this.trainingVersionId),
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
    final count =
        TypedJsonReader.readOptionalInt(json, 'count', minValue: 0) ?? 0;
    final next = json['next'];
    final rawResults = TypedJsonReader.readOptionalList(json, 'results');
    final items = rawResults
        .map(
          (r) => AssignmentReportItemViewData.fromJson(
            TypedJsonReader.readMap(r, 'report result'),
          ),
        )
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
