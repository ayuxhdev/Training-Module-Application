import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:training_app/core/presentation/components/error_view.dart';
import 'package:training_app/core/presentation/components/loading_view.dart';
import 'package:training_app/core/presentation/components/primary_button.dart';
import 'package:training_app/core/presentation/components/status_badge.dart';
import 'package:training_app/core/theme/app_spacing.dart';
import 'package:training_app/core/errors/api_error.dart';
import 'package:training_app/features/learning/data/repositories/learning_repository.dart';
import 'package:training_app/features/learning/domain/models/assignment_detail.dart';
import 'package:training_app/features/learning/presentation/controllers/learning_controller.dart';

class TextLessonScreen extends ConsumerStatefulWidget {
  final int assignmentId;
  final int lessonId;

  const TextLessonScreen({
    super.key,
    required this.assignmentId,
    required this.lessonId,
  });

  @override
  ConsumerState<TextLessonScreen> createState() => _TextLessonScreenState();
}

class _TextLessonScreenState extends ConsumerState<TextLessonScreen> {
  bool _isSubmitting = false;

  Future<void> _completeLesson() async {
    if (_isSubmitting) return;

    setState(() {
      _isSubmitting = true;
    });

    try {
      final repository = ref.read(learningRepositoryProvider);
      await repository.completeTextLesson(widget.assignmentId, widget.lessonId);
      
      if (mounted) {
        ref.invalidate(assignmentDetailProvider(widget.assignmentId));
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Lesson completed successfully')),
        );
        context.pop();
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isSubmitting = false;
        });

        String errorMessage = 'Unable to complete this lesson. Please try again.';
        if (e is ApiError) {
          errorMessage = e.message;
        }

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(errorMessage),
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final detailAsync = ref.watch(assignmentDetailProvider(widget.assignmentId));

    return Scaffold(
      appBar: AppBar(
        title: const Text('Lesson'),
      ),
      body: detailAsync.when(
        data: (detail) {
          LessonLearning? targetLesson;
          for (final module in detail.modules) {
            for (final lesson in module.lessons) {
              if (lesson.id == widget.lessonId) {
                targetLesson = lesson;
                break;
              }
            }
            if (targetLesson != null) break;
          }

          if (targetLesson == null) {
            return ErrorView(
              message: 'Lesson not found',
              onRetry: () => ref.refresh(assignmentDetailProvider(widget.assignmentId).future),
            );
          }

          if (targetLesson.type.toUpperCase() != 'TEXT') {
            return ErrorView(
              message: 'This screen only supports text lessons.',
              onRetry: () => context.pop(),
            );
          }

          final isCompleted = targetLesson.progress.completed;

          return SingleChildScrollView(
            padding: AppSpacing.pagePadding,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(
                      child: Text(
                        targetLesson.title,
                        style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                      ),
                    ),
                    AppSpacing.gapSm,
                    StatusBadge(
                      text: isCompleted ? 'COMPLETED' : 'INCOMPLETE',
                      status: isCompleted ? BadgeStatus.success : BadgeStatus.info,
                    ),
                  ],
                ),
                AppSpacing.gapMd,
                if (targetLesson.isRequired)
                  Text(
                    'Required Lesson',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.primary,
                          fontWeight: FontWeight.bold,
                        ),
                  ),
                AppSpacing.gapLg,
                Text(
                  targetLesson.body.isNotEmpty ? targetLesson.body : 'No content available.',
                  style: Theme.of(context).textTheme.bodyLarge,
                ),
                const SizedBox(height: AppSpacing.xxl),
                if (!isCompleted)
                  PrimaryButton(
                    text: _isSubmitting ? 'Submitting...' : 'Complete Lesson',
                    onPressed: _isSubmitting ? null : _completeLesson,
                  )
                else
                  PrimaryButton(
                    text: 'Back to Module',
                    onPressed: () => context.pop(),
                  ),
              ],
            ),
          );
        },
        loading: () => const LoadingView(),
        error: (error, stackTrace) => ErrorView(
          message: error.toString(),
          onRetry: () => ref.refresh(assignmentDetailProvider(widget.assignmentId).future),
        ),
      ),
    );
  }
}
