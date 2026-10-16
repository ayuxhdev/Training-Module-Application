import 'package:flutter_test/flutter_test.dart';
import 'package:training_app/features/certificates/domain/models/certificate.dart';

void main() {
  group('Certificate.fromJson', () {
    Map<String, dynamic> validJson() => {
          'id': 1,
          'certificate_number': 'GN-ABCDEF',
          'training_title': 'Safety Training',
          'version_number': 2,
          'issued_at': '2024-06-15T10:00:00Z',
          'is_revoked': false,
        };

    test('parses valid active certificate', () {
      final cert = Certificate.fromJson(validJson());
      expect(cert.id, 1);
      expect(cert.certificateNumber, 'GN-ABCDEF');
      expect(cert.trainingTitle, 'Safety Training');
      expect(cert.versionNumber, 2);
      expect(cert.issuedAt, DateTime.parse('2024-06-15T10:00:00Z'));
      expect(cert.isRevoked, false);
    });

    test('parses revoked certificate', () {
      final json = validJson()..['is_revoked'] = true;
      final cert = Certificate.fromJson(json);
      expect(cert.isRevoked, true);
    });

    test('throws on missing id', () {
      final json = validJson()..remove('id');
      expect(() => Certificate.fromJson(json), throwsFormatException);
    });

    test('throws on zero id', () {
      final json = validJson()..['id'] = 0;
      expect(() => Certificate.fromJson(json), throwsFormatException);
    });

    test('throws on negative id', () {
      final json = validJson()..['id'] = -1;
      expect(() => Certificate.fromJson(json), throwsFormatException);
    });

    test('throws on empty certificate_number', () {
      final json = validJson()..['certificate_number'] = '';
      expect(() => Certificate.fromJson(json), throwsFormatException);
    });

    test('throws on missing certificate_number', () {
      final json = validJson()..remove('certificate_number');
      expect(() => Certificate.fromJson(json), throwsFormatException);
    });

    test('throws on version_number less than 1', () {
      final json = validJson()..['version_number'] = 0;
      expect(() => Certificate.fromJson(json), throwsFormatException);
    });

    test('throws on unparseable issued_at', () {
      final json = validJson()..['issued_at'] = 'not-a-date';
      expect(() => Certificate.fromJson(json), throwsFormatException);
    });

    test('throws on non-string issued_at', () {
      final json = validJson()..['issued_at'] = 12345;
      expect(() => Certificate.fromJson(json), throwsFormatException);
    });

    test('throws on non-bool is_revoked', () {
      final json = validJson()..['is_revoked'] = 'yes';
      expect(() => Certificate.fromJson(json), throwsFormatException);
    });
  });
}
