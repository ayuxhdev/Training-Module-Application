import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:training_app/core/presentation/components/api_error_view.dart';
import 'package:training_app/core/presentation/components/content_skeleton.dart';
import 'package:training_app/core/presentation/components/custom_card.dart';
import 'package:training_app/core/presentation/components/empty_view.dart';
import 'package:training_app/core/presentation/components/status_badge.dart';
import 'package:training_app/core/presentation/formatters/date_labels.dart';
import 'package:training_app/core/theme/app_spacing.dart';
import 'package:training_app/features/auth/domain/models/auth_state.dart';
import 'package:training_app/features/auth/presentation/controllers/auth_controller.dart';
import 'package:training_app/features/management/data/repositories/management_repository.dart';
import 'package:training_app/features/management/presentation/controllers/management_controller.dart';
import 'package:training_app/features/management/presentation/models/audit_log_view_data.dart';

/// Formats datetime for audit event display (YYYY-MM-DD HH:MM).
String _formatAuditTimestamp(DateTime? dt) {
  if (dt == null) return 'Date not recorded';
  final local = dt.toLocal();
  final date = localDateLabel(local);
  final hour = local.hour.toString().padLeft(2, '0');
  final minute = local.minute.toString().padLeft(2, '0');
  return '$date $hour:$minute';
}

/// Normalizes datetime to a pure calendar date (00:00:00) for comparison.
DateTime _calendarDate(DateTime dt) => DateTime(dt.year, dt.month, dt.day);

/// Permission-aware presentation screen for audit-log viewing.
/// Strictly read-only: no mutation controls, no raw JSON/secret dumps,
/// safe field diffs only. Exposes strictly confirmed backend filters:
/// actor, action substring, start_date, end_date, and target_type.
class AuditLogScreen extends ConsumerStatefulWidget {
  final bool? isLoading;
  final Object? error;
  final AuditLogPageViewData? pageData;
  final AuditLogFilterOptionsViewData? filterOptions;
  final AuditLogFilterQuery? currentQuery;
  final ValueChanged<AuditLogFilterQuery>? onQueryChanged;
  final ValueChanged<int>? onPageChanged;
  final Future<void> Function()? onRefresh;
  final VoidCallback? onRetry;
  final ValueChanged<AuditLogEntryViewData>? onEntryTap;

  const AuditLogScreen({
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
    this.onEntryTap,
  });

  @override
  ConsumerState<AuditLogScreen> createState() => _AuditLogScreenState();
}

class _AuditLogScreenState extends ConsumerState<AuditLogScreen> {
  late AuditLogFilterQuery _query;

  @override
  void initState() {
    super.initState();
    _query = widget.currentQuery ?? const AuditLogFilterQuery();
  }

