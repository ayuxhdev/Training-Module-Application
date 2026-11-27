import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:training_app/core/presentation/components/api_error_view.dart';
import 'package:training_app/core/presentation/components/cadence_masthead.dart';
import 'package:training_app/core/presentation/components/content_skeleton.dart';
import 'package:training_app/core/presentation/components/custom_card.dart';
import 'package:training_app/core/presentation/components/empty_view.dart';
import 'package:training_app/core/presentation/formatters/date_labels.dart';
import 'package:training_app/core/theme/cadence_theme.dart';
import 'package:training_app/core/theme/cadence_tokens.dart';
import 'package:training_app/features/auth/domain/models/auth_state.dart';
import 'package:training_app/features/auth/presentation/controllers/auth_controller.dart';
import 'package:training_app/features/dashboard/domain/models/dashboard_data.dart';
import 'package:training_app/features/dashboard/presentation/controllers/dashboard_controller.dart';
import 'package:training_app/features/dashboard/presentation/widgets/continue_training_card.dart';
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
    final dashboardAsync = ref.watch(dashboardDataProvider);
    return Theme(
      data: CadenceTheme.from(Theme.of(context)),
      child: Builder(
        builder: (context) => Scaffold(
          appBar: const CadenceMasthead(action: NotificationBell()),
          body: RefreshIndicator(
            onRefresh: () {
              ref.invalidate(notificationUnreadCountProvider);
              return ref
                  .refresh(dashboardDataProvider.future)
                  .then<void>((_) {}, onError: (Object _, StackTrace _) {});
            },
            child: CustomScrollView(
              key: ValueKey(authState.personalAccount),
              physics: const AlwaysScrollableScrollPhysics(),
              slivers: [
                dashboardAsync.when(
                  skipLoadingOnRefresh: false,
                  skipLoadingOnReload: false,
                  data: (data) =>
                      _content(context, authState.employee!.displayName, data),
                  loading: () => const SliverToBoxAdapter(
                    child: Padding(
                      padding: EdgeInsets.all(CadenceTokens.pagePadding),
                      child: DashboardSkeleton(),
                    ),
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
        ),
      ),
    );
  }

  Widget _content(
    BuildContext context,
    String employeeName,
    DashboardData data,
  ) {
    final theme = Theme.of(context);
    final largeText = MediaQuery.textScalerOf(context).scale(12) > 18;
    final narrow = MediaQuery.sizeOf(context).width < 360;
    return SliverPadding(
      padding: EdgeInsets.all(narrow ? 16 : CadenceTokens.pagePadding),
      sliver: SliverList(
        delegate: SliverChildListDelegate([
          Text(
            'YOUR DASHBOARD',
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          Semantics(
            header: true,
            child: Text(
              'Hello, $employeeName.',
              style: largeText
                  ? theme.textTheme.titleLarge
                  : theme.textTheme.headlineLarge,
            ),
          ),
          // At large text sizes prioritize identity and the next real action
          // over the decorative tagline. The user's text scale is unchanged.
          if (!largeText) ...[
            const SizedBox(height: 6),
            Text(
              'A little progress. A stronger tomorrow.',
              style: theme.textTheme.bodyLarge?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
          const SizedBox(height: 20),
          if (data.actionRequired.isNotEmpty)
            ContinueTrainingCard(
              assignment: data.actionRequired.first,
              onContinue: () => context.push(
                '/learning/assignments/${data.actionRequired.first.id}',
              ),
            )
          else
            const EmptyView(
              message: 'No pending assignments.',
              icon: Icons.assignment_turned_in,
            ),
          const SizedBox(height: CadenceTokens.sectionGap),
          _metrics(context, data.metrics),
          if (data.actionRequired.length > 1) ...[
            const SizedBox(height: CadenceTokens.sectionGap),
            _heading(context, 'More training'),
            const SizedBox(height: 12),
            ...data.actionRequired
                .skip(1)
                .map(
                  (assignment) => Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: _assignment(context, assignment),
                  ),
                ),
          ],
          const SizedBox(height: CadenceTokens.sectionGap),
          _certificates(context, data.recentCertificates),
        ]),
      ),
    );
  }

  Widget _heading(BuildContext context, String label) => Semantics(
    header: true,
    child: Text(label, style: Theme.of(context).textTheme.titleMedium),
  );

  Widget _metrics(BuildContext context, DashboardMetrics metrics) {
    final theme = Theme.of(context);
    final percentage = metrics.completionPercent.toStringAsFixed(
      metrics.completionPercent % 1 == 0 ? 0 : 1,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _heading(context, 'Overview'),
        const SizedBox(height: 16),
        LayoutBuilder(
          builder: (context, constraints) {
            final stacked =
                constraints.maxWidth < 280 ||
                MediaQuery.textScalerOf(context).scale(12) > 18;
            final width = stacked
                ? constraints.maxWidth
                : (constraints.maxWidth - 24) / 3;
            return Wrap(
              spacing: 12,
              runSpacing: 16,
              children: [
                for (final item in [
                  ('Assigned', metrics.assigned, CadenceTokens.blue),
                  ('In progress', metrics.inProgress, CadenceTokens.violet),
                  ('Completed', metrics.completed, CadenceTokens.teal),
                ])
                  SizedBox(
                    width: width,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        border: Border(
                          left: BorderSide(color: item.$3, width: 3),
                        ),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.only(left: 12),
                        child: stacked
                            ? Row(
                                crossAxisAlignment: CrossAxisAlignment.center,
                                children: [
                                  Expanded(
                                    flex: 3,
                                    child: Text(
                                      item.$1,
                                      style: theme.textTheme.bodyMedium
                                          ?.copyWith(
                                            color: theme
                                                .colorScheme
                                                .onSurfaceVariant,
                                          ),
                                    ),
                                  ),
                                  const SizedBox(width: 16),
                                  Flexible(
                                    child: Text(
                                      '${item.$2}',
                                      style: theme.textTheme.titleLarge,
                                    ),
                                  ),
                                ],
                              )
                            : Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    '${item.$2}',
                                    style: theme.textTheme.headlineLarge
                                        ?.copyWith(fontSize: 28),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    item.$1,
                                    style: theme.textTheme.bodySmall?.copyWith(
                                      color: theme.colorScheme.onSurfaceVariant,
                                    ),
                                  ),
                                ],
                              ),
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
        const SizedBox(height: 20),
        Divider(height: 1, color: theme.colorScheme.outlineVariant),
        const SizedBox(height: 20),
        SizedBox(
          width: double.infinity,
          child: Wrap(
            alignment: WrapAlignment.spaceBetween,
            spacing: 16,
            runSpacing: 4,
            children: [
              Text('Overall completion', style: theme.textTheme.titleMedium),
              Text('$percentage%', style: theme.textTheme.titleMedium),
            ],
          ),
        ),
        const SizedBox(height: 12),
        LinearProgressIndicator(
          value: (metrics.completionPercent / 100).clamp(0.0, 1.0),
          semanticsLabel: 'Overall completion',
          semanticsValue: '$percentage%',
        ),
        const SizedBox(height: 8),
        Text(
          metrics.total == 0
              ? 'No assignments yet.'
              : '${metrics.completed} of ${metrics.total} assignments completed',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          metrics.overdue == 0
              ? 'No overdue training'
              : '${metrics.overdue} overdue ${metrics.overdue == 1 ? 'assignment' : 'assignments'}',
          style: theme.textTheme.bodySmall?.copyWith(
            color: metrics.overdue > 0
                ? CadenceTokens.amber
                : theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }

  Widget _assignment(BuildContext context, DashboardAssignment assignment) {
    final theme = Theme.of(context);
    final status = switch (assignment.status) {
      'IN_PROGRESS' => 'In progress',
      'ASSIGNED' => 'Assigned',
      _ => assignment.status.replaceAll('_', ' '),
    };
    return CustomCard(
      onTap: () => context.push('/learning/assignments/${assignment.id}'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            assignment.trainingTitle,
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 12,
            runSpacing: 6,
            children: [
              Text(status, style: theme.textTheme.bodyMedium),
              Text(
                'Version ${assignment.versionNumber}',
                style: theme.textTheme.bodyMedium,
              ),
              Text(
                assignment.dueAt == null
                    ? 'No deadline'
                    : 'Due ${assignmentDeadlineLabel(assignment.dueAt!)}',
                style: theme.textTheme.bodyMedium,
              ),
              if (assignment.isOverdue)
                Text(
                  'Overdue',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _certificates(
    BuildContext context,
    List<DashboardCertificate> certificates,
  ) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _heading(context, 'Recent Certificates'),
        const SizedBox(height: 16),
        if (certificates.isEmpty)
          const EmptyView(
            message: 'No certificates earned yet.',
            icon: Icons.workspace_premium,
          )
        else
          ...certificates.map(
            (cert) => Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: CustomCard(
                onTap: () => context.push('/profile/certificates/${cert.id}'),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.workspace_premium,
                      color: colors.secondary,
                      size: 26,
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            cert.trainingTitle,
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'Cert #: ${cert.certificateNumber}',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: colors.onSurfaceVariant,
                            ),
                          ),
                          Text(
                            'Version ${cert.versionNumber}',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: colors.onSurfaceVariant,
                            ),
                          ),
                          if (cert.issuedAt != null)
                            Text(
                              'Issued: ${localDateLabel(cert.issuedAt!)}',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: colors.onSurfaceVariant,
                              ),
                            ),
                        ],
                      ),
                    ),
                    Icon(
                      Icons.chevron_right_rounded,
                      color: colors.onSurfaceVariant,
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}
