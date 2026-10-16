/// Lightweight certificate model used in the paginated list.
class Certificate {
  final int id;
  final String certificateNumber;
  final String trainingTitle;
  final int versionNumber;
  final DateTime issuedAt;
  final bool isRevoked;

  const Certificate({
    required this.id,
    required this.certificateNumber,
    required this.trainingTitle,
    required this.versionNumber,
    required this.issuedAt,
    required this.isRevoked,
  });

  factory Certificate.fromJson(Map<String, dynamic> json) {
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
    return Certificate(
      id: id,
      certificateNumber: certificateNumber,
      trainingTitle: trainingTitle,
      versionNumber: versionNumber,
      issuedAt: issuedAt,
      isRevoked: isRevoked,
    );
  }
}
