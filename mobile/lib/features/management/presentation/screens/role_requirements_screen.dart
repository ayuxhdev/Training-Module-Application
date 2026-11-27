import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:training_app/core/errors/api_error.dart';
import 'package:training_app/core/presentation/components/api_error_view.dart';
import 'package:training_app/core/presentation/components/content_skeleton.dart';
import 'package:training_app/core/presentation/components/custom_card.dart';
import 'package:training_app/core/presentation/components/empty_view.dart';
import 'package:training_app/core/presentation/components/status_badge.dart';
import 'package:training_app/core/theme/app_spacing.dart';
import 'package:training_app/features/auth/domain/models/auth_state.dart';
import 'package:training_app/features/auth/presentation/controllers/auth_controller.dart';
import 'package:training_app/features/management/data/repositories/management_repository.dart';
import 'package:training_app/features/management/domain/models/management_models.dart';
import 'package:training_app/features/management/presentation/controllers/management_controller.dart';

class RoleRequirementsScreen extends ConsumerStatefulWidget {
  const RoleRequirementsScreen({super.key});

  @override
  ConsumerState<RoleRequirementsScreen> createState() =>
      _RoleRequirementsScreenState();
}

class _RoleRequirementsScreenState
    extends ConsumerState<RoleRequirementsScreen> {
  int _page = 1;
  String _search = '';
  bool? _isActive;
  late final TextEditingController _searchController;

  final Set<int> _inFlightStatusIds = {};
  final Set<int> _inFlightBatchIds = {};

  @override
  void initState() {
    super.initState();
    _searchController = TextEditingController();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _onSearchChanged(String value) {
    setState(() {
      _search = value.trim();
      _page = 1;
    });
  }

  void _onFilterChanged(bool? isActive) {
    setState(() {
      _isActive = isActive;
      _page = 1;
    });
  }

  RoleRequirementsRequest get _currentQuery => (
    page: _page,
    search: _search.isEmpty ? null : _search,
    jobRoleId: null,
    trainingVersionId: null,
    isActive: _isActive,
  );

  void _refreshList() {
    ref.invalidate(roleRequirementsProvider(_currentQuery));
  }

  Future<void> _showCreateDialog() async {
    final result = await showDialog<bool>(
      context: context,
      builder: (_) => const _CreateRoleRequirementDialog(),
    );
    if (result == true && mounted) {
      final auth = ref.read(authControllerProvider);
      if (auth is AuthAuthenticated && canViewRoleRequirements(auth.identity)) {
        _refreshList();
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Role requirement created successfully.'),
          ),
        );
      }
    }
  }

  Future<void> _toggleRequirementStatus(
    RoleTrainingRequirement requirement,
  ) async {
    if (_inFlightStatusIds.contains(requirement.id) ||
        _inFlightBatchIds.contains(requirement.id)) {
      return;
    }

    final nextStatus = !requirement.isActive;
    final actionLabel = nextStatus ? 'activate' : 'deactivate';

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('${nextStatus ? 'Activate' : 'Deactivate'} requirement'),
        content: Text(
          'Are you sure you want to $actionLabel the training requirement for '
          '${requirement.jobRoleName} on "${requirement.trainingTitle}"?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(nextStatus ? 'Activate' : 'Deactivate'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;
    if (_inFlightStatusIds.contains(requirement.id)) return;

    setState(() {
      _inFlightStatusIds.add(requirement.id);
    });

    try {
      final controller = ref.read(roleRequirementMutationProvider);
      await controller.update(id: requirement.id, isActive: nextStatus);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Requirement ${nextStatus ? 'activated' : 'deactivated'} successfully.',
            ),
          ),
        );
        _refreshList();
      }
    } catch (error) {
      if (mounted) {
        final message = error is ApiError ? error.message : error.toString();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to update requirement: $message'),
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _inFlightStatusIds.remove(requirement.id);
        });
      } else {
        _inFlightStatusIds.remove(requirement.id);
      }
    }
  }

  Future<void> _executeBatchAssignment(
    RoleTrainingRequirement requirement,
  ) async {
    if (_inFlightBatchIds.contains(requirement.id) ||
        _inFlightStatusIds.contains(requirement.id)) {
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Run role batch assignment'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'This will assign "${requirement.trainingTitle}" (v${requirement.versionNumber}) '
              'to all active employees in job role "${requirement.jobRoleName}".',
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              'Employees who already have an active, completed, or existing assignment '
              'for this version will be skipped.',
              style: Theme.of(ctx).textTheme.bodySmall
                  ?.copyWith(color: Theme.of(ctx).colorScheme.onSurfaceVariant),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton.icon(
            icon: const Icon(Icons.send_outlined),
            onPressed: () => Navigator.of(ctx).pop(true),
            label: const Text('Assign now'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;
    if (_inFlightBatchIds.contains(requirement.id)) return;

    setState(() {
      _inFlightBatchIds.add(requirement.id);
    });

    RoleBatchResult? result;
    try {
      final controller = ref.read(roleRequirementMutationProvider);
      result = await controller.executeBatch(id: requirement.id);
    } catch (error) {
      if (mounted) {
        final message = error is ApiError ? error.message : error.toString();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Batch assignment failed: $message'),
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _inFlightBatchIds.remove(requirement.id);
        });
      } else {
        _inFlightBatchIds.remove(requirement.id);
      }
    }

    final batchResult = result;
    if (batchResult != null && mounted) {
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Batch assignment completed'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Created: ${batchResult.createdCount} new assignment${batchResult.createdCount == 1 ? '' : 's'}.',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 4),
              Text(
                'Skipped: ${batchResult.skippedCount} employee${batchResult.skippedCount == 1 ? '' : 's'} (already assigned or inactive).',
              ),
            ],
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('OK'),
            ),
          ],
        ),
      );
    }
  }

  void _showDetailSheet(
    RoleTrainingRequirement requirement,
    bool canEdit,
    bool canAssign,
  ) {
    final isStatusInFlight = _inFlightStatusIds.contains(requirement.id);
    final isBatchInFlight = _inFlightBatchIds.contains(requirement.id);
    final isAnyInFlight = isStatusInFlight || isBatchInFlight;

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'Requirement details',
                    style: Theme.of(ctx).textTheme.titleLarge
                        ?.copyWith(fontWeight: FontWeight.bold),
                  ),
                  StatusBadge(
                    text: requirement.isActive ? 'ACTIVE' : 'INACTIVE',
                    status: requirement.isActive
                        ? BadgeStatus.success
                        : BadgeStatus.neutral,
                  ),
                ],
              ),
              const Divider(height: AppSpacing.lg),
              _detailRow(
                ctx,
                'Job role',
                '${requirement.jobRoleName} (${requirement.jobRoleCode})',
              ),
              _detailRow(ctx, 'Course', requirement.trainingTitle),
              _detailRow(
                ctx,
                'Version',
                'v${requirement.versionNumber} · ${requirement.versionTitle.isNotEmpty ? requirement.versionTitle : 'Version ${requirement.versionNumber}'} (${requirement.versionStatus})',
              ),
              _detailRow(ctx, 'Due in', '${requirement.dueInDays} days'),
              _detailRow(
                ctx,
                'Created',
                requirement.createdAt.toLocal().toString().split('.')[0],
              ),
              _detailRow(
                ctx,
                'Last updated',
                requirement.updatedAt.toLocal().toString().split('.')[0],
              ),
              const SizedBox(height: AppSpacing.md),
              Row(
                children: [
                  if (canEdit)
                    Expanded(
                      child: OutlinedButton.icon(
                        icon: isStatusInFlight
                            ? const SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : Icon(
                                requirement.isActive
                                    ? Icons.pause_circle_outline
                                    : Icons.play_circle_outline,
                              ),
                        label: Text(
                          isStatusInFlight
                              ? 'Updating...'
                              : (requirement.isActive
                                    ? 'Deactivate'
                                    : 'Activate'),
                        ),
                        onPressed: isAnyInFlight
                            ? null
                            : () {
                                Navigator.of(ctx).pop();
                                _toggleRequirementStatus(requirement);
                              },
                      ),
                    ),
                  if (canEdit && canAssign)
                    const SizedBox(width: AppSpacing.sm),
                  if (canAssign)
                    Expanded(
                      child: FilledButton.icon(
                        icon: isBatchInFlight
                            ? const SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.send_outlined),
                        label: Text(
                          isBatchInFlight ? 'Assigning...' : 'Assign batch',
                        ),
                        onPressed: isAnyInFlight
                            ? null
                            : () {
                                Navigator.of(ctx).pop();
                                _executeBatchAssignment(requirement);
                              },
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _detailRow(BuildContext context, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 100,
            child: Text(
              label,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Expanded(
            child: Text(value, style: Theme.of(context).textTheme.bodyMedium),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authControllerProvider);
    if (auth is! AuthAuthenticated ||
        (!canViewRoleRequirements(auth.identity) &&
            !canCreateRoleRequirement(auth.identity))) {
      return Scaffold(
        appBar: AppBar(title: const Text('Role requirements')),
        body: const Center(
          child: Text('You do not have permission to view role requirements.'),
        ),
      );
    }

    final identity = auth.identity;
    final canView = canViewRoleRequirements(identity);
    final canCreate = canCreateRoleRequirement(identity);
    final canEdit = canEditRoleRequirement(identity);
    final canAssign = canExecuteRoleBatchAssignment(identity);

    if (!canView) {
      return Scaffold(
        appBar: AppBar(title: const Text('Role requirements')),
        body: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(AppSpacing.lg),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  padding: const EdgeInsets.all(AppSpacing.md),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.primaryContainer,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    Icons.assignment_ind_outlined,
                    size: 48,
                    color: Theme.of(context).colorScheme.onPrimaryContainer,
                  ),
                ),
                const SizedBox(height: AppSpacing.md),
                Text(
                  'Choose a job role and a published version.',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: AppSpacing.lg),
                FilledButton.icon(
                  icon: const Icon(Icons.add),
                  label: const Text('Add role requirement'),
                  onPressed: _showCreateDialog,
                ),
              ],
            ),
          ),
        ),
      );
    }

    final query = _currentQuery;
    final requirementsAsync = ref.watch(roleRequirementsProvider(query));

    return Scaffold(
      appBar: AppBar(
        title: const Text('Role requirements'),
        actions: [
          if (canCreate)
            IconButton(
              tooltip: 'Add requirement',
              icon: const Icon(Icons.add),
              onPressed: _showCreateDialog,
            ),
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
            onPressed: () =>
                ref.refresh(roleRequirementsProvider(query).future),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(AppSpacing.md),
            child: Column(
              children: [
                TextField(
                  controller: _searchController,
                  decoration: InputDecoration(
                    hintText: 'Search role or course title...',
                    prefixIcon: const Icon(Icons.search),
                    suffixIcon: _search.isNotEmpty
                        ? IconButton(
                            icon: const Icon(Icons.clear),
                            onPressed: () {
                              _searchController.clear();
                              _onSearchChanged('');
                            },
                          )
                        : null,
                  ),
                  onSubmitted: _onSearchChanged,
                ),
                const SizedBox(height: AppSpacing.sm),
                Row(
                  children: [
                    FilterChip(
                      label: const Text('All'),
                      selected: _isActive == null,
                      onSelected: (_) => _onFilterChanged(null),
                    ),
                    const SizedBox(width: AppSpacing.xs),
                    FilterChip(
                      label: const Text('Active only'),
                      selected: _isActive == true,
                      onSelected: (_) => _onFilterChanged(true),
                    ),
                    const SizedBox(width: AppSpacing.xs),
                    FilterChip(
                      label: const Text('Inactive only'),
                      selected: _isActive == false,
                      onSelected: (_) => _onFilterChanged(false),
                    ),
                  ],
                ),
              ],
            ),
          ),
          Expanded(
            child: requirementsAsync.when(
              loading: () => const Center(
                child: CardListSkeleton(
                  message: 'Loading role requirements...',
                  compact: true,
                ),
              ),
              error: (error, _) => ApiErrorView(
                error: error,
                onRetry: () =>
                    ref.refresh(roleRequirementsProvider(query).future),
              ),
              data: (pageData) {
                final requirements = pageData.items;
                if (requirements.isEmpty) {
                  if (_page > 1) {
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (mounted && _page > 1) {
                        setState(() {
                          _page = _page - 1;
                        });
                      }
                    });
                    return const Center(
                      child: CardListSkeleton(
                        message: 'Returning to previous page...',
                        compact: true,
                      ),
                    );
                  }

                  return EmptyView(
                    message: 'No role requirements found.',
                    icon: Icons.assignment_ind_outlined,
                    action: canCreate
                        ? FilledButton.icon(
                            icon: const Icon(Icons.add),
                            label: const Text('Add requirement'),
                            onPressed: _showCreateDialog,
                          )
                        : null,
                  );
                }

                return RefreshIndicator(
                  onRefresh: () async {
                    ref.invalidate(roleRequirementsProvider(query));
                    await ref.read(roleRequirementsProvider(query).future);
                  },
                  child: ListView.builder(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.md,
                    ),
                    itemCount: requirements.length + 1,
                    itemBuilder: (context, index) {
                      if (index == requirements.length) {
                        return Padding(
                          padding: const EdgeInsets.symmetric(
                            vertical: AppSpacing.md,
                          ),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              TextButton.icon(
                                icon: const Icon(Icons.chevron_left),
                                label: const Text('Previous'),
                                onPressed: _page > 1
                                    ? () => setState(() => _page--)
                                    : null,
                              ),
                              Text(
                                'Page $_page · ${pageData.count} total',
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                              TextButton.icon(
                                label: const Text('Next'),
                                icon: const Icon(Icons.chevron_right),
                                onPressed: pageData.hasMore
                                    ? () => setState(() => _page++)
                                    : null,
                              ),
                            ],
                          ),
                        );
                      }

                      final req = requirements[index];
                      final isStatusInFlight = _inFlightStatusIds.contains(
                        req.id,
                      );
                      final isBatchInFlight = _inFlightBatchIds.contains(
                        req.id,
                      );
                      final isAnyInFlight = isStatusInFlight || isBatchInFlight;

                      return Padding(
                        padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                        child: CustomCard(
                          child: InkWell(
                            borderRadius: BorderRadius.circular(12),
                            onTap: isAnyInFlight
                                ? null
                                : () =>
                                      _showDetailSheet(req, canEdit, canAssign),
                            child: Padding(
                              padding: const EdgeInsets.all(AppSpacing.md),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      CircleAvatar(
                                        backgroundColor: req.isActive
                                            ? Theme.of(context)
                                                  .colorScheme
                                                  .primaryContainer
                                            : Theme.of(context)
                                                  .colorScheme
                                                  .surfaceContainerHighest,
                                        child: Icon(
                                          Icons.assignment_ind_outlined,
                                          color: req.isActive
                                              ? Theme.of(context)
                                                    .colorScheme
                                                    .onPrimaryContainer
                                              : Theme.of(context)
                                                    .colorScheme
                                                    .onSurfaceVariant,
                                        ),
                                      ),
                                      const SizedBox(width: AppSpacing.md),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              req.jobRoleName,
                                              style: Theme.of(context)
                                                  .textTheme
                                                  .titleMedium
                                                  ?.copyWith(
                                                    fontWeight: FontWeight.bold,
                                                  ),
                                            ),
                                            Text(
                                              'Code: ${req.jobRoleCode}',
                                              style: Theme.of(context)
                                                  .textTheme
                                                  .bodySmall
                                                  ?.copyWith(
                                                    color: Theme.of(context)
                                                        .colorScheme
                                                        .onSurfaceVariant,
                                                  ),
                                            ),
                                          ],
                                        ),
                                      ),
                                      StatusBadge(
                                        text: req.isActive
                                            ? 'ACTIVE'
                                            : 'INACTIVE',
                                        status: req.isActive
                                            ? BadgeStatus.success
                                            : BadgeStatus.neutral,
                                      ),
                                    ],
                                  ),
                                  const Divider(height: AppSpacing.md),
                                  Text(
                                    req.trainingTitle,
                                    style: Theme.of(context)
                                        .textTheme
                                        .bodyMedium
                                        ?.copyWith(fontWeight: FontWeight.w600),
                                  ),
                                  const SizedBox(height: 2),
                                  Row(
                                    children: [
                                      Text(
                                        'v${req.versionNumber} (${req.versionStatus})',
                                        style: Theme.of(context)
                                            .textTheme
                                            .bodySmall
                                            ?.copyWith(
                                              color: Theme.of(context)
                                                  .colorScheme
                                                  .onSurfaceVariant,
                                            ),
                                      ),
                                      const Spacer(),
                                      Icon(
                                        Icons.schedule_outlined,
                                        size: 14,
                                        color: Theme.of(context)
                                            .colorScheme
                                            .onSurfaceVariant,
                                      ),
                                      const SizedBox(width: 4),
                                      Text(
                                        'Due in ${req.dueInDays} days',
                                        style: Theme.of(context)
                                            .textTheme
                                            .bodySmall
                                            ?.copyWith(
                                              color: Theme.of(context)
                                                  .colorScheme
                                                  .onSurfaceVariant,
                                            ),
                                      ),
                                    ],
                                  ),
                                  if (canEdit || canAssign) ...[
                                    const SizedBox(height: AppSpacing.sm),
                                    Row(
                                      mainAxisAlignment: MainAxisAlignment.end,
                                      children: [
                                        if (canEdit)
                                          TextButton.icon(
                                            icon: isStatusInFlight
                                                ? const SizedBox(
                                                    width: 14,
                                                    height: 14,
                                                    child:
                                                        CircularProgressIndicator(
                                                          strokeWidth: 2,
                                                        ),
                                                  )
                                                : Icon(
                                                    req.isActive
                                                        ? Icons
                                                              .pause_circle_outline
                                                        : Icons
                                                              .play_circle_outline,
                                                    size: 18,
                                                  ),
                                            label: Text(
                                              isStatusInFlight
                                                  ? 'Updating...'
                                                  : (req.isActive
                                                        ? 'Deactivate'
                                                        : 'Activate'),
                                            ),
                                            onPressed: isAnyInFlight
                                                ? null
                                                : () =>
                                                      _toggleRequirementStatus(
                                                        req,
                                                      ),
                                          ),
                                        if (canAssign)
                                          FilledButton.tonalIcon(
                                            icon: isBatchInFlight
                                                ? const SizedBox(
                                                    width: 14,
                                                    height: 14,
                                                    child:
                                                        CircularProgressIndicator(
                                                          strokeWidth: 2,
                                                        ),
                                                  )
                                                : const Icon(
                                                    Icons.send_outlined,
                                                    size: 16,
                                                  ),
                                            label: Text(
                                              isBatchInFlight
                                                  ? 'Assigning...'
                                                  : 'Assign batch',
                                            ),
                                            onPressed: isAnyInFlight
                                                ? null
                                                : () => _executeBatchAssignment(
                                                    req,
                                                  ),
                                          ),
                                      ],
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _CreateRoleRequirementDialog extends ConsumerStatefulWidget {
  const _CreateRoleRequirementDialog();

  @override
  ConsumerState<_CreateRoleRequirementDialog> createState() =>
      _CreateRoleRequirementDialogState();
}

class _CreateRoleRequirementDialogState
    extends ConsumerState<_CreateRoleRequirementDialog> {
  final _formKey = GlobalKey<FormState>();
  CancelToken _cancelToken = CancelToken();

  int? _selectedJobRoleId;
  int? _selectedTrainingVersionId;
  int _dueInDays = 30;
  bool _isActive = true;
  bool _submitting = false;
  String? _errorMessage;

  List<RoleRequirementOption>? _jobRoles;
  List<RoleRequirementOption>? _versions;
  bool _loadingReferences = true;
  String? _referencesError;
  String? _initialAccount;

  bool get _isFormReady =>
      !_loadingReferences &&
      _referencesError == null &&
      _jobRoles != null &&
      _versions != null;

  @override
  void initState() {
    super.initState();
    _initialAccount = managementAccount(ref.read(authControllerProvider));
    _fetchReferences();
  }

  @override
  void dispose() {
    _cancelToken.cancel();
    super.dispose();
  }

  String _formatReferenceError(String resource, dynamic error) {
    if (error is ApiError) {
      if (error.statusCode == 403) {
        return '$resource permission required: ${error.message}';
      }
      return '$resource: ${error.message}';
    }
    return '$resource: $error';
  }

  Future<void> _fetchReferences() async {
    final initialAuth = ref.read(authControllerProvider);
    final initialAccount = managementAccount(initialAuth);
    if (initialAuth is! AuthAuthenticated) {
      if (mounted) {
        setState(() {
          _referencesError = 'You must be authenticated to load options.';
          _loadingReferences = false;
        });
      }
      return;
    }

    if (_cancelToken.isCancelled) {
      _cancelToken = CancelToken();
    }

    final repo = ref.read(managementRepositoryProvider);

    String? rolesFailure;
    String? versionsFailure;
    List<RoleRequirementOption>? roles;
    List<RoleRequirementOption>? versions;

    try {
      roles = await repo.allRoleRequirementCreationOptions(
        kind: RoleRequirementOptionKind.jobRoles,
        cancelToken: _cancelToken,
      );
    } catch (e) {
      if (_cancelToken.isCancelled) return;
      rolesFailure = _formatReferenceError('Job roles', e);
    }

    try {
      versions = await repo.allRoleRequirementCreationOptions(
        kind: RoleRequirementOptionKind.trainingVersions,
        cancelToken: _cancelToken,
      );
    } catch (e) {
      if (_cancelToken.isCancelled) return;
      versionsFailure = _formatReferenceError('Training versions', e);
    }

    if (_cancelToken.isCancelled) return;

    final currentAccount = managementAccount(ref.read(authControllerProvider));
    if (currentAccount != initialAccount) {
      if (mounted) {
        setState(() {
          _referencesError =
              'Account context changed. Please reopen the dialog.';
          _loadingReferences = false;
        });
      }
      return;
    }

    if (rolesFailure != null || versionsFailure != null) {
      final errors = <String>[];
      if (rolesFailure != null) errors.add(rolesFailure);
      if (versionsFailure != null) errors.add(versionsFailure);
      if (mounted) {
        setState(() {
          _referencesError = errors.join('\n');
          _loadingReferences = false;
        });
      }
      return;
    }

    if (mounted) {
      setState(() {
        _jobRoles = roles;
        _versions = versions;
        _loadingReferences = false;
      });
    }
  }

  Future<void> _submit() async {
    final form = _formKey.currentState;
    if (!_isFormReady || form == null || !form.validate()) return;

    final currentAccount = managementAccount(ref.read(authControllerProvider));
    if (_initialAccount != null && currentAccount != _initialAccount) {
      setState(
        () => _errorMessage =
            'Account context changed. Please reopen the dialog.',
      );
      return;
    }

    if (_selectedJobRoleId == null) {
      setState(() => _errorMessage = 'Please select a job role.');
      return;
    }
    if (_selectedTrainingVersionId == null) {
      setState(() => _errorMessage = 'Please select a training version.');
      return;
    }

    form.save();
    setState(() {
      _submitting = true;
      _errorMessage = null;
    });

    try {
      final controller = ref.read(roleRequirementMutationProvider);
      await controller.create(
        jobRoleId: _selectedJobRoleId!,
        trainingVersionId: _selectedTrainingVersionId!,
        dueInDays: _dueInDays,
        isActive: _isActive,
        cancelToken: _cancelToken,
      );
      if (mounted) {
        Navigator.of(context).pop(true);
      }
    } catch (error) {
      if (_cancelToken.isCancelled) return;
      if (mounted) {
        setState(() {
          _submitting = false;
          if (error is ApiError && error.statusCode == 409) {
            _errorMessage = 'Another operation conflicts with this request. Refresh before trying again.';
          } else if (error is ApiError) {
            _errorMessage = error.message;
          } else {
            _errorMessage = error.toString();
          }
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Add role requirement'),
      content: SizedBox(
        width: double.maxFinite,
        child: _loadingReferences
            ? const SizedBox(
                height: 120,
                child: Center(child: CircularProgressIndicator()),
              )
            : _referencesError != null
            ? Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Failed to load options: $_referencesError',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  TextButton(
                    onPressed: () {
                      if (_cancelToken.isCancelled) {
                        _cancelToken = CancelToken();
                      }
                      setState(() {
                        _loadingReferences = true;
                        _referencesError = null;
                      });
                      _fetchReferences();
                    },
                    child: const Text('Retry'),
                  ),
                ],
              )
            : Form(
                key: _formKey,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (_errorMessage != null) ...[
                        Container(
                          padding: const EdgeInsets.all(AppSpacing.sm),
                          decoration: BoxDecoration(
                            color: Theme.of(context).colorScheme.errorContainer,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            _errorMessage!,
                            style: TextStyle(
                              color: Theme.of(context)
                                  .colorScheme
                                  .onErrorContainer,
                            ),
                          ),
                        ),
                        const SizedBox(height: AppSpacing.sm),
                      ],
                      DropdownButtonFormField<int>(
                        isExpanded: true,
                        initialValue: _selectedJobRoleId,
                        decoration: const InputDecoration(
                          labelText: 'Job role *',
                          hintText: 'Select job role',
                        ),
                        items: _jobRoles?.map((role) {
                          return DropdownMenuItem<int>(
                            value: role.id,
                            child: Text(
                              role.label,
                              overflow: TextOverflow.ellipsis,
                            ),
                          );
                        }).toList(),
                        onChanged: (value) =>
                            setState(() => _selectedJobRoleId = value),
                        validator: (val) =>
                            val == null ? 'Job role is required' : null,
                      ),
                      const SizedBox(height: AppSpacing.md),
                      DropdownButtonFormField<int>(
                        isExpanded: true,
                        initialValue: _selectedTrainingVersionId,
                        decoration: const InputDecoration(
                          labelText: 'Published training version *',
                          hintText: 'Select training version',
                        ),
                        items: _versions?.map((ver) {
                          return DropdownMenuItem<int>(
                            value: ver.id,
                            child: Text(
                              ver.label,
                              overflow: TextOverflow.ellipsis,
                            ),
                          );
                        }).toList(),
                        onChanged: (value) =>
                            setState(() => _selectedTrainingVersionId = value),
                        validator: (val) =>
                            val == null ? 'Training version is required' : null,
                      ),
                      const SizedBox(height: AppSpacing.md),
                      TextFormField(
                        initialValue: '30',
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                          labelText: 'Due in days *',
                          helperText: 'Days after assignment before training is overdue',
                        ),
                        validator: (val) {
                          if (val == null || val.trim().isEmpty) {
                            return 'Due days is required';
                          }
                          final days = int.tryParse(val.trim());
                          if (days == null || days < 0) {
                            return 'Enter a non-negative number';
                          }
                          return null;
                        },
                        onSaved: (val) {
                          _dueInDays = int.parse(val!.trim());
                        },
                      ),
                      const SizedBox(height: AppSpacing.sm),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('Active requirement'),
                        subtitle: const Text(
                          'Active requirements participate in role batch assignments',
                        ),
                        value: _isActive,
                        onChanged: (val) => setState(() => _isActive = val),
                      ),
                    ],
                  ),
                ),
              ),
      ),
      actions: [
        TextButton(
          onPressed: _submitting ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _submitting || !_isFormReady ? null : _submit,
          child: _submitting
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Create'),
        ),
      ],
    );
  }
}
