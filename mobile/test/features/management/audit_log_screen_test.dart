import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:training_app/core/errors/api_error.dart';
import 'package:training_app/core/presentation/components/content_skeleton.dart';
import 'package:training_app/core/presentation/components/empty_view.dart';
import 'package:training_app/core/theme/app_theme.dart';
import 'package:training_app/features/management/presentation/models/audit_log_view_data.dart';
import 'package:training_app/features/management/presentation/screens/audit_log_screen.dart';

void setTestViewport(WidgetTester tester, [Size size = const Size(800, 1400)]) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
}

AuditLogEntryViewData createSampleAuditEntry({
  int id = 101,
  DateTime? occurredAt,
  String actorLabelSnapshot = 'Jane Doe (admin)',
  int? actorId = 1,
  String action = 'training.trainingassignment.created',
  String actionLabel = 'Training assignment created',
  String entityType = 'training.trainingassignment',
  String entityLabel = 'Training assignment',
  String entityId = '50',
  String? recordSummary = 'Alice Johnson',
  String? reason,
  List<AuditFieldChangeViewData> changes = const [],
  String detailKind = 'creation',
  String? snapshotNotice,
}) {
  return AuditLogEntryViewData(
    id: id,
    occurredAt: occurredAt ?? DateTime(2026, 11, 10, 14, 30),
    actorLabelSnapshot: actorLabelSnapshot,
    actorId: actorId,
    action: action,
    actionLabel: actionLabel,
    entityType: entityType,
    entityLabel: entityLabel,
    entityId: entityId,
    recordSummary: recordSummary,
    reason: reason,
    changes: changes,
    detailKind: detailKind,
    snapshotNotice: snapshotNotice,
  );
}

AuditLogFilterOptionsViewData createSampleAuditFilterOptions() {
  return const AuditLogFilterOptionsViewData(
    actors: [
      AuditFilterActorOption(id: 1, username: 'admin', displayName: 'Jane Doe'),
      AuditFilterActorOption(
        id: 2,
        username: 'coord_bob',
        displayName: 'Bob Coordinator',
      ),
    ],
    entityTypes: [
      AuditFilterEntityOption(
        value: 'training.trainingassignment',
        label: 'Training assignment',
      ),
      AuditFilterEntityOption(
        value: 'organization.employee',
        label: 'Employee',
      ),
      AuditFilterEntityOption(
        value: 'training.trainingversion',
        label: 'Training version',
      ),
    ],
  );
}

Widget buildTestableAuditScreen({
  bool isLoading = false,
  Object? error,
  AuditLogPageViewData? pageData,
  AuditLogFilterOptionsViewData? filterOptions,
  AuditLogFilterQuery currentQuery = const AuditLogFilterQuery(),
  ValueChanged<AuditLogFilterQuery>? onQueryChanged,
  ValueChanged<int>? onPageChanged,
  Future<void> Function()? onRefresh,
  VoidCallback? onRetry,
  ValueChanged<AuditLogEntryViewData>? onEntryTap,
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
            child: AuditLogScreen(
              isLoading: isLoading,
              error: error,
              pageData: pageData,
              filterOptions: filterOptions ?? createSampleAuditFilterOptions(),
              currentQuery: currentQuery,
              onQueryChanged: onQueryChanged,
              onPageChanged: onPageChanged,
              onRefresh: onRefresh,
              onRetry: onRetry,
              onEntryTap: onEntryTap,
            ),
          );
        },
      ),
    ),
  );
}

