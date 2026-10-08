class DashboardMetrics {
  final int total;
  final int assigned;
  final int inProgress;
  final int completed;
  final int cancelled;
  final int overdue;
  final double completionPercent;
  final int certificatesCount;

  DashboardMetrics({
    required this.total,
    required this.assigned,
    required this.inProgress,
    required this.completed,
    required this.cancelled,
    required this.overdue,
    required this.completionPercent,
    required this.certificatesCount,
  });

  factory DashboardMetrics.fromJson(Map<String, dynamic> json) {
    return DashboardMetrics(
      total: json['total'] as int? ?? 0,
      assigned: json['assigned'] as int? ?? 0,
      inProgress: json['in_progress'] as int? ?? 0,
      completed: json['completed'] as int? ?? 0,
      cancelled: json['cancelled'] as int? ?? 0,
      overdue: json['overdue'] as int? ?? 0,
      completionPercent: (json['completion_percent'] as num?)?.toDouble() ?? 0.0,
      certificatesCount: json['certificates_count'] as int? ?? 0,
    );
  }
}

class DashboardAssignment {
  final int id;
  final int trainingId;
  final String trainingTitle;
  final int versionNumber;
  final String status;
  final DateTime? dueAt;
  final bool isOverdue;
  final DateTime? startedAt;

  DashboardAssignment({
    required this.id,
    required this.trainingId,
    required this.trainingTitle,
    required this.versionNumber,
    required this.status,
    this.dueAt,
    required this.isOverdue,
    this.startedAt,
  });

  factory DashboardAssignment.fromJson(Map<String, dynamic> json) {
    return DashboardAssignment(
      id: json['id'] as int? ?? 0,
      trainingId: json['training_id'] as int? ?? 0,
      trainingTitle: json['training_title'] as String? ?? '',
      versionNumber: json['version_number'] as int? ?? 1,
      status: json['status'] as String? ?? '',
      dueAt: json['due_at'] != null ? DateTime.tryParse(json['due_at']) : null,
      isOverdue: json['is_overdue'] as bool? ?? false,
      startedAt: json['started_at'] != null ? DateTime.tryParse(json['started_at']) : null,
    );
  }
}

class DashboardCertificate {
  final int id;
  final String certificateNumber;
  final String trainingTitle;
  final int versionNumber;
  final DateTime? issuedAt;

  DashboardCertificate({
    required this.id,
    required this.certificateNumber,
    required this.trainingTitle,
    required this.versionNumber,
    this.issuedAt,
  });

  factory DashboardCertificate.fromJson(Map<String, dynamic> json) {
    return DashboardCertificate(
      id: json['id'] as int? ?? 0,
      certificateNumber: json['certificate_number'] as String? ?? '',
      trainingTitle: json['training_title'] as String? ?? '',
      versionNumber: json['version_number'] as int? ?? 1,
      issuedAt: json['issued_at'] != null ? DateTime.tryParse(json['issued_at']) : null,
    );
  }
}

class DashboardData {
  final DashboardMetrics metrics;
  final List<DashboardAssignment> actionRequired;
  final List<DashboardCertificate> recentCertificates;

  DashboardData({
    required this.metrics,
    required this.actionRequired,
    required this.recentCertificates,
  });

  factory DashboardData.fromJson(Map<String, dynamic> json) {
    return DashboardData(
      metrics: DashboardMetrics.fromJson(json['metrics'] ?? {}),
      actionRequired: (json['action_required'] as List<dynamic>?)
              ?.map((e) => DashboardAssignment.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
      recentCertificates: (json['recent_certificates'] as List<dynamic>?)
              ?.map((e) => DashboardCertificate.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
    );
  }
}

