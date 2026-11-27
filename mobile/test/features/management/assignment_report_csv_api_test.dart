import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:training_app/core/errors/api_error.dart';
import 'package:training_app/core/network/dio_client.dart';
import 'package:training_app/features/management/data/repositories/management_repository.dart';
import 'package:training_app/features/management/presentation/models/assignment_report_view_data.dart';

import '../../core/network/automatic_auth_test.dart' as http;

const _header =
    'Employee,Department,Job role,Training,Version,Assigned,Deadline,Status,Overdue,Completed,Certificate\r\n';
String _csv([int count = 1]) =>
    _header +
    List.generate(
      count,
      (i) =>
          'Learner $i,Operations,Operator,Safety,Pinned v1,2026-11-16T00:00:00Z,,Assigned,No,,Not issued\r\n',
    ).join();

ResponseBody _reply(
  String body, {
  int status = 200,
  String type = 'text/csv; charset=utf-8',
  String? filename,
}) => ResponseBody.fromBytes(
  utf8.encode(body),
  status,
  headers: {
    Headers.contentTypeHeader: [type],
    if (filename != null) 'content-disposition': [filename],
  },
);

class _Fixture {
  final storage = http.MemoryTokens();
  final requests = <RequestOptions>[];
  late final ApiClient client;
  late final ManagementRepository repository;
  _Fixture(FutureOr<ResponseBody> Function(RequestOptions) respond) {
    storage.access = http.jwt(DateTime.now().add(const Duration(minutes: 30)));
    storage.refresh = 'csv-test-refresh';
    client = http.clientFor(storage, (options) {
      requests.add(options);
      if (options.path == '/auth/refresh/') {
        return http.reply({'detail': 'Token is expired'}, 401);
      }
      return respond(options);
    });
    repository = ManagementRepository(client);
    addTearDown(() => client.dio.close(force: true));
  }
}

