import 'package:flutter/services.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:training_app/features/certificates/domain/models/certificate_print_data.dart';

/// Service responsible for rendering a print-ready PDF document from authoritative certificate data.
class CertificatePdfGenerator {
  final pw.Font? regularFont;
  final pw.Font? boldFont;
  final pw.Font? monoFont;
  final pw.Font? monoBoldFont;

  const CertificatePdfGenerator({
    this.regularFont,
    this.boldFont,
    this.monoFont,
    this.monoBoldFont,
  });

  static const _brandDarkGreen = PdfColor.fromInt(0xFF1B4D3E);
  static const _brandLightBg = PdfColor.fromInt(0xFFF7FAF8);
  static const _brandGold = PdfColor.fromInt(0xFFC5A059);
  static const _revokedRed = PdfColor.fromInt(0xFFB00020);
  static const _revokedBg = PdfColor.fromInt(0xFFFDE8E8);
  static const _validGreen = PdfColor.fromInt(0xFF2E7D32);
  static const _validBg = PdfColor.fromInt(0xFFE8F5E9);

  /// Generates PDF document bytes for the given certificate data.
  ///
  /// In production, fonts are loaded from bundled assets using [rootBundle].
  /// In tests, fonts injected via the constructor are used directly (no asset loading),
  /// which avoids a [rootBundle] dependency on the test environment.
  Future<Uint8List> generate(
    CertificatePrintData data, {
    PdfPageFormat format = PdfPageFormat.a4,
  }) async {
    final pdf = pw.Document(
      title: 'Certificate_${data.certificateNumber}',
      author: "Garden's Need Training",
      creator: "Garden's Need Training Module Application",
    );

    final pw.Font fontRegular;
    final pw.Font fontBold;
    final pw.Font fontMono;
    final pw.Font fontMonoBold;

    if (regularFont != null && boldFont != null) {
      // Test path: use injected fonts directly, skip asset loading.
      fontRegular = regularFont!;
      fontBold = boldFont!;
      fontMono = monoFont ?? fontRegular;
      fontMonoBold = monoBoldFont ?? pw.Font.courierBold();
    } else {
      // Production path: load NotoSansDevanagari from bundled assets.
      // NotoSansDevanagari covers Latin (Basic + Extended) and the full
      // Devanagari Unicode block (U+0900–U+097F) including standalone vowels,
      // consonants, and vowel signs. Complex conjunct shaping (GSUB ligatures)
      // is NOT applied by package:pdf — conjunct sequences render as individual
      // glyphs in Unicode order. Names with simple vowel signs render correctly;
      // names with conjunct consonants (e.g. क्ष, त्र) will show each codepoint
      // separately rather than as a fused ligature glyph.
      final regularData = await rootBundle.load(
        'assets/fonts/NotoSansDevanagari-Regular.ttf',
      );
      final boldData = await rootBundle.load(
        'assets/fonts/NotoSansDevanagari-Bold.ttf',
      );
      fontRegular = pw.Font.ttf(regularData);
      fontBold = pw.Font.ttf(boldData);
      fontMono = monoFont ?? fontRegular;
      fontMonoBold = monoBoldFont ?? pw.Font.courierBold();
    }

    pdf.addPage(
      pw.Page(
        pageFormat: format,
        margin: const pw.EdgeInsets.all(28),
        build: (context) {
          return pw.Container(
            decoration: pw.BoxDecoration(
              color: PdfColors.white,
              border: pw.Border.all(
                color: data.isRevoked ? _revokedRed : _brandDarkGreen,
                width: 2.5,
              ),
              borderRadius: const pw.BorderRadius.all(pw.Radius.circular(12)),
            ),
            padding: const pw.EdgeInsets.symmetric(
              horizontal: 28,
              vertical: 24,
            ),
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.center,
              mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
              children: [
                // Header section
                pw.Column(
                  children: [
                    pw.Text(
                      "GARDEN'S NEED TRAINING",
                      style: pw.TextStyle(
                        font: fontBold,
                        fontSize: 13,
                        color: _brandDarkGreen,
                        letterSpacing: 2.0,
                      ),
                    ),
                    pw.SizedBox(height: 4),
                    pw.Container(width: 140, height: 1.5, color: _brandGold),
                    pw.SizedBox(height: 14),
                    pw.Text(
                      'Certificate of Completion',
                      style: pw.TextStyle(
                        font: fontBold,
                        fontSize: 22,
                        color: data.isRevoked ? _revokedRed : _brandDarkGreen,
                      ),
                    ),
                  ],
                ),

                // Recipient section
                pw.Column(
                  children: [
                    pw.Text(
                      'This is to certify that',
                      style: pw.TextStyle(
                        font: fontRegular,
                        fontSize: 11,
                        color: PdfColors.grey700,
                      ),
                    ),
                    pw.SizedBox(height: 8),
                    pw.Text(
                      _safeText(data.employeeName),
                      textAlign: pw.TextAlign.center,
                      style: pw.TextStyle(
                        font: fontBold,
                        fontSize: 18,
                        color: PdfColors.black,
                      ),
                    ),
                    pw.SizedBox(height: 4),
                    pw.Text(
                      'Employee code: ${_safeText(data.employeeCode)}',
                      style: pw.TextStyle(
                        font: fontMono,
                        fontFallback: [fontRegular],
                        fontSize: 10,
                        color: PdfColors.grey700,
                      ),
                    ),
                  ],
                ),

                // Curriculum section
                pw.Column(
                  children: [
                    pw.Text(
                      'has successfully completed the assigned training program for',
                      textAlign: pw.TextAlign.center,
                      style: pw.TextStyle(
                        font: fontRegular,
                        fontSize: 10,
                        color: PdfColors.grey700,
                      ),
                    ),
                    pw.SizedBox(height: 8),
                    pw.Text(
                      _safeText(data.trainingTitle),
                      textAlign: pw.TextAlign.center,
                      style: pw.TextStyle(
                        font: fontBold,
                        fontSize: 16,
                        color: _brandDarkGreen,
                      ),
                    ),
                    pw.SizedBox(height: 4),
                    pw.Text(
                      'Version ${data.versionNumber}',
                      style: pw.TextStyle(
                        font: fontRegular,
                        fontSize: 11,
                        color: PdfColors.grey800,
                      ),
                    ),
                  ],
                ),

                // Status in the loaded server record
                if (data.isRevoked)
                  pw.Container(
                    width: double.infinity,
                    decoration: pw.BoxDecoration(
                      color: _revokedBg,
                      border: pw.Border.all(color: _revokedRed, width: 1.5),
                      borderRadius: const pw.BorderRadius.all(
                        pw.Radius.circular(6),
                      ),
                    ),
                    padding: const pw.EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 10,
                    ),
                    child: pw.Column(
                      children: [
                        pw.Container(
                          padding: const pw.EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 3,
                          ),
                          decoration: const pw.BoxDecoration(
                            color: _revokedRed,
                            borderRadius: pw.BorderRadius.all(
                              pw.Radius.circular(3),
                            ),
                          ),
                          child: pw.Text(
                            'REVOKED CREDENTIAL',
                            style: pw.TextStyle(
                              font: fontBold,
                              fontSize: 11,
                              color: PdfColors.white,
                              letterSpacing: 1.2,
                            ),
                          ),
                        ),
                        pw.SizedBox(height: 6),
                        pw.Text(
                          data.revokedAt == null
                              ? 'This certificate has been revoked. Revocation date not available.'
                              : 'This certificate was revoked on ${_formatDate(data.revokedAt!)}.',
                          textAlign: pw.TextAlign.center,
                          style: pw.TextStyle(
                            font: fontBold,
                            fontSize: 10,
                            color: _revokedRed,
                          ),
                        ),
                        if (data.revocationReason != null &&
                            data.revocationReason!.trim().isNotEmpty) ...[
                          pw.SizedBox(height: 4),
                          pw.Text(
                            'Reason: ${_safeText(data.revocationReason!.trim())}',
                            textAlign: pw.TextAlign.center,
                            style: pw.TextStyle(
                              font: fontRegular,
                              fontSize: 9,
                              color: _revokedRed,
                            ),
                          ),
                        ],
                        pw.SizedBox(height: 2),
                        pw.Text(
                          'THIS CERTIFICATE IS NO LONGER VALID',
                          textAlign: pw.TextAlign.center,
                          style: pw.TextStyle(
                            font: fontBold,
                            fontSize: 8,
                            color: _revokedRed,
                          ),
                        ),
                      ],
                    ),
                  )
                else
                  pw.Container(
                    width: double.infinity,
                    decoration: pw.BoxDecoration(
                      color: _validBg,
                      border: pw.Border.all(color: _validGreen, width: 1),
                      borderRadius: const pw.BorderRadius.all(
                        pw.Radius.circular(6),
                      ),
                    ),
                    padding: const pw.EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 6,
                    ),
                    child: pw.Row(
                      mainAxisAlignment: pw.MainAxisAlignment.center,
                      children: [
                        pw.Text(
                          'ISSUED CERTIFICATE',
                          style: pw.TextStyle(
                            font: fontBold,
                            fontSize: 9,
                            color: _validGreen,
                            letterSpacing: 1.0,
                          ),
                        ),
                        pw.Text(
                          "  -  Not revoked in the loaded server record.",
                          style: pw.TextStyle(
                            font: fontRegular,
                            fontSize: 9,
                            color: _validGreen,
                          ),
                        ),
                      ],
                    ),
                  ),

                // Metadata Row
                pw.Container(
                  padding: const pw.EdgeInsets.all(12),
                  decoration: pw.BoxDecoration(
                    color: _brandLightBg,
                    border: pw.Border.all(color: PdfColors.grey300, width: 0.8),
                    borderRadius: const pw.BorderRadius.all(
                      pw.Radius.circular(6),
                    ),
                  ),
                  child: pw.Row(
                    mainAxisAlignment: pw.MainAxisAlignment.spaceAround,
                    children: [
                      pw.Column(
                        crossAxisAlignment: pw.CrossAxisAlignment.start,
                        children: [
                          pw.Text(
                            'Certificate Number',
                            style: pw.TextStyle(
                              font: fontRegular,
                              fontSize: 8,
                              color: PdfColors.grey600,
                            ),
                          ),
                          pw.SizedBox(height: 2),
                          pw.Text(
                            _safeText(data.certificateNumber),
                            style: pw.TextStyle(
                              font: fontMonoBold,
                              fontFallback: [fontBold],
                              fontSize: 10,
                              color: PdfColors.black,
                            ),
                          ),
                        ],
                      ),
                      pw.Column(
                        crossAxisAlignment: pw.CrossAxisAlignment.start,
                        children: [
                          pw.Text(
                            'Issued On',
                            style: pw.TextStyle(
                              font: fontRegular,
                              fontSize: 8,
                              color: PdfColors.grey600,
                            ),
                          ),
                          pw.SizedBox(height: 2),
                          pw.Text(
                            _formatDate(data.issuedAt),
                            style: pw.TextStyle(
                              font: fontBold,
                              fontSize: 10,
                              color: PdfColors.black,
                            ),
                          ),
                        ],
                      ),
                      pw.Column(
                        crossAxisAlignment: pw.CrossAxisAlignment.start,
                        children: [
                          pw.Text(
                            'Recorded Status',
                            style: pw.TextStyle(
                              font: fontRegular,
                              fontSize: 8,
                              color: PdfColors.grey600,
                            ),
                          ),
                          pw.SizedBox(height: 2),
                          pw.Text(
                            data.isRevoked ? 'REVOKED' : 'NOT REVOKED',
                            style: pw.TextStyle(
                              font: fontBold,
                              fontSize: 10,
                              color: data.isRevoked ? _revokedRed : _validGreen,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),

                // Local-copy notice (not a signature or verification seal)
                pw.Column(
                  children: [
                    pw.Text(
                      "LOCAL PRINTABLE COPY  *  Garden's Need Training",
                      style: pw.TextStyle(
                        font: fontBold,
                        fontSize: 9,
                        color: _brandDarkGreen,
                      ),
                    ),
                    pw.SizedBox(height: 2),
                    pw.Text(
                      'Status reflects the loaded server record and may change. Check the current record in the app.',
                      style: pw.TextStyle(
                        font: fontRegular,
                        fontSize: 7.5,
                        color: PdfColors.grey600,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          );
        },
      ),
    );

    return pdf.save();
  }

  /// Returns [input] unchanged.
  ///
  /// The certificate PDF is now rendered with NotoSansDevanagari (production)
  /// or a caller-injected TrueType font (tests). Both have full Unicode coverage
  /// for Latin and Devanagari. Authoritative certificate data -- employee names,
  /// course titles, dates -- must be preserved exactly as supplied by the server.
  /// No transliteration, normalisation or character substitution is applied.
  static String _safeText(String input) => input;

  static String _formatDate(DateTime dt) {
    final local = dt.toLocal();
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    final m = months[local.month - 1];
    return '$m ${local.day}, ${local.year}';
  }
}
