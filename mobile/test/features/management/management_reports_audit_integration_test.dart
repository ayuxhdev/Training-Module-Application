import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:training_app/core/errors/api_error.dart';
import 'package:training_app/core/network/dio_client.dart';
import 'package:training_app/core/presentation/components/api_error_view.dart';
import 'package:training_app/core/presentation/screens/workspace_screen.dart';
import 'package:training_app/core/router/app_router.dart';
import 'package:training_app/core/theme/app_theme.dart';
import 'package:training_app/features/auth/domain/models/auth_state.dart';
import 'package:training_app/features/auth/presentation/controllers/auth_controller.dart';
import 'package:training_app/features/management/data/repositories/management_repository.dart';
import 'package:training_app/features/management/domain/models/management_models.dart';
import 'package:training_app/features/management/presentation/controllers/management_controller.dart';
import 'package:training_app/features/management/presentation/models/assignment_report_view_data.dart';
import 'package:training_app/features/management/presentation/models/audit_log_view_data.dart';
import 'package:training_app/features/management/presentation/screens/assignment_report_screen.dart';
import 'package:training_app/features/management/presentation/screens/audit_log_screen.dart';
import 'package:training_app/features/notifications/presentation/controllers/notification_controller.dart';

import 'management_fixtures.dart';

class MockManagementRepository extends Mock implements ManagementRepository {}

class MockApiClient extends Mock implements ApiClient {}

class MockDio extends Mock implements Dio {}

class ZeroUnread extends NotificationUnreadController {
  @override
  Future<int?> build() async => 0;
}

Map<String, dynamic> sampleAssignmentReportItemJson({
  int id = 1,
  String employeeName = 'Alice Johnson',
  String employeeCode = 'EMP001',
  String? departmentName = 'Gardening Operations',
  String? jobRoleName = 'Senior Horticulturist',
  String trainingTitle = 'Greenhouse Safety Protocols',
  String versionTitle = 'Safety Standards v1',
  int versionNumber = 1,
  String status = 'COMPLETED',
  String statusDisplay = 'Completed',
  bool isOverdue = false,
  String assignedAt = '2026-10-01T09:00:00Z',
  String dueAt = '2026-11-01T09:00:00Z',
  String? completedAt = '2026-10-15T14:30:00Z',
  int? certificateId = 42,
  String? certificateNumber = 'CERT-2026-042',
  bool? isCertificateRevoked = false,
}) => {
  'id': id,
  'employee_name': employeeName,
  'employee_code': employeeCode,
  'department_name': departmentName,
  'job_role_name': jobRoleName,
  'training_title': trainingTitle,
  'version_title': versionTitle,
  'version_number': versionNumber,
  'status': status,
  'status_display': statusDisplay,
  'is_overdue': isOverdue,
  'assigned_at': assignedAt,
  'due_at': dueAt,
  'completed_at': completedAt,
  'certificate_id': certificateId,
  'certificate_number': certificateNumber,
  'is_certificate_revoked': isCertificateRevoked,
};

Map<String, dynamic> sampleAuditLogEntryJson({
  int id = 101,
  String occurredAt = '2026-10-15T10:00:00Z',
  String actorLabelSnapshot = 'Admin User (admin)',
  int? actorId = 1,
  String action = 'training.trainingassignment.created',
  String actionLabel = 'Training assignment created',
  String entityType = 'training.trainingassignment',
  String entityLabel = 'Training assignment',
  String entityId = '50',
  String? recordSummary = 'Alice Johnson assigned to Greenhouse Safety',
  String? reason = 'Annual compliance requirement',
  List<Map<String, dynamic>>? changes = const [
    {
      'field': 'status',
      'field_label': 'Status',
      'before_display': 'DRAFT',
      'after_display': 'ASSIGNED',
      'captured': true,
    },
  ],
  String detailKind = 'changes',
  String? snapshotNotice,
}) => {
  'id': id,
  'occurred_at': occurredAt,
  'actor_label_snapshot': actorLabelSnapshot,
  'actor_id': actorId,
  'action': action,
  'action_label': actionLabel,
  'entity_type': entityType,
  'entity_label': entityLabel,
  'entity_id': entityId,
  'record_summary': recordSummary,
  'reason': reason,
  'changes': changes,
  'detail_kind': detailKind,
  'snapshot_notice': snapshotNotice,
};