void main() {
  test('one authenticated byte request preserves all six filters, omitting pagination', () async {
    final fixture = _Fixture(
      (_) => _reply(_csv(), filename: 'attachment; filename="report.csv"'),
    );
    final result = await fixture.repository.downloadAssignmentReportCsv(
      query: const AssignmentReportFilterQuery(
        status: ' IN_PROGRESS ',
        departmentId: '2',
        jobRoleId: '3',
        trainingId: '4',
        trainingVersionId: '5',
        overdueOnly: true,
        page: 7,
        pageSize: 100,
      ),
    );
    expect(fixture.requests, hasLength(1));
    final request = fixture.requests.single;
    expect(request.path, '/management/reports/assignments/export/');
    expect(request.method, 'GET');
    expect(request.responseType, ResponseType.bytes);
    expect(request.headers['Accept'], 'text/csv, application/json');
    expect(request.headers['Authorization'], startsWith('Bearer '));
    expect(request.queryParameters, {
      'status': 'IN_PROGRESS',
      'department': 2,
      'job_role': 3,
      'training': 4,
      'training_version': 5,
      'overdue_only': true,
    });
    expect(result.bytes, orderedEquals(utf8.encode(_csv())));
    expect(result.filename, 'report.csv');
    expect(result.itemCount, 1);
  });

  test('JSON report and CSV export use equivalent active filters', () async {
    final fixture = _Fixture(
      (options) => options.path.endsWith('/export/')
          ? _reply(_csv())
          : http.reply({
              'count': 0,
              'next': null,
              'previous': null,
              'results': [],
            }),
    );
    const query = AssignmentReportFilterQuery(
      status: 'COMPLETED',
      departmentId: '2',
      jobRoleId: '3',
      trainingId: '4',
      trainingVersionId: '5',
      overdueOnly: true,
    );
    await fixture.repository.assignmentReport(query: query);
    await fixture.repository.downloadAssignmentReportCsv(query: query);
    final listFilters =
        Map<String, dynamic>.of(fixture.requests.first.queryParameters)
          ..remove('page_size')
          ..remove('page');
    expect(fixture.requests.last.queryParameters, listFilters);
  });

  test(
    'more than 1,000 rows is a single server download, not a client page loop',
    () async {
      final fixture = _Fixture((_) => _reply(_csv(1500)));
      final result = await fixture.repository.downloadAssignmentReportCsv(
        query: const AssignmentReportFilterQuery(),
      );
      expect(result.itemCount, 1500);
      expect(fixture.requests, hasLength(1));
    },
  );

  test(
    'malformed active ID filter is rejected, never silently dropped',
    () async {
      final fixture = _Fixture((_) => _reply(_csv()));
      await expectLater(
        fixture.repository.downloadAssignmentReportCsv(
          query: const AssignmentReportFilterQuery(departmentId: 'not-an-id'),
        ),
        throwsA(isA<ApiError>().having((e) => e.statusCode, 'status', 400)),
      );
      expect(fixture.requests, isEmpty);
    },
  );

  test('quoted Unicode and multiline cells preserve bytes and accurate record count', () async {
    final body =
        '$_header"Learner, \u90e8\u9580\nSecond line",Operations,Operator,Safety,"Pinned ""v1""",2026-11-16T00:00:00Z,,Assigned,No,,Not issued\r\n';
    final fixture = _Fixture((_) => _reply(body));
    final result = await fixture.repository.downloadAssignmentReportCsv(
      query: const AssignmentReportFilterQuery(),
    );
    expect(result.bytes, orderedEquals(utf8.encode(body)));
    expect(result.itemCount, 1);
  });

  test('formula-protected server cells are passed through unchanged', () async {
    final body =
        '$_header\'=1+1,Operations,Operator,Safety,Pinned,2026-11-16T00:00:00Z,,Assigned,No,,Not issued\r\n';
    final fixture = _Fixture((_) => _reply(body));
    final result = await fixture.repository.downloadAssignmentReportCsv(
      query: const AssignmentReportFilterQuery(),
    );
    expect(result.bytes, orderedEquals(utf8.encode(body)));
  });

  test('header-only CSV is a valid empty report', () async {
    final fixture = _Fixture((_) => _reply(_header));
    final result = await fixture.repository.downloadAssignmentReportCsv(
      query: const AssignmentReportFilterQuery(),
    );
    expect(result.itemCount, 0);
  });

  for (final entry in {
    'attachment; filename="safe-report.csv"': 'safe-report.csv',
    'attachment; filename=ordinary-report.csv': 'ordinary-report.csv',
    "attachment; filename*=UTF-8''safe%2Dreport.csv": 'safe-report.csv',
  }.entries) {
    test('safe Content-Disposition filename: ${entry.key}', () async {
      final fixture = _Fixture((_) => _reply(_csv(), filename: entry.key));
      final result = await fixture.repository.downloadAssignmentReportCsv(
        query: const AssignmentReportFilterQuery(),
      );
      expect(result.filename, entry.value);
    });
  }

  for (final filename in <String?>[
    null,
    'attachment; filename="../../private.csv"',
    'attachment; filename="C:\\private.csv"',
    'attachment; filename="report.json"',
    'attachment; filename="CON.csv"',
    'attachment; filename="report\r\nInjected.csv"',
    "attachment; filename*=UTF-8''bad%ZZ.csv",
    "attachment; filename*=UTF-8''bad%.csv",
    "attachment; filename*=UTF-8''bad%2",
    "attachment; filename*=UTF-8''bad%C3%28.csv",
    "attachment; filename*=UTF-8''caf%C3%A9.csv",
    "attachment; filename*=UTF-8''%2E%2E%2Fprivate.csv",
  ]) {
    test(
      'unsafe or missing filename uses safe dated fallback: $filename',
      () async {
        final fixture = _Fixture((_) => _reply(_csv(), filename: filename));
        final result = await fixture.repository.downloadAssignmentReportCsv(
          query: const AssignmentReportFilterQuery(),
        );
        expect(
          result.filename,
          matches(r'^assignment-report-\d{4}-\d{2}-\d{2}\.csv$'),
        );
      },
    );
  }

  for (final status in [400, 401, 403, 413, 500]) {
    test('HTTP $status byte error never becomes a CSV download', () async {
      final fixture = _Fixture(
        (_) => _reply(
          jsonEncode({
            'error': {
              'code': 'test_error',
              'message': 'Controlled rejection',
              'fields': {},
            },
          }),
          status: status,
          type: 'application/json',
        ),
      );
      await expectLater(
        fixture.repository.downloadAssignmentReportCsv(
          query: const AssignmentReportFilterQuery(),
        ),
        throwsA(isA<ApiError>().having((e) => e.statusCode, 'status', status)),
      );
    });
  }

  for (final entry in <String, String>{
    'application/json': '{"error":"not a report"}',
    'text/html': '<html>Proxy failure</html>',
    'text/csv; charset=iso-8859-1': _csv(),
    'text/csv': '',
  }.entries) {
    test(
      'invalid content type or empty bytes rejected: ${entry.key}',
      () async {
        final fixture = _Fixture((_) => _reply(entry.value, type: entry.key));
        await expectLater(
          fixture.repository.downloadAssignmentReportCsv(
            query: const AssignmentReportFilterQuery(),
          ),
          throwsA(
            isA<ApiError>().having((e) => e.code, 'code', 'invalid_response'),
          ),
        );
      },
    );
  }

  for (final body in [
    '{"error":"disguised JSON"}',
    '${_header}bad,row\r\n',
    '$_header"unterminated',
  ]) {
    test('malformed CSV is rejected: ${body.length}', () async {
      final fixture = _Fixture((_) => _reply(body));
      await expectLater(
        fixture.repository.downloadAssignmentReportCsv(
          query: const AssignmentReportFilterQuery(),
        ),
        throwsA(
          isA<ApiError>().having((e) => e.code, 'code', 'invalid_response'),
        ),
      );
    });
  }

  test('timeout is controlled and retains existing authentication', () async {
    final fixture = _Fixture(
      (options) => throw DioException(
        requestOptions: options,
        type: DioExceptionType.receiveTimeout,
      ),
    );
    final originalToken = fixture.storage.access;
    await expectLater(
      fixture.repository.downloadAssignmentReportCsv(
        query: const AssignmentReportFilterQuery(),
      ),
      throwsA(isA<ApiError>().having((e) => e.code, 'code', 'timeout')),
    );
    expect(fixture.storage.access, originalToken);
    expect(fixture.storage.sessionInvalid, isFalse);
  });

  test('pre-cancelled request never reaches transport', () async {
    final fixture = _Fixture((_) => _reply(_csv()));
    final token = CancelToken()..cancel();
    await expectLater(
      fixture.repository.downloadAssignmentReportCsv(
        query: const AssignmentReportFilterQuery(),
        cancelToken: token,
      ),
      throwsA(
        isA<DioException>().having(CancelToken.isCancel, 'cancelled', isTrue),
      ),
    );
    expect(fixture.requests, isEmpty);
  });

  test(
    'in-flight cancellation rejects late bytes without invalidating session',
    () async {
      final entered = Completer<void>();
      final pending = Completer<ResponseBody>();
      final fixture = _Fixture((_) {
        entered.complete();
        return pending.future;
      });
      final token = CancelToken();
      final running = fixture.repository.downloadAssignmentReportCsv(
        query: const AssignmentReportFilterQuery(),
        cancelToken: token,
      );
      final expected = expectLater(
        running,
        throwsA(
          isA<DioException>().having(CancelToken.isCancel, 'cancelled', isTrue),
        ),
      );
      await entered.future;
      token.cancel('test cancellation');
      pending.complete(_reply(_csv()));
      await expected;
      expect(fixture.storage.sessionInvalid, isFalse);
    },
  );
}
