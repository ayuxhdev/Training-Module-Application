import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:training_app/core/errors/api_error.dart';
import 'package:training_app/core/presentation/components/content_skeleton.dart';
import 'package:training_app/core/presentation/components/empty_view.dart';
import 'package:training_app/core/theme/app_theme.dart';
import 'package:training_app/features/management/presentation/models/assignment_report_view_data.dart';
import 'package:training_app/features/management/presentation/screens/assignment_report_screen.dart';

void setTestViewport(WidgetTester tester, [Size size = const Size(800, 1400)]) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
}

AssignmentReportItemViewData createSampleItem({
  int id = 1,
  String employeeName = 'Alice Johnson',
  String employeeCode = 'EMP-001',
  String departmentName = 'Gardening Operations',
  String jobRoleName = 'Senior Horticulturist',
  String trainingTitle = 'Greenhouse Safety Protocols',
  String versionTitle = 'Safety Standards v1',
  int versionNumber = 1,
  String status = 'ASSIGNED',
  String statusDisplay = 'Assigned',
  bool isOverdue = false,
  DateTime? assignedAt,
  DateTime? dueAt,
  DateTime? completedAt,
  int? certificateId,
  String? certificateNumber,
  bool? isCertificateRevoked,
}) {
  return AssignmentReportItemViewData(
    id: id,
    employeeName: employeeName,
    employeeCode: employeeCode,
    departmentName: departmentName,
    jobRoleName: jobRoleName,
    trainingTitle: trainingTitle,
    versionTitle: versionTitle,
    versionNumber: versionNumber,
    status: status,
    statusDisplay: statusDisplay,
    isOverdue: isOverdue,
    assignedAt: assignedAt ?? DateTime(2026, 10, 1),
    dueAt: dueAt ?? DateTime(2026, 11, 1),
    completedAt: completedAt,
    certificateId: certificateId,
    certificateNumber: certificateNumber,
    isCertificateRevoked: isCertificateRevoked,
  );
}

AssignmentReportFilterOptionsViewData createSampleFilterOptions() {
  return const AssignmentReportFilterOptionsViewData(
    departments: [
      ReportFilterOption(value: '1', label: 'Gardening Operations'),
      ReportFilterOption(value: '2', label: 'Logistics'),
    ],
    jobRoles: [
      ReportFilterOption(value: '10', label: 'Senior Horticulturist'),
      ReportFilterOption(value: '11', label: 'Equipment Specialist'),
    ],
    trainings: [
      ReportFilterOption(value: '100', label: 'Greenhouse Safety Protocols'),
      ReportFilterOption(value: '101', label: 'Forklift Handling'),
    ],
    trainingVersions: [
      ReportVersionFilterOption(
        id: 201,
        trainingId: 100,
        versionNumber: 1,
        title: 'Safety Standards v1',
      ),
      ReportVersionFilterOption(
        id: 202,
        trainingId: 100,
        versionNumber: 2,
        title: 'Safety Standards v2',
      ),
      ReportVersionFilterOption(
        id: 301,
        trainingId: 101,
        versionNumber: 1,
        title: 'Forklift Operation v1',
      ),
    ],
  );
}

Widget buildTestableScreen({
  bool isLoading = false,
  Object? error,
  AssignmentReportPageViewData? pageData,
  AssignmentReportFilterOptionsViewData? filterOptions,
  AssignmentReportFilterQuery currentQuery =
      const AssignmentReportFilterQuery(),
  ValueChanged<AssignmentReportFilterQuery>? onQueryChanged,
  ValueChanged<int>? onPageChanged,
  Future<void> Function()? onRefresh,
  VoidCallback? onRetry,
  ValueChanged<int>? onCertificateTap,
  ThemeData? theme,
  double textScaleFactor = 1.0,
}) {
  return ProviderScope(
    child: MaterialApp(
      theme: theme ?? AppTheme.lightTheme,
      home: Builder(
        builder: (context) {
          return MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(textScaleFactor)),
            child: AssignmentReportScreen(
              isLoading: isLoading,
              error: error,
              pageData: pageData,
              filterOptions: filterOptions ?? createSampleFilterOptions(),
              currentQuery: currentQuery,
              onQueryChanged: onQueryChanged,
              onPageChanged: onPageChanged,
              onRefresh: onRefresh,
              onRetry: onRetry,
              onCertificateTap: onCertificateTap,
            ),
          );
        },
      ),
    ),
  );
}

