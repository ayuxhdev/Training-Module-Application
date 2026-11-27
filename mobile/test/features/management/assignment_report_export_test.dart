import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:training_app/core/errors/api_error.dart';
import 'package:training_app/features/auth/domain/models/auth_state.dart';
import 'package:training_app/features/auth/domain/models/authenticated_identity.dart';
import 'package:training_app/features/auth/domain/models/employee.dart';
import 'package:training_app/features/auth/presentation/controllers/auth_controller.dart';
import 'package:training_app/features/management/data/repositories/management_repository.dart';
import 'package:training_app/features/management/data/services/assignment_report_csv_service.dart';
import 'package:training_app/features/management/presentation/controllers/assignment_report_export_controller.dart';
import 'package:training_app/features/management/presentation/models/assignment_report_view_data.dart';
import 'package:training_app/features/management/presentation/screens/assignment_report_screen.dart';

class _MockManagementRepository extends Mock implements ManagementRepository {}

class _MockReportFileSaver extends Mock implements ReportFileSaver {}

class _TestAuthController extends AuthController {
  final AuthState _initial;
  _TestAuthController([AuthState? initial])
    : _initial = initial ?? _defaultManager();

  @override
  AuthState build() => _initial;

  void setAuth(AuthState state) => this.state = state;
}

AuthState _defaultManager({String code = 'MGR-01'}) =>
    AuthAuthenticated.identity(
      AuthenticatedIdentity(
        username: code,
        displayName: 'Manager $code',
        employee: Employee(
          username: code,
          employeeCode: code,
          displayName: 'Manager $code',
          department: 'Operations',
          jobRole: 'Manager',
          isActive: true,
        ),
        capabilities: const {'personal_learning', 'team_workspace'},
      ),
    );

AuthState _unauthorizedEmployee() => AuthAuthenticated.identity(
  AuthenticatedIdentity(
    username: 'worker',
    displayName: 'Worker',
    employee: Employee(
      username: 'worker',
      employeeCode: 'W-01',
      displayName: 'Worker',
      department: 'Floor',
      jobRole: 'Worker',
      isActive: true,
    ),
    capabilities: const {'personal_learning'},
  ),
);

AssignmentReportCsvDownload _download({int count = 5}) =>
    AssignmentReportCsvDownload(
      bytes: Uint8List.fromList(utf8.encode('server-rendered-csv')),
      filename: 'assignment-report-2026-11-16.csv',
      itemCount: count,
    );

