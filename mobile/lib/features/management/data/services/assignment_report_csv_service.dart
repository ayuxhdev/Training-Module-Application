import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:training_app/core/errors/api_error.dart';
import 'package:training_app/features/management/presentation/models/assignment_report_view_data.dart';

/// Represents the platform result of a file save or export operation.
enum ReportFileSaveStatus {
  /// File was saved directly to the device filesystem/storage via native Save As or file creation.
  saved,

  /// A platform sharing or intent dialog was opened (the user was handed off to an external app/chooser),
  /// but confirmation of an actual written file cannot be verified by the platform API.
  shared,

  /// The user dismissed, cancelled, or backed out of the native save/share flow.
  cancelled,
}

/// Structured outcome of a [ReportFileSaver.saveFile] operation.
class ReportFileSaveResult {
  final ReportFileSaveStatus status;
  final String? savedPath;
  final String? message;

  const ReportFileSaveResult.saved({this.savedPath, this.message})
    : status = ReportFileSaveStatus.saved;

  const ReportFileSaveResult.shared({this.message})
    : status = ReportFileSaveStatus.shared,
      savedPath = null;

  const ReportFileSaveResult.cancelled({this.message})
    : status = ReportFileSaveStatus.cancelled,
      savedPath = null;

  bool get isSaved => status == ReportFileSaveStatus.saved;
  bool get isShared => status == ReportFileSaveStatus.shared;
  bool get isCancelled => status == ReportFileSaveStatus.cancelled;
}

/// Contract for saving or exporting generated report files using the platform's
/// native document/save flow (e.g. Android ACTION_CREATE_DOCUMENT "Save As" flow)
/// without requesting unrestricted external storage permissions.
abstract class ReportFileSaver {
  /// Presents the platform document Save As or export interface.
  ///
  /// [bytes] contains raw UTF-8 CSV content.
  /// [filename] must end with `.csv`.
  /// [mimeType] must be `text/csv`.
  Future<ReportFileSaveResult> saveFile({
    required Uint8List bytes,
    required String filename,
    required String mimeType,
  });
}

/// Production implementation leveraging native platform channel for Android
/// Storage Access Framework (ACTION_CREATE_DOCUMENT) Save As flow.
class PlatformReportFileSaver implements ReportFileSaver {
  static const MethodChannel _channel = MethodChannel('gardensneed/file_saver');

  const PlatformReportFileSaver();

  @override
  Future<ReportFileSaveResult> saveFile({
    required Uint8List bytes,
    required String filename,
    required String mimeType,
  }) async {
    if (!filename.toLowerCase().endsWith('.csv')) {
      throw ArgumentError.value(
        filename,
        'filename',
        'CSV export filename must end with .csv',
      );
    }
    if (mimeType.toLowerCase() != 'text/csv') {
      throw ArgumentError.value(
        mimeType,
        'mimeType',
        'CSV export MIME type must be text/csv',
      );
    }

    try {
      final result = await _channel.invokeMapMethod<String, dynamic>(
        'saveFile',
        {'bytes': bytes, 'filename': filename, 'mimeType': mimeType},
      );

      if (result == null) {
        return const ReportFileSaveResult.cancelled();
      }

      final statusStr = result['status'];
      if (statusStr == 'cancelled') {
        return const ReportFileSaveResult.cancelled();
      }
      if (statusStr == 'shared') {
        return ReportFileSaveResult.shared(
          message: result['message'] as String?,
        );
      }
      final path = result['path'];
      final written = result['bytesWritten'];
      final destination = path is String ? Uri.tryParse(path) : null;
      if (statusStr != 'saved' ||
          written is! int ||
          written != bytes.length ||
          destination == null ||
          destination.scheme != 'content' ||
          destination.authority.isEmpty ||
          destination.path.isEmpty) {
        throw ApiError(
          message: 'The device did not confirm a complete CSV file save. Check the destination before trying again.',
          code: 'invalid_save_result',
        );
      }
      return ReportFileSaveResult.saved(
        savedPath: path as String,
        message: result['message'] is String
            ? result['message'] as String
            : null,
      );
    } on MissingPluginException {
      throw ApiError(
        message: 'Native CSV Save As flow is not supported or not configured on this device platform.',
        statusCode: 501,
      );
    } on PlatformException catch (e) {
      if (e.code == 'CANCELLED' || e.code == 'USER_CANCELLED') {
        return const ReportFileSaveResult.cancelled();
      }
      if (e.code == 'ALREADY_ACTIVE') {
        throw ApiError(
          message: e.message ?? 'A file save operation is already in progress.',
          statusCode: 409,
        );
      }
      throw ApiError(
        message: e.message ?? 'Failed to save CSV report file.',
        statusCode: 400,
      );
    }
  }
}

