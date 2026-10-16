import 'package:flutter_test/flutter_test.dart';
import 'package:training_app/features/certificates/domain/models/certificate_detail.dart';

void main() {
  group('CertificateDetail.fromJson', () {
    Map<String, dynamic> validJson() => {
          'id': 5,
          'certificate_number': 'GN-XYZ123',
          'training_title': 'First Aid',
          'version_number': 1,
          'employee_name': 'Alice Smith',
          'employee_code': 'GN-001',
          'issued_at': '2024-07-01T08:00:00Z',
          'is_revoked': false,
          'revoked_at': null,
          'assignment_id': 42,
          'has_document': false,
        };

    test('parses valid active certificate detail', () {
      final detail = CertificateDetail.fromJson(validJson());
      expect(detail.id, 5);
      expect(detail.certificateNumber, 'GN-XYZ123');
      expect(detail.trainingTitle, 'First Aid');
      expect(detail.versionNumber, 1);
      expect(detail.employeeName, 'Alice Smith');
      expect(detail.employeeCode, 'GN-001');
      expect(detail.issuedAt, DateTime.parse('2024-07-01T08:00:00Z'));
      expect(detail.isRevoked, false);
      expect(detail.revokedAt, isNull);
      expect(detail.assignmentId, 42);
      expect(detail.hasDocument, false);
    });

    test('parses revoked certificate with revoked_at', () {
      final json = validJson()
        ..['is_revoked'] = true
        ..['revoked_at'] = '2024-08-01T09:00:00Z';
      final detail = CertificateDetail.fromJson(json);
      expect(detail.isRevoked, true);
      expect(detail.revokedAt, DateTime.parse('2024-08-01T09:00:00Z'));
    });

    test('parses certificate with document', () {
      final json = validJson()..['has_document'] = true;
      final detail = CertificateDetail.fromJson(json);
      expect(detail.hasDocument, true);
    });

    test('throws on invalid id', () {
      final json = validJson()..['id'] = 0;
      expect(() => CertificateDetail.fromJson(json), throwsFormatException);
    });

    test('throws on empty certificate_number', () {
      final json = validJson()..['certificate_number'] = '';
      expect(() => CertificateDetail.fromJson(json), throwsFormatException);
    });

    test('throws on version_number zero', () {
      final json = validJson()..['version_number'] = 0;
      expect(() => CertificateDetail.fromJson(json), throwsFormatException);
    });

    test('throws on non-string employee_name', () {
      final json = validJson()..['employee_name'] = 123;
      expect(() => CertificateDetail.fromJson(json), throwsFormatException);
    });

    test('throws on unparseable issued_at', () {
      final json = validJson()..['issued_at'] = 'bad-ts';
      expect(() => CertificateDetail.fromJson(json), throwsFormatException);
    });

    test('throws on non-string revoked_at when present', () {
      final json = validJson()
        ..['is_revoked'] = true
        ..['revoked_at'] = 99999;
      expect(() => CertificateDetail.fromJson(json), throwsFormatException);
    });

    test('throws on unparseable revoked_at string', () {
      final json = validJson()
        ..['is_revoked'] = true
        ..['revoked_at'] = 'not-a-date';
      expect(() => CertificateDetail.fromJson(json), throwsFormatException);
    });

    test('throws on invalid assignment_id', () {
      final json = validJson()..['assignment_id'] = 0;
      expect(() => CertificateDetail.fromJson(json), throwsFormatException);
    });

    test('throws on non-bool has_document', () {
      final json = validJson()..['has_document'] = 'yes';
      expect(() => CertificateDetail.fromJson(json), throwsFormatException);
    });
  });
}
