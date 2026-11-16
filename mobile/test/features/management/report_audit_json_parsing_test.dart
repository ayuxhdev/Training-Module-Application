import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:training_app/core/presentation/components/api_error_view.dart';
import 'package:training_app/core/theme/app_theme.dart';
import 'package:training_app/features/management/presentation/models/assignment_report_view_data.dart';
import 'package:training_app/features/management/presentation/models/audit_log_view_data.dart';
import 'package:training_app/features/management/presentation/models/report_audit_json_parsers.dart';
import 'package:training_app/features/management/presentation/screens/assignment_report_screen.dart';
import 'package:training_app/features/management/presentation/screens/audit_log_screen.dart';

void main() {
  group('Task 1: AuditFilterActorOption.label duplicate prevention', () {
    test('identical display name and username does not duplicate label', () {
      const option = AuditFilterActorOption(
        id: 1,
        username: 'alice',
        displayName: 'alice',
      );
      expect(option.label, equals('alice'));
      expect(option.label, isNot(contains('(alice)')));
    });

    test(
      'distinct display name and username renders parenthesized username',
      () {
        const option = AuditFilterActorOption(
          id: 2,
          username: 'alice',
          displayName: 'Alice Cooper',
        );
        expect(option.label, equals('Alice Cooper (alice)'));
      },
    );

    test('empty display name renders bare username without parentheses', () {
      const option = AuditFilterActorOption(
        id: 3,
        username: 'alice',
        displayName: '',
      );
      expect(option.label, equals('alice'));
      expect(option.label, isNot(contains('(')));
    });

    test(
      'whitespace-only display name renders bare username without parentheses',
      () {
        const option = AuditFilterActorOption(
          id: 4,
          username: 'alice',
          displayName: '   ',
        );
        expect(option.label, equals('alice'));
        expect(option.label, isNot(contains('(')));
      },
    );

    test('empty username with nonempty display name renders display name', () {
      const option = AuditFilterActorOption(
        id: 5,
        username: '',
        displayName: 'Alice Cooper',
      );
      expect(option.label, equals('Alice Cooper'));
      expect(option.label, isNot(contains('(')));
    });

    test('both username and display name empty renders empty string', () {
      const option = AuditFilterActorOption(
        id: 6,
        username: '',
        displayName: '',
      );
      expect(option.label, equals(''));
    });
  });

  group('Task 2: TypedJsonReader contract validation', () {
    test('readRequiredInt throws FormatException on string or missing', () {
      expect(
        () => TypedJsonReader.readRequiredInt({'val': '2'}, 'val'),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => TypedJsonReader.readRequiredInt({}, 'val'),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => TypedJsonReader.readRequiredInt({'val': 0}, 'val', minValue: 1),
        throwsA(isA<FormatException>()),
      );
      expect(
        TypedJsonReader.readRequiredInt({'val': 2}, 'val', minValue: 1),
        equals(2),
      );
    });

    test('readRequiredBool throws FormatException on string or missing', () {
      expect(
        () => TypedJsonReader.readRequiredBool({'val': 'false'}, 'val'),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => TypedJsonReader.readRequiredBool({}, 'val'),
        throwsA(isA<FormatException>()),
      );
      expect(TypedJsonReader.readRequiredBool({'val': false}, 'val'), isFalse);
    });

    test(
      'readRequiredDateTime throws FormatException on null or invalid format',
      () {
        expect(
          () => TypedJsonReader.readRequiredDateTime({'val': null}, 'val'),
          throwsA(isA<FormatException>()),
        );
        expect(
          () => TypedJsonReader.readRequiredDateTime({
            'val': 'not-a-date',
          }, 'val'),
          throwsA(isA<FormatException>()),
        );
        expect(
          TypedJsonReader.readRequiredDateTime({
            'val': '2026-10-15T12:00:00Z',
          }, 'val'),
          isA<DateTime>(),
        );
      },
    );

    test('readOptionalDateTime handles null, omission, valid dates and rejects malformed values', () {
      expect(
        TypedJsonReader.readOptionalDateTime({'val': null}, 'val'),
        isNull,
      );
      expect(TypedJsonReader.readOptionalDateTime({}, 'val'), isNull);
      expect(
        TypedJsonReader.readOptionalDateTime({
          'val': '2026-10-15T12:00:00Z',
        }, 'val'),
        equals(DateTime.parse('2026-10-15T12:00:00Z')),
      );
      expect(
        () =>
            TypedJsonReader.readOptionalDateTime({'val': 'not-a-date'}, 'val'),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => TypedJsonReader.readOptionalDateTime({'val': 12345}, 'val'),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => TypedJsonReader.readOptionalDateTime({'val': false}, 'val'),
        throwsA(isA<FormatException>()),
      );
    });

    test('readEnumString validates allowed values strictly', () {
      const allowed = {'ASSIGNED', 'IN_PROGRESS', 'COMPLETED', 'CANCELLED'};
      expect(
        () => TypedJsonReader.readEnumString(
          {'status': 'invalid'},
          'status',
          allowed,
        ),
        throwsA(isA<FormatException>()),
      );
      expect(
        () =>
            TypedJsonReader.readEnumString({'status': 123}, 'status', allowed),
        throwsA(isA<FormatException>()),
      );
      expect(
        TypedJsonReader.readEnumString(
          {'status': 'in_progress'},
          'status',
          allowed,
        ),
        equals('IN_PROGRESS'),
      );
    });
  });

  group(
    'Task 2: AssignmentReportItemViewData.fromJson contract validation',
    () {
      Map<String, dynamic> validReportJson() => {
        'id': 101,
        'employee_name': 'Jane Doe',
        'employee_code': 'EMP-001',
        'department_name': 'Horticulture',
        'job_role_name': 'Grower',
        'training_title': 'Irrigation 101',
        'version_title': 'Basics v1',
        'version_number': 1,
        'status': 'IN_PROGRESS',
        'status_display': 'In progress',
        'is_overdue': false,
        'assigned_at': '2026-10-01T08:00:00Z',
        'due_at': '2026-11-01T08:00:00Z',
        'completed_at': null,
        'certificate_id': null,
        'certificate_number': null,
        'is_certificate_revoked': null,
      };

      test('parses valid API response completely', () {
        final item = AssignmentReportItemViewData.fromJson(validReportJson());
        expect(item.id, equals(101));
        expect(item.employeeName, equals('Jane Doe'));
        expect(item.versionNumber, equals(1));
        expect(item.status, equals('IN_PROGRESS'));
        expect(item.isOverdue, isFalse);
        expect(item.assignedAt, equals(DateTime.parse('2026-10-01T08:00:00Z')));
        expect(item.dueAt, equals(DateTime.parse('2026-11-01T08:00:00Z')));
        expect(item.completedAt, isNull);
        expect(item.certificateId, isNull);
      });

      test('throws FormatException when version_number is string "2"', () {
        final json = validReportJson()..['version_number'] = '2';
        expect(
          () => AssignmentReportItemViewData.fromJson(json),
          throwsA(isA<FormatException>()),
        );
      });

      test('throws FormatException when is_overdue is string "false"', () {
        final json = validReportJson()..['is_overdue'] = 'false';
        expect(
          () => AssignmentReportItemViewData.fromJson(json),
          throwsA(isA<FormatException>()),
        );
      });

      test('parses assigned_at as null when omitted or null in JSON', () {
        final json = validReportJson()..['assigned_at'] = null;
        final item = AssignmentReportItemViewData.fromJson(json);
        expect(item.assignedAt, isNull);

        final jsonOmitted = validReportJson()..remove('assigned_at');
        final itemOmitted = AssignmentReportItemViewData.fromJson(jsonOmitted);
        expect(itemOmitted.assignedAt, isNull);
      });

      test(
        'throws FormatException when assigned_at is malformed date string',
        () {
          final json = validReportJson()
            ..['assigned_at'] = 'invalid-timestamp-format';
          expect(
            () => AssignmentReportItemViewData.fromJson(json),
            throwsA(isA<FormatException>()),
          );
        },
      );

      test('throws FormatException when assigned_at is non-string type (int or bool)', () {
        final jsonInt = validReportJson()..['assigned_at'] = 1601539200;
        expect(
          () => AssignmentReportItemViewData.fromJson(jsonInt),
          throwsA(isA<FormatException>()),
        );

        final jsonBool = validReportJson()..['assigned_at'] = false;
        expect(
          () => AssignmentReportItemViewData.fromJson(jsonBool),
          throwsA(isA<FormatException>()),
        );
      });

      test('throws FormatException when status is invalid', () {
        final json = validReportJson()..['status'] = 'PENDING_APPROVAL';
        expect(
          () => AssignmentReportItemViewData.fromJson(json),
          throwsA(isA<FormatException>()),
        );
      });

      test('throws FormatException when missing required id', () {
        final json = validReportJson()..remove('id');
        expect(
          () => AssignmentReportItemViewData.fromJson(json),
          throwsA(isA<FormatException>()),
        );
      });

      test('throws FormatException when non-positive id', () {
        final json = validReportJson()..['id'] = 0;
        expect(
          () => AssignmentReportItemViewData.fromJson(json),
          throwsA(isA<FormatException>()),
        );
      });

      test('preserves genuinely optional fields when null or present', () {
        final jsonWithCompleted = validReportJson()
          ..['status'] = 'COMPLETED'
          ..['completed_at'] = '2026-10-20T10:00:00Z'
          ..['certificate_id'] = 55
          ..['certificate_number'] = 'CERT-0055'
          ..['is_certificate_revoked'] = false;

        final item = AssignmentReportItemViewData.fromJson(jsonWithCompleted);
        expect(item.isCompleted, isTrue);
        expect(item.completedAt, isNotNull);
        expect(item.certificateId, equals(55));
        expect(item.certificateNumber, equals('CERT-0055'));
        expect(item.isCertificateRevoked, isFalse);
      });
    },
  );

  group('Task 2: AuditLogEntryViewData.fromJson contract validation', () {
    Map<String, dynamic> validAuditJson() => {
      'id': 500,
      'occurred_at': '2026-10-10T14:30:00Z',
      'actor_label_snapshot': 'admin_user',
      'actor_id': 12,
      'action': 'certifications.certificate.revoked',
      'action_label': 'Certificate Revoked',
      'entity_type': 'certifications.certificate',
      'entity_label': 'Certificate',
      'entity_id': '45',
      'record_summary': 'Certificate #45',
      'reason': 'Issued in error',
      'changes': [
        {
          'field': 'revoked_at',
          'field_label': 'Revocation Date',
          'before_display': 'None',
          'after_display': '2026-10-10 14:30',
          'captured': true,
        },
      ],
      'detail_kind': 'changes',
      'snapshot_notice': null,
    };

    test('parses valid API response completely', () {
      final entry = AuditLogEntryViewData.fromJson(validAuditJson());
      expect(entry.id, equals(500));
      expect(entry.action, equals('certifications.certificate.revoked'));
      expect(entry.occurredAt, equals(DateTime.parse('2026-10-10T14:30:00Z')));
      expect(entry.actorId, equals(12));
      expect(entry.hasChanges, isTrue);
      expect(entry.changes.first.field, equals('revoked_at'));
    });

    test('throws FormatException on missing occurred_at timestamp', () {
      final json = validAuditJson()..remove('occurred_at');
      expect(
        () => AuditLogEntryViewData.fromJson(json),
        throwsA(isA<FormatException>()),
      );
    });

    test('throws FormatException on empty action', () {
      final json = validAuditJson()..['action'] = '';
      expect(
        () => AuditLogEntryViewData.fromJson(json),
        throwsA(isA<FormatException>()),
      );
    });

    test('throws FormatException on malformed changes list (not a list)', () {
      final json = validAuditJson()..['changes'] = 'none';
      expect(
        () => AuditLogEntryViewData.fromJson(json),
        throwsA(isA<FormatException>()),
      );
    });

    test('throws FormatException on malformed change item (not a map)', () {
      final json = validAuditJson()..['changes'] = ['invalid_string_item'];
      expect(
        () => AuditLogEntryViewData.fromJson(json),
        throwsA(isA<FormatException>()),
      );
    });

    test(
      'throws FormatException when captured in field change is string "true"',
      () {
        final changeJson = {
          'field': 'status',
          'field_label': 'Status',
          'before_display': 'DRAFT',
          'after_display': 'PUBLISHED',
          'captured': 'true', // Malformed type
        };
        expect(
          () => AuditFieldChangeViewData.fromJson(changeJson),
          throwsA(isA<FormatException>()),
        );
      },
    );
  });

  group('Task 2: Filter options deserializer contract validation', () {
    test('AssignmentReportFilterOptionsViewData throws FormatException on malformed version', () {
      final json = {
        'departments': [],
        'job_roles': [],
        'trainings': [],
        'training_versions': [
          {
            'id': '201', // String instead of int
            'training_id': 100,
            'version_number': 1,
            'title': 'V1',
          },
        ],
      };
      expect(
        () => AssignmentReportFilterOptionsViewData.fromJson(json),
        throwsA(isA<FormatException>()),
      );
    });

    test('AuditLogFilterOptionsViewData throws FormatException on malformed actor id', () {
      final json = {
        'actors': [
          {'id': 'not-an-int', 'username': 'alice', 'display_name': 'Alice'},
        ],
        'entity_types': [],
      };
      expect(
        () => AuditLogFilterOptionsViewData.fromJson(json),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group(
    'Task 2: Safe Failure UI upon malformed data without crashes or loops',
    () {
      testWidgets(
        'AssignmentReportScreen displays ApiErrorView and allows retry on malformed response',
        (tester) async {
          tester.view.physicalSize = const Size(800, 1400);
          tester.view.devicePixelRatio = 1.0;
          addTearDown(() {
            tester.view.resetPhysicalSize();
            tester.view.resetDevicePixelRatio();
          });

          var retried = false;
          await tester.pumpWidget(
            ProviderScope(
              child: MaterialApp(
                theme: AppTheme.lightTheme,
                home: AssignmentReportScreen(
                  isLoading: false,
                  error: const FormatException(
                    'Invalid assignment report version_number.',
                  ),
                  onRetry: () => retried = true,
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();

          expect(find.byType(ApiErrorView), findsOneWidget);
          expect(find.text('Unable to load this page'), findsOneWidget);
          expect(find.text('Retry'), findsOneWidget);

          await tester.tap(find.text('Retry'));
          await tester.pumpAndSettle();
          expect(retried, isTrue);
        },
      );

      testWidgets(
        'AuditLogScreen displays ApiErrorView and allows retry on malformed response',
        (tester) async {
          tester.view.physicalSize = const Size(800, 1400);
          tester.view.devicePixelRatio = 1.0;
          addTearDown(() {
            tester.view.resetPhysicalSize();
            tester.view.resetDevicePixelRatio();
          });

          var retried = false;
          await tester.pumpWidget(
            ProviderScope(
              child: MaterialApp(
                theme: AppTheme.lightTheme,
                home: AuditLogScreen(
                  isLoading: false,
                  error: const FormatException(
                    'Invalid audit log occurred_at.',
                  ),
                  onRetry: () => retried = true,
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();

          expect(find.byType(ApiErrorView), findsOneWidget);
          expect(find.text('Unable to load this page'), findsOneWidget);
          expect(find.text('Retry'), findsOneWidget);

          await tester.tap(find.text('Retry'));
          await tester.pumpAndSettle();
          expect(retried, isTrue);
        },
      );
    },
  );
}