/// Riverpod provider for platform file saver. Can be overridden in tests.
final reportFileSaverProvider = Provider<ReportFileSaver>(
  (ref) => const PlatformReportFileSaver(),
);

/// Service responsible for serializing assignment report data into RFC 4180
/// compliant UTF-8 CSV, matching website reporting column semantics and
/// defending against spreadsheet formula injection.
class AssignmentReportCsvService {
  const AssignmentReportCsvService();

  static const List<String> csvHeaders = [
    'Employee',
    'Department',
    'Job role',
    'Training',
    'Version',
    'Assigned',
    'Deadline',
    'Status',
    'Overdue',
    'Completed',
    'Certificate',
  ];

  /// Defangs spreadsheet formula injection in a cell value.
  ///
  /// If the first non-whitespace, non-control character is one of `=+-@`,
  /// prefixes the string with `'` so spreadsheet software treats it as literal text.
  static String defangFormula(String value) {
    var index = 0;
    while (index < value.length) {
      final code = value.codeUnitAt(index);
      if (code <= 0x20 || (code >= 0x7F && code <= 0x9F) || code == 0x00A0) {
        index++;
      } else {
        break;
      }
    }
    if (index < value.length) {
      final firstChar = value[index];
      if (firstChar == '=' ||
          firstChar == '+' ||
          firstChar == '-' ||
          firstChar == '@') {
        return "'$value";
      }
    }
    return value;
  }

  /// Formats a single CSV cell according to RFC 4180 rules.
  static String formatCell(String value) {
    final safe = defangFormula(value);
    if (safe.contains(',') ||
        safe.contains('"') ||
        safe.contains('\n') ||
        safe.contains('\r')) {
      final escaped = safe.replaceAll('"', '""');
      return '"$escaped"';
    }
    return safe;
  }

  /// Extracts the formatted row cells for a single report item.
  List<String> rowCells(AssignmentReportItemViewData item) {
    final String certificateStatus;
    if (item.hasCertificate || item.isCertificateRevoked != null) {
      certificateStatus = item.isCertificateRevoked == true
          ? 'Revoked'
          : 'Issued';
    } else {
      certificateStatus = 'Not issued';
    }

    return [
      item.safeEmployeeName,
      item.departmentName,
      item.jobRoleName,
      item.safeTrainingTitle,
      '${item.safeVersionTitle} · Version ${item.versionNumber}',
      item.assignedAt?.toIso8601String() ?? '',
      item.dueAt?.toIso8601String() ?? '',
      item.statusDisplay,
      item.isOverdue ? 'Yes' : 'No',
      item.completedAt?.toIso8601String() ?? '',
      certificateStatus,
    ];
  }

  /// Serializes report items into a valid RFC 4180 CSV string with CRLF line endings.
  String generateCsv(List<AssignmentReportItemViewData> items) {
    final buffer = StringBuffer();
    buffer.write(csvHeaders.map(formatCell).join(','));
    buffer.write('\r\n');
    for (final item in items) {
      buffer.write(rowCells(item).map(formatCell).join(','));
      buffer.write('\r\n');
    }
    return buffer.toString();
  }

  /// Encodes report items into valid UTF-8 CSV bytes.
  Uint8List generateCsvBytes(List<AssignmentReportItemViewData> items) {
    final csv = generateCsv(items);
    return Uint8List.fromList(utf8.encode(csv));
  }
}

/// Riverpod provider for [AssignmentReportCsvService].
final assignmentReportCsvServiceProvider = Provider<AssignmentReportCsvService>(
  (ref) => const AssignmentReportCsvService(),
);
