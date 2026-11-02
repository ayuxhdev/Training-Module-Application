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
import 'package:training_app/features/management/presentation/controllers/management_controller.dart';

class ManagedAssessmentDetailScreen extends ConsumerStatefulWidget {
  final int versionId;
  final int assessmentId;

  const ManagedAssessmentDetailScreen({
    super.key,
    required this.versionId,
    required this.assessmentId,
  });

  @override
  ConsumerState<ManagedAssessmentDetailScreen> createState() =>
      _ManagedAssessmentDetailScreenState();
}

class _ManagedAssessmentDetailScreenState
    extends ConsumerState<ManagedAssessmentDetailScreen> {
  int _questionsPage = 1;

  @override
  Widget build(BuildContext context) {
    final versionId = widget.versionId;
    final assessmentId = widget.assessmentId;
    final auth = ref.watch(authControllerProvider);
    if (auth is! AuthAuthenticated || !canViewAssessments(auth.identity)) {
      return Scaffold(
        appBar: AppBar(title: const Text('Assessment details')),
        body: const Center(
          child: Text('You do not have permission to view assessments.'),
        ),
      );
    }

    final identity = auth.identity;
    final assessmentAsync = ref.watch(
      managedAssessmentDetailProvider((
        versionId: versionId,
        assessmentId: assessmentId,
      )),
    );
    final versionAsync = ref.watch(managedVersionDetailProvider(versionId));
    final questionsAsync = ref.watch(
      managedAssessmentQuestionsProvider((
        versionId: versionId,
        assessmentId: assessmentId,
        page: _questionsPage,
      )),
    );

    final isDraft = versionAsync.asData?.value.status.toUpperCase() == 'DRAFT';

    return Scaffold(
      appBar: AppBar(
        title: const Text('Assessment details'),
        actions: [
          if (isDraft && canEditAssessments(identity))
            IconButton(
              tooltip: 'Edit assessment',
              icon: const Icon(Icons.edit_outlined),
              onPressed: () {
                final assessment = assessmentAsync.asData?.value;
                context.push(
                  '/workspace/training/versions/$versionId/assessments/$assessmentId/edit',
                  extra: assessment,
                );
              },
            ),
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
            onPressed: () {
              ref.invalidate(
                managedAssessmentDetailProvider((
                  versionId: versionId,
                  assessmentId: assessmentId,
                )),
              );
              ref.invalidate(managedAssessmentQuestionsProvider);
            },
          ),
        ],
      ),
      body: assessmentAsync.when(
        loading: () => const Center(
          child: CardListSkeleton(
            message: 'Loading assessment...',
            compact: true,
          ),
        ),
        error: (error, _) => ApiErrorView(
          error: error,
          onRetry: () {
            ref.invalidate(
              managedAssessmentDetailProvider((
                versionId: versionId,
                assessmentId: assessmentId,
              )),
            );
          },
        ),
        data: (assessment) {
          final isQuiz = assessment.isQuiz;

          return RefreshIndicator(
            onRefresh: () async {
              ref.invalidate(
                managedAssessmentDetailProvider((
                  versionId: versionId,
                  assessmentId: assessmentId,
                )),
              );
              ref.invalidate(managedAssessmentQuestionsProvider);
              await ref.read(
                managedAssessmentDetailProvider((
                  versionId: versionId,
                  assessmentId: assessmentId,
                )).future,
              );
            },
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.all(AppSpacing.md),
              children: [
                CinematicHero(
                  eyebrow: isQuiz ? 'MODULE QUIZ' : 'FINAL ASSESSMENT',
                  title: assessment.title,
                  subtitle: isQuiz
                      ? 'Quiz sequence ${assessment.sequence}'
                      : 'Comprehensive final assessment',
                  icon: isQuiz
                      ? Icons.quiz_outlined
                      : Icons.military_tech_outlined,
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      StatusBadge(
                        text: assessment.kind,
                        status: isQuiz ? BadgeStatus.info : BadgeStatus.success,
                      ),
                      if (assessment.isRequired)
                        const StatusBadge(
                          text: 'REQUIRED',
                          status: BadgeStatus.warning,
                        ),
                      if (!isDraft)
                        const StatusBadge(
                          text: 'LOCKED / IMMUTABLE',
                          status: BadgeStatus.neutral,
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: AppSpacing.lg),

                // Assessment Specifications
                const SectionHeading(
                  'Specifications',
                  subtitle: 'Scoring criteria, attempt limits, and timings.',
                ),
                CustomCard(
                  child: Column(
                    children: [
                      _specRow(
                        context,
                        'Pass percentage',
                        '${double.tryParse(assessment.passPercentage)?.toStringAsFixed(1) ?? assessment.passPercentage}%',
                      ),
                      const Divider(height: AppSpacing.md),
                      _specRow(
                        context,
                        'Maximum attempts',
                        '${assessment.maxAttempts}',
                      ),
                      const Divider(height: AppSpacing.md),
                      _specRow(
                        context,
                        'Time limit',
                        assessment.timeLimitMinutes != null
                            ? '${assessment.timeLimitMinutes} minutes'
                            : 'No time limit',
                      ),
                      if (isQuiz) ...[
                        const Divider(height: AppSpacing.md),
                        _specRow(
                          context,
                          'Module ID',
                          '${assessment.moduleId ?? 'None'}',
                        ),
                        const Divider(height: AppSpacing.md),
                        _specRow(context, 'Sequence', '${assessment.sequence}'),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: AppSpacing.lg),

                // Questions Section
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Expanded(
                      child: SectionHeading(
                        'Attached questions',
                        subtitle: 'Questions attached to this assessment in presentation order.',
                      ),
                    ),
                    if (isDraft && canCreateAssessmentQuestions(identity))
                      FilledButton.icon(
                        icon: const Icon(Icons.add, size: 18),
                        label: const Text('Add question'),
                        onPressed: () {
                          context.push(
                            '/workspace/training/versions/$versionId/assessments/$assessmentId/questions/new',
                          );
                        },
                      ),
                  ],
                ),
                const SizedBox(height: AppSpacing.sm),

                questionsAsync.when(
                  loading: () => const Center(
                    child: Padding(
                      padding: EdgeInsets.all(AppSpacing.md),
                      child: CircularProgressIndicator(),
                    ),
                  ),
                  error: (err, _) => CustomCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Error loading questions: $err'),
                        const SizedBox(height: AppSpacing.sm),
                        TextButton.icon(
                          onPressed: () => ref.refresh(
                            managedAssessmentQuestionsProvider((
                              versionId: versionId,
                              assessmentId: assessmentId,
                              page: _questionsPage,
                            )).future,
                          ),
                          icon: const Icon(Icons.refresh),
                          label: const Text('Retry'),
                        ),
                      ],
                    ),
                  ),
                  data: (page) {
                    final items = page.items;
                    if (items.isEmpty) {
                      return const EmptyView(
                        message: 'No questions attached yet.',
                        icon: Icons.help_outline,
                      );
                    }

                    return Column(
                      children: [
                        ...items.map((q) {
                          return Padding(
                            padding: const EdgeInsets.only(
                              bottom: AppSpacing.sm,
                            ),
                            child: CustomCard(
                              child: Row(
                                children: [
                                  CircleAvatar(
                                    radius: 16,
                                    backgroundColor: Theme.of(context)
                                        .colorScheme
                                        .primaryContainer,
                                    child: Text(
                                      '${q.position}',
                                      style: TextStyle(
                                        fontWeight: FontWeight.bold,
                                        color: Theme.of(context)
                                            .colorScheme
                                            .onPrimaryContainer,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: AppSpacing.md),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          'Question Revision #${q.questionRevisionId}',
                                          style: Theme.of(context)
                                              .textTheme
                                              .titleSmall
                                              ?.copyWith(
                                                fontWeight: FontWeight.w600,
                                              ),
                                        ),
                                        const SizedBox(height: 2),
                                        Text(
                                          'Points: ${q.points}',
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
                                  if (isDraft &&
                                      canAccessAssessmentQuestionEditForm(
                                        identity,
                                      ))
                                    IconButton(
                                      tooltip: 'Edit attachment',
                                      icon: const Icon(
                                        Icons.edit_outlined,
                                        size: 20,
                                      ),
                                      onPressed: () {
                                        context.push(
                                          '/workspace/training/versions/$versionId/assessments/$assessmentId/questions/${q.id}/edit',
                                          extra: q,
                                        );
                                      },
                                    ),
                                ],
                              ),
                            ),
                          );
                        }),
                        if (page.hasMore || _questionsPage > 1)
                          Padding(
                            padding: const EdgeInsets.symmetric(
                              vertical: AppSpacing.sm,
                            ),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                TextButton.icon(
                                  icon: const Icon(Icons.chevron_left),
                                  label: const Text('Previous'),
                                  onPressed: _questionsPage > 1
                                      ? () => setState(() => _questionsPage--)
                                      : null,
                                ),
                                Text(
                                  'Page $_questionsPage · ${page.count} total',
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                                TextButton.icon(
                                  label: const Text('Next'),
                                  icon: const Icon(Icons.chevron_right),
                                  onPressed: page.hasMore
                                      ? () => setState(() => _questionsPage++)
                                      : null,
                                ),
                              ],
                            ),
                          ),
                      ],
                    );
                  },
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _specRow(BuildContext context, String label, String value) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: Theme.of(context).textTheme.bodyMedium
              ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
        ),
        Text(
          value,
          style: Theme.of(context).textTheme.bodyMedium
              ?.copyWith(fontWeight: FontWeight.bold),
        ),
      ],
    );
  }
}
