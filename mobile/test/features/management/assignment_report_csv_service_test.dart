import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:training_app/core/errors/api_error.dart';
import 'package:training_app/features/management/data/services/assignment_report_csv_service.dart';
import 'package:training_app/features/management/presentation/models/assignment_report_view_data.dart';

void main() {
  const service = AssignmentReportCsvService();

  group('AssignmentReportCsvService - Formula Defanging', () {
    test('defangs formula prefixes = + - @', () {
      expect(AssignmentReportCsvService.defangFormula('=1+1'), "'=1+1");
      expect(
        AssignmentReportCsvService.defangFormula('+SUM(1,1)'),
        "'+SUM(1,1)",
      );
      expect(AssignmentReportCsvService.defangFormula('-1+2'), "'-1+2");
      expect(
        AssignmentReportCsvService.defangFormula('@SUM(1,1)'),
        "'@SUM(1,1)",
      );
    });

    test('defangs formulas preceded by whitespace or control characters', () {
      expect(AssignmentReportCsvService.defangFormula(' =1+1'), "' =1+1");
      expect(AssignmentReportCsvService.defangFormula('\t=1+1'), "'\t=1+1");
      expect(AssignmentReportCsvService.defangFormula(' \t=1+1'), "' \t=1+1");
      expect(AssignmentReportCsvService.defangFormula('\u00A0+1'), "'\u00A0+1");
      expect(
        AssignmentReportCsvService.defangFormula('\x00@SUM(1,1)'),
        "'\x00@SUM(1,1)",
      );
      expect(AssignmentReportCsvService.defangFormula('\r\n-cmd'), "'\r\n-cmd");
    });

    test('preserves legitimate text without formula prefixes', () {
      expect(AssignmentReportCsvService.defangFormula('John Doe'), 'John Doe');
      expect(AssignmentReportCsvService.defangFormula('EMP-001'), 'EMP-001');
      expect(AssignmentReportCsvService.defangFormula('12345'), '12345');
      expect(AssignmentReportCsvService.defangFormula(''), '');
      expect(AssignmentReportCsvService.defangFormula('   '), '   ');
    });
  });

  group('AssignmentReportCsvService - RFC 4180 Cell Formatting', () {
    test(
      'wraps cells containing commas, quotes, and newlines in double quotes',
      () {
        expect(
          AssignmentReportCsvService.formatCell('North, South'),
          '"North, South"',
        );
        expect(
          AssignmentReportCsvService.formatCell('Role "A"'),
          '"Role ""A"""',
        );
        expect(
          AssignmentReportCsvService.formatCell('Line 1\nLine 2'),
          '"Line 1\nLine 2"',
        );
        expect(
          AssignmentReportCsvService.formatCell('Line 1\r\nLine 2'),
          '"Line 1\r\nLine 2"',
        );
      },
    );

    test(
      'quotes cells that combine formula defanging and delimiter characters',
      () {
        expect(AssignmentReportCsvService.formatCell('=1+1,2'), '"\'=1+1,2"');
        expect(
          AssignmentReportCsvService.formatCell('="quoted"'),
          '"\'=""quoted"""',
        );
      },
    );

    test('leaves plain cells unquoted', () {
      expect(AssignmentReportCsvService.formatCell('Operations'), 'Operations');
      expect(AssignmentReportCsvService.formatCell('Completed'), 'Completed');
    });
  });

  group('AssignmentReportCsvService - CSV Generation', () {
    test('matches the server-authoritative 11-column export schema', () {
      expect(AssignmentReportCsvService.csvHeaders, [
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
      ]);

      const item = AssignmentReportItemViewData(
        id: 1,
        employeeName: 'Alice Smith',
        employeeCode: 'EMP-001',
        departmentName: 'Safety',
        jobRoleName: 'Technician',
        trainingTitle: 'Hazard Awareness',
        versionTitle: 'Core Safety',
        versionNumber: 2,
        status: 'COMPLETED',
        statusDisplay: 'Completed',
        isOverdue: false,
      );
      expect(service.rowCells(item), [
        'Alice Smith',
        'Safety',
        'Technician',
        'Hazard Awareness',
        'Core Safety · Version 2',
        '',
        '',
        'Completed',
        'No',
        '',
        'Not issued',
      ]);
    });

    test('produces header-only CSV when items list is empty', () {
      final csv = service.generateCsv([]);
      expect(
        csv,
        'Employee,Department,Job role,Training,Version,Assigned,Deadline,Status,Overdue,Completed,Certificate\r\n',
      );
    });

    test('formats rows with correct columns, ISO dates, overdue flag, and certificate status', () {
      final assignedAt = DateTime.utc(2026, 1, 15, 10, 30);
      final dueAt = DateTime.utc(2026, 2, 15, 17, 0);
      final completedAt = DateTime.utc(2026, 2, 10, 14, 0);

      final items = [
        AssignmentReportItemViewData(
          id: 1,
          employeeName: 'Alice Smith',
          employeeCode: 'EMP-001',
          departmentName: 'Safety',
          jobRoleName: 'Technician',
          trainingTitle: 'Hazard Awareness',
          versionTitle: 'Core Safety',
          versionNumber: 2,
          status: 'COMPLETED',
          statusDisplay: 'Completed',
          isOverdue: false,
          assignedAt: assignedAt,
          dueAt: dueAt,
          completedAt: completedAt,
          certificateId: 101,
          certificateNumber: 'CERT-001',
          isCertificateRevoked: false,
        ),
        AssignmentReportItemViewData(
          id: 2,
          employeeName: 'Bob, Jones',
          employeeCode: 'EMP-002',
          departmentName: 'Operations',
          jobRoleName: 'Operator "B"',
          trainingTitle: '=Formula Hazard',
          versionTitle: 'Standard',
          versionNumber: 1,
          status: 'IN_PROGRESS',
          statusDisplay: 'In progress',
          isOverdue: true,
          assignedAt: assignedAt,
          dueAt: dueAt,
          completedAt: null,
          certificateId: null,
          certificateNumber: null,
          isCertificateRevoked: null,
        ),
        AssignmentReportItemViewData(
          id: 3,
          employeeName: 'Charlie Brown',
          employeeCode: 'EMP-003',
          departmentName: 'Logistics',
          jobRoleName: 'Driver',
          trainingTitle: 'Forklift Safety',
          versionTitle: 'Standard',
          versionNumber: 1,
          status: 'COMPLETED',
          statusDisplay: 'Completed',
          isOverdue: false,
          assignedAt: assignedAt,
          dueAt: null,
          completedAt: completedAt,
          certificateId: 102,
          certificateNumber: 'CERT-002',
          isCertificateRevoked: true,
        ),
      ];

      final csv = service.generateCsv(items);
      final lines = csv.split('\r\n');

      expect(
        lines.length,
        5,
      ); // header + 3 rows + trailing empty string from split
      expect(
        lines[0],
        'Employee,Department,Job role,Training,Version,Assigned,Deadline,Status,Overdue,Completed,Certificate',
      );

      // Row 1: Alice (Issued certificate, completed, not overdue)
      expect(
        lines[1],
        'Alice Smith,Safety,Technician,Hazard Awareness,Core Safety · Version 2,2026-01-15T10:30:00.000Z,2026-02-15T17:00:00.000Z,Completed,No,2026-02-10T14:00:00.000Z,Issued',
      );

      // Row 2: Bob (comma in name, quotes in job role, formula in training title, overdue, no certificate)
      expect(
        lines[2],
        '"Bob, Jones",Operations,"Operator ""B""",\'=Formula Hazard,Standard · Version 1,2026-01-15T10:30:00.000Z,2026-02-15T17:00:00.000Z,In progress,Yes,,Not issued',
      );

      // Row 3: Charlie (Revoked certificate, null deadline)
      expect(
        lines[3],
        'Charlie Brown,Logistics,Driver,Forklift Safety,Standard · Version 1,2026-01-15T10:30:00.000Z,,Completed,No,2026-02-10T14:00:00.000Z,Revoked',
      );
    });

    test('generates valid UTF-8 bytes', () {
      final items = [
        const AssignmentReportItemViewData(
          id: 1,
          employeeName: 'José Müller · 👷',
          employeeCode: 'EMP-009',
          departmentName: 'Warehouse',
          jobRoleName: 'Specialist',
          trainingTitle: 'Safety & Health',
          versionTitle: 'V1',
          versionNumber: 1,
          status: 'ASSIGNED',
          statusDisplay: 'Assigned',
          isOverdue: false,
        ),
      ];

      final bytes = service.generateCsvBytes(items);
      final decoded = utf8.decode(bytes);

      expect(decoded.contains('José Müller · 👷'), isTrue);
      expect(decoded.endsWith('\r\n'), isTrue);
    });
  });

  group('ReportFileSaver and ReportFileSaveResult Contract', () {
    test('distinguishes saved, shared, and cancelled statuses accurately', () {
      const savedResult = ReportFileSaveResult.saved(
        savedPath: '/downloads/report.csv',
      );
      expect(savedResult.isSaved, isTrue);
      expect(savedResult.isShared, isFalse);
      expect(savedResult.isCancelled, isFalse);
      expect(savedResult.savedPath, '/downloads/report.csv');

      const sharedResult = ReportFileSaveResult.shared(
        message: 'Share chooser displayed',
      );
      expect(sharedResult.isSaved, isFalse);
      expect(sharedResult.isShared, isTrue);
      expect(sharedResult.isCancelled, isFalse);
      expect(sharedResult.savedPath, isNull);

      const cancelledResult = ReportFileSaveResult.cancelled();
      expect(cancelledResult.isSaved, isFalse);
      expect(cancelledResult.isShared, isFalse);
      expect(cancelledResult.isCancelled, isTrue);
      expect(cancelledResult.savedPath, isNull);
    });

    test(
      'PlatformReportFileSaver rejects non-csv filename and invalid MIME type',
      () async {
        const saver = PlatformReportFileSaver();
        final dummyBytes = Uint8List.fromList([1, 2, 3]);

        expect(
          () => saver.saveFile(
            bytes: dummyBytes,
            filename: 'report.pdf',
            mimeType: 'text/csv',
          ),
          throwsA(isA<ArgumentError>()),
        );

        expect(
          () => saver.saveFile(
            bytes: dummyBytes,
            filename: 'report.csv',
            mimeType: 'application/pdf',
          ),
          throwsA(isA<ArgumentError>()),
        );
      },
    );
  });

  group('PlatformReportFileSaver - Native Channel Integration', () {
    TestWidgetsFlutterBinding.ensureInitialized();
    const channel = MethodChannel('gardensneed/file_saver');
    final dummyBytes = Uint8List.fromList([10, 20, 30]);

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test(
      'invokes saveFile channel and returns saved result on success',
      () async {
        MethodCall? capturedCall;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async {
              capturedCall = call;
              return {
                'status': 'saved',
                'path': 'content://com.android.providers.downloads.documents/document/123',
                'displayName': 'assignment-report-2026-11-16.csv',
                'bytesWritten': 3,
              };
            });

        const saver = PlatformReportFileSaver();
        final result = await saver.saveFile(
          bytes: dummyBytes,
          filename: 'assignment-report-2026-11-16.csv',
          mimeType: 'text/csv',
        );

        expect(capturedCall, isNotNull);
        expect(capturedCall!.method, 'saveFile');
        expect(
          capturedCall!.arguments['filename'],
          'assignment-report-2026-11-16.csv',
        );
        expect(capturedCall!.arguments['mimeType'], 'text/csv');
        expect(capturedCall!.arguments['bytes'], dummyBytes);

        expect(result.isSaved, isTrue);
        expect(result.savedPath, contains('content://'));
      },
    );

    test(
      'returns cancelled result when native channel reports cancelled status',
      () async {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async {
              return {'status': 'cancelled'};
            });

        const saver = PlatformReportFileSaver();
        final result = await saver.saveFile(
          bytes: dummyBytes,
          filename: 'report.csv',
          mimeType: 'text/csv',
        );

        expect(result.isCancelled, isTrue);
        expect(result.isSaved, isFalse);
      },
    );

    test('returns cancelled result when native channel throws CANCELLED PlatformException', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            throw PlatformException(
              code: 'CANCELLED',
              message: 'User dismissed',
            );
          });

      const saver = PlatformReportFileSaver();
      final result = await saver.saveFile(
        bytes: dummyBytes,
        filename: 'report.csv',
        mimeType: 'text/csv',
      );

      expect(result.isCancelled, isTrue);
    });

    test(
      'throws ApiError 409 when native channel reports ALREADY_ACTIVE',
      () async {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async {
              throw PlatformException(
                code: 'ALREADY_ACTIVE',
                message: 'A file save operation is already in progress',
              );
            });

        const saver = PlatformReportFileSaver();
        expect(
          () => saver.saveFile(
            bytes: dummyBytes,
            filename: 'report.csv',
            mimeType: 'text/csv',
          ),
          throwsA(
            isA<ApiError>()
                .having((e) => e.statusCode, 'statusCode', 409)
                .having(
                  (e) => e.message,
                  'message',
                  contains('already in progress'),
                ),
          ),
        );
      },
    );

    test(
      'throws ApiError 400 when native write fails with WRITE_FAILED',
      () async {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async {
              throw PlatformException(
                code: 'WRITE_FAILED',
                message: 'Disk full or permission denied',
              );
            });

        const saver = PlatformReportFileSaver();
        expect(
          () => saver.saveFile(
            bytes: dummyBytes,
            filename: 'report.csv',
            mimeType: 'text/csv',
          ),
          throwsA(
            isA<ApiError>()
                .having((e) => e.statusCode, 'statusCode', 400)
                .having((e) => e.message, 'message', contains('Disk full')),
          ),
        );
      },
    );

    for (final result in <Map<String, dynamic>>[
      {},
      {'status': 'unknown'},
      {
        'status': 'saved',
        'path': 'content://documents/report',
        'bytesWritten': 2,
      },
      {
        'status': 'saved',
        'path': 'content://documents/report',
        'bytesWritten': 4,
      },
      {'status': 'saved', 'path': 'content://documents/report'},
      {'status': 'saved', 'path': '/tmp/report.csv', 'bytesWritten': 3},
      {'status': 'saved', 'bytesWritten': 3},
    ]) {
      test('rejects unconfirmed or incomplete native save: $result', () async {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (_) async => result);
        await expectLater(
          const PlatformReportFileSaver().saveFile(
            bytes: dummyBytes,
            filename: 'report.csv',
            mimeType: 'text/csv',
          ),
          throwsA(
            isA<ApiError>().having(
              (e) => e.code,
              'code',
              'invalid_save_result',
            ),
          ),
        );
      });
    }

    test('null native result preserves cancellation semantics', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (_) async => null);
      final result = await const PlatformReportFileSaver().saveFile(
        bytes: dummyBytes,
        filename: 'report.csv',
        mimeType: 'text/csv',
      );
      expect(result.isCancelled, isTrue);
      expect(result.isSaved, isFalse);
    });

    test('throws ApiError 501 when native channel is missing without silent fallback', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            throw MissingPluginException();
          });

      const saver = PlatformReportFileSaver();
      expect(
        () => saver.saveFile(
          bytes: dummyBytes,
          filename: 'report.csv',
          mimeType: 'text/csv',
        ),
        throwsA(
          isA<ApiError>()
              .having((e) => e.statusCode, 'statusCode', 501)
              .having(
                (e) => e.message,
                'message',
                contains('not supported or not configured'),
              ),
        ),
      );
    });
  });
}
