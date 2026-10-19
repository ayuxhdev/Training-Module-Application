import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:training_app/core/presentation/components/cinematic_components.dart';
import 'package:training_app/core/presentation/components/empty_view.dart';
import 'package:training_app/core/presentation/components/api_error_view.dart';
import 'package:training_app/core/presentation/components/loading_view.dart';
import 'package:training_app/core/presentation/components/status_badge.dart';
import 'package:training_app/core/theme/app_spacing.dart';
import 'package:training_app/features/learning/domain/models/assignment.dart';
import 'package:training_app/features/learning/presentation/controllers/learning_controller.dart';
import 'package:go_router/go_router.dart';

class LearningScreen extends ConsumerWidget {
  const LearningScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final assignmentsAsync = ref.watch(assignmentListProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Learning')),
      body: assignmentsAsync.when(
        skipLoadingOnRefresh: false,
        skipLoadingOnReload: false,
        data: (assignments) {
          return RefreshIndicator(
            onRefresh: () async {
              // The provider renders refresh errors; don't leak a second async error.
              await ref
                  .refresh(assignmentListProvider.future)
                  .then<void>((_) {}, onError: (Object _, StackTrace _) {});
            },
            child: assignments.isEmpty
                ? CustomScrollView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    slivers: [
                      SliverFillRemaining(
                        child: const EmptyView(
                          message: 'No assignments found.',
                        ),
                      ),
                    ],
                  )
                : ListView.separated(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: AppSpacing.pagePadding,
                    itemCount: assignments.length + 1,
                    separatorBuilder: (context, index) => AppSpacing.gapMd,
                    itemBuilder: (context, index) {
                      if (index == 0) {
                        return const CinematicHero(
                          eyebrow: 'Learning library',
                          title: 'Your next chapter.',
                          subtitle: 'Explore your assigned training and pick up where you left off.',
                          icon: Icons.school_outlined,
                        );
                      }
                      final assignment = assignments[index - 1];
                      return _AssignmentCard(assignment: assignment);
                    },
                  ),
          );
        },
        loading: () => const LoadingView(),
        error: (error, stackTrace) => ApiErrorView(
          error: error,
          onRetry: () => ref.invalidate(assignmentListProvider),
        ),
      ),
    );
  }
}

class _AssignmentCard extends StatelessWidget {
  final Assignment assignment;

  const _AssignmentCard({required this.assignment});

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
  Widget build(BuildContext context) {
    final dueDate = assignment.dueAt;
    final formattedDate = dueDate != null
        ? '${dueDate.year}-${dueDate.month.toString().padLeft(2, '0')}-${dueDate.day.toString().padLeft(2, '0')}'
        : 'No due date';

    return LearningCard(
      title: assignment.trainingTitle,
      subtitle: 'Version: ${assignment.versionNumber}',
      status: assignment.status,
      badgeStatus: _getStatusBadge(assignment.status),
      onTap: () => context.go('/learning/assignments/${assignment.id}'),
      footer: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Due: $formattedDate',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: assignment.isOverdue
                  ? Theme.of(context).colorScheme.error
                  : null,
            ),
          ),
          const SizedBox(height: 16),
          LearningProgress(
            completed: assignment.progressSummary.requiredLessonsCompleted,
            total: assignment.progressSummary.requiredLessonsTotal,
            label:
                'Progress: ${assignment.progressSummary.requiredLessonsCompleted}/${assignment.progressSummary.requiredLessonsTotal}',
          ),
        ],
      ),
    );
  }
}
