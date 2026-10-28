import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:training_app/core/presentation/components/api_error_view.dart';
import 'package:training_app/core/presentation/components/cinematic_components.dart';
import 'package:training_app/core/presentation/components/content_skeleton.dart';
import 'package:training_app/core/presentation/components/custom_card.dart';
import 'package:training_app/core/presentation/components/empty_view.dart';
import 'package:training_app/core/presentation/components/status_badge.dart';
import 'package:training_app/core/theme/app_spacing.dart';
import 'package:training_app/features/auth/domain/models/auth_state.dart';
import 'package:training_app/features/auth/presentation/controllers/auth_controller.dart';
import 'package:training_app/features/management/domain/models/management_models.dart';
import 'package:training_app/features/management/presentation/controllers/management_controller.dart';
import 'package:training_app/features/management/presentation/widgets/employee_deactivation_action.dart';
import 'package:training_app/features/management/presentation/widgets/employee_assignments_section.dart';
import 'package:training_app/features/management/presentation/widgets/read_only_page.dart';

class OrganizationListScreen extends ConsumerStatefulWidget {
  final ReferenceKind? referenceKind;
  const OrganizationListScreen({super.key, this.referenceKind});

  @override
  ConsumerState<OrganizationListScreen> createState() =>
      _OrganizationListScreenState();
}

