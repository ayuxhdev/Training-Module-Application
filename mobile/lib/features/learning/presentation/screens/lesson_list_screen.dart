import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:training_app/core/presentation/components/custom_card.dart';
import 'package:training_app/core/presentation/components/error_view.dart';
import 'package:training_app/core/presentation/components/loading_view.dart';
import 'package:training_app/core/presentation/components/empty_view.dart';
import 'package:training_app/core/presentation/components/status_badge.dart';
import 'package:training_app/core/theme/app_spacing.dart';
import 'package:training_app/features/learning/presentation/controllers/learning_controller.dart';

class LessonListScreen extends ConsumerWidget {
  final int assignmentId;
  final int moduleId;

  const LessonListScreen({
    super.key,
    required this.assignmentId,
    required this.moduleId,
  });

  BadgeStatus _getLessonStatusBadge(bool isCompleted) {
    return isCompleted ? BadgeStatus.success : BadgeStatus.warning;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final detailAsync = ref.watch(assignmentDetailProvider(assignmentId));

    return Scaffold(
      appBar: AppBar(
        title: const Text('Lessons'),
      ),
      body: detailAsync.when(
        data: (detail) {
          final moduleIndex = detail.modules.indexWhere((m) => m.id == moduleId);
          
          if (moduleIndex == -1) {
            return ErrorView(
              message: 'Module not found',
              onRetry: () => ref.refresh(assignmentDetailProvider(assignmentId).future),
            );
          }

          final module = detail.modules[moduleIndex];
          final lessons = module.lessons;

          if (lessons.isEmpty) {
            return RefreshIndicator(
              onRefresh: () async => ref.refresh(assignmentDetailProvider(assignmentId).future),
              child: CustomScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                slivers: [
                  SliverFillRemaining(
                    child: EmptyView(
                      message: 'No lessons found in this module.',
                      icon: Icons.play_lesson_outlined,
                    ),
                  ),
                ],
              ),
            );
          }

          return RefreshIndicator(
            onRefresh: () async => ref.refresh(assignmentDetailProvider(assignmentId).future),
            child: ListView.separated(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: AppSpacing.pagePadding,
              itemCount: lessons.length,
              separatorBuilder: (context, index) => AppSpacing.gapMd,
              itemBuilder: (context, index) {
                final lesson = lessons[index];
                final isCompleted = lesson.progress.completed;

                return GestureDetector(
                  onTap: () {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Lesson entry coming soon!'),
                      ),
                    );
                  },
                  child: CustomCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Expanded(
                              child: Text(
                                '${lesson.position}. ${lesson.title}',
                                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                            AppSpacing.gapSm,
                            StatusBadge(
                              text: isCompleted ? 'COMPLETED' : 'PENDING',
                              status: _getLessonStatusBadge(isCompleted),
                            ),
                          ],
                        ),
                        AppSpacing.gapSm,
                        Row(
                          children: [
                            Icon(
                              lesson.type.toUpperCase() == 'VIDEO'
                                  ? Icons.play_circle_outline
                                  : Icons.article_outlined,
                              size: 16,
                              color: Theme.of(context).textTheme.bodySmall?.color,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              lesson.type.toUpperCase(),
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                            if (lesson.isRequired) ...[
                              const SizedBox(width: 8),
                              Text(
                                '• REQUIRED',
                                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                  color: Theme.of(context).colorScheme.error,
                                ),
                              ),
                            ]
                          ],
                        ),
                      ],
                    ),
                  ),
                );
              },
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
