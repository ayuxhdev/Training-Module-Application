import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:training_app/core/presentation/components/api_error_view.dart';
import 'package:training_app/core/presentation/components/content_skeleton.dart';
import 'package:training_app/core/presentation/components/custom_card.dart';
import 'package:training_app/core/presentation/components/empty_view.dart';
import 'package:training_app/core/presentation/components/status_badge.dart';
import 'package:training_app/core/presentation/formatters/date_labels.dart';
import 'package:training_app/core/theme/app_colors.dart';
import 'package:training_app/core/theme/app_spacing.dart';
import 'package:training_app/features/auth/domain/models/auth_state.dart';
import 'package:training_app/features/auth/presentation/controllers/auth_controller.dart';
import 'package:training_app/features/management/data/repositories/management_repository.dart';
import 'package:training_app/features/management/presentation/controllers/management_controller.dart';
import 'package:training_app/features/management/presentation/models/assignment_report_view_data.dart';

/// Permission-aware presentation screen for filtered assignment reports.
/// Exposes strictly supported backend filter dimensions: status, department,
/// job_role, training, training_version, and overdue_only.
class AssignmentReportScreen extends ConsumerStatefulWidget {
  final bool? isLoading;
  final Object? error;
  final AssignmentReportPageViewData? pageData;
  final AssignmentReportFilterOptionsViewData? filterOptions;
  final AssignmentReportFilterQuery? currentQuery;
  final ValueChanged<AssignmentReportFilterQuery>? onQueryChanged;
  final ValueChanged<int>? onPageChanged;
  final Future<void> Function()? onRefresh;
  final VoidCallback? onRetry;
  final ValueChanged<int>? onCertificateTap;

  const AssignmentReportScreen({
    super.key,
    this.isLoading,
    this.error,
    this.pageData,
    this.filterOptions,
    this.currentQuery,
    this.onQueryChanged,
    this.onPageChanged,
    this.onRefresh,
    this.onRetry,
    this.onCertificateTap,
  });

  @override
  ConsumerState<AssignmentReportScreen> createState() =>
      _AssignmentReportScreenState();
}

