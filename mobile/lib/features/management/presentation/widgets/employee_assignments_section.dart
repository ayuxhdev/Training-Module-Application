import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:training_app/core/errors/api_error.dart';
import 'package:training_app/core/presentation/components/cinematic_components.dart';
import 'package:training_app/core/presentation/components/custom_card.dart';
import 'package:training_app/core/presentation/components/status_badge.dart';
import 'package:training_app/core/presentation/formatters/date_labels.dart';
import 'package:training_app/core/theme/app_spacing.dart';
import 'package:training_app/features/management/presentation/controllers/management_controller.dart';

class EmployeeAssignmentsSection extends ConsumerStatefulWidget {
  final int employeeId;

  const EmployeeAssignmentsSection({
    super.key,
    required this.employeeId,
  });

  @override
  ConsumerState<EmployeeAssignmentsSection> createState() =>
      _EmployeeAssignmentsSectionState();
}

class _EmployeeAssignmentsSectionState
    extends ConsumerState<EmployeeAssignmentsSection> {
  int _page = 1;

  @override
  void didUpdateWidget(covariant EmployeeAssignmentsSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.employeeId != widget.employeeId) {
      _page = 1;
    }
  }

  Widget _statusBadge(String status) {
    final normalized = status.toUpperCase();
    return switch (normalized) {
      'COMPLETED' => const StatusBadge(
        text: 'Completed',
        status: BadgeStatus.success,
      ),
      'IN_PROGRESS' => const StatusBadge(
        text: 'In Progress',
        status: BadgeStatus.info,
      ),
      'ASSIGNED' => const StatusBadge(
        text: 'Assigned',
        status: BadgeStatus.neutral,
      ),
      'CANCELLED' => const StatusBadge(
        text: 'Cancelled',
        status: BadgeStatus.neutral,
      ),
      _ => StatusBadge(text: status, status: BadgeStatus.neutral),
    };
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final assignmentsAsync = ref.watch(
      employeeAssignmentsProvider((
        employeeId: widget.employeeId,
        page: _page,
      )),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SectionHeading(
          'Training assignments',
          subtitle: 'Assigned courses and completion history.',
        ),
        assignmentsAsync.when(
          loading: () => const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Center(child: CircularProgressIndicator()),
          ),
          error: (error, _) => CustomCard(
            key: const ValueKey('employee-assignments-error'),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.error_outline, color: colors.error),
                    const SizedBox(width: 8),
                    Text(
                      'Unable to load assignments',
                      style: theme.textTheme.titleMedium?.copyWith(
                        color: colors.error,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  error is ApiError
                      ? error.message
                      : 'An error occurred while loading assignments.',
                  style: theme.textTheme.bodyMedium,
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  key: const ValueKey('employee-assignments-retry'),
                  onPressed: () => ref.invalidate(
                    employeeAssignmentsProvider((
                      employeeId: widget.employeeId,
                      page: _page,
                    )),
                  ),
                  icon: const Icon(Icons.refresh),
                  label: const Text('Retry'),
                ),
              ],
            ),
          ),
          data: (page) {
            if (page.items.isEmpty) {
              return const CustomCard(
                key: ValueKey('employee-assignments-empty'),
                child: Text('No training assignments found for this employee.'),
              );
            }

            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ...page.items.map((assignment) {
                  return Padding(
                    padding: const EdgeInsets.only(bottom: AppSpacing.md),
                    child: CustomCard(
                      key: ValueKey('assignment-card-${assignment.id}'),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      assignment.trainingTitle,
                                      style: theme.textTheme.titleMedium
                                          ?.copyWith(
                                            fontWeight: FontWeight.w600,
                                          ),
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      'Version ${assignment.versionNumber}',
                                      style: theme.textTheme.bodySmall
                                          ?.copyWith(
                                            color: colors.onSurfaceVariant,
                                          ),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 8),
                              _statusBadge(assignment.status),
                            ],
                          ),
                          if (assignment.isOverdue) ...[
                            const SizedBox(height: 8),
                            const Align(
                              alignment: Alignment.centerLeft,
                              child: StatusBadge(
                                text: 'Overdue',
                                status: BadgeStatus.error,
                              ),
                            ),
                          ],
                          const Divider(height: 24),
                          if (assignment.assignedAt != null)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 6),
                              child: Row(
                                children: [
                                  Icon(
                                    Icons.calendar_today_outlined,
                                    size: 14,
                                    color: colors.onSurfaceVariant,
                                  ),
                                  const SizedBox(width: 6),
                                  Text(
                                    'Assigned: ${localDateLabel(assignment.assignedAt!)}',
                                    style: theme.textTheme.bodySmall,
                                  ),
                                ],
                              ),
                            ),
                          if (assignment.dueAt != null)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 6),
                              child: Row(
                                children: [
                                  Icon(
                                    Icons.event_outlined,
                                    size: 14,
                                    color: assignment.isOverdue
                                        ? colors.error
                                        : colors.onSurfaceVariant,
                                  ),
                                  const SizedBox(width: 6),
                                  Text(
                                    'Deadline: ${localDateLabel(assignment.dueAt!)}',
                                    style: theme.textTheme.bodySmall?.copyWith(
                                      color: assignment.isOverdue
                                          ? colors.error
                                          : null,
                                      fontWeight: assignment.isOverdue
                                          ? FontWeight.w600
                                          : null,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          if (assignment.completedAt != null)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 6),
                              child: Row(
                                children: [
                                  Icon(
                                    Icons.check_circle_outline,
                                    size: 14,
                                    color: colors.primary,
                                  ),
                                  const SizedBox(width: 6),
                                  Text(
                                    'Completed: ${localDateLabel(assignment.completedAt!)}',
                                    style: theme.textTheme.bodySmall,
                                  ),
                                ],
                              ),
                            ),
                          if (assignment.progressSummary != null &&
                              assignment.progressSummary!.requiredLessonsTotal >
                                  0) ...[
                            const SizedBox(height: 6),
                            ClipRRect(
                              borderRadius: BorderRadius.circular(4),
                              child: LinearProgressIndicator(
                                value:
                                    assignment.progressSummary!
                                        .requiredLessonsCompleted /
                                    assignment.progressSummary!
                                        .requiredLessonsTotal,
                                minHeight: 6,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              '${assignment.progressSummary!.requiredLessonsCompleted} of ${assignment.progressSummary!.requiredLessonsTotal} required lessons completed',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: colors.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  );
                }),
                if (page.count > 0 && (_page > 1 || page.hasMore)) ...[
                  const SizedBox(height: 8),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      TextButton.icon(
                        key: const ValueKey('assignments-previous-page'),
                        onPressed: _page > 1
                            ? () => setState(() => _page--)
                            : null,
                        icon: const Icon(Icons.chevron_left),
                        label: const Text('Previous'),
                      ),
                      Text(
                        'Page $_page',
                        style: theme.textTheme.bodyMedium,
                      ),
                      TextButton.icon(
                        key: const ValueKey('assignments-next-page'),
                        onPressed: page.hasMore
                            ? () => setState(() => _page++)
                            : null,
                        icon: const Icon(Icons.chevron_right),
                        label: const Text('Next'),
                      ),
                    ],
                  ),
                ],
              ],
            );
          },
        ),
      ],
    );
  }
}
