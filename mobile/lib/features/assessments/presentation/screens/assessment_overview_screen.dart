import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:training_app/core/presentation/components/custom_card.dart';
import 'package:training_app/core/presentation/components/cinematic_components.dart';
import 'package:training_app/core/presentation/components/cinematic_notice.dart';
import 'package:training_app/core/presentation/components/status_badge.dart';
import 'package:training_app/core/presentation/components/empty_view.dart';
import 'package:training_app/core/presentation/components/api_error_view.dart';
import 'package:training_app/core/presentation/components/loading_view.dart';
import 'package:training_app/features/assessments/domain/models/assessment.dart';
import 'package:training_app/features/assessments/presentation/controllers/assessment_controller.dart';

class AssessmentOverviewScreen extends ConsumerWidget {
  final int assignmentId;
  final int? moduleId;

  const AssessmentOverviewScreen({
    super.key,
    required this.assignmentId,
    this.moduleId,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final provider = assessmentOverviewProvider(assignmentId);
    return Scaffold(
      appBar: AppBar(
        title: Text(moduleId == null ? 'Assessments' : 'Module assessments'),
      ),
      body: ref
          .watch(provider)
          .when(
            skipLoadingOnReload: false,
            skipLoadingOnRefresh: false,
            loading: () =>
                const LoadingView(message: 'Loading your assessments...'),
            error: (error, _) => ApiErrorView(
              error: error,
              onRetry: () => ref.invalidate(provider),
            ),
            data: (catalog) {
              if (catalog == null) return const LoadingView();
              final assessments = catalog.assessments
                  .where(
                    (item) => moduleId == null || item.moduleId == moduleId,
                  )
                  .toList();
              return RefreshIndicator(
                onRefresh: () async {
                  try {
                    await ref.refresh(provider.future).then<void>((_) {});
                  } catch (_) {
                    // The provider renders the refresh failure with a retry action.
                  }
                },
                child: ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.all(16),
                  children: [
                    const CinematicHero(
                      eyebrow: 'Assessment center',
                      title: 'Put your learning into practice.',
                      subtitle: 'Review your requirements and attempts before you begin.',
                      icon: Icons.quiz_outlined,
                    ),
                    const SizedBox(height: 24),
                    if (assessments.isEmpty)
                      const EmptyView(
                        message: 'No assessments available here.',
                        icon: Icons.quiz_outlined,
                      ),
                    for (final assessment in assessments)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 16),
                        child: _AssessmentCard(
                          assignmentId: assignmentId,
                          assessment: assessment,
                        ),
                      ),
                  ],
                ),
              );
            },
          ),
    );
  }
}

class _AssessmentCard extends StatelessWidget {
  final int assignmentId;
  final AssessmentOverview assessment;
  const _AssessmentCard({required this.assignmentId, required this.assessment});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final item = assessment;
    final base = '/learning/assignments/$assignmentId/assessments/${item.id}';
    final label = item.completed
        ? 'Completed'
        : item.eligibility.canResume
        ? 'In progress'
        : item.eligibility.canStart
        ? 'Ready'
        : item.attemptsRemaining == 0
        ? 'No attempts left'
        : 'Locked';
    return CustomCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: item.completed
                      ? colors.primaryContainer.withValues(alpha: 0.5)
                      : colors.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  item.completed ? Icons.task_alt : Icons.quiz_outlined,
                  color: colors.primary,
                  size: 24,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Align(
                  alignment: Alignment.centerRight,
                  child: StatusBadge(
                    text: label,
                    status: item.completed
                        ? BadgeStatus.success
                        : item.eligibility.canStart ||
                              item.eligibility.canResume
                        ? BadgeStatus.info
                        : BadgeStatus.warning,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Text(
            item.title,
            style: theme.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '${item.kind == AssessmentKind.quiz ? 'Module quiz' : 'Final assessment'} • ${item.isRequired ? 'Required' : 'Optional'}',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: colors.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: colors.surfaceContainerLow,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: colors.outlineVariant),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Passing score: ${item.passPercentage}%'),
                const SizedBox(height: 4),
                Text(
                  'Attempts remaining: ${item.attemptsRemaining} of ${item.maxAttempts}',
                ),
                if (item.timeLimitMinutes != null) ...[
                  const SizedBox(height: 4),
                  Text('Time limit: ${item.timeLimitMinutes} minutes'),
                ],
              ],
            ),
          ),
          if (item.eligibility.blockingReason != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: CinematicNotice(
                message: item.eligibility.blockingReason!,
                icon: item.eligibility.canResume
                    ? Icons.pause_circle_outline
                    : Icons.lock_outline,
              ),
            ),
          if (item.eligibility.canStart || item.eligibility.canResume) ...[
            const SizedBox(height: 12),
            FilledButton.icon(
              icon: Icon(
                item.eligibility.canResume ? Icons.play_arrow : Icons.edit_note,
              ),
              label: Text(
                item.eligibility.canResume
                    ? 'Resume assessment'
                    : 'Start assessment',
              ),
              onPressed: () => context.push(
                item.eligibility.canResume && item.ongoingAttemptId != null
                    ? '$base/attempts/${item.ongoingAttemptId}'
                    : '$base/attempt',
              ),
            ),
          ],
          if (item.attempts.isNotEmpty) ...[
            const Divider(height: 32),
            const SectionHeading(
              'Attempt history',
              subtitle: 'Your recorded attempts and results.',
            ),
            for (final attempt in item.attempts)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Container(
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    color: attempt.passed == true
                        ? colors.primaryContainer.withValues(alpha: 0.5)
                        : colors.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(
                    attempt.passed == true
                        ? Icons.check_circle_outline
                        : Icons.history_rounded,
                    color: colors.primary,
                    size: 20,
                  ),
                ),
                title: Text('Attempt ${attempt.attemptNumber}'),
                subtitle: Text(attemptLabel(attempt)),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => context.push('$base/attempts/${attempt.id}'),
              ),
          ],
        ],
      ),
    );
  }
}

String attemptLabel(AssessmentAttemptSummary attempt) =>
    switch (attempt.status) {
      AttemptStatus.inProgress => 'In progress',
      AttemptStatus.expired => 'Expired',
      AttemptStatus.abandoned => 'Abandoned',
      AttemptStatus.submitted =>
        attempt.passed == true ? 'Passed' : 'Not passed',
    };
