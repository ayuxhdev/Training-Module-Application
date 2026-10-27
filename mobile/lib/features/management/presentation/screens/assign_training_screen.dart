import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:training_app/core/errors/api_error.dart';
import 'package:training_app/core/presentation/components/api_error_view.dart';
import 'package:training_app/core/presentation/components/cinematic_components.dart';
import 'package:training_app/core/presentation/components/content_skeleton.dart';
import 'package:training_app/core/presentation/components/custom_card.dart';
import 'package:training_app/core/presentation/components/empty_view.dart';
import 'package:training_app/core/presentation/components/status_badge.dart';
import 'package:training_app/core/theme/app_spacing.dart';
import 'package:training_app/features/auth/domain/models/auth_state.dart';
import 'package:training_app/features/auth/domain/models/authenticated_identity.dart';
import 'package:training_app/features/auth/presentation/controllers/auth_controller.dart';
import 'package:training_app/features/management/domain/models/management_models.dart';
import 'package:training_app/features/management/presentation/controllers/management_controller.dart';
import 'package:training_app/features/management/presentation/widgets/read_only_page.dart';

class AssignTrainingScreen extends ConsumerStatefulWidget {
  final int employeeId;
  final DirectoryEmployee? initialEmployee;

  const AssignTrainingScreen({
    super.key,
    required this.employeeId,
    this.initialEmployee,
  });

  @override
  ConsumerState<AssignTrainingScreen> createState() =>
      _AssignTrainingScreenState();
}

class _AssignTrainingScreenState extends ConsumerState<AssignTrainingScreen> {
  static const _searchDebounceDuration = Duration(milliseconds: 350);

  final _scrollController = ScrollController();
  final _searchController = TextEditingController();
  Timer? _searchDebounce;
  String _searchQuery = '';
  int _page = 1;

  AssignableTrainingVersion? _selectedVersion;
  DateTime? _dueDate;
  bool _isSaving = false;
  CancelToken? _activeRequest;
  String? _serverError;
  String? _serverValidationError;
  Map<String, String> _fieldErrors = const {};
  late final String? _account;

  bool get _isDirty => _selectedVersion != null || _dueDate != null;

  @override
  void initState() {
    super.initState();
    _account = managementAccount(ref.read(authControllerProvider));
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _searchController.dispose();
    _scrollController.dispose();
    _activeRequest?.cancel('Assign training form disposed');
    super.dispose();
  }

  void _onSearchChanged(String _) {
    _searchDebounce?.cancel();
    setState(() {});
    _searchDebounce = Timer(_searchDebounceDuration, () {
      if (!mounted) return;
      final query = _searchController.text.trim();
      if (_searchQuery == query) return;
      setState(() {
        _searchQuery = query;
        _page = 1;
      });
    });
  }

  void _clearSearch() {
    _searchDebounce?.cancel();
    _searchController.clear();
    setState(() {
      _searchQuery = '';
      _page = 1;
    });
  }

  String _formatDate(DateTime date) =>
      '${date.year.toString().padLeft(4, '0')}-'
      '${date.month.toString().padLeft(2, '0')}-'
      '${date.day.toString().padLeft(2, '0')}';

  Future<void> _pickDueDate() async {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final initial = _dueDate ?? today.add(const Duration(days: 14));
    final selected = await showDatePicker(
      context: context,
      initialDate: initial.isBefore(today) ? today : initial,
      firstDate: today,
      lastDate: DateTime(today.year + 10),
      helpText: 'Select assignment due date',
      cancelText: 'Cancel',
      confirmText: 'Set date',
    );
    if (selected != null && mounted) {
      setState(() {
        _dueDate = DateTime(selected.year, selected.month, selected.day);
        _clearServerErrors();
      });
    }
  }

  void _clearDueDate() {
    setState(() {
      _dueDate = null;
      _clearServerErrors();
    });
  }

  void _clearServerErrors() {
    _serverError = null;
    _serverValidationError = null;
    _fieldErrors = const {};
  }

