import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:training_app/core/presentation/components/cinematic_components.dart';
import 'package:training_app/core/presentation/components/api_error_view.dart';
import 'package:training_app/core/presentation/components/loading_view.dart';
import 'package:training_app/core/presentation/components/primary_button.dart';
import 'package:training_app/core/presentation/components/status_badge.dart';
import 'package:training_app/core/theme/app_spacing.dart';
import 'package:training_app/features/learning/presentation/controllers/learning_controller.dart';

class AssignmentDetailScreen extends ConsumerWidget {
  final int assignmentId;

  const AssignmentDetailScreen({super.key, required this.assignmentId});

  BadgeStatus _getStatusBadge(String status) {
    switch (status.toUpperCase()) {
      case 'COMPLETED':
        return BadgeStatus.success;
      case 'IN_PROGRESS':
        return BadgeStatus.warning;
      case 'CANCELLED':
        return BadgeStatus.error;
      case 'ASSIGNED':
      default:
        return BadgeStatus.info;
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final detailAsync = ref.watch(assignmentDetailProvider(assignmentId));

    return Scaffold(
      appBar: AppBar(title: const Text('Assignment Detail')),
      body: detailAsync.when(
        skipLoadingOnRefresh: false,
        skipLoadingOnReload: false,
        data: (detail) {
          final dueDate = detail.dueAt;
          final formattedDate = dueDate != null
              ? '${dueDate.year}-${dueDate.month.toString().padLeft(2, '0')}-${dueDate.day.toString().padLeft(2, '0')}'
              : 'No due date';

          return RefreshIndicator(
            onRefresh: () async {
              await ref
                  .refresh(assignmentDetailProvider(assignmentId).future)
                  .then<void>((_) {}, onError: (Object _, StackTrace _) {});
            },
            child: CustomScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              slivers: [
                SliverPadding(
                  padding: AppSpacing.pagePadding,
                  sliver: SliverToBoxAdapter(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        CinematicHero(
                          eyebrow: 'Your training',
                          title: detail.trainingTitle,
                          subtitle: 'Version: ${detail.versionNumber}',
                          icon: Icons.play_lesson_outlined,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Align(
                                alignment: Alignment.centerLeft,
                                child: StatusBadge(
                                  text: detail.status.replaceAll('_', ' '),
                                  status: _getStatusBadge(detail.status),
                                ),
                              ),
                              AppSpacing.gapLg,
                              Text(
                                'Due: $formattedDate',
                                style: Theme.of(context).textTheme.bodyMedium
                                    ?.copyWith(
                                      color: detail.isOverdue
                                          ? Theme.of(context).colorScheme.error
                                          : null,
                                    ),
                              ),
                              AppSpacing.gapLg,
                              LearningProgress(
                                completed: detail.requiredLessonsCompleted,
                                total: detail.requiredLessonsTotal,
                                label:
                                    'Progress: ${detail.requiredLessonsCompleted}/${detail.requiredLessonsTotal} lessons',
                              ),
                              AppSpacing.gapLg,
                              PrimaryButton(
                                text: 'Start Training',
                                onPressed: () => context.go(
                                  '/learning/assignments/$assignmentId/modules',
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 16),
                        OutlinedButton.icon(
                          onPressed: () => context.push(
                            '/learning/assignments/$assignmentId/assessments',
                          ),
                          icon: const Icon(Icons.quiz_outlined),
                          label: const Text('Assessments and attempts'),
                        ),
                        if (detail.status.toUpperCase() == 'COMPLETED') ...[
                          const SizedBox(height: 12),
                          OutlinedButton.icon(
                            onPressed: () =>
                                context.push('/profile/certificates'),
                            icon: const Icon(Icons.workspace_premium_outlined),
                            label: const Text('My Certificates'),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ],
            ),
          );
        },
        loading: () => const LoadingView(),
        error: (error, stackTrace) => ApiErrorView(
          error: error,
          onRetry: () => ref.invalidate(assignmentDetailProvider(assignmentId)),
        ),
      ),
    );
  }
}
