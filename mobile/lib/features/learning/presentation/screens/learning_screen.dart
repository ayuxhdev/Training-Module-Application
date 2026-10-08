import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:training_app/core/presentation/components/custom_card.dart';
import 'package:training_app/core/presentation/components/empty_view.dart';
import 'package:training_app/core/presentation/components/error_view.dart';
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
      appBar: AppBar(
        title: const Text('Learning'),
      ),
      body: assignmentsAsync.when(
        data: (assignments) {
          return RefreshIndicator(
            onRefresh: () async {
              return ref.refresh(assignmentListProvider.future);
            },
            child: assignments.isEmpty
                ? CustomScrollView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    slivers: [
                      SliverFillRemaining(
                        child: const EmptyView(message: 'No assignments found.'),
                      ),
                    ],
                  )
                : ListView.separated(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: AppSpacing.pagePadding,
                    itemCount: assignments.length,
                    separatorBuilder: (context, index) => AppSpacing.gapMd,
                    itemBuilder: (context, index) {
                      final assignment = assignments[index];
                      return _AssignmentCard(assignment: assignment);
                    },
                  ),
          );
        },
        loading: () => const LoadingView(),
        error: (error, stackTrace) => ErrorView(
          message: error.toString(),
          onRetry: () => ref.refresh(assignmentListProvider.future),
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

    return GestureDetector(
      onTap: () => context.go('/learning/assignments/${assignment.id}'),
      child: CustomCard(
        child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Text(
                  assignment.trainingTitle,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                ),
              ),
              AppSpacing.gapSm,
              StatusBadge(
                text: assignment.status.replaceAll('_', ' '),
                status: _getStatusBadge(assignment.status),
              ),
            ],
          ),
          AppSpacing.gapSm,
          Text(
            'Version: ${assignment.versionNumber}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          AppSpacing.gapSm,
          SizedBox(
            width: double.infinity,
            child: Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 8.0,
              runSpacing: 4.0,
              children: [
                Text(
                  'Due: $formattedDate',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: assignment.isOverdue ? Theme.of(context).colorScheme.error : null,
                        fontWeight: assignment.isOverdue ? FontWeight.bold : null,
                      ),
                ),
                Text(
                  'Progress: ${assignment.progressSummary.requiredLessonsCompleted}/${assignment.progressSummary.requiredLessonsTotal}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ],
      ),
      ),
    );
  }
}