void main() {
  late _MockManagementRepository repository;
  late _MockReportFileSaver fileSaver;
  late _TestAuthController authController;
  late ProviderContainer container;

  setUpAll(() {
    registerFallbackValue(const AssignmentReportFilterQuery());
    registerFallbackValue(CancelToken());
    registerFallbackValue(Uint8List(0));
  });

  setUp(() {
    repository = _MockManagementRepository();
    fileSaver = _MockReportFileSaver();
    authController = _TestAuthController();

    when(
      () => fileSaver.saveFile(
        bytes: any(named: 'bytes'),
        filename: any(named: 'filename'),
        mimeType: any(named: 'mimeType'),
      ),
    ).thenAnswer(
      (_) async => const ReportFileSaveResult.saved(
        savedPath: '/storage/emulated/0/Download/assignment-report-test.csv',
      ),
    );
  });

  Widget createTestWidget({
    required Widget child,
    List<Override> extraOverrides = const [],
  }) {
    container = ProviderContainer(
      overrides: [
        managementRepositoryProvider.overrideWithValue(repository),
        reportFileSaverProvider.overrideWithValue(fileSaver),
        authControllerProvider.overrideWith(() => authController),
        ...extraOverrides,
      ],
    );

    return UncontrolledProviderScope(
      container: container,
      child: MaterialApp(home: child),
    );
  }

  group('AssignmentReportScreen - Export CSV UI Action', () {
    testWidgets(
      'renders Export CSV button with accessible semantics and tooltip',
      (tester) async {
        final semantics = tester.ensureSemantics();

        await tester.pumpWidget(
          createTestWidget(
            child: const AssignmentReportScreen(
              isLoading: false,
              pageData: AssignmentReportPageViewData(
                items: [],
                count: 0,
                hasMore: false,
                page: 1,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        final exportButtonFinder = find.byTooltip('Export CSV');
        expect(exportButtonFinder, findsOneWidget);

        final accessibleButton = find.bySemanticsLabel(
          'Export assignment report as CSV',
        );
        expect(accessibleButton, findsOneWidget);
        final semanticsNode = tester.getSemantics(accessibleButton);
        expect(semanticsNode.label, 'Export assignment report as CSV');
        expect(
          semanticsNode.getSemanticsData().flagsCollection.isButton,
          isTrue,
        );
        semantics.dispose();
      },
    );

    testWidgets('invokes onExport callback in controlled mode', (tester) async {
      AssignmentReportFilterQuery? exportedQuery;

      await tester.pumpWidget(
        createTestWidget(
          child: AssignmentReportScreen(
            isLoading: false,
            currentQuery: const AssignmentReportFilterQuery(
              status: 'IN_PROGRESS',
              departmentId: '2',
              overdueOnly: true,
            ),
            pageData: const AssignmentReportPageViewData(
              items: [],
              count: 0,
              hasMore: false,
              page: 1,
            ),
            onExport: (query) async {
              exportedQuery = query;
            },
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Export CSV'));
      await tester.pumpAndSettle();

      expect(exportedQuery, isNotNull);
      expect(exportedQuery!.status, 'IN_PROGRESS');
      expect(exportedQuery!.departmentId, '2');
      expect(exportedQuery!.overdueOnly, isTrue);
    });

    testWidgets('disables export button while operation is in flight', (
      tester,
    ) async {
      final exportCompleter = Completer<void>();
      var exportCallCount = 0;

      await tester.pumpWidget(
        createTestWidget(
          child: AssignmentReportScreen(
            isLoading: false,
            pageData: const AssignmentReportPageViewData(
              items: [],
              count: 1,
              hasMore: false,
              page: 1,
            ),
            onExport: (query) {
              exportCallCount++;
              return exportCompleter.future;
            },
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Tap export
      await tester.tap(find.byTooltip('Export CSV'));
      await tester.pump(); // Enter exporting state

      // Verify progress indicator is rendered
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      // Attempt second tap while in flight
      await tester.tap(find.byTooltip('Export CSV'), warnIfMissed: false);
      await tester.pump();

      expect(exportCallCount, 1);

      // Complete the export
      exportCompleter.complete();
      await tester.pumpAndSettle();

      expect(find.byType(CircularProgressIndicator), findsNothing);
    });
  });

  group('AssignmentReportExportController - server CSV', () {
    ProviderContainer createContainer() {
      final result = ProviderContainer(
        overrides: [
          managementRepositoryProvider.overrideWithValue(repository),
          reportFileSaverProvider.overrideWithValue(fileSaver),
          authControllerProvider.overrideWith(() => authController),
        ],
      );
      final subscription = result.listen(
        assignmentReportExportControllerProvider,
        (_, _) {},
      );
      addTearDown(() {
        subscription.close();
        result.dispose();
      });
      return result;
    }

    void stubDownload({int count = 5}) {
      when(
        () => repository.downloadAssignmentReportCsv(
          query: any(named: 'query'),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer((_) async => _download(count: count));
    }

    test(
      'hands exact server bytes and filename to saver with current filters',
      () async {
        const query = AssignmentReportFilterQuery(
          status: 'ASSIGNED',
          departmentId: '5',
          jobRoleId: '6',
          trainingId: '7',
          trainingVersionId: '8',
          overdueOnly: true,
          page: 3,
        );
        final download = _download(count: 1500);
        when(
          () => repository.downloadAssignmentReportCsv(
            query: query,
            cancelToken: any(named: 'cancelToken'),
          ),
        ).thenAnswer((_) async => download);
        final container = createContainer();
        await container
            .read(assignmentReportExportControllerProvider.notifier)
            .exportReport(query);
        final state = container.read(
          assignmentReportExportControllerProvider,
        ) as AssignmentReportExportSuccess;
        expect(state.itemCount, 1500); // No obsolete 1,000-row client cap.
        expect(state.filename, download.filename);
        expect(state.isFileSaved, isTrue);
        verify(
          () => fileSaver.saveFile(
            bytes: download.bytes,
            filename: download.filename,
            mimeType: 'text/csv',
          ),
        ).called(1);
        verifyNever(
          () => repository.assignmentReport(
            query: any(named: 'query'),
            cancelToken: any(named: 'cancelToken'),
          ),
        );
      },
    );

    test('success waits for native confirmation and duplicate clicks do not replay', () async {
      stubDownload();
      final saved = Completer<ReportFileSaveResult>();
      final entered = Completer<void>();
      when(
        () => fileSaver.saveFile(
          bytes: any(named: 'bytes'),
          filename: any(named: 'filename'),
          mimeType: any(named: 'mimeType'),
        ),
      ).thenAnswer((_) {
        entered.complete();
        return saved.future;
      });
      final container = createContainer();
      final controller = container.read(
        assignmentReportExportControllerProvider.notifier,
      );
      final running = controller.exportReport(
        const AssignmentReportFilterQuery(),
      );
      // Await the saver call deterministically instead of sleeping.
      await entered.future;
      expect(
        container.read(assignmentReportExportControllerProvider),
        isA<AssignmentReportExportInProgress>(),
      );
      await controller.exportReport(const AssignmentReportFilterQuery());
      verify(
        () => repository.downloadAssignmentReportCsv(
          query: any(named: 'query'),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).called(1);
      saved.complete(const ReportFileSaveResult.saved());
      await running;
      expect(
        container.read(assignmentReportExportControllerProvider),
        isA<AssignmentReportExportSuccess>(),
      );
    });

    for (final status in [400, 401, 403, 413, 500]) {
      test('HTTP $status never reaches native saver', () async {
        when(
          () => repository.downloadAssignmentReportCsv(
            query: any(named: 'query'),
            cancelToken: any(named: 'cancelToken'),
          ),
        ).thenThrow(
          ApiError(message: 'Controlled error $status', statusCode: status),
        );
        final container = createContainer();
        await container
            .read(assignmentReportExportControllerProvider.notifier)
            .exportReport(const AssignmentReportFilterQuery());
        expect(
          container.read(assignmentReportExportControllerProvider),
          isA<AssignmentReportExportError>(),
        );
        verifyNever(
          () => fileSaver.saveFile(
            bytes: any(named: 'bytes'),
            filename: any(named: 'filename'),
            mimeType: any(named: 'mimeType'),
          ),
        );
      });
    }

    test('export limit error has accurate guidance and allows retry', () async {
      var requests = 0;
      when(
        () => repository.downloadAssignmentReportCsv(
          query: any(named: 'query'),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer((_) async {
        requests++;
        if (requests == 1) {
          throw ApiError(
            message: 'Reports are limited to 10,000 rows.',
            statusCode: 413,
            code: 'export_too_large',
          );
        }
        return _download();
      });
      final container = createContainer();
      final controller = container.read(
        assignmentReportExportControllerProvider.notifier,
      );

      await controller.exportReport(const AssignmentReportFilterQuery());

      final state = container.read(
        assignmentReportExportControllerProvider,
      ) as AssignmentReportExportError;
      expect(
        state.message,
        'This report exceeds the 10,000-row export limit. Narrow the filters and try again.',
      );
      expect(state.message, isNot(contains('found')));
      verifyNever(
        () => fileSaver.saveFile(
          bytes: any(named: 'bytes'),
          filename: any(named: 'filename'),
          mimeType: any(named: 'mimeType'),
        ),
      );

      await controller.exportReport(const AssignmentReportFilterQuery());

      expect(
        container.read(assignmentReportExportControllerProvider),
        isA<AssignmentReportExportSuccess>(),
      );
      verify(
        () => repository.downloadAssignmentReportCsv(
          query: any(named: 'query'),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).called(2);
    });

    test('empty server report does not invoke saver', () async {
      stubDownload(count: 0);
      final container = createContainer();
      await container
          .read(assignmentReportExportControllerProvider.notifier)
          .exportReport(const AssignmentReportFilterQuery());
      expect(
        container.read(assignmentReportExportControllerProvider),
        isA<AssignmentReportExportEmpty>(),
      );
      verifyNever(
        () => fileSaver.saveFile(
          bytes: any(named: 'bytes'),
          filename: any(named: 'filename'),
          mimeType: any(named: 'mimeType'),
        ),
      );
    });

    test('native cancellation is not reported as success', () async {
      stubDownload();
      when(
        () => fileSaver.saveFile(
          bytes: any(named: 'bytes'),
          filename: any(named: 'filename'),
          mimeType: any(named: 'mimeType'),
        ),
      ).thenAnswer((_) async => const ReportFileSaveResult.cancelled());
      final container = createContainer();
      await container
          .read(assignmentReportExportControllerProvider.notifier)
          .exportReport(const AssignmentReportFilterQuery());
      expect(
        container.read(assignmentReportExportControllerProvider),
        isA<AssignmentReportExportCancelled>(),
      );
    });

    test(
      'share-only handoff does not falsely report a completed write',
      () async {
        stubDownload();
        when(
          () => fileSaver.saveFile(
            bytes: any(named: 'bytes'),
            filename: any(named: 'filename'),
            mimeType: any(named: 'mimeType'),
          ),
        ).thenAnswer((_) async => const ReportFileSaveResult.shared());
        final container = createContainer();
        await container
            .read(assignmentReportExportControllerProvider.notifier)
            .exportReport(const AssignmentReportFilterQuery());
        expect(
          container.read(assignmentReportExportControllerProvider),
          isA<AssignmentReportExportError>(),
        );
      },
    );

    test('native write failure uses controlled feedback', () async {
      stubDownload();
      when(
        () => fileSaver.saveFile(
          bytes: any(named: 'bytes'),
          filename: any(named: 'filename'),
          mimeType: any(named: 'mimeType'),
        ),
      ).thenThrow(StateError('private native diagnostic'));
      final container = createContainer();
      await container
          .read(assignmentReportExportControllerProvider.notifier)
          .exportReport(const AssignmentReportFilterQuery());
      final state = container.read(
        assignmentReportExportControllerProvider,
      ) as AssignmentReportExportError;
      expect(state.message, isNot(contains('private native diagnostic')));
    });

    test('account switch cancels request and ignores late download even after switching back', () async {
      final pending = Completer<AssignmentReportCsvDownload>();
      CancelToken? token;
      when(
        () => repository.downloadAssignmentReportCsv(
          query: any(named: 'query'),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer((invocation) {
        token = invocation.namedArguments[#cancelToken] as CancelToken;
        return pending.future;
      });
      final container = createContainer();
      final running = container
          .read(assignmentReportExportControllerProvider.notifier)
          .exportReport(const AssignmentReportFilterQuery());
      authController.setAuth(_defaultManager(code: 'SECOND-ACCOUNT'));
      expect(token!.isCancelled, isTrue);
      authController.setAuth(_defaultManager());
      pending.complete(_download());
      await running;
      expect(
        container.read(assignmentReportExportControllerProvider),
        isA<AssignmentReportExportIdle>(),
      );
      verifyNever(
        () => fileSaver.saveFile(
          bytes: any(named: 'bytes'),
          filename: any(named: 'filename'),
          mimeType: any(named: 'mimeType'),
        ),
      );
    });

    test('account switch during native write hides stale success and prevents overlapping saves', () async {
      stubDownload();
      final pending = Completer<ReportFileSaveResult>();
      final entered = Completer<void>();
      when(
        () => fileSaver.saveFile(
          bytes: any(named: 'bytes'),
          filename: any(named: 'filename'),
          mimeType: any(named: 'mimeType'),
        ),
      ).thenAnswer((_) {
        entered.complete();
        return pending.future;
      });
      final container = createContainer();
      final controller = container.read(
        assignmentReportExportControllerProvider.notifier,
      );
      final running = controller.exportReport(
        const AssignmentReportFilterQuery(),
      );
      await entered.future;
      authController.setAuth(_defaultManager(code: 'SECOND-ACCOUNT'));
      await controller.exportReport(const AssignmentReportFilterQuery());
      pending.complete(
        const ReportFileSaveResult.saved(savedPath: 'prior-account.csv'),
      );
      await running;
      expect(
        container.read(assignmentReportExportControllerProvider),
        isA<AssignmentReportExportIdle>(),
      );
      verify(
        () => repository.downloadAssignmentReportCsv(
          query: any(named: 'query'),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).called(1);
    });

    test('reset cancels pending download and ignores stale result', () async {
      final pending = Completer<AssignmentReportCsvDownload>();
      when(
        () => repository.downloadAssignmentReportCsv(
          query: any(named: 'query'),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer((_) => pending.future);
      final container = createContainer();
      final controller = container.read(
        assignmentReportExportControllerProvider.notifier,
      );
      final running = controller.exportReport(
        const AssignmentReportFilterQuery(),
      );
      controller.reset();
      pending.complete(_download());
      await running;
      expect(
        container.read(assignmentReportExportControllerProvider),
        isA<AssignmentReportExportIdle>(),
      );
    });

    test('duplicate clicks while downloading issue only one request', () async {
      final pending = Completer<AssignmentReportCsvDownload>();
      when(
        () => repository.downloadAssignmentReportCsv(
          query: any(named: 'query'),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer((_) => pending.future);
      final container = createContainer();
      final controller = container.read(
        assignmentReportExportControllerProvider.notifier,
      );
      final first = controller.exportReport(
        const AssignmentReportFilterQuery(),
      );
      await controller.exportReport(const AssignmentReportFilterQuery());
      pending.complete(_download());
      await first;
      verify(
        () => repository.downloadAssignmentReportCsv(
          query: any(named: 'query'),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).called(1);
    });

    test(
      'disposal cancels download and late response does not call saver',
      () async {
        final pending = Completer<AssignmentReportCsvDownload>();
        CancelToken? token;
        when(
          () => repository.downloadAssignmentReportCsv(
            query: any(named: 'query'),
            cancelToken: any(named: 'cancelToken'),
          ),
        ).thenAnswer((invocation) {
          token = invocation.namedArguments[#cancelToken] as CancelToken;
          return pending.future;
        });
        final container = ProviderContainer(
          overrides: [
            managementRepositoryProvider.overrideWithValue(repository),
            reportFileSaverProvider.overrideWithValue(fileSaver),
            authControllerProvider.overrideWith(() => authController),
          ],
        );
        final subscription = container.listen(
          assignmentReportExportControllerProvider,
          (_, _) {},
        );
        final running = container
            .read(assignmentReportExportControllerProvider.notifier)
            .exportReport(const AssignmentReportFilterQuery());
        subscription.close();
        container.dispose();
        expect(token!.isCancelled, isTrue);
        pending.complete(_download());
        await running;
        verifyNever(
          () => fileSaver.saveFile(
            bytes: any(named: 'bytes'),
            filename: any(named: 'filename'),
            mimeType: any(named: 'mimeType'),
          ),
        );
      },
    );

    test('unauthorized account never downloads', () async {
      final container = createContainer();
      authController.setAuth(_unauthorizedEmployee());
      await container
          .read(assignmentReportExportControllerProvider.notifier)
          .exportReport(const AssignmentReportFilterQuery());
      verifyNever(
        () => repository.downloadAssignmentReportCsv(
          query: any(named: 'query'),
          cancelToken: any(named: 'cancelToken'),
        ),
      );
    });

    test('network timeout is visible and never invokes saver', () async {
      when(
        () => repository.downloadAssignmentReportCsv(
          query: any(named: 'query'),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenThrow(ApiError.timeout());
      final container = createContainer();
      await container
          .read(assignmentReportExportControllerProvider.notifier)
          .exportReport(const AssignmentReportFilterQuery());
      final state = container.read(
        assignmentReportExportControllerProvider,
      ) as AssignmentReportExportError;
      expect(state.message, contains('timed out'));
      verifyNever(
        () => fileSaver.saveFile(
          bytes: any(named: 'bytes'),
          filename: any(named: 'filename'),
          mimeType: any(named: 'mimeType'),
        ),
      );
    });

    test('account switch while native Save As picker is open invokes cancelSave on method channel', () async {
      stubDownload();
      final channelCalls = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('gardensneed/file_saver'), (call) async {
        channelCalls.add(call.method);
        if (call.method == 'cancelSave') {
          return true;
        }
        return null;
      });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(const MethodChannel('gardensneed/file_saver'), null);
      });

      final saveCompleter = Completer<ReportFileSaveResult>();
      final enteredSaver = Completer<void>();
      when(
        () => fileSaver.saveFile(
          bytes: any(named: 'bytes'),
          filename: any(named: 'filename'),
          mimeType: any(named: 'mimeType'),
        ),
      ).thenAnswer((_) {
        enteredSaver.complete();
        return saveCompleter.future;
      });

      final container = createContainer();
      final controller = container.read(
        assignmentReportExportControllerProvider.notifier,
      );
      final running = controller.exportReport(
        const AssignmentReportFilterQuery(),
      );
      await enteredSaver.future;

      authController.setAuth(_defaultManager(code: 'NEW-MANAGER'));
      await pumpEventQueue();

      expect(channelCalls, contains('cancelSave'));
      expect(
        container.read(assignmentReportExportControllerProvider),
        isA<AssignmentReportExportIdle>(),
      );

      saveCompleter.complete(
        const ReportFileSaveResult.saved(savedPath: '/stale/prior-user.csv'),
      );
      await running;

      expect(
        container.read(assignmentReportExportControllerProvider),
        isA<AssignmentReportExportIdle>(),
      );
    });

    test('logout while native Save As picker is open invokes cancelSave and state is idle', () async {
      stubDownload();
      final channelCalls = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('gardensneed/file_saver'), (call) async {
        channelCalls.add(call.method);
        return true;
      });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(const MethodChannel('gardensneed/file_saver'), null);
      });

      final saveCompleter = Completer<ReportFileSaveResult>();
      final enteredSaver = Completer<void>();
      when(
        () => fileSaver.saveFile(
          bytes: any(named: 'bytes'),
          filename: any(named: 'filename'),
          mimeType: any(named: 'mimeType'),
        ),
      ).thenAnswer((_) {
        enteredSaver.complete();
        return saveCompleter.future;
      });

      final container = createContainer();
      final controller = container.read(
        assignmentReportExportControllerProvider.notifier,
      );
      final running = controller.exportReport(
        const AssignmentReportFilterQuery(),
      );
      await enteredSaver.future;

      authController.setAuth(AuthUnauthenticated());
      await pumpEventQueue();

      expect(channelCalls, contains('cancelSave'));
      expect(
        container.read(assignmentReportExportControllerProvider),
        isA<AssignmentReportExportIdle>(),
      );

      saveCompleter.complete(const ReportFileSaveResult.cancelled());
      await running;
    });

    test('reset while native Save As picker is open invokes cancelSave and returns to idle', () async {
      stubDownload();
      final channelCalls = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('gardensneed/file_saver'), (call) async {
        channelCalls.add(call.method);
        return true;
      });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(const MethodChannel('gardensneed/file_saver'), null);
      });

      final saveCompleter = Completer<ReportFileSaveResult>();
      final enteredSaver = Completer<void>();
      when(
        () => fileSaver.saveFile(
          bytes: any(named: 'bytes'),
          filename: any(named: 'filename'),
          mimeType: any(named: 'mimeType'),
        ),
      ).thenAnswer((_) {
        enteredSaver.complete();
        return saveCompleter.future;
      });

      final container = createContainer();
      final controller = container.read(
        assignmentReportExportControllerProvider.notifier,
      );
      final running = controller.exportReport(
        const AssignmentReportFilterQuery(),
      );
      await enteredSaver.future;

      controller.reset();
      await pumpEventQueue();

      expect(channelCalls, contains('cancelSave'));
      expect(
        container.read(assignmentReportExportControllerProvider),
        isA<AssignmentReportExportIdle>(),
      );

      saveCompleter.complete(
        const ReportFileSaveResult.saved(savedPath: '/stale/reset.csv'),
      );
      await running;

      expect(
        container.read(assignmentReportExportControllerProvider),
        isA<AssignmentReportExportIdle>(),
      );
    });

    test('container disposal while native Save As picker is open invokes cancelSave', () async {
      stubDownload();
      final channelCalls = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('gardensneed/file_saver'), (call) async {
        channelCalls.add(call.method);
        return true;
      });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(const MethodChannel('gardensneed/file_saver'), null);
      });

      final saveCompleter = Completer<ReportFileSaveResult>();
      final enteredSaver = Completer<void>();
      when(
        () => fileSaver.saveFile(
          bytes: any(named: 'bytes'),
          filename: any(named: 'filename'),
          mimeType: any(named: 'mimeType'),
        ),
      ).thenAnswer((_) {
        enteredSaver.complete();
        return saveCompleter.future;
      });

      final container = ProviderContainer(
        overrides: [
          managementRepositoryProvider.overrideWithValue(repository),
          reportFileSaverProvider.overrideWithValue(fileSaver),
          authControllerProvider.overrideWith(() => authController),
        ],
      );
      final subscription = container.listen(
        assignmentReportExportControllerProvider,
        (_, _) {},
      );
      final controller = container.read(
        assignmentReportExportControllerProvider.notifier,
      );
      final running = controller.exportReport(
        const AssignmentReportFilterQuery(),
      );
      await enteredSaver.future;

      subscription.close();
      container.dispose();
      await pumpEventQueue();

      expect(channelCalls, contains('cancelSave'));
      saveCompleter.complete(
        const ReportFileSaveResult.saved(savedPath: '/stale/disposed.csv'),
      );
      await running;
    });

    test('late native error after account switch is ignored and does not set error state', () async {
      stubDownload();
      final saveCompleter = Completer<ReportFileSaveResult>();
      final enteredSaver = Completer<void>();
      when(
        () => fileSaver.saveFile(
          bytes: any(named: 'bytes'),
          filename: any(named: 'filename'),
          mimeType: any(named: 'mimeType'),
        ),
      ).thenAnswer((_) {
        enteredSaver.complete();
        return saveCompleter.future;
      });

      final container = createContainer();
      final controller = container.read(
        assignmentReportExportControllerProvider.notifier,
      );
      final running = controller.exportReport(
        const AssignmentReportFilterQuery(),
      );
      await enteredSaver.future;

      authController.setAuth(_defaultManager(code: 'ANOTHER-MGR'));
      await pumpEventQueue();

      saveCompleter.completeError(
        ApiError(message: 'Native write aborted after cancellation', statusCode: 400),
      );
      await running;

      expect(
        container.read(assignmentReportExportControllerProvider),
        isA<AssignmentReportExportIdle>(),
      );
    });

    test('subsequent export succeeds cleanly after previous export was cancelled', () async {
      var downloadCalls = 0;
      when(
        () => repository.downloadAssignmentReportCsv(
          query: any(named: 'query'),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer((_) async {
        downloadCalls++;
        return _download(count: downloadCalls * 10);
      });

      final firstSaveCompleter = Completer<ReportFileSaveResult>();
      final enteredFirstSaver = Completer<void>();
      var saveCalls = 0;

      when(
        () => fileSaver.saveFile(
          bytes: any(named: 'bytes'),
          filename: any(named: 'filename'),
          mimeType: any(named: 'mimeType'),
        ),
      ).thenAnswer((_) {
        saveCalls++;
        if (saveCalls == 1) {
          enteredFirstSaver.complete();
          return firstSaveCompleter.future;
        }
        return Future.value(
          const ReportFileSaveResult.saved(savedPath: '/valid/second-user.csv'),
        );
      });

      final container = createContainer();
      final controller = container.read(
        assignmentReportExportControllerProvider.notifier,
      );

      final firstRunning = controller.exportReport(
        const AssignmentReportFilterQuery(),
      );
      await enteredFirstSaver.future;

      authController.setAuth(_defaultManager(code: 'SECOND-MGR'));
      await pumpEventQueue();

      firstSaveCompleter.complete(const ReportFileSaveResult.cancelled());
      await firstRunning;

      expect(
        container.read(assignmentReportExportControllerProvider),
        isA<AssignmentReportExportIdle>(),
      );

      await controller.exportReport(const AssignmentReportFilterQuery());

      final state = container.read(
        assignmentReportExportControllerProvider,
      ) as AssignmentReportExportSuccess;
      expect(state.itemCount, 20);
      expect(state.savedPath, '/valid/second-user.csv');
      expect(downloadCalls, 2);
      expect(saveCalls, 2);
    });

    test('platform-backed saver dispatches saveFile and cancelSave across gardensneed/file_saver method channel', () async {
      stubDownload();
      final channelInvocations = <String>[];
      Completer<Map<String, dynamic>?>? activeSaveCompleter;

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('gardensneed/file_saver'), (call) async {
        channelInvocations.add(call.method);
        if (call.method == 'saveFile') {
          activeSaveCompleter = Completer<Map<String, dynamic>?>();
          return activeSaveCompleter!.future;
        } else if (call.method == 'cancelSave') {
          activeSaveCompleter?.complete({'status': 'cancelled'});
          return true;
        }
        return null;
      });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(const MethodChannel('gardensneed/file_saver'), null);
      });

      final container = ProviderContainer(
        overrides: [
          managementRepositoryProvider.overrideWithValue(repository),
          reportFileSaverProvider.overrideWithValue(const PlatformReportFileSaver()),
          authControllerProvider.overrideWith(() => authController),
        ],
      );
      final subscription = container.listen(
        assignmentReportExportControllerProvider,
        (_, _) {},
      );
      addTearDown(() {
        subscription.close();
        container.dispose();
      });

      final controller = container.read(
        assignmentReportExportControllerProvider.notifier,
      );

      final running = controller.exportReport(
        const AssignmentReportFilterQuery(),
      );
      await pumpEventQueue();

      expect(channelInvocations, contains('saveFile'));

      authController.setAuth(_defaultManager(code: 'SWITCHED-USER'));
      await pumpEventQueue();

      expect(channelInvocations, contains('cancelSave'));
      await running;

      expect(
        container.read(assignmentReportExportControllerProvider),
        isA<AssignmentReportExportIdle>(),
      );
    });
  });
}
