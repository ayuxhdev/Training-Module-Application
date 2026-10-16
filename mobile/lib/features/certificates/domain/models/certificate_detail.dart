/// Full certificate detail used on the certificate detail screen.
class CertificateDetail {
  final int id;
  final String certificateNumber;
  final String trainingTitle;
  final int versionNumber;
  final String employeeName;
  final String employeeCode;
  final DateTime issuedAt;
  final bool isRevoked;
  final DateTime? revokedAt;
  final int assignmentId;
  final bool hasDocument;

  const CertificateDetail({
    required this.id,
    required this.certificateNumber,
    required this.trainingTitle,
    required this.versionNumber,
    required this.employeeName,
    required this.employeeCode,
    required this.issuedAt,
    required this.isRevoked,
    required this.revokedAt,
    required this.assignmentId,
    required this.hasDocument,
  });

  factory CertificateDetail.fromJson(Map<String, dynamic> json) {
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
    final employeeName = json['employee_name'];
    if (employeeName is! String) {
      throw const FormatException('Invalid employee_name.');
    }
    final employeeCode = json['employee_code'];
    if (employeeCode is! String) {
      throw const FormatException('Invalid employee_code.');
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
    final assignmentId = json['assignment_id'];
    if (assignmentId is! int || assignmentId <= 0) {
      throw const FormatException('Invalid assignment_id.');
    }
    final hasDocument = json['has_document'];
    if (hasDocument is! bool) {
      throw const FormatException('Invalid has_document flag.');
    }
    return CertificateDetail(
      id: id,
      certificateNumber: certificateNumber,
      trainingTitle: trainingTitle,
      versionNumber: versionNumber,
      employeeName: employeeName,
      employeeCode: employeeCode,
      issuedAt: issuedAt,
      isRevoked: isRevoked,
      revokedAt: revokedAt,
      assignmentId: assignmentId,
      hasDocument: hasDocument,
    );
  }
}
