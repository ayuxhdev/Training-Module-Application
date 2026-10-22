import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:training_app/core/presentation/components/custom_card.dart';
import 'package:training_app/core/presentation/components/cinematic_components.dart';
import 'package:training_app/core/presentation/components/empty_view.dart';
import 'package:training_app/core/presentation/components/api_error_view.dart';
import 'package:training_app/core/presentation/components/loading_view.dart';
import 'package:training_app/core/presentation/formatters/date_labels.dart';
import 'package:training_app/core/presentation/components/status_badge.dart';
import 'package:training_app/core/theme/app_spacing.dart';
import 'package:training_app/features/auth/domain/models/auth_state.dart';
import 'package:training_app/features/auth/presentation/controllers/auth_controller.dart';
import 'package:training_app/features/dashboard/domain/models/dashboard_data.dart';
import 'package:training_app/features/dashboard/presentation/controllers/dashboard_controller.dart';
import 'package:training_app/features/notifications/presentation/controllers/notification_controller.dart';
import 'package:training_app/features/notifications/presentation/widgets/notification_bell.dart';

class DashboardScreen extends ConsumerWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final authState = ref.watch(authControllerProvider);

    if (authState is! AuthAuthenticated || !authState.canLearn) {
      return const SizedBox.shrink();
    }
    final employeeName = authState.employee!.displayName;

    final dashboardAsync = ref.watch(dashboardDataProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Dashboard'),
        actions: const [NotificationBell()],
      ),
      body: RefreshIndicator(
        onRefresh: () {
          ref.invalidate(notificationUnreadCountProvider);
          return ref
              .refresh(dashboardDataProvider.future)
              .then<void>((_) {}, onError: (Object _, StackTrace _) {});
        },
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            dashboardAsync.when(
              skipLoadingOnRefresh: false,
              skipLoadingOnReload: false,
              data: (data) =>
                  _buildDashboardContent(context, employeeName, data),
              loading: () => const SliverFillRemaining(
                child: LoadingView(message: 'Loading dashboard...'),
              ),
              error: (error, stack) => SliverFillRemaining(
                child: ApiErrorView(
                  error: error,
                  onRetry: () => ref.invalidate(dashboardDataProvider),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDashboardContent(
    BuildContext context,
    String employeeName,
    DashboardData data,
  ) {
    return SliverPadding(
      padding: const EdgeInsets.all(AppSpacing.md),
      sliver: SliverList(
        delegate: SliverChildListDelegate([
          CinematicHero(
            eyebrow: 'Your learning journey',
            title: 'Welcome, $employeeName!',
            subtitle: 'Build your skills. Make every lesson count.',
            icon: Icons.auto_awesome_outlined,
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
    final colors = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionHeading('Overview'),
        LayoutBuilder(
          builder: (context, constraints) {
            // Wrap metrics at large text sizes rather than compressing labels.
            final width = constraints.maxWidth < 720
                ? constraints.maxWidth
                : (constraints.maxWidth - 24) / 3;
            return Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                for (final metric in [
                  ('Assigned', metrics.assigned, Icons.bookmark_outline),
                  ('In Progress', metrics.inProgress, Icons.timelapse_rounded),
                  ('Completed', metrics.completed, Icons.check_circle_outline),
                ])
                  SizedBox(
                    width: width,
                    child: CustomCard(
                      child: Row(
                        children: [
                          Icon(metric.$3, color: colors.primary),
                          const SizedBox(width: 16),
                          Expanded(
                            child: Text(
                              metric.$1,
                              style: Theme.of(context).textTheme.bodyMedium,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            '${metric.$2}',
                            style: Theme.of(context).textTheme.headlineSmall
                                ?.copyWith(
                                  fontWeight: FontWeight.w700,
                                  color: colors.primary,
                                ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
      ],
    );
  }

  Widget _buildActionRequired(
    BuildContext context,
    List<DashboardAssignment> assignments,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionHeading(
          'Action Required',
          subtitle: 'Your next steps, all in one place.',
        ),
        const SizedBox(height: AppSpacing.md),
        if (assignments.isEmpty)
          const EmptyView(
            message: 'No pending assignments.',
            icon: Icons.assignment_turned_in,
          )
        else
          ...assignments.map(
            (assignment) => Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.sm),
              child: LearningCard(
                title: assignment.trainingTitle,
                subtitle: 'Version ${assignment.versionNumber}',
                status: assignment.status,
                badgeStatus: _getBadgeStatus(
                  assignment.status,
                  assignment.isOverdue,
                ),
                onTap: () =>
                    context.push('/learning/assignments/${assignment.id}'),
                footer: assignment.dueAt == null
                    ? null
                    : Text(
                        'Due: ${_formatDate(assignment.dueAt)}',
                        style: TextStyle(
                          color: assignment.isOverdue
                              ? Theme.of(context).colorScheme.error
                              : Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildRecentCertificates(
    BuildContext context,
    List<DashboardCertificate> certificates,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionHeading(
          'Recent Certificates',
          subtitle: 'Milestones you have earned.',
        ),
        const SizedBox(height: AppSpacing.md),
        if (certificates.isEmpty)
          const EmptyView(
            message: 'No certificates earned yet.',
            icon: Icons.workspace_premium,
          )
        else
          ...certificates.map(
            (cert) => Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.sm),
              child: InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: () => context.push('/profile/certificates/${cert.id}'),
                child: CustomCard(
                  child: Row(
                    children: [
                      Icon(
                        Icons.workspace_premium,
                        color: Theme.of(context).colorScheme.secondary,
                        size: 32,
                      ),
                      const SizedBox(width: AppSpacing.md),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              cert.trainingTitle,
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text('Cert #: ${cert.certificateNumber}'),
                            if (cert.issuedAt != null)
                              Text('Issued: ${localDateLabel(cert.issuedAt!)}'),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
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
