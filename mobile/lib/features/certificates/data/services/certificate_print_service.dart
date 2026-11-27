import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pdf/pdf.dart';
import 'package:printing/printing.dart';
import 'package:training_app/core/errors/api_error.dart';
import 'package:training_app/features/certificates/data/services/certificate_pdf_generator.dart';
import 'package:training_app/features/certificates/domain/models/certificate_print_data.dart';

/// Contract for printing and PDF generation of certificates.
abstract class CertificatePrintService {
  /// Generates a local printable copy from the supplied server record.
  Future<Uint8List> generatePdf(
    CertificatePrintData data, {
    PdfPageFormat format = PdfPageFormat.a4,
  });

  /// Triggers the native platform print preview and PDF export flow.
  /// Returns `true` if printing completed or was sent to spooler, `false` if dismissed/cancelled.
  /// [canPrint] is rechecked after generation and before supplying native layout
  /// bytes. It cannot recall a copy already handed to the external print system.
  Future<bool> printCertificate(
    CertificatePrintData data, {
    PdfPageFormat format = PdfPageFormat.a4,
    bool Function()? canPrint,
  });
}

/// Production implementation leveraging standard `pdf` layout and native `printing` plugin.
class PlatformCertificatePrintService implements CertificatePrintService {
  final CertificatePdfGenerator generator;

  const PlatformCertificatePrintService({
    this.generator = const CertificatePdfGenerator(),
  });

  @override
  Future<Uint8List> generatePdf(
    CertificatePrintData data, {
    PdfPageFormat format = PdfPageFormat.a4,
  }) {
    return generator.generate(data, format: format);
  }

  @override
  Future<bool> printCertificate(
    CertificatePrintData data, {
    PdfPageFormat format = PdfPageFormat.a4,
    bool Function()? canPrint,
  }) async {
    final bytes = await generatePdf(data, format: format);
    if (canPrint?.call() == false) return false;
    return Printing.layoutPdf(
      onLayout: (_) async {
        if (canPrint?.call() == false) {
          throw ApiError(
            message:
                'The print context changed. Reopen the certificate to print.',
            code: 'print_cancelled',
          );
        }
        return bytes;
      },
      name: 'Certificate_${data.certificateNumber}',
      format: format,
    );
  }
}

/// Riverpod provider for certificate printing capabilities.
final certificatePrintServiceProvider = Provider<CertificatePrintService>((
  ref,
) {
  return const PlatformCertificatePrintService();
});