void setTestViewport(WidgetTester tester, [Size size = const Size(800, 2400)]) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    registerFallbackValue(const AssignmentReportFilterQuery());
    registerFallbackValue(const AuditLogFilterQuery());
  });

  group('1. Domain / Presentation Models JSON Mapping & Fail-Closed Validation', () {
    test('AssignmentReportItemViewData parses complete valid JSON', () {
      final json = sampleAssignmentReportItemJson();
      final item = AssignmentReportItemViewData.fromJson(json);

      expect(item.id, 1);
      expect(item.employeeName, 'Alice Johnson');
      expect(item.employeeCode, 'EMP001');
      expect(item.departmentName, 'Gardening Operations');
      expect(item.jobRoleName, 'Senior Horticulturist');
      expect(item.trainingTitle, 'Greenhouse Safety Protocols');
      expect(item.versionTitle, 'Safety Standards v1');
      expect(item.versionNumber, 1);
      expect(item.status, 'COMPLETED');
      expect(item.statusDisplay, 'Completed');
      expect(item.isOverdue, isFalse);
      expect(item.assignedAt, DateTime.parse('2026-10-01T09:00:00Z'));
      expect(item.dueAt, DateTime.parse('2026-11-01T09:00:00Z'));
      expect(item.completedAt, DateTime.parse('2026-10-15T14:30:00Z'));
      expect(item.certificateId, 42);
      expect(item.certificateNumber, 'CERT-2026-042');
      expect(item.isCertificateRevoked, isFalse);

      expect(item.hasCertificateIndicator, isTrue);
      expect(item.hasCertificate, isTrue);
    });

    test('AssignmentReportItemViewData parses minimal JSON with null optional fields', () {
      final json = {
        'id': 5,
        'employee_name': 'Bob Smith',
        'employee_code': 'EMP005',
        'department_name': null,
        'job_role_name': null,
        'training_title': 'Plant Care Basics',
        'version_title': null,
        'version_number': 2,
        'status': 'ASSIGNED',
        'status_display': 'Assigned',
        'is_overdue': true,
        'assigned_at': null,
        'due_at': null,
        'completed_at': null,
        'certificate_id': null,
        'certificate_number': null,
        'is_certificate_revoked': null,
      };

      final item = AssignmentReportItemViewData.fromJson(json);
      expect(item.id, 5);
      expect(item.employeeName, 'Bob Smith');
      expect(item.departmentName, '');
      expect(item.jobRoleName, '');
      expect(item.versionTitle, '');
      expect(item.isOverdue, isTrue);
      expect(item.assignedAt, isNull);
      expect(item.dueAt, isNull);
      expect(item.completedAt, isNull);
      expect(item.certificateId, isNull);
      expect(item.hasCertificateIndicator, isFalse);
      expect(item.hasCertificate, isFalse);
      expect(item.certificateNumber, isNull);
    });

    test('AssignmentReportItemViewData throws FormatException on malformed assigned_at', () {
      final jsonMalformedString = {
        'id': 5,
        'employee_name': 'Bob Smith',
        'employee_code': 'EMP005',
        'department_name': 'Gardening',
        'job_role_name': 'Horticulturist',
        'training_title': 'Plant Care Basics',
        'version_title': 'v1',
        'version_number': 2,
        'status': 'ASSIGNED',
        'status_display': 'Assigned',
        'is_overdue': true,
        'assigned_at': 'not-a-date',
      };
      expect(
        () => AssignmentReportItemViewData.fromJson(jsonMalformedString),
        throwsFormatException,
      );

      final jsonMalformedType = {
        'id': 5,
        'employee_name': 'Bob Smith',
        'employee_code': 'EMP005',
        'department_name': 'Gardening',
        'job_role_name': 'Horticulturist',
        'training_title': 'Plant Care Basics',
        'version_title': 'v1',
        'version_number': 2,
        'status': 'ASSIGNED',
        'status_display': 'Assigned',
        'is_overdue': true,
        'assigned_at': 12345,
      };
      expect(
        () => AssignmentReportItemViewData.fromJson(jsonMalformedType),
        throwsFormatException,
      );
    });

    test(
      'AssignmentReportItemViewData throws FormatException on non-positive ID',
      () {
        expect(
          () => AssignmentReportItemViewData.fromJson(
            sampleAssignmentReportItemJson(id: 0),
          ),
          throwsFormatException,
        );
        expect(
          () => AssignmentReportItemViewData.fromJson(
            sampleAssignmentReportItemJson(id: -1),
          ),
          throwsFormatException,
        );
      },
    );

    test('AssignmentReportFilterOptionsViewData parses collections and handles missing safely', () {
      final json = {
        'departments': [
          {'id': 1, 'label': 'Dept A'},
        ],
        'job_roles': [
          {'id': 10, 'label': 'Role X'},
        ],
        'trainings': [
          {'id': 100, 'label': 'Training Alpha'},
        ],
        'training_versions': [
          {
            'id': 201,
            'training_id': 100,
            'version_number': 1,
            'title': 'Alpha v1',
          },
        ],
      };

      final options = AssignmentReportFilterOptionsViewData.fromJson(json);
      expect(options.departments.length, 1);
      expect(options.departments.first.label, 'Dept A');
      expect(options.jobRoles.length, 1);
      expect(options.trainings.length, 1);
      expect(options.trainingVersions.length, 1);
      expect(options.trainingVersions.first.title, 'Alpha v1');

      // Empty map fallback
      final emptyOptions = AssignmentReportFilterOptionsViewData.fromJson({});
      expect(emptyOptions.departments, isEmpty);
      expect(emptyOptions.jobRoles, isEmpty);
      expect(emptyOptions.trainings, isEmpty);
      expect(emptyOptions.trainingVersions, isEmpty);
    });

    test('AssignmentReportPageViewData calculates pagination boundaries accurately', () {
      final json = {
        'count': 45,
        'next': '/management/reports/assignments/?page=3',
        'results': [
          sampleAssignmentReportItemJson(id: 1),
          sampleAssignmentReportItemJson(id: 2),
        ],
      };

      final page = AssignmentReportPageViewData.fromJson(
        json,
        page: 2,
        pageSize: 20,
      );
      expect(page.count, 45);
      expect(page.page, 2);
      expect(page.pageSize, 20);
      expect(page.totalPages, 3);
      expect(page.hasMore, isTrue);
      expect(page.items.length, 2);

      // Last page
      final lastPage = AssignmentReportPageViewData.fromJson(
        {
          'count': 45,
          'next': null,
          'results': [sampleAssignmentReportItemJson(id: 3)],
        },
        page: 3,
        pageSize: 20,
      );
      expect(lastPage.totalPages, 3);
      expect(lastPage.hasMore, isFalse);

      // Empty results
      final emptyPage = AssignmentReportPageViewData.fromJson(
        {'count': 0, 'next': null, 'results': <dynamic>[]},
        page: 1,
        pageSize: 20,
      );
      expect(emptyPage.count, 0);
      expect(emptyPage.totalPages, 1);
      expect(emptyPage.hasMore, isFalse);
      expect(emptyPage.items, isEmpty);
    });

    test('AuditLogEntryViewData parses complete valid JSON with changes', () {
      final json = sampleAuditLogEntryJson();
      final entry = AuditLogEntryViewData.fromJson(json);

      expect(entry.id, 101);
      expect(entry.occurredAt, DateTime.parse('2026-10-15T10:00:00Z'));
      expect(entry.actorLabelSnapshot, 'Admin User (admin)');
      expect(entry.actorId, 1);
      expect(entry.action, 'training.trainingassignment.created');
      expect(entry.actionLabel, 'Training assignment created');
      expect(entry.entityType, 'training.trainingassignment');
      expect(entry.entityLabel, 'Training assignment');
      expect(entry.entityId, '50');
      expect(
        entry.recordSummary,
        'Alice Johnson assigned to Greenhouse Safety',
      );
      expect(entry.reason, 'Annual compliance requirement');
      expect(entry.detailKind, 'changes');
      expect(entry.changes.length, 1);
      expect(entry.changes.first.field, 'status');
      expect(entry.changes.first.fieldLabel, 'Status');
      expect(entry.changes.first.beforeDisplay, 'DRAFT');
      expect(entry.changes.first.afterDisplay, 'ASSIGNED');
      expect(entry.changes.first.captured, isTrue);
    });

    test('AuditLogEntryViewData throws FormatException on non-positive ID', () {
      expect(
        () => AuditLogEntryViewData.fromJson(sampleAuditLogEntryJson(id: 0)),
        throwsFormatException,
      );
      expect(
        () => AuditLogEntryViewData.fromJson(sampleAuditLogEntryJson(id: -5)),
        throwsFormatException,
      );
    });

    test(
      'AuditLogFilterOptionsViewData parses entity types and actors safely',
      () {
        final json = {
          'entity_types': [
            {'value': 'training.trainingassignment', 'label': 'Assignment'},
          ],
          'actors': [
            {'id': 10, 'username': 'admin_jane', 'display_name': 'Jane Admin'},
          ],
        };

        final options = AuditLogFilterOptionsViewData.fromJson(json);
        expect(options.entityTypes.length, 1);
        expect(options.entityTypes.first.value, 'training.trainingassignment');
        expect(options.actors.length, 1);
        expect(options.actors.first.id, 10);
        expect(options.actors.first.label, 'Jane Admin (admin_jane)');
      },
    );

    test(
      'AuditLogPageViewData calculates totalPages and hasMore accurately',
      () {
        final json = {
          'count': 55,
          'next': '/management/audit-logs/?page=3',
          'results': [sampleAuditLogEntryJson(id: 10)],
        };

        final page = AuditLogPageViewData.fromJson(json, page: 2, pageSize: 25);
        expect(page.count, 55);
        expect(page.page, 2);
        expect(page.pageSize, 25);
        expect(page.totalPages, 3);
        expect(page.hasMore, isTrue);

        final lastPage = AuditLogPageViewData.fromJson(
          {
            'count': 55,
            'next': null,
            'results': [sampleAuditLogEntryJson(id: 11)],
          },
          page: 3,
          pageSize: 25,
        );
        expect(lastPage.totalPages, 3);
        expect(lastPage.hasMore, isFalse);
      },
    );
  });

  group('2. Filter Encoding, Query Serialization & Date Formatting', () {
    late MockApiClient mockApiClient;
    late MockDio mockDio;
    late ManagementRepository repository;

    setUp(() {
      mockApiClient = MockApiClient();
      mockDio = MockDio();
      when(() => mockApiClient.dio).thenReturn(mockDio);
      repository = ManagementRepository(mockApiClient);
    });

    test(
      'assignmentReport encodes all filter parameters and omits null/empty',
      () async {
        when(
          () => mockDio.get(
            '/management/reports/assignments/',
            queryParameters: any(named: 'queryParameters'),
            cancelToken: any(named: 'cancelToken'),
          ),
        ).thenAnswer(
          (_) async => Response(
            requestOptions: RequestOptions(
              path: '/management/reports/assignments/',
            ),
            statusCode: 200,
            data: {
              'count': 1,
              'next': null,
              'results': [sampleAssignmentReportItemJson()],
            },
          ),
        );

        final query = const AssignmentReportFilterQuery(
          page: 2,
          pageSize: 15,
          departmentId: '1',
          jobRoleId: '10',
          trainingId: '100',
          trainingVersionId: '201',
          status: 'COMPLETED',
          overdueOnly: true,
        );

        final result = await repository.assignmentReport(query: query);
        expect(result.count, 1);

        verify(
          () => mockDio.get(
            '/management/reports/assignments/',
            queryParameters: {
              'page': 2,
              'page_size': 15,
              'status': 'COMPLETED',
              'department': 1,
              'job_role': 10,
              'training': 100,
              'training_version': 201,
              'overdue_only': true,
            },
            cancelToken: any(named: 'cancelToken'),
          ),
        ).called(1);
      },
    );

    test('assignmentReport omits empty strings and null filters', () async {
      when(
        () => mockDio.get(
          '/management/reports/assignments/',
          queryParameters: any(named: 'queryParameters'),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer(
        (_) async => Response(
          requestOptions: RequestOptions(
            path: '/management/reports/assignments/',
          ),
          statusCode: 200,
          data: {'count': 0, 'next': null, 'results': <dynamic>[]},
        ),
      );

      final query = const AssignmentReportFilterQuery(
        page: 1,
        pageSize: 20,
        departmentId: '',
        jobRoleId: null,
        trainingId: '',
        status: null,
        overdueOnly: null,
      );

      await repository.assignmentReport(query: query);

      verify(
        () => mockDio.get(
          '/management/reports/assignments/',
          queryParameters: {'page_size': 20},
          cancelToken: any(named: 'cancelToken'),
        ),
      ).called(1);
    });

    test('auditLogs encodes filters, formats dates as YYYY-MM-DD, and validates date bounds', () async {
      when(
        () => mockDio.get(
          '/management/audit-logs/',
          queryParameters: any(named: 'queryParameters'),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer(
        (_) async => Response(
          requestOptions: RequestOptions(path: '/management/audit-logs/'),
          statusCode: 200,
          data: {
            'count': 1,
            'next': null,
            'results': [sampleAuditLogEntryJson()],
          },
        ),
      );

      final startDate = DateTime(2026, 3, 5, 14, 30, 45);
      final endDate = DateTime(2026, 4, 1, 9, 15, 0);

      final query = AuditLogFilterQuery(
        page: 1,
        pageSize: 25,
        action: 'auth.login',
        targetType: 'user',
        actorId: 42,
        startDate: startDate,
        endDate: endDate,
      );

      final result = await repository.auditLogs(query: query);
      expect(result.count, 1);

      verify(
        () => mockDio.get(
          '/management/audit-logs/',
          queryParameters: {
            'page_size': 25,
            'actor': 42,
            'action': 'auth.login',
            'target_type': 'user',
            'start_date': '2026-03-05',
            'end_date': '2026-04-01',
          },
          cancelToken: any(named: 'cancelToken'),
        ),
      ).called(1);

      // Throws ArgumentError when start_date is after end_date
      final invalidQuery = AuditLogFilterQuery(
        startDate: DateTime(2026, 5, 1),
        endDate: DateTime(2026, 4, 1),
      );
      expect(
        () => repository.auditLogs(query: invalidQuery),
        throwsArgumentError,
      );
    });

    test('auditLogDetail validates id and fetches from endpoint', () async {
      when(
        () => mockDio.get(
          '/management/audit-logs/42/',
          queryParameters: any(named: 'queryParameters'),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer(
        (_) async => Response(
          requestOptions: RequestOptions(path: '/management/audit-logs/42/'),
          statusCode: 200,
          data: sampleAuditLogEntryJson(id: 42),
        ),
      );

      final detail = await repository.auditLogDetail(42);
      expect(detail.id, 42);

      expect(() => repository.auditLogDetail(0), throwsArgumentError);
      expect(() => repository.auditLogDetail(-1), throwsArgumentError);
    });
  });

  group('3. Filter Option Continuation & Safe Pagination Bounds', () {
    late MockApiClient mockApiClient;
    late MockDio mockDio;
    late ManagementRepository repository;

    setUp(() {
      mockApiClient = MockApiClient();
      mockDio = MockDio();
      when(() => mockApiClient.dio).thenReturn(mockDio);
      repository = ManagementRepository(mockApiClient);
    });

    test('assignmentReportFilterOptions follows next links and merges multi-page options', () async {
      when(
        () => mockDio.get(
          '/management/reports/assignments/filters/',
          queryParameters: {'page_size': 100},
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer(
        (_) async => Response(
          requestOptions: RequestOptions(
            path: '/management/reports/assignments/filters/',
          ),
          statusCode: 200,
          data: {
            'pagination': {
              'departments': {
                'next': '/management/reports/assignments/filters/?kind=departments&page=2',
              },
            },
            'departments': [
              {'id': 1, 'label': 'Dept 1'},
            ],
            'job_roles': [
              {'id': 10, 'label': 'Role 10'},
            ],
            'trainings': [
              {'id': 100, 'label': 'Course A'},
            ],
            'training_versions': [
              {
                'id': 1,
                'training_id': 100,
                'version_number': 1,
                'title': 'Course A v1',
              },
            ],
          },
        ),
      );

      when(
        () => mockDio.get(
          '/management/reports/assignments/filters/',
          queryParameters: {'kind': 'departments', 'page': 2, 'page_size': 100},
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer(
        (_) async => Response(
          requestOptions: RequestOptions(
            path: '/management/reports/assignments/filters/',
          ),
          statusCode: 200,
          data: {
            'pagination': {
              'departments': {'next': null},
            },
            'departments': [
              {'id': 2, 'label': 'Dept 2'},
            ],
          },
        ),
      );

      final filterOptions = await repository.assignmentReportFilterOptions();

      expect(filterOptions.departments.length, 2);
      expect(
        filterOptions.departments.map((d) => d.label),
        containsAll(['Dept 1', 'Dept 2']),
      );
      expect(filterOptions.jobRoles.length, 1);
      expect(filterOptions.trainings.length, 1);
      expect(filterOptions.trainingVersions.length, 1);
    });

    test('assignmentReportFilterOptions enforces maxPages=10 limit and throws incomplete_pagination on truncated choices', () async {
      var requestCount = 0;
      final requestedPages = <int>[];

      when(
        () => mockDio.get(
          '/management/reports/assignments/filters/',
          queryParameters: any(named: 'queryParameters'),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer((invocation) async {
        requestCount++;
        final queryParams =
            invocation.namedArguments[#queryParameters]
                as Map<String, dynamic>?;
        final page = queryParams?['page'] as int? ?? 1;
        requestedPages.add(page);

        final nextPage = page + 1;
        return Response(
          requestOptions: RequestOptions(
            path: '/management/reports/assignments/filters/',
          ),
          statusCode: 200,
          data: {
            'pagination': {
              'departments': {
                'count': 2500,
                'next':
                    '/management/reports/assignments/filters/?kind=departments&page=$nextPage&page_size=100',
              },
            },
            'departments': [
              {'id': page, 'label': 'Dept $page'},
            ],
            'job_roles': <dynamic>[],
            'trainings': <dynamic>[],
            'training_versions': <dynamic>[],
          },
        );
      });

      await expectLater(
        repository.assignmentReportFilterOptions(),
        throwsA(
          isA<ApiError>()
              .having((e) => e.code, 'code', 'incomplete_pagination')
              .having(
                (e) => e.message,
                'message',
                'Could not load all departments filter options. Refresh and try again.',
              ),
        ),
      );

      // 1 initial request (page 1) + 9 continuation requests (pages 2..10) = 10 requests total
      expect(requestCount, equals(10));
      expect(requestedPages, equals([1, 2, 3, 4, 5, 6, 7, 8, 9, 10]));
      expect(requestedPages.contains(11), isFalse);
    });

    test(
      'auditLogFilterOptions follows actor next links and terminates safely',
      () async {
        when(
          () => mockDio.get(
            '/management/audit-logs/filters/',
            queryParameters: {'page_size': 100},
            cancelToken: any(named: 'cancelToken'),
          ),
        ).thenAnswer(
          (_) async => Response(
            requestOptions: RequestOptions(
              path: '/management/audit-logs/filters/',
            ),
            statusCode: 200,
            data: {
              'pagination': {
                'actors': {
                  'count': 2,
                  'next': '/management/audit-logs/filters/?kind=actors&page=2',
                },
              },
              'entity_types': [
                {'value': 'e1', 'label': 'Entity 1'},
              ],
              'actors': [
                {'id': 1, 'username': 'user1', 'display_name': 'User One'},
              ],
            },
          ),
        );

        when(
          () => mockDio.get(
            '/management/audit-logs/filters/',
            queryParameters: {'kind': 'actors', 'page': 2, 'page_size': 100},
            cancelToken: any(named: 'cancelToken'),
          ),
        ).thenAnswer(
          (_) async => Response(
            requestOptions: RequestOptions(
              path: '/management/audit-logs/filters/',
            ),
            statusCode: 200,
            data: {
              'pagination': {
                'actors': {'next': null},
              },
              'actors': [
                {'id': 2, 'username': 'user2', 'display_name': 'User Two'},
              ],
            },
          ),
        );

        final options = await repository.auditLogFilterOptions();
        expect(options.entityTypes.length, 1);
        expect(options.actors.length, 2);
        expect(
          options.actors.map((a) => a.displayName),
          containsAll(['User One', 'User Two']),
        );
      },
    );

    test('auditLogFilterOptions enforces maxPages=10 limit and throws incomplete_pagination on truncated choices', () async {
      var requestCount = 0;
      final requestedPages = <int>[];

      when(
        () => mockDio.get(
          '/management/audit-logs/filters/',
          queryParameters: any(named: 'queryParameters'),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer((invocation) async {
        requestCount++;
        final queryParams =
            invocation.namedArguments[#queryParameters]
                as Map<String, dynamic>?;
        final page = queryParams?['page'] as int? ?? 1;
        requestedPages.add(page);

        final nextPage = page + 1;
        return Response(
          requestOptions: RequestOptions(
            path: '/management/audit-logs/filters/',
          ),
          statusCode: 200,
          data: {
            'entity_types': [
              {'value': 'e1', 'label': 'Entity 1'},
            ],
            'actors': [
              {
                'id': page,
                'username': 'user$page',
                'display_name': 'User $page',
              },
            ],
            'pagination': {
              'actors': {
                'count': 2500,
                'next':
                    '/management/audit-logs/filters/?kind=actors&page=$nextPage&page_size=100',
              },
            },
          },
        );
      });

      await expectLater(
        repository.auditLogFilterOptions(),
        throwsA(
          isA<ApiError>()
              .having((e) => e.code, 'code', 'incomplete_pagination')
              .having(
                (e) => e.message,
                'message',
                'Could not load all audit actor options. Refresh and try again.',
              ),
        ),
      );

      // 1 initial request (page 1) + 9 continuation requests (pages 2..10) = 10 requests total
      expect(requestCount, equals(10));
      expect(requestedPages, equals([1, 2, 3, 4, 5, 6, 7, 8, 9, 10]));
      expect(requestedPages.contains(11), isFalse);
    });
  });

  group('4. Capability Helpers & Permission Boundaries', () {
    test('canViewAssignmentReports checks company_dashboard, assignment_report, or team_workspace', () {
      final adminWithPerm = managementIdentity(
        capabilities: {'management_workspace', 'company_dashboard'},
      );
      expect(canViewAssignmentReports(adminWithPerm), isTrue);

      final managerWithPerm = managementIdentity(
        team: true,
        capabilities: {'team_workspace'},
      );
      expect(canViewAssignmentReports(managerWithPerm), isTrue);

      final directPermUser = managementIdentity(
        capabilities: {'assignment_report'},
      );
      expect(canViewAssignmentReports(directPermUser), isTrue);

      final learnerNoWorkspace = managementIdentity(
        capabilities: {'personal_learning'},
      );
      expect(canViewAssignmentReports(learnerNoWorkspace), isFalse);
    });

    test('canViewAuditLogs strictly requires audit.view_auditlog', () {
      final adminWithAudit = managementIdentity(
        capabilities: {'management_workspace', 'audit.view_auditlog'},
      );
      expect(canViewAuditLogs(adminWithAudit), isTrue);

      final adminWithoutAudit = managementIdentity(
        capabilities: {'management_workspace', 'organization.view_employee'},
      );
      expect(canViewAuditLogs(adminWithoutAudit), isFalse);
    });
  });

  group('5. Controller Invalidation & Account Switching', () {
    test('switching auth identity resets report provider state', () async {
      final mockRepo = MockManagementRepository();
      when(
        () => mockRepo.assignmentReport(
          query: any(named: 'query'),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer(
        (_) async => const AssignmentReportPageViewData(
          items: [],
          count: 0,
          page: 1,
          pageSize: 20,
          hasMore: false,
        ),
      );

      final authA = ManagementTestAuth(
        managementIdentity(
          username: 'user_a',
          capabilities: {'management_workspace', 'company_dashboard'},
        ),
      );

      final container = ProviderContainer(
        overrides: [
          authControllerProvider.overrideWith(() => authA),
          managementRepositoryProvider.overrideWithValue(mockRepo),
        ],
      );
      addTearDown(container.dispose);

      final query = const AssignmentReportFilterQuery();
      final result1 = await container.read(
        assignmentReportProvider(query).future,
      );
      expect(result1.count, 0);

      // Change auth state to user B (lacks assignment report permission)
      authA.setAuth(
        AuthAuthenticated.identity(
          managementIdentity(
            username: 'user_b',
            capabilities: {'personal_learning'},
          ),
        ),
      );

      // Now reading should throw ApiError.unauthorized because user_b lacks permission
      expect(
        () => container.read(assignmentReportProvider(query).future),
        throwsA(isA<ApiError>().having((e) => e.statusCode, 'statusCode', 403)),
      );
    });
  });

  group('6. Router Guarding, Route Access & Regression Checks', () {
    late MockManagementRepository mockRepo;

    setUp(() {
      mockRepo = MockManagementRepository();
      when(
        () => mockRepo.assignmentReport(
          query: any(named: 'query'),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer(
        (_) async => const AssignmentReportPageViewData(
          items: [],
          count: 0,
          page: 1,
          pageSize: 20,
          hasMore: false,
        ),
      );
      when(
        () => mockRepo.assignmentReportFilterOptions(
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer((_) async => const AssignmentReportFilterOptionsViewData());
      when(
        () => mockRepo.auditLogs(
          query: any(named: 'query'),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer(
        (_) async => const AuditLogPageViewData(
          items: [],
          count: 0,
          page: 1,
          pageSize: 25,
          hasMore: false,
        ),
      );
      when(
        () => mockRepo.auditLogFilterOptions(
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer((_) async => const AuditLogFilterOptionsViewData());
      when(
        () => mockRepo.certificates(
          page: any(named: 'page'),
          pageSize: any(named: 'pageSize'),
          search: any(named: 'search'),
          isRevoked: any(named: 'isRevoked'),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer(
        (_) async => ManagementPage<ManagedCertificate>(
          count: 0,
          hasMore: false,
          items: [],
        ),
      );
      when(
        () => mockRepo.certificateDetail(
          any(),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer(
        (_) async => ManagedCertificateDetail.fromJson({
          'id': 1,
          'certificate_number': 'CERT-2026-001',
          'training_title': 'Plant Safety',
          'version_number': 1,
          'issued_at': '2026-02-15T10:00:00Z',
          'is_revoked': false,
          'employee_name': 'Alice',
          'employee_code': 'EMP001',
        }),
      );
    });

    testWidgets(
      'allows navigation to /workspace/reports/assignments for authorized user',
      (tester) async {
        setTestViewport(tester);
        final auth = ManagementTestAuth(
          managementIdentity(
            capabilities: {'management_workspace', 'company_dashboard'},
          ),
        );

        final container = ProviderContainer(
          overrides: [
            authControllerProvider.overrideWith(() => auth),
            managementRepositoryProvider.overrideWithValue(mockRepo),
            notificationUnreadCountProvider.overrideWith(ZeroUnread.new),
          ],
        );
        addTearDown(container.dispose);

        final router = container.read(appRouterProvider);
        router.go('/workspace/reports/assignments');

        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp.router(
              routerConfig: router,
              theme: AppTheme.lightTheme,
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('Assignment reports'), findsOneWidget);
      },
    );

    testWidgets(
      'blocks navigation to /workspace/reports/assignments for unauthorized user',
      (tester) async {
        setTestViewport(tester);
        final auth = ManagementTestAuth(
          managementIdentity(capabilities: {'personal_learning'}),
        );

        final container = ProviderContainer(
          overrides: [
            authControllerProvider.overrideWith(() => auth),
            managementRepositoryProvider.overrideWithValue(mockRepo),
            notificationUnreadCountProvider.overrideWith(ZeroUnread.new),
          ],
        );
        addTearDown(container.dispose);

        final router = container.read(appRouterProvider);
        router.go('/workspace/reports/assignments');

        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp.router(
              routerConfig: router,
              theme: AppTheme.lightTheme,
            ),
          ),
        );
        await tester.pumpAndSettle();

        // Redirected away from assignment reports
        expect(find.text('Assignment reports'), findsNothing);
      },
    );

    testWidgets(
      'allows navigation to /workspace/audit-log for authorized user',
      (tester) async {
        setTestViewport(tester);
        final auth = ManagementTestAuth(
          managementIdentity(
            capabilities: {'management_workspace', 'audit.view_auditlog'},
          ),
        );

        final container = ProviderContainer(
          overrides: [
            authControllerProvider.overrideWith(() => auth),
            managementRepositoryProvider.overrideWithValue(mockRepo),
            notificationUnreadCountProvider.overrideWith(ZeroUnread.new),
          ],
        );
        addTearDown(container.dispose);

        final router = container.read(appRouterProvider);
        router.go('/workspace/audit-log');

        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp.router(
              routerConfig: router,
              theme: AppTheme.lightTheme,
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('Audit history'), findsOneWidget);
      },
    );

    testWidgets(
      'blocks navigation to /workspace/audit-log for user lacking audit perm',
      (tester) async {
        setTestViewport(tester);
        final auth = ManagementTestAuth(
          managementIdentity(team: true, capabilities: {'team_workspace'}),
        );

        final container = ProviderContainer(
          overrides: [
            authControllerProvider.overrideWith(() => auth),
            managementRepositoryProvider.overrideWithValue(mockRepo),
            notificationUnreadCountProvider.overrideWith(ZeroUnread.new),
          ],
        );
        addTearDown(container.dispose);

        final router = container.read(appRouterProvider);
        router.go('/workspace/audit-log');

        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp.router(
              routerConfig: router,
              theme: AppTheme.lightTheme,
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('Audit history'), findsNothing);
      },
    );

    testWidgets(
      'existing certificate routes remain fully registered and accessible',
      (tester) async {
        setTestViewport(tester);
        final auth = ManagementTestAuth(
          managementIdentity(
            capabilities: {
              'management_workspace',
              'certifications.view_certificate',
            },
          ),
        );

        final container = ProviderContainer(
          overrides: [
            authControllerProvider.overrideWith(() => auth),
            managementRepositoryProvider.overrideWithValue(mockRepo),
            notificationUnreadCountProvider.overrideWith(ZeroUnread.new),
          ],
        );
        addTearDown(container.dispose);

        final router = container.read(appRouterProvider);
        router.go('/workspace/certificates');

        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp.router(
              routerConfig: router,
              theme: AppTheme.lightTheme,
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('Certificate management'), findsOneWidget);
      },
    );

    testWidgets(
      'WorkspaceScreen renders Assignment reports and Audit log cards conditionally',
      (tester) async {
        setTestViewport(tester);
        final auth = ManagementTestAuth(
          managementIdentity(
            capabilities: {
              'management_workspace',
              'company_dashboard',
              'audit.view_auditlog',
              'certifications.view_certificate',
            },
          ),
        );

        final container = ProviderContainer(
          overrides: [
            authControllerProvider.overrideWith(() => auth),
            managementRepositoryProvider.overrideWithValue(mockRepo),
            notificationUnreadCountProvider.overrideWith(ZeroUnread.new),
          ],
        );
        addTearDown(container.dispose);

        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              theme: AppTheme.lightTheme,
              home: const WorkspaceScreen(),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('Assignment reports'), findsOneWidget);
        expect(find.text('Audit log'), findsOneWidget);
        expect(find.text('Certificates'), findsOneWidget);
      },
    );
  });

  group('7. Screen Widget Integration: Nullable Certificates, Error Handling & Retry', () {
    testWidgets(
      'nullable certificate identifier displays badge but is non-interactive',
      (tester) async {
        setTestViewport(tester);
        int? tappedCertificateId;

        final itemWithoutId = const AssignmentReportItemViewData(
          id: 1,
          employeeName: 'Alice Johnson',
          employeeCode: 'EMP-001',
          departmentName: 'Gardening Operations',
          jobRoleName: 'Senior Horticulturist',
          trainingTitle: 'Safety Protocols',
          versionTitle: 'v1',
          versionNumber: 1,
          status: 'COMPLETED',
          statusDisplay: 'Completed',
          isOverdue: false,
          certificateId: null,
          certificateNumber: null,
          isCertificateRevoked: false,
        );

        final pageData = AssignmentReportPageViewData(
          items: [itemWithoutId],
          count: 1,
          page: 1,
          pageSize: 20,
          hasMore: false,
        );

        await tester.pumpWidget(
          ProviderScope(
            child: MaterialApp(
              theme: AppTheme.lightTheme,
              home: AssignmentReportScreen(
                isLoading: false,
                pageData: pageData,
                onCertificateTap: (id) => tappedCertificateId = id,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        // Certificate badge is visible
        expect(find.text('Certificate'), findsOneWidget);
        expect(find.text('ISSUED'), findsOneWidget);

        final certInkWellFinder = find.ancestor(
          of: find.text('Certificate'),
          matching: find.byType(InkWell),
        );

        // No chevron icon is rendered inside certificate InkWell when certificateId is null
        expect(
          find.descendant(
            of: certInkWellFinder,
            matching: find.byIcon(Icons.chevron_right),
          ),
          findsNothing,
        );

        // InkWell onTap is null
        final inkWell = tester.widget<InkWell>(certInkWellFinder);
        expect(inkWell.onTap, isNull);

        // Tapping badge does not invoke callback
        await tester.tap(find.text('Certificate'));
        await tester.pumpAndSettle();
        expect(tappedCertificateId, isNull);

        // Now test with non-null certificate ID
        final itemWithId = const AssignmentReportItemViewData(
          id: 2,
          employeeName: 'Bob Smith',
          employeeCode: 'EMP-002',
          departmentName: 'Logistics',
          jobRoleName: 'Operator',
          trainingTitle: 'Forklift Safety',
          versionTitle: 'v1',
          versionNumber: 1,
          status: 'COMPLETED',
          statusDisplay: 'Completed',
          isOverdue: false,
          certificateId: 99,
          certificateNumber: 'CERT-099',
          isCertificateRevoked: false,
        );

        await tester.pumpWidget(
          ProviderScope(
            child: MaterialApp(
              theme: AppTheme.lightTheme,
              home: AssignmentReportScreen(
                isLoading: false,
                pageData: AssignmentReportPageViewData(
                  items: [itemWithId],
                  count: 1,
                  page: 1,
                  pageSize: 20,
                  hasMore: false,
                ),
                onCertificateTap: (id) => tappedCertificateId = id,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        final certWithIdFinder = find.ancestor(
          of: find.text('CERT-099'),
          matching: find.byType(InkWell),
        );

        expect(find.text('CERT-099'), findsOneWidget);
        expect(
          find.descendant(
            of: certWithIdFinder,
            matching: find.byIcon(Icons.chevron_right),
          ),
          findsOneWidget,
        );

        final activeInkWell = tester.widget<InkWell>(certWithIdFinder);
        expect(activeInkWell.onTap, isNotNull);

        await tester.tap(find.text('CERT-099'));
        await tester.pumpAndSettle();
        expect(tappedCertificateId, 99);
      },
    );

    testWidgets(
      'connected AssignmentReportScreen displays permission denied when user lacks access',
      (tester) async {
        setTestViewport(tester);
        final auth = ManagementTestAuth(
          managementIdentity(capabilities: {'personal_learning'}),
        );

        final container = ProviderContainer(
          overrides: [authControllerProvider.overrideWith(() => auth)],
        );
        addTearDown(container.dispose);

        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              theme: AppTheme.lightTheme,
              home: const AssignmentReportScreen(),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(
          find.text('You do not have permission to view assignment reports.'),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'connected AuditLogScreen displays permission denied when user lacks access',
      (tester) async {
        setTestViewport(tester);
        final auth = ManagementTestAuth(
          managementIdentity(team: true, capabilities: {'team_workspace'}),
        );

        final container = ProviderContainer(
          overrides: [authControllerProvider.overrideWith(() => auth)],
        );
        addTearDown(container.dispose);

        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              theme: AppTheme.lightTheme,
              home: const AuditLogScreen(),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(
          find.text('You do not have permission to view audit history.'),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'renders ApiErrorView on failure and triggers retry in controlled screen',
      (tester) async {
        setTestViewport(tester);
        bool retryClicked = false;

        await tester.pumpWidget(
          ProviderScope(
            child: MaterialApp(
              theme: AppTheme.lightTheme,
              home: AssignmentReportScreen(
                isLoading: false,
                error: ApiError(
                  statusCode: 500,
                  message: 'Failed to load assignment report',
                ),
                onRetry: () => retryClicked = true,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.byType(ApiErrorView), findsOneWidget);
        expect(find.text('Failed to load assignment report'), findsOneWidget);

        await tester.tap(find.text('Retry'));
        await tester.pumpAndSettle();
        expect(retryClicked, isTrue);
      },
    );

    test('sensitive audit field exclusion: passwords/tokens are not present in entry or changes', () {
      final entry = AuditLogEntryViewData.fromJson(sampleAuditLogEntryJson());
      expect(
        entry.changes.any((c) => c.field.toLowerCase().contains('password')),
        isFalse,
      );
      expect(
        entry.changes.any((c) => c.field.toLowerCase().contains('token')),
        isFalse,
      );
      expect(
        entry.changes.any((c) => c.field.toLowerCase().contains('secret')),
        isFalse,
      );
    });
  });
}
