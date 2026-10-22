import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:training_app/core/presentation/components/cinematic_components.dart';
import 'package:training_app/core/presentation/components/error_view.dart';
import 'package:training_app/core/presentation/components/api_error_view.dart';
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
        actions: [
          IconButton(
            tooltip: 'Module assessments',
            icon: const Icon(Icons.quiz_outlined),
            onPressed: () => context.push(
              '/learning/assignments/$assignmentId/assessments?module=$moduleId',
            ),
          ),
        ],
      ),
      body: detailAsync.when(
        data: (detail) {
          final moduleIndex = detail.modules.indexWhere(
            (m) => m.id == moduleId,
          );

          if (moduleIndex == -1) {
            return ErrorView(
              message: 'Module not found',
              onRetry: () =>
                  ref.invalidate(assignmentDetailProvider(assignmentId)),
            );
          }

          final module = detail.modules[moduleIndex];
          final lessons = module.lessons;

          if (lessons.isEmpty) {
            return RefreshIndicator(
              onRefresh: () => ref
                  .refresh(assignmentDetailProvider(assignmentId).future)
                  .then<void>((_) {}, onError: (Object _, StackTrace _) {}),
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
            onRefresh: () => ref
                .refresh(assignmentDetailProvider(assignmentId).future)
                .then<void>((_) {}, onError: (Object _, StackTrace _) {}),
            child: ListView.separated(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: AppSpacing.pagePadding,
              itemCount: lessons.length,
              separatorBuilder: (context, index) => AppSpacing.gapMd,
              itemBuilder: (context, index) {
                final lesson = lessons[index];
                final isCompleted = lesson.progress.completed;

                return LearningCard(
                  title: '${lesson.position}. ${lesson.title}',
                  subtitle: lesson.type.toUpperCase(),
                  status: isCompleted ? 'COMPLETED' : 'PENDING',
                  badgeStatus: _getLessonStatusBadge(isCompleted),
                  icon: isCompleted
                      ? Icons.check_circle_outline
                      : lesson.type.toUpperCase() == 'VIDEO'
                      ? Icons.play_circle_outline
                      : Icons.article_outlined,
                  footer: lesson.isRequired
                      ? Text(
                          '• REQUIRED',
                          style: Theme.of(context).textTheme.labelMedium
                              ?.copyWith(
                                color: Theme.of(context)
                                    .colorScheme
                                    .onSurfaceVariant,
                              ),
                        )
                      : null,
                  onTap: () {
                    if (lesson.type.toUpperCase() == 'TEXT') {
                      context.go(
                        '/learning/assignments/$assignmentId/modules/$moduleId/lessons/${lesson.id}/text',
                      );
                    } else if (lesson.type.toUpperCase() == 'VIDEO') {
                      context.push(
                        '/learning/assignments/$assignmentId/modules/$moduleId/lessons/${lesson.id}/video',
                      );
                    } else {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(
                            '${lesson.type} lessons are not supported yet.',
                          ),
                        ),
                      );
                    }
                  },
                );
              },
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
