import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:training_app/core/errors/api_error.dart';
import 'package:training_app/core/network/dio_client.dart';
import 'package:training_app/features/management/data/repositories/management_repository.dart';
import 'package:training_app/features/management/domain/models/management_models.dart';

import 'management_fixtures.dart';

class ClientMock extends Mock implements ApiClient {}

class DioMock extends Mock implements Dio {}

void main() {
  late ClientMock client;
  late DioMock dio;
  late ManagementRepository repository;
  setUpAll(() => registerFallbackValue(CancelToken()));
  setUp(() {
    client = ClientMock();
    dio = DioMock();
    when(() => client.dio).thenReturn(dio);
    when(() => client.mapExceptionToApiError(any())).thenAnswer(
      (invocation) => invocation.positionalArguments.first is ApiError
          ? invocation.positionalArguments.first as ApiError
          : ApiError.unexpected(),
    );
    repository = ManagementRepository(client);
  });

  void reply(String path, Object data, {int? page}) {
    when(
      () => dio.get(
        path,
        queryParameters: page == null ? null : {'page': page},
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenAnswer(
      (_) async => Response(
        requestOptions: RequestOptions(path: path),
        data: data,
      ),
    );
  }

  test(
    'dashboard parses company/team metrics and exact decimal score strings',
    () async {
      for (final team in [false, true]) {
        reply('/management/dashboard/', managementDashboardJson(team: team));
        final dashboard = await repository.dashboard();
        expect(dashboard.isCompany, !team);
        expect(dashboard.metrics.completionPercent, 33.3);
        expect(dashboard.metrics.eligible, 3);
        expect(dashboard.recentFailures.single.scorePoints, '0.00');
        expect(dashboard.incompleteEmployees.length, team ? 1 : 0);
      }
    },
  );

  test(
    'directory pagination uses fixed authenticated paths, never returned URLs',
    () async {
      reply(
        '/management/employees/',
        pageJson(
          [employeeJson()],
          count: 2,
          next: 'https://untrusted.invalid/media',
        ),
        page: 2,
      );
      final page = await repository.employees(page: 2);
      expect(page.hasMore, isTrue);
      expect(page.items.single.employeeCode, 'EMP1');
      verify(
        () => dio.get(
          '/management/employees/',
          queryParameters: {'page': 2},
          cancelToken: null,
        ),
      ).called(1);
      verifyNever(() => dio.get('https://untrusted.invalid/media'));
      expect(() => page.items.clear(), throwsUnsupportedError);
    },
  );

  test(
    'employee detail and both reference routes parse their exact contracts',
    () async {
      reply('/management/employees/3/', employeeJson(3));
      final employee = await repository.employee(3);
      expect(employee.reportingManager, 'Team Manager');
      expect(employee.dateJoined, '2020-01-02');
      expect(employee.loginStatus, 'ACTIVE');
      for (final kind in ReferenceKind.values) {
        reply(
          '/management/${kind.path}/',
          pageJson([referenceJson()..['is_active'] = false]),
        );
        final references = await repository.references(kind);
        expect(references.items.single.isActive, isFalse);
        expect(references.items.single.description, 'Organization reference');
      }
    },
  );

  test('empty pages and nullable reporting relationships are represented correctly', () async {
    reply('/management/employees/', pageJson([]));
    expect((await repository.employees()).items, isEmpty);
    reply(
      '/management/employees/1/',
      employeeJson()..['reporting_manager'] = null,
    );
    expect((await repository.employee(1)).reportingManager, isNull);
  });

  test('invalid identifiers are rejected before networking', () async {
    await expectLater(repository.employee(0), throwsArgumentError);
    await expectLater(repository.employees(page: 0), throwsArgumentError);
    await expectLater(
      repository.references(ReferenceKind.jobRoles, page: -1),
      throwsArgumentError,
    );
    verifyZeroInteractions(dio);
  });

  test('structured authorization failures and network errors are mapped without retries', () async {
    for (final status in [401, 403, 404, 500]) {
      final error = ApiError(message: 'Controlled failure', statusCode: status);
      when(
        () => dio.get(
          '/management/dashboard/',
          queryParameters: null,
          cancelToken: null,
        ),
      ).thenThrow(error);
      await expectLater(repository.dashboard(), throwsA(same(error)));
    }
    verify(
      () => dio.get(
        '/management/dashboard/',
        queryParameters: null,
        cancelToken: null,
      ),
    ).called(4);
  });

  test('cancelled responses are not parsed as current data', () async {
    final token = CancelToken()..cancel();
    reply('/management/dashboard/', managementDashboardJson());
    await expectLater(
      repository.dashboard(cancelToken: token),
      throwsA(isA<ApiError>()),
    );
    verify(() => client.mapExceptionToApiError(any(that: isA<DioException>())))
        .called(1);
  });

  test('mismatched employee detail identifiers fail closed', () async {
    reply('/management/employees/2/', employeeJson(99));
    await expectLater(repository.employee(2), throwsA(isA<ApiError>()));
  });

  test('malformed scope and empty continuing pages are rejected', () {
    expect(
      () => ManagementDashboard.fromJson(
        managementDashboardJson()..['scope'] = 'all',
      ),
      throwsFormatException,
    );
    expect(
      () => ManagementPage.fromJson(
        pageJson([], next: 'next'),
        DirectoryEmployee.fromJson,
      ),
      throwsFormatException,
    );
  });
}