class _OrganizationListScreenState
    extends ConsumerState<OrganizationListScreen> {
  static const _allReferencesId = 0;
  static const _searchDebounceDuration = Duration(milliseconds: 350);

  int _page = 1;
  String? _account;
  final _searchController = TextEditingController();
  Timer? _searchDebounce;
  String _searchQuery = '';
  int? _departmentId;
  int? _jobRoleId;
  String _activeStatus = 'all';

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  bool get _hasEmployeeFilters =>
      _searchController.text.trim().isNotEmpty ||
      _departmentId != null ||
      _jobRoleId != null ||
      _activeStatus != 'all';

  bool? get _isActiveFilter => switch (_activeStatus) {
    'active' => true,
    'inactive' => false,
    _ => null,
  };

  EmployeeDirectoryRequest _directoryRequest({int? page}) => (
    page: page ?? _page,
    search: _searchQuery.isEmpty ? null : _searchQuery,
    departmentId: _departmentId,
    jobRoleId: _jobRoleId,
    isActive: _isActiveFilter,
  );

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

  void _applyDirectoryFilters({
    bool changeDepartment = false,
    int? departmentId,
    bool changeJobRole = false,
    int? jobRoleId,
    String? activeStatus,
  }) {
    _searchDebounce?.cancel();
    setState(() {
      _page = 1;
      _searchQuery = _searchController.text.trim();
      if (changeDepartment) _departmentId = departmentId;
      if (changeJobRole) _jobRoleId = jobRoleId;
      if (activeStatus != null) _activeStatus = activeStatus;
    });
  }

  void _clearDirectoryFilters() {
    _searchDebounce?.cancel();
    _searchController.clear();
    setState(() {
      _page = 1;
      _searchQuery = '';
      _departmentId = null;
      _jobRoleId = null;
      _activeStatus = 'all';
    });
  }

  Future<void> _refreshEmployeeDirectory(WidgetRef ref) async {
    setState(() => _page = 1);
    final request = _directoryRequest(page: 1);
    ref.invalidate(employeeDirectoryProvider(request));
    try {
      await ref.read(employeeDirectoryProvider(request).future);
    } catch (_) {
      // The provider exposes the failed refresh in the page content.
    }
  }

  Widget _searchAndFilters(
    WidgetRef ref, {
    required AsyncValue<List<OrganizationReference>>? departments,
    required AsyncValue<List<OrganizationReference>>? jobRoles,
  }) => Column(
    key: const ValueKey('employee-directory-filters'),
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      TextField(
        controller: _searchController,
        textInputAction: TextInputAction.search,
        onChanged: _onSearchChanged,
        decoration: InputDecoration(
          labelText: 'Search employees',
          hintText: 'Name or employee code',
          prefixIcon: const Icon(Icons.search),
          suffixIcon: _searchController.text.isEmpty
              ? null
              : IconButton(
                  tooltip: 'Clear search',
                  onPressed: () {
                    _searchDebounce?.cancel();
                    _searchController.clear();
                    setState(() {
                      _searchQuery = '';
                      _page = 1;
                    });
                  },
                  icon: const Icon(Icons.close),
                ),
        ),
      ),
      if (departments case final choices?) ...[
        const SizedBox(height: 12),
        _referenceFilter(
          ref,
          kind: ReferenceKind.departments,
          choices: choices,
          selectedId: _departmentId,
          onChanged: (id) =>
              _applyDirectoryFilters(changeDepartment: true, departmentId: id),
        ),
      ],
      if (jobRoles case final choices?) ...[
        const SizedBox(height: 12),
        _referenceFilter(
          ref,
          kind: ReferenceKind.jobRoles,
          choices: choices,
          selectedId: _jobRoleId,
          onChanged: (id) =>
              _applyDirectoryFilters(changeJobRole: true, jobRoleId: id),
        ),
      ],
      const SizedBox(height: 12),
      DropdownButtonFormField<String>(
        initialValue: _activeStatus,
        isExpanded: true,
        decoration: const InputDecoration(labelText: 'Active status'),
        items: const [
          DropdownMenuItem(value: 'all', child: Text('All employees')),
          DropdownMenuItem(value: 'active', child: Text('Active')),
          DropdownMenuItem(value: 'inactive', child: Text('Inactive')),
        ],
        onChanged: (value) {
          if (value != null) {
            _applyDirectoryFilters(activeStatus: value);
          }
        },
      ),
      if (_hasEmployeeFilters) ...[
        const SizedBox(height: 8),
        Align(
          alignment: AlignmentDirectional.centerEnd,
          child: TextButton.icon(
            onPressed: _clearDirectoryFilters,
            icon: const Icon(Icons.filter_alt_off_outlined),
            label: const Text('Clear filters'),
          ),
        ),
      ],
    ],
  );

  Widget _referenceFilter(
    WidgetRef ref, {
    required ReferenceKind kind,
    required AsyncValue<List<OrganizationReference>> choices,
    required int? selectedId,
    required ValueChanged<int?> onChanged,
  }) => choices.when(
    data: (items) => DropdownButtonFormField<int>(
      initialValue: selectedId ?? _allReferencesId,
      isExpanded: true,
      decoration: InputDecoration(
        labelText: kind.title == 'Departments' ? 'Department' : 'Job role',
      ),
      items: [
        DropdownMenuItem(
          value: _allReferencesId,
          child: Text('All ${kind.title.toLowerCase()}'),
        ),
        ...items.map(
          (item) => DropdownMenuItem(value: item.id, child: Text(item.name)),
        ),
      ],
      onChanged: (value) {
        if (value != null) {
          onChanged(value == _allReferencesId ? null : value);
        }
      },
    ),
    loading: () => InputDecorator(
      decoration: InputDecoration(
        labelText: kind.title == 'Departments' ? 'Department' : 'Job role',
      ),
      child: const LinearProgressIndicator(),
    ),
    error: (error, _) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Unable to load ${kind.title.toLowerCase()} filter options.'),
        TextButton(
          onPressed: () =>
              ref.invalidate(organizationReferenceChoicesProvider(kind)),
          child: Text('Retry ${kind.title.toLowerCase()}'),
        ),
      ],
    ),
  );

  List<Widget> _employeeContent(
    ManagementPage<DirectoryEmployee> page,
    BuildContext context,
  ) => [
    SectionHeading('${page.count} ${_recordLabel(page.count)}'),
    if (page.items.isEmpty)
      EmptyView(
        message: _hasEmployeeFilters
            ? 'No employees match these search and filter criteria.'
            : 'No records to display.',
        action: _hasEmployeeFilters
            ? TextButton(
                onPressed: _clearDirectoryFilters,
                child: const Text('Clear filters'),
              )
            : null,
      ),
    ...page.items.map(
      (employee) => Padding(
        padding: const EdgeInsets.only(bottom: AppSpacing.md),
        child: CustomCard(
          padding: EdgeInsets.zero,
          child: ListTile(
            contentPadding: const EdgeInsets.all(16),
            title: Text(employee.displayName),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(employee.employeeCode),
                Text('${employee.department.name} · ${employee.jobRole.name}'),
                if (employee.reportingManager != null)
                  Text('Reports to ${employee.reportingManager}'),
                const SizedBox(height: 8),
                _status(employee.isActive),
              ],
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/workspace/employees/${employee.id}'),
          ),
        ),
      ),
    ),
    const SizedBox(height: 16),
    Text('Page $_page', textAlign: TextAlign.center),
    Wrap(
      alignment: WrapAlignment.spaceBetween,
      spacing: 16,
      children: [
        TextButton.icon(
          onPressed: _page > 1 ? () => setState(() => _page--) : null,
          icon: const Icon(Icons.chevron_left),
          label: const Text('Previous page'),
        ),
        TextButton.icon(
          onPressed: page.hasMore ? () => setState(() => _page++) : null,
          icon: const Icon(Icons.chevron_right),
          label: const Text('Next page'),
        ),
      ],
    ),
  ];

  Widget _employeeDirectory(
    BuildContext context,
    WidgetRef ref,
    AuthAuthenticated auth,
  ) {
    final request = _directoryRequest();
    final value = ref.watch(employeeDirectoryProvider(request));
    final isLoading = value.isLoading;
    final canViewDepartments = auth.identity.capabilities.contains(
      ReferenceKind.departments.permission,
    );
    final canViewJobRoles = auth.identity.capabilities.contains(
      ReferenceKind.jobRoles.permission,
    );
    final departments = canViewDepartments
        ? ref.watch(
            organizationReferenceChoicesProvider(ReferenceKind.departments),
          )
        : null;
    final jobRoles = canViewJobRoles
        ? ref.watch(
            organizationReferenceChoicesProvider(ReferenceKind.jobRoles),
          )
        : null;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Employees'),
        actions: [
          if (canCreateEmployee(auth.identity))
            IconButton(
              tooltip: 'Add employee',
              onPressed: () => _openEmployeeCreation(context, ref),
              icon: const Icon(Icons.person_add_alt_1_outlined),
            ),
          IconButton(
            tooltip: 'Refresh',
            onPressed: isLoading ? null : () => _refreshEmployeeDirectory(ref),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () => _refreshEmployeeDirectory(ref),
        child: ListView(
          key: ValueKey('employee-directory-$_account'),
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(16),
          children: [
            const CinematicHero(
              eyebrow: 'Organization',
              title: 'Employee directory',
              subtitle: 'Profiles and reporting relationships available to your account.',
              icon: Icons.badge_outlined,
            ),
            const SizedBox(height: 24),
            _searchAndFilters(
              ref,
              departments: departments,
              jobRoles: jobRoles,
            ),
            const SizedBox(height: 16),
            if (isLoading)
              const CardListSkeleton(
                message: 'Loading employees',
                compact: true,
              ),
            if (!isLoading)
              ...value.when<List<Widget>>(
                skipLoadingOnReload: false,
                skipLoadingOnRefresh: false,
                data: (page) => _employeeContent(page, context),
                loading: () => const [],
                error: (error, _) => [
                  ApiErrorView(
                    error: error,
                    onRetry: () {
                      unawaited(_refreshEmployeeDirectory(ref));
                    },
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }

  String _recordLabel(int count) => count == 1
      ? widget.referenceKind?.singular ?? 'employee'
      : widget.referenceKind?.title.toLowerCase() ?? 'employees';

  @override
  void didUpdateWidget(OrganizationListScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.referenceKind != oldWidget.referenceKind) _page = 1;
  }

  List<Widget> _items<T>(ManagementPage<T> page, Widget Function(T) tile) => [
    CinematicHero(
      eyebrow: 'Organization',
      title: widget.referenceKind?.title ?? 'Employee directory',
      subtitle: widget.referenceKind == null
          ? 'Profiles and reporting relationships available to your account.'
          : 'Codes, descriptions and current organization status.',
      icon: widget.referenceKind == null
          ? Icons.badge_outlined
          : Icons.account_tree_outlined,
    ),
    const SizedBox(height: 24),
    SectionHeading('${page.count} ${_recordLabel(page.count)}'),
    if (page.items.isEmpty) const EmptyView(message: 'No records to display.'),
    ...page.items.map(
      (item) => Padding(
        padding: const EdgeInsets.only(bottom: AppSpacing.md),
        child: tile(item),
      ),
    ),
    const SizedBox(height: 16),
    Text('Page $_page', textAlign: TextAlign.center),
    Wrap(
      alignment: WrapAlignment.spaceBetween,
      spacing: 16,
      children: [
        TextButton.icon(
          onPressed: _page > 1 ? () => setState(() => _page--) : null,
          icon: const Icon(Icons.chevron_left),
          label: const Text('Previous page'),
        ),
        TextButton.icon(
          onPressed: page.hasMore ? () => setState(() => _page++) : null,
          icon: const Icon(Icons.chevron_right),
          label: const Text('Next page'),
        ),
      ],
    ),
  ];

  Future<void> _openReferenceForm(
    BuildContext context,
    WidgetRef ref,
    ReferenceKind kind, {
    OrganizationReference? reference,
  }) async {
    final path = reference == null
        ? '/workspace/${kind.path}/new'
        : '/workspace/${kind.path}/${reference.id}/edit';
    final saved = await context.push<bool>(path, extra: reference);
    if (saved == true && mounted) {
      setState(() => _page = 1);
      ref.invalidate(organizationReferencesProvider((kind: kind, page: 1)));
    }
  }

  Future<void> _openEmployeeCreation(
    BuildContext context,
    WidgetRef ref,
  ) async {
    final created = await context.push<bool>('/workspace/employees/new');
    if (created == true && mounted) {
      setState(() => _page = 1);
      ref.invalidate(employeeDirectoryProvider);
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authControllerProvider);
    final account = managementAccount(auth);
    if (_account != account) {
      _account = account;
      _searchDebounce?.cancel();
      _searchController.clear();
      _searchQuery = '';
      _departmentId = null;
      _jobRoleId = null;
      _activeStatus = 'all';
      _page = 1;
    }
    final kind = widget.referenceKind;
    final permission = kind?.permission ?? 'organization.view_employee';
    if (auth is! AuthAuthenticated ||
        !auth.identity.capabilities.contains(permission)) {
      return const SizedBox.shrink();
    }
    if (kind == null) {
      return _employeeDirectory(context, ref, auth);
    }
    final canCreate = canCreateOrganizationReference(auth.identity, kind);
    final canEdit = canEditOrganizationReference(auth.identity, kind);
    return ReadOnlyPage<ManagementPage<OrganizationReference>>(
      title: kind.title,
      loading: CardListSkeleton(
        message: 'Loading ${kind.title.toLowerCase()}',
        compact: true,
      ),
      actions: [
        if (canCreate)
          IconButton(
            tooltip: 'Add ${kind.singular}',
            onPressed: () => _openReferenceForm(context, ref, kind),
            icon: const Icon(Icons.add),
          ),
      ],
      value: ref.watch(
        organizationReferencesProvider((kind: kind, page: _page)),
      ),
      refresh: () {
        setState(() => _page = 1);
        return ref
            .refresh(
              organizationReferencesProvider((kind: kind, page: 1)).future,
            )
            .then<void>((_) {});
      },
      content: (page) => _items(
        page,
        (item) => CustomCard(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.name,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    Text(item.code),
                    if (item.description.isNotEmpty) Text(item.description),
                    const SizedBox(height: 8),
                    _status(item.isActive),
                  ],
                ),
              ),
              if (canEdit)
                IconButton(
                  tooltip: 'Edit ${kind.singular}: ${item.name}',
                  onPressed: () =>
                      _openReferenceForm(context, ref, kind, reference: item),
                  icon: const Icon(Icons.edit_outlined),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

Widget _status(bool active) => StatusBadge(
  text: active ? 'Active' : 'Inactive',
  status: active ? BadgeStatus.success : BadgeStatus.warning,
);

class DirectoryEmployeeScreen extends ConsumerWidget {
  final int employeeId;
  const DirectoryEmployeeScreen({super.key, required this.employeeId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authControllerProvider);
    if (auth is! AuthAuthenticated ||
        !auth.identity.capabilities.contains('organization.view_employee')) {
      return const SizedBox.shrink();
    }
    final employee = ref.watch(directoryEmployeeProvider(employeeId));
    final currentDetail = employee.asData?.value;
    final isCurrentEmployee =
        auth.identity.employee != null &&
        auth.identity.employee!.employeeCode == currentDetail?.employeeCode;
    return ReadOnlyPage<DirectoryEmployee>(
      title: 'Employee details',
      actions: [
        if (canEditEmployee(auth.identity) && employee.hasValue)
          IconButton(
            tooltip: 'Edit employee',
            onPressed: () async {
              final saved = await context.push<bool>(
                '/workspace/employees/$employeeId/edit',
                extra: employee.value,
              );
              if (saved == true) {
                ref.invalidate(directoryEmployeeProvider(employeeId));
                ref.invalidate(employeeDirectoryProvider);
              }
            },
            icon: const Icon(Icons.edit_outlined),
          ),
        if (canEditEmployee(auth.identity) &&
            currentDetail?.isActive == true &&
            !isCurrentEmployee)
          EmployeeDeactivationAction(
            key: ValueKey('deactivate-$employeeId'),
            employee: currentDetail!,
          ),
        if (currentDetail != null &&
            canAssignTrainingToEmployee(
              identity: auth.identity,
              employee: currentDetail,
            ))
          IconButton(
            tooltip: 'Assign training',
            onPressed: () async {
              final assigned = await context.push<bool>(
                '/workspace/employees/$employeeId/assign',
                extra: currentDetail,
              );
              if (assigned == true) {
                ref.invalidate(directoryEmployeeProvider(employeeId));
                ref.invalidate(employeeAssignmentsProvider);
              }
            },
            icon: const Icon(Icons.school_outlined),
          ),
      ],
      value: employee,
      refresh: () async {
        ref.invalidate(employeeAssignmentsProvider);
        await ref
            .refresh(directoryEmployeeProvider(employeeId).future)
            .then<void>((_) {});
      },
      content: (employee) => [
        CinematicHero(
          eyebrow: employee.employeeCode,
          title: employee.displayName,
          subtitle: 'Employee profile',
          icon: Icons.person_outline,
          child: _status(employee.isActive),
        ),
        const SizedBox(height: 24),
        CustomCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              InformationRow('Department', employee.department.name),
              InformationRow('Job role', employee.jobRole.name),
              InformationRow(
                'Reporting manager',
                employee.reportingManager ?? 'Not assigned',
              ),
              InformationRow(
                'Date joined',
                employee.dateJoined ?? 'Unavailable',
              ),
              InformationRow(
                'Employment status',
                employee.isActive ? 'Active' : 'Inactive',
              ),
              InformationRow('Login account', switch (employee.loginStatus) {
                'ACTIVE' => 'Active',
                'INACTIVE' => 'Inactive',
                _ => 'Not linked',
              }),
            ],
          ),
        ),
        if (canAssignTrainingToEmployee(
          identity: auth.identity,
          employee: employee,
        )) ...[
          const SizedBox(height: 16),
          FilledButton.icon(
            key: const ValueKey('assign-training-button'),
            onPressed: () async {
              final assigned = await context.push<bool>(
                '/workspace/employees/$employeeId/assign',
                extra: employee,
              );
              if (assigned == true) {
                ref.invalidate(directoryEmployeeProvider(employeeId));
                ref.invalidate(employeeAssignmentsProvider);
              }
            },
            icon: const Icon(Icons.school_outlined),
            label: const Text('Assign training'),
          ),
        ],
        if (canViewEmployeeAssignments(
          auth.identity,
          isCurrentEmployee: isCurrentEmployee ||
              (auth.identity.employee != null &&
                  auth.identity.employee!.employeeCode == employee.employeeCode),
        )) ...[
          const SizedBox(height: 24),
          EmployeeAssignmentsSection(employeeId: employeeId),
        ],
      ],
    );
  }
}
