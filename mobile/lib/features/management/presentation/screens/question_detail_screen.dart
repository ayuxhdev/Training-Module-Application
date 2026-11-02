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

class QuestionDetailScreen extends ConsumerStatefulWidget {
  final int questionId;
  final ManagedQuestion? initialQuestion;

  const QuestionDetailScreen({
    super.key,
    required this.questionId,
    this.initialQuestion,
  });

  @override
  ConsumerState<QuestionDetailScreen> createState() =>
      _QuestionDetailScreenState();
}

class _QuestionDetailScreenState extends ConsumerState<QuestionDetailScreen> {
  int _page = 1;

  @override
  Widget build(BuildContext context) {
    final questionId = widget.questionId;
    final auth = ref.watch(authControllerProvider);
    if (auth is! AuthAuthenticated || !canViewQuestions(auth.identity)) {
      return Scaffold(
        appBar: AppBar(title: const Text('Question details')),
        body: const Center(
          child: Text('You do not have permission to view question details.'),
        ),
      );
    }

    final identity = auth.identity;
    final questionAsync = ref.watch(managedQuestionDetailProvider(questionId));
    final revisionsAsync = ref.watch(
      managedQuestionRevisionsProvider((questionId: questionId, page: _page)),
    );

    return Scaffold(
      appBar: AppBar(
        title: const Text('Question details'),
        actions: [
          if (canEditQuestions(identity))
            IconButton(
              tooltip: 'Edit question',
              icon: const Icon(Icons.edit_outlined),
              onPressed: () {
                final q = questionAsync.asData?.value ?? widget.initialQuestion;
                context.push(
                  '/workspace/training/questions/$questionId/edit',
                  extra: q,
                );
              },
            ),
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
            onPressed: () {
              ref.invalidate(managedQuestionDetailProvider(questionId));
              ref.invalidate(managedQuestionRevisionsProvider);
            },
          ),
        ],
      ),
      body: questionAsync.when(
        loading: () => const Center(
          child: CardListSkeleton(
            message: 'Loading question...',
            compact: true,
          ),
        ),
        error: (error, _) => ApiErrorView(
          error: error,
          onRetry: () {
            ref.invalidate(managedQuestionDetailProvider(questionId));
          },
        ),
        data: (question) {
          return RefreshIndicator(
            onRefresh: () async {
              ref.invalidate(managedQuestionDetailProvider(questionId));
              ref.invalidate(managedQuestionRevisionsProvider);
              await ref.read(managedQuestionDetailProvider(questionId).future);
            },
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.all(AppSpacing.md),
              children: [
                CinematicHero(
                  eyebrow: 'QUESTION ENTRY',
                  title: question.code,
                  subtitle: question.topic.isNotEmpty
                      ? question.topic
                      : 'No topic designated',
                  icon: Icons.quiz_outlined,
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      StatusBadge(
                        text: question.isActive ? 'ACTIVE' : 'INACTIVE',
                        status: question.isActive
                            ? BadgeStatus.success
                            : BadgeStatus.neutral,
                      ),
                      const StatusBadge(
                        text: 'QUESTION BANK',
                        status: BadgeStatus.info,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: AppSpacing.lg),

                // Revisions Header
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Expanded(
                      child: SectionHeading(
                        'Revisions history',
                        subtitle: 'Revisions are versioned, authored in draft, and frozen for immutability.',
                      ),
                    ),
                    if (canCreateQuestionRevisions(identity))
                      FilledButton.icon(
                        icon: const Icon(Icons.add, size: 18),
                        label: const Text('New revision'),
                        onPressed: () {
                          context.push(
                            '/workspace/training/questions/$questionId/revisions/new',
                          );
                        },
                      ),
                  ],
                ),
                const SizedBox(height: AppSpacing.sm),

                revisionsAsync.when(
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
                        Text('Error loading revisions: $err'),
                        const SizedBox(height: AppSpacing.sm),
                        TextButton.icon(
                          onPressed: () => ref.refresh(
                            managedQuestionRevisionsProvider((
                              questionId: questionId,
                              page: _page,
                            )).future,
                          ),
                          icon: const Icon(Icons.refresh),
                          label: const Text('Retry'),
                        ),
                      ],
                    ),
                  ),
                  data: (page) {
                    final revisions = page.items;
                    if (revisions.isEmpty) {
                      return const EmptyView(
                        message: 'No revisions found for this question.',
                        icon: Icons.history,
                      );
                    }

                    return Column(
                      children: [
                        ...revisions.map((rev) {
                          return Padding(
                            padding: const EdgeInsets.only(
                              bottom: AppSpacing.sm,
                            ),
                            child: CustomCard(
                              child: InkWell(
                                borderRadius: BorderRadius.circular(12),
                                onTap: () {
                                  context.push(
                                    '/workspace/training/questions/$questionId/revisions/${rev.id}',
                                    extra: rev,
                                  );
                                },
                                child: Padding(
                                  padding: const EdgeInsets.all(AppSpacing.sm),
                                  child: Row(
                                    children: [
                                      CircleAvatar(
                                        radius: 18,
                                        backgroundColor: rev.isFrozen
                                            ? Theme.of(context)
                                                  .colorScheme
                                                  .primaryContainer
                                            : Theme.of(context)
                                                  .colorScheme
                                                  .secondaryContainer,
                                        child: Icon(
                                          rev.isFrozen
                                              ? Icons.lock_outline
                                              : Icons.edit_note_outlined,
                                          size: 20,
                                          color: rev.isFrozen
                                              ? Theme.of(context)
                                                    .colorScheme
                                                    .onPrimaryContainer
                                              : Theme.of(context)
                                                    .colorScheme
                                                    .onSecondaryContainer,
                                        ),
                                      ),
                                      const SizedBox(width: AppSpacing.md),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              'Revision ${rev.revisionNumber}',
                                              style: Theme.of(context)
                                                  .textTheme
                                                  .titleSmall
                                                  ?.copyWith(
                                                    fontWeight: FontWeight.bold,
                                                  ),
                                            ),
                                            const SizedBox(height: 2),
                                            Text(
                                              'Type: ${rev.questionType}',
                                              style: Theme.of(context)
                                                  .textTheme
                                                  .bodySmall
                                                  ?.copyWith(
                                                    color: Theme.of(context)
                                                        .colorScheme
                                                        .onSurfaceVariant,
                                                  ),
                                            ),
                                            if (rev.frozenAt != null) ...[
                                              const SizedBox(height: 2),
                                              Text(
                                                'Frozen on: ${rev.frozenAt!.toLocal().toString().split('.').first}',
                                                style: Theme.of(context)
                                                    .textTheme
                                                    .bodySmall
                                                    ?.copyWith(
                                                      color: Theme.of(context)
                                                          .colorScheme
                                                          .onSurfaceVariant,
                                                      fontStyle:
                                                          FontStyle.italic,
                                                    ),
                                              ),
                                            ],
                                          ],
                                        ),
                                      ),
                                      StatusBadge(
                                        text: rev.status,
                                        status: rev.isFrozen
                                            ? BadgeStatus.info
                                            : BadgeStatus.warning,
                                      ),
                                      const SizedBox(width: AppSpacing.xs),
                                      const Icon(Icons.chevron_right, size: 20),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          );
                        }),
                        if (page.hasMore || _page > 1)
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
                                  onPressed: _page > 1
                                      ? () => setState(() => _page--)
                                      : null,
                                ),
                                Text(
                                  'Page $_page · ${page.count} total',
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                                TextButton.icon(
                                  label: const Text('Next'),
                                  icon: const Icon(Icons.chevron_right),
                                  onPressed: page.hasMore
                                      ? () => setState(() => _page++)
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
}
