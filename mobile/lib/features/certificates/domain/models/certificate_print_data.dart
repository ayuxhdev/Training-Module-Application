import 'package:flutter/foundation.dart';
import 'package:training_app/features/certificates/domain/models/certificate_detail.dart';
import 'package:training_app/features/management/domain/models/management_models.dart';

/// Immutable print-ready payload representing authoritative certificate data.
@immutable
class CertificatePrintData {
  final int certificateId;
  final String certificateNumber;
  final String employeeName;
  final String employeeCode;
  final String trainingTitle;
  final int versionNumber;
  final DateTime issuedAt;
  final bool isRevoked;
  final DateTime? revokedAt;
  final String? revocationReason;

  const CertificatePrintData({
    required this.certificateId,
    required this.certificateNumber,
    required this.employeeName,
    required this.employeeCode,
    required this.trainingTitle,
    required this.versionNumber,
    required this.issuedAt,
    required this.isRevoked,
    this.revokedAt,
    this.revocationReason,
  });

  /// Creates print data from an employee certificate detail model.
  factory CertificatePrintData.fromCertificateDetail(CertificateDetail detail) {
    return CertificatePrintData(
      certificateId: detail.id,
      certificateNumber: detail.certificateNumber,
      employeeName: detail.employeeName,
      employeeCode: detail.employeeCode,
      trainingTitle: detail.trainingTitle,
      versionNumber: detail.versionNumber,
      issuedAt: detail.issuedAt,
      isRevoked: detail.isRevoked,
      revokedAt: detail.revokedAt,
    );
  }

  /// Creates print data from a management certificate detail model.
  factory CertificatePrintData.fromManagedCertificateDetail(
    ManagedCertificateDetail detail,
  ) {
    return CertificatePrintData(
      certificateId: detail.id,
      certificateNumber: detail.certificateNumber,
      employeeName: detail.employeeName,
      employeeCode: detail.employeeCode,
      trainingTitle: detail.trainingTitle,
      versionNumber: detail.versionNumber,
      issuedAt: detail.issuedAt,
      isRevoked: detail.isRevoked,
      revokedAt: detail.revokedAt,
      revocationReason: detail.revocationReason,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CertificatePrintData &&
          runtimeType == other.runtimeType &&
          certificateId == other.certificateId &&
          certificateNumber == other.certificateNumber &&
          employeeName == other.employeeName &&
          employeeCode == other.employeeCode &&
          trainingTitle == other.trainingTitle &&
          versionNumber == other.versionNumber &&
          issuedAt == other.issuedAt &&
          isRevoked == other.isRevoked &&
          revokedAt == other.revokedAt &&
          revocationReason == other.revocationReason;

  @override
  int get hashCode => Object.hash(
    certificateId,
    certificateNumber,
    employeeName,
    employeeCode,
    trainingTitle,
    versionNumber,
    issuedAt,
    isRevoked,
    revokedAt,
    revocationReason,
  );
}