void main() {
  group('AssignmentReportScreen UI Foundations', () {
    testWidgets('renders loading state with CardListSkeleton', (tester) async {
      setTestViewport(tester);
      await tester.pumpWidget(buildTestableScreen(isLoading: true));
      expect(find.byType(CardListSkeleton), findsOneWidget);
      expect(find.text('Loading assignment reports...'), findsOneWidget);
    });

    testWidgets('renders empty state when no assignments exist (unfiltered)', (
      tester,
    ) async {
      setTestViewport(tester);
      final emptyPage = const AssignmentReportPageViewData(
        items: [],
        count: 0,
        hasMore: false,
        page: 1,
      );

      await tester.pumpWidget(buildTestableScreen(pageData: emptyPage));
      expect(find.byType(EmptyView), findsOneWidget);
      expect(find.text('No assignments found'), findsOneWidget);
      expect(
        find.text('No training assignments have been recorded yet.'),
        findsOneWidget,
      );
      expect(find.text('Reset filters'), findsNothing);
    });

    testWidgets(
      'renders empty state with reset button when filters are active',
      (tester) async {
        setTestViewport(tester);
        final emptyPage = const AssignmentReportPageViewData(
          items: [],
          count: 0,
          hasMore: false,
          page: 1,
        );
        AssignmentReportFilterQuery? capturedQuery;

        await tester.pumpWidget(
          buildTestableScreen(
            pageData: emptyPage,
            currentQuery: const AssignmentReportFilterQuery(
              status: 'COMPLETED',
            ),
            onQueryChanged: (q) => capturedQuery = q,
          ),
        );

        expect(find.byType(EmptyView), findsOneWidget);
        expect(
          find.text(
            'No assignments match the selected filters. Try adjusting or clearing your filters.',
          ),
          findsOneWidget,
        );
        expect(find.text('Reset filters'), findsOneWidget);

        await tester.tap(find.text('Reset filters'));
        await tester.pumpAndSettle();

        expect(capturedQuery, isNotNull);
        expect(capturedQuery!.status, isNull);
        expect(capturedQuery!.hasActiveFilters, isFalse);
      },
    );

    testWidgets('renders populated assignments with all details and badges', (
      tester,
    ) async {
      setTestViewport(tester);
      final item1 = createSampleItem(
        id: 1,
        employeeName: 'Alice Johnson',
        employeeCode: 'EMP-001',
        departmentName: 'Gardening Operations',
        jobRoleName: 'Senior Horticulturist',
        trainingTitle: 'Greenhouse Safety Protocols',
        versionTitle: 'Safety Standards v1',
        versionNumber: 1,
        status: 'IN_PROGRESS',
        statusDisplay: 'In progress',
        isOverdue: false,
      );
      final item2 = createSampleItem(
        id: 2,
        employeeName: 'Bob Smith',
        employeeCode: 'EMP-002',
        departmentName: 'Logistics',
        jobRoleName: 'Equipment Specialist',
        trainingTitle: 'Forklift Handling',
        versionTitle: 'Operation v2',
        versionNumber: 2,
        status: 'COMPLETED',
        statusDisplay: 'Completed',
        isOverdue: false,
        completedAt: DateTime(2026, 10, 25),
        certificateId: 44,
        certificateNumber: 'CERT-2026-0044',
        isCertificateRevoked: false,
      );

      final page = AssignmentReportPageViewData(
        items: [item1, item2],
        count: 2,
        hasMore: false,
        page: 1,
      );

      int? tappedCertId;
      await tester.pumpWidget(
        buildTestableScreen(
          pageData: page,
          onCertificateTap: (id) => tappedCertId = id,
        ),
      );

      // Verify item 1
      expect(find.text('Alice Johnson'), findsOneWidget);
      expect(find.text('ID: EMP-001'), findsOneWidget);
      expect(
        find.text('IN PROGRESS'),
        findsOneWidget,
      ); // StatusBadge converts text to uppercase
      expect(find.text('Greenhouse Safety Protocols'), findsOneWidget);
      expect(find.text('Safety Standards v1 · Version 1'), findsOneWidget);
      expect(find.textContaining('Gardening Operations'), findsOneWidget);
      expect(find.textContaining('Senior Horticulturist'), findsOneWidget);

      // Verify item 2 with certificate
      expect(find.text('Bob Smith'), findsOneWidget);
      expect(find.text('COMPLETED'), findsOneWidget);
      expect(find.text('CERT-2026-0044'), findsOneWidget);
      expect(find.text('ISSUED'), findsOneWidget);

      // Tap certificate badge
      await tester.tap(find.text('CERT-2026-0044'));
      await tester.pumpAndSettle();
      expect(tappedCertId, equals(44));
    });

    testWidgets('renders prominent OVERDUE badge when assignment is overdue', (
      tester,
    ) async {
      setTestViewport(tester);
      final overdueItem = createSampleItem(
        id: 10,
        employeeName: 'Overdue Learner',
        status: 'ASSIGNED',
        statusDisplay: 'Assigned',
        isOverdue: true,
      );

      final page = AssignmentReportPageViewData(
        items: [overdueItem],
        count: 1,
        hasMore: false,
        page: 1,
      );

      await tester.pumpWidget(buildTestableScreen(pageData: page));
      expect(find.text('OVERDUE'), findsOneWidget);
    });

    testWidgets(
      'strictly prevents unsupported search control: no search text field rendered',
      (tester) async {
        setTestViewport(tester);
        final page = const AssignmentReportPageViewData(
          items: [],
          count: 0,
          hasMore: false,
          page: 1,
        );

        await tester.pumpWidget(buildTestableScreen(pageData: page));

        // Confirms Option B: no unsupported search field exists
        expect(find.byType(TextField), findsNothing);
        expect(find.byIcon(Icons.search), findsNothing);
      },
    );

    testWidgets(
      'filter bottom sheet opens, applies filters and updates query',
      (tester) async {
        setTestViewport(tester);
        final page = const AssignmentReportPageViewData(
          items: [],
          count: 0,
          hasMore: false,
          page: 1,
        );
        AssignmentReportFilterQuery? capturedQuery;

        await tester.pumpWidget(
          buildTestableScreen(
            pageData: page,
            onQueryChanged: (q) => capturedQuery = q,
          ),
        );

        // Open filter bottom sheet
        await tester.tap(find.byTooltip('Filter options'));
        await tester.pumpAndSettle();

        expect(find.text('Filter assignments'), findsOneWidget);
        expect(find.text('Assignment status'), findsOneWidget);
        expect(find.text('Department'), findsOneWidget);
        expect(find.text('Job role'), findsOneWidget);
        expect(find.text('Training course'), findsOneWidget);
        expect(find.text('Overdue assignments only'), findsOneWidget);

        // Toggle overdue switch
        await tester.tap(find.byType(Switch));
        await tester.pumpAndSettle();

        // Tap Apply filters
        await tester.tap(find.text('Apply filters'));
        await tester.pumpAndSettle();

        // Sheet closes and query was updated
        expect(find.text('Filter assignments'), findsNothing);
        expect(capturedQuery, isNotNull);
        expect(capturedQuery!.overdueOnly, isTrue);
        expect(capturedQuery!.page, equals(1));
      },
    );

    testWidgets(
      'course selection updates available version options in filter sheet',
      (tester) async {
        setTestViewport(tester);
        final page = const AssignmentReportPageViewData(
          items: [],
          count: 0,
          hasMore: false,
          page: 1,
        );

        await tester.pumpWidget(buildTestableScreen(pageData: page));

        // Open filter sheet
        await tester.tap(find.byTooltip('Filter options'));
        await tester.pumpAndSettle();

        // Training version dropdown is present because sample options has versions
        expect(find.text('Training version'), findsOneWidget);
      },
    );

    testWidgets(
      'course change on page 3 resets to page 1, clears incompatible version, updates choices, and retains independent filters',
      (tester) async {
        setTestViewport(tester);
        final page = const AssignmentReportPageViewData(
          items: [],
          count: 60,
          hasMore: true,
          page: 3,
        );
        AssignmentReportFilterQuery? capturedQuery;

        // Start on page 3 with independent filters and course 100 with version 201 selected
        const initialQuery = AssignmentReportFilterQuery(
          status: 'IN_PROGRESS',
          departmentId: '1',
          jobRoleId: '10',
          overdueOnly: true,
          trainingId: '100',
          trainingVersionId: '201',
          page: 3,
        );

        await tester.pumpWidget(
          buildTestableScreen(
            pageData: page,
            currentQuery: initialQuery,
            onQueryChanged: (q) => capturedQuery = q,
          ),
        );

        // Open filter sheet
        await tester.tap(find.byTooltip('Filter options'));
        await tester.pumpAndSettle();

        // Verify initial state: Safety Standards v1 (v1) is displayed
        expect(find.text('Safety Standards v1 (v1)'), findsOneWidget);

        // Change course to Forklift Handling (101)
        await tester.tap(find.text('Greenhouse Safety Protocols'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Forklift Handling').last);
        await tester.pumpAndSettle();

        // The version dropdown should have reset to 'All versions'
        expect(find.text('All versions'), findsOneWidget);

        // Open the version dropdown to inspect available choices
        await tester.tap(find.text('All versions'));
        await tester.pumpAndSettle();

        // Incompatible versions (Safety Standards v1 & v2) must NOT be choices
        expect(find.text('Safety Standards v1 (v1)'), findsNothing);
        expect(find.text('Safety Standards v2 (v2)'), findsNothing);

        // Forklift Operation v1 (v1) MUST be available
        expect(find.text('Forklift Operation v1 (v1)'), findsOneWidget);

        // Select Forklift Operation v1 (301)
        await tester.tap(find.text('Forklift Operation v1 (v1)').last);
        await tester.pumpAndSettle();

        // Apply filters
        await tester.tap(find.text('Apply filters'));
        await tester.pumpAndSettle();

        // Verify emitted query
        expect(capturedQuery, isNotNull);
        expect(capturedQuery!.trainingId, equals('101'));
        expect(capturedQuery!.trainingVersionId, equals('301'));
        // Verify independent filters were preserved
        expect(capturedQuery!.status, equals('IN_PROGRESS'));
        expect(capturedQuery!.departmentId, equals('1'));
        expect(capturedQuery!.jobRoleId, equals('10'));
        expect(capturedQuery!.overdueOnly, isTrue);
        expect(capturedQuery!.page, equals(1));
      },
    );

    testWidgets(
      'switching to All courses resets training version and retains other filters',
      (tester) async {
        setTestViewport(tester);
        final page = const AssignmentReportPageViewData(
          items: [],
          count: 0,
          hasMore: false,
          page: 1,
        );
        AssignmentReportFilterQuery? capturedQuery;

        const initialQuery = AssignmentReportFilterQuery(
          status: 'COMPLETED',
          departmentId: '2',
          trainingId: '101',
          trainingVersionId: '301',
        );

        await tester.pumpWidget(
          buildTestableScreen(
            pageData: page,
            currentQuery: initialQuery,
            onQueryChanged: (q) => capturedQuery = q,
          ),
        );

        await tester.tap(find.byTooltip('Filter options'));
        await tester.pumpAndSettle();

        expect(find.text('Forklift Handling'), findsOneWidget);

        // Switch to All courses
        await tester.tap(find.text('Forklift Handling'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('All courses').last);
        await tester.pumpAndSettle();

        // Apply filters
        await tester.tap(find.text('Apply filters'));
        await tester.pumpAndSettle();

        expect(capturedQuery, isNotNull);
        expect(capturedQuery!.trainingId, isNull);
        expect(capturedQuery!.trainingVersionId, isNull);
        expect(capturedQuery!.status, equals('COMPLETED'));
        expect(capturedQuery!.departmentId, equals('2'));
      },
    );

    testWidgets(
      'active filter chips are displayed and can be removed individually',
      (tester) async {
        setTestViewport(tester);
        final page = const AssignmentReportPageViewData(
          items: [],
          count: 0,
          hasMore: false,
          page: 1,
        );
        AssignmentReportFilterQuery? capturedQuery;

        final query = const AssignmentReportFilterQuery(
          status: 'IN_PROGRESS',
          departmentId: '1',
          overdueOnly: true,
        );

        await tester.pumpWidget(
          buildTestableScreen(
            pageData: page,
            currentQuery: query,
            onQueryChanged: (q) => capturedQuery = q,
          ),
        );

        expect(find.text('Status: In progress'), findsOneWidget);
        expect(find.text('Dept: Gardening Operations'), findsOneWidget);
        expect(find.text('Overdue only'), findsOneWidget);
        expect(find.text('Clear all'), findsOneWidget);

        // Delete the status chip
        final statusChip = find.widgetWithText(
          InputChip,
          'Status: In progress',
        );
        final deleteIcon = find.descendant(
          of: statusChip,
          matching: find.byType(Icon),
        );
        await tester.tap(deleteIcon);
        await tester.pumpAndSettle();

        expect(capturedQuery, isNotNull);
        expect(capturedQuery!.status, isNull);
        expect(capturedQuery!.departmentId, equals('1'));
        expect(capturedQuery!.overdueOnly, isTrue);

        // Tap Clear all
        await tester.ensureVisible(find.text('Clear all'));
        await tester.tap(find.text('Clear all'));
        await tester.pumpAndSettle();

        expect(capturedQuery!.hasActiveFilters, isFalse);
      },
    );

    testWidgets(
      'pagination controls handle single-page and multi-page boundaries',
      (tester) async {
        setTestViewport(tester);
        final item = createSampleItem(id: 1);

        // Single page test
        final singlePage = AssignmentReportPageViewData(
          items: [item],
          count: 5,
          hasMore: false,
          page: 1,
          pageSize: 20,
        );

        await tester.pumpWidget(buildTestableScreen(pageData: singlePage));
        expect(find.text('Page 1 of 1 · 5 total'), findsOneWidget);
        final prevBtnSingle = tester.widget<TextButton>(
          find.widgetWithText(TextButton, 'Previous'),
        );
        final nextBtnSingle = tester.widget<TextButton>(
          find.widgetWithText(TextButton, 'Next'),
        );
        expect(prevBtnSingle.onPressed, isNull);
        expect(nextBtnSingle.onPressed, isNull);

        // Multi-page test (page 1 of 3)
        final multiPage = AssignmentReportPageViewData(
          items: [item],
          count: 50,
          hasMore: true,
          page: 1,
          pageSize: 20,
        );

        int? requestedPage;
        await tester.pumpWidget(
          buildTestableScreen(
            pageData: multiPage,
            onPageChanged: (p) => requestedPage = p,
          ),
        );

        expect(find.text('Page 1 of 3 · 50 total'), findsOneWidget);
        final prevBtn = tester.widget<TextButton>(
          find.widgetWithText(TextButton, 'Previous'),
        );
        final nextBtn = tester.widget<TextButton>(
          find.widgetWithText(TextButton, 'Next'),
        );
        expect(prevBtn.onPressed, isNull);
        expect(nextBtn.onPressed, isNotNull);

        await tester.tap(find.widgetWithText(TextButton, 'Next'));
        await tester.pumpAndSettle();

        expect(requestedPage, equals(2));
      },
    );

    testWidgets('renders ApiErrorView on failure and invokes onRetry', (
      tester,
    ) async {
      setTestViewport(tester);
      var retryCalled = false;
      final error = ApiError(
        message: 'Server error loading assignments',
        statusCode: 500,
      );

      await tester.pumpWidget(
        buildTestableScreen(error: error, onRetry: () => retryCalled = true),
      );

      expect(find.text('Server error loading assignments'), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);

      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(retryCalled, isTrue);
    });

    testWidgets('handles long text without visual overflow', (tester) async {
      setTestViewport(tester);
      final longItem = createSampleItem(
        id: 99,
        employeeName: 'Very Long Employee Name That Might Overflow Layouts Under Constrained Space Conditions',
        trainingTitle: 'Comprehensive Global Enterprise Operational Environmental Health and Botanical Safety Certification Curriculum Course',
        versionTitle: 'Long Descriptive Version Title Explaining Compliance In Full Length',
        departmentName: 'Botanical Sciences Operations and Cross-Functional Nursery Facilities Management Division',
        jobRoleName: 'Principal Senior Horticultural Architect and Agricultural Quality Inspector',
      );

      final page = AssignmentReportPageViewData(
        items: [longItem],
        count: 1,
        hasMore: false,
        page: 1,
      );

      await tester.pumpWidget(buildTestableScreen(pageData: page));
      expect(tester.takeException(), isNull);
      expect(find.textContaining('Very Long Employee Name'), findsOneWidget);
    });

    testWidgets('long certificate wraps and opens at 320px with 2x text', (
      tester,
    ) async {
      setTestViewport(tester, const Size(320, 800));
      final semantics = tester.ensureSemantics();
      try {
        const number = 'GN-CERT-2026-000000000000000000000000000000000001';
        final item = createSampleItem(
          status: 'COMPLETED',
          statusDisplay: 'Completed',
          dueAt: DateTime.parse('2026-11-26T23:59:59Z'),
          certificateId: 44,
          certificateNumber: number,
          isCertificateRevoked: true,
        );
        final page = AssignmentReportPageViewData(
          items: [item],
          count: 1,
          hasMore: false,
          page: 1,
        );
        int? openedCertificate;
        await tester.pumpWidget(
          buildTestableScreen(
            pageData: page,
            textScaleFactor: 2,
            onCertificateTap: (id) => openedCertificate = id,
          ),
        );

        final certificate = find.text(number);
        expect(certificate, findsOneWidget);
        await tester.ensureVisible(certificate);
        await tester.pumpAndSettle();
        expect(tester.getSize(certificate).height, greaterThan(48));
        expect(
          find.bySemanticsLabel(RegExp(RegExp.escape(number))),
          findsOneWidget,
        );
        expect(find.text('REVOKED'), findsOneWidget);
        expect(find.textContaining('2026-11-26'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.tap(certificate.hitTestable());
        expect(openedCertificate, 44);
      } finally {
        semantics.dispose();
      }
    });

    testWidgets('renders cleanly on narrow screen (320px) without overflow', (
      tester,
    ) async {
      setTestViewport(tester, const Size(320, 800));
      final item = createSampleItem(id: 1);
      final page = AssignmentReportPageViewData(
        items: [item],
        count: 25,
        hasMore: true,
        page: 1,
      );

      await tester.pumpWidget(buildTestableScreen(pageData: page));
      expect(tester.takeException(), isNull);
      expect(find.text('Alice Johnson'), findsOneWidget);
      expect(find.text('Page 1 of 2 · 25 total'), findsOneWidget);
    });

    testWidgets('renders cleanly under large text scale (2.0x)', (
      tester,
    ) async {
      setTestViewport(tester, const Size(800, 1600));
      final item = createSampleItem(id: 1);
      final page = AssignmentReportPageViewData(
        items: [item],
        count: 1,
        hasMore: false,
        page: 1,
      );

      await tester.pumpWidget(
        buildTestableScreen(pageData: page, textScaleFactor: 2.0),
      );

      expect(tester.takeException(), isNull);
      expect(find.text('Alice Johnson'), findsOneWidget);
    });

    testWidgets('renders tablet layout (1024px) cleanly', (tester) async {
      setTestViewport(tester, const Size(1024, 768));
      final item = createSampleItem(id: 1);
      final page = AssignmentReportPageViewData(
        items: [item],
        count: 1,
        hasMore: false,
        page: 1,
      );

      await tester.pumpWidget(buildTestableScreen(pageData: page));
      expect(tester.takeException(), isNull);
      expect(find.text('Alice Johnson'), findsOneWidget);
    });

    testWidgets(
      'missing optional presentation fields are safely displayed with fallbacks',
      (tester) async {
        setTestViewport(tester);
        final fallbackItem = AssignmentReportItemViewData(
          id: 77,
          employeeName: '',
          employeeCode: '',
          departmentName: '',
          jobRoleName: '',
          trainingTitle: '',
          versionTitle: '',
          versionNumber: 3,
          status: 'ASSIGNED',
          statusDisplay: 'Assigned',
          isOverdue: false,
          assignedAt: null,
          dueAt: null,
          completedAt: null,
        );

        final page = AssignmentReportPageViewData(
          items: [fallbackItem],
          count: 1,
          hasMore: false,
          page: 1,
        );

        await tester.pumpWidget(buildTestableScreen(pageData: page));
        expect(tester.takeException(), isNull);
        expect(find.text('Unknown employee'), findsOneWidget);
        expect(find.text('ID: N/A'), findsOneWidget);
        expect(find.text('Untitled training'), findsOneWidget);
        expect(find.text('Version 3 · Version 3'), findsOneWidget);
        expect(find.textContaining('No deadline'), findsOneWidget);
      },
    );

    testWidgets(
      'strictly read-only: no mutation controls or unsupported exports exist',
      (tester) async {
        setTestViewport(tester);
        final item = createSampleItem(id: 1);
        final page = AssignmentReportPageViewData(
          items: [item],
          count: 1,
          hasMore: false,
          page: 1,
        );

        await tester.pumpWidget(buildTestableScreen(pageData: page));

        // No mutation or export controls
        expect(find.text('Create'), findsNothing);
        expect(find.text('Add'), findsNothing);
        expect(find.text('Edit'), findsNothing);
        expect(find.text('Delete'), findsNothing);
        expect(find.text('Export'), findsNothing);
        expect(find.text('Download'), findsNothing);
        expect(find.text('CSV'), findsNothing);
        expect(find.text('PDF'), findsNothing);
        expect(find.byIcon(Icons.download), findsNothing);
        expect(find.byIcon(Icons.file_download), findsNothing);
      },
    );
  });
}
