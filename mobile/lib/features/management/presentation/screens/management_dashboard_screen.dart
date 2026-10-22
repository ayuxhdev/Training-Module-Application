import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:training_app/core/presentation/components/cinematic_components.dart';
import 'package:training_app/core/presentation/components/custom_card.dart';
import 'package:training_app/core/presentation/formatters/date_labels.dart';
import 'package:training_app/features/auth/domain/models/auth_state.dart';
import 'package:training_app/features/auth/presentation/controllers/auth_controller.dart';
import 'package:training_app/features/management/domain/models/management_models.dart';
import 'package:training_app/features/management/presentation/controllers/management_controller.dart';
import 'package:training_app/features/management/presentation/widgets/read_only_page.dart';

class ManagementDashboardScreen extends ConsumerWidget {
  const ManagementDashboardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authControllerProvider);
    if (auth is! AuthAuthenticated ||
        !canViewManagementDashboard(auth.identity)) {
      return const SizedBox.shrink();
    }
    return ReadOnlyPage<ManagementDashboard>(
      title: 'Management dashboard',
      value: ref.watch(managementDashboardProvider),
      refresh: () =>
          ref.refresh(managementDashboardProvider.future).then<void>((_) {}),
      content: (dashboard) {
        final metrics = dashboard.metrics;
        final summaryLabels = dashboard.isCompany
            ? const {
                'active_employee_count': 'Active employees',
                'department_count': 'Departments',
                'published_training_count': 'Published trainings',
                'certificates_issued': 'Certificates issued',
              }
            : const {
                'employees_in_scope': 'Active employees in scope',
                'certificates_issued': 'Certificates issued',
              };
        return [
          CinematicHero(
            eyebrow: "Garden's Need",
            title: dashboard.isCompany ? 'Company dashboard' : 'Team dashboard',
            subtitle: dashboard.isCompany
                ? 'Company-wide training overview.'
                : 'Your reporting hierarchy, including your own assignments.',
            icon: dashboard.isCompany
                ? Icons.business_outlined
                : Icons.groups_outlined,
          ),
          const SizedBox(height: 24),
          const SectionHeading('Overview'),
          CustomCard(
            child: Wrap(
              spacing: 32,
              runSpacing: 8,
              children: [
                for (final entry in summaryLabels.entries)
                  InformationRow(
                    entry.value,
                    dashboard.summary[entry.key]?.toString() ?? '—',
                  ),
              ],
            ),
          ),
          const SectionHeading('Assignment status'),
          CustomCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Wrap(
                  spacing: 32,
                  runSpacing: 8,
                  children: [
                    InformationRow('Total assignments', '${metrics.total}'),
                    InformationRow('Assigned', '${metrics.assigned}'),
                    InformationRow('In progress', '${metrics.inProgress}'),
                    InformationRow('Completed', '${metrics.completed}'),
                    InformationRow('Cancelled', '${metrics.cancelled}'),
                    InformationRow('Overdue', '${metrics.overdue}'),
                  ],
                ),
                const Divider(),
                InformationRow('Completion', '${metrics.completionPercent}%'),
              ],
            ),
          ),
          if (!dashboard.isCompany) ...[
            const SectionHeading('Employees with incomplete training'),
            if (dashboard.incompleteEmployees.isEmpty)
              const CustomCard(
                child: Text(
                  'No employees with incomplete training in your scope.',
                ),
              ),
            for (final employee in dashboard.incompleteEmployees)
              Card(
                child: ListTile(
                  title: Text(employee.employeeName),
                  subtitle: Text(
                    '${employee.incompleteCount} incomplete · ${employee.overdueCount} overdue',
                  ),
                  trailing:
                      auth.identity.capabilities.contains(
                        'organization.view_employee',
                      )
                      ? const Icon(Icons.chevron_right)
                      : null,
                  onTap:
                      auth.identity.capabilities.contains(
                        'organization.view_employee',
                      )
                      ? () => context.push(
                          '/workspace/employees/${employee.employeeId}',
                        )
                      : null,
                ),
              ),
          ],
          const SectionHeading('Recent assessment failures'),
          if (dashboard.recentFailures.isEmpty)
            const CustomCard(
              child: Text('There are no recent assessment failures to review.'),
            ),
          for (final failure in dashboard.recentFailures)
            CustomCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    failure.assessmentTitle,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  Text(failure.employeeName),
                  Text(
                    'Score: ${failure.scorePoints} / ${failure.maximumPoints}',
                  ),
                  Text('Submitted: ${localDateLabel(failure.submittedAt)}'),
                  const Text('Not passed'),
                ],
              ),
            ),
        ];
      },
    );
  }
}
