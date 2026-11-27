import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:training_app/features/certificates/data/services/certificate_pdf_generator.dart';
import 'package:training_app/features/certificates/domain/models/certificate_detail.dart';
import 'package:training_app/features/certificates/domain/models/certificate_print_data.dart';
import 'package:training_app/features/management/domain/models/management_models.dart';

// Helper to load font binary assets whether running from mobile/ or repository root.
Uint8List _loadFontBytes(String filename) {
  for (final candidate in [
    'assets/fonts/$filename',
    'mobile/assets/fonts/$filename',
  ]) {
    final file = File(candidate);
    if (file.existsSync()) {
      return file.readAsBytesSync();
    }
  }
  throw StateError('Could not find font asset $filename on disk');
}

class _PdfDecoded {
  final String text;
  final Set<int> codepoints;
  const _PdfDecoded(this.text, this.codepoints);
}

_PdfDecoded _decodePdfContent(Uint8List bytes) {
  final raw = latin1.decode(bytes);

  // 1. Index PDF objects: objNum -> object body text
  final objects = <int, String>{};
  for (final m in RegExp(r'(\d+)\s+\d+\s+obj\b(.*?)\bendobj', dotAll: true).allMatches(raw)) {
    final num = int.parse(m.group(1)!);
    objects[num] = m.group(2)!;
  }

  // 2. Extract and decompress streams for each object
  final streams = <int, String>{};
  for (final entry in objects.entries) {
    final body = entry.value;
    final streamMatch = RegExp(r'stream\r?\n', dotAll: true).firstMatch(body);
    final endStreamMatch = RegExp(r'\r?\nendstream', dotAll: true).firstMatch(body);
    if (streamMatch != null && endStreamMatch != null && endStreamMatch.start > streamMatch.end) {
      final streamRaw = body.substring(streamMatch.end, endStreamMatch.start);
      final streamBytes = Uint8List.fromList(streamRaw.codeUnits);
      final decodedBytes = body.contains('/FlateDecode')
          ? zlib.decode(streamBytes)
          : streamBytes;
      streams[entry.key] = latin1.decode(decodedBytes);
    }
  }

  // 3. Map font names (/F6, /F11, etc.) to their /ToUnicode CID -> char map,
  // and collect all mapped Unicode codepoints.
  final fontCmaps = <String, Map<String, String>>{};
  final allCodepoints = <int>{};
  for (final entry in objects.entries) {
    final body = entry.value;
    if (body.contains('/Type/Font') && body.contains('/Subtype/Type0')) {
      final nameMatch = RegExp(r'/Name/([A-Za-z0-9]+)').firstMatch(body);
      final toUnicodeMatch = RegExp(r'/ToUnicode\s+(\d+)\s+\d+\s+R').firstMatch(body);
      if (nameMatch != null && toUnicodeMatch != null) {
        final fontName = '/${nameMatch.group(1)!}';
        final cmapObjNum = int.parse(toUnicodeMatch.group(1)!);
        final cmapStream = streams[cmapObjNum] ?? '';
        final cmap = <String, String>{};
        for (final cm in RegExp(r'<([0-9a-fA-F]{4})>\s*<([0-9a-fA-F]{4})>').allMatches(cmapStream)) {
          final cid = cm.group(1)!.toUpperCase();
          final charCode = int.parse(cm.group(2)!, radix: 16);
          allCodepoints.add(charCode);
          cmap[cid] = String.fromCharCode(charCode);
        }
        fontCmaps[fontName] = cmap;
      }
    }
  }

  // 4. Extract text from page content streams (streams with BT and without /Length1 or /CIDInit)
  final extracted = <String>[];
  final tokenPattern = RegExp(r'(/F\d+)\s+[\d.]+\s+Tf|\(((?:\\.|[^\\()])*)\)|<([0-9a-fA-F]{4,})>');
  for (final entry in streams.entries) {
    final objNum = entry.key;
    final body = objects[objNum] ?? '';
    if (body.contains('/Length1') || body.contains('/CIDInit')) continue;
    final content = entry.value;
    if (!content.contains('BT')) continue;

    for (final block in RegExp(r'\bBT\b(.*?)\bET\b', dotAll: true).allMatches(content)) {
      final blockContent = block.group(1)!;
      final blockBuffer = StringBuffer();
      String? currentFont;
      for (final t in tokenPattern.allMatches(blockContent)) {
        if (t.group(1) != null) {
          currentFont = t.group(1)!;
        } else if (t.group(2) != null) {
          final lit = t.group(2)!.replaceAllMapped(RegExp(r'\\([()\\])'), (m) => m.group(1)!);
          blockBuffer.write(lit);
          allCodepoints.addAll(lit.runes);
        } else if (t.group(3) != null) {
          final hexStr = t.group(3)!;
          final cmap = fontCmaps[currentFont] ?? const {};
          for (var i = 0; i + 4 <= hexStr.length; i += 4) {
            final cid = hexStr.substring(i, i + 4).toUpperCase();
            if (cmap.containsKey(cid)) {
              blockBuffer.write(cmap[cid]);
            }
          }
        }
      }
      if (blockBuffer.isNotEmpty) {
        extracted.add(blockBuffer.toString());
      }
    }
  }

  expect(extracted, isNotEmpty, reason: 'Must inspect actual PDF content streams.');
  return _PdfDecoded(
    extracted.join(' ').replaceAll(RegExp(r'\s+'), ' '),
    allCodepoints,
  );
}

