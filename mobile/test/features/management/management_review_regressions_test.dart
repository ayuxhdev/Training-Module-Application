import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:training_app/core/errors/api_error.dart';
import 'package:training_app/core/network/dio_client.dart';
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
import 'package:training_app/features/management/presentation/screens/managed_certificate_detail_screen.dart';

import 'assignment_report_screen_test.dart' as reports;
import 'audit_log_screen_test.dart' as audit;
import 'managed_certificate_test.dart' as certificates;
import 'management_fixtures.dart';

class ReviewRepository extends Mock implements ManagementRepository {}

class ReviewClient extends Mock implements ApiClient {}

class ReviewDio extends Mock implements Dio {}

const _permissions = {
  'management_workspace',
  'assignment_report',
  'audit.view_auditlog',
  'certifications.view_certificate',
  'certifications.change_certificate',
};

void viewport(WidgetTester tester, [Size size = const Size(800, 1400)]) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
}

void main() {
  testWidgets(
    'account A stale confirmation cannot revoke under equally authorized B',
    (tester) async {
      viewport(tester);
      final auth = ManagementTestAuth(
        managementIdentity(username: 'account_a', capabilities: _permissions),
      );
      final repository = ReviewRepository();
      when(
        () => repository.certificateDetail(
          1,
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer(
        (_) async => ManagedCertificateDetail.fromJson(
          certificates.sampleManagedCertificateDetailJson(id: 1),
        ),
      );
      when(
        () => repository.revokeCertificate(
          1,
          any(),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer(
        (_) async => CertificateRevocationResult(
          id: 1,
          isRevoked: true,
          revokedAt: DateTime(2026),
        ),
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            authControllerProvider.overrideWith(() => auth),
            managementRepositoryProvider.overrideWithValue(repository),
          ],
          child: MaterialApp(
            theme: AppTheme.lightTheme,
            home: const ManagedCertificateDetailScreen(certificateId: 1),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Revoke certificate'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Revocation reason *'),
        'A reason',
      );
      auth.setAuth(
        AuthAuthenticated.identity(
          managementIdentity(
            team: true,
            username: 'account_b',
            capabilities: _permissions,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Confirm Revocation'));
      await tester.pumpAndSettle();
      verifyNever(
        () => repository.revokeCertificate(
          any(),
          any(),
          cancelToken: any(named: 'cancelToken'),
        ),
      );
      expect(
        find.text(
          'The account changed. Reopen the certificate before revoking it.',
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  test('mutation boundary rejects a stale expected account before repository invocation', () async {
    final repository = ReviewRepository();
    final a = AuthAuthenticated.identity(
      managementIdentity(username: 'a', capabilities: _permissions),
    );
    final b = AuthAuthenticated.identity(
      managementIdentity(team: true, username: 'b', capabilities: _permissions),
    );
    final controller = CertificateRevocationMutationController(
      repository: repository,
      readAuth: () => b,
    );
    await expectLater(
      controller.revoke(
        certificateId: 1,
        reason: 'Reason',
        expectedAccount: managementAccount(a),
      ),
      throwsA(
        isA<ApiError>().having((error) => error.statusCode, 'status', 403),
      ),
    );
    verifyNever(
      () => repository.revokeCertificate(
        any(),
        any(),
        cancelToken: any(named: 'cancelToken'),
      ),
    );
  });

  for (final isAudit in [false, true]) {
    for (final retryChoices in [false, true]) {
      testWidgets(
        '${isAudit ? 'audit' : 'report'} 1001 choices do not block independent filters (retry: $retryChoices)',
        (tester) async {
          viewport(tester);
          final client = ReviewClient();
          final dio = ReviewDio();
          when(() => client.dio).thenReturn(dio);
          final queries = <Map<String, dynamic>>[];
          var optionRequests = 0;
          var completeEnumeration = false;
          final kind = isAudit ? 'actors' : 'departments';
          when(
            () => dio.get(
              any(),
              queryParameters: any(named: 'queryParameters'),
              cancelToken: any(named: 'cancelToken'),
            ),
          ).thenAnswer((invocation) async {
            final path = invocation.positionalArguments.first as String;
            final query = Map<String, dynamic>.from(
              invocation.namedArguments[#queryParameters] as Map? ?? {},
            );
            final options = path.endsWith('/filters/');
            if (options) {
              optionRequests++;
            } else {
              queries.add(query);
            }
            final page = query['page'] as int? ?? 1;
            return Response(
              requestOptions: RequestOptions(path: path),
              statusCode: 200,
              data: options
                  ? {
                      kind: List.generate(
                        completeEnumeration ? 2 : 100,
                        (index) => {
                          'id': (page - 1) * 100 + index + 1,
                          'label': 'Option $page $index',
                          'username': 'actor-$page-$index',
                        },
                      ),
                      'job_roles': [
                        {'id': 7, 'label': 'Independent role'},
                      ],
                      'entity_types': [
                        {'value': 'training.training', 'label': 'Training'},
                      ],
                      'pagination': {
                        kind: {
                          'count': completeEnumeration ? 2 : 1001,
                          'next': completeEnumeration
                              ? null
                              : 'page=${page + 1}',
                        },
                      },
                    }
                  : {'count': 0, 'next': null, 'results': <dynamic>[]},
            );
          });
          final auth = ManagementTestAuth(
            managementIdentity(capabilities: _permissions),
          );
          await tester.pumpWidget(
            ProviderScope(
              overrides: [
                authControllerProvider.overrideWith(() => auth),
                managementRepositoryProvider.overrideWithValue(
                  ManagementRepository(client),
                ),
              ],
              child: MaterialApp(
                theme: AppTheme.lightTheme,
                home: isAudit
                    ? const AuditLogScreen(
                        currentQuery: AuditLogFilterQuery(actorId: 9999),
                      )
                    : const AssignmentReportScreen(
                        currentQuery: AssignmentReportFilterQuery(
                          departmentId: '9999',
                        ),
                      ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(optionRequests, 10);
          final filter = find.widgetWithIcon(IconButton, Icons.filter_list);
          expect(tester.widget<IconButton>(filter).onPressed, isNotNull);
          await tester.tap(filter);
          await tester.pumpAndSettle();
          expect(find.textContaining('incomplete'), findsWidgets);
          expect(find.text('Option 1 0'), findsNothing);
          final unavailable = isAudit
              ? find.widgetWithText(
                  DropdownButtonFormField<int>,
                  'Performed by',
                )
              : find.widgetWithText(
                  DropdownButtonFormField<String>,
                  'Department',
                );
          if (isAudit) {
            expect(
              tester
                  .widget<DropdownButtonFormField<int>>(unavailable)
                  .onChanged,
              isNull,
            );
          } else {
            expect(
              tester
                  .widget<DropdownButtonFormField<String>>(unavailable)
                  .onChanged,
              isNull,
            );
          }

          if (isAudit) {
            await tester.enterText(
              find.widgetWithText(TextField, 'Action name contains'),
              'published',
            );
            await tester.tap(find.text('From date'));
            await tester.pumpAndSettle();
            await tester.tap(find.text('OK'));
            await tester.pumpAndSettle();
          } else {
            await tester.tap(find.text('All statuses'));
            await tester.pumpAndSettle();
            await tester.tap(find.text('Completed').last);
            await tester.pumpAndSettle();
            await tester.tap(find.text('All job roles'));
            await tester.pumpAndSettle();
            await tester.tap(find.text('Independent role').last);
            await tester.pumpAndSettle();
            await tester.ensureVisible(find.text('Overdue assignments only'));
            await tester.tap(find.text('Overdue assignments only'));
            await tester.pumpAndSettle();
          }

          if (retryChoices) {
            // Retrying the open sheet must preserve unsaved filter edits.
            completeEnumeration = true;
            await tester.ensureVisible(find.text('Retry filters').last);
            await tester.tap(find.text('Retry filters').last);
            await tester.pumpAndSettle();
            expect(find.textContaining('incomplete'), findsNothing);
            if (isAudit) {
              expect(
                tester
                    .widget<DropdownButtonFormField<int>>(unavailable)
                    .onChanged,
                isNotNull,
              );
              expect(
                tester
                    .widget<TextField>(find.byType(TextField).last)
                    .controller!
                    .text,
                'published',
              );
            } else {
              expect(
                tester
                    .widget<DropdownButtonFormField<String>>(unavailable)
                    .onChanged,
                isNotNull,
              );
            }
          }
          await tester.ensureVisible(find.text('Apply filters'));
          await tester.tap(find.text('Apply filters'));
          await tester.pumpAndSettle();
          final applied = queries.last;
          if (isAudit) {
            expect(applied['action'], 'published');
            expect(applied['start_date'], isNotNull);
            expect(applied['actor'], 9999);
          } else {
            expect(applied['job_role'], 7);
            expect(applied['status'], 'COMPLETED');
            expect(applied['overdue_only'], true);
            expect(applied['department'], 9999);
          }
          expect(optionRequests, retryChoices ? 11 : 10);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  for (final isAudit in [false, true]) {
    final name = isAudit ? 'audit' : 'report';
    for (final status in [503, 403]) {
      test(
        '$name option continuation $status preserves the error boundary',
        () async {
          final client = ReviewClient();
          final dio = ReviewDio();
          when(() => client.dio).thenReturn(dio);
          when(() => client.mapExceptionToApiError(any())).thenAnswer(
            (invocation) => invocation.positionalArguments.first as ApiError,
          );
          final failure = ApiError(
            message: 'Continuation failed',
            statusCode: status,
          );
          final kind = isAudit ? 'actors' : 'departments';
          when(
            () => dio.get(
              any(),
              queryParameters: any(named: 'queryParameters'),
              cancelToken: any(named: 'cancelToken'),
            ),
          ).thenAnswer((invocation) async {
            final query = invocation.namedArguments[#queryParameters] as Map;
            if (query['page'] == 2) throw failure;
            return Response(
              requestOptions: RequestOptions(path: '/filters/'),
              statusCode: 200,
              data: {
                kind: [
                  {'id': 1, 'label': 'Partial option', 'username': 'partial'},
                ],
                'job_roles': [
                  {'id': 7, 'label': 'Complete role'},
                ],
                'entity_types': [
                  {'value': 'training.training', 'label': 'Training'},
                ],
                'pagination': {
                  kind: {'count': 2, 'next': 'page=2'},
                },
              },
            );
          });
          final repository = ManagementRepository(client);
          final operation = isAudit
              ? repository.auditLogFilterOptions()
              : repository.assignmentReportFilterOptions();
          if (status == 403) {
            await expectLater(operation, throwsA(same(failure)));
          } else if (isAudit) {
            await expectLater(
              operation,
              throwsA(
                isA<FilterOptionsLoadFailure<AuditLogFilterOptionsViewData>>()
                    .having(
                      (e) => e.completeOptions.actors,
                      'no partial actors',
                      isEmpty,
                    )
                    .having(
                      (e) => e.completeOptions.entityTypes.single.label,
                      'complete record types',
                      'Training',
                    )
                    .having(
                      (e) => e.failures['actors'],
                      'original failure',
                      same(failure),
                    ),
              ),
            );
          } else {
            await expectLater(
              operation,
              throwsA(
                isA<
                      FilterOptionsLoadFailure<
                        AssignmentReportFilterOptionsViewData
                      >
                    >()
                    .having(
                      (e) => e.completeOptions.departments,
                      'no partial departments',
                      isEmpty,
                    )
                    .having(
                      (e) => e.completeOptions.jobRoles.single.label,
                      'complete roles',
                      'Complete role',
                    )
                    .having(
                      (e) => e.failures['departments'],
                      'original failure',
                      same(failure),
                    ),
              ),
            );
          }
        },
      );
    }

    testWidgets(
      '$name open filters isolate account switches and late options',
      (tester) async {
        viewport(tester, const Size(320, 900));
        final client = ReviewClient();
        final dio = ReviewDio();
        when(() => client.dio).thenReturn(dio);
        when(
          () => client.mapExceptionToApiError(any()),
        ).thenReturn(ApiError(message: 'Request cancelled', code: 'cancelled'));
        final pending = Completer<Response<dynamic>>();
        CancelToken? firstRequest;
        var optionCalls = 0;
        when(
          () => dio.get(
            any(),
            queryParameters: any(named: 'queryParameters'),
            cancelToken: any(named: 'cancelToken'),
          ),
        ).thenAnswer((invocation) async {
          final path = invocation.positionalArguments.first as String;
          if (path.endsWith('/filters/')) {
            optionCalls++;
            if (optionCalls == 1) {
              firstRequest =
                  invocation.namedArguments[#cancelToken] as CancelToken;
              return pending.future;
            }
          }
          return Response(
            requestOptions: RequestOptions(path: path),
            statusCode: 200,
            data: {
              'count': 0,
              'next': null,
              'results': <dynamic>[],
              'actors': [
                {'id': 2, 'username': 'account_b'},
              ],
              'departments': [
                {'id': 2, 'label': 'Account B department'},
              ],
            },
          );
        });
        final auth = ManagementTestAuth(
          managementIdentity(username: 'account_a', capabilities: _permissions),
        );
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              authControllerProvider.overrideWith(() => auth),
              managementRepositoryProvider.overrideWithValue(
                ManagementRepository(client),
              ),
            ],
            child: MaterialApp(
              theme: AppTheme.lightTheme,
              home: isAudit
                  ? const AuditLogScreen()
                  : const AssignmentReportScreen(),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithIcon(IconButton, Icons.filter_list));
        await tester.pumpAndSettle();
        expect(find.text('Apply filters'), findsOneWidget);
        expect(tester.takeException(), isNull);
        if (isAudit) {
          await tester.tap(find.text('From date'));
          await tester.pumpAndSettle();
        }
        auth.setAuth(
          AuthAuthenticated.identity(
            managementIdentity(
              team: true,
              username: 'account_b',
              capabilities: _permissions,
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(firstRequest!.isCancelled, isTrue);
        expect(
          find.text('The account changed. Close and reopen filters.'),
          findsOneWidget,
        );
        expect(find.text('Apply filters'), findsNothing);
        pending.complete(
          Response(
            requestOptions: RequestOptions(path: '/old-options/'),
            statusCode: 200,
            data: {
              'actors': [
                {'id': 1, 'username': 'private_account_a'},
              ],
              'departments': [
                {'id': 1, 'label': 'Private A department'},
              ],
            },
          ),
        );
        await tester.pumpAndSettle();
        if (isAudit) {
          await tester.tap(find.text('OK'));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
        }
        await tester.tap(find.text('Close filters'));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithIcon(IconButton, Icons.filter_list));
        await tester.pumpAndSettle();
        expect(find.textContaining('private_account_a'), findsNothing);
        expect(find.textContaining('Private A department'), findsNothing);
        expect(optionCalls, 2);
        expect(tester.takeException(), isNull);
      },
    );

    for (final scenario in [
      'complete',
      '1001',
      'loop',
      'empty continuation',
      'empty',
      'missing next',
    ]) {
      test('$name filter options: $scenario', () async {
        final client = ReviewClient();
        final dio = ReviewDio();
        when(() => client.dio).thenReturn(dio);
        final repository = ManagementRepository(client);
        final kind = isAudit ? 'actors' : 'departments';
        var calls = 0;
        final cancel = CancelToken();
        when(
          () => dio.get(
            any(),
            queryParameters: any(named: 'queryParameters'),
            cancelToken: any(named: 'cancelToken'),
          ),
        ).thenAnswer((invocation) async {
          calls++;
          expect(invocation.namedArguments[#cancelToken], same(cancel));
          final query =
              invocation.namedArguments[#queryParameters]
                  as Map<String, dynamic>;
          final page = query['page'] as int? ?? 1;
          final count = scenario == '1001'
              ? 1001
              : scenario == 'empty'
              ? 0
              : 101;
          final length =
              scenario == 'empty' ||
                  (scenario == 'empty continuation' && page > 1)
              ? 0
              : page == 1 || scenario == '1001'
              ? 100
              : 1;
          final next = scenario == 'loop'
              ? 'same-continuation'
              : scenario == 'missing next'
              ? null
              : page * 100 < count
              ? 'page=${page + 1}'
              : null;
          final data = <String, dynamic>{
            kind: List.generate(
              length,
              (index) => {
                'id': (page - 1) * 100 + index + 1,
                'label': 'Option $page $index',
                'username': 'actor-$page-$index',
                'display_name': 'Actor $page $index',
              },
            ),
            'pagination': {
              kind: {'count': count, 'next': next},
            },
          };
          return Response(
            requestOptions: RequestOptions(
              path: invocation.positionalArguments.first as String,
            ),
            statusCode: 200,
            data: data,
          );
        });
        final operation = isAudit
            ? repository.auditLogFilterOptions(cancelToken: cancel)
            : repository.assignmentReportFilterOptions(cancelToken: cancel);
        if (scenario == 'complete' || scenario == 'empty') {
          final result = await operation;
          final length = isAudit
              ? (result as AuditLogFilterOptionsViewData).actors.length
              : (result as AssignmentReportFilterOptionsViewData)
                    .departments
                    .length;
          expect(length, scenario == 'empty' ? 0 : 101);
        } else {
          await expectLater(
            operation,
            throwsA(
              isA<ApiError>().having(
                (e) => e.code,
                'code',
                'incomplete_pagination',
              ),
            ),
          );
        }
        expect(calls, lessThanOrEqualTo(10));
        if (scenario == '1001') expect(calls, 10);
        if (scenario == 'loop') expect(calls, 2);
      });
    }

    for (final failFirst in [false, true]) {
      testWidgets(
        '$name preserves results during ${failFirst ? 'filter failure and retry' : 'delayed filter loading'}',
        (tester) async {
          viewport(tester);
          final auth = ManagementTestAuth(
            managementIdentity(capabilities: _permissions),
          );
          final pendingReport =
              Completer<AssignmentReportFilterOptionsViewData>();
          final pendingAudit = Completer<AuditLogFilterOptionsViewData>();
          var calls = 0;
          final reportQuery = const AssignmentReportFilterQuery(
            departmentId: '99',
          );
          final auditQuery = const AuditLogFilterQuery(actorId: 99);
          final overrides = [
            authControllerProvider.overrideWith(() => auth),
            if (isAudit) ...[
              auditLogsProvider(auditQuery).overrideWith(
                (ref) async => AuditLogPageViewData(
                  items: [audit.createSampleAuditEntry()],
                  count: 1,
                  hasMore: false,
                  page: 1,
                ),
              ),
              auditLogFilterOptionsProvider.overrideWith((ref) {
                calls++;
                if (failFirst && calls == 1) {
                  throw ApiError(message: 'Filter failure');
                }
                return pendingAudit.future;
              }),
            ] else ...[
              assignmentReportProvider(reportQuery).overrideWith(
                (ref) async => AssignmentReportPageViewData(
                  items: [reports.createSampleItem()],
                  count: 1,
                  hasMore: false,
                  page: 1,
                ),
              ),
              assignmentReportFilterOptionsProvider.overrideWith((ref) {
                calls++;
                if (failFirst && calls == 1) {
                  throw ApiError(message: 'Filter failure');
                }
                return pendingReport.future;
              }),
            ],
          ];
          await tester.pumpWidget(
            ProviderScope(
              overrides: overrides,
              child: MaterialApp(
                theme: AppTheme.lightTheme,
                home: isAudit
                    ? AuditLogScreen(currentQuery: auditQuery)
                    : AssignmentReportScreen(currentQuery: reportQuery),
              ),
            ),
          );
          await tester.pumpAndSettle();
          const resultLabel = 'Alice Johnson';
          expect(find.text(resultLabel), findsWidgets);
          final filter = find.widgetWithIcon(IconButton, Icons.filter_list);
          expect(tester.widget<IconButton>(filter).onPressed, isNotNull);
          if (failFirst) {
            expect(
              find.text('Filter options could not be loaded.'),
              findsOneWidget,
            );
            await tester.tap(find.text('Retry filters'));
            await tester.pumpAndSettle();
          }
          expect(find.text('Loading filter options…'), findsOneWidget);
          expect(find.text(resultLabel), findsWidgets);
          if (isAudit) {
            pendingAudit.complete(const AuditLogFilterOptionsViewData());
          } else {
            pendingReport.complete(
              const AssignmentReportFilterOptionsViewData(),
            );
          }
          await tester.pumpAndSettle();
          expect(tester.widget<IconButton>(filter).onPressed, isNotNull);
          await tester.tap(filter);
          await tester.pumpAndSettle();
          expect(
            find.text(
              isAudit
                  ? 'Selected account #99 (unavailable)'
                  : 'Selected department #99 (unavailable)',
            ),
            findsWidgets,
          );
          await tester.ensureVisible(find.text('Apply filters'));
          await tester.tap(find.text('Apply filters'));
          await tester.pumpAndSettle();
          expect(
            find.text(
              isAudit ? 'Actor: Actor #99 (user_99)' : 'Dept: Dept #99',
            ),
            findsOneWidget,
          );
          expect(tester.takeException(), isNull);
        },
      );
    }

    testWidgets(
      '$name actual filter sheet and long dropdown menus fit a narrow screen',
      (tester) async {
        viewport(tester, const Size(320, 900));
        final long = 'Long authorized option label ' * 6;
        await tester.pumpWidget(
          ProviderScope(
            child: MaterialApp(
              theme: AppTheme.lightTheme,
              home: isAudit
                  ? AuditLogScreen(
                      isLoading: false,
                      filterOptions: AuditLogFilterOptionsViewData(
                        actors: [
                          AuditFilterActorOption(
                            id: 1,
                            username: 'actor',
                            displayName: long,
                          ),
                        ],
                        entityTypes: [
                          AuditFilterEntityOption(
                            value: 'training.training',
                            label: long,
                          ),
                        ],
                      ),
                    )
                  : AssignmentReportScreen(
                      isLoading: false,
                      filterOptions: AssignmentReportFilterOptionsViewData(
                        departments: [
                          ReportFilterOption(value: '1', label: long),
                        ],
                        trainings: [
                          ReportFilterOption(value: '1', label: long),
                        ],
                      ),
                    ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(
          find.byTooltip(isAudit ? 'Filter audit history' : 'Filter options'),
        );
        await tester.pumpAndSettle();
        final labels = isAudit
            ? ['Performed by', 'Record type']
            : ['Department', 'Training course'];
        for (final label in labels) {
          final field = find
              .ancestor(
                of: find.text(label),
                matching: find.byWidgetPredicate(
                  (w) => w is DropdownButtonFormField,
                ),
              )
              .first;
          await tester.ensureVisible(field);
          await tester.tap(field);
          await tester.pumpAndSettle();
          final option = find
              .textContaining('Long authorized option label')
              .hitTestable()
              .last;
          await tester.tap(option);
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
        }
        for (final dropdown in tester.widgetList<DropdownButton>(
          find.byType(DropdownButton<String>),
        )) {
          expect(dropdown.isExpanded, isTrue);
        }
        expect(
          find.textContaining('Long authorized option label'),
          findsWidgets,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }
}
