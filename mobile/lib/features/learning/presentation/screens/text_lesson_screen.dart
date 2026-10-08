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

class _LessonLocation {
  final int moduleId;
  final LessonLearning lesson;

  _LessonLocation(this.moduleId, this.lesson);
}

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
  bool _isCompletedLocally = false;
  int _generation = 0;

  @override
  void didUpdateWidget(TextLessonScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.assignmentId != widget.assignmentId || oldWidget.lessonId != widget.lessonId) {
      _generation++;
      _isSubmitting = false;
      _isCompletedLocally = false;
    }
  }

  Future<void> _completeLesson() async {
    if (_isSubmitting) return;

    _generation++;
    final capturedGeneration = _generation;
    final requestedAssignmentId = widget.assignmentId;
    final requestedLessonId = widget.lessonId;

    setState(() {
      _isSubmitting = true;
    });

    try {
      final repository = ref.read(learningRepositoryProvider);
      final result = await repository.completeTextLesson(requestedAssignmentId, requestedLessonId);
      
      if (!mounted) return;

      final bool isCurrentLesson = widget.assignmentId == requestedAssignmentId && widget.lessonId == requestedLessonId;
      final bool isGenerationMatch = _generation == capturedGeneration;

      if (result.completed) {
        // Invalidate if it's for a different lesson, or if it's the current lesson and not stale.
        if (!isCurrentLesson || isGenerationMatch) {
          ref.invalidate(assignmentDetailProvider(requestedAssignmentId));
        }
      }

      if (isCurrentLesson && isGenerationMatch) {
        if (result.completed) {
          _isCompletedLocally = true;
        }
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Lesson completed successfully')),
        );
        setState(() {
          _isSubmitting = false;
        });
      }
    } catch (e) {
      if (!mounted) return;

      final bool isCurrentLesson = widget.assignmentId == requestedAssignmentId && widget.lessonId == requestedLessonId;
      final bool isGenerationMatch = _generation == capturedGeneration;

      if (isCurrentLesson && isGenerationMatch) {
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
          final allLessons = <_LessonLocation>[];
          for (final module in detail.modules) {
            for (final lesson in module.lessons) {
              allLessons.add(_LessonLocation(module.id, lesson));
            }
          }

          final currentIndex = allLessons.indexWhere((loc) => loc.lesson.id == widget.lessonId);
          if (currentIndex == -1) {
            return ErrorView(
              message: 'Lesson not found',
              onRetry: () => ref.refresh(assignmentDetailProvider(widget.assignmentId).future),
            );
          }

          final currentLocation = allLessons[currentIndex];
          final targetLesson = currentLocation.lesson;
          final prevLocation = currentIndex > 0 ? allLessons[currentIndex - 1] : null;
          final nextLocation = currentIndex < allLessons.length - 1 ? allLessons[currentIndex + 1] : null;

          final isCompleted = _isCompletedLocally || targetLesson.progress.completed;
          final isTextLesson = targetLesson.type.toUpperCase() == 'TEXT';

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
                if (isTextLesson)
                  Text(
                    targetLesson.body.isNotEmpty ? targetLesson.body : 'No content available.',
                    style: Theme.of(context).textTheme.bodyLarge,
                  )
                else
                  Container(
                    padding: AppSpacing.pagePadding,
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Center(
                      child: Text(
                        'This ${targetLesson.type} lesson is not supported yet.',
                        style: Theme.of(context).textTheme.bodyMedium,
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ),
                const SizedBox(height: AppSpacing.xxl),
                if (isTextLesson && !isCompleted)
                  PrimaryButton(
                    text: _isSubmitting ? 'Submitting...' : 'Complete Lesson',
                    onPressed: _isSubmitting ? null : _completeLesson,
                  ),
                if (isTextLesson && !isCompleted)
                  AppSpacing.gapLg,
                Row(
                  children: [
                    if (prevLocation != null)
                      Expanded(
                        child: OutlinedButton(
                          onPressed: _isSubmitting ? null : () {
                            context.pushReplacement('/learning/assignments/${widget.assignmentId}/modules/${prevLocation.moduleId}/lessons/${prevLocation.lesson.id}/text');
                          },
                          child: const Text('Previous'),
                        ),
                      )
                    else
                      const Spacer(),
                    
                    if (prevLocation != null && nextLocation != null) 
                      AppSpacing.gapMd,
                      
                    if (nextLocation != null)
                      Expanded(
                        child: OutlinedButton(
                          onPressed: _isSubmitting ? null : () {
                            context.pushReplacement('/learning/assignments/${widget.assignmentId}/modules/${nextLocation.moduleId}/lessons/${nextLocation.lesson.id}/text');
                          },
                          child: const Text('Next'),
                        ),
                      )
                    else
                      const Spacer(),
                  ],
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