/// Extracts decoded text from PDF content streams.
///
/// Handles both:
/// 1. Type 1 fonts (literal strings in parentheses: `(...)`)
/// 2. Type 0 TrueType fonts (hex CIDs `<...>` mapped via their font's `/ToUnicode` CMap).
String renderedText(Uint8List bytes) => _decodePdfContent(bytes).text;

/// Returns the set of all Unicode codepoints mapped in embedded /ToUnicode CMaps.
Set<int> embeddedUnicodeCodepoints(Uint8List bytes) => _decodePdfContent(bytes).codepoints;

void main() {
  // Inject Helvetica/Courier (Type 1) to bypass rootBundle in the test VM.
  // Tests exercise all layout and content-stream logic without an asset binding.
  // The production rootBundle font path is documented separately below.
  final generator = CertificatePdfGenerator(
    regularFont: pw.Font.helvetica(),
    boldFont: pw.Font.helveticaBold(),
    monoFont: pw.Font.courier(),
    monoBoldFont: pw.Font.courierBold(),
  );

  CertificatePrintData sampleData({
    bool isRevoked = false,
    DateTime? revokedAt,
    String? revocationReason,
    String employeeName = 'Jane Doe',
    String employeeCode = 'EMP-001',
    String trainingTitle = 'Workplace Safety & Hazard Control',
    int versionNumber = 2,
    String certificateNumber = 'GN-CERT-10023',
    DateTime? issuedAt,
  }) {
    return CertificatePrintData(
      certificateId: 10,
      certificateNumber: certificateNumber,
      employeeName: employeeName,
      employeeCode: employeeCode,
      trainingTitle: trainingTitle,
      versionNumber: versionNumber,
      issuedAt: issuedAt ?? DateTime.utc(2026, 6, 15, 10, 30),
      isRevoked: isRevoked,
      revokedAt: revokedAt,
      revocationReason: revocationReason,
    );
  }

  group('CertificatePdfGenerator', () {
    test('PDF is a local copy without unsupported accreditation or verification claims', () async {
      final bytes = await generator.generate(sampleData());
      final printed = renderedText(bytes);
      expect(printed, contains('assigned training program'));
      expect(printed, contains('LOCAL PRINTABLE COPY'));
      expect(printed, contains('ISSUED CERTIFICATE'));
      expect(printed, contains('NOT REVOKED'));
      expect(printed, contains('loaded server record'));
      expect(printed, contains('may change'));
      for (final unsupported in [
        'accredited',
        'VERIFIED RECORD',
        'Authoritative Record',
        'official workforce verification',
        'digitally signed',
      ]) {
        expect(printed, isNot(contains(unsupported)));
      }
      expect(latin1.decode(bytes), isNot(contains('/ByteRange')));
    });

    test('PDF includes exact authorized metadata and pinned version', () async {
      final bytes = await generator.generate(
        sampleData(
          employeeName: 'Alice Green',
          employeeCode: 'EMP-987',
          trainingTitle: 'Organic Crop Management',
          versionNumber: 3,
          certificateNumber: 'GN-CERT-98701',
          issuedAt: DateTime.utc(2026, 6, 15),
        ),
      );
      final printed = renderedText(bytes);
      for (final value in [
        'Alice Green',
        'EMP-987',
        'Organic Crop Management',
        'Version 3',
        'GN-CERT-98701',
        'Jun 15, 2026',
      ]) {
        expect(printed, contains(value));
      }
    });

    test(
      'revoked PDF prominently preserves revocation date and reason',
      () async {
        final printed = renderedText(
          await generator.generate(
            sampleData(
              isRevoked: true,
              revokedAt: DateTime.utc(2026, 9, 20),
              revocationReason: 'Superseded by approved revision',
            ),
          ),
        );
        expect(printed, contains('REVOKED CREDENTIAL'));
        expect(printed, contains('Sep 20, 2026'));
        expect(printed, contains('Superseded by approved revision'));
        expect(printed, contains('NO LONGER VALID'));
        expect(printed, contains('LOCAL PRINTABLE COPY'));
        expect(printed, isNot(contains('NOT REVOKED')));
        expect(printed, isNot(contains('ISSUED CERTIFICATE')));
      },
    );

    test(
      'missing revocation timestamp never substitutes the issuance date',
      () async {
        final printed = renderedText(
          await generator.generate(sampleData(isRevoked: true)),
        );
        expect(printed, contains('REVOKED CREDENTIAL'));
        expect(printed, contains('Revocation date not available.'));
        expect(printed, isNot(contains('revoked on Jun 15, 2026')));
      },
    );

    test('employee and management mappings preserve server metadata without inventing fields', () {
      final json = <String, dynamic>{
        'id': 42,
        'certificate_number': 'GN-SERVER-42',
        'employee_name': 'Server Employee',
        'employee_code': 'SERVER-7',
        'training_title': 'Pinned Server Training',
        'version_number': 4,
        'issued_at': '2026-06-15T10:30:00Z',
        'is_revoked': true,
        'revoked_at': '2026-09-20T14:00:00Z',
        'revocation_reason': 'Server reason',
        'assignment_id': 17,
        'has_document': false,
      };
      final employee = CertificatePrintData.fromCertificateDetail(
        CertificateDetail.fromJson(json),
      );
      final management = CertificatePrintData.fromManagedCertificateDetail(
        ManagedCertificateDetail.fromJson(json),
      );
      for (final data in [employee, management]) {
        expect(data.certificateId, 42);
        expect(data.certificateNumber, 'GN-SERVER-42');
        expect(data.employeeName, 'Server Employee');
        expect(data.employeeCode, 'SERVER-7');
        expect(data.trainingTitle, 'Pinned Server Training');
        expect(data.versionNumber, 4);
        expect(data.issuedAt, DateTime.utc(2026, 6, 15, 10, 30));
        expect(data.isRevoked, isTrue);
        expect(data.revokedAt, DateTime.utc(2026, 9, 20, 14));
      }
      expect(
        employee.revocationReason,
        isNull,
      ); // Not exposed by learner contract.
      expect(management.revocationReason, 'Server reason');
    });

    test(
      'generates valid non-empty PDF bytes with correct PDF header',
      () async {
        final data = sampleData();
        final Uint8List bytes = await generator.generate(data);

        expect(bytes, isNotEmpty);
        // PDF documents start with '%PDF-'
        final header = ascii.decode(bytes.sublist(0, 5));
        expect(header, equals('%PDF-'));
      },
    );

    test(
      'valid certificate PDF contains required authoritative text',
      () async {
        final data = sampleData(
          employeeName: 'Alice Green',
          employeeCode: 'EMP-987',
          trainingTitle: 'Organic Crop Management',
          versionNumber: 3,
          certificateNumber: 'GN-CERT-98701',
        );

        final bytes = await generator.generate(data);
        final printed = renderedText(bytes);
        expect(printed, contains('Alice Green'));
        expect(printed, contains('EMP-987'));
        expect(printed, contains('Organic Crop Management'));
        expect(printed, contains('Version 3'));
        expect(printed, contains('GN-CERT-98701'));
      },
    );

    test(
      'revoked certificate PDF generates successfully with revocation details',
      () async {
        final data = sampleData(
          isRevoked: true,
          revokedAt: DateTime.utc(2026, 9, 20, 14, 0),
          revocationReason: 'Credential superseded by safety revision v3',
        );

        final bytes = await generator.generate(data);
        expect(bytes, isNotEmpty);
        final header = ascii.decode(bytes.sublist(0, 5));
        expect(header, equals('%PDF-'));
      },
    );

    test('handles extremely long employee and training text without overflow', () async {
      final data = sampleData(
        employeeName: 'Alexandria Bartholomew-Montgomery ' * 5,
        employeeCode: 'EMP-${'9876543210' * 5}',
        trainingTitle:
            'Advanced Comprehensive Horticultural Safety and Chemical Management ' *
            4,
        versionNumber: 12,
        certificateNumber: 'GN-CERT-${'1234567890' * 6}',
        isRevoked: true,
        revokedAt: DateTime.utc(2026, 10, 1),
        revocationReason:
            'Detailed compliance audit finding: procedural non-conformance recorded during quarterly inspection. ' *
            3,
      );

      final bytes = await generator.generate(data);
      expect(bytes, isNotEmpty);
      final header = ascii.decode(bytes.sublist(0, 5));
      expect(header, equals('%PDF-'));
    });

    test(
      'supports different standard page formats like Letter and A4',
      () async {
        final data = sampleData();
        final a4Bytes = await generator.generate(
          data,
          format: PdfPageFormat.a4,
        );
        final letterBytes = await generator.generate(
          data,
          format: PdfPageFormat.letter,
        );

        expect(a4Bytes, isNotEmpty);
        expect(letterBytes, isNotEmpty);
      },
    );

    test(
      'generates valid and revoked sample PDFs entirely in memory',
      () async {
        final validData = sampleData(
          employeeName: 'Sarah Connor',
          employeeCode: 'EMP-777',
          trainingTitle: 'Workplace Safety & Hazard Control',
          versionNumber: 3,
          certificateNumber: 'GN-CERT-00077',
        );
        final validBytes = await generator.generate(validData);

        final revokedData = sampleData(
          employeeName: 'Bob Vance',
          employeeCode: 'EMP-102',
          trainingTitle: 'Refrigeration Equipment Safety',
          versionNumber: 1,
          certificateNumber: 'GN-CERT-00102',
          isRevoked: true,
          revokedAt: DateTime.utc(2026, 8, 14, 16, 45),
          revocationReason:
              'Safety certification was falsified during annual review.',
        );
        final revokedBytes = await generator.generate(revokedData);

        final printedValid = renderedText(validBytes);
        expect(printedValid, contains('Sarah Connor'));
        expect(printedValid, contains('EMP-777'));
        expect(printedValid, contains('GN-CERT-00077'));

        final printedRevoked = renderedText(revokedBytes);
        expect(printedRevoked, contains('REVOKED CREDENTIAL'));
        expect(printedRevoked, contains('Bob Vance'));
        expect(printedRevoked, contains('EMP-102'));
        expect(printedRevoked, contains('GN-CERT-00102'));
        expect(
          printedRevoked,
          contains('Safety certification was falsified during annual review.'),
        );
      },
    );

    test('formats certificate issuance date consistently across local timezone boundaries', () async {
      final localDate = DateTime(2026, 6, 15, 14, 30);
      final bytes = await generator.generate(
        sampleData(issuedAt: localDate),
      );
      final printed = renderedText(bytes);
      expect(printed, contains('Jun 15, 2026'));
    });

    test('revocation date matches local calendar date semantics', () async {
      final localRevocation = DateTime(2026, 9, 20, 16, 45);
      final bytes = await generator.generate(
        sampleData(isRevoked: true, revokedAt: localRevocation),
      );
      final printed = renderedText(bytes);
      expect(printed, contains('Sep 20, 2026'));
    });

    test('formats certificate issuance date deterministically across all timezones for midday UTC dates', () async {
      // 12:00 UTC falls on June 15 across every world timezone (UTC-11 to UTC+12)
      final middayUtc = DateTime.utc(2026, 6, 15, 12, 0);
      final bytes = await generator.generate(
        sampleData(issuedAt: middayUtc),
      );
      final printed = renderedText(bytes);
      expect(printed, contains('Jun 15, 2026'));
    });

    test('generator supports custom font injection for Unicode rendering', () {
      final customGenerator = CertificatePdfGenerator(
        regularFont: pw.Font.courier(),
        boldFont: pw.Font.courierBold(),
      );
      expect(customGenerator.regularFont, isNotNull);
      expect(customGenerator.boldFont, isNotNull);
    });

    test('Type 1 font drops non-Latin Devanagari characters silently in content stream', () async {
      // Type 1 (Helvetica) cannot encode Devanagari codepoints.
      // package:pdf silently drops characters without a matching glyph.
      final type1Generator = CertificatePdfGenerator(
        regularFont: pw.Font.helvetica(),
        boldFont: pw.Font.helveticaBold(),
      );
      final bytes = await type1Generator.generate(
        sampleData(employeeName: 'राजेश कुमार'),
      );
      final printed = renderedText(bytes);
      // Type 1 fonts encode only Latin-1; Devanagari codepoints are silently dropped.
      expect(printed, isNot(contains('राजेश कुमार')));
    });

    test('bundled NotoSansDevanagari TTF retains actual Hindi employee name, course title and code', () async {
      final regBytes = _loadFontBytes('NotoSansDevanagari-Regular.ttf');
      final boldBytes = _loadFontBytes('NotoSansDevanagari-Bold.ttf');
      final ttfGenerator = CertificatePdfGenerator(
        regularFont: pw.Font.ttf(regBytes.buffer.asByteData()),
        boldFont: pw.Font.ttf(boldBytes.buffer.asByteData()),
      );

      final bytes = await ttfGenerator.generate(
        sampleData(
          employeeName: 'राजेश कुमार',
          trainingTitle: 'कार्यस्थल सुरक्षा एवं खतरा नियंत्रण',
          employeeCode: 'EMP-हिंदी-01',
        ),
      );

      final printed = renderedText(bytes);
      expect(printed, contains('राजेश कुमार'));
      expect(printed, contains('कार्यस्थल सुरक्षा'));
      expect(printed, contains('EMP-हिंदी-01'));

      final codepoints = embeddedUnicodeCodepoints(bytes);
      expect(codepoints, containsAll('राजेश कुमार'.replaceAll(' ', '').runes.toSet()));
      expect(codepoints, containsAll('कार्यस्थल सुरक्षा'.replaceAll(' ', '').runes.toSet()));
      expect(codepoints, containsAll('हिंदी'.runes.toSet()));
    });

    testWidgets('production rootBundle asset loading generates certificate with Devanagari codepoints', (tester) async {
      // Tests production CertificatePdfGenerator() with no injected fonts,
      // confirming assets/fonts/NotoSansDevanagari-*.ttf are loaded via rootBundle.
      const productionGenerator = CertificatePdfGenerator();

      final bytes = await tester.runAsync(() => productionGenerator.generate(
        sampleData(
          employeeName: 'राजेश कुमार',
          trainingTitle: 'कार्यस्थल सुरक्षा एवं खतरा नियंत्रण',
          employeeCode: 'EMP-हिंदी-01',
        ),
      ));

      expect(bytes, isNotNull);
      expect(bytes!, isNotEmpty);
      final printed = renderedText(bytes);
      expect(printed, contains('राजेश कुमार'));
      expect(printed, contains('कार्यस्थल सुरक्षा'));
      expect(printed, contains('EMP-हिंदी-01'));

      final codepoints = embeddedUnicodeCodepoints(bytes);
      expect(codepoints, containsAll('राजेश कुमार'.replaceAll(' ', '').runes.toSet()));
    });

    test('supports English, Hindi, and mixed employee codes and identifiers', () async {
      final regBytes = _loadFontBytes('NotoSansDevanagari-Regular.ttf');
      final boldBytes = _loadFontBytes('NotoSansDevanagari-Bold.ttf');
      final ttfGenerator = CertificatePdfGenerator(
        regularFont: pw.Font.ttf(regBytes.buffer.asByteData()),
        boldFont: pw.Font.ttf(boldBytes.buffer.asByteData()),
      );

      for (final code in ['EMP-001', 'EMP-हिंदी-01', 'GN-कर्मचारी-42', '10023']) {
        final bytes = await ttfGenerator.generate(
          sampleData(employeeCode: code),
        );
        final printed = renderedText(bytes);
        expect(printed, contains(code));
      }
    });

    test('exercises fallback font when monospace lacks Devanagari glyphs in certificate number', () async {
      final regBytes = _loadFontBytes('NotoSansDevanagari-Regular.ttf');
      final boldBytes = _loadFontBytes('NotoSansDevanagari-Bold.ttf');
      // fontMonoBold is Courier Bold (Type 1), which cannot render Hindi characters.
      // fontFallback is configured with fontBold (NotoSansDevanagari-Bold).
      final ttfGenerator = CertificatePdfGenerator(
        regularFont: pw.Font.ttf(regBytes.buffer.asByteData()),
        boldFont: pw.Font.ttf(boldBytes.buffer.asByteData()),
        monoBoldFont: pw.Font.courierBold(),
      );

      const hindiCertNumber = 'GN-प्रमाण-00123';
      final bytes = await ttfGenerator.generate(
        sampleData(certificateNumber: hindiCertNumber),
      );

      expect(bytes, isNotEmpty);
      final printed = renderedText(bytes);
      // Because fontMonoBold (Courier) falls back to fontBold (NotoSansDevanagari)
      // for Devanagari characters, package:pdf emits separate text runs for the fallback
      // glyphs. We check that the full certificate number is preserved.
      expect(printed.replaceAll(' ', ''), contains(hindiCertNumber.replaceAll(' ', '')));

      final codepoints = embeddedUnicodeCodepoints(bytes);
      expect(codepoints, containsAll('प्रमाण'.runes.toSet()));
    });

    test('handles extremely long names and titles without layout overflow or failure', () async {
      final regBytes = _loadFontBytes('NotoSansDevanagari-Regular.ttf');
      final boldBytes = _loadFontBytes('NotoSansDevanagari-Bold.ttf');
      final ttfGenerator = CertificatePdfGenerator(
        regularFont: pw.Font.ttf(regBytes.buffer.asByteData()),
        boldFont: pw.Font.ttf(boldBytes.buffer.asByteData()),
      );

      final longName = 'डॉ. राजेश कुमार शर्मा ' * 5; // ~110 chars
      final longTitle = 'औद्योगिक सुरक्षा, अग्नि सुरक्षा, एवं पर्यावरण प्रबंधन प्रशिक्षण कार्यक्रम ' * 3; // ~230 chars

      final bytes = await ttfGenerator.generate(
        sampleData(
          employeeName: longName.trim(),
          trainingTitle: longTitle.trim(),
        ),
      );

      expect(bytes, isNotEmpty);
      final printed = renderedText(bytes);
      expect(printed, contains('डॉ. राजेश कुमार शर्मा'));
      expect(printed, contains('औद्योगिक सुरक्षा'));
    });

    test('documents and preserves known Indic shaping limitation without failing codepoint retention', () async {
      // KNOWN LIMITATION: package:pdf does not apply OpenType GSUB ligature shaping
      // for complex Indic conjuncts (such as क्ष or त्र). All Unicode codepoints
      // are fully retained in the PDF CMap and content stream, allowing text searching
      // and extraction, but the visual glyphs are displayed in logical sequence
      // rather than fused as a ligature.
      final regBytes = _loadFontBytes('NotoSansDevanagari-Regular.ttf');
      final boldBytes = _loadFontBytes('NotoSansDevanagari-Bold.ttf');
      final ttfGenerator = CertificatePdfGenerator(
        regularFont: pw.Font.ttf(regBytes.buffer.asByteData()),
        boldFont: pw.Font.ttf(boldBytes.buffer.asByteData()),
      );

      const conjunctName = 'लक्ष्मी क्षेत्रीय'; // contains क्ष (क + ् + ष) and त्र (त + ् + र)
      final bytes = await ttfGenerator.generate(
        sampleData(employeeName: conjunctName),
      );

      final printed = renderedText(bytes);
      expect(printed, contains(conjunctName));

      final codepoints = embeddedUnicodeCodepoints(bytes);
      expect(codepoints, containsAll(conjunctName.replaceAll(' ', '').runes.toSet()));
    });
  });
}
