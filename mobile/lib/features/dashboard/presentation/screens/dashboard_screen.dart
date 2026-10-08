import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:training_app/core/presentation/components/custom_card.dart';
import 'package:training_app/core/presentation/components/empty_view.dart';
import 'package:training_app/core/presentation/components/error_view.dart';
import 'package:training_app/core/presentation/components/loading_view.dart';
import 'package:training_app/core/presentation/components/status_badge.dart';
import 'package:training_app/core/theme/app_spacing.dart';
import 'package:training_app/features/auth/domain/models/auth_state.dart';
import 'package:training_app/features/auth/presentation/controllers/auth_controller.dart';
import 'package:training_app/features/dashboard/domain/models/dashboard_data.dart';
import 'package:training_app/features/dashboard/presentation/controllers/dashboard_controller.dart';

class DashboardScreen extends ConsumerWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final authState = ref.watch(authControllerProvider);

    String employeeName = 'Employee';
    if (authState is AuthAuthenticated) {
      employeeName = authState.employee.displayName;
    }

    final dashboardAsync = ref.watch(dashboardDataProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Dashboard'),
      ),
      body: RefreshIndicator(
        onRefresh: () => ref.refresh(dashboardDataProvider.future),
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            dashboardAsync.when(
              data: (data) => _buildDashboardContent(context, employeeName, data),
              loading: () => const SliverFillRemaining(
                child: LoadingView(message: 'Loading dashboard...'),
              ),
              error: (error, stack) => SliverFillRemaining(
                child: ErrorView(
                  message: error.toString(),
                  onRetry: () => ref.refresh(dashboardDataProvider),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDashboardContent(BuildContext context, String employeeName, DashboardData data) {
    return SliverPadding(
      padding: const EdgeInsets.all(AppSpacing.md),
      sliver: SliverList(
        delegate: SliverChildListDelegate([
          Text(
            'Welcome, $employeeName!',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: AppSpacing.lg),
          _buildMetricsOverview(context, data.metrics),
          const SizedBox(height: AppSpacing.lg),
          _buildActionRequired(context, data.actionRequired),
          const SizedBox(height: AppSpacing.lg),
          _buildRecentCertificates(context, data.recentCertificates),
        ]),
      ),
    );
  }

  Widget _buildMetricsOverview(BuildContext context, DashboardMetrics metrics) {
    return CustomCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Overview', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: AppSpacing.md),
          Wrap(
            alignment: WrapAlignment.spaceAround,
            spacing: AppSpacing.md,
            runSpacing: AppSpacing.md,
            children: [
              _buildMetricItem(context, 'Assigned', metrics.assigned.toString()),
              _buildMetricItem(context, 'In Progress', metrics.inProgress.toString()),
              _buildMetricItem(context, 'Completed', metrics.completed.toString()),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildMetricItem(BuildContext context, String label, String value) {
    return Column(
      children: [
        Text(
          value,
          style: Theme.of(context).textTheme.headlineMedium?.copyWith(
            color: Theme.of(context).colorScheme.primary,
            fontWeight: FontWeight.bold,
          ),
        ),
        Text(label, style: Theme.of(context).textTheme.bodyMedium),
      ],
    );
  }

  Widget _buildActionRequired(BuildContext context, List<DashboardAssignment> assignments) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Action Required', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: AppSpacing.md),
        if (assignments.isEmpty)
          const EmptyView(
            message: 'No pending assignments.',
            icon: Icons.assignment_turned_in,
          )
        else
          ...assignments.map((assignment) => Padding(
                padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                child: CustomCard(
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              assignment.trainingTitle,
                              style: const TextStyle(fontWeight: FontWeight.bold),
                            ),
                            const SizedBox(height: 4),
                            Text('Version ${assignment.versionNumber}'),
                            if (assignment.dueAt != null)
                              Text(
                                'Due: ${_formatDate(assignment.dueAt)}',
                                style: TextStyle(
                                  color: assignment.isOverdue ? Theme.of(context).colorScheme.error : null,
                                  fontWeight: assignment.isOverdue ? FontWeight.bold : FontWeight.normal,
                                ),
                              ),
                          ],
                        ),
                      ),
                      const SizedBox(width: AppSpacing.md),
                      StatusBadge(
                        text: assignment.status,
                        status: _getBadgeStatus(assignment.status, assignment.isOverdue),
                      ),
                    ],
                  ),
                ),
              )),
      ],
    );
  }

  Widget _buildRecentCertificates(BuildContext context, List<DashboardCertificate> certificates) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Recent Certificates', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: AppSpacing.md),
        if (certificates.isEmpty)
          const EmptyView(
            message: 'No certificates earned yet.',
            icon: Icons.workspace_premium,
          )
        else
          ...certificates.map((cert) => Padding(
                padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                child: CustomCard(
                  child: Row(
                    children: [
                      Icon(Icons.workspace_premium, color: Theme.of(context).colorScheme.secondary, size: 32),
                      const SizedBox(width: AppSpacing.md),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              cert.trainingTitle,
                              style: const TextStyle(fontWeight: FontWeight.bold),
                            ),
                            const SizedBox(height: 4),
                            Text('Cert #: ${cert.certificateNumber}'),
                            if (cert.issuedAt != null)
                              Text('Issued: ${_formatDate(cert.issuedAt)}'),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              )),
      ],
    );
  }

  BadgeStatus _getBadgeStatus(String status, bool isOverdue) {
    if (isOverdue) return BadgeStatus.error;
    switch (status.toUpperCase()) {
      case 'COMPLETED':
        return BadgeStatus.success;
      case 'IN_PROGRESS':
        return BadgeStatus.warning;
      case 'ASSIGNED':
        return BadgeStatus.info;
      default:
        return BadgeStatus.info;
    }
  }

  String _formatDate(DateTime? date) {
    if (date == null) return 'N/A';
    return '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
  }
}
