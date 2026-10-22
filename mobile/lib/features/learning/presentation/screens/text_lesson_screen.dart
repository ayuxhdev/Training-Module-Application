import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show ProviderException;
import 'package:go_router/go_router.dart';
import 'package:training_app/core/presentation/components/error_view.dart';
import 'package:training_app/core/presentation/components/api_error_view.dart';
import 'package:training_app/core/presentation/components/cinematic_components.dart';
import 'package:training_app/core/presentation/components/custom_card.dart';
import 'package:training_app/core/presentation/components/loading_view.dart';
import 'package:training_app/core/presentation/components/primary_button.dart';
import 'package:training_app/core/presentation/components/status_badge.dart';
import 'package:training_app/core/theme/app_spacing.dart';
import 'package:training_app/core/errors/api_error.dart';
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
  ApiError? _completionError;

  @override
  void didUpdateWidget(TextLessonScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.assignmentId != widget.assignmentId ||
        oldWidget.lessonId != widget.lessonId) {
      _generation++;
      _isSubmitting = false;
      _isCompletedLocally = false;
      _completionError = null;
    }
  }

  Future<void> _completeLesson() async {
    if (_isSubmitting || _isCompletedLocally || _completionError != null) {
      return;
    }

    _generation++;
    final capturedGeneration = _generation;
    final requestedAssignmentId = widget.assignmentId;
    final requestedLessonId = widget.lessonId;

    setState(() {
      _isSubmitting = true;
    });

    try {
      final result = await ref.read(
        textLessonCompletionProvider((
          assignmentId: requestedAssignmentId,
          lessonId: requestedLessonId,
        )).future,
      );

      if (!mounted) return;

      final bool isCurrentLesson =
          widget.assignmentId == requestedAssignmentId &&
          widget.lessonId == requestedLessonId;
      final bool isGenerationMatch = _generation == capturedGeneration;

      if (isCurrentLesson && isGenerationMatch) {
        if (result.completed) {
          _isCompletedLocally = true;
        }
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              result.completed
                  ? 'Lesson completed successfully'
                  : 'Completion was not confirmed. Please try again.',
            ),
          ),
        );
        setState(() {
          _isSubmitting = false;
        });
      }
    } catch (e) {
      if (!mounted) return;

      final bool isCurrentLesson =
          widget.assignmentId == requestedAssignmentId &&
          widget.lessonId == requestedLessonId;
      final bool isGenerationMatch = _generation == capturedGeneration;

      if (isCurrentLesson && isGenerationMatch) {
        setState(() {
          _isSubmitting = false;
        });

        String errorMessage =
            'Unable to complete this lesson. Please try again.';
        final error = e is ProviderException ? e.exception : e;
        if (error is ApiError) {
          if (error.statusCode == 401 || error.statusCode == 403) {
            setState(() => _completionError = error);
            return;
          }
          errorMessage = error.message;
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
    final detailAsync = ref.watch(
      assignmentDetailProvider(widget.assignmentId),
    );

    return Scaffold(
      appBar: AppBar(title: const Text('Lesson')),
      body: _completionError != null
          ? ApiErrorView(error: _completionError!)
          : detailAsync.when(
              skipLoadingOnRefresh: false,
              data: (detail) {
                final allLessons = <_LessonLocation>[];
                for (final module in detail.modules) {
                  for (final lesson in module.lessons) {
                    allLessons.add(_LessonLocation(module.id, lesson));
                  }
                }

                final currentIndex = allLessons.indexWhere(
                  (loc) => loc.lesson.id == widget.lessonId,
                );
                if (currentIndex == -1) {
                  return ErrorView(
                    message: 'Lesson not found',
                    onRetry: () => ref.invalidate(
                      assignmentDetailProvider(widget.assignmentId),
                    ),
                  );
                }

                final currentLocation = allLessons[currentIndex];
                final targetLesson = currentLocation.lesson;
                final prevLocation = currentIndex > 0
                    ? allLessons[currentIndex - 1]
                    : null;
                final nextLocation = currentIndex < allLessons.length - 1
                    ? allLessons[currentIndex + 1]
                    : null;

                final isCompleted =
                    _isCompletedLocally || targetLesson.progress.completed;
                final isTextLesson = targetLesson.type.toUpperCase() == 'TEXT';
                final acceptsProgress = const {
                  'ASSIGNED',
                  'IN_PROGRESS',
                }.contains(detail.status.toUpperCase());

                return SingleChildScrollView(
                  padding: AppSpacing.pagePadding,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      CinematicHero(
                        eyebrow: 'Learning notes',
                        title: targetLesson.title,
                        subtitle: targetLesson.isRequired
                            ? 'Required Lesson'
                            : 'Lesson content',
                        icon: Icons.article_outlined,
                      ),
                      AppSpacing.gapMd,
                      Align(
                        alignment: Alignment.centerLeft,
                        child: StatusBadge(
                          text: isCompleted ? 'COMPLETED' : 'INCOMPLETE',
                          status: isCompleted
                              ? BadgeStatus.success
                              : BadgeStatus.info,
                        ),
                      ),
                      AppSpacing.gapLg,
                      if (isTextLesson)
                        CustomCard(
                          child: Text(
                            targetLesson.body.isNotEmpty
                                ? targetLesson.body
                                : 'No content available.',
                            style: Theme.of(context).textTheme.bodyLarge
                                ?.copyWith(height: 1.65),
                          ),
                        )
                      else
                        Container(
                          padding: AppSpacing.pagePadding,
                          decoration: BoxDecoration(
                            color: Theme.of(context)
                                .colorScheme
                                .surfaceContainerHighest,
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
                      if (!acceptsProgress) ...[
                        Text(
                          detail.status.toUpperCase() == 'COMPLETED'
                              ? 'This assignment is complete. You can review this lesson without changing its recorded progress.'
                              : 'This assignment no longer accepts lesson progress.',
                        ),
                        AppSpacing.gapLg,
                      ],
                      if (isTextLesson && !isCompleted && acceptsProgress)
                        PrimaryButton(
                          text: _isSubmitting
                              ? 'Submitting...'
                              : 'Complete Lesson',
                          onPressed: _isSubmitting ? null : _completeLesson,
                        ),
                      if (isTextLesson && !isCompleted && acceptsProgress)
                        AppSpacing.gapLg,
                      Row(
                        children: [
                          if (prevLocation != null)
                            Expanded(
                              child: OutlinedButton(
                                onPressed: _isSubmitting
                                    ? null
                                    : () {
                                        final route =
                                            prevLocation.lesson.type
                                                    .toUpperCase() ==
                                                'VIDEO'
                                            ? 'video'
                                            : 'text';
                                        context.pushReplacement(
                                          '/learning/assignments/${widget.assignmentId}/modules/${prevLocation.moduleId}/lessons/${prevLocation.lesson.id}/$route',
                                        );
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
                                onPressed: _isSubmitting
                                    ? null
                                    : () {
                                        final route =
                                            nextLocation.lesson.type
                                                    .toUpperCase() ==
                                                'VIDEO'
                                            ? 'video'
                                            : 'text';
                                        context.pushReplacement(
                                          '/learning/assignments/${widget.assignmentId}/modules/${nextLocation.moduleId}/lessons/${nextLocation.lesson.id}/$route',
                                        );
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
              error: (error, stackTrace) => ApiErrorView(
                error: error,
                onRetry: () => ref.invalidate(
                  assignmentDetailProvider(widget.assignmentId),
                ),
              ),
            ),
    );
  }
}
