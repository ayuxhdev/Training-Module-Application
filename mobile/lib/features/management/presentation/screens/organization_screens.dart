import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:training_app/core/presentation/components/cinematic_components.dart';
import 'package:training_app/core/presentation/components/custom_card.dart';
import 'package:training_app/core/presentation/components/empty_view.dart';
import 'package:training_app/core/presentation/components/status_badge.dart';
import 'package:training_app/core/theme/app_spacing.dart';
import 'package:training_app/features/auth/domain/models/auth_state.dart';
import 'package:training_app/features/auth/presentation/controllers/auth_controller.dart';
import 'package:training_app/features/management/domain/models/management_models.dart';
import 'package:training_app/features/management/presentation/controllers/management_controller.dart';
import 'package:training_app/features/management/presentation/widgets/employee_deactivation_action.dart';
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
  int _page = 1;
  String? _account;

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
      ref.invalidate(employeeDirectoryProvider(1));
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authControllerProvider);
    final kind = widget.referenceKind;
    final permission = kind?.permission ?? 'organization.view_employee';
    if (auth is! AuthAuthenticated ||
        !auth.identity.capabilities.contains(permission)) {
      return const SizedBox.shrink();
    }
    final account = managementAccount(auth);
    if (_account != account) {
      _account = account;
      _page = 1;
    }
    if (kind == null) {
      return ReadOnlyPage<ManagementPage<DirectoryEmployee>>(
        title: 'Employees',
        actions: [
          if (canCreateEmployee(auth.identity))
            IconButton(
              tooltip: 'Add employee',
              onPressed: () => _openEmployeeCreation(context, ref),
              icon: const Icon(Icons.person_add_alt_1_outlined),
            ),
        ],
        value: ref.watch(employeeDirectoryProvider(_page)),
        refresh: () {
          setState(() => _page = 1);
          return ref
              .refresh(employeeDirectoryProvider(1).future)
              .then<void>((_) {});
        },
        content: (page) => _items(
          page,
          (employee) => CustomCard(
            padding: EdgeInsets.zero,
            child: ListTile(
              contentPadding: const EdgeInsets.all(16),
              title: Text(employee.displayName),
              subtitle: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(employee.employeeCode),
                  Text(
                    '${employee.department.name} · ${employee.jobRole.name}',
                  ),
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
      );
    }
    final canCreate = canCreateOrganizationReference(auth.identity, kind);
    final canEdit = canEditOrganizationReference(auth.identity, kind);
    return ReadOnlyPage<ManagementPage<OrganizationReference>>(
      title: kind.title,
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
      ],
      value: employee,
      refresh: () => ref
          .refresh(directoryEmployeeProvider(employeeId).future)
          .then<void>((_) {}),
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
      ],
    );
  }
}
