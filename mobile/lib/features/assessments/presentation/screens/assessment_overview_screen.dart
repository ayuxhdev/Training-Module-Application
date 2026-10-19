import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:training_app/core/errors/api_error.dart';
import 'package:training_app/core/presentation/components/custom_card.dart';
import 'package:training_app/core/presentation/components/cinematic_components.dart';
import 'package:training_app/core/presentation/components/cinematic_notice.dart';
import 'package:training_app/core/presentation/components/status_badge.dart';
import 'package:training_app/core/presentation/components/empty_view.dart';
import 'package:training_app/core/presentation/components/error_view.dart';
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
            error: (error, _) => SingleChildScrollView(
              child: ErrorView(
                title: 'Assessments unavailable',
                message: error is ApiError
                    ? error.message
                    : 'Unable to load assessments.',
                onRetry: () => ref.invalidate(provider),
              ),
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
              Icon(
                item.completed ? Icons.task_alt : Icons.quiz_outlined,
                color: theme.colorScheme.primary,
                size: 32,
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
          const SizedBox(height: 20),
          Text(item.title, style: theme.textTheme.titleLarge),
          Text(
            '${item.kind == AssessmentKind.quiz ? 'Module quiz' : 'Final assessment'} • ${item.isRequired ? 'Required' : 'Optional'}',
          ),
          const SizedBox(height: 16),
          Text('Passing score: ${item.passPercentage}%'),
          Text(
            'Attempts remaining: ${item.attemptsRemaining} of ${item.maxAttempts}',
          ),
          if (item.timeLimitMinutes != null)
            Text('Time limit: ${item.timeLimitMinutes} minutes'),
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
          if (item.eligibility.canStart || item.eligibility.canResume)
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
          if (item.attempts.isNotEmpty) ...[
            const Divider(height: 32),
            const SectionHeading(
              'Attempt history',
              subtitle: 'Your recorded attempts and results.',
            ),
            for (final attempt in item.attempts)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  attempt.passed == true
                      ? Icons.check_circle_outline
                      : Icons.history_rounded,
                  color: theme.colorScheme.primary,
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