  Map<String, String> _fieldErrorsFrom(ApiError error) {
    final details = error.details;
    if (details is! Map) return const {};
    final result = <String, String>{};
    for (final field in [
      'employee_id',
      'training_version_id',
      'due_date',
    ]) {
      final value = details[field];
      if (value is String && value.isNotEmpty) {
        result[field] = value;
      } else if (value is List && value.isNotEmpty) {
        result[field] = value.map((item) => item.toString()).join(' ');
      }
    }
    return result;
  }

  String? _nonFieldErrorFrom(ApiError error) {
    final details = error.details;
    if (details is! Map) return null;
    final value = details['non_field_errors'];
    if (value is String && value.isNotEmpty) return value;
    if (value is List && value.isNotEmpty) {
      return value.map((item) => item.toString()).join(' ');
    }
    return null;
  }

  Future<void> _leave() async {
    if (_isSaving) return;
    if (!_isDirty) {
      context.pop();
      return;
    }
    final discard = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Discard training assignment?'),
        content: const Text(
          'Your selected training curriculum and due date will not be saved.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Keep editing'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Discard'),
          ),
        ],
      ),
    );
    if (discard == true && mounted) context.pop();
  }

  Future<void> _submit(DirectoryEmployee employee) async {
    if (_isSaving || _selectedVersion == null) return;

    final auth = ref.read(authControllerProvider);
    if (auth is! AuthAuthenticated ||
        managementAccount(auth) != _account ||
        !canAssignTrainingToEmployee(identity: auth.identity, employee: employee)) {
      setState(() {
        _serverError =
            'Your account or permissions changed. Reopen the form to continue.';
      });
      return;
    }

    final request = CancelToken();
    _activeRequest = request;
    setState(() {
      _isSaving = true;
      _clearServerErrors();
    });

    try {
      final mutationController = ref.read(trainingAssignmentMutationProvider);
      await mutationController.assign(
        employeeId: employee.id,
        employeeCode: employee.employeeCode,
        trainingVersionId: _selectedVersion!.id,
        dueDate: _dueDate != null ? _formatDate(_dueDate!) : null,
        cancelToken: request,
      );

      if (!mounted ||
          request.isCancelled ||
          managementAccount(ref.read(authControllerProvider)) != _account) {
        return;
      }

      ref.invalidate(managementDashboardProvider);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Training "${_selectedVersion!.trainingTitle}" assigned to ${employee.displayName}.',
          ),
        ),
      );
      context.pop(true);
    } catch (error) {
      if (!mounted || request.isCancelled) return;
      final apiError = error is ApiError ? error : ApiError.unexpected();
      if (apiError.statusCode == 401) {
        await ref.read(authControllerProvider.notifier).logout();
        return;
      }
      setState(() {
        _serverError = apiError.statusCode == 403
            ? 'You are not authorized to assign training to this employee.'
            : apiError.message;
        _serverValidationError = apiError.statusCode == 403
            ? null
            : _nonFieldErrorFrom(apiError);
        _fieldErrors = _fieldErrorsFrom(apiError);
      });
      _scrollController.jumpTo(0);
    } finally {
      if (mounted) {
        setState(() {
          _isSaving = false;
          if (identical(_activeRequest, request)) _activeRequest = null;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<AuthState>(authControllerProvider, (_, next) {
      if (managementAccount(next) != _account) {
        _activeRequest?.cancel('Account changed');
        setState(() {});
      }
    });

    final auth = ref.watch(authControllerProvider);
    if (auth is! AuthAuthenticated || !canAssignTraining(auth.identity)) {
      return Scaffold(
        appBar: AppBar(title: const Text('Assign training')),
        body: const Center(
          child: Text('You do not have permission to assign training.'),
        ),
      );
    }

    final employeeAsync = widget.initialEmployee != null
        ? AsyncData(widget.initialEmployee!)
        : ref.watch(directoryEmployeeProvider(widget.employeeId));

    return PopScope(
      canPop: !_isDirty && !_isSaving,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && !_isSaving) _leave();
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Assign training'),
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            tooltip: 'Back',
            onPressed: _isSaving ? null : _leave,
          ),
        ),
        body: employeeAsync.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (error, _) => ApiErrorView(
            error: error is ApiError ? error : ApiError.unexpected(),
            onRetry: () => ref.refresh(
              directoryEmployeeProvider(widget.employeeId).future,
            ),
          ),
          data: (employee) => _buildForm(context, auth.identity, employee),
        ),
      ),
    );
  }

  Widget _buildForm(
    BuildContext context,
    AuthenticatedIdentity identity,
    DirectoryEmployee employee,
  ) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final isAllowed = canAssignTrainingToEmployee(
      identity: identity,
      employee: employee,
    );

    if (!isAllowed) {
      final reason = !employee.isActive
          ? 'Inactive employees cannot receive training assignments.'
          : (identity.employee != null &&
                  identity.employee!.employeeCode == employee.employeeCode)
              ? 'Managers cannot assign training to themselves.'
              : 'You are not authorized to assign training to this employee.';
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: EmptyView(message: reason),
        ),
      );
    }

    final versionsAsync = ref.watch(
      assignableTrainingVersionsProvider((
        page: _page,
        search: _searchQuery.isEmpty ? null : _searchQuery,
      )),
    );

    return SingleChildScrollView(
      controller: _scrollController,
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          CinematicHero(
            eyebrow: employee.employeeCode,
            title: employee.displayName,
            subtitle: 'Target employee',
            icon: Icons.school_outlined,
            child: StatusBadge(
              text: employee.isActive ? 'Active' : 'Inactive',
              status: employee.isActive
                  ? BadgeStatus.success
                  : BadgeStatus.warning,
            ),
          ),
          const SizedBox(height: 16),

          // Target Employee Read-Only Card
          CustomCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'Recipient details',
                      style: theme.textTheme.titleMedium,
                    ),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.lock_outline,
                          size: 16,
                          color: colors.onSurfaceVariant,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          'Read-only',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: colors.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                InformationRow('Department', employee.department.name),
                InformationRow('Job role', employee.jobRole.name),
                InformationRow(
                  'Reporting manager',
                  employee.reportingManager ?? 'Not assigned',
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),

          // Server Error Banner
          if (_serverError != null ||
              _serverValidationError != null ||
              _fieldErrors.isNotEmpty)
            _buildErrorBanner(context),

          // Training Curriculum Picker
          const SectionHeading(
            'Select curriculum',
            subtitle: 'Choose a published training version to assign.',
          ),
          _buildSearchField(),
          const SizedBox(height: 12),
          _buildVersionsSection(versionsAsync),
          const SizedBox(height: 24),

          // Due Date Section
          const SectionHeading(
            'Due date (Optional)',
            subtitle: 'Set a completion deadline for the learner.',
          ),
          _buildDueDateSection(context),
          const SizedBox(height: 32),

          // Submit Action
          FilledButton.icon(
            key: const ValueKey('submit-assignment-button'),
            onPressed: (_isSaving || _selectedVersion == null)
                ? null
                : () => _submit(employee),
            icon: _isSaving
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.add_task),
            label: Text(
              _isSaving ? 'Assigning training...' : 'Assign Training',
            ),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Widget _buildErrorBanner(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final message = _serverValidationError ??
        _fieldErrors['employee_id'] ??
        _fieldErrors['training_version_id'] ??
        _fieldErrors['due_date'] ??
        _serverError ??
        'An error occurred.';
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: CustomCard(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.error_outline, color: colors.error),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                message,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: colors.error,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSearchField() {
    return TextField(
      controller: _searchController,
      onChanged: _onSearchChanged,
      decoration: InputDecoration(
        hintText: 'Search training title or code...',
        prefixIcon: const Icon(Icons.search),
        suffixIcon: _searchController.text.isNotEmpty
            ? IconButton(
                icon: const Icon(Icons.clear),
                tooltip: 'Clear search',
                onPressed: _clearSearch,
              )
            : null,
        border: const OutlineInputBorder(),
        isDense: true,
      ),
    );
  }

  Widget _buildVersionsSection(
    AsyncValue<ManagementPage<AssignableTrainingVersion>> versionsAsync,
  ) {
    return versionsAsync.when(
      loading: () => const CardListSkeleton(
        message: 'Loading available training versions...',
        compact: true,
      ),
      error: (error, _) => ApiErrorView(
        error: error is ApiError ? error : ApiError.unexpected(),
        onRetry: () => ref.refresh(
          assignableTrainingVersionsProvider((
            page: _page,
            search: _searchQuery.isEmpty ? null : _searchQuery,
          )).future,
        ),
      ),
      data: (page) => _buildVersionsList(page),
    );
  }

  Widget _buildVersionsList(ManagementPage<AssignableTrainingVersion> page) {
    if (page.items.isEmpty) {
      return const EmptyView(
        message: 'No published training versions match your search.',
      );
    }

    final theme = Theme.of(context);
    final colors = theme.colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ...page.items.map((version) {
          final isSelected = _selectedVersion?.id == version.id;
          return Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.sm),
            child: InkWell(
              key: ValueKey('training-version-${version.id}'),
              onTap: _isSaving
                  ? null
                  : () {
                      setState(() {
                        _selectedVersion = version;
                        _clearServerErrors();
                      });
                    },
              borderRadius: BorderRadius.circular(16),
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: isSelected ? colors.primary : colors.outlineVariant,
                    width: isSelected ? 2 : 1,
                  ),
                  color: isSelected
                      ? colors.primaryContainer.withValues(alpha: 0.15)
                      : colors.surfaceContainerLow,
                ),
                padding: const EdgeInsets.all(AppSpacing.md),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Icon(
                        isSelected
                            ? Icons.radio_button_checked
                            : Icons.radio_button_unchecked,
                        color: isSelected
                            ? colors.primary
                            : colors.outlineVariant,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            version.trainingTitle.isNotEmpty
                                ? version.trainingTitle
                                : version.title,
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: isSelected
                                  ? FontWeight.w700
                                  : FontWeight.w600,
                              color: isSelected ? colors.primary : null,
                            ),
                          ),
                          if (version.title.isNotEmpty &&
                              version.title != version.trainingTitle)
                            Padding(
                              padding: const EdgeInsets.only(top: 2),
                              child: Text(
                                version.title,
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  color: colors.onSurfaceVariant,
                                ),
                              ),
                            ),
                          const SizedBox(height: 6),
                          Wrap(
                            spacing: 8,
                            runSpacing: 4,
                            children: [
                              StatusBadge(
                                text: version.trainingCode,
                                status: BadgeStatus.neutral,
                              ),
                              StatusBadge(
                                text: 'v${version.versionNumber}',
                                status: BadgeStatus.info,
                              ),
                            ],
                          ),
                          if (version.description.isNotEmpty) ...[
                            const SizedBox(height: 6),
                            Text(
                              version.description,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: colors.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        }),
        const SizedBox(height: 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            TextButton.icon(
              onPressed: _page > 1 && !_isSaving
                  ? () => setState(() => _page--)
                  : null,
              icon: const Icon(Icons.chevron_left),
              label: const Text('Previous'),
            ),
            Text('Page $_page', style: theme.textTheme.bodyMedium),
            TextButton.icon(
              onPressed: page.hasMore && !_isSaving
                  ? () => setState(() => _page++)
                  : null,
              icon: const Icon(Icons.chevron_right),
              label: const Text('Next'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildDueDateSection(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;

    return CustomCard(
      child: Row(
        children: [
          Icon(Icons.calendar_today_outlined, color: colors.primary),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _dueDate == null
                      ? 'No due date set'
                      : 'Due: ${_formatDate(_dueDate!)}',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight:
                        _dueDate != null ? FontWeight.w600 : FontWeight.normal,
                  ),
                ),
                Text(
                  _dueDate == null
                      ? 'The learner will have unrestricted time.'
                      : 'Deadline for curriculum completion.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          if (_dueDate != null)
            IconButton(
              icon: const Icon(Icons.clear),
              tooltip: 'Clear due date',
              onPressed: _isSaving ? null : _clearDueDate,
            ),
          OutlinedButton(
            onPressed: _isSaving ? null : _pickDueDate,
            child: Text(_dueDate == null ? 'Set date' : 'Change'),
          ),
        ],
      ),
    );
  }
}