class _AssignmentReportScreenState
    extends ConsumerState<AssignmentReportScreen> {
  late AssignmentReportFilterQuery _query;

  @override
  void initState() {
    super.initState();
    _query = widget.currentQuery ?? const AssignmentReportFilterQuery();
  }

  @override
  void didUpdateWidget(covariant AssignmentReportScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.currentQuery != null &&
        widget.currentQuery != oldWidget.currentQuery) {
      _query = widget.currentQuery!;
    }
  }

  bool get _isControlled =>
      widget.onQueryChanged != null ||
      widget.pageData != null ||
      widget.isLoading != null;

  void _applyQuery(AssignmentReportFilterQuery newQuery) {
    setState(() => _query = newQuery);
    widget.onQueryChanged?.call(newQuery);
  }

  AssignmentReportFilterOptionsViewData _availableOptions(
    AsyncValue<AssignmentReportFilterOptionsViewData> options,
  ) {
    if (options.isLoading) return const AssignmentReportFilterOptionsViewData();
    final error = options.error;
    if (error
        is FilterOptionsLoadFailure<AssignmentReportFilterOptionsViewData>) {
      return error.completeOptions;
    }
    return options.asData?.value ??
        widget.filterOptions ??
        const AssignmentReportFilterOptionsViewData();
  }

  void _openFilterSheet(AssignmentReportFilterOptionsViewData filterOptions) {
    final account = managementAccount(ref.read(authControllerProvider));
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (sheetContext) => Consumer(
        builder: (context, ref, child) {
          if (!_isControlled &&
              managementAccount(ref.watch(authControllerProvider)) != account) {
            return Padding(
              padding: const EdgeInsets.all(AppSpacing.md),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('The account changed. Close and reopen filters.'),
                  TextButton(
                    onPressed: () => Navigator.of(sheetContext).pop(),
                    child: const Text('Close filters'),
                  ),
                ],
              ),
            );
          }
          final options = _isControlled
              ? null
              : ref.watch(assignmentReportFilterOptionsProvider);
          return _AssignmentReportFilterSheet(
            filterOptions: options == null
                ? filterOptions
                : _availableOptions(options),
            filtersLoading: options?.isLoading ?? false,
            filtersError: options?.error,
            onRetryFilters: options == null
                ? null
                : () => ref.invalidate(assignmentReportFilterOptionsProvider),
            initialQuery: _query,
            onApply: (newQuery) {
              Navigator.of(sheetContext).pop();
              if (mounted &&
                  (_isControlled ||
                      managementAccount(ref.read(authControllerProvider)) ==
                          account)) {
                _applyQuery(newQuery);
              }
            },
          );
        },
      ),
    );
  }

  void _clearAllFilters() {
    final resetQuery = AssignmentReportFilterQuery(
      pageSize: _query.pageSize,
      page: 1,
    );
    _applyQuery(resetQuery);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (!_isControlled) {
      final auth = ref.watch(authControllerProvider);
      if (auth is! AuthAuthenticated ||
          !canViewAssignmentReports(auth.identity)) {
        return Scaffold(
          appBar: AppBar(title: const Text('Assignment reports')),
          body: const Center(
            child: Text(
              'You do not have permission to view assignment reports.',
            ),
          ),
        );
      }

      final reportAsync = ref.watch(assignmentReportProvider(_query));
      final filterOptionsAsync = ref.watch(
        assignmentReportFilterOptionsProvider,
      );

      final isLoading = reportAsync.isLoading;
      final error = reportAsync.error;
      final pageData = reportAsync.asData?.value;
      final filterOptions = _availableOptions(filterOptionsAsync);

      return _buildScaffold(
        context: context,
        theme: theme,
        isLoading: isLoading,
        error: error,
        pageData: pageData,
        filterOptions: filterOptions,
        filtersLoading: filterOptionsAsync.isLoading,
        filtersError: filterOptionsAsync.error,
        onRetryFilters: () =>
            ref.invalidate(assignmentReportFilterOptionsProvider),
        onRefresh: () async {
          ref.invalidate(assignmentReportProvider);
          ref.invalidate(assignmentReportFilterOptionsProvider);
        },
        onRetry: () => ref.refresh(assignmentReportProvider(_query)),
        onCertificateTap: canViewCertificates(auth.identity)
            ? (certId) => context.push('/workspace/certificates/$certId')
            : null,
      );
    }

    // Controlled mode (tests)
    final effectiveOptions =
        widget.filterOptions ?? const AssignmentReportFilterOptionsViewData();
    return _buildScaffold(
      context: context,
      theme: theme,
      isLoading: widget.isLoading ?? false,
      error: widget.error,
      pageData: widget.pageData,
      filterOptions: effectiveOptions,
      onRefresh: widget.onRefresh,
      onRetry: widget.onRetry,
      onCertificateTap: widget.onCertificateTap,
    );
  }

  Widget _buildScaffold({
    required BuildContext context,
    required ThemeData theme,
    required bool isLoading,
    required Object? error,
    required AssignmentReportPageViewData? pageData,
    required AssignmentReportFilterOptionsViewData filterOptions,
    required Future<void> Function()? onRefresh,
    required VoidCallback? onRetry,
    required ValueChanged<int>? onCertificateTap,
    bool filtersLoading = false,
    Object? filtersError,
    VoidCallback? onRetryFilters,
  }) {
    final activeCount = _query.activeFilterCount;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Assignment reports'),
        actions: [
          Semantics(
            label: 'Filter assignments, $activeCount active',
            button: true,
            child: IconButton(
              tooltip: 'Filter options',
              icon: Badge(
                isLabelVisible: activeCount > 0,
                label: Text('$activeCount'),
                child: const Icon(Icons.filter_list),
              ),
              onPressed: () => _openFilterSheet(filterOptions),
            ),
          ),
          if (onRefresh != null)
            IconButton(
              tooltip: 'Refresh',
              icon: const Icon(Icons.refresh),
              onPressed: isLoading ? null : onRefresh,
            ),
        ],
      ),
      body: Column(
        children: [
          if (filtersLoading)
            Semantics(
              liveRegion: true,
              child: const Padding(
                padding: EdgeInsets.all(AppSpacing.sm),
                child: Text('Loading filter options…'),
              ),
            )
          else if (filtersError != null)
            Semantics(
              liveRegion: true,
              child: Padding(
                padding: const EdgeInsets.all(AppSpacing.sm),
                child: Row(
                  children: [
                    const Expanded(
                      child: Text('Filter options could not be loaded.'),
                    ),
                    TextButton(
                      onPressed: onRetryFilters,
                      child: const Text('Retry filters'),
                    ),
                  ],
                ),
              ),
            ),
          // Active Filter Chips Bar
          if (_query.hasActiveFilters)
            _buildActiveFilterChips(theme, filterOptions),

          // Main Content Area
          Expanded(
            child: _buildBody(
              context: context,
              isLoading: isLoading,
              error: error,
              pageData: pageData,
              onRefresh: onRefresh,
              onRetry: onRetry,
              onCertificateTap: onCertificateTap,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActiveFilterChips(
    ThemeData theme,
    AssignmentReportFilterOptionsViewData filterOptions,
  ) {
    final chips = <Widget>[];

    if (_query.status != null) {
      final statusOpt = filterOptions.statuses.firstWhere(
        (s) => s.value == _query.status,
        orElse: () =>
            ReportFilterOption(value: _query.status!, label: _query.status!),
      );
      chips.add(
        InputChip(
          label: Text('Status: ${statusOpt.label}'),
          onDeleted: () =>
              _applyQuery(_query.copyWith(clearStatus: true, page: 1)),
        ),
      );
    }

    if (_query.departmentId != null) {
      final deptOpt = filterOptions.departments.firstWhere(
        (d) => d.value == _query.departmentId,
        orElse: () => ReportFilterOption(
          value: _query.departmentId!,
          label: 'Dept #${_query.departmentId}',
        ),
      );
      chips.add(
        InputChip(
          label: Text('Dept: ${deptOpt.label}'),
          onDeleted: () =>
              _applyQuery(_query.copyWith(clearDepartment: true, page: 1)),
        ),
      );
    }

    if (_query.jobRoleId != null) {
      final roleOpt = filterOptions.jobRoles.firstWhere(
        (r) => r.value == _query.jobRoleId,
        orElse: () => ReportFilterOption(
          value: _query.jobRoleId!,
          label: 'Role #${_query.jobRoleId}',
        ),
      );
      chips.add(
        InputChip(
          label: Text('Role: ${roleOpt.label}'),
          onDeleted: () =>
              _applyQuery(_query.copyWith(clearJobRole: true, page: 1)),
        ),
      );
    }

    if (_query.trainingId != null) {
      final trainOpt = filterOptions.trainings.firstWhere(
        (t) => t.value == _query.trainingId,
        orElse: () => ReportFilterOption(
          value: _query.trainingId!,
          label: 'Course #${_query.trainingId}',
        ),
      );
      chips.add(
        InputChip(
          label: Text('Course: ${trainOpt.label}'),
          onDeleted: () => _applyQuery(
            _query.copyWith(
              clearTraining: true,
              clearTrainingVersion: true,
              page: 1,
            ),
          ),
        ),
      );
    }

    if (_query.trainingVersionId != null) {
      final verOpt = filterOptions.trainingVersions.firstWhere(
        (v) => v.id.toString() == _query.trainingVersionId,
        orElse: () => ReportVersionFilterOption(
          id: int.tryParse(_query.trainingVersionId!) ?? 0,
          trainingId: 0,
          versionNumber: 0,
          title: 'Version #${_query.trainingVersionId}',
        ),
      );
      chips.add(
        InputChip(
          label: Text('Version: v${verOpt.versionNumber}'),
          onDeleted: () =>
              _applyQuery(_query.copyWith(clearTrainingVersion: true, page: 1)),
        ),
      );
    }

    if (_query.overdueOnly == true) {
      chips.add(
        InputChip(
          avatar: const Icon(Icons.warning_amber_rounded, size: 16),
          label: const Text('Overdue only'),
          onDeleted: () =>
              _applyQuery(_query.copyWith(clearOverdue: true, page: 1)),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
        child: Row(
          children: [
            ...chips.map(
              (c) => Padding(
                padding: const EdgeInsets.only(right: AppSpacing.xs),
                child: c,
              ),
            ),
            ActionChip(
              avatar: const Icon(Icons.clear_all, size: 18),
              label: const Text('Clear all'),
              onPressed: _clearAllFilters,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBody({
    required BuildContext context,
    required bool isLoading,
    required Object? error,
    required AssignmentReportPageViewData? pageData,
    required Future<void> Function()? onRefresh,
    required VoidCallback? onRetry,
    required ValueChanged<int>? onCertificateTap,
  }) {
    if (isLoading && pageData == null) {
      return const SingleChildScrollView(
        padding: EdgeInsets.all(AppSpacing.md),
        child: CardListSkeleton(
          message: 'Loading assignment reports...',
          compact: true,
        ),
      );
    }

    if (error != null && pageData == null) {
      return Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: ApiErrorView(error: error, onRetry: onRetry),
        ),
      );
    }

    final page = pageData;
    if (page == null || page.items.isEmpty) {
      return EmptyView(
        icon: Icons.assignment_outlined,
        title: 'No assignments found',
        message: _query.hasActiveFilters
            ? 'No assignments match the selected filters. Try adjusting or clearing your filters.'
            : 'No training assignments have been recorded yet.',
        action: _query.hasActiveFilters
            ? OutlinedButton.icon(
                icon: const Icon(Icons.filter_alt_off),
                label: const Text('Reset filters'),
                onPressed: _clearAllFilters,
              )
            : null,
      );
    }

    return RefreshIndicator(
      onRefresh: onRefresh ?? () async {},
      child: ListView.builder(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: AppSpacing.sm,
        ),
        itemCount: page.items.length + 1,
        itemBuilder: (context, index) {
          if (index == page.items.length) {
            return _buildPaginationBar(context, page, isLoading);
          }
          final item = page.items[index];
          return _AssignmentReportCard(
            item: item,
            onCertificateTap: onCertificateTap,
          );
        },
      ),
    );
  }

  Widget _buildPaginationBar(
    BuildContext context,
    AssignmentReportPageViewData page,
    bool isLoading,
  ) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final textScaler = MediaQuery.textScalerOf(context);
          final isCompact =
              constraints.maxWidth < 360 || textScaler.scale(1.0) > 1.3;

          final prevButton = TextButton.icon(
            icon: const Icon(Icons.chevron_left),
            label: const Text('Previous'),
            onPressed: page.page > 1 && !isLoading
                ? () {
                    final newPage = page.page - 1;
                    _applyQuery(_query.copyWith(page: newPage));
                    widget.onPageChanged?.call(newPage);
                  }
                : null,
          );

          final pageText = Text(
            'Page ${page.page} of ${page.totalPages} · ${page.count} total',
            style: Theme.of(context).textTheme.bodySmall,
            textAlign: TextAlign.center,
          );

          final nextButton = TextButton.icon(
            label: const Text('Next'),
            icon: const Icon(Icons.chevron_right),
            onPressed: page.hasMore && !isLoading
                ? () {
                    final newPage = page.page + 1;
                    _applyQuery(_query.copyWith(page: newPage));
                    widget.onPageChanged?.call(newPage);
                  }
                : null,
          );

          return Column(
            children: [
              if (isCompact) ...[
                pageText,
                const SizedBox(height: AppSpacing.xs),
                Wrap(
                  alignment: WrapAlignment.center,
                  spacing: AppSpacing.sm,
                  children: [prevButton, nextButton],
                ),
              ] else
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [prevButton, pageText, nextButton],
                ),
            ],
          );
        },
      ),
    );
  }
}

/// Card representing a single assignment report item.
class _AssignmentReportCard extends StatelessWidget {
  final AssignmentReportItemViewData item;
  final ValueChanged<int>? onCertificateTap;

  const _AssignmentReportCard({required this.item, this.onCertificateTap});

  BadgeStatus _resolveStatusBadge(String status) {
    switch (status.toUpperCase()) {
      case 'COMPLETED':
        return BadgeStatus.success;
      case 'IN_PROGRESS':
        return BadgeStatus.warning;
      case 'CANCELLED':
        return BadgeStatus.neutral;
      case 'ASSIGNED':
      default:
        return BadgeStatus.info;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;

    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: CustomCard(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Top Row: Employee Name + Status Badges
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        item.safeEmployeeName,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'ID: ${item.safeEmployeeCode}',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colors.onSurfaceVariant,
                          fontFamily: 'monospace',
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                Wrap(
                  direction: Axis.vertical,
                  crossAxisAlignment: WrapCrossAlignment.end,
                  spacing: AppSpacing.xs,
                  children: [
                    StatusBadge(
                      text: item.statusDisplay,
                      status: _resolveStatusBadge(item.status),
                    ),
                    if (item.isOverdue)
                      const StatusBadge(
                        text: 'OVERDUE',
                        status: BadgeStatus.error,
                      ),
                  ],
                ),
              ],
            ),
            const Divider(height: AppSpacing.md),

            // Course & Version
            Text(
              item.safeTrainingTitle,
              style: theme.textTheme.bodyLarge?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              '${item.safeVersionTitle} · Version ${item.versionNumber}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: colors.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: AppSpacing.sm),

            // Org Metadata: Department and Job role
            Wrap(
              spacing: AppSpacing.md,
              runSpacing: AppSpacing.xs,
              children: [
                if (item.departmentName.isNotEmpty)
                  _buildIconMetadata(
                    context,
                    Icons.business_outlined,
                    item.departmentName,
                  ),
                if (item.jobRoleName.isNotEmpty)
                  _buildIconMetadata(
                    context,
                    Icons.badge_outlined,
                    item.jobRoleName,
                  ),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),

            // Dates Row
            Wrap(
              spacing: AppSpacing.md,
              runSpacing: AppSpacing.xs,
              children: [
                if (item.assignedAt != null)
                  _buildDateLabel(
                    context,
                    'Assigned',
                    localDateLabel(item.assignedAt!),
                  ),
                _buildDateLabel(
                  context,
                  'Deadline',
                  item.dueAt != null
                      ? localDateLabel(item.dueAt!)
                      : 'No deadline',
                  isWarning: item.isOverdue,
                ),
                if (item.completedAt != null)
                  _buildDateLabel(
                    context,
                    'Completed',
                    localDateLabel(item.completedAt!),
                  ),
              ],
            ),

            // Certificate section if issued
            if (item.hasCertificateIndicator) ...[
              const SizedBox(height: AppSpacing.sm),
              InkWell(
                onTap: (onCertificateTap != null && item.hasCertificate)
                    ? () => onCertificateTap!(item.certificateId!)
                    : null,
                borderRadius: BorderRadius.circular(8),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.sm,
                    vertical: AppSpacing.xs,
                  ),
                  decoration: BoxDecoration(
                    color: colors.surfaceContainerHighest.withAlpha(80),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: colors.outlineVariant.withAlpha(120),
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        item.isCertificateRevoked == true
                            ? Icons.block
                            : Icons.workspace_premium_outlined,
                        size: 16,
                        color: item.isCertificateRevoked == true
                            ? colors.error
                            : AppColors.statusSuccess,
                      ),
                      const SizedBox(width: AppSpacing.xs),
                      Text(
                        item.hasCertificate
                            ? (item.certificateNumber ??
                                  'Certificate #${item.certificateId}')
                            : 'Certificate',
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontFamily: 'monospace',
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(width: AppSpacing.xs),
                      StatusBadge(
                        text: item.isCertificateRevoked == true
                            ? 'Revoked'
                            : 'Issued',
                        status: item.isCertificateRevoked == true
                            ? BadgeStatus.error
                            : BadgeStatus.success,
                      ),
                      if (onCertificateTap != null && item.hasCertificate) ...[
                        const SizedBox(width: AppSpacing.xs),
                        Icon(
                          Icons.chevron_right,
                          size: 16,
                          color: colors.onSurfaceVariant,
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildIconMetadata(BuildContext context, IconData icon, String text) {
    final theme = Theme.of(context);
    return Text.rich(
      TextSpan(
        children: [
          WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: Padding(
              padding: const EdgeInsets.only(right: AppSpacing.xs),
              child: Icon(
                icon,
                size: 14,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          TextSpan(
            text: text,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDateLabel(
    BuildContext context,
    String label,
    String dateText, {
    bool isWarning = false,
  }) {
    final theme = Theme.of(context);
    final color = isWarning
        ? theme.colorScheme.error
        : theme.colorScheme.onSurfaceVariant;

    return Text.rich(
      TextSpan(
        children: [
          TextSpan(
            text: '$label: ',
            style: theme.textTheme.bodySmall?.copyWith(
              fontWeight: FontWeight.w500,
              color: color,
            ),
          ),
          TextSpan(
            text: dateText,
            style: theme.textTheme.bodySmall?.copyWith(
              color: color,
              fontWeight: isWarning ? FontWeight.bold : FontWeight.normal,
            ),
          ),
        ],
      ),
    );
  }
}

/// Filter bottom sheet for selecting assignment report filters.
class _AssignmentReportFilterSheet extends StatefulWidget {
  final AssignmentReportFilterOptionsViewData filterOptions;
  final bool filtersLoading;
  final Object? filtersError;
  final VoidCallback? onRetryFilters;
  final AssignmentReportFilterQuery initialQuery;
  final ValueChanged<AssignmentReportFilterQuery> onApply;

  const _AssignmentReportFilterSheet({
    required this.filterOptions,
    this.filtersLoading = false,
    this.filtersError,
    this.onRetryFilters,
    required this.initialQuery,
    required this.onApply,
  });

  @override
  State<_AssignmentReportFilterSheet> createState() =>
      _AssignmentReportFilterSheetState();
}

class _AssignmentReportFilterSheetState
    extends State<_AssignmentReportFilterSheet> {
  late String? _status;
  late String? _departmentId;
  late String? _jobRoleId;
  late String? _trainingId;
  late String? _trainingVersionId;
  late bool _overdueOnly;

  bool _choiceUnavailable(String collection) {
    if (widget.filtersLoading) return true;
    final error = widget.filtersError;
    if (error
        is FilterOptionsLoadFailure<AssignmentReportFilterOptionsViewData>) {
      return error.unavailableCollections.contains(collection);
    }
    return error != null;
  }

  String? _choiceHint(String collection, String label) {
    if (!_choiceUnavailable(collection)) return null;
    if (widget.filtersLoading) return 'Loading $label choices...';
    final error = widget.filtersError;
    final incomplete =
        error
            is FilterOptionsLoadFailure<
              AssignmentReportFilterOptionsViewData
            > &&
        error.failures[collection]?.code == 'incomplete_pagination';
    return incomplete
        ? '$label choices are incomplete. Retry filters.'
        : '$label choices are unavailable. Retry filters.';
  }

  @override
  void initState() {
    super.initState();
    _status = widget.initialQuery.status;
    _departmentId = widget.initialQuery.departmentId;
    _jobRoleId = widget.initialQuery.jobRoleId;
    _trainingId = widget.initialQuery.trainingId;
    _trainingVersionId = widget.initialQuery.trainingVersionId;
    _overdueOnly = widget.initialQuery.overdueOnly ?? false;
  }

  void _reset() {
    setState(() {
      _status = null;
      _departmentId = null;
      _jobRoleId = null;
      _trainingId = null;
      _trainingVersionId = null;
      _overdueOnly = false;
    });
  }

  void _apply() {
    final updated = widget.initialQuery.copyWith(
      status: _status,
      clearStatus: _status == null,
      departmentId: _departmentId,
      clearDepartment: _departmentId == null,
      jobRoleId: _jobRoleId,
      clearJobRole: _jobRoleId == null,
      trainingId: _trainingId,
      clearTraining: _trainingId == null,
      trainingVersionId: _trainingVersionId,
      clearTrainingVersion: _trainingVersionId == null,
      overdueOnly: _overdueOnly ? true : null,
      clearOverdue: !_overdueOnly,
      page: 1,
    );
    widget.onApply(updated);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // Filter versions by selected training course if selected
    final availableVersions = _trainingId != null
        ? widget.filterOptions.trainingVersions
              .where((v) => v.trainingId.toString() == _trainingId)
              .toList()
        : widget.filterOptions.trainingVersions;

    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Container(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.85,
        ),
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Sheet Header
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Text(
                    'Filter assignments',
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Close filter options',
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
            const Divider(),

            // Scrollable Filter Inputs
            Expanded(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (widget.filtersLoading || widget.filtersError != null)
                      Semantics(
                        liveRegion: true,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              widget.filtersLoading
                                  ? 'Loading filter choices...'
                                  : 'Some choices could not be loaded. Other filters remain available.',
                            ),
                            if (!widget.filtersLoading)
                              TextButton(
                                onPressed: widget.onRetryFilters,
                                child: const Text('Retry filters'),
                              ),
                            const SizedBox(height: AppSpacing.sm),
                          ],
                        ),
                      ),
                    // Status Dropdown
                    DropdownButtonFormField<String>(
                      isExpanded: true,
                      initialValue: _status,
                      decoration: const InputDecoration(
                        labelText: 'Assignment status',
                      ),
                      items: [
                        if (_status != null &&
                            !widget.filterOptions.statuses.any(
                              (s) => s.value == _status,
                            ))
                          DropdownMenuItem(
                            value: _status,
                            child: Text(
                              'Selected status: $_status',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        const DropdownMenuItem(
                          value: null,
                          child: Text('All statuses'),
                        ),
                        ...widget.filterOptions.statuses.map(
                          (s) => DropdownMenuItem(
                            value: s.value,
                            child: Text(
                              s.label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ),
                      ],
                      onChanged: (val) => setState(() => _status = val),
                    ),
                    const SizedBox(height: AppSpacing.md),

                    // Department Dropdown
                    DropdownButtonFormField<String>(
                      isExpanded: true,
                      initialValue: _departmentId,
                      decoration: InputDecoration(
                        labelText: 'Department',
                        helperText: _choiceHint('departments', 'Department'),
                        helperMaxLines: 3,
                      ),
                      items: [
                        if (_departmentId != null &&
                            !widget.filterOptions.departments.any(
                              (d) => d.value == _departmentId,
                            ))
                          DropdownMenuItem(
                            value: _departmentId,
                            child: Text(
                              'Selected department #$_departmentId (unavailable)',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        const DropdownMenuItem(
                          value: null,
                          child: Text('All departments'),
                        ),
                        ...widget.filterOptions.departments.map(
                          (d) => DropdownMenuItem(
                            value: d.value,
                            child: Text(
                              d.label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ),
                      ],
                      onChanged: _choiceUnavailable('departments')
                          ? null
                          : (val) => setState(() => _departmentId = val),
                    ),
                    const SizedBox(height: AppSpacing.md),

                    // Job Role Dropdown
                    DropdownButtonFormField<String>(
                      isExpanded: true,
                      initialValue: _jobRoleId,
                      decoration: InputDecoration(
                        labelText: 'Job role',
                        helperText: _choiceHint('job_roles', 'Job role'),
                        helperMaxLines: 3,
                      ),
                      items: [
                        if (_jobRoleId != null &&
                            !widget.filterOptions.jobRoles.any(
                              (r) => r.value == _jobRoleId,
                            ))
                          DropdownMenuItem(
                            value: _jobRoleId,
                            child: Text(
                              'Selected job role #$_jobRoleId (unavailable)',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        const DropdownMenuItem(
                          value: null,
                          child: Text('All job roles'),
                        ),
                        ...widget.filterOptions.jobRoles.map(
                          (r) => DropdownMenuItem(
                            value: r.value,
                            child: Text(
                              r.label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ),
                      ],
                      onChanged: _choiceUnavailable('job_roles')
                          ? null
                          : (val) => setState(() => _jobRoleId = val),
                    ),
                    const SizedBox(height: AppSpacing.md),

                    // Training Course Dropdown
                    DropdownButtonFormField<String>(
                      isExpanded: true,
                      initialValue: _trainingId,
                      decoration: InputDecoration(
                        labelText: 'Training course',
                        helperText: _choiceHint('trainings', 'Training course'),
                        helperMaxLines: 3,
                      ),
                      items: [
                        if (_trainingId != null &&
                            !widget.filterOptions.trainings.any(
                              (t) => t.value == _trainingId,
                            ))
                          DropdownMenuItem(
                            value: _trainingId,
                            child: Text(
                              'Selected course #$_trainingId (unavailable)',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        const DropdownMenuItem(
                          value: null,
                          child: Text('All courses'),
                        ),
                        ...widget.filterOptions.trainings.map(
                          (t) => DropdownMenuItem(
                            value: t.value,
                            child: Text(
                              t.label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ),
                      ],
                      onChanged: _choiceUnavailable('trainings')
                          ? null
                          : (val) {
                              setState(() {
                                _trainingId = val;
                                _trainingVersionId =
                                    null; // reset version when course changes
                              });
                            },
                    ),
                    const SizedBox(height: AppSpacing.md),

                    // Training Version Dropdown (if available)
                    if (availableVersions.isNotEmpty ||
                        _trainingVersionId != null ||
                        _choiceUnavailable('training_versions')) ...[
                      DropdownButtonFormField<String>(
                        isExpanded: true,
                        initialValue: _trainingVersionId,
                        decoration: InputDecoration(
                          labelText: 'Training version',
                          helperText: _choiceHint(
                            'training_versions',
                            'Training version',
                          ),
                          helperMaxLines: 3,
                        ),
                        items: [
                          if (_trainingVersionId != null &&
                              !availableVersions.any(
                                (v) => v.id.toString() == _trainingVersionId,
                              ))
                            DropdownMenuItem(
                              value: _trainingVersionId,
                              child: Text(
                                'Selected version #$_trainingVersionId (unavailable)',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          const DropdownMenuItem(
                            value: null,
                            child: Text('All versions'),
                          ),
                          ...availableVersions.map(
                            (v) => DropdownMenuItem(
                              value: v.id.toString(),
                              child: Text(
                                v.label,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ),
                        ],
                        onChanged: _choiceUnavailable('training_versions')
                            ? null
                            : (val) => setState(() => _trainingVersionId = val),
                      ),
                      const SizedBox(height: AppSpacing.md),
                    ],

                    // Overdue Only Switch
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Overdue assignments only'),
                      subtitle: const Text(
                        'Show only assignments that have passed their deadline.',
                      ),
                      value: _overdueOnly,
                      onChanged: (val) => setState(() => _overdueOnly = val),
                    ),
                  ],
                ),
              ),
            ),
            const Divider(),

            // Actions Footer
            Wrap(
              alignment: WrapAlignment.end,
              spacing: AppSpacing.sm,
              runSpacing: AppSpacing.sm,
              children: [
                TextButton(onPressed: _reset, child: const Text('Reset')),
                FilledButton(
                  onPressed: _apply,
                  child: const Text('Apply filters'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