  @override
  void didUpdateWidget(covariant AuditLogScreen oldWidget) {
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

  void _applyQuery(AuditLogFilterQuery newQuery) {
    setState(() => _query = newQuery);
    widget.onQueryChanged?.call(newQuery);
  }

  AuditLogFilterOptionsViewData _availableOptions(
    AsyncValue<AuditLogFilterOptionsViewData> options,
  ) {
    if (options.isLoading) return const AuditLogFilterOptionsViewData();
    final error = options.error;
    if (error is FilterOptionsLoadFailure<AuditLogFilterOptionsViewData>) {
      return error.completeOptions;
    }
    return options.asData?.value ??
        widget.filterOptions ??
        const AuditLogFilterOptionsViewData();
  }

  void _openFilterSheet(AuditLogFilterOptionsViewData filterOptions) {
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
              : ref.watch(auditLogFilterOptionsProvider);
          return _AuditLogFilterSheet(
            filterOptions: options == null
                ? filterOptions
                : _availableOptions(options),
            filtersLoading: options?.isLoading ?? false,
            filtersError: options?.error,
            onRetryFilters: options == null
                ? null
                : () => ref.invalidate(auditLogFilterOptionsProvider),
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
    final resetQuery = AuditLogFilterQuery(pageSize: _query.pageSize, page: 1);
    _applyQuery(resetQuery);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (!_isControlled) {
      final auth = ref.watch(authControllerProvider);
      if (auth is! AuthAuthenticated || !canViewAuditLogs(auth.identity)) {
        return Scaffold(
          appBar: AppBar(title: const Text('Audit history')),
          body: const Center(
            child: Text('You do not have permission to view audit history.'),
          ),
        );
      }

      final auditAsync = ref.watch(auditLogsProvider(_query));
      final filterOptionsAsync = ref.watch(auditLogFilterOptionsProvider);

      final isLoading = auditAsync.isLoading;
      final error = auditAsync.error;
      final pageData = auditAsync.asData?.value;
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
        onRetryFilters: () => ref.invalidate(auditLogFilterOptionsProvider),
        onRefresh: () async {
          ref.invalidate(auditLogsProvider);
          ref.invalidate(auditLogFilterOptionsProvider);
        },
        onRetry: () => ref.refresh(auditLogsProvider(_query)),
        onEntryTap: widget.onEntryTap,
      );
    }

    // Controlled mode (tests)
    final effectiveOptions =
        widget.filterOptions ?? const AuditLogFilterOptionsViewData();
    return _buildScaffold(
      context: context,
      theme: theme,
      isLoading: widget.isLoading ?? false,
      error: widget.error,
      pageData: widget.pageData,
      filterOptions: effectiveOptions,
      onRefresh: widget.onRefresh,
      onRetry: widget.onRetry,
      onEntryTap: widget.onEntryTap,
    );
  }

  Widget _buildScaffold({
    required BuildContext context,
    required ThemeData theme,
    required bool isLoading,
    required Object? error,
    required AuditLogPageViewData? pageData,
    required AuditLogFilterOptionsViewData filterOptions,
    required Future<void> Function()? onRefresh,
    required VoidCallback? onRetry,
    required ValueChanged<AuditLogEntryViewData>? onEntryTap,
    bool filtersLoading = false,
    Object? filtersError,
    VoidCallback? onRetryFilters,
  }) {
    final activeCount = _query.activeFilterCount;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Audit history'),
        actions: [
          Semantics(
            label: 'Filter audit logs, $activeCount active',
            button: true,
            child: IconButton(
              tooltip: 'Filter audit history',
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

          // Main Body
          Expanded(
            child: _buildBody(
              context: context,
              isLoading: isLoading,
              error: error,
              pageData: pageData,
              onRefresh: onRefresh,
              onRetry: onRetry,
              onEntryTap: onEntryTap,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActiveFilterChips(
    ThemeData theme,
    AuditLogFilterOptionsViewData filterOptions,
  ) {
    final chips = <Widget>[];

    if (_query.actorId != null) {
      final actorOpt = filterOptions.actors.firstWhere(
        (a) => a.id == _query.actorId,
        orElse: () => AuditFilterActorOption(
          id: _query.actorId!,
          username: 'user_${_query.actorId}',
          displayName: 'Actor #${_query.actorId}',
        ),
      );
      chips.add(
        InputChip(
          label: Text('Actor: ${actorOpt.label}'),
          onDeleted: () =>
              _applyQuery(_query.copyWith(clearActor: true, page: 1)),
        ),
      );
    }

    if (_query.targetType != null) {
      final entityOpt = filterOptions.entityTypes.firstWhere(
        (e) => e.value == _query.targetType,
        orElse: () => AuditFilterEntityOption(
          value: _query.targetType!,
          label: _query.targetType!,
        ),
      );
      chips.add(
        InputChip(
          label: Text('Record: ${entityOpt.label}'),
          onDeleted: () =>
              _applyQuery(_query.copyWith(clearTargetType: true, page: 1)),
        ),
      );
    }

    if (_query.action != null && _query.action!.isNotEmpty) {
      chips.add(
        InputChip(
          label: Text('Action: ${_query.action}'),
          onDeleted: () =>
              _applyQuery(_query.copyWith(clearAction: true, page: 1)),
        ),
      );
    }

    if (_query.startDate != null) {
      chips.add(
        InputChip(
          label: Text('From: ${localDateLabel(_query.startDate!)}'),
          onDeleted: () =>
              _applyQuery(_query.copyWith(clearStartDate: true, page: 1)),
        ),
      );
    }

    if (_query.endDate != null) {
      chips.add(
        InputChip(
          label: Text('Through: ${localDateLabel(_query.endDate!)}'),
          onDeleted: () =>
              _applyQuery(_query.copyWith(clearEndDate: true, page: 1)),
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
    required AuditLogPageViewData? pageData,
    required Future<void> Function()? onRefresh,
    required VoidCallback? onRetry,
    required ValueChanged<AuditLogEntryViewData>? onEntryTap,
  }) {
    if (isLoading && pageData == null) {
      return const SingleChildScrollView(
        padding: EdgeInsets.all(AppSpacing.md),
        child: CardListSkeleton(
          message: 'Loading audit history...',
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
        icon: Icons.history,
        title: 'No audit events found',
        message: _query.hasActiveFilters
            ? 'No events match the selected filters. Try adjusting or clearing your filters.'
            : 'No audit history events recorded.',
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
          return _AuditEventCard(
            item: item,
            onTap: onEntryTap != null ? () => onEntryTap(item) : null,
          );
        },
      ),
    );
  }

  Widget _buildPaginationBar(
    BuildContext context,
    AuditLogPageViewData page,
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
              if (page.resultLimit != null && page.count >= page.resultLimit!)
                Padding(
                  padding: const EdgeInsets.only(bottom: AppSpacing.xs),
                  child: Text(
                    'Showing up to the ${page.resultLimit} newest events. Narrow filters for earlier history.',
                    style: Theme.of(context).textTheme.bodySmall
                        ?.copyWith(fontStyle: FontStyle.italic),
                    textAlign: TextAlign.center,
                  ),
                ),
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

/// Card representing a single audit log event.
class _AuditEventCard extends StatelessWidget {
  final AuditLogEntryViewData item;
  final VoidCallback? onTap;

  const _AuditEventCard({required this.item, this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;

    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: CustomCard(
        padding: const EdgeInsets.all(AppSpacing.md),
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Top Row: Action Chip + Entity Badge + Timestamp
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Wrap(
                    spacing: AppSpacing.xs,
                    runSpacing: AppSpacing.xs,
                    children: [
                      StatusBadge(
                        text: item.safeActionLabel,
                        status: BadgeStatus.info,
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: colors.surfaceContainerHighest.withAlpha(120),
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(
                            color: colors.outlineVariant.withAlpha(100),
                          ),
                        ),
                        child: Text(
                          item.safeEntityLabel,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: colors.onSurfaceVariant,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                Text(
                  _formatAuditTimestamp(item.occurredAt),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),

            // Record Summary
            Text(
              item.safeRecordSummary,
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 2),

            // Actor Attribution
            Row(
              children: [
                Icon(
                  Icons.person_outline,
                  size: 14,
                  color: colors.onSurfaceVariant,
                ),
                const SizedBox(width: AppSpacing.xs),
                Expanded(
                  child: Text(
                    'Performed by: ${item.safeActorLabel}',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),

            // Optional Reason Banner
            if (item.hasReason) ...[
              const SizedBox(height: AppSpacing.sm),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.sm,
                  vertical: AppSpacing.xs,
                ),
                decoration: BoxDecoration(
                  color: colors.secondaryContainer.withAlpha(60),
                  borderRadius: BorderRadius.circular(6),
                  border: Border(
                    left: BorderSide(color: colors.secondary, width: 3),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Reason',
                      style: theme.textTheme.labelSmall?.copyWith(
                        fontWeight: FontWeight.bold,
                        color: colors.onSecondaryContainer,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      item.reason!,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colors.onSecondaryContainer,
                      ),
                    ),
                  ],
                ),
              ),
            ],

            // Safe Field-Level Changes (if present)
            if (item.hasChanges) ...[
              const SizedBox(height: AppSpacing.sm),
              Theme(
                data: theme.copyWith(dividerColor: Colors.transparent),
                child: ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  childrenPadding: EdgeInsets.zero,
                  dense: true,
                  title: Text(
                    item.detailKind == 'creation'
                        ? 'New record details (${item.changes.length})'
                        : 'Recorded changes (${item.changes.length})',
                    style: theme.textTheme.labelMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: colors.primary,
                    ),
                  ),
                  children: [
                    if (item.snapshotNotice != null &&
                        item.snapshotNotice!.trim().isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(bottom: AppSpacing.xs),
                        child: Text(
                          item.snapshotNotice!,
                          style: theme.textTheme.bodySmall?.copyWith(
                            fontStyle: FontStyle.italic,
                            color: colors.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ...item.changes.map(
                      (change) => _buildChangeRow(context, change),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildChangeRow(
    BuildContext context,
    AuditFieldChangeViewData change,
  ) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.sm,
          vertical: AppSpacing.xs,
        ),
        decoration: BoxDecoration(
          color: colors.surfaceContainerHighest.withAlpha(50),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              flex: 4,
              child: Text(
                change.safeFieldLabel,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(width: AppSpacing.xs),
            Expanded(
              flex: 6,
              child:
                  change.safeBeforeDisplay != 'Not recorded' &&
                      change.safeBeforeDisplay != change.safeAfterDisplay
                  ? Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Flexible(
                          child: Text(
                            change.safeBeforeDisplay,
                            style: theme.textTheme.bodySmall?.copyWith(
                              decoration: TextDecoration.lineThrough,
                              color: colors.error,
                            ),
                          ),
                        ),
                        const Padding(
                          padding: EdgeInsets.symmetric(horizontal: 4),
                          child: Icon(Icons.arrow_forward, size: 12),
                        ),
                        Flexible(
                          child: Text(
                            change.safeAfterDisplay,
                            style: theme.textTheme.bodySmall?.copyWith(
                              fontWeight: FontWeight.bold,
                              color: colors.primary,
                            ),
                          ),
                        ),
                      ],
                    )
                  : Text(
                      change.safeAfterDisplay,
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontWeight: FontWeight.w500,
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Filter modal sheet for configuring audit log filters.
class _AuditLogFilterSheet extends StatefulWidget {
  final AuditLogFilterOptionsViewData filterOptions;
  final bool filtersLoading;
  final Object? filtersError;
  final VoidCallback? onRetryFilters;
  final AuditLogFilterQuery initialQuery;
  final ValueChanged<AuditLogFilterQuery> onApply;

  const _AuditLogFilterSheet({
    required this.filterOptions,
    this.filtersLoading = false,
    this.filtersError,
    this.onRetryFilters,
    required this.initialQuery,
    required this.onApply,
  });

  @override
  State<_AuditLogFilterSheet> createState() => _AuditLogFilterSheetState();
}

class _AuditLogFilterSheetState extends State<_AuditLogFilterSheet> {
  late int? _actorId;
  late String? _targetType;
  late final TextEditingController _actionController;
  late DateTime? _startDate;
  late DateTime? _endDate;
  String? _dateError;

  bool _choiceUnavailable(String collection) {
    if (widget.filtersLoading) return true;
    final error = widget.filtersError;
    if (error is FilterOptionsLoadFailure<AuditLogFilterOptionsViewData>) {
      return error.unavailableCollections.contains(collection);
    }
    return error != null;
  }

  String? _choiceHint(String collection, String label) {
    if (!_choiceUnavailable(collection)) return null;
    if (widget.filtersLoading) return 'Loading $label choices...';
    final error = widget.filtersError;
    final incomplete =
        error is FilterOptionsLoadFailure<AuditLogFilterOptionsViewData> &&
        error.failures[collection]?.code == 'incomplete_pagination';
    return incomplete
        ? '$label choices are incomplete. Retry filters.'
        : '$label choices are unavailable. Retry filters.';
  }

  @override
  void initState() {
    super.initState();
    _actorId = widget.initialQuery.actorId;
    _targetType = widget.initialQuery.targetType;
    _actionController = TextEditingController(
      text: widget.initialQuery.action ?? '',
    );
    _startDate = widget.initialQuery.startDate;
    _endDate = widget.initialQuery.endDate;
    _validateDates();
  }

  @override
  void dispose() {
    _actionController.dispose();
    super.dispose();
  }

  void _validateDates() {
    if (_startDate != null &&
        _endDate != null &&
        _calendarDate(_startDate!).isAfter(_calendarDate(_endDate!))) {
      _dateError = 'End date must not precede start date.';
    } else {
      _dateError = null;
    }
  }

  Future<void> _pickDate({required bool isStart}) async {
    final initialDate = isStart
        ? (_startDate ?? DateTime.now())
        : (_endDate ?? _startDate ?? DateTime.now());

    final picked = await showDatePicker(
      context: context,
      initialDate: initialDate,
      firstDate: DateTime(2020),
      lastDate: DateTime.now().add(const Duration(days: 365)),
    );

    if (mounted && picked != null) {
      setState(() {
        if (isStart) {
          _startDate = picked;
        } else {
          _endDate = picked;
        }
        _validateDates();
      });
    }
  }

  void _reset() {
    setState(() {
      _actorId = null;
      _targetType = null;
      _actionController.clear();
      _startDate = null;
      _endDate = null;
      _dateError = null;
    });
  }

  void _apply() {
    _validateDates();
    if (_dateError != null) return;

    final actionText = _actionController.text.trim();
    final updated = widget.initialQuery.copyWith(
      actorId: _actorId,
      clearActor: _actorId == null,
      targetType: _targetType,
      clearTargetType: _targetType == null,
      action: actionText.isEmpty ? null : actionText,
      clearAction: actionText.isEmpty,
      startDate: _startDate,
      clearStartDate: _startDate == null,
      endDate: _endDate,
      clearEndDate: _endDate == null,
      page: 1,
    );
    widget.onApply(updated);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;

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
                    'Filter audit history',
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

            // Scrollable Inputs
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
                    // Actor Dropdown
                    DropdownButtonFormField<int>(
                      isExpanded: true,
                      initialValue: _actorId,
                      decoration: InputDecoration(
                        labelText: 'Performed by',
                        helperText: _choiceHint('actors', 'Actor'),
                        helperMaxLines: 3,
                        hintText: 'Select user',
                      ),
                      items: [
                        if (_actorId != null &&
                            !widget.filterOptions.actors.any(
                              (a) => a.id == _actorId,
                            ))
                          DropdownMenuItem(
                            value: _actorId,
                            child: Text(
                              'Selected account #$_actorId (unavailable)',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        const DropdownMenuItem(
                          value: null,
                          child: Text('All accounts'),
                        ),
                        ...widget.filterOptions.actors.map(
                          (a) => DropdownMenuItem(
                            value: a.id,
                            child: Text(
                              a.label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ),
                      ],
                      onChanged: _choiceUnavailable('actors')
                          ? null
                          : (val) => setState(() => _actorId = val),
                    ),
                    const SizedBox(height: AppSpacing.md),

                    // Target Type Dropdown
                    DropdownButtonFormField<String>(
                      isExpanded: true,
                      initialValue: _targetType,
                      decoration: InputDecoration(
                        labelText: 'Record type',
                        helperText: _choiceHint('entity_types', 'Record type'),
                        helperMaxLines: 3,
                        hintText: 'Select record type',
                      ),
                      items: [
                        if (_targetType != null &&
                            !widget.filterOptions.entityTypes.any(
                              (e) => e.value == _targetType,
                            ))
                          DropdownMenuItem(
                            value: _targetType,
                            child: Text(
                              'Selected type: $_targetType (unavailable)',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        const DropdownMenuItem(
                          value: null,
                          child: Text('All record types'),
                        ),
                        ...widget.filterOptions.entityTypes.map(
                          (e) => DropdownMenuItem(
                            value: e.value,
                            child: Text(
                              e.label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ),
                      ],
                      onChanged: _choiceUnavailable('entity_types')
                          ? null
                          : (val) => setState(() => _targetType = val),
                    ),
                    const SizedBox(height: AppSpacing.md),

                    // Action Input
                    TextField(
                      controller: _actionController,
                      decoration: const InputDecoration(
                        labelText: 'Action name contains',
                        hintText: 'e.g. created, updated, published',
                      ),
                    ),
                    const SizedBox(height: AppSpacing.md),

                    // Date Pickers Row
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            icon: const Icon(Icons.calendar_today, size: 16),
                            label: Text(
                              _startDate != null
                                  ? localDateLabel(_startDate!)
                                  : 'From date',
                            ),
                            onPressed: () => _pickDate(isStart: true),
                          ),
                        ),
                        const SizedBox(width: AppSpacing.sm),
                        Expanded(
                          child: OutlinedButton.icon(
                            icon: const Icon(Icons.calendar_today, size: 16),
                            label: Text(
                              _endDate != null
                                  ? localDateLabel(_endDate!)
                                  : 'Through date',
                            ),
                            onPressed: () => _pickDate(isStart: false),
                          ),
                        ),
                      ],
                    ),

                    if (_dateError != null)
                      Padding(
                        padding: const EdgeInsets.only(top: AppSpacing.xs),
                        child: Text(
                          _dateError!,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: colors.error,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
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
                  onPressed: _dateError != null ? null : _apply,
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
