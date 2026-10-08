import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:training_app/core/presentation/components/custom_card.dart';
import 'package:training_app/core/presentation/components/error_view.dart';
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
      appBar: AppBar(
        title: const Text('Assignment Detail'),
      ),
      body: detailAsync.when(
        data: (detail) {
          final dueDate = detail.dueAt;
          final formattedDate = dueDate != null
              ? '${dueDate.year}-${dueDate.month.toString().padLeft(2, '0')}-${dueDate.day.toString().padLeft(2, '0')}'
              : 'No due date';

          return RefreshIndicator(
            onRefresh: () async {
              return ref.refresh(assignmentDetailProvider(assignmentId).future);
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
                        CustomCard(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  Expanded(
                                    child: Text(
                                      detail.trainingTitle,
                                      style: Theme.of(context)
                                          .textTheme
                                          .headlineSmall
                                          ?.copyWith(
                                            fontWeight: FontWeight.bold,
                                          ),
                                    ),
                                  ),
                                  AppSpacing.gapSm,
                                  StatusBadge(
                                    text: detail.status.replaceAll('_', ' '),
                                    status: _getStatusBadge(detail.status),
                                  ),
                                ],
                              ),
                              AppSpacing.gapMd,
                              Text(
                                'Version: ${detail.versionNumber}',
                                style: Theme.of(context).textTheme.bodyMedium,
                              ),
                              AppSpacing.gapSm,
                              Text(
                                'Due: $formattedDate',
                                style: Theme.of(context)
                                    .textTheme
                                    .bodyMedium
                                    ?.copyWith(
                                      color: detail.isOverdue
                                          ? Theme.of(context).colorScheme.error
                                          : null,
                                      fontWeight: detail.isOverdue
                                          ? FontWeight.bold
                                          : null,
                                    ),
                              ),
                              AppSpacing.gapSm,
                              Text(
                                'Progress: ${detail.requiredLessonsCompleted}/${detail.requiredLessonsTotal} lessons',
                                style: Theme.of(context).textTheme.bodyMedium,
                              ),
                              AppSpacing.gapLg,
                              PrimaryButton(
                                text: 'Start Training',
                                onPressed: () {
                                  context.go('/learning/assignments/$assignmentId/modules');
                                },
                              ),
                            ],
                          ),
                        ),
                        // Future modules list can go here
                      ],
                    ),
                  ),
                ),
              ],
            ),
          );
        },
        loading: () => const LoadingView(),
        error: (error, stackTrace) => ErrorView(
          message: error.toString(),
          onRetry: () => ref.refresh(assignmentDetailProvider(assignmentId).future),
        ),
      ),
    );
  }
}