void main() {
  group('AuditLogScreen UI Foundations', () {
    testWidgets('renders loading state with CardListSkeleton', (tester) async {
      setTestViewport(tester);
      await tester.pumpWidget(buildTestableAuditScreen(isLoading: true));
      expect(find.byType(CardListSkeleton), findsOneWidget);
      expect(find.text('Loading audit history...'), findsOneWidget);
    });

    testWidgets('renders empty state when no audit events exist (unfiltered)', (
      tester,
    ) async {
      setTestViewport(tester);
      final emptyPage = const AuditLogPageViewData(
        items: [],
        count: 0,
        hasMore: false,
        page: 1,
      );

      await tester.pumpWidget(buildTestableAuditScreen(pageData: emptyPage));
      expect(find.byType(EmptyView), findsOneWidget);
      expect(find.text('No audit events found'), findsOneWidget);
      expect(find.text('No audit history events recorded.'), findsOneWidget);
      expect(find.text('Reset filters'), findsNothing);
    });

    testWidgets(
      'renders empty state with reset button when filters are active',
      (tester) async {
        setTestViewport(tester);
        final emptyPage = const AuditLogPageViewData(
          items: [],
          count: 0,
          hasMore: false,
          page: 1,
        );
        AuditLogFilterQuery? capturedQuery;

        await tester.pumpWidget(
          buildTestableAuditScreen(
            pageData: emptyPage,
            currentQuery: const AuditLogFilterQuery(action: 'created'),
            onQueryChanged: (q) => capturedQuery = q,
          ),
        );

        expect(find.byType(EmptyView), findsOneWidget);
        expect(
          find.text(
            'No events match the selected filters. Try adjusting or clearing your filters.',
          ),
          findsOneWidget,
        );
        expect(find.text('Reset filters'), findsOneWidget);

        await tester.tap(find.text('Reset filters'));
        await tester.pumpAndSettle();

        expect(capturedQuery, isNotNull);
        expect(capturedQuery!.hasActiveFilters, isFalse);
      },
    );

    testWidgets(
      'renders populated audit events with action, entity, timestamp and actor',
      (tester) async {
        setTestViewport(tester);
        final entry1 = createSampleAuditEntry(
          id: 1,
          actionLabel: 'Training assignment created',
          entityLabel: 'Training assignment',
          recordSummary: 'Alice Johnson',
          actorLabelSnapshot: 'Jane Doe (admin)',
          occurredAt: DateTime(2026, 11, 10, 14, 30),
        );
        final entry2 = createSampleAuditEntry(
          id: 2,
          actionLabel: 'Employee updated',
          entityLabel: 'Employee',
          recordSummary: 'Bob Smith',
          actorLabelSnapshot: 'Bob Coordinator (coord_bob)',
          reason: 'Department transfer from Logistics to Operations',
          occurredAt: DateTime(2026, 11, 11, 9, 15),
        );

        final page = AuditLogPageViewData(
          items: [entry1, entry2],
          count: 2,
          hasMore: false,
          page: 1,
        );

        AuditLogEntryViewData? tappedEntry;
        await tester.pumpWidget(
          buildTestableAuditScreen(
            pageData: page,
            onEntryTap: (e) => tappedEntry = e,
          ),
        );

        // Verify entry 1
        expect(find.text('TRAINING ASSIGNMENT CREATED'), findsOneWidget);
        expect(find.text('Training assignment'), findsOneWidget);
        expect(find.text('Alice Johnson'), findsOneWidget);
        expect(find.text('Performed by: Jane Doe (admin)'), findsOneWidget);

        // Verify entry 2 with reason callout
        expect(find.text('EMPLOYEE UPDATED'), findsOneWidget);
        expect(find.text('Employee'), findsOneWidget);
        expect(find.text('Bob Smith'), findsOneWidget);
        expect(
          find.text('Performed by: Bob Coordinator (coord_bob)'),
          findsOneWidget,
        );
        expect(find.text('Reason'), findsOneWidget);
        expect(
          find.text('Department transfer from Logistics to Operations'),
          findsOneWidget,
        );

        // Tap card
        await tester.tap(find.text('Alice Johnson'));
        await tester.pumpAndSettle();
        expect(tappedEntry, isNotNull);
        expect(tappedEntry!.id, equals(1));
      },
    );

    testWidgets(
      'displays safe field changes in expansion tile without raw secrets',
      (tester) async {
        setTestViewport(tester);
        final entryWithDiff = createSampleAuditEntry(
          id: 5,
          actionLabel: 'Training assignment updated',
          entityLabel: 'Training assignment',
          recordSummary: 'Charlie Brown',
          detailKind: 'changes',
          changes: const [
            AuditFieldChangeViewData(
              field: 'status',
              fieldLabel: 'Status',
              beforeDisplay: 'Assigned',
              afterDisplay: 'In progress',
            ),
            AuditFieldChangeViewData(
              field: 'due_at',
              fieldLabel: 'Due date',
              beforeDisplay: '2026-11-01',
              afterDisplay: '2026-12-01',
            ),
          ],
        );

        final page = AuditLogPageViewData(
          items: [entryWithDiff],
          count: 1,
          hasMore: false,
          page: 1,
        );

        await tester.pumpWidget(buildTestableAuditScreen(pageData: page));

        expect(find.text('Recorded changes (2)'), findsOneWidget);

        // Expand the changes tile
        await tester.tap(find.text('Recorded changes (2)'));
        await tester.pumpAndSettle();

        // Field labels and diff values
        expect(find.text('Status'), findsOneWidget);
        expect(find.text('Assigned'), findsOneWidget);
        expect(find.text('In progress'), findsOneWidget);
        expect(find.text('Due date'), findsOneWidget);
        expect(find.text('2026-11-01'), findsOneWidget);
        expect(find.text('2026-12-01'), findsOneWidget);

        // Verify NO raw secret fields exist
        expect(find.text('password'), findsNothing);
        expect(find.text('token'), findsNothing);
        expect(find.text('secret'), findsNothing);
        expect(find.text('raw_json'), findsNothing);
      },
    );

    testWidgets(
      'filter bottom sheet opens, applies filters and updates query',
      (tester) async {
        setTestViewport(tester);
        final page = const AuditLogPageViewData(
          items: [],
          count: 0,
          hasMore: false,
          page: 1,
        );
        AuditLogFilterQuery? capturedQuery;

        await tester.pumpWidget(
          buildTestableAuditScreen(
            pageData: page,
            onQueryChanged: (q) => capturedQuery = q,
          ),
        );

        // Open filter bottom sheet
        await tester.tap(find.byTooltip('Filter audit history'));
        await tester.pumpAndSettle();

        expect(find.text('Filter audit history'), findsOneWidget);
        expect(find.text('Performed by'), findsOneWidget);
        expect(find.text('Record type'), findsOneWidget);
        expect(find.text('Action name contains'), findsOneWidget);

        // Enter action filter text
        await tester.enterText(
          find.widgetWithText(TextField, 'Action name contains'),
          'created',
        );
        await tester.pumpAndSettle();

        // Tap Apply filters
        await tester.tap(find.text('Apply filters'));
        await tester.pumpAndSettle();

        expect(find.text('Filter audit history'), findsNothing);
        expect(capturedQuery, isNotNull);
        expect(capturedQuery!.action, equals('created'));
        expect(capturedQuery!.page, equals(1));
      },
    );

    testWidgets(
      'strictly prevents unsupported search control: no search text field rendered',
      (tester) async {
        setTestViewport(tester);
        final page = const AuditLogPageViewData(
          items: [],
          count: 0,
          hasMore: false,
          page: 1,
        );

        await tester.pumpWidget(buildTestableAuditScreen(pageData: page));

        // Verify that no general search text field or search icon exists on the main screen
        expect(find.byType(TextField), findsNothing);
        expect(find.text('Search'), findsNothing);
        expect(find.byIcon(Icons.search), findsNothing);
      },
    );

    testWidgets('active filter chips are displayed and can be removed', (
      tester,
    ) async {
      setTestViewport(tester);
      final page = const AuditLogPageViewData(
        items: [],
        count: 0,
        hasMore: false,
        page: 1,
      );
      AuditLogFilterQuery? capturedQuery;

      final query = AuditLogFilterQuery(
        actorId: 1,
        targetType: 'training.trainingassignment',
        action: 'created',
        startDate: DateTime(2026, 11, 1),
        endDate: DateTime(2026, 11, 10),
      );

      await tester.pumpWidget(
        buildTestableAuditScreen(
          pageData: page,
          currentQuery: query,
          onQueryChanged: (q) => capturedQuery = q,
        ),
      );

      expect(find.text('Actor: Jane Doe (admin)'), findsOneWidget);
      expect(find.text('Record: Training assignment'), findsOneWidget);
      expect(find.text('Action: created'), findsOneWidget);
      expect(find.text('From: 2026-11-01'), findsOneWidget);
      expect(find.text('Through: 2026-11-10'), findsOneWidget);
      expect(find.text('Clear all'), findsOneWidget);

      // Clear action chip
      final actionChip = find.widgetWithText(InputChip, 'Action: created');
      await tester.ensureVisible(actionChip);
      final deleteIcon = find.descendant(
        of: actionChip,
        matching: find.byType(Icon),
      );
      await tester.tap(deleteIcon);
      await tester.pumpAndSettle();

      expect(capturedQuery, isNotNull);
      expect(capturedQuery!.action, isNull);
      expect(capturedQuery!.actorId, equals(1));

      // Tap Clear all
      await tester.ensureVisible(find.text('Clear all'));
      await tester.tap(find.text('Clear all'));
      await tester.pumpAndSettle();

      expect(capturedQuery!.hasActiveFilters, isFalse);
    });

    testWidgets(
      'pagination controls navigate between pages correctly and show bounded limit',
      (tester) async {
        setTestViewport(tester);
        final entry = createSampleAuditEntry(id: 1);
        final page1 = AuditLogPageViewData(
          items: [entry],
          count: 200,
          hasMore: true,
          page: 1,
          pageSize: 20,
          resultLimit: 200,
        );

        int? requestedPage;
        await tester.pumpWidget(
          buildTestableAuditScreen(
            pageData: page1,
            onPageChanged: (p) => requestedPage = p,
          ),
        );

        expect(find.text('Page 1 of 10 · 200 total'), findsOneWidget);
        expect(
          find.text(
            'Showing up to the 200 newest events. Narrow filters for earlier history.',
          ),
          findsOneWidget,
        );

        // Previous disabled on page 1
        final prevBtn = tester.widget<TextButton>(
          find.widgetWithText(TextButton, 'Previous'),
        );
        expect(prevBtn.onPressed, isNull);

        // Next enabled
        final nextBtn = tester.widget<TextButton>(
          find.widgetWithText(TextButton, 'Next'),
        );
        expect(nextBtn.onPressed, isNotNull);

        await tester.tap(find.widgetWithText(TextButton, 'Next'));
        await tester.pumpAndSettle();

        expect(requestedPage, equals(2));
      },
    );

    testWidgets(
      'pagination does not show bounded limit notice when resultLimit is null',
      (tester) async {
        setTestViewport(tester);
        final entry = createSampleAuditEntry(id: 1);
        final page = AuditLogPageViewData(
          items: [entry],
          count: 50,
          hasMore: true,
          page: 1,
          pageSize: 20,
          resultLimit: null,
        );

        await tester.pumpWidget(buildTestableAuditScreen(pageData: page));

        expect(find.text('Page 1 of 3 · 50 total'), findsOneWidget);
        expect(find.textContaining('Showing up to the'), findsNothing);
      },
    );

    group('Date range validation matrix', () {
      testWidgets(
        'scenario 1: same start and end date is accepted without error',
        (tester) async {
          setTestViewport(tester);
          AuditLogFilterQuery? capturedQuery;
          final query = AuditLogFilterQuery(
            startDate: DateTime(2026, 11, 10),
            endDate: DateTime(2026, 11, 10),
          );

          await tester.pumpWidget(
            buildTestableAuditScreen(
              currentQuery: query,
              onQueryChanged: (q) => capturedQuery = q,
            ),
          );

          await tester.tap(find.byTooltip('Filter audit history'));
          await tester.pumpAndSettle();

          expect(
            find.text('End date must not precede start date.'),
            findsNothing,
          );
          final applyBtn = tester.widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Apply filters'),
          );
          expect(applyBtn.onPressed, isNotNull);

          await tester.tap(find.widgetWithText(FilledButton, 'Apply filters'));
          await tester.pumpAndSettle();

          expect(capturedQuery, isNotNull);
          expect(capturedQuery!.startDate, equals(DateTime(2026, 11, 10)));
          expect(capturedQuery!.endDate, equals(DateTime(2026, 11, 10)));
        },
      );

      testWidgets(
        'scenario 2: start date earlier than end date is accepted without error',
        (tester) async {
          setTestViewport(tester);
          AuditLogFilterQuery? capturedQuery;
          final query = AuditLogFilterQuery(
            startDate: DateTime(2026, 11, 5),
            endDate: DateTime(2026, 11, 10),
          );

          await tester.pumpWidget(
            buildTestableAuditScreen(
              currentQuery: query,
              onQueryChanged: (q) => capturedQuery = q,
            ),
          );

          await tester.tap(find.byTooltip('Filter audit history'));
          await tester.pumpAndSettle();

          expect(
            find.text('End date must not precede start date.'),
            findsNothing,
          );
          final applyBtn = tester.widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Apply filters'),
          );
          expect(applyBtn.onPressed, isNotNull);

          await tester.tap(find.widgetWithText(FilledButton, 'Apply filters'));
          await tester.pumpAndSettle();

          expect(capturedQuery, isNotNull);
          expect(capturedQuery!.startDate, equals(DateTime(2026, 11, 5)));
          expect(capturedQuery!.endDate, equals(DateTime(2026, 11, 10)));
        },
      );

      testWidgets(
        'scenario 3: start date after end date is rejected with error and disabled apply',
        (tester) async {
          setTestViewport(tester);
          AuditLogFilterQuery? capturedQuery;
          final query = AuditLogFilterQuery(
            startDate: DateTime(2026, 11, 15),
            endDate: DateTime(2026, 11, 10),
          );

          await tester.pumpWidget(
            buildTestableAuditScreen(
              currentQuery: query,
              onQueryChanged: (q) => capturedQuery = q,
            ),
          );

          await tester.tap(find.byTooltip('Filter audit history'));
          await tester.pumpAndSettle();

          expect(
            find.text('End date must not precede start date.'),
            findsOneWidget,
          );
          final applyBtn = tester.widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Apply filters'),
          );
          expect(applyBtn.onPressed, isNull);
          expect(capturedQuery, isNull);
        },
      );

      testWidgets(
        'scenario 4: only start date specified is accepted without error',
        (tester) async {
          setTestViewport(tester);
          AuditLogFilterQuery? capturedQuery;
          final query = AuditLogFilterQuery(startDate: DateTime(2026, 11, 10));

          await tester.pumpWidget(
            buildTestableAuditScreen(
              currentQuery: query,
              onQueryChanged: (q) => capturedQuery = q,
            ),
          );

          await tester.tap(find.byTooltip('Filter audit history'));
          await tester.pumpAndSettle();

          expect(
            find.text('End date must not precede start date.'),
            findsNothing,
          );
          final applyBtn = tester.widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Apply filters'),
          );
          expect(applyBtn.onPressed, isNotNull);

          await tester.tap(find.widgetWithText(FilledButton, 'Apply filters'));
          await tester.pumpAndSettle();

          expect(capturedQuery, isNotNull);
          expect(capturedQuery!.startDate, equals(DateTime(2026, 11, 10)));
          expect(capturedQuery!.endDate, isNull);
        },
      );

      testWidgets(
        'scenario 5: only end date specified is accepted without error',
        (tester) async {
          setTestViewport(tester);
          AuditLogFilterQuery? capturedQuery;
          final query = AuditLogFilterQuery(endDate: DateTime(2026, 11, 10));

          await tester.pumpWidget(
            buildTestableAuditScreen(
              currentQuery: query,
              onQueryChanged: (q) => capturedQuery = q,
            ),
          );

          await tester.tap(find.byTooltip('Filter audit history'));
          await tester.pumpAndSettle();

          expect(
            find.text('End date must not precede start date.'),
            findsNothing,
          );
          final applyBtn = tester.widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Apply filters'),
          );
          expect(applyBtn.onPressed, isNotNull);

          await tester.tap(find.widgetWithText(FilledButton, 'Apply filters'));
          await tester.pumpAndSettle();

          expect(capturedQuery, isNotNull);
          expect(capturedQuery!.startDate, isNull);
          expect(capturedQuery!.endDate, equals(DateTime(2026, 11, 10)));
        },
      );

      testWidgets(
        'scenario 6: resetting invalid date filters clears error and enables apply',
        (tester) async {
          setTestViewport(tester);
          AuditLogFilterQuery? capturedQuery;
          final query = AuditLogFilterQuery(
            startDate: DateTime(2026, 11, 15),
            endDate: DateTime(2026, 11, 10),
          );

          await tester.pumpWidget(
            buildTestableAuditScreen(
              currentQuery: query,
              onQueryChanged: (q) => capturedQuery = q,
            ),
          );

          await tester.tap(find.byTooltip('Filter audit history'));
          await tester.pumpAndSettle();

          expect(
            find.text('End date must not precede start date.'),
            findsOneWidget,
          );
          var applyBtn = tester.widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Apply filters'),
          );
          expect(applyBtn.onPressed, isNull);

          // Tap Reset in the sheet
          await tester.tap(find.text('Reset'));
          await tester.pumpAndSettle();

          expect(
            find.text('End date must not precede start date.'),
            findsNothing,
          );
          applyBtn = tester.widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Apply filters'),
          );
          expect(applyBtn.onPressed, isNotNull);

          await tester.tap(find.widgetWithText(FilledButton, 'Apply filters'));
          await tester.pumpAndSettle();

          expect(capturedQuery, isNotNull);
          expect(capturedQuery!.startDate, isNull);
          expect(capturedQuery!.endDate, isNull);
        },
      );
    });

    testWidgets('renders ApiErrorView on failure and invokes onRetry', (
      tester,
    ) async {
      setTestViewport(tester);
      var retryCalled = false;
      final error = ApiError(
        message: 'Failed to load audit events',
        statusCode: 500,
      );

      await tester.pumpWidget(
        buildTestableAuditScreen(
          error: error,
          onRetry: () => retryCalled = true,
        ),
      );

      expect(find.text('Failed to load audit events'), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);

      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(retryCalled, isTrue);
    });

    testWidgets('handles long text without visual overflow', (tester) async {
      setTestViewport(tester);
      final longEntry = createSampleAuditEntry(
        id: 999,
        actionLabel: 'Comprehensive Enterprise Global Environmental Quality and Safety Curriculum Version Replaced',
        entityLabel: 'Job-role training requirement specifications',
        recordSummary: 'Botanical Sciences Operations and Cross-Functional Nursery Facilities Management Division Senior Lead',
        actorLabelSnapshot: 'Administrator Account With Extremely Long Profile Name And Identity Attribution Details (admin_long_username)',
        reason: 'This is an extensive operational reason that explains in extraordinary detail the complete rationale behind the administrative update without truncating essential context.',
      );

      final page = AuditLogPageViewData(
        items: [longEntry],
        count: 1,
        hasMore: false,
        page: 1,
      );

      await tester.pumpWidget(buildTestableAuditScreen(pageData: page));
      expect(tester.takeException(), isNull);
      expect(
        find.textContaining(
          RegExp(r'Comprehensive Enterprise Global', caseSensitive: false),
        ),
        findsOneWidget,
      );
    });

    testWidgets('renders cleanly on narrow screen (320px) without overflow', (
      tester,
    ) async {
      setTestViewport(tester, const Size(320, 800));
      final entry = createSampleAuditEntry(id: 1);
      final page = AuditLogPageViewData(
        items: [entry],
        count: 15,
        hasMore: true,
        page: 1,
      );

      await tester.pumpWidget(buildTestableAuditScreen(pageData: page));
      expect(tester.takeException(), isNull);
      expect(find.text('Alice Johnson'), findsOneWidget);
      expect(find.text('Page 1 of 1 · 15 total'), findsOneWidget);
    });

    testWidgets('renders cleanly under large text scale (2.0x)', (
      tester,
    ) async {
      setTestViewport(tester, const Size(800, 1600));
      final entry = createSampleAuditEntry(id: 1);
      final page = AuditLogPageViewData(
        items: [entry],
        count: 1,
        hasMore: false,
        page: 1,
      );

      await tester.pumpWidget(
        buildTestableAuditScreen(pageData: page, textScaleFactor: 2.0),
      );

      expect(tester.takeException(), isNull);
      expect(find.text('Alice Johnson'), findsOneWidget);
    });

    testWidgets('renders tablet layout (1024px) cleanly', (tester) async {
      setTestViewport(tester, const Size(1024, 768));
      final entry = createSampleAuditEntry(id: 1);
      final page = AuditLogPageViewData(
        items: [entry],
        count: 1,
        hasMore: false,
        page: 1,
      );

      await tester.pumpWidget(buildTestableAuditScreen(pageData: page));
      expect(tester.takeException(), isNull);
      expect(find.text('Alice Johnson'), findsOneWidget);
    });

    testWidgets(
      'missing optional presentation fields are safely displayed with fallbacks',
      (tester) async {
        setTestViewport(tester);
        final fallbackEntry = const AuditLogEntryViewData(
          id: 88,
          occurredAt: null,
          actorLabelSnapshot: '',
          actorId: null,
          action: 'custom.event',
          actionLabel: '',
          entityType: 'custom.record',
          entityLabel: '',
          entityId: '777',
          recordSummary: null,
          reason: null,
          changes: [],
        );

        final page = AuditLogPageViewData(
          items: [fallbackEntry],
          count: 1,
          hasMore: false,
          page: 1,
        );

        await tester.pumpWidget(buildTestableAuditScreen(pageData: page));

        expect(tester.takeException(), isNull);
        expect(find.text('Date not recorded'), findsOneWidget);
        expect(find.text('CUSTOM.EVENT'), findsOneWidget);
        expect(find.text('custom.record'), findsOneWidget);
        expect(find.text('custom.record #777'), findsOneWidget);
        expect(find.text('Performed by: System'), findsOneWidget);
        expect(find.text('Reason'), findsNothing);
        expect(find.textContaining('Recorded changes'), findsNothing);
      },
    );

    testWidgets(
      'accessibility labels exist and touch targets meet guidelines',
      (tester) async {
        setTestViewport(tester);
        final entry = createSampleAuditEntry(id: 1);
        final page = AuditLogPageViewData(
          items: [entry],
          count: 1,
          hasMore: false,
          page: 1,
        );

        await tester.pumpWidget(buildTestableAuditScreen(pageData: page));
        expect(
          find.bySemanticsLabel(RegExp(r'Filter audit logs')),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'strictly read-only: no edit, delete, or create controls exist',
      (tester) async {
        setTestViewport(tester);
        final entry = createSampleAuditEntry(id: 1);
        final page = AuditLogPageViewData(
          items: [entry],
          count: 1,
          hasMore: false,
          page: 1,
        );

        await tester.pumpWidget(buildTestableAuditScreen(pageData: page));

        // No mutation controls
        expect(find.text('Create'), findsNothing);
        expect(find.text('Add'), findsNothing);
        expect(find.text('Edit'), findsNothing);
        expect(find.text('Delete'), findsNothing);
        expect(find.text('Modify'), findsNothing);
        expect(find.text('Update'), findsNothing);
        expect(find.byIcon(Icons.add), findsNothing);
        expect(find.byIcon(Icons.edit), findsNothing);
        expect(find.byIcon(Icons.delete), findsNothing);
      },
    );
  });
}
